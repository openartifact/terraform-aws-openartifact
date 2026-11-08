# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: MPL-2.0

# Tests for the optional EFS persistent volume of the root module: wiring of the file system into
# the web and worker services and the environment variables that point at it. The module itself
# (encryption, access points, policy, security group) is covered by tests/efs.tftest.hcl.
# These runs apply against the mocked provider; nothing touches AWS.
# Run: terraform test -filter=tests/root-efs.tftest.hcl   (or tofu test)

mock_provider "aws" {
  # OpenTofu fills computed attributes with mock values at plan time and the provider schema
  # validates some of them, so ARNs must look like ARNs.
  mock_resource "aws_kms_key" {
    defaults = {
      arn    = "arn:aws:kms:eu-west-1:123456789012:key/00000000-0000-0000-0000-000000000000"
      key_id = "00000000-0000-0000-0000-000000000000"
    }
  }

  mock_resource "aws_security_group" {
    defaults = {
      id  = "sg-0123456789abcdef0"
      arn = "arn:aws:ec2:eu-west-1:123456789012:security-group/sg-0123456789abcdef0"
    }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:eu-west-1:123456789012:log-group:/ecs/oa-test"
    }
  }

  mock_resource "aws_sfn_state_machine" {
    defaults = {
      arn = "arn:aws:states:eu-west-1:123456789012:stateMachine:oa-test-redeploy"
    }
  }

  mock_resource "aws_cloudwatch_event_rule" {
    defaults = {
      arn = "arn:aws:events:eu-west-1:123456789012:rule/oa-test-redeploy"
    }
  }

  mock_resource "aws_s3_bucket" {
    defaults = {
      arn    = "arn:aws:s3:::oa-test-blobs-123456789012-eu-west-1"
      region = "eu-west-1"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/oa-test"
    }
  }

  mock_resource "aws_secretsmanager_secret" {
    defaults = {
      arn = "arn:aws:secretsmanager:eu-west-1:123456789012:secret:oa-test/secret-AbCdEf"
    }
  }

  mock_resource "aws_db_instance" {
    defaults = {
      address = "oa-test.abcdefghijkl.eu-west-1.rds.amazonaws.com"
      master_user_secret = [{
        kms_key_id    = "00000000-0000-0000-0000-000000000000"
        secret_arn    = "arn:aws:secretsmanager:eu-west-1:123456789012:secret:rds!db-00000000-AbCdEf"
        secret_status = "active"
      }]
    }
  }

  mock_resource "aws_lb" {
    defaults = {
      arn        = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:loadbalancer/app/oa-test/0123456789abcdef"
      arn_suffix = "app/oa-test/0123456789abcdef"
      dns_name   = "oa-test-123456.eu-west-1.elb.amazonaws.com"
    }
  }

  mock_resource "aws_lb_listener" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:listener/app/oa-test/0123456789abcdef/0123456789abcdef"
    }
  }

  mock_resource "aws_lb_target_group" {
    defaults = {
      arn        = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:targetgroup/oa-test/0123456789abcdef"
      arn_suffix = "targetgroup/oa-test/0123456789abcdef"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/test"
      user_id    = "AIDATEST"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "eu-west-1"
    }
  }

  mock_data "aws_vpc" {
    defaults = {
      cidr_block = "10.0.0.0/16"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"s3:GetObject\",\"Resource\":\"arn:aws:s3:::bucket/*\"}]}"
    }
  }

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

  mock_resource "aws_iam_instance_profile" {
    defaults = {
      arn = "arn:aws:iam::123456789012:instance-profile/oa-test-ecs-instance"
    }
  }

  mock_resource "aws_launch_template" {
    defaults = {
      id             = "lt-0123456789abcdef0"
      latest_version = 1
    }
  }

  mock_resource "aws_autoscaling_group" {
    defaults = {
      arn = "arn:aws:autoscaling:eu-west-1:123456789012:autoScalingGroup:00000000-0000-0000-0000-000000000000:autoScalingGroupName/oa-test"
    }
  }

  mock_resource "aws_ecs_capacity_provider" {
    defaults = {
      arn = "arn:aws:ecs:eu-west-1:123456789012:capacity-provider/oa-test"
    }
  }

  mock_data "aws_ssm_parameter" {
    defaults = {
      insecure_value = "ami-0123456789abcdef0"
      value          = "ami-0123456789abcdef0"
    }
  }
}

variables {
  name                  = "oa-test"
  vpc_id                = "vpc-0123456789abcdef0"
  private_subnet_ids    = ["subnet-0aaaaaaaaaaaaaaa1", "subnet-0bbbbbbbbbbbbbbb2"]
  public_subnet_ids     = ["subnet-0ccccccccccccccc3", "subnet-0ddddddddddddddd4"]
  certificate_arn       = "arn:aws:acm:eu-west-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
  allowed_ingress_cidrs = ["203.0.113.0/24"]
}

run "disabled_by_default_changes_nothing" {
  command = apply

  variables {
    worker_enabled = true
  }

  assert {
    condition     = length(module.efs) == 0 && output.efs_file_system_id == null && output.efs_access_point_arns == null && output.efs_security_group_id == null
    error_message = "Without persistent_volume.enabled no EFS resources and no EFS outputs must exist."
  }

  assert {
    condition = alltrue([
      for key in ["OPENARTIFACT_SCANNER_CACHE_DIR", "OPENARTIFACT_BACKUP_DIR", "OPENARTIFACT_TRIVY_INSTALL", "OPENARTIFACT_GRYPE_INSTALL"] :
      !contains([for e in jsondecode(module.web.container_definitions)[0].environment : e.name], key) && !contains([for e in jsondecode(module.worker[0].container_definitions)[0].environment : e.name], key)
    ])
    error_message = "Without a persistent volume the scanner cache and backup variables must not be set: the behaviour of existing deployments stays as it is."
  }

  assert {
    condition     = [for m in jsondecode(module.web.container_definitions)[0].mountPoints : m.containerPath] == ["/tmp"] && [for m in jsondecode(module.worker[0].container_definitions)[0].mountPoints : m.containerPath] == ["/tmp"]
    error_message = "/tmp must stay the only mount of both services."
  }
}

run "enabled_mounts_both_uses_in_both_services" {
  command = apply

  variables {
    worker_enabled    = true
    persistent_volume = { enabled = true }
  }

  assert {
    condition     = output.efs_file_system_id == "fs-0123456789abcdef0" && toset(keys(output.efs_access_point_arns)) == toset(["scanner_cache", "backups"])
    error_message = "An enabled volume must create the file system with a scanner_cache and a backups access point."
  }

  assert {
    condition = alltrue([
      for service in [module.web, module.worker[0]] : (
        { for m in jsondecode(service.container_definitions)[0].mountPoints : m.sourceVolume => m.containerPath }
        == { tmp = "/tmp", scanner-cache = "/var/cache/openartifact/scanners", backups = "/var/lib/openartifact/backups" }
      )
    ])
    error_message = "Web and worker must both mount the scanner cache and the backups next to /tmp, so every task sees the same files."
  }

  assert {
    condition = alltrue([
      for service in [module.web, module.worker[0]] : (
        { for e in jsondecode(service.container_definitions)[0].environment : e.name => e.value }["OPENARTIFACT_SCANNER_CACHE_DIR"] == "/var/cache/openartifact/scanners"
        && { for e in jsondecode(service.container_definitions)[0].environment : e.name => e.value }["OPENARTIFACT_BACKUP_DIR"] == "/var/lib/openartifact/backups"
      )
    ])
    error_message = "The directories must be announced to OpenArtifact through OPENARTIFACT_SCANNER_CACHE_DIR and OPENARTIFACT_BACKUP_DIR."
  }

  assert {
    condition     = !contains([for e in jsondecode(module.web.container_definitions)[0].environment : e.name], "OPENARTIFACT_TRIVY_INSTALL") && !contains([for e in jsondecode(module.web.container_definitions)[0].environment : e.name], "OPENARTIFACT_GRYPE_INSTALL")
    error_message = "Scanner auto-install must stay off unless scanner_auto_install is set."
  }

  assert {
    condition     = length(module.efs[0].ingress_security_group_ids) == 2
    error_message = "With a worker the mount targets must accept exactly the web and the worker security groups."
  }

  assert {
    condition     = jsondecode(module.web.container_definitions)[0].readonlyRootFilesystem == true && jsondecode(module.worker[0].container_definitions)[0].readonlyRootFilesystem == true
    error_message = "The root filesystem must stay read-only with a persistent volume."
  }
}

run "single_service_mounts_the_volume_too" {
  command = apply

  variables {
    persistent_volume = { enabled = true }
  }

  assert {
    condition     = length(module.worker) == 0 && length(module.efs[0].ingress_security_group_ids) == 1
    error_message = "Without a worker only the web (role all) security group may reach the mount targets."
  }

  assert {
    condition     = contains([for m in jsondecode(module.web.container_definitions)[0].mountPoints : m.containerPath], "/var/lib/openartifact/backups")
    error_message = "The single all-in-one task runs the backups and must mount the volume."
  }
}

run "scanner_auto_install_sets_both_install_variables" {
  command = apply

  variables {
    persistent_volume = { enabled = true, scanner_auto_install = true }
  }

  assert {
    condition = (
      { for e in jsondecode(module.web.container_definitions)[0].environment : e.name => e.value }["OPENARTIFACT_TRIVY_INSTALL"] == "auto"
      && { for e in jsondecode(module.web.container_definitions)[0].environment : e.name => e.value }["OPENARTIFACT_GRYPE_INSTALL"] == "auto"
    )
    error_message = "scanner_auto_install must set OPENARTIFACT_TRIVY_INSTALL and OPENARTIFACT_GRYPE_INSTALL to auto."
  }
}

run "backups_only" {
  command = apply

  variables {
    persistent_volume = { enabled = true, scanner_cache = false }
  }

  assert {
    condition     = toset(keys(output.efs_access_point_arns)) == toset(["backups"])
    error_message = "Only the backups access point must exist."
  }

  assert {
    condition     = [for m in jsondecode(module.web.container_definitions)[0].mountPoints : m.containerPath if m.sourceVolume != "tmp"] == ["/var/lib/openartifact/backups"]
    error_message = "Only the backup directory must be mounted."
  }

  assert {
    condition     = !contains([for e in jsondecode(module.web.container_definitions)[0].environment : e.name], "OPENARTIFACT_SCANNER_CACHE_DIR") && contains([for e in jsondecode(module.web.container_definitions)[0].environment : e.name], "OPENARTIFACT_BACKUP_DIR")
    error_message = "Only the variable of a mounted directory may be set."
  }
}

run "scanner_cache_only" {
  command = apply

  variables {
    persistent_volume = { enabled = true, backups = false }
  }

  assert {
    condition     = toset(keys(output.efs_access_point_arns)) == toset(["scanner_cache"])
    error_message = "Only the scanner_cache access point must exist."
  }

  assert {
    condition     = !contains([for e in jsondecode(module.web.container_definitions)[0].environment : e.name], "OPENARTIFACT_BACKUP_DIR") && contains([for e in jsondecode(module.web.container_definitions)[0].environment : e.name], "OPENARTIFACT_SCANNER_CACHE_DIR")
    error_message = "Only the variable of a mounted directory may be set."
  }
}

run "extra_environment_can_still_override_a_directory" {
  command = apply

  variables {
    persistent_volume = { enabled = true }
    extra_environment = { OPENARTIFACT_BACKUP_DIR = "/tmp/backups" }
  }

  assert {
    condition     = { for e in jsondecode(module.web.container_definitions)[0].environment : e.name => e.value }["OPENARTIFACT_BACKUP_DIR"] == "/tmp/backups"
    error_message = "An explicit extra_environment value must win over the module's default, as for every other variable."
  }
}

run "customer_managed_key_and_tiering_reach_the_file_system" {
  command = apply

  variables {
    persistent_volume = {
      enabled          = true
      kms_key_arn      = "arn:aws:kms:eu-west-1:123456789012:key/00000000-0000-0000-0000-000000000000"
      transition_to_ia = "AFTER_30_DAYS"
    }
  }

  assert {
    condition     = output.efs_file_system_id == "fs-0123456789abcdef0"
    error_message = "A file system must be created with a customer-managed key and tiering."
  }
}

run "enabled_without_any_use_rejected" {
  command = plan

  variables {
    persistent_volume = { enabled = true, scanner_cache = false, backups = false }
  }

  expect_failures = [var.persistent_volume]
}

run "auto_install_without_cache_rejected" {
  command = plan

  variables {
    persistent_volume = { enabled = true, scanner_cache = false, scanner_auto_install = true }
  }

  expect_failures = [var.persistent_volume]
}

run "unknown_throughput_mode_rejected" {
  command = plan

  variables {
    persistent_volume = { enabled = true, throughput_mode = "turbo" }
  }

  expect_failures = [var.persistent_volume]
}

run "provisioned_throughput_needs_a_value_rejected" {
  command = plan

  variables {
    persistent_volume = { enabled = true, throughput_mode = "provisioned" }
  }

  expect_failures = [var.persistent_volume]
}
