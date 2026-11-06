# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

variable "name" {
  description = "Name prefix for the VPC and its resources (lowercase letters, digits and hyphens, 3-24 characters)."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,22}[a-z0-9]$", var.name))
    error_message = "name must match ^[a-z][a-z0-9-]{1,22}[a-z0-9]$ (3-24 characters)."
  }
}

variable "cidr" {
  description = "IPv4 CIDR block of the VPC, a network address with a prefix length between /16 and /22. The first three quarters hold one private subnet per AZ (prefix + 2 bits); the last quarter holds the public subnets (prefix + 4 bits)."
  type        = string
  default     = "10.0.0.0/16"
  nullable    = false

  validation {
    condition = (
      can(cidrhost(var.cidr, 0))
      && can(regex("^[0-9.]+/[0-9]+$", var.cidr))
      && can(tonumber(split("/", var.cidr)[1]))
      && tonumber(try(split("/", var.cidr)[1], "0")) >= 16
      && tonumber(try(split("/", var.cidr)[1], "99")) <= 22
      && try(cidrhost(var.cidr, 0), "") == try(split("/", var.cidr)[0], "-")
    )
    error_message = "cidr must be an IPv4 network address in CIDR notation with a prefix length between /16 and /22, for example 10.0.0.0/16."
  }
}

variable "az_count" {
  description = "Number of availability zones to spread public and private subnets across (2 or 3)."
  type        = number
  default     = 2
  nullable    = false

  validation {
    condition     = contains([2, 3], var.az_count)
    error_message = "az_count must be 2 or 3."
  }
}

variable "nat_gateway_mode" {
  description = "\"single\" shares one NAT gateway (cheaper, but the AZ hosting it is a single point of failure for egress); \"per_az\" creates one NAT gateway per AZ (highly available, one NAT gateway charge per AZ)."
  type        = string
  default     = "single"
  nullable    = false

  validation {
    condition     = contains(["single", "per_az"], var.nat_gateway_mode)
    error_message = "nat_gateway_mode must be \"single\" or \"per_az\"."
  }
}

variable "flow_logs_enabled" {
  description = "Send VPC flow logs (all traffic) to a CloudWatch Logs group."
  type        = bool
  default     = true
  nullable    = false
}

variable "flow_logs_retention_days" {
  description = "Retention in days of the flow log group. Must be a value CloudWatch Logs accepts; 0 (never expire) is not allowed."
  type        = number
  default     = 90
  nullable    = false

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.flow_logs_retention_days)
    error_message = "flow_logs_retention_days must be one of the retention values supported by CloudWatch Logs (1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653)."
  }
}

variable "flow_logs_kms_key_arn" {
  description = "ARN of a KMS key to encrypt the flow log group. The key policy must allow the CloudWatch Logs service principal (logs.<region>.amazonaws.com) to use it. null leaves the log group with the default CloudWatch Logs encryption."
  type        = string
  default     = null

  validation {
    condition     = var.flow_logs_kms_key_arn == null || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/.+$", coalesce(var.flow_logs_kms_key_arn, "x")))
    error_message = "flow_logs_kms_key_arn must be a KMS key ARN."
  }
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
  nullable    = false
}
