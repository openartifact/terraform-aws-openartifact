# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

output "url" {
  description = "Public URL of the repository (base_url)."
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

output "web_service_name" {
  description = "Name of the web ECS service."
  value       = module.openartifact.web_service_name
}

output "worker_service_name" {
  description = "Name of the worker ECS service."
  value       = module.openartifact.worker_service_name
}

output "bootstrap_admin_password_secret_arn" {
  description = "Secret holding the initial admin password: aws secretsmanager get-secret-value --secret-id <arn> --query SecretString --output text. Used only on an empty instance; change it after the first login."
  value       = module.openartifact.secret_arns["bootstrap_admin_password"]
}

output "web_acl_arn" {
  description = "ARN of the WAFv2 web ACL associated with the ALB."
  value       = aws_wafv2_web_acl.this.arn
}

output "access_log_buckets" {
  description = "Names of the buckets that receive the ALB access logs (alb) and the blob bucket server access logs (s3)."
  value       = { for key, bucket in aws_s3_bucket.access_logs : key => bucket.id }
}

output "kms_key_arns" {
  description = "ARNs of the customer-managed KMS keys: storage, database (from the module), secrets and logs (from this example)."
  value = {
    storage  = module.openartifact.kms_key_arns["storage"]
    database = module.openartifact.kms_key_arns["database"]
    secrets  = aws_kms_key.secrets.arn
    logs     = aws_kms_key.logs.arn
  }
}

output "nat_gateway_public_ips" {
  description = "Source addresses of all outbound traffic of the deployment (one NAT gateway per AZ), useful for upstream allow-lists of proxy repositories."
  value       = module.network.nat_gateway_public_ips
}
