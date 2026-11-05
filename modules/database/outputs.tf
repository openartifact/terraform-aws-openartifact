# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

output "endpoint" {
  description = "DNS address of the DB instance (host name only, without the port)."
  value       = aws_db_instance.this.address
}

output "port" {
  description = "Port the database listens on."
  value       = aws_db_instance.this.port
}

output "database_name" {
  description = "Name of the initial database."
  value       = aws_db_instance.this.db_name
}

output "master_username" {
  description = "Master user name."
  value       = aws_db_instance.this.username
}

output "master_user_secret_arn" {
  description = "ARN of the RDS-managed Secrets Manager secret holding the master credentials as JSON {username, password}. RDS rotates the password about every 7 days: consumers that read it only at start must be redeployed after rotation."
  value       = one(aws_db_instance.this.master_user_secret[*].secret_arn)
}

output "kms_key_arn" {
  description = "ARN of the KMS key encrypting the storage, Performance Insights and the master-user secret (the module-created key or var.kms_key_arn)."
  value       = local.kms_key_arn
}

output "security_group_id" {
  description = "ID of the database security group. Add further ingress rules to it only through aws_vpc_security_group_ingress_rule."
  value       = aws_security_group.database.id
}

output "instance_arn" {
  description = "ARN of the DB instance."
  value       = aws_db_instance.this.arn
}

output "instance_id" {
  description = "Identifier of the DB instance."
  value       = aws_db_instance.this.identifier
}
