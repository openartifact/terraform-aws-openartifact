# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

output "secret_key_arn" {
  description = "ARN of the secret holding OPENARTIFACT_SECRET_KEY."
  value       = local.arns["secret_key"]
}

output "hmac_key_arn" {
  description = "ARN of the secret holding AUTH_HMAC_KEY."
  value       = local.arns["hmac_key"]
}

output "metrics_token_arn" {
  description = "ARN of the secret holding METRICS_AUTH_TOKEN; null when metrics_token_enabled is false."
  value       = lookup(local.arns, "metrics_token", null)
}

output "bootstrap_admin_password_arn" {
  description = "ARN of the secret holding the initial admin password; null when bootstrap_admin_password_enabled is false."
  value       = lookup(local.arns, "bootstrap_admin_password", null)
}

output "bootstrap_admin_token_arn" {
  description = "ARN of the secret holding the initial admin API token; null when bootstrap_admin_token_enabled is false."
  value       = lookup(local.arns, "bootstrap_admin_token", null)
}

output "secret_arns" {
  description = "ARNs of all enabled secrets (created or bring-your-own), for scoping IAM secretsmanager:GetSecretValue permissions."
  value       = values(local.arns)
}

output "secret_arns_by_env" {
  description = "Environment variable name to secret ARN, for the enabled secrets that map to an environment variable (OPENARTIFACT_SECRET_KEY, AUTH_HMAC_KEY, METRICS_AUTH_TOKEN, OPENARTIFACT_BOOTSTRAP_ADMIN_PASSWORD). The bootstrap admin token is excluded: the server only reads it from a file."
  value = {
    for k, v in local.enabled : v.env_name => local.arns[k]
    if k != "bootstrap_admin_token"
  }
}
