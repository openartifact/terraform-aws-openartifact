# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# Tests for modules/efs. The file system policy embeds the file system ARN, which a mocked plan
# leaves unknown, so the behaviour runs apply against the mocked provider; nothing touches AWS.
# Run: terraform test -filter=tests/efs.tftest.hcl   (or tofu test)

mock_provider "aws" {
  mock_resource "aws_efs_file_system" {
    defaults = {
      arn = "arn:aws:elasticfilesystem:eu-west-1:123456789012:file-system/fs-0123456789abcdef0"
      id  = "fs-0123456789abcdef0"
    }
  }

  mock_resource "aws_efs_access_point" {
    defaults = {
      arn = "arn:aws:elasticfilesystem:eu-west-1:123456789012:access-point/fsap-0123456789abcdef0"
      id  = "fsap-0123456789abcdef0"
    }
  }

  mock_resource "aws_security_group" {
    defaults = {
      id  = "sg-0123456789abcdef0"
      arn = "arn:aws:ec2:eu-west-1:123456789012:security-group/sg-0123456789abcdef0"
    }
  }
}

variables {
  name                       = "oa-test"
  vpc_id                     = "vpc-0123456789abcdef0"
  subnet_ids                 = ["subnet-0aaaaaaaaaaaaaaa1", "subnet-0bbbbbbbbbbbbbbb2"]
  allowed_security_group_ids = ["sg-0aaaaaaaaaaaaaaa1", "sg-0bbbbbbbbbbbbbbb2"]
  access_points = {
    scanner_cache = { path = "/scanner-cache" }
    backups       = { path = "/backups" }
  }
}

run "secure_defaults" {
  command = apply

  module {
    source = "./modules/efs"
  }

  assert {
    condition     = aws_efs_file_system.this.encrypted == true
    error_message = "The file system must always be encrypted, also without a customer-managed key (kms_key_id is then computed: the AWS managed key)."
  }

  assert {
    condition     = aws_efs_file_system.this.performance_mode == "generalPurpose" && aws_efs_file_system.this.throughput_mode == "elastic"
    error_message = "The defaults must be generalPurpose performance and elastic throughput."
  }

  assert {
    condition     = length(aws_efs_file_system.this.lifecycle_policy) == 0
    error_message = "Without transition_to_ia no lifecycle policy must exist."
  }

  assert {
    condition     = aws_efs_backup_policy.this.backup_policy[0].status == "ENABLED"
    error_message = "Automatic backups must be enabled by default."
  }

  assert {
    condition     = length(aws_efs_mount_target.this) == 2 && alltrue([for mt in aws_efs_mount_target.this : length(mt.security_groups) == 1])
    error_message = "Every subnet must get one mount target with the module security group."
  }

  assert {
    condition = (
      length(aws_vpc_security_group_ingress_rule.nfs) == 2
      && alltrue([for r in aws_vpc_security_group_ingress_rule.nfs : r.from_port == 2049 && r.to_port == 2049 && r.ip_protocol == "tcp" && r.cidr_ipv4 == null && r.cidr_ipv6 == null])
      && toset([for r in aws_vpc_security_group_ingress_rule.nfs : r.referenced_security_group_id]) == toset(["sg-0aaaaaaaaaaaaaaa1", "sg-0bbbbbbbbbbbbbbb2"])
    )
    error_message = "NFS (TCP 2049) must be reachable only from the allowed security groups, never from a CIDR block."
  }

  assert {
    condition     = output.file_system_arn == "arn:aws:elasticfilesystem:eu-west-1:123456789012:file-system/fs-0123456789abcdef0" && output.file_system_id == "fs-0123456789abcdef0"
    error_message = "The file system id and ARN must be exported."
  }
}

run "access_points_use_the_image_user_and_0750" {
  command = apply

  module {
    source = "./modules/efs"
  }

  assert {
    condition     = toset(keys(aws_efs_access_point.this)) == toset(["scanner_cache", "backups"]) && toset(keys(output.access_points)) == toset(["scanner_cache", "backups"])
    error_message = "One access point per entry of access_points must exist and be exported by key."
  }

  assert {
    condition = alltrue([
      for ap in aws_efs_access_point.this : (
        ap.posix_user[0].uid == 10001 && ap.posix_user[0].gid == 10001
        && ap.root_directory[0].creation_info[0].owner_uid == 10001
        && ap.root_directory[0].creation_info[0].owner_gid == 10001
        && ap.root_directory[0].creation_info[0].permissions == "0750"
      )
    ])
    error_message = "Every access point must enforce the image user 10001:10001 and create its directory as 10001:10001 with mode 0750."
  }

  assert {
    condition     = { for key, ap in aws_efs_access_point.this : key => ap.root_directory[0].path } == { scanner_cache = "/scanner-cache", backups = "/backups" }
    error_message = "Every access point must root the client in its own directory."
  }
}

run "policy_denies_plain_nfs_and_access_without_access_point" {
  command = apply

  module {
    source = "./modules/efs"
  }

  assert {
    condition = (
      length(jsondecode(aws_efs_file_system_policy.this.policy).Statement) == 2
      && alltrue([for s in jsondecode(aws_efs_file_system_policy.this.policy).Statement : s.Effect == "Deny"])
    )
    error_message = "The file system policy must consist of Deny statements only: access is granted by the task role."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_efs_file_system_policy.this.policy).Statement :
      s.Condition.Bool["aws:SecureTransport"] == "false" if try(s.Condition.Bool, null) != null
    ])
    error_message = "The policy must deny every request that does not use TLS (aws:SecureTransport = false)."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_efs_file_system_policy.this.policy).Statement :
      toset(s.Action) == toset(["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite", "elasticfilesystem:ClientRootAccess"])
      && s.Condition.Null["elasticfilesystem:AccessPointArn"] == "true"
      if try(s.Condition.Null, null) != null
    ])
    error_message = "The policy must deny mounting and writing without an access point (elasticfilesystem:AccessPointArn is null)."
  }

  assert {
    condition     = alltrue([for s in jsondecode(aws_efs_file_system_policy.this.policy).Statement : s.Resource == "arn:aws:elasticfilesystem:eu-west-1:123456789012:file-system/fs-0123456789abcdef0"])
    error_message = "Every policy statement must be scoped to the file system."
  }
}

run "customer_managed_key_tiering_and_provisioned_throughput" {
  command = apply

  module {
    source = "./modules/efs"
  }

  variables {
    kms_key_arn                     = "arn:aws:kms:eu-west-1:123456789012:key/00000000-0000-0000-0000-000000000000"
    transition_to_ia                = "AFTER_30_DAYS"
    throughput_mode                 = "provisioned"
    provisioned_throughput_in_mibps = 64
    backup_policy_enabled           = false
  }

  assert {
    condition     = aws_efs_file_system.this.kms_key_id == "arn:aws:kms:eu-west-1:123456789012:key/00000000-0000-0000-0000-000000000000" && aws_efs_file_system.this.encrypted == true
    error_message = "A customer-managed key must be passed to the file system."
  }

  assert {
    condition = (
      toset([for p in aws_efs_file_system.this.lifecycle_policy : p.transition_to_ia if p.transition_to_ia != null]) == toset(["AFTER_30_DAYS"])
      && toset([for p in aws_efs_file_system.this.lifecycle_policy : p.transition_to_primary_storage_class if p.transition_to_primary_storage_class != null]) == toset(["AFTER_1_ACCESS"])
    )
    error_message = "Tiering must move files to IA after 30 days and back to Standard on first access."
  }

  assert {
    condition     = aws_efs_file_system.this.throughput_mode == "provisioned" && aws_efs_file_system.this.provisioned_throughput_in_mibps == 64
    error_message = "Provisioned throughput must be passed through."
  }

  assert {
    condition     = aws_efs_backup_policy.this.backup_policy[0].status == "DISABLED"
    error_message = "backup_policy_enabled = false must disable the automatic backups."
  }
}

run "provisioned_throughput_needs_a_value" {
  command = plan

  module {
    source = "./modules/efs"
  }

  variables {
    throughput_mode = "provisioned"
  }

  expect_failures = [var.provisioned_throughput_in_mibps]
}

run "throughput_value_without_provisioned_mode_rejected" {
  command = plan

  module {
    source = "./modules/efs"
  }

  variables {
    provisioned_throughput_in_mibps = 64
  }

  expect_failures = [var.provisioned_throughput_in_mibps]
}

run "elastic_throughput_rejects_max_io" {
  command = plan

  module {
    source = "./modules/efs"
  }

  variables {
    performance_mode = "maxIO"
  }

  expect_failures = [var.throughput_mode]
}

run "unknown_tiering_period_rejected" {
  command = plan

  module {
    source = "./modules/efs"
  }

  variables {
    transition_to_ia = "AFTER_2_DAYS"
  }

  expect_failures = [var.transition_to_ia]
}

run "access_point_at_the_root_rejected" {
  command = plan

  module {
    source = "./modules/efs"
  }

  variables {
    access_points = { everything = { path = "/" } }
  }

  expect_failures = [var.access_points]
}

run "bad_kms_key_rejected" {
  command = plan

  module {
    source = "./modules/efs"
  }

  variables {
    kms_key_arn = "my-key"
  }

  expect_failures = [var.kms_key_arn]
}
