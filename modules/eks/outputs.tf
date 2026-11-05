# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

output "release_name" {
  description = "Name of the Helm release."
  value       = helm_release.openartifact.name
}

output "namespace" {
  description = "Kubernetes namespace of the release."
  value       = var.namespace
}

output "chart_version" {
  description = "Version of the OpenArtifact Helm chart that was deployed."
  value       = helm_release.openartifact.version
}

output "service_account_name" {
  description = "Kubernetes service account the web and worker pods run as; the EKS Pod Identity association binds the IAM role to it."
  value       = local.service_account_name
}

output "url" {
  description = "Public base URL (BASE_URL) configured on the release: base_url, else https://<ingress.host>; null when neither is set. The ALB host name is assigned by the AWS Load Balancer Controller: read it with kubectl get ingress -n <namespace>."
  value       = local.base_url == "" ? null : local.base_url
}

output "pod_identity_role_arn" {
  description = "ARN of the IAM role the pods assume through EKS Pod Identity (S3 blob storage and its KMS key only)."
  value       = aws_iam_role.pod_identity.arn
}

output "pod_identity_role_name" {
  description = "Name of the IAM role the pods assume through EKS Pod Identity."
  value       = aws_iam_role.pod_identity.name
}

output "pod_identity_association_arn" {
  description = "ARN of the EKS Pod Identity association."
  value       = aws_eks_pod_identity_association.this.association_arn
}

output "bucket_name" {
  description = "Name of the S3 bucket that holds the artifact blobs."
  value       = module.storage.bucket_id
}

output "bucket_arn" {
  description = "ARN of the S3 bucket that holds the artifact blobs."
  value       = module.storage.bucket_arn
}

output "kms_key_arns" {
  description = "ARNs of the customer managed KMS keys by purpose: s3 (null with s3_kms_mode = aws_managed) and database."
  value = {
    s3       = module.storage.kms_key_arn
    database = module.database.kms_key_arn
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

output "database_security_group_id" {
  description = "ID of the database security group. Add further ingress rules only through aws_vpc_security_group_ingress_rule."
  value       = module.database.security_group_id
}

output "database_master_secret_arn" {
  description = "ARN of the RDS-managed Secrets Manager secret with the master credentials as JSON {username, password}. RDS rotates it about every 7 days; the pods read the password only at start, so restart them after a rotation (see the README)."
  value       = module.database.master_user_secret_arn
}

output "secret_arns" {
  description = "ARNs of the generated or bring-your-own Secrets Manager secrets by logical name (secret_key, hmac_key, metrics_token, bootstrap_admin_password, bootstrap_admin_token; only the enabled ones). Empty when secret_delivery is existing."
  value       = local.generated_secret_arns
}

output "kubernetes_secret_names" {
  description = "Names of the Kubernetes Secrets the chart reads: app (envFrom: OPENARTIFACT_SECRET_KEY, AUTH_HMAC_KEY, METRICS_AUTH_TOKEN), database (key password) and bootstrap (keys admin-password, admin-token; null when bootstrap_admin_password_enabled is false)."
  value = {
    app       = local.app_secret_name
    database  = local.db_secret_name
    bootstrap = var.bootstrap_admin_password_enabled ? local.bootstrap_secret_name : null
  }
}

output "external_secrets_policy_json" {
  description = "IAM policy (JSON) that lets the External Secrets Operator's identity read the secrets listed above and the RDS-managed database secret, plus kms:Decrypt on their keys. Attach it to the role of the SecretStore. Not attached by this module."
  value       = data.aws_iam_policy_document.external_secrets.json
}
