# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: MPL-2.0

# ---------------------------------------------------------------------------
# Identity and network
# ---------------------------------------------------------------------------

variable "name" {
  description = "Name of the deployment and prefix of every resource (ECS cluster and web service, ALB, database, bucket, secrets). The worker service is named \"<name>-worker\". Must be 3-17 characters: lowercase letters, digits and hyphens, starting with a letter. The limit keeps \"<name>-worker\" within the 24 characters the building modules accept."
  type        = string
  default     = "openartifact"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,15}[a-z0-9]$", var.name))
    error_message = "name must match ^[a-z][a-z0-9-]{1,15}[a-z0-9]$ (3-17 characters: lowercase letters, digits and hyphens, starting with a letter, not ending with a hyphen)."
  }
  nullable = false
}

variable "vpc_id" {
  description = "ID of the existing VPC to deploy into (for example the vpc_id output of modules/network). Its primary IPv4 CIDR is the default for trusted_proxy_cidrs."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id must look like vpc-0123456789abcdef0."
  }
  nullable = false
}

variable "private_subnet_ids" {
  description = "IDs of the private subnets (at least two, in different Availability Zones) that hold the ECS tasks and the RDS database. They need outbound internet access (NAT gateway) for proxy repositories, ghcr.io and the AWS APIs, unless you provide VPC endpoints for everything the tasks use. When internal is true the ALB is placed here as well."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "private_subnet_ids must contain at least two subnets in different Availability Zones (RDS and a highly available service require it)."
  }
  nullable = false
}

variable "public_subnet_ids" {
  description = "IDs of the public subnets (at least two, in different Availability Zones) for an internet-facing ALB. Ignored when internal is true."
  type        = list(string)
  default     = []

  validation {
    condition     = var.internal || length(var.public_subnet_ids) >= 2
    error_message = "public_subnet_ids must contain at least two subnets in different Availability Zones unless internal is true."
  }
  nullable = false
}

# ---------------------------------------------------------------------------
# Load balancer
# ---------------------------------------------------------------------------

variable "certificate_arn" {
  description = "ARN of the ACM certificate for the HTTPS listener. It must cover the host name clients use (see base_url) and live in the region of the deployment. The module does not create or validate certificates."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:acm:[a-z0-9-]+:[0-9]{12}:certificate/.+$", var.certificate_arn))
    error_message = "certificate_arn must be an ACM certificate ARN (arn:aws:acm:<region>:<account>:certificate/<id>)."
  }
  nullable = false
}

variable "additional_certificate_arns" {
  description = "ARNs of additional ACM certificates attached to the HTTPS listener (SNI), for serving more than one host name."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for arn in var.additional_certificate_arns : can(regex("^arn:aws[a-z-]*:acm:[a-z0-9-]+:[0-9]{12}:certificate/.+$", arn))])
    error_message = "Every additional_certificate_arns entry must be an ACM certificate ARN."
  }
  nullable = false
}

variable "allowed_ingress_cidrs" {
  description = "IPv4 CIDR blocks allowed to reach the ALB on ports 443 and 80 (80 only redirects to HTTPS). There is deliberately no default: decide who may reach your artifact repository. \"0.0.0.0/0\" is accepted only when you list it explicitly (a check block warns about it). The list must not be empty; for an IPv6-only ALB use allowed_ingress_ipv6_cidrs and list at least one IPv4 block you control."
  type        = list(string)

  validation {
    condition     = length(var.allowed_ingress_cidrs) > 0
    error_message = "allowed_ingress_cidrs must contain at least one CIDR block; there is no default on purpose (use [\"0.0.0.0/0\"] only if the repository really is public)."
  }

  validation {
    condition = alltrue([
      for cidr in var.allowed_ingress_cidrs :
      can(cidrnetmask(cidr)) && try(cidrhost(cidr, 0) == split("/", cidr)[0], false)
    ])
    error_message = "Every allowed_ingress_cidrs entry must be a valid IPv4 network address in CIDR notation, for example 203.0.113.0/24 (host bits must be zero)."
  }
  nullable = false
}

variable "allowed_ingress_ipv6_cidrs" {
  description = "IPv6 CIDR blocks allowed to reach the ALB on ports 443 and 80. A non-empty list switches the ALB to dualstack, which requires IPv6 CIDRs on the ALB subnets (modules/network creates IPv4-only subnets)."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for cidr in var.allowed_ingress_ipv6_cidrs : can(cidrhost(cidr, 0)) && strcontains(cidr, ":")])
    error_message = "Every allowed_ingress_ipv6_cidrs entry must be a valid IPv6 CIDR block, for example 2001:db8::/32."
  }
  nullable = false
}

variable "internal" {
  description = "Create an internal ALB in private_subnet_ids instead of an internet-facing one in public_subnet_ids. Use it when clients reach OpenArtifact over VPN, Direct Connect, peering or a transit gateway."
  type        = bool
  default     = false
  nullable    = false
}

variable "alb_idle_timeout" {
  description = "ALB idle timeout in seconds (1-4000). Large uploads and downloads can sit idle between chunks, so the default is 300. The server's keep-alive timeout (SERVER_IDLE_TIMEOUT) is set 60 seconds above it so the ALB, not the task, closes idle connections."
  type        = number
  default     = 300

  validation {
    condition     = var.alb_idle_timeout >= 1 && var.alb_idle_timeout <= 4000 && floor(var.alb_idle_timeout) == var.alb_idle_timeout
    error_message = "alb_idle_timeout must be a whole number of seconds between 1 and 4000."
  }
  nullable = false
}

variable "alb_deletion_protection" {
  description = "Block deletion of the ALB through the API. Disable it (and apply) before destroying the deployment."
  type        = bool
  default     = true
  nullable    = false
}

variable "alb_access_logs_bucket" {
  description = "S3 bucket for ALB access logs (bucket name and optional key prefix), or null to disable access logs. The bucket must already exist in the same region with a bucket policy that lets the regional Elastic Load Balancing log delivery principal write to it (see examples/complete). Create the policy before the ALB: the module cannot, the bucket is not its own."
  type = object({
    bucket = string
    prefix = optional(string)
  })
  default = null

  validation {
    condition     = var.alb_access_logs_bucket == null || length(try(var.alb_access_logs_bucket.bucket, "")) > 0
    error_message = "alb_access_logs_bucket.bucket must not be empty."
  }
}

variable "ssl_policy" {
  description = "Security policy of the HTTPS listener. Must be a TLS 1.3 policy (name starting with ELBSecurityPolicy-TLS13). The default ELBSecurityPolicy-TLS13-1-2-2021-06 accepts TLS 1.2 and 1.3 with forward-secret ciphers; use ELBSecurityPolicy-TLS13-1-3-2021-06 to require TLS 1.3 (older package manager clients may fail)."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-2021-06"

  validation {
    condition     = startswith(var.ssl_policy, "ELBSecurityPolicy-TLS13")
    error_message = "ssl_policy must be a TLS 1.3 security policy (name starting with ELBSecurityPolicy-TLS13)."
  }
  nullable = false
}

variable "waf_acl_arn" {
  description = "ARN of a regional WAFv2 web ACL to associate with the ALB, or null for none. When the web ACL is created in the same configuration its ARN is unknown at plan time, so also set waf_acl_enabled = true."
  type        = string
  default     = null

  validation {
    condition     = var.waf_acl_arn == null || can(regex("^arn:aws[a-z-]*:wafv2:[a-z0-9-]+:[0-9]{12}:regional/webacl/.+$", coalesce(var.waf_acl_arn, "x")))
    error_message = "waf_acl_arn must be a regional WAFv2 web ACL ARN (arn:aws:wafv2:<region>:<account>:regional/webacl/<name>/<id>)."
  }
}

variable "waf_acl_enabled" {
  description = "Whether to associate waf_acl_arn with the ALB. Null (default) associates it whenever waf_acl_arn is set, which needs the ARN to be known at plan time. Set true when the web ACL is created in the same configuration (its ARN is only known after apply, and Terraform cannot count on that), or false to detach an ACL without losing the value."
  type        = bool
  default     = null

  validation {
    condition     = var.waf_acl_enabled != true || var.waf_acl_arn != null
    error_message = "waf_acl_enabled = true requires waf_acl_arn."
  }
}

variable "alb_deregistration_delay_seconds" {
  description = "Seconds the ALB keeps a deregistering task in the target group (draining). Null computes shutdown_delay_seconds + shutdown_timeout_seconds so in-flight downloads finish before the task is stopped."
  type        = number
  default     = null

  validation {
    condition     = var.alb_deregistration_delay_seconds == null || (coalesce(var.alb_deregistration_delay_seconds, 0) >= 0 && coalesce(var.alb_deregistration_delay_seconds, 0) <= 3600)
    error_message = "alb_deregistration_delay_seconds must be null or between 0 and 3600."
  }
}

# ---------------------------------------------------------------------------
# Image and application
# ---------------------------------------------------------------------------

variable "image_repository" {
  description = "Container image repository (without tag or digest). The default image is public and multi-arch (amd64 and arm64)."
  type        = string
  default     = "ghcr.io/openartifact/openartifact"

  validation {
    condition     = can(regex("^[a-z0-9._-]+(:[0-9]+)?(/[a-z0-9._-]+)+$", var.image_repository))
    error_message = "image_repository must be a repository name without tag or digest, for example ghcr.io/openartifact/openartifact."
  }
  nullable = false
}

variable "image_tag" {
  description = "Image tag to deploy. Ignored when image_digest is set. Prefer pinning image_digest in production: tags are mutable."
  type        = string
  default     = "0.19.2"

  validation {
    condition     = can(regex("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$", var.image_tag))
    error_message = "image_tag must be a valid image tag (letters, digits, underscore, dot and hyphen, at most 128 characters)."
  }
  nullable = false
}

variable "image_digest" {
  description = "Image digest (sha256:<64 hex characters>) to deploy. When set it wins over image_tag and the image becomes <image_repository>@<digest>, which pins the exact image."
  type        = string
  default     = null

  validation {
    condition     = var.image_digest == null || can(regex("^sha256:[0-9a-f]{64}$", coalesce(var.image_digest, "x")))
    error_message = "image_digest must look like sha256:<64 lowercase hex characters>."
  }
}

variable "base_url" {
  description = "Public URL of the repository (for example https://artifacts.example.com), injected as BASE_URL. Required for SSO, SAML and webhooks and when serving under a path prefix. When null, BASE_URL is not set, the server derives URLs from the request (trusting X-Forwarded-* only from trusted_proxy_cidrs) and the url output falls back to https://<ALB DNS name>."
  type        = string
  default     = null

  validation {
    condition     = var.base_url == null || can(regex("^https?://[^\\s/]+(/\\S*)?$", coalesce(var.base_url, "x")))
    error_message = "base_url must be an absolute http(s) URL such as https://artifacts.example.com."
  }
}

variable "trusted_proxy_cidrs" {
  description = "CIDR blocks of the reverse proxies whose X-Forwarded-* and client-IP headers the server believes (OPENARTIFACT_TRUSTED_PROXIES). Null trusts the VPC CIDR, which covers the ALB. An empty list trusts nobody, so client IPs and generated URLs name the ALB. Never trust 0.0.0.0/0: any client could then spoof its address."
  type        = list(string)
  default     = null

  validation {
    condition     = var.trusted_proxy_cidrs == null || alltrue([for cidr in coalesce(var.trusted_proxy_cidrs, []) : can(cidrhost(cidr, 0))])
    error_message = "Every trusted_proxy_cidrs entry must be a valid CIDR block."
  }
}

variable "extra_environment" {
  description = "Additional plain-text environment variables for the web and worker containers (name to value), for example LOG_LEVEL or SERVER_IDLE_TIMEOUT. Never put secrets here: the values are visible in the task definition. Keys that the module manages are rejected: DB_*, STORAGE_*, AWS_*, BASE_URL, OPENARTIFACT_TRUSTED_PROXIES, OPENARTIFACT_ROLE, OPENARTIFACT_SECRET_KEY, OPENARTIFACT_BOOTSTRAP_ADMIN_PASSWORD, AUTH_HMAC_KEY, METRICS_AUTH_TOKEN, SERVER_PORT, SERVER_SHUTDOWN_DELAY and SERVER_SHUTDOWN_TIMEOUT."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for key in keys(var.extra_environment) : can(regex("^[A-Za-z_][A-Za-z0-9_]*$", key))])
    error_message = "extra_environment keys must be valid environment variable names (letters, digits and underscores, not starting with a digit)."
  }

  validation {
    condition = alltrue([
      for key in keys(var.extra_environment) :
      !can(regex("^(DB_|STORAGE_|AWS_)", key)) && !contains([
        "BASE_URL",
        "OPENARTIFACT_TRUSTED_PROXIES",
        "OPENARTIFACT_ROLE",
        "OPENARTIFACT_SECRET_KEY",
        "OPENARTIFACT_BOOTSTRAP_ADMIN_PASSWORD",
        "AUTH_HMAC_KEY",
        "METRICS_AUTH_TOKEN",
        "SERVER_PORT",
        "SERVER_SHUTDOWN_DELAY",
        "SERVER_SHUTDOWN_TIMEOUT",
      ], key)
    ])
    error_message = "extra_environment must not override module-managed keys: DB_*, STORAGE_*, AWS_*, BASE_URL, OPENARTIFACT_TRUSTED_PROXIES, OPENARTIFACT_ROLE, OPENARTIFACT_SECRET_KEY, OPENARTIFACT_BOOTSTRAP_ADMIN_PASSWORD, AUTH_HMAC_KEY, METRICS_AUTH_TOKEN, SERVER_PORT, SERVER_SHUTDOWN_DELAY, SERVER_SHUTDOWN_TIMEOUT. Use the dedicated variables instead."
  }
  nullable = false
}

# ---------------------------------------------------------------------------
# Secrets
# ---------------------------------------------------------------------------

variable "enable_metrics_token" {
  description = "Generate a bearer token (METRICS_AUTH_TOKEN) that protects the /metrics endpoint."
  type        = bool
  default     = true
  nullable    = false
}

variable "bootstrap_admin_password_enabled" {
  description = "Generate the initial admin password and inject it as OPENARTIFACT_BOOTSTRAP_ADMIN_PASSWORD. It is used only on an empty instance; read it once from Secrets Manager and change it after the first login. The bootstrap admin token is file-only and not supported on ECS."
  type        = bool
  default     = true
  nullable    = false
}

variable "existing_secret_arns" {
  description = "Bring-your-own Secrets Manager secrets (plain string values, not JSON): every attribute that is set is used as-is and NO secret is generated for it. Attributes: secret_key (OPENARTIFACT_SECRET_KEY), hmac_key (AUTH_HMAC_KEY), metrics_token, bootstrap_admin_password."
  type = object({
    secret_key               = optional(string)
    hmac_key                 = optional(string)
    metrics_token            = optional(string)
    bootstrap_admin_password = optional(string)
  })
  default  = {}
  nullable = false
}

variable "secret_version" {
  description = "Rotation counter for the generated metrics token, HMAC key and bootstrap admin password: bump it to write new values, then redeploy the services. It never changes OPENARTIFACT_SECRET_KEY, whose replacement would make stored credentials permanently unreadable."
  type        = number
  default     = 1

  validation {
    condition     = var.secret_version >= 1 && floor(var.secret_version) == var.secret_version
    error_message = "secret_version must be a whole number >= 1."
  }
  nullable = false
}

variable "secrets_kms_key_arn" {
  description = "ARN of a customer-managed KMS key that encrypts the generated application secrets, or null for the AWS managed aws/secretsmanager key. The key must be known at plan time; the task execution roles are granted kms:Decrypt on it."
  type        = string
  default     = null

  validation {
    condition     = var.secrets_kms_key_arn == null || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:(key|alias)/.+$", coalesce(var.secrets_kms_key_arn, "x")))
    error_message = "secrets_kms_key_arn must be a KMS key or alias ARN."
  }
}

variable "secrets_recovery_window_in_days" {
  description = "Days Secrets Manager keeps a deleted application secret recoverable (7-30), or 0 to delete immediately. Keep the default: an accidentally deleted OPENARTIFACT_SECRET_KEY can only be restored inside this window."
  type        = number
  default     = 30

  validation {
    condition     = var.secrets_recovery_window_in_days == 0 || (var.secrets_recovery_window_in_days >= 7 && var.secrets_recovery_window_in_days <= 30 && floor(var.secrets_recovery_window_in_days) == var.secrets_recovery_window_in_days)
    error_message = "secrets_recovery_window_in_days must be 0 or a whole number between 7 and 30."
  }
  nullable = false
}

# ---------------------------------------------------------------------------
# Compute
# ---------------------------------------------------------------------------

variable "capacity_type" {
  description = "Where the ECS tasks run: FARGATE (the default: serverless, nothing to patch) or EC2 (container instances in Auto Scaling groups behind ECS capacity providers, see ec2_capacity: cheaper at steady load, local disk for /tmp, your AMI and patching responsibility). Switching replaces the services' task definitions and moves the tasks. With EC2, assign_public_ip must be false and name must not start with aws, ecs or fargate."
  type        = string
  default     = "FARGATE"

  validation {
    condition     = contains(["FARGATE", "EC2"], var.capacity_type)
    error_message = "capacity_type must be FARGATE or EC2."
  }

  validation {
    condition     = var.capacity_type != "EC2" || !var.assign_public_ip
    error_message = "assign_public_ip must be false with capacity_type EC2: tasks on EC2 container instances cannot get a public IP address."
  }

  validation {
    condition     = var.capacity_type != "EC2" || !can(regex("^(aws|ecs|fargate)", var.name))
    error_message = "name must not start with aws, ecs or fargate with capacity_type EC2: ECS reserves these prefixes for capacity provider names."
  }
  nullable = false
}

variable "ec2_capacity" {
  description = <<-EOT
    EC2 capacity used when capacity_type is EC2 (ignored with FARGATE). One On-Demand Auto Scaling group, plus a Spot one when spot_percentage.web is above 0, each behind an ECS capacity provider with managed scaling, managed termination protection and managed draining.
    - instance_types: instance types in order of preference, all of the architecture cpu_architecture. Null: m7g.large and m6g.large (ARM64) or m7i.large and m6i.large (X86_64). In awsvpc mode every task needs a network interface; a large instance has three (one is the instance itself), so it fits two tasks unless ENI trunking is enabled for the account.
    - ami_id: AMI to use instead of the recommended ECS-optimized Amazon Linux 2023 image from the public SSM parameter (resolved at plan time: a new release replaces the instances on the next apply).
    - min_size, max_size: bounds of every Auto Scaling group; managed scaling moves between them.
    - root_volume_size_gib: encrypted gp3 volume with the OS, the images and the /tmp scratch of every task on the instance.
    - kms_key_arn: customer-managed key for the volumes (null: aws/ebs); its policy must allow the Auto Scaling service-linked role.
    - target_capacity: percent utilization managed scaling aims for (100 packs tightly; lower keeps headroom).
    - spot_percentage.web: share in percent of the web tasks (beyond the first, which always runs On-Demand) placed on Spot instances. spot_percentage.worker must stay 0: an interruption would abort running scans and backups.
  EOT
  type = object({
    instance_types       = optional(list(string))
    ami_id               = optional(string)
    min_size             = optional(number, 1)
    max_size             = optional(number, 4)
    root_volume_size_gib = optional(number, 100)
    kms_key_arn          = optional(string)
    target_capacity      = optional(number, 100)
    spot_percentage = optional(object({
      web    = optional(number, 0)
      worker = optional(number, 0)
    }), {})
  })
  default = {}

  validation {
    condition     = var.ec2_capacity.instance_types == null || (length(coalesce(var.ec2_capacity.instance_types, [])) >= 1 && length(coalesce(var.ec2_capacity.instance_types, [])) <= 20)
    error_message = "ec2_capacity.instance_types must be null or contain between 1 and 20 instance types."
  }

  validation {
    condition     = var.ec2_capacity.instance_types == null || alltrue([for t in coalesce(var.ec2_capacity.instance_types, []) : can(regex("^[a-z0-9-]+\\.[a-z0-9]+$", t))])
    error_message = "Every ec2_capacity.instance_types entry must look like m7g.large."
  }

  validation {
    condition     = var.ec2_capacity.ami_id == null || can(regex("^ami-[0-9a-f]+$", coalesce(var.ec2_capacity.ami_id, "x")))
    error_message = "ec2_capacity.ami_id must be null or look like ami-0123456789abcdef0."
  }

  validation {
    condition     = var.ec2_capacity.min_size >= 0 && floor(var.ec2_capacity.min_size) == var.ec2_capacity.min_size && var.ec2_capacity.max_size >= 1 && floor(var.ec2_capacity.max_size) == var.ec2_capacity.max_size && var.ec2_capacity.min_size <= var.ec2_capacity.max_size
    error_message = "ec2_capacity.min_size and ec2_capacity.max_size must be whole numbers with 0 <= min_size <= max_size and max_size >= 1."
  }

  validation {
    condition     = var.ec2_capacity.root_volume_size_gib >= 30 && var.ec2_capacity.root_volume_size_gib <= 16384 && floor(var.ec2_capacity.root_volume_size_gib) == var.ec2_capacity.root_volume_size_gib
    error_message = "ec2_capacity.root_volume_size_gib must be a whole number between 30 and 16384."
  }

  validation {
    condition     = var.ec2_capacity.kms_key_arn == null || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:(key|alias)/.+$", coalesce(var.ec2_capacity.kms_key_arn, "x")))
    error_message = "ec2_capacity.kms_key_arn must be null or a KMS key or alias ARN."
  }

  validation {
    condition     = var.ec2_capacity.target_capacity >= 1 && var.ec2_capacity.target_capacity <= 100 && floor(var.ec2_capacity.target_capacity) == var.ec2_capacity.target_capacity
    error_message = "ec2_capacity.target_capacity must be a whole number between 1 and 100."
  }

  validation {
    condition     = var.ec2_capacity.spot_percentage.web >= 0 && var.ec2_capacity.spot_percentage.web <= 100 && floor(var.ec2_capacity.spot_percentage.web) == var.ec2_capacity.spot_percentage.web
    error_message = "ec2_capacity.spot_percentage.web must be a whole number between 0 and 100."
  }

  validation {
    condition     = var.ec2_capacity.spot_percentage.worker == 0
    error_message = "ec2_capacity.spot_percentage.worker must be 0: the worker runs scans and backups that a Spot interruption would abort. Only the web service can use Spot."
  }
  nullable = false
}

variable "cpu_architecture" {
  description = "CPU architecture of the tasks: ARM64 (about 20% cheaper, the default) or X86_64. The OpenArtifact image is published for both. With capacity_type EC2 it also selects the AMI and the default instance types."
  type        = string
  default     = "ARM64"

  validation {
    condition     = contains(["ARM64", "X86_64"], var.cpu_architecture)
    error_message = "cpu_architecture must be ARM64 or X86_64."
  }
  nullable = false
}

variable "ephemeral_storage_gib" {
  description = "Task ephemeral storage in GiB (21-200) for the writable /tmp, where uploads and proxied downloads are spooled before they go to S3. Size it for the largest artifact you expect. Fargate only: with capacity_type EC2, /tmp lives on the instance disk (ec2_capacity.root_volume_size_gib)."
  type        = number
  default     = 50

  validation {
    condition     = var.ephemeral_storage_gib >= 21 && var.ephemeral_storage_gib <= 200 && floor(var.ephemeral_storage_gib) == var.ephemeral_storage_gib
    error_message = "ephemeral_storage_gib must be a whole number between 21 and 200."
  }
  nullable = false
}

variable "web_cpu" {
  description = "CPU units of each web task: 256, 512, 1024, 2048, 4096, 8192 or 16384. Must form a valid Fargate combination with web_memory."
  type        = number
  default     = 1024

  validation {
    condition     = contains([256, 512, 1024, 2048, 4096, 8192, 16384], var.web_cpu)
    error_message = "web_cpu must be one of 256, 512, 1024, 2048, 4096, 8192 or 16384."
  }
  nullable = false
}

variable "web_memory" {
  description = "Memory in MiB of each web task. Valid Fargate combinations: 256 CPU 512/1024/2048; 512 CPU 1024-4096 step 1024; 1024 CPU 2048-8192 step 1024; 2048 CPU 4096-16384 step 1024; 4096 CPU 8192-30720 step 1024; 8192 CPU 16384-61440 step 4096; 16384 CPU 32768-122880 step 8192."
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
    }, tostring(var.web_cpu), []), var.web_memory)
    error_message = "web_cpu and web_memory do not form a valid Fargate combination (256: 512/1024/2048; 512: 1024-4096; 1024: 2048-8192; 2048: 4096-16384; 4096: 8192-30720; 8192: 16384-61440 step 4096; 16384: 32768-122880 step 8192)."
  }
  nullable = false
}

variable "web_desired_count" {
  description = "Initial number of web tasks. Application Auto Scaling (web_autoscaling) or manual scaling owns the count after creation; later changes to this value are ignored."
  type        = number
  default     = 2

  validation {
    condition     = var.web_desired_count >= 1 && floor(var.web_desired_count) == var.web_desired_count
    error_message = "web_desired_count must be a whole number >= 1."
  }
  nullable = false
}

variable "web_autoscaling" {
  description = "Target-tracking autoscaling of the web service. When enabled, CPU tracking (cpu_target_percent) is always created, memory tracking when memory_target_percent is set, and ALB request count per target when requests_per_target is set (the module builds the ALB resource label). Autoscaling owns the task count after creation."
  type = object({
    enabled               = optional(bool, true)
    min_capacity          = optional(number, 2)
    max_capacity          = optional(number, 6)
    cpu_target_percent    = optional(number, 60)
    memory_target_percent = optional(number)
    requests_per_target   = optional(number)
    scale_in_cooldown     = optional(number, 300)
    scale_out_cooldown    = optional(number, 60)
  })
  default = {}

  validation {
    condition     = !var.web_autoscaling.enabled || (var.web_autoscaling.min_capacity >= 1 && var.web_autoscaling.min_capacity <= var.web_autoscaling.max_capacity)
    error_message = "web_autoscaling.min_capacity must be >= 1 and <= web_autoscaling.max_capacity."
  }

  validation {
    condition = (var.web_autoscaling.cpu_target_percent > 0 && var.web_autoscaling.cpu_target_percent <= 100) && (
      var.web_autoscaling.memory_target_percent == null || (coalesce(var.web_autoscaling.memory_target_percent, 1) > 0 && coalesce(var.web_autoscaling.memory_target_percent, 1) <= 100)
    )
    error_message = "web_autoscaling.cpu_target_percent and web_autoscaling.memory_target_percent must be greater than 0 and at most 100."
  }

  validation {
    condition     = var.web_autoscaling.requests_per_target == null || coalesce(var.web_autoscaling.requests_per_target, 0) > 0
    error_message = "web_autoscaling.requests_per_target must be greater than 0."
  }
  nullable = false
}

variable "worker_enabled" {
  description = "Run the background jobs (OPENARTIFACT_ROLE=worker) in a separate service without load balancer, and the web service as role \"web\". When false a single service runs everything (role \"all\")."
  type        = bool
  default     = false
  nullable    = false
}

variable "worker_cpu" {
  description = "CPU units of each worker task (same values as web_cpu). Only used when worker_enabled is true."
  type        = number
  default     = 1024

  validation {
    condition     = contains([256, 512, 1024, 2048, 4096, 8192, 16384], var.worker_cpu)
    error_message = "worker_cpu must be one of 256, 512, 1024, 2048, 4096, 8192 or 16384."
  }
  nullable = false
}

variable "worker_memory" {
  description = "Memory in MiB of each worker task; must form a valid Fargate combination with worker_cpu (see web_memory). Only used when worker_enabled is true."
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
    }, tostring(var.worker_cpu), []), var.worker_memory)
    error_message = "worker_cpu and worker_memory do not form a valid Fargate combination (256: 512/1024/2048; 512: 1024-4096; 1024: 2048-8192; 2048: 4096-16384; 4096: 8192-30720; 8192: 16384-61440 step 4096; 16384: 32768-122880 step 8192)."
  }
  nullable = false
}

variable "worker_desired_count" {
  description = "Initial number of worker tasks. Must be at least 1 when worker_enabled is true. Changes after creation are ignored (autoscaling or manual scaling owns the count)."
  type        = number
  default     = 1

  validation {
    condition     = floor(var.worker_desired_count) == var.worker_desired_count && var.worker_desired_count >= (var.worker_enabled ? 1 : 0)
    error_message = "worker_desired_count must be a whole number >= 1 when worker_enabled is true (>= 0 otherwise)."
  }
  nullable = false
}

variable "worker_autoscaling" {
  description = "Target-tracking autoscaling of the worker service on CPU (always) and memory (when memory_target_percent is set). Disabled by default: the worker has no load balancer and its load is background jobs, so scale it deliberately."
  type = object({
    enabled               = optional(bool, false)
    min_capacity          = optional(number, 1)
    max_capacity          = optional(number, 4)
    cpu_target_percent    = optional(number, 60)
    memory_target_percent = optional(number)
    scale_in_cooldown     = optional(number, 300)
    scale_out_cooldown    = optional(number, 60)
  })
  default = {}

  validation {
    condition     = !var.worker_autoscaling.enabled || (var.worker_autoscaling.min_capacity >= 1 && var.worker_autoscaling.min_capacity <= var.worker_autoscaling.max_capacity)
    error_message = "worker_autoscaling.min_capacity must be >= 1 and <= worker_autoscaling.max_capacity."
  }

  validation {
    condition = (var.worker_autoscaling.cpu_target_percent > 0 && var.worker_autoscaling.cpu_target_percent <= 100) && (
      var.worker_autoscaling.memory_target_percent == null || (coalesce(var.worker_autoscaling.memory_target_percent, 1) > 0 && coalesce(var.worker_autoscaling.memory_target_percent, 1) <= 100)
    )
    error_message = "worker_autoscaling.cpu_target_percent and worker_autoscaling.memory_target_percent must be greater than 0 and at most 100."
  }
  nullable = false
}

variable "shutdown_delay_seconds" {
  description = "Seconds the server keeps serving after SIGTERM before it stops accepting connections (SERVER_SHUTDOWN_DELAY), so the ALB deregisters the task first."
  type        = number
  default     = 15

  validation {
    condition     = var.shutdown_delay_seconds >= 0 && floor(var.shutdown_delay_seconds) == var.shutdown_delay_seconds
    error_message = "shutdown_delay_seconds must be a whole number >= 0."
  }
  nullable = false
}

variable "shutdown_timeout_seconds" {
  description = "Seconds in-flight requests get to finish during shutdown (SERVER_SHUTDOWN_TIMEOUT). shutdown_delay_seconds + shutdown_timeout_seconds + 5 must not exceed 120, the Fargate stop timeout limit."
  type        = number
  default     = 60

  validation {
    condition     = var.shutdown_timeout_seconds >= 0 && floor(var.shutdown_timeout_seconds) == var.shutdown_timeout_seconds && var.shutdown_delay_seconds + var.shutdown_timeout_seconds + 5 <= 120
    error_message = "shutdown_delay_seconds + shutdown_timeout_seconds + 5 must be <= 120 (the Fargate stopTimeout maximum)."
  }
  nullable = false
}

variable "health_check_grace_period_seconds" {
  description = "Seconds ECS ignores failing load balancer health checks after a web task starts, to cover database connection and migrations on startup."
  type        = number
  default     = 60

  validation {
    condition     = var.health_check_grace_period_seconds >= 0 && var.health_check_grace_period_seconds <= 2147483647
    error_message = "health_check_grace_period_seconds must be between 0 and 2147483647."
  }
  nullable = false
}

variable "assign_public_ip" {
  description = "Give the tasks a public IPv4 address. Keep false and run them in private subnets; enable it only when the subnets are public and there is no NAT gateway. Fargate only: must be false with capacity_type EC2."
  type        = bool
  default     = false
  nullable    = false
}

variable "enable_execute_command" {
  description = "Enable ECS Exec on the services. The image is shell-less, so a session has nothing to run; enable it only together with a debug image."
  type        = bool
  default     = false
  nullable    = false
}

variable "container_insights" {
  description = "CloudWatch Container Insights of the ECS cluster: \"enabled\", \"enhanced\" (more detailed metrics, higher cost) or \"disabled\"."
  type        = string
  default     = "enabled"

  validation {
    condition     = contains(["enabled", "enhanced", "disabled"], var.container_insights)
    error_message = "container_insights must be enabled, enhanced or disabled."
  }
  nullable = false
}

variable "log_retention_days" {
  description = "Retention in days of the CloudWatch log groups of the services. Must be a value CloudWatch Logs accepts; never-expire (0) is deliberately not allowed."
  type        = number
  default     = 90

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be one of 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653."
  }
  nullable = false
}

variable "log_kms_key_arn" {
  description = "ARN of a customer-managed KMS key that encrypts the CloudWatch log groups, or null for the default CloudWatch Logs encryption. Its key policy must allow the logs.<region>.amazonaws.com service principal."
  type        = string
  default     = null

  validation {
    condition     = var.log_kms_key_arn == null || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/.+$", coalesce(var.log_kms_key_arn, "x")))
    error_message = "log_kms_key_arn must be a KMS key ARN."
  }
}

# ---------------------------------------------------------------------------
# Persistent volume (EFS)
# ---------------------------------------------------------------------------

variable "persistent_volume" {
  description = <<-EOT
    Optional encrypted EFS file system mounted into every web and worker task, for the scanner database cache and the in-application backups, which need a writable directory that survives restarts and is shared by the tasks. Disabled by default: the tasks then keep the read-only root filesystem and /tmp as the only writable path.
    - enabled: create the file system, one mount target per private subnet and the access points. Encrypted at rest and in transit, IAM-authorized, reachable only from the task security groups (and the container instances with capacity_type EC2), through access points as 10001:10001 with mode 0750.
    - performance_mode, throughput_mode, provisioned_throughput_in_mibps: EFS performance settings; elastic throughput (the default) scales with the workload. A scanner database is about 5 GB with Trivy and Grype together.
    - kms_key_arn: customer-managed key (null: aws/elasticfilesystem); its policy must allow use through EFS.
    - backup_policy_enabled: EFS automatic backups (AWS Backup, daily, 35 days).
    - transition_to_ia: tier files not read for this long (for example AFTER_30_DAYS) to Infrequent Access. It applies to the whole file system, scanner databases included; null keeps everything in Standard.
    - scanner_cache: mount the scanner cache at /var/cache/openartifact/scanners and set OPENARTIFACT_SCANNER_CACHE_DIR.
    - scanner_auto_install: also set OPENARTIFACT_TRIVY_INSTALL and OPENARTIFACT_GRYPE_INSTALL to auto, so the server downloads the pinned, checksum-verified scanner binaries into the cache (needs HTTPS egress to github.com). Requires scanner_cache.
    - backups: mount the backup directory at /var/lib/openartifact/backups and set OPENARTIFACT_BACKUP_DIR.
  EOT
  type = object({
    enabled                         = optional(bool, false)
    performance_mode                = optional(string, "generalPurpose")
    throughput_mode                 = optional(string, "elastic")
    provisioned_throughput_in_mibps = optional(number)
    kms_key_arn                     = optional(string)
    backup_policy_enabled           = optional(bool, true)
    transition_to_ia                = optional(string)
    scanner_cache                   = optional(bool, true)
    scanner_auto_install            = optional(bool, false)
    backups                         = optional(bool, true)
  })
  default = {}

  validation {
    condition     = contains(["generalPurpose", "maxIO"], var.persistent_volume.performance_mode)
    error_message = "persistent_volume.performance_mode must be generalPurpose or maxIO."
  }

  validation {
    condition     = contains(["elastic", "bursting", "provisioned"], var.persistent_volume.throughput_mode)
    error_message = "persistent_volume.throughput_mode must be elastic, bursting or provisioned."
  }

  validation {
    condition     = var.persistent_volume.throughput_mode != "elastic" || var.persistent_volume.performance_mode == "generalPurpose"
    error_message = "persistent_volume.throughput_mode elastic requires performance_mode generalPurpose."
  }

  validation {
    condition     = (var.persistent_volume.throughput_mode == "provisioned") == (var.persistent_volume.provisioned_throughput_in_mibps != null)
    error_message = "persistent_volume.provisioned_throughput_in_mibps must be set when throughput_mode is provisioned and null otherwise."
  }

  validation {
    condition     = var.persistent_volume.kms_key_arn == null || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:(key|alias)/.+$", coalesce(var.persistent_volume.kms_key_arn, "x")))
    error_message = "persistent_volume.kms_key_arn must be null or a KMS key or alias ARN."
  }

  validation {
    condition = var.persistent_volume.transition_to_ia == null || contains([
      "AFTER_1_DAY", "AFTER_7_DAYS", "AFTER_14_DAYS", "AFTER_30_DAYS", "AFTER_60_DAYS",
      "AFTER_90_DAYS", "AFTER_180_DAYS", "AFTER_270_DAYS", "AFTER_365_DAYS",
    ], coalesce(var.persistent_volume.transition_to_ia, "none"))
    error_message = "persistent_volume.transition_to_ia must be null or one of AFTER_1_DAY, AFTER_7_DAYS, AFTER_14_DAYS, AFTER_30_DAYS, AFTER_60_DAYS, AFTER_90_DAYS, AFTER_180_DAYS, AFTER_270_DAYS, AFTER_365_DAYS."
  }

  validation {
    condition     = !var.persistent_volume.enabled || var.persistent_volume.scanner_cache || var.persistent_volume.backups
    error_message = "persistent_volume.enabled needs at least one use: scanner_cache or backups."
  }

  validation {
    condition     = !var.persistent_volume.scanner_auto_install || var.persistent_volume.scanner_cache
    error_message = "persistent_volume.scanner_auto_install installs the scanners into the cache and therefore requires scanner_cache."
  }
  nullable = false
}

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------

variable "db_instance_class" {
  description = "RDS instance class, for example db.t4g.medium. Performance Insights is not available on db.t4g.micro and db.t4g.small."
  type        = string
  default     = "db.t4g.medium"

  validation {
    condition     = can(regex("^db\\.[a-z0-9-]+\\.[a-z0-9]+$", var.db_instance_class))
    error_message = "db_instance_class must look like db.t4g.medium."
  }
  nullable = false
}

variable "db_allocated_storage" {
  description = "Initial RDS storage in GiB (20-65536)."
  type        = number
  default     = 50

  validation {
    condition     = var.db_allocated_storage >= 20 && var.db_allocated_storage <= 65536 && floor(var.db_allocated_storage) == var.db_allocated_storage
    error_message = "db_allocated_storage must be a whole number between 20 and 65536 GiB."
  }
  nullable = false
}

variable "db_max_allocated_storage" {
  description = "Upper limit in GiB for RDS storage autoscaling. 0 disables autoscaling; otherwise it must be at least db_allocated_storage."
  type        = number
  default     = 200

  validation {
    condition     = var.db_max_allocated_storage == 0 || (var.db_max_allocated_storage >= var.db_allocated_storage && var.db_max_allocated_storage <= 65536 && floor(var.db_max_allocated_storage) == var.db_max_allocated_storage)
    error_message = "db_max_allocated_storage must be 0 (autoscaling disabled) or a whole number between db_allocated_storage and 65536 GiB."
  }
  nullable = false
}

variable "db_engine_version" {
  description = "PostgreSQL major version (16, 17 or 18). Only the major is passed to RDS; minor upgrades are applied automatically in the maintenance window."
  type        = string
  default     = "17"

  validation {
    condition     = contains(["16", "17", "18"], var.db_engine_version)
    error_message = "db_engine_version must be a PostgreSQL major supported by OpenArtifact on RDS: 16, 17 or 18 (major only, no minor)."
  }
  nullable = false
}

variable "db_multi_az" {
  description = "Run a synchronous standby in a second Availability Zone. Doubles the instance and storage cost; keep it on for production."
  type        = bool
  default     = true
  nullable    = false
}

variable "db_backup_retention_period" {
  description = "Days to keep automated RDS backups (1-35)."
  type        = number
  default     = 14

  validation {
    condition     = var.db_backup_retention_period >= 1 && var.db_backup_retention_period <= 35 && floor(var.db_backup_retention_period) == var.db_backup_retention_period
    error_message = "db_backup_retention_period must be a whole number of days between 1 and 35."
  }
  nullable = false
}

variable "db_deletion_protection" {
  description = "Block deletion of the DB instance through the API. Disable it (and apply) before destroying the deployment."
  type        = bool
  default     = true
  nullable    = false
}

variable "db_skip_final_snapshot" {
  description = "Skip the final DB snapshot on destroy. Keep false in production so the data survives an accidental destroy."
  type        = bool
  default     = false
  nullable    = false
}

variable "db_performance_insights_enabled" {
  description = "Enable RDS Performance Insights (encrypted with the database KMS key). Turn it off on db.t4g.micro and db.t4g.small, which do not support it."
  type        = bool
  default     = true
  nullable    = false
}

variable "db_monitoring_interval" {
  description = "Seconds between RDS Enhanced Monitoring samples (0, 1, 5, 10, 15, 30 or 60). 0 disables it; any other value creates the monitoring IAM role."
  type        = number
  default     = 0

  validation {
    condition     = contains([0, 1, 5, 10, 15, 30, 60], var.db_monitoring_interval)
    error_message = "db_monitoring_interval must be one of 0, 1, 5, 10, 15, 30 or 60."
  }
  nullable = false
}

variable "db_max_open_conns" {
  description = "Size of the database connection pool of each task (DB_MAX_OPEN_CONNS). 0 means unlimited, otherwise at least 2. Total connections are this value times the number of tasks (web plus worker), so keep it within the RDS max_connections of db_instance_class."
  type        = number
  default     = 25

  validation {
    condition     = (var.db_max_open_conns == 0 || var.db_max_open_conns >= 2) && floor(var.db_max_open_conns) == var.db_max_open_conns
    error_message = "db_max_open_conns must be 0 (unlimited) or a whole number >= 2."
  }
  nullable = false
}

variable "db_sslmode" {
  description = "PostgreSQL sslmode of the connection (DB_SSLMODE): \"require\" encrypts the connection (the database forces TLS) without verifying the server certificate; \"verify-full\" also verifies it, but needs the RDS CA bundle, which the shell-less image does not contain, so it only works with a custom image."
  type        = string
  default     = "require"

  validation {
    condition     = contains(["require", "verify-full"], var.db_sslmode)
    error_message = "db_sslmode must be require or verify-full."
  }
  nullable = false
}

variable "db_apply_immediately" {
  description = "Apply RDS modifications immediately instead of in the next maintenance window. Some changes (instance class, Multi-AZ, storage) cause a brief outage when applied immediately."
  type        = bool
  default     = false
  nullable    = false
}

variable "redeploy_on_db_secret_rotation" {
  description = "Redeploy the ECS services when RDS rotates the managed master password (about every 7 days). The containers read DB_PASSWORD only at start, so without a redeployment they fail to connect after a rotation. Creates an EventBridge rule and a small Step Functions state machine per service (see modules/ecs-service). Set to false only if you redeploy by other means."
  type        = bool
  default     = true
  nullable    = false
}

# ---------------------------------------------------------------------------
# Storage
# ---------------------------------------------------------------------------

variable "s3_bucket_name" {
  description = "Explicit name of the S3 blob bucket. Null names it \"<name>-blobs-<account_id>-<region>\"."
  type        = string
  default     = null

  validation {
    condition     = var.s3_bucket_name == null || can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", coalesce(var.s3_bucket_name, "x")))
    error_message = "s3_bucket_name must be 3-63 characters of lowercase letters, digits, dots and hyphens, starting and ending with a letter or digit."
  }
}

variable "s3_kms_mode" {
  description = "Bucket encryption key: \"cmk\" creates a dedicated customer-managed KMS key with rotation (recommended); \"aws_managed\" uses the AWS managed aws/s3 key."
  type        = string
  default     = "cmk"

  validation {
    condition     = contains(["cmk", "aws_managed"], var.s3_kms_mode)
    error_message = "s3_kms_mode must be \"cmk\" or \"aws_managed\"."
  }
  nullable = false
}

variable "s3_versioning_enabled" {
  description = "Keep previous object versions, which protects blobs against accidental or malicious deletes."
  type        = bool
  default     = true
  nullable    = false
}

variable "s3_noncurrent_version_expiration_days" {
  description = "Days after which noncurrent object versions are permanently deleted. Only used when s3_versioning_enabled is true."
  type        = number
  default     = 30

  validation {
    condition     = var.s3_noncurrent_version_expiration_days >= 1 && floor(var.s3_noncurrent_version_expiration_days) == var.s3_noncurrent_version_expiration_days
    error_message = "s3_noncurrent_version_expiration_days must be a whole number >= 1."
  }
  nullable = false
}

variable "s3_force_destroy" {
  description = "Delete the bucket with all objects and versions on destroy. Leave false in production: the bucket holds every stored artifact."
  type        = bool
  default     = false
  nullable    = false
}

variable "s3_access_logging" {
  description = "S3 server access logging of the blob bucket: the target bucket (which must grant logging.s3.amazonaws.com PutObject) and key prefix. Null disables it."
  type = object({
    target_bucket = string
    target_prefix = optional(string, "s3/")
  })
  default = null
}

# ---------------------------------------------------------------------------
# Tags
# ---------------------------------------------------------------------------

variable "tags" {
  description = "Tags applied to every resource of the module that supports tags (merged with the provider default_tags)."
  type        = map(string)
  default     = {}
  nullable    = false
}
