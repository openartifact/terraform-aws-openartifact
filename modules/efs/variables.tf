# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

variable "name" {
  description = "Name prefix for every resource of the file system (Name tags, security group). Must be 3-24 characters, lowercase letters, digits and hyphens."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,22}[a-z0-9]$", var.name))
    error_message = "name must match ^[a-z][a-z0-9-]{1,22}[a-z0-9]$ (3-24 characters, lowercase letters, digits and hyphens)."
  }
  nullable = false
}

variable "vpc_id" {
  description = "ID of the VPC the mount target security group is created in."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id must look like vpc-0123456789abcdef0."
  }
  nullable = false
}

variable "subnet_ids" {
  description = "IDs of the private subnets that get a mount target, one per Availability Zone (EFS allows one mount target per zone). Only the list length must be known at plan time."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 1
    error_message = "subnet_ids must contain at least one subnet."
  }
  nullable = false
}

variable "allowed_security_group_ids" {
  description = "IDs of the security groups allowed to reach the mount targets on TCP 2049 (the ECS task security groups, and the container instance security group when the tasks run on EC2: there the ECS agent mounts the file system on the instance). One ingress rule is created per entry; only the list length must be known at plan time."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "kms_key_arn" {
  description = "ARN (or alias ARN) of a customer-managed KMS key that encrypts the file system, or null for the AWS managed key aws/elasticfilesystem. The file system is always encrypted. The key policy must allow the principals that create and mount the file system to use the key through Amazon EFS (condition kms:ViaService = elasticfilesystem.<region>.amazonaws.com)."
  type        = string
  default     = null

  validation {
    condition     = var.kms_key_arn == null || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:(key|alias)/.+$", coalesce(var.kms_key_arn, "x")))
    error_message = "kms_key_arn must be null or a KMS key or alias ARN (arn:aws:kms:<region>:<account>:key/<id>)."
  }
}

variable "performance_mode" {
  description = "EFS performance mode: generalPurpose (the default, required for elastic throughput) or maxIO (legacy, higher latency, only with bursting or provisioned throughput). Cannot be changed after creation."
  type        = string
  default     = "generalPurpose"

  validation {
    condition     = contains(["generalPurpose", "maxIO"], var.performance_mode)
    error_message = "performance_mode must be generalPurpose or maxIO."
  }
  nullable = false
}

variable "throughput_mode" {
  description = "EFS throughput mode: elastic (the default: scales with the workload, pay per use), bursting or provisioned (set provisioned_throughput_in_mibps)."
  type        = string
  default     = "elastic"

  validation {
    condition     = contains(["elastic", "bursting", "provisioned"], var.throughput_mode)
    error_message = "throughput_mode must be elastic, bursting or provisioned."
  }

  validation {
    condition     = var.throughput_mode != "elastic" || var.performance_mode == "generalPurpose"
    error_message = "throughput_mode elastic requires performance_mode generalPurpose."
  }
  nullable = false
}

variable "provisioned_throughput_in_mibps" {
  description = "Provisioned throughput in MiB/s. Required when throughput_mode is provisioned, and rejected otherwise."
  type        = number
  default     = null

  validation {
    condition     = (var.throughput_mode == "provisioned") == (var.provisioned_throughput_in_mibps != null)
    error_message = "provisioned_throughput_in_mibps must be set when throughput_mode is provisioned and null otherwise."
  }

  validation {
    condition     = var.provisioned_throughput_in_mibps == null || coalesce(var.provisioned_throughput_in_mibps, 0) >= 1
    error_message = "provisioned_throughput_in_mibps must be at least 1."
  }
}

variable "transition_to_ia" {
  description = "Move files not accessed for this long to the Infrequent Access storage class: AFTER_1_DAY, AFTER_7_DAYS, AFTER_14_DAYS, AFTER_30_DAYS, AFTER_60_DAYS, AFTER_90_DAYS, AFTER_180_DAYS, AFTER_270_DAYS or AFTER_365_DAYS. Files return to Standard on their first access. Null keeps everything in Standard storage."
  type        = string
  default     = null

  validation {
    condition = var.transition_to_ia == null || contains([
      "AFTER_1_DAY", "AFTER_7_DAYS", "AFTER_14_DAYS", "AFTER_30_DAYS", "AFTER_60_DAYS",
      "AFTER_90_DAYS", "AFTER_180_DAYS", "AFTER_270_DAYS", "AFTER_365_DAYS",
    ], coalesce(var.transition_to_ia, "none"))
    error_message = "transition_to_ia must be null or one of AFTER_1_DAY, AFTER_7_DAYS, AFTER_14_DAYS, AFTER_30_DAYS, AFTER_60_DAYS, AFTER_90_DAYS, AFTER_180_DAYS, AFTER_270_DAYS, AFTER_365_DAYS."
  }
}

variable "backup_policy_enabled" {
  description = "Enable the EFS automatic backup policy (daily backups by AWS Backup, 35 days retention, no backup plan to manage). Costs per GB-month of backup storage."
  type        = bool
  default     = true
  nullable    = false
}

variable "access_points" {
  description = "Access points to create, keyed by a short name (used in Name tags and as the key of the access_points output). Each enforces the POSIX identity uid:gid for every request and roots the client at path, which is created with the given owner and permissions when missing. The defaults match the OpenArtifact image user (10001:10001) and a 0750 directory."
  type = map(object({
    path        = string
    uid         = optional(number, 10001)
    gid         = optional(number, 10001)
    permissions = optional(string, "0750")
  }))
  default = {}

  validation {
    condition     = alltrue([for ap in values(var.access_points) : startswith(ap.path, "/") && ap.path != "/"])
    error_message = "Every access point path must be an absolute directory below the file system root (for example /backups); a path of / is not allowed."
  }

  validation {
    condition     = alltrue([for ap in values(var.access_points) : can(regex("^[0-7]{3,4}$", ap.permissions))])
    error_message = "Every access point permissions value must be an octal mode such as 0750."
  }
  nullable = false
}

variable "tags" {
  description = "Tags applied to every resource of the module that supports tags."
  type        = map(string)
  default     = {}
  nullable    = false
}
