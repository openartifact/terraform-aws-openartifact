# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

variable "name" {
  description = "Name prefix for the bucket, KMS alias and tags (lowercase letters, digits and hyphens, 3-24 characters)."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,22}[a-z0-9]$", var.name))
    error_message = "name must match ^[a-z][a-z0-9-]{1,22}[a-z0-9]$ (3-24 characters)."
  }
}

variable "bucket_name" {
  description = "Explicit S3 bucket name. When null the bucket is named \"<name>-blobs-<account_id>-<region>\"."
  type        = string
  default     = null

  validation {
    condition     = var.bucket_name == null || can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", coalesce(var.bucket_name, "x")))
    error_message = "bucket_name must be 3-63 characters of lowercase letters, digits, dots and hyphens, starting and ending with a letter or digit."
  }
}

variable "kms_mode" {
  description = "Server-side encryption key: \"cmk\" creates a dedicated customer managed KMS key (rotation on, recommended); \"aws_managed\" uses the AWS managed aws/s3 key (no key to manage, but no key-policy control or per-key audit trail)."
  type        = string
  default     = "cmk"
  nullable    = false

  validation {
    condition     = contains(["cmk", "aws_managed"], var.kms_mode)
    error_message = "kms_mode must be \"cmk\" or \"aws_managed\"."
  }
}

variable "kms_key_deletion_window_days" {
  description = "Waiting period in days before the dedicated KMS key is deleted after destroy (7-30). Only used when kms_mode is \"cmk\"."
  type        = number
  default     = 30
  nullable    = false

  validation {
    condition     = var.kms_key_deletion_window_days >= 7 && var.kms_key_deletion_window_days <= 30 && floor(var.kms_key_deletion_window_days) == var.kms_key_deletion_window_days
    error_message = "kms_key_deletion_window_days must be a whole number between 7 and 30."
  }
}

variable "versioning_enabled" {
  description = "Keep previous object versions. Recommended: it protects blobs against accidental or malicious deletes. When false, versioning is set to Suspended (S3 cannot return to the never-versioned state)."
  type        = bool
  default     = true
  nullable    = false
}

variable "noncurrent_version_expiration_days" {
  description = "Days after which noncurrent object versions are permanently deleted. Only used when versioning_enabled is true."
  type        = number
  default     = 30
  nullable    = false

  validation {
    condition     = var.noncurrent_version_expiration_days >= 1 && floor(var.noncurrent_version_expiration_days) == var.noncurrent_version_expiration_days
    error_message = "noncurrent_version_expiration_days must be a whole number >= 1."
  }
}

variable "abort_incomplete_multipart_days" {
  description = "Days after which incomplete multipart uploads are aborted and their parts deleted."
  type        = number
  default     = 7
  nullable    = false

  validation {
    condition     = var.abort_incomplete_multipart_days >= 1 && floor(var.abort_incomplete_multipart_days) == var.abort_incomplete_multipart_days
    error_message = "abort_incomplete_multipart_days must be a whole number >= 1."
  }
}

variable "access_logging" {
  description = "S3 server access logging. Set target_bucket to an existing bucket that grants the S3 logging service principal (logging.s3.amazonaws.com) PutObject; null disables access logging."
  type = object({
    target_bucket = string
    target_prefix = optional(string, "s3/")
  })
  default = null

  validation {
    condition     = var.access_logging == null || length(try(var.access_logging.target_bucket, "")) > 0
    error_message = "access_logging.target_bucket must not be empty."
  }
}

variable "force_destroy" {
  description = "Delete the bucket with all objects (and versions) on destroy. Leave false in production: the bucket holds every stored artifact."
  type        = bool
  default     = false
  nullable    = false
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
  nullable    = false
}
