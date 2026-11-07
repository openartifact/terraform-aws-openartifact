# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

output "url" {
  description = "Public URL of the repository: base_url when set, otherwise https://<ALB DNS name> (the certificate must cover that name for clients to connect without errors)."
  value       = var.base_url != null ? var.base_url : "https://${aws_lb.this.dns_name}"
}

output "alb_dns_name" {
  description = "DNS name of the ALB. Point your DNS record (CNAME, or an alias to alb_dns_name and alb_zone_id) at it."
  value       = aws_lb.this.dns_name
}

output "alb_zone_id" {
  description = "Route 53 hosted zone ID of the ALB, for alias records."
  value       = aws_lb.this.zone_id
}

output "alb_arn" {
  description = "ARN of the ALB."
  value       = aws_lb.this.arn
}

output "alb_arn_suffix" {
  description = "ARN suffix of the ALB (app/<name>/<id>), the dimension value of its CloudWatch metrics."
  value       = aws_lb.this.arn_suffix
}

output "bucket_name" {
  description = "Name of the S3 blob bucket."
  value       = module.storage.bucket_id
}

output "bucket_arn" {
  description = "ARN of the S3 blob bucket."
  value       = module.storage.bucket_arn
}

output "kms_key_arns" {
  description = "ARNs of the customer-managed KMS keys by purpose: storage (null with s3_kms_mode = \"aws_managed\"), database, secrets (the key you supplied, null for the AWS managed key) and logs (the key you supplied, null for the default encryption)."
  value = {
    storage  = module.storage.kms_key_arn
    database = module.database.kms_key_arn
    secrets  = var.secrets_kms_key_arn
    logs     = var.log_kms_key_arn
  }
}

output "database_endpoint" {
  description = "DNS address of the RDS instance (host name only)."
  value       = module.database.endpoint
}

output "database_port" {
  description = "Port of the RDS instance."
  value       = module.database.port
}

output "database_master_secret_arn" {
  description = "ARN of the RDS-managed Secrets Manager secret with the master credentials as JSON {username, password}. RDS rotates the password about every 7 days."
  value       = module.database.master_user_secret_arn
}

output "secret_arns" {
  description = "ARNs of the application secrets by logical name (null when disabled): secret_key, hmac_key, metrics_token, bootstrap_admin_password, plus database_master (the RDS-managed master secret). Read the bootstrap admin password with `aws secretsmanager get-secret-value`."
  value = {
    secret_key               = module.secrets.secret_key_arn
    hmac_key                 = module.secrets.hmac_key_arn
    metrics_token            = module.secrets.metrics_token_arn
    bootstrap_admin_password = module.secrets.bootstrap_admin_password_arn
    database_master          = module.database.master_user_secret_arn
  }
}

output "cluster_name" {
  description = "Name of the ECS cluster."
  value       = aws_ecs_cluster.this.name
}

output "cluster_arn" {
  description = "ARN of the ECS cluster."
  value       = aws_ecs_cluster.this.arn
}

output "web_service_name" {
  description = "Name of the web ECS service (role \"web\" with a worker, otherwise \"all\")."
  value       = module.web.service_name
}

output "worker_service_name" {
  description = "Name of the worker ECS service, or null when worker_enabled is false."
  value       = one(module.worker[*].service_name)
}

output "log_group_names" {
  description = "Names of the CloudWatch log groups by service (web, worker); worker is null when worker_enabled is false."
  value = {
    web    = module.web.log_group_name
    worker = one(module.worker[*].log_group_name)
  }
}

output "security_group_ids" {
  description = "IDs of the security groups by component: alb, web, worker (null when worker_enabled is false) and database."
  value = {
    alb      = aws_security_group.alb.id
    web      = module.web.security_group_id
    worker   = one(module.worker[*].security_group_id)
    database = module.database.security_group_id
  }
}

output "task_role_arns" {
  description = "ARNs of the ECS task roles by service (web, worker); worker is null when worker_enabled is false. Each holds only the S3 and KMS access to the blob bucket."
  value = {
    web    = module.web.task_role_arn
    worker = one(module.worker[*].task_role_arn)
  }
}

output "execution_role_arns" {
  description = "ARNs of the ECS task execution roles by service (web, worker); worker is null when worker_enabled is false."
  value = {
    web    = module.web.execution_role_arn
    worker = one(module.worker[*].execution_role_arn)
  }
}

output "capacity_type" {
  description = "Where the ECS tasks run: FARGATE or EC2."
  value       = var.capacity_type
}

output "ecs_capacity_provider_names" {
  description = "Names of the ECS capacity providers (on_demand, spot) when capacity_type is EC2, otherwise null. spot is null unless ec2_capacity.spot_percentage.web is above 0."
  value       = one(module.ec2_capacity[*].capacity_provider_names)
}

output "ecs_autoscaling_group_names" {
  description = "Names of the Auto Scaling groups of the container instances (on_demand, spot) when capacity_type is EC2, otherwise null."
  value       = one(module.ec2_capacity[*].autoscaling_group_names)
}

output "ecs_instance_role_arn" {
  description = "ARN of the container instance role when capacity_type is EC2, otherwise null. It carries only the AWS managed ECS agent and SSM policies; tasks do not use it."
  value       = one(module.ec2_capacity[*].instance_role_arn)
}

output "ecs_instance_security_group_id" {
  description = "ID of the container instance security group when capacity_type is EC2, otherwise null."
  value       = one(module.ec2_capacity[*].security_group_id)
}

output "efs_file_system_id" {
  description = "ID of the EFS file system, or null unless persistent_volume.enabled."
  value       = one(module.efs[*].file_system_id)
}

output "efs_access_point_arns" {
  description = "ARNs of the EFS access points by use (scanner_cache, backups), or null unless persistent_volume.enabled."
  value       = one([for efs in module.efs : { for key, ap in efs.access_points : key => ap.arn }])
}

output "efs_security_group_id" {
  description = "ID of the EFS mount target security group, or null unless persistent_volume.enabled."
  value       = one(module.efs[*].security_group_id)
}
