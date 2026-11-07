# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# The IDs are only handed out once the mount targets and the file system policy exist: an ECS
# service that starts before the mount targets are available fails to mount the volume.

output "file_system_id" {
  description = "ID of the file system. Available once the mount targets and the file system policy exist, so consumers (ECS services) wait for them."
  value       = aws_efs_file_system.this.id

  depends_on = [
    aws_efs_mount_target.this,
    aws_efs_file_system_policy.this,
    aws_efs_backup_policy.this,
    aws_vpc_security_group_ingress_rule.nfs,
  ]
}

output "file_system_arn" {
  description = "ARN of the file system, for IAM policies."
  value       = aws_efs_file_system.this.arn
}

output "access_points" {
  description = "ID and ARN of every access point, keyed like the access_points variable. Available once the mount targets exist."
  value       = { for key, ap in aws_efs_access_point.this : key => { id = ap.id, arn = ap.arn } }

  depends_on = [
    aws_efs_mount_target.this,
    aws_efs_file_system_policy.this,
    aws_vpc_security_group_ingress_rule.nfs,
  ]
}

output "security_group_id" {
  description = "ID of the mount target security group."
  value       = aws_security_group.this.id
}

output "ingress_security_group_ids" {
  description = "IDs of the security groups that may reach the mount targets on NFS (TCP 2049), as granted by the ingress rules. Nothing else can."
  value       = [for rule in aws_vpc_security_group_ingress_rule.nfs : rule.referenced_security_group_id]
}
