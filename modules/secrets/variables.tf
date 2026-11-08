# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: MPL-2.0

variable "name" {
  description = "Name prefix for the secrets (\"<name>/secret-key\", \"<name>/hmac-key\", ...). Lowercase letters, digits and hyphens, 3-24 characters."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,22}[a-z0-9]$", var.name))
    error_message = "name must match ^[a-z][a-z0-9-]{1,22}[a-z0-9]$ (3-24 characters)."
  }
}

variable "kms_key_arn" {
  description = "ARN of the customer managed KMS key that encrypts the secrets. null uses the AWS managed aws/secretsmanager key. A customer managed key must allow the workload's execution role kms:Decrypt."
  type        = string
  default     = null

  validation {
    condition     = var.kms_key_arn == null || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:(key|alias)/.+$", coalesce(var.kms_key_arn, "x")))
    error_message = "kms_key_arn must be a KMS key or alias ARN."
  }
}

variable "recovery_window_in_days" {
  description = "Days Secrets Manager keeps a deleted secret recoverable (7-30), or 0 to delete immediately without recovery. Keep the default: an accidentally deleted OPENARTIFACT_SECRET_KEY can only be restored inside this window."
  type        = number
  default     = 30
  nullable    = false

  validation {
    condition     = var.recovery_window_in_days == 0 || (var.recovery_window_in_days >= 7 && var.recovery_window_in_days <= 30 && floor(var.recovery_window_in_days) == var.recovery_window_in_days)
    error_message = "recovery_window_in_days must be 0 or a whole number between 7 and 30."
  }
}

variable "secret_version" {
  description = "Rotation counter for the generated metrics token, HMAC key, bootstrap admin password and bootstrap admin token: bump it to generate and store new values (secret_string_wo_version). It deliberately does NOT affect the OPENARTIFACT_SECRET_KEY secret, because replacing that key makes every credential OpenArtifact stored with it (GPG/APK/Nix/attestation signing keys, SAML key, stored upstream credentials) permanently unreadable. Rotate that one only on purpose, see the README."
  type        = number
  default     = 1
  nullable    = false

  validation {
    condition     = var.secret_version >= 1 && floor(var.secret_version) == var.secret_version
    error_message = "secret_version must be a whole number >= 1."
  }
}

variable "existing_secret_arns" {
  description = "Bring-your-own secrets. Every attribute that is set is used as-is (its ARN is passed through to the outputs) and NO secret is created or generated for it. The secret value must be the plain string the matching environment variable expects (not a JSON document)."
  type = object({
    secret_key               = optional(string)
    hmac_key                 = optional(string)
    metrics_token            = optional(string)
    bootstrap_admin_password = optional(string)
    bootstrap_admin_token    = optional(string)
  })
  default  = {}
  nullable = false

  validation {
    condition = alltrue([
      for arn in values(var.existing_secret_arns) :
      arn == null || can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:.+$", arn))
    ])
    error_message = "Every existing_secret_arns entry must be a Secrets Manager secret ARN."
  }
}

variable "metrics_token_enabled" {
  description = "Provide a bearer token (METRICS_AUTH_TOKEN) protecting the /metrics endpoint."
  type        = bool
  default     = true
  nullable    = false
}

variable "bootstrap_admin_password_enabled" {
  description = "Provide the initial admin password (OPENARTIFACT_BOOTSTRAP_ADMIN_PASSWORD)."
  type        = bool
  default     = true
  nullable    = false
}

variable "bootstrap_admin_token_enabled" {
  description = "Provide an initial admin API token. The server only reads it from a file (OPENARTIFACT_BOOTSTRAP_ADMIN_TOKEN_FILE), so it is usable on Kubernetes (mounted secret) but not on ECS Fargate."
  type        = bool
  default     = false
  nullable    = false
}

variable "tags" {
  description = "Tags applied to every secret."
  type        = map(string)
  default     = {}
  nullable    = false
}
