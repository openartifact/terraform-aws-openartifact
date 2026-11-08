# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: MPL-2.0

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_region" "current" {}

locals {
  port                   = 5432
  create_kms_key         = var.kms_key_arn == null
  kms_key_arn            = local.create_kms_key ? one(aws_kms_key.database[*].arn) : var.kms_key_arn
  create_monitoring      = var.monitoring_interval > 0
  parameter_group_family = "postgres${var.engine_version}"

  # rds.force_ssl is merged last so a caller can never turn TLS off.
  parameters = merge(var.parameters, { "rds.force_ssl" = "1" })
}

# ---------------------------------------------------------------------------
# Encryption key (storage, Performance Insights and the RDS-managed master
# user secret all use the same CMK)
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "kms" {
  count = local.create_kms_key ? 1 : 0

  statement {
    sid       = "EnableIamPolicies"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  # RDS creates grants on this key for storage and Performance Insights, and
  # Secrets Manager uses it for the managed master-user secret and its
  # rotation. Principals of this account may use the key only through those
  # two services.
  statement {
    sid    = "AllowUseThroughRdsAndSecretsManager"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:CreateGrant",
      "kms:DescribeKey",
    ]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values = [
        "rds.${data.aws_region.current.region}.amazonaws.com",
        "secretsmanager.${data.aws_region.current.region}.amazonaws.com",
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_kms_key" "database" {
  count = local.create_kms_key ? 1 : 0

  description             = "OpenArtifact ${var.name} database (RDS storage, Performance Insights, master-user secret)"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms[0].json

  tags = merge(var.tags, { Name = "${var.name}-database" })
}

resource "aws_kms_alias" "database" {
  count = local.create_kms_key ? 1 : 0

  name          = "alias/${var.name}-database"
  target_key_id = aws_kms_key.database[0].key_id
}

# ---------------------------------------------------------------------------
# Network access
# ---------------------------------------------------------------------------

resource "aws_db_subnet_group" "database" {
  name_prefix = "${var.name}-"
  description = "OpenArtifact ${var.name} database subnets"
  subnet_ids  = var.subnet_ids

  tags = merge(var.tags, { Name = "${var.name}-database" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "database" {
  name_prefix = "${var.name}-database-"
  description = "OpenArtifact ${var.name} database: PostgreSQL from allowed security groups only"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-database" })

  lifecycle {
    create_before_destroy = true
  }
}

# Indexed (not for_each) because the security group IDs are often unknown
# until apply, and unknown values cannot be for_each keys.
resource "aws_vpc_security_group_ingress_rule" "postgres_from_allowed" {
  count = length(var.allowed_security_group_ids)

  security_group_id            = aws_security_group.database.id
  referenced_security_group_id = var.allowed_security_group_ids[count.index]
  description                  = "PostgreSQL from allowed security group ${count.index}"
  ip_protocol                  = "tcp"
  from_port                    = local.port
  to_port                      = local.port

  tags = merge(var.tags, { Name = "${var.name}-database-postgres-${count.index}" })
}

# ---------------------------------------------------------------------------
# Parameter group
# ---------------------------------------------------------------------------

resource "aws_db_parameter_group" "database" {
  name_prefix = "${var.name}-"
  description = "OpenArtifact ${var.name} PostgreSQL parameters"
  family      = local.parameter_group_family

  dynamic "parameter" {
    for_each = local.parameters

    content {
      name         = parameter.key
      value        = parameter.value
      apply_method = parameter.key == "rds.force_ssl" ? "immediate" : "pending-reboot"
    }
  }

  tags = merge(var.tags, { Name = "${var.name}-database" })

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Enhanced Monitoring role (only when monitoring_interval > 0)
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "monitoring_assume_role" {
  count = local.create_monitoring ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "monitoring" {
  count = local.create_monitoring ? 1 : 0

  name_prefix        = "${var.name}-rds-mon-"
  description        = "RDS Enhanced Monitoring for the OpenArtifact ${var.name} database"
  assume_role_policy = data.aws_iam_policy_document.monitoring_assume_role[0].json

  tags = merge(var.tags, { Name = "${var.name}-rds-monitoring" })
}

resource "aws_iam_role_policy_attachment" "monitoring" {
  count = local.create_monitoring ? 1 : 0

  role       = aws_iam_role.monitoring[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# ---------------------------------------------------------------------------
# DB instance
# ---------------------------------------------------------------------------

# Suffix of the final snapshot name. Generated once and kept in state, so the
# name is stable across plans but a destroy/re-create of the same <name> never
# collides with an older final snapshot.
resource "random_id" "final_snapshot" {
  byte_length = 4
}

resource "aws_db_instance" "this" {
  #checkov:skip=CKV_AWS_118: Enhanced Monitoring is opt-in through monitoring_interval (Performance Insights and CloudWatch log exports are on by default); the role is created when enabled.
  #checkov:skip=CKV_AWS_161: OpenArtifact authenticates with the RDS-managed, Secrets Manager rotated master password; IAM database authentication is deliberately off.
  #checkov:skip=CKV2_AWS_69: TLS is enforced server-side by rds.force_ssl = 1 in the parameter group, which cannot be overridden (checkov does not follow the parameter group).

  identifier = var.name

  engine = "postgres"
  # Major only: with auto_minor_version_upgrade the provider treats the
  # configured prefix as a match for the running minor (engine_version_actual),
  # so automatic minor upgrades produce no plan diff and no ignore_changes is needed.
  engine_version       = var.engine_version
  instance_class       = var.instance_class
  parameter_group_name = aws_db_parameter_group.database.name
  ca_cert_identifier   = var.ca_cert_identifier

  db_name = var.database_name
  port    = local.port

  username                      = var.master_username
  manage_master_user_password   = true
  master_user_secret_kms_key_id = local.kms_key_arn

  iam_database_authentication_enabled = false

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage == 0 ? null : var.max_allocated_storage
  storage_type          = var.storage_type
  storage_encrypted     = true
  kms_key_id            = local.kms_key_arn

  multi_az               = var.multi_az
  db_subnet_group_name   = aws_db_subnet_group.database.name
  vpc_security_group_ids = [aws_security_group.database.id]
  publicly_accessible    = false

  backup_retention_period  = var.backup_retention_period
  backup_window            = var.backup_window
  maintenance_window       = var.maintenance_window
  copy_tags_to_snapshot    = true
  delete_automated_backups = true

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.name}-final-${random_id.final_snapshot.hex}"

  auto_minor_version_upgrade = var.auto_minor_version_upgrade
  apply_immediately          = var.apply_immediately

  performance_insights_enabled          = var.performance_insights_enabled
  performance_insights_kms_key_id       = var.performance_insights_enabled ? local.kms_key_arn : null
  performance_insights_retention_period = var.performance_insights_enabled ? var.performance_insights_retention_period : null

  monitoring_interval = var.monitoring_interval
  monitoring_role_arn = local.create_monitoring ? aws_iam_role.monitoring[0].arn : null

  enabled_cloudwatch_logs_exports = var.enabled_cloudwatch_logs_exports

  tags = merge(var.tags, { Name = var.name })

  depends_on = [aws_iam_role_policy_attachment.monitoring]
}
