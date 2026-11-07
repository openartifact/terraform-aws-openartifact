# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

variable "name" {
  description = "Name of the ECS service and task definition family, and the prefix of every resource created by this module (IAM roles, security group, log group). Must be 3-24 characters, lowercase letters, digits and hyphens. Must be unique per cluster; IAM roles use a name prefix so the same name may be reused in another region."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,22}[a-z0-9]$", var.name))
    error_message = "name must match ^[a-z][a-z0-9-]{1,22}[a-z0-9]$ (3-24 characters, lowercase letters, digits and hyphens)."
  }
  nullable = false
}

variable "cluster_arn" {
  description = "ARN of the ECS cluster the service runs in."
  type        = string
  nullable    = false
}

variable "cluster_name" {
  description = "Name of the ECS cluster the service runs in. Used for the Application Auto Scaling resource ID (service/<cluster_name>/<service name>)."
  type        = string
  nullable    = false
}

variable "vpc_id" {
  description = "ID of the VPC the task security group is created in."
  type        = string
  nullable    = false
}

variable "subnet_ids" {
  description = "IDs of the subnets the tasks run in (private subnets with a NAT gateway or the VPC endpoints for ECR/S3/Secrets Manager/CloudWatch Logs, unless assign_public_ip is set)."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 1
    error_message = "subnet_ids must contain at least one subnet."
  }
  nullable = false
}

variable "assign_public_ip" {
  description = "Whether the tasks get a public IPv4 address. Keep false and place the tasks in private subnets; only enable it for Fargate tasks in public subnets without a NAT gateway. Must be false with capacity_provider_strategy: tasks on EC2 instances cannot get a public address."
  type        = bool
  default     = false

  validation {
    condition     = !var.assign_public_ip || length(var.capacity_provider_strategy) == 0
    error_message = "assign_public_ip must be false when capacity_provider_strategy is set: tasks on EC2 container instances cannot get a public IP address."
  }
  nullable = false
}

variable "image" {
  description = "Full container image reference including the tag or digest, for example ghcr.io/openartifact/openartifact:0.19.2 or ghcr.io/openartifact/openartifact@sha256:<64 hex>. A digest is passed through unchanged. The image must be multi-arch or match cpu_architecture."
  type        = string

  validation {
    condition     = length(trimspace(var.image)) > 0 && !can(regex("\\s", var.image))
    error_message = "image must be a non-empty image reference without whitespace."
  }
  nullable = false
}

variable "role" {
  description = "Process role of the OpenArtifact server, injected as OPENARTIFACT_ROLE: \"all\" (HTTP API and background jobs), \"web\" (HTTP API only) or \"worker\" (background jobs only, no load balancer)."
  type        = string
  default     = "all"

  validation {
    condition     = contains(["all", "web", "worker"], var.role)
    error_message = "role must be one of: all, web, worker."
  }
  nullable = false
}

variable "cpu_architecture" {
  description = "CPU architecture of the tasks: ARM64 (cheaper, the default) or X86_64. The OpenArtifact image is published for both. With capacity_provider_strategy the container instances must have the same architecture."
  type        = string
  default     = "ARM64"

  validation {
    condition     = contains(["ARM64", "X86_64"], var.cpu_architecture)
    error_message = "cpu_architecture must be ARM64 or X86_64."
  }
  nullable = false
}

variable "cpu" {
  description = "Task CPU units: 256, 512, 1024, 2048, 4096, 8192 or 16384. Must form a valid Fargate combination with memory."
  type        = number
  default     = 1024

  validation {
    condition     = contains([256, 512, 1024, 2048, 4096, 8192, 16384], var.cpu)
    error_message = "cpu must be one of 256, 512, 1024, 2048, 4096, 8192 or 16384."
  }
  nullable = false
}

variable "memory" {
  description = "Task memory in MiB. Must be a valid Fargate combination with cpu: 256 CPU 512/1024/2048; 512 CPU 1024-4096 step 1024; 1024 CPU 2048-8192 step 1024; 2048 CPU 4096-16384 step 1024; 4096 CPU 8192-30720 step 1024; 8192 CPU 16384-61440 step 4096; 16384 CPU 32768-122880 step 8192."
  type        = number
  default     = 2048

  validation {
    condition = contains(lookup({
      "256"   = [512, 1024, 2048]
      "512"   = range(1024, 4097, 1024)
      "1024"  = range(2048, 8193, 1024)
      "2048"  = range(4096, 16385, 1024)
      "4096"  = range(8192, 30721, 1024)
      "8192"  = range(16384, 61441, 4096)
      "16384" = range(32768, 122881, 8192)
    }, tostring(var.cpu), []), var.memory)
    error_message = "cpu and memory do not form a valid Fargate combination (256: 512/1024/2048; 512: 1024-4096; 1024: 2048-8192; 2048: 4096-16384; 4096: 8192-30720; 8192: 16384-61440 step 4096; 16384: 32768-122880 step 8192)."
  }
  nullable = false
}

variable "ephemeral_storage_gib" {
  description = "Size of the task ephemeral storage in GiB (21-200; Fargate includes 20 GiB); ignored with capacity_provider_strategy, where /tmp is a Docker volume on the container instance disk. The volume holds the writable /tmp where OpenArtifact spools uploads and downloads before they are sent to S3, so size it for the largest blob you expect to proxy or upload."
  type        = number
  default     = 21

  validation {
    condition     = var.ephemeral_storage_gib >= 21 && var.ephemeral_storage_gib <= 200 && floor(var.ephemeral_storage_gib) == var.ephemeral_storage_gib
    error_message = "ephemeral_storage_gib must be a whole number between 21 and 200."
  }
  nullable = false
}

variable "capacity_provider_strategy" {
  description = "ECS capacity providers the service places its tasks with (EC2 container instances, for example from modules/ecs-ec2-capacity or the root module). Empty (the default) runs the tasks on Fargate. With a strategy the task definition is EC2-only: the same CPU/memory combinations apply, ephemeral_storage_gib is ignored, /tmp becomes a task-scoped Docker volume on the instance disk, and the network mode stays awsvpc. weight is the relative share of tasks (0 sends none beyond base), base the number of tasks that always run on the provider; only one provider may set a base."
  type = list(object({
    capacity_provider = string
    weight            = optional(number, 1)
    base              = optional(number, 0)
  }))
  default = []

  validation {
    condition     = alltrue([for s in var.capacity_provider_strategy : s.weight >= 0 && s.weight <= 1000 && floor(s.weight) == s.weight && s.base >= 0 && s.base <= 100000 && floor(s.base) == s.base])
    error_message = "Every capacity_provider_strategy weight must be a whole number between 0 and 1000 and every base a whole number between 0 and 100000."
  }

  validation {
    condition     = length([for s in var.capacity_provider_strategy : s if s.base > 0]) <= 1
    error_message = "Only one capacity_provider_strategy entry may set a base."
  }

  validation {
    # sum([]) is an error and || does not short-circuit before Terraform 1.12, hence the 0 element.
    condition     = length(var.capacity_provider_strategy) == 0 || sum(concat([0], [for s in var.capacity_provider_strategy : s.weight])) > 0 || length([for s in var.capacity_provider_strategy : s if s.base > 0]) > 0
    error_message = "capacity_provider_strategy needs at least one entry with a weight above 0 (or a base)."
  }
  nullable = false
}

variable "efs_volumes" {
  description = "EFS access points to mount into the container, one entry per volume (for example the outputs of modules/efs). Each volume is mounted writable at container_path, encrypted in transit and authorized with the task role, which is granted elasticfilesystem:ClientMount and ClientWrite on file_system_arn restricted to access_point_arn. Only the list length and the names must be known at plan time. Security groups, mount targets and the access point itself are the caller's concern."
  type = list(object({
    name             = string
    container_path   = string
    file_system_id   = string
    file_system_arn  = string
    access_point_id  = string
    access_point_arn = string
  }))
  default = []

  validation {
    condition     = alltrue([for v in var.efs_volumes : can(regex("^[a-z][a-z0-9-]{0,254}$", v.name)) && v.name != "tmp"])
    error_message = "Every efs_volumes name must be lowercase letters, digits and hyphens, start with a letter and not be tmp (reserved for the scratch volume)."
  }

  validation {
    condition     = length(distinct([for v in var.efs_volumes : v.name])) == length(var.efs_volumes) && length(distinct([for v in var.efs_volumes : v.container_path])) == length(var.efs_volumes)
    error_message = "efs_volumes names and container_path values must be unique."
  }

  validation {
    condition     = alltrue([for v in var.efs_volumes : startswith(v.container_path, "/") && v.container_path != "/" && v.container_path != "/tmp"])
    error_message = "Every efs_volumes container_path must be an absolute path other than / and /tmp."
  }
  nullable = false
}

variable "container_port" {
  description = "Port the OpenArtifact server listens on, injected as SERVER_PORT and used for the container port mapping, the security group ingress rules and the load balancer registration."
  type        = number
  default     = 8080

  validation {
    condition     = var.container_port >= 1024 && var.container_port <= 65535
    error_message = "container_port must be between 1024 and 65535 (the container runs as a non-root user)."
  }
  nullable = false
}

variable "desired_count" {
  description = "Initial number of tasks. Changes after creation are ignored (lifecycle ignore_changes) so Application Auto Scaling and manual scaling are not reverted; scale with the autoscaling variable or `aws ecs update-service`."
  type        = number

  validation {
    condition     = var.desired_count >= 0 && floor(var.desired_count) == var.desired_count
    error_message = "desired_count must be a whole number >= 0."
  }
  nullable = false
}

variable "environment" {
  description = "Plain environment variables for the container (map of name to value). OPENARTIFACT_ROLE, SERVER_PORT, SERVER_SHUTDOWN_DELAY and SERVER_SHUTDOWN_TIMEOUT are set by the module and override the same keys here. Static credentials (STORAGE_ACCESS_KEY, STORAGE_SECRET_KEY, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY) are rejected: the task role provides S3 access."
  type        = map(string)
  default     = {}

  validation {
    condition = length(setintersection(
      toset(keys(var.environment)),
      toset(["STORAGE_ACCESS_KEY", "STORAGE_SECRET_KEY", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN"])
    )) == 0
    error_message = "environment must not set static AWS/S3 credentials; the task role provides S3 access."
  }
  nullable = false
}

variable "secrets" {
  description = "Secret environment variables (map of environment variable name to the Secrets Manager valueFrom reference: a secret ARN, or \"<secret ARN>:<json key>::\" for one key of a JSON secret such as the RDS-managed master secret). The execution role must be allowed to read them: list the secret ARNs (without the json key suffix) in execution_secret_arns. Names must not also appear in environment."
  type        = map(string)
  default     = {}

  validation {
    condition     = length(setintersection(toset(keys(var.secrets)), toset(keys(var.environment)))) == 0
    error_message = "A name must not be defined in both secrets and environment."
  }
  nullable = false
}

variable "execution_secret_arns" {
  description = "ARNs of the Secrets Manager secrets the task execution role may read with secretsmanager:GetSecretValue (the secrets referenced in the secrets variable, without the json key suffix). When empty, no secret access is granted."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "execution_kms_key_arns" {
  description = "ARNs of the customer-managed KMS keys that encrypt the secrets in execution_secret_arns; the execution role is granted kms:Decrypt on them. Leave empty when the secrets use the aws/secretsmanager key."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "task_role_policy_json" {
  description = "IAM policy document (JSON) attached inline to the task role, normally the S3/KMS access policy from the storage module (access_policy_json). Required and non-empty so the plan does not depend on a value that is unknown until apply; the task role has no other permissions except the SSM channel actions added when enable_execute_command is true."
  type        = string

  validation {
    condition     = length(trimspace(var.task_role_policy_json)) > 0
    error_message = "task_role_policy_json must be a non-empty IAM policy document."
  }
  nullable = false
}

variable "target_group_arn" {
  description = "ARN of the ALB target group the service registers its tasks with. Null attaches no load balancer, which is required for role = worker."
  type        = string
  default     = null

  validation {
    condition     = var.target_group_arn == null || var.role != "worker"
    error_message = "role = worker serves no HTTP traffic: target_group_arn must be null."
  }
}

variable "ingress_security_group_ids" {
  description = "IDs of the security groups allowed to reach container_port on the tasks (normally the ALB security group). One ingress rule is created per entry."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "egress_security_group_rules" {
  description = "Additional egress rules towards other security groups, one per entry (for example the database security group on port 5432)."
  type = list(object({
    security_group_id = string
    port              = number
    description       = string
  }))
  default  = []
  nullable = false
}

variable "egress_https_cidr_blocks" {
  description = "IPv4 CIDR blocks the tasks may reach on TCP 443. The default 0.0.0.0/0 is needed because OpenArtifact proxy repositories fetch from arbitrary upstream registries, plus ghcr.io image pulls and the AWS APIs (S3, Secrets Manager, CloudWatch Logs, ECS). Narrow it only if you use VPC endpoints and an allow-listed set of upstreams; the S3 gateway endpoint is reached through egress_https_prefix_list_ids."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = alltrue([for cidr in var.egress_https_cidr_blocks : can(cidrnetmask(cidr))])
    error_message = "egress_https_cidr_blocks must contain valid IPv4 CIDR blocks."
  }
  nullable = false
}

variable "egress_https_prefix_list_ids" {
  description = "IDs of the managed prefix lists the tasks may reach on TCP 443, for example the S3 gateway endpoint prefix list when egress_https_cidr_blocks is narrowed."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "shutdown_delay_seconds" {
  description = "Seconds the server keeps serving after SIGTERM before it stops accepting connections (SERVER_SHUTDOWN_DELAY), so the load balancer deregisters the task first."
  type        = number
  default     = 15

  validation {
    condition     = var.shutdown_delay_seconds >= 0
    error_message = "shutdown_delay_seconds must be >= 0."
  }
  nullable = false
}

variable "shutdown_timeout_seconds" {
  description = "Seconds in-flight requests get to finish during shutdown (SERVER_SHUTDOWN_TIMEOUT). shutdown_delay_seconds + shutdown_timeout_seconds + 5 must not exceed 120, the Fargate stop timeout limit."
  type        = number
  default     = 60

  validation {
    condition     = var.shutdown_timeout_seconds >= 0 && var.shutdown_delay_seconds + var.shutdown_timeout_seconds + 5 <= 120
    error_message = "shutdown_delay_seconds + shutdown_timeout_seconds + 5 must be <= 120 (the Fargate stopTimeout maximum)."
  }
  nullable = false
}

variable "stop_timeout_seconds" {
  description = "Container stopTimeout in seconds (2-120). Null computes min(120, shutdown_delay_seconds + shutdown_timeout_seconds + 5) so ECS sends SIGKILL only after the graceful shutdown completed."
  type        = number
  default     = null

  validation {
    condition     = var.stop_timeout_seconds == null || (coalesce(var.stop_timeout_seconds, 2) >= 2 && coalesce(var.stop_timeout_seconds, 2) <= 120)
    error_message = "stop_timeout_seconds must be null or between 2 and 120 (the Fargate limit)."
  }
}

variable "health_check_grace_period_seconds" {
  description = "Seconds ECS ignores failing load balancer health checks after a task starts. Applied only when target_group_arn is set."
  type        = number
  default     = 60

  validation {
    condition     = var.health_check_grace_period_seconds >= 0 && var.health_check_grace_period_seconds <= 2147483647
    error_message = "health_check_grace_period_seconds must be between 0 and 2147483647."
  }
  nullable = false
}

variable "container_health_check_start_period" {
  description = "Seconds the container health check (openartifact -healthcheck, GET /health) is not counted as failed after the container starts, to cover database connection and migrations on startup (0-300)."
  type        = number
  default     = 60

  validation {
    condition     = var.container_health_check_start_period >= 0 && var.container_health_check_start_period <= 300
    error_message = "container_health_check_start_period must be between 0 and 300."
  }
  nullable = false
}

variable "log_retention_days" {
  description = "Retention of the CloudWatch log group /ecs/<name> (and of the redeploy state machine log group) in days. Must be a value CloudWatch Logs accepts; never-expire (0) is deliberately not allowed."
  type        = number
  default     = 90

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be one of 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653."
  }
  nullable = false
}

variable "log_kms_key_arn" {
  description = "ARN of a customer-managed KMS key to encrypt the CloudWatch log groups, or null for the default CloudWatch Logs encryption. The key policy must allow the logs.<region>.amazonaws.com service principal (kms:Encrypt*, kms:Decrypt*, kms:ReEncrypt*, kms:GenerateDataKey*, kms:Describe*) with the encryption context aws:logs:arn matching the log group ARNs, otherwise log group creation fails."
  type        = string
  default     = null
}

variable "enable_execute_command" {
  description = "Enable ECS Exec (aws ecs execute-command) on the service. The image is shell-less, so the session has nothing to run; leave disabled unless you use a debug sidecar or image. Enabling adds the ssmmessages permissions to the task role."
  type        = bool
  default     = false
  nullable    = false
}

variable "deployment_minimum_healthy_percent" {
  description = "Lower limit, in percent of desired_count, of tasks that must stay running and healthy during a deployment."
  type        = number
  default     = 100

  validation {
    condition     = var.deployment_minimum_healthy_percent >= 0 && var.deployment_minimum_healthy_percent <= 100
    error_message = "deployment_minimum_healthy_percent must be between 0 and 100."
  }
  nullable = false
}

variable "deployment_maximum_percent" {
  description = "Upper limit, in percent of desired_count, of tasks that may run during a deployment."
  type        = number
  default     = 200

  validation {
    condition     = var.deployment_maximum_percent >= 100 && var.deployment_maximum_percent <= 400 && var.deployment_maximum_percent >= var.deployment_minimum_healthy_percent
    error_message = "deployment_maximum_percent must be between 100 and 400 and not below deployment_minimum_healthy_percent."
  }
  nullable = false
}

variable "autoscaling" {
  description = "Application Auto Scaling target tracking for the service desired count. When enabled, CPU tracking (cpu_target_percent) is always created; memory tracking when memory_target_percent is set; ALB request count per target when requests_per_target is set, which also requires alb_resource_label (app/<lb name>/<lb id>/targetgroup/<tg name>/<tg id>, the ALB arn_suffix and target group arn_suffix joined as <alb arn_suffix>/<tg arn_suffix>). Once enabled, autoscaling owns the task count and desired_count is ignored after creation."
  type = object({
    enabled               = optional(bool, false)
    min_capacity          = optional(number, 1)
    max_capacity          = optional(number, 4)
    cpu_target_percent    = optional(number, 60)
    memory_target_percent = optional(number)
    requests_per_target   = optional(number)
    alb_resource_label    = optional(string)
    scale_in_cooldown     = optional(number, 300)
    scale_out_cooldown    = optional(number, 60)
  })
  default = {}

  validation {
    condition     = !var.autoscaling.enabled || (var.autoscaling.min_capacity >= 0 && var.autoscaling.min_capacity <= var.autoscaling.max_capacity)
    error_message = "autoscaling.min_capacity must be >= 0 and <= autoscaling.max_capacity."
  }

  validation {
    condition     = var.autoscaling.requests_per_target == null || var.autoscaling.alb_resource_label != null
    error_message = "autoscaling.requests_per_target requires autoscaling.alb_resource_label (the app/<alb>/<id>/targetgroup/<tg>/<id> resource label)."
  }

  validation {
    condition = (var.autoscaling.cpu_target_percent > 0 && var.autoscaling.cpu_target_percent <= 100) && (
      var.autoscaling.memory_target_percent == null || (coalesce(var.autoscaling.memory_target_percent, 1) > 0 && coalesce(var.autoscaling.memory_target_percent, 1) <= 100)
    )
    error_message = "autoscaling.cpu_target_percent and autoscaling.memory_target_percent must be greater than 0 and at most 100."
  }

  validation {
    condition     = var.autoscaling.scale_in_cooldown >= 0 && var.autoscaling.scale_out_cooldown >= 0
    error_message = "autoscaling.scale_in_cooldown and autoscaling.scale_out_cooldown must be >= 0."
  }
  nullable = false
}

variable "redeploy_on_secret_rotation_arns" {
  description = "ARNs of Secrets Manager secrets whose rotation must restart the tasks (the container reads its environment only at start), typically the RDS-managed master user secret. Non-empty creates an EventBridge rule on the native `Secret Label Updated` event (AWSCURRENT moved) that starts a small Step Functions state machine calling ecs:UpdateService with forceNewDeployment on this service. Only the list length must be known at plan time, the ARNs may be unknown."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "tags" {
  description = "Tags applied to every resource of the module that supports tags."
  type        = map(string)
  default     = {}
  nullable    = false
}
