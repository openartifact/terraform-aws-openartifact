# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

output "url" {
  description = "URL of the repository (https://<ingress_host>). The host name must point at the ALB: kubectl get ingress -n <namespace>."
  value       = module.openartifact.url
}

output "namespace" {
  description = "Kubernetes namespace of the release."
  value       = module.openartifact.namespace
}

output "bucket_name" {
  description = "S3 bucket with the artifact blobs."
  value       = module.openartifact.bucket_name
}

output "pod_identity_role_arn" {
  description = "IAM role the pods assume through EKS Pod Identity."
  value       = module.openartifact.pod_identity_role_arn
}

output "external_secrets_policy_json" {
  description = "IAM policy for the identity of the External Secrets Operator's ClusterSecretStore: it lets the operator read the OpenArtifact secrets. Attach it to the operator's role (not done by this example)."
  value       = module.openartifact.external_secrets_policy_json
}

output "bootstrap_admin_password_secret_arn" {
  description = "Secret holding the initial admin password: aws secretsmanager get-secret-value --secret-id <arn> --query SecretString --output text. Used only on an empty instance; change it after the first login."
  value       = module.openartifact.secret_arns["bootstrap_admin_password"]
}
