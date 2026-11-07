# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# ---------------------------------------------------------------------------
# File system: encrypted at rest, automatic backups, optional IA tiering
# ---------------------------------------------------------------------------

resource "aws_efs_file_system" "this" {
  #checkov:skip=CKV2_AWS_18: Backups use the EFS automatic backup policy (aws_efs_backup_policy, AWS Backup managed by EFS) controlled by backup_policy_enabled, not a caller-owned backup plan; the check only recognises aws_backup_selection.
  encrypted        = true
  kms_key_id       = var.kms_key_arn
  performance_mode = var.performance_mode
  throughput_mode  = var.throughput_mode

  provisioned_throughput_in_mibps = var.throughput_mode == "provisioned" ? var.provisioned_throughput_in_mibps : null

  dynamic "lifecycle_policy" {
    for_each = var.transition_to_ia != null ? [var.transition_to_ia] : []

    content {
      transition_to_ia = lifecycle_policy.value
    }
  }

  # Files read again after tiering move back to Standard storage instead of paying IA read fees.
  dynamic "lifecycle_policy" {
    for_each = var.transition_to_ia != null ? ["AFTER_1_ACCESS"] : []

    content {
      transition_to_primary_storage_class = lifecycle_policy.value
    }
  }

  tags = merge(var.tags, { Name = var.name })
}

resource "aws_efs_backup_policy" "this" {
  file_system_id = aws_efs_file_system.this.id

  backup_policy {
    status = var.backup_policy_enabled ? "ENABLED" : "DISABLED"
  }
}

# The policy only denies; access is granted by the identity policy of the task role (ECS volumes
# with IAM authorization). Deny statements are evaluated before any allow.
resource "aws_efs_file_system_policy" "this" {
  file_system_id = aws_efs_file_system.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyUnencryptedTransport"
        Effect    = "Deny"
        Principal = { AWS = "*" }
        Action    = "*"
        Resource  = aws_efs_file_system.this.arn
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "DenyClientAccessWithoutAccessPoint"
        Effect    = "Deny"
        Principal = { AWS = "*" }
        Action = [
          "elasticfilesystem:ClientMount",
          "elasticfilesystem:ClientWrite",
          "elasticfilesystem:ClientRootAccess",
        ]
        Resource  = aws_efs_file_system.this.arn
        Condition = { Null = { "elasticfilesystem:AccessPointArn" = "true" } }
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Access points: one per use, fixed POSIX identity
# ---------------------------------------------------------------------------

resource "aws_efs_access_point" "this" {
  for_each = var.access_points

  file_system_id = aws_efs_file_system.this.id

  posix_user {
    uid = each.value.uid
    gid = each.value.gid
  }

  root_directory {
    path = each.value.path

    creation_info {
      owner_uid   = each.value.uid
      owner_gid   = each.value.gid
      permissions = each.value.permissions
    }
  }

  tags = merge(var.tags, { Name = "${var.name}-${each.key}" })
}

# ---------------------------------------------------------------------------
# Network access: mount targets in every subnet, NFS only from allowed security groups
# ---------------------------------------------------------------------------

resource "aws_security_group" "this" {
  name_prefix = "${var.name}-efs-"
  description = "OpenArtifact ${var.name} EFS: NFS from allowed security groups only"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-efs" })

  lifecycle {
    create_before_destroy = true
  }
}

# The security group IDs may only be known after apply: the rules are counted by list length.
resource "aws_vpc_security_group_ingress_rule" "nfs" {
  count = length(var.allowed_security_group_ids)

  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = var.allowed_security_group_ids[count.index]
  description                  = "NFS from allowed security group"
  ip_protocol                  = "tcp"
  from_port                    = 2049
  to_port                      = 2049

  tags = merge(var.tags, { Name = "${var.name}-efs-ingress-${count.index}" })
}

# One mount target per Availability Zone: subnet_ids must be in different zones. The count is the
# list length because the subnet IDs may only be known after apply.
resource "aws_efs_mount_target" "this" {
  count = length(var.subnet_ids)

  file_system_id  = aws_efs_file_system.this.id
  subnet_id       = var.subnet_ids[count.index]
  security_groups = [aws_security_group.this.id]
}
