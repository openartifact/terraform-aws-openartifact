# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

output "url" {
  description = "URL to open in the browser (base_url, or the ALB DNS name when base_url is null)."
  value       = module.openartifact.url
}

output "alb_dns_name" {
  description = "DNS name of the ALB: create a CNAME (or alias record) from your host name to it."
  value       = module.openartifact.alb_dns_name
}

output "alb_zone_id" {
  description = "Route 53 hosted zone ID of the ALB, for alias records."
  value       = module.openartifact.alb_zone_id
}

output "bootstrap_admin_password_secret_arn" {
  description = "Secret holding the initial admin password: aws secretsmanager get-secret-value --secret-id <arn> --query SecretString --output text. Used only on an empty instance; change it after the first login."
  value       = module.openartifact.secret_arns["bootstrap_admin_password"]
}

output "nat_gateway_public_ips" {
  description = "Source addresses of all outbound traffic of the deployment, useful for upstream allow-lists of proxy repositories."
  value       = module.network.nat_gateway_public_ips
}

output "ecs_capacity_provider_names" {
  description = "Capacity providers of the container instances (on_demand, spot)."
  value       = module.openartifact.ecs_capacity_provider_names
}

output "ecs_autoscaling_group_names" {
  description = "Auto Scaling groups of the container instances. Shell access to an instance: Session Manager (aws ssm start-session), there is no SSH."
  value       = module.openartifact.ecs_autoscaling_group_names
}

output "efs_file_system_id" {
  description = "ID of the EFS file system holding the scanner cache and the backups."
  value       = module.openartifact.efs_file_system_id
}
