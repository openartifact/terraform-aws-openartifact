# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# Plan-only behaviour tests for modules/database. No AWS access: the provider
# is mocked.

mock_provider "aws" {
  # Computed ARNs are validated by the provider schema (OpenTofu applies the
  # mock values at plan time), so they must look like ARNs.
  mock_resource "aws_kms_key" {
    defaults = {
      arn    = "arn:aws:kms:eu-west-1:123456789012:key/00000000-0000-0000-0000-000000000000"
      key_id = "00000000-0000-0000-0000-000000000000"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/oa-test-rds-mon"
    }
  }

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/test"
      user_id    = "AIDATEST"
    }
  }

  override_data {
    target = data.aws_partition.current
    values = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }

  override_data {
    target = data.aws_region.current
    values = {
      region = "eu-west-1"
    }
  }

  override_data {
    target = data.aws_iam_policy_document.kms[0]
    values = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"EnableIamPolicies\",\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"arn:aws:iam::123456789012:root\"},\"Action\":\"kms:*\",\"Resource\":\"*\"}]}"
    }
  }

  override_data {
    target = data.aws_iam_policy_document.monitoring_assume_role[0]
    values = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"monitoring.rds.amazonaws.com\"},\"Action\":\"sts:AssumeRole\"}]}"
    }
  }
}

variables {
  name       = "oa-test"
  vpc_id     = "vpc-0123456789abcdef0"
  subnet_ids = ["subnet-0aaaaaaaaaaaaaaa1", "subnet-0bbbbbbbbbbbbbbb2"]
}

run "secure_defaults" {
  command = plan

  module {
    source = "./modules/database"
  }

  assert {
    condition     = aws_db_instance.this.storage_encrypted == true
    error_message = "Storage must be encrypted."
  }

  assert {
    condition     = aws_db_instance.this.deletion_protection == true
    error_message = "Deletion protection must default to true."
  }

  assert {
    condition     = aws_db_instance.this.manage_master_user_password == true
    error_message = "The master password must be managed by RDS in Secrets Manager."
  }

  assert {
    condition     = aws_db_instance.this.password == null && aws_db_instance.this.password_wo == null
    error_message = "No static or write-only master password may be configured."
  }

  assert {
    condition     = aws_db_instance.this.publicly_accessible == false
    error_message = "The instance must not be publicly accessible."
  }

  assert {
    condition     = aws_db_instance.this.skip_final_snapshot == false
    error_message = "The final snapshot must not be skipped by default."
  }

  assert {
    condition     = aws_db_instance.this.copy_tags_to_snapshot == true
    error_message = "Tags must be copied to snapshots."
  }

  assert {
    condition     = aws_db_instance.this.multi_az == true && aws_db_instance.this.storage_type == "gp3"
    error_message = "Defaults must be Multi-AZ on gp3."
  }

  assert {
    condition     = aws_db_instance.this.engine == "postgres" && aws_db_instance.this.engine_version == "17"
    error_message = "Only the PostgreSQL major version must be requested."
  }

  assert {
    condition     = aws_db_instance.this.iam_database_authentication_enabled == false
    error_message = "IAM database authentication must be off."
  }

  assert {
    condition     = aws_db_instance.this.max_allocated_storage == 200
    error_message = "Storage autoscaling must default to 200 GiB."
  }

  assert {
    condition     = aws_db_parameter_group.database.family == "postgres17"
    error_message = "The parameter group family must follow the engine major."
  }
}

run "dedicated_kms_key_with_rotation" {
  command = plan

  module {
    source = "./modules/database"
  }

  assert {
    condition     = length(aws_kms_key.database) == 1 && aws_kms_key.database[0].enable_key_rotation == true
    error_message = "A dedicated KMS key with rotation must be created by default."
  }

  assert {
    condition     = aws_kms_alias.database[0].name == "alias/oa-test-database"
    error_message = "The KMS key must carry a descriptive alias."
  }

  assert {
    condition     = aws_db_instance.this.performance_insights_enabled == true && aws_db_instance.this.performance_insights_retention_period == 7
    error_message = "Performance Insights must default to on with 7 days of retention."
  }
}

run "external_kms_key_is_used_and_no_key_created" {
  command = plan

  module {
    source = "./modules/database"
  }

  variables {
    kms_key_arn = "arn:aws:kms:eu-west-1:123456789012:key/11111111-2222-3333-4444-555555555555"
  }

  assert {
    condition     = length(aws_kms_key.database) == 0
    error_message = "No KMS key may be created when kms_key_arn is supplied."
  }

  assert {
    condition     = aws_db_instance.this.kms_key_id == var.kms_key_arn && aws_db_instance.this.master_user_secret_kms_key_id == var.kms_key_arn
    error_message = "Storage and the master secret must use the supplied key."
  }

  assert {
    condition     = aws_db_instance.this.performance_insights_kms_key_id == var.kms_key_arn
    error_message = "Performance Insights must use the supplied key."
  }
}

run "force_ssl_cannot_be_overridden" {
  command = plan

  module {
    source = "./modules/database"
  }

  variables {
    parameters = {
      "rds.force_ssl"              = "0"
      "log_min_duration_statement" = "1000"
    }
  }

  assert {
    condition     = [for p in aws_db_parameter_group.database.parameter : p.value if p.name == "rds.force_ssl"] == ["1"]
    error_message = "rds.force_ssl must be exactly one parameter with value 1."
  }

  assert {
    condition     = contains([for p in aws_db_parameter_group.database.parameter : p.name], "log_min_duration_statement")
    error_message = "Caller parameters must be merged into the parameter group."
  }
}

run "ssl_forced_without_overrides" {
  command = plan

  module {
    source = "./modules/database"
  }

  assert {
    condition     = [for p in aws_db_parameter_group.database.parameter : p.value if p.name == "rds.force_ssl"] == ["1"]
    error_message = "rds.force_ssl must be 1 by default."
  }
}

run "no_ingress_rules_without_allowed_security_groups" {
  command = plan

  module {
    source = "./modules/database"
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.postgres_from_allowed) == 0
    error_message = "No ingress rule may exist when no security group is allowed."
  }
}

run "ingress_rule_per_allowed_security_group" {
  command = plan

  module {
    source = "./modules/database"
  }

  variables {
    allowed_security_group_ids = ["sg-0aaaaaaaaaaaaaaa1", "sg-0bbbbbbbbbbbbbbb2"]
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.postgres_from_allowed) == 2
    error_message = "One ingress rule per allowed security group is expected."
  }

  assert {
    condition = alltrue([
      for r in aws_vpc_security_group_ingress_rule.postgres_from_allowed :
      r.from_port == 5432 && r.to_port == 5432 && r.ip_protocol == "tcp" && r.cidr_ipv4 == null
    ])
    error_message = "Ingress rules must be TCP 5432 from a security group, never from a CIDR."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.postgres_from_allowed[1].referenced_security_group_id == "sg-0bbbbbbbbbbbbbbb2"
    error_message = "Rules must reference the allowed security groups by index."
  }
}

run "no_monitoring_role_by_default" {
  command = plan

  module {
    source = "./modules/database"
  }

  assert {
    condition     = length(aws_iam_role.monitoring) == 0 && aws_db_instance.this.monitoring_interval == 0
    error_message = "No monitoring role may be created when Enhanced Monitoring is off."
  }
}

run "monitoring_role_when_enabled" {
  command = plan

  module {
    source = "./modules/database"
  }

  variables {
    monitoring_interval = 60
  }

  assert {
    condition     = length(aws_iam_role.monitoring) == 1 && length(aws_iam_role_policy_attachment.monitoring) == 1
    error_message = "A monitoring role and its policy attachment must be created when monitoring_interval > 0."
  }

  assert {
    condition     = aws_iam_role_policy_attachment.monitoring[0].policy_arn == "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
    error_message = "The AWS managed Enhanced Monitoring policy must be attached."
  }
}

run "autoscaling_disabled_with_zero" {
  command = plan

  module {
    source = "./modules/database"
  }

  variables {
    max_allocated_storage = 0
  }

  assert {
    condition     = aws_db_instance.this.max_allocated_storage == null
    error_message = "max_allocated_storage = 0 must disable storage autoscaling (null)."
  }
}

run "final_snapshot_skipped_on_request" {
  command = plan

  module {
    source = "./modules/database"
  }

  variables {
    skip_final_snapshot = true
  }

  assert {
    condition     = aws_db_instance.this.skip_final_snapshot == true && aws_db_instance.this.final_snapshot_identifier == null
    error_message = "No final snapshot identifier may be set when the snapshot is skipped."
  }
}

run "performance_insights_off" {
  command = plan

  module {
    source = "./modules/database"
  }

  variables {
    performance_insights_enabled = false
  }

  assert {
    condition     = aws_db_instance.this.performance_insights_enabled == false
    error_message = "Performance Insights must be disabled when requested."
  }
}

run "rejects_unsupported_engine_version" {
  command = plan

  module {
    source = "./modules/database"
  }

  variables {
    engine_version = "14"
  }

  expect_failures = [var.engine_version]
}

run "rejects_minor_engine_version" {
  command = plan

  module {
    source = "./modules/database"
  }

  variables {
    engine_version = "17.4"
  }

  expect_failures = [var.engine_version]
}

run "rejects_zero_backup_retention" {
  command = plan

  module {
    source = "./modules/database"
  }

  variables {
    backup_retention_period = 0
  }

  expect_failures = [var.backup_retention_period]
}

run "rejects_excessive_backup_retention" {
  command = plan

  module {
    source = "./modules/database"
  }

  variables {
    backup_retention_period = 36
  }

  expect_failures = [var.backup_retention_period]
}

run "rejects_single_subnet" {
  command = plan

  module {
    source = "./modules/database"
  }

  variables {
    subnet_ids = ["subnet-0aaaaaaaaaaaaaaa1"]
  }

  expect_failures = [var.subnet_ids]
}

run "rejects_bad_instance_class" {
  command = plan

  module {
    source = "./modules/database"
  }

  variables {
    instance_class = "t4g.medium"
  }

  expect_failures = [var.instance_class]
}

run "rejects_max_storage_below_allocated" {
  command = plan

  module {
    source = "./modules/database"
  }

  variables {
    allocated_storage     = 100
    max_allocated_storage = 50
  }

  expect_failures = [var.max_allocated_storage]
}

run "rejects_bad_allowed_security_group" {
  command = plan

  module {
    source = "./modules/database"
  }

  variables {
    allowed_security_group_ids = ["0.0.0.0/0"]
  }

  expect_failures = [var.allowed_security_group_ids]
}
