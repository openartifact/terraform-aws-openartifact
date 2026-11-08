# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: MPL-2.0

variable "name" {
  description = "Name prefix for every resource (IAM role, instance profile, security group, launch template, Auto Scaling groups and capacity providers). Must be 3-24 characters, lowercase letters, digits and hyphens, and must not start with aws, ecs or fargate: ECS reserves those prefixes for capacity provider names."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,22}[a-z0-9]$", var.name))
    error_message = "name must match ^[a-z][a-z0-9-]{1,22}[a-z0-9]$ (3-24 characters, lowercase letters, digits and hyphens)."
  }

  validation {
    condition     = !can(regex("^(aws|ecs|fargate)", var.name))
    error_message = "name must not start with aws, ecs or fargate: ECS reserves these prefixes for capacity provider names."
  }
  nullable = false
}

variable "cluster_name" {
  description = "Name of the ECS cluster the instances join. The module attaches its capacity providers to it (aws_ecs_cluster_capacity_providers), so no other resource may manage the capacity providers of this cluster."
  type        = string
  nullable    = false
}

variable "vpc_id" {
  description = "ID of the VPC the instance security group is created in."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id must look like vpc-0123456789abcdef0."
  }
  nullable = false
}

variable "subnet_ids" {
  description = "IDs of the private subnets the instances run in (at least two, in different Availability Zones, with a NAT gateway or VPC endpoints for ECS, S3, Secrets Manager, CloudWatch Logs and SSM). The instances never get a public IP address."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 1
    error_message = "subnet_ids must contain at least one subnet."
  }
  nullable = false
}

variable "cpu_architecture" {
  description = "CPU architecture of the instances: ARM64 (Graviton, the default) or X86_64. It selects the AMI and the default instance types, and must match the architecture of the tasks and of every entry in instance_types."
  type        = string
  default     = "ARM64"

  validation {
    condition     = contains(["ARM64", "X86_64"], var.cpu_architecture)
    error_message = "cpu_architecture must be ARM64 or X86_64."
  }
  nullable = false
}

variable "instance_types" {
  description = "EC2 instance types of the fleet in order of preference (at most 20), all of the architecture cpu_architecture. Null uses m7g.large and m6g.large for ARM64, m7i.large and m6i.large for X86_64: two 1 vCPU / 2 GiB tasks fill a 2 vCPU / 8 GiB instance. In awsvpc mode every task needs its own network interface (instance types allow 2 to 15; three on the large sizes above, one used by the instance itself), so small types fit few tasks unless ENI trunking is enabled for the account (awsvpcTrunking, only on supported types)."
  type        = list(string)
  default     = null

  validation {
    condition     = var.instance_types == null || (length(coalesce(var.instance_types, [])) >= 1 && length(coalesce(var.instance_types, [])) <= 20)
    error_message = "instance_types must be null or contain between 1 and 20 instance types."
  }

  validation {
    condition     = var.instance_types == null || alltrue([for t in coalesce(var.instance_types, []) : can(regex("^[a-z0-9-]+\\.[a-z0-9]+$", t))])
    error_message = "Every instance_types entry must look like m7g.large."
  }
}

variable "ami_id" {
  description = "ID of the AMI of the instances: an ECS-optimized Amazon Linux 2023 image (or a derivative with the ECS agent and the SSM agent) of the architecture cpu_architecture. Null resolves the recommended ECS-optimized AMI from the public SSM parameter at plan time, which needs ssm:GetParameter on /aws/service/ecs/optimized-ami/*."
  type        = string
  default     = null

  validation {
    condition     = var.ami_id == null || can(regex("^ami-[0-9a-f]+$", coalesce(var.ami_id, "x")))
    error_message = "ami_id must be null or look like ami-0123456789abcdef0."
  }
}

variable "min_size" {
  description = "Minimum number of On-Demand instances. ECS managed scaling raises the group above it when tasks do not fit and lowers it again, never below this value. 0 allows the cluster to scale to zero; a service then waits for its first instance after a deployment."
  type        = number
  default     = 1

  validation {
    condition     = var.min_size >= 0 && floor(var.min_size) == var.min_size && var.min_size <= var.max_size
    error_message = "min_size must be a whole number between 0 and max_size."
  }
  nullable = false
}

variable "max_size" {
  description = "Maximum number of instances of each Auto Scaling group (On-Demand and, when enabled, Spot)."
  type        = number
  default     = 4

  validation {
    condition     = var.max_size >= 1 && floor(var.max_size) == var.max_size
    error_message = "max_size must be a whole number >= 1."
  }
  nullable = false
}

variable "spot_enabled" {
  description = "Create a second Auto Scaling group and capacity provider of Spot instances (starting from zero instances, up to max_size). They only receive the tasks a capacity provider strategy sends to the spot provider; interrupted tasks are drained (ECS_ENABLE_SPOT_INSTANCE_DRAINING) and rescheduled."
  type        = bool
  default     = false
  nullable    = false
}

variable "root_volume_size_gib" {
  description = "Size in GiB of the encrypted gp3 root volume. It holds the OS, the Docker images and the /tmp scratch volume of every task on the instance, so size it for the largest blob you expect times the concurrent transfers of all tasks that share an instance."
  type        = number
  default     = 100

  validation {
    condition     = var.root_volume_size_gib >= 30 && var.root_volume_size_gib <= 16384 && floor(var.root_volume_size_gib) == var.root_volume_size_gib
    error_message = "root_volume_size_gib must be a whole number between 30 (the AMI snapshot size) and 16384."
  }
  nullable = false
}

variable "kms_key_arn" {
  description = "ARN of a customer-managed KMS key for the EBS volumes, or null for the AWS managed key aws/ebs. The volumes are always encrypted. The key policy must allow the Auto Scaling service-linked role (AWSServiceRoleForAutoScaling) to use the key and create grants, otherwise instances fail to launch."
  type        = string
  default     = null

  validation {
    condition     = var.kms_key_arn == null || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:(key|alias)/.+$", coalesce(var.kms_key_arn, "x")))
    error_message = "kms_key_arn must be null or a KMS key or alias ARN (arn:aws:kms:<region>:<account>:key/<id>)."
  }
}

variable "target_capacity" {
  description = "Target utilization in percent of the instances that ECS managed scaling aims for (1-100). 100 packs tasks tightly and keeps no spare instance; lower values keep headroom for faster scale-out and rolling deployments."
  type        = number
  default     = 100

  validation {
    condition     = var.target_capacity >= 1 && var.target_capacity <= 100 && floor(var.target_capacity) == var.target_capacity
    error_message = "target_capacity must be a whole number between 1 and 100."
  }
  nullable = false
}

variable "egress_https_cidr_blocks" {
  description = "IPv4 CIDR blocks the instances may reach on TCP 443: the ECS control plane, ghcr.io (image pulls happen on the instance), CloudWatch Logs, Secrets Manager and SSM. Narrow it only with VPC endpoints and a mirrored image registry."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = alltrue([for cidr in var.egress_https_cidr_blocks : can(cidrnetmask(cidr))])
    error_message = "egress_https_cidr_blocks must contain valid IPv4 CIDR blocks."
  }
  nullable = false
}

variable "egress_https_prefix_list_ids" {
  description = "IDs of the managed prefix lists the instances may reach on TCP 443, for example the S3 gateway endpoint prefix list when egress_https_cidr_blocks is narrowed."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "egress_security_group_rules" {
  description = "Additional egress rules towards other security groups, one per entry, for example the EFS mount target security group on port 2049 (the ECS agent mounts EFS volumes on the instance). Only the list length must be known at plan time."
  type = list(object({
    security_group_id = string
    port              = number
    description       = string
  }))
  default  = []
  nullable = false
}

variable "tags" {
  description = "Tags applied to every resource of the module that supports tags, and propagated to the instances and their volumes."
  type        = map(string)
  default     = {}
  nullable    = false
}
