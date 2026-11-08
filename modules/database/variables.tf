# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: MPL-2.0

variable "name" {
  description = "Name prefix for every resource of the database (DB instance identifier, subnet group, parameter group, security group, KMS alias). Must be 3-24 characters, lowercase letters, digits and hyphens."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,22}[a-z0-9]$", var.name))
    error_message = "name must match ^[a-z][a-z0-9-]{1,22}[a-z0-9]$ (3-24 characters, lowercase letters, digits and hyphens)."
  }
  nullable = false
}

variable "vpc_id" {
  description = "ID of the VPC the database security group is created in."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id must look like vpc-0123456789abcdef0."
  }
  nullable = false
}

variable "subnet_ids" {
  description = "IDs of the private subnets for the DB subnet group. At least two subnets in different Availability Zones are required by RDS."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "subnet_ids must contain at least two subnets (in different Availability Zones)."
  }
  nullable = false
}

variable "allowed_security_group_ids" {
  description = "IDs of the security groups (for example the ECS tasks or EKS nodes/pods) allowed to reach the database on port 5432. One ingress rule is created per entry."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for id in var.allowed_security_group_ids : can(regex("^sg-[0-9a-f]+$", id))])
    error_message = "Every allowed_security_group_ids entry must look like sg-0123456789abcdef0."
  }
  nullable = false
}

variable "engine_version" {
  description = "PostgreSQL major version. Only the major is passed to RDS, so minor upgrades are picked up automatically while auto_minor_version_upgrade is true. OpenArtifact runs CI against PostgreSQL 18 and its integration harness against 16."
  type        = string
  default     = "17"

  validation {
    condition     = contains(["16", "17", "18"], var.engine_version)
    error_message = "engine_version must be a PostgreSQL major supported by OpenArtifact on RDS: 16, 17 or 18 (major only, no minor)."
  }
  nullable = false
}

variable "instance_class" {
  description = "RDS instance class, for example db.t4g.medium."
  type        = string
  default     = "db.t4g.medium"

  validation {
    condition     = can(regex("^db\\.[a-z0-9-]+\\.[a-z0-9]+$", var.instance_class))
    error_message = "instance_class must look like db.t4g.medium."
  }
  nullable = false
}

variable "allocated_storage" {
  description = "Initial allocated storage in GiB."
  type        = number
  default     = 50

  validation {
    condition     = var.allocated_storage >= 20 && var.allocated_storage <= 65536 && var.allocated_storage == floor(var.allocated_storage)
    error_message = "allocated_storage must be a whole number between 20 and 65536 GiB."
  }
  nullable = false
}

variable "max_allocated_storage" {
  description = "Upper limit in GiB for RDS storage autoscaling. 0 disables autoscaling; otherwise it must be at least allocated_storage."
  type        = number
  default     = 200

  validation {
    condition     = var.max_allocated_storage == 0 || (var.max_allocated_storage >= var.allocated_storage && var.max_allocated_storage <= 65536 && var.max_allocated_storage == floor(var.max_allocated_storage))
    error_message = "max_allocated_storage must be 0 (autoscaling disabled) or a whole number between allocated_storage and 65536 GiB."
  }
  nullable = false
}

variable "storage_type" {
  description = "Storage type of the DB instance. Provisioned-IOPS types are not offered because the module has no iops input."
  type        = string
  default     = "gp3"

  validation {
    condition     = contains(["gp3", "gp2"], var.storage_type)
    error_message = "storage_type must be gp3 or gp2."
  }
  nullable = false
}

variable "multi_az" {
  description = "Deploy a synchronous standby in a second Availability Zone."
  type        = bool
  default     = true
  nullable    = false
}

variable "backup_retention_period" {
  description = "Days to keep automated backups (1-35). Backups cannot be disabled because they also enable point-in-time recovery."
  type        = number
  default     = 14

  validation {
    condition     = var.backup_retention_period >= 1 && var.backup_retention_period <= 35 && var.backup_retention_period == floor(var.backup_retention_period)
    error_message = "backup_retention_period must be a whole number of days between 1 and 35."
  }
  nullable = false
}

variable "backup_window" {
  description = "Daily UTC time range (hh24:mi-hh24:mi) for automated backups. Must not overlap maintenance_window."
  type        = string
  default     = "02:00-03:00"

  validation {
    condition     = can(regex("^([01][0-9]|2[0-3]):[0-5][0-9]-([01][0-9]|2[0-3]):[0-5][0-9]$", var.backup_window))
    error_message = "backup_window must look like 02:00-03:00 (hh24:mi-hh24:mi, UTC)."
  }
  nullable = false
}

variable "maintenance_window" {
  description = "Weekly UTC time range (ddd:hh24:mi-ddd:hh24:mi, lowercase day names) for maintenance. Must not overlap backup_window."
  type        = string
  default     = "sun:04:00-sun:05:00"

  validation {
    condition     = can(regex("^(mon|tue|wed|thu|fri|sat|sun):([01][0-9]|2[0-3]):[0-5][0-9]-(mon|tue|wed|thu|fri|sat|sun):([01][0-9]|2[0-3]):[0-5][0-9]$", var.maintenance_window))
    error_message = "maintenance_window must look like sun:04:00-sun:05:00 (ddd:hh24:mi-ddd:hh24:mi, lowercase day names, UTC)."
  }
  nullable = false
}

variable "deletion_protection" {
  description = "Block deletion of the DB instance through the API. Disable it (and apply) before destroying the database."
  type        = bool
  default     = true
  nullable    = false
}

variable "skip_final_snapshot" {
  description = "Skip the final DB snapshot when the instance is destroyed. Keep false in production so the data survives an accidental destroy."
  type        = bool
  default     = false
  nullable    = false
}

variable "database_name" {
  description = "Name of the initial database created on the instance."
  type        = string
  default     = "openartifact"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9_]{0,62}$", var.database_name))
    error_message = "database_name must start with a letter and contain only letters, digits and underscores (max 63 characters)."
  }
  nullable = false
}

variable "master_username" {
  description = "Master user name. The password is generated and rotated by RDS in Secrets Manager; it never enters Terraform state or configuration."
  type        = string
  default     = "openartifact"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9_]{0,62}$", var.master_username)) && !contains(["postgres", "rdsadmin", "admin"], lower(var.master_username))
    error_message = "master_username must start with a letter, contain only letters, digits and underscores (max 63 characters) and must not be a reserved name (postgres, rdsadmin, admin)."
  }
  nullable = false
}

variable "kms_key_arn" {
  description = "ARN of an existing customer-managed KMS key used for storage, Performance Insights and the master-user secret. null creates a dedicated key with annual rotation. A supplied key must be known at plan time and its key policy must let RDS and Secrets Manager use it (see README)."
  type        = string
  default     = null

  validation {
    condition     = var.kms_key_arn == null || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[0-9a-f-]+$", coalesce(var.kms_key_arn, "x")))
    error_message = "kms_key_arn must be null or a KMS key ARN (arn:aws:kms:<region>:<account>:key/<id>); aliases are not accepted."
  }
}

variable "performance_insights_enabled" {
  description = "Enable Performance Insights, encrypted with the module KMS key. Not supported on the smallest burstable classes (db.t4g.micro, db.t4g.small)."
  type        = bool
  default     = true
  nullable    = false
}

variable "performance_insights_retention_period" {
  description = "Days to retain Performance Insights data: 7, 731, or a multiple of 31 up to 713. Ignored when performance_insights_enabled is false."
  type        = number
  default     = 7

  validation {
    condition     = contains([7, 731], var.performance_insights_retention_period) || (var.performance_insights_retention_period % 31 == 0 && var.performance_insights_retention_period >= 31 && var.performance_insights_retention_period <= 713)
    error_message = "performance_insights_retention_period must be 7, 731 or a multiple of 31 between 31 and 713."
  }
  nullable = false
}

variable "monitoring_interval" {
  description = "Seconds between Enhanced Monitoring samples (0, 1, 5, 10, 15, 30 or 60). 0 disables Enhanced Monitoring; any other value creates the monitoring IAM role."
  type        = number
  default     = 0

  validation {
    condition     = contains([0, 1, 5, 10, 15, 30, 60], var.monitoring_interval)
    error_message = "monitoring_interval must be one of 0, 1, 5, 10, 15, 30 or 60."
  }
  nullable = false
}

variable "auto_minor_version_upgrade" {
  description = "Apply PostgreSQL minor version upgrades automatically during the maintenance window. Required for the major-only engine_version to track minors without a Terraform diff."
  type        = bool
  default     = true
  nullable    = false
}

variable "apply_immediately" {
  description = "Apply modifications immediately instead of in the next maintenance window. Some changes (instance class, Multi-AZ, storage) cause a brief outage when applied immediately."
  type        = bool
  default     = false
  nullable    = false
}

variable "enabled_cloudwatch_logs_exports" {
  description = "Log types exported to CloudWatch Logs."
  type        = list(string)
  default     = ["postgresql", "upgrade"]

  validation {
    condition     = alltrue([for t in var.enabled_cloudwatch_logs_exports : contains(["postgresql", "upgrade", "iam-db-auth-error"], t)])
    error_message = "enabled_cloudwatch_logs_exports entries must be postgresql, upgrade or iam-db-auth-error."
  }
  nullable = false
}

variable "parameters" {
  description = "Extra DB parameter group parameters (name => value), for example log_min_duration_statement = \"1000\". Applied with apply_method pending-reboot so static parameters work too. rds.force_ssl is always 1 and cannot be overridden."
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "ca_cert_identifier" {
  description = "Identifier of the CA certificate for the DB instance server certificate."
  type        = string
  default     = "rds-ca-rsa2048-g1"

  validation {
    condition     = can(regex("^rds-ca-[a-z0-9-]+$", var.ca_cert_identifier))
    error_message = "ca_cert_identifier must look like rds-ca-rsa2048-g1."
  }
  nullable = false
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
  nullable    = false
}
