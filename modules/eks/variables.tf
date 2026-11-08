# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: MPL-2.0

# ---------------------------------------------------------------------------
# Cluster and network
# ---------------------------------------------------------------------------

variable "name" {
  description = "Name prefix for the AWS resources this module creates (S3 bucket, KMS aliases, RDS instance, IAM role, Secrets Manager secrets). Lowercase letters, digits and hyphens, 3-24 characters."
  type        = string
  default     = "openartifact"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,22}[a-z0-9]$", var.name))
    error_message = "name must match ^[a-z][a-z0-9-]{1,22}[a-z0-9]$ (3-24 characters)."
  }
}

variable "cluster_name" {
  description = "Name of the EXISTING EKS cluster to deploy onto. The helm and kubernetes providers configured by the caller must point at this cluster."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[0-9A-Za-z][A-Za-z0-9_-]{0,99}$", var.cluster_name))
    error_message = "cluster_name must be a valid EKS cluster name (1-100 characters: letters, digits, hyphens and underscores, starting with a letter or digit)."
  }
}

variable "vpc_id" {
  description = "ID of the VPC of the cluster. The database security group is created in it and the VPC CIDR is the default for trusted_proxy_cidrs."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id must look like vpc-0123456789abcdef0."
  }
}

variable "database_subnet_ids" {
  description = "IDs of the private subnets for the RDS subnet group. At least two subnets in different Availability Zones are required by RDS; they must be routable from the pods."
  type        = list(string)
  nullable    = false

  validation {
    condition     = length(var.database_subnet_ids) >= 2 && alltrue([for id in var.database_subnet_ids : can(regex("^subnet-[0-9a-f]+$", id))])
    error_message = "database_subnet_ids must contain at least two subnet IDs (subnet-0123456789abcdef0) in different Availability Zones."
  }
}

variable "workload_security_group_ids" {
  description = "IDs of the security groups the OpenArtifact pods egress from (the node security group, or the pod security groups when you use security groups for pods). Each one is allowed to reach the database on port 5432."
  type        = list(string)
  nullable    = false

  validation {
    condition     = length(var.workload_security_group_ids) >= 1 && alltrue([for id in var.workload_security_group_ids : can(regex("^sg-[0-9a-f]+$", id))])
    error_message = "workload_security_group_ids must contain at least one security group ID (sg-0123456789abcdef0); without it the pods cannot reach the database."
  }
}

variable "namespace" {
  description = "Kubernetes namespace of the release, of the Pod Identity association, of the ExternalSecrets and of the secrets this module writes."
  type        = string
  default     = "openartifact"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$", var.namespace))
    error_message = "namespace must be a valid Kubernetes namespace name (DNS-1123 label: lowercase letters, digits and hyphens, at most 63 characters)."
  }
}

variable "create_namespace" {
  description = "Create the namespace with a kubernetes_namespace_v1 resource (before the secrets and the release, which both need it). Set to false when the namespace already exists."
  type        = bool
  default     = true
  nullable    = false
}

variable "namespace_labels" {
  description = "Labels of the namespace created by this module. The default enforces the Pod Security Standard \"restricted\", which the chart's pods satisfy (non-root uid 10001, read-only root filesystem, all capabilities dropped, RuntimeDefault seccomp). Ignored when create_namespace is false."
  type        = map(string)
  default = {
    "pod-security.kubernetes.io/enforce" = "restricted"
  }
  nullable = false
}

variable "release_name" {
  description = "Helm release name. It is also the Kubernetes service account name (serviceAccount.name) that the EKS Pod Identity association binds to the IAM role."
  type        = string
  default     = "openartifact"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]{0,51}[a-z0-9])?$", var.release_name))
    error_message = "release_name must be a valid Helm release name: lowercase letters, digits and hyphens, at most 53 characters, starting and ending with an alphanumeric character."
  }
}

variable "tags" {
  description = "Tags applied to every AWS resource this module creates."
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "iam_role_permissions_boundary_arn" {
  description = "ARN of an IAM permissions boundary policy for the Pod Identity role. null attaches none."
  type        = string
  default     = null

  validation {
    condition     = var.iam_role_permissions_boundary_arn == null || can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:policy/.+$", coalesce(var.iam_role_permissions_boundary_arn, "x")))
    error_message = "iam_role_permissions_boundary_arn must be an IAM policy ARN."
  }
}

# ---------------------------------------------------------------------------
# Helm release
# ---------------------------------------------------------------------------

variable "chart_repository" {
  description = "Helm repository of the OpenArtifact chart. The official chart is published as an OCI artifact: oci://ghcr.io/openartifact/charts/openartifact."
  type        = string
  default     = "oci://ghcr.io/openartifact/charts"
  nullable    = false

  validation {
    condition     = can(regex("^(oci|https)://[^\\s]+$", var.chart_repository))
    error_message = "chart_repository must be an oci:// or https:// URL."
  }
}

variable "chart_version" {
  description = "Version of the OpenArtifact Helm chart (semantic version, no leading v). Pinned on purpose: chart upgrades can change the default image and need a database backup first. 0.16.2 ships OpenArtifact 0.19.2."
  type        = string
  default     = "0.16.2"
  nullable    = false

  validation {
    condition     = can(regex("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?$", var.chart_version))
    error_message = "chart_version must be a semantic version such as 0.16.2 (no leading v, no range)."
  }
}

variable "image_tag" {
  description = "Container image tag. null uses the chart's appVersion (0.19.2 for chart 0.16.2). Ignored when image_digest is set."
  type        = string
  default     = null

  validation {
    condition     = var.image_tag == null || can(regex("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$", coalesce(var.image_tag, "x")))
    error_message = "image_tag must be a valid container image tag."
  }
}

variable "image_digest" {
  description = "Container image digest (sha256:<64 hex>). When set it wins over image_tag and pins the exact image."
  type        = string
  default     = null

  validation {
    condition     = var.image_digest == null || can(regex("^sha256:[0-9a-f]{64}$", coalesce(var.image_digest, "x")))
    error_message = "image_digest must look like sha256:<64 lowercase hex characters>."
  }
}

variable "helm_timeout_seconds" {
  description = "Seconds the Helm release waits for the Deployments to become ready (the release is atomic: it rolls back on failure)."
  type        = number
  default     = 600
  nullable    = false

  validation {
    condition     = var.helm_timeout_seconds >= 60 && var.helm_timeout_seconds <= 3600 && floor(var.helm_timeout_seconds) == var.helm_timeout_seconds
    error_message = "helm_timeout_seconds must be a whole number between 60 and 3600."
  }
}

variable "extra_values" {
  description = "Additional Helm values documents (YAML strings), merged after the values this module generates (later documents win, maps are merged deeply). Use it for chart options the module does not expose. NEVER put secret material here: it is stored in Terraform state."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for doc in var.extra_values : can(yamldecode(doc))])
    error_message = "Every extra_values entry must be a valid YAML document."
  }
}

# ---------------------------------------------------------------------------
# Application
# ---------------------------------------------------------------------------

variable "base_url" {
  description = "Public base URL of OpenArtifact (BASE_URL), for example https://artifacts.example.com. Required for SSO (OIDC/SAML) callbacks and webhook links; the SAML identifiers derive from it, so do not change it afterwards. null uses https://<ingress.host> when the ingress is enabled, otherwise it is left unset."
  type        = string
  default     = null

  validation {
    condition     = var.base_url == null || can(regex("^https?://[^/\\s]+(/[^\\s]*)?$", coalesce(var.base_url, "x")))
    error_message = "base_url must be an http(s) URL such as https://artifacts.example.com."
  }
}

variable "trusted_proxy_cidrs" {
  description = "CIDRs of the reverse proxies whose X-Forwarded-* headers OpenArtifact trusts (OPENARTIFACT_TRUSTED_PROXIES). null uses the CIDR of the VPC, which covers an ALB in target-type ip mode because it forwards from addresses in the VPC subnets. Narrow it to the ALB subnets when other workloads in the VPC can reach the pods."
  type        = list(string)
  default     = null

  validation {
    condition     = var.trusted_proxy_cidrs == null || (length(coalesce(var.trusted_proxy_cidrs, [])) > 0 && alltrue([for c in coalesce(var.trusted_proxy_cidrs, []) : can(cidrhost(c, 0))]))
    error_message = "trusted_proxy_cidrs must be null or a non-empty list of valid CIDRs."
  }
}

variable "replica_count" {
  description = "Replicas of the web Deployment (the whole server when worker_enabled is false). More than one is fine: blobs live in S3 and the state in PostgreSQL. Ignored while autoscaling.enabled is true."
  type        = number
  default     = 2
  nullable    = false

  validation {
    condition     = var.replica_count >= 1 && floor(var.replica_count) == var.replica_count
    error_message = "replica_count must be a whole number >= 1."
  }
}

variable "worker_enabled" {
  description = "Run the background workers (metadata regeneration, webhooks, scans, federation sync, schedulers) in a separate Deployment with OPENARTIFACT_ROLE=worker; the main Deployment then runs role web. false runs everything in one Deployment (role all)."
  type        = bool
  default     = false
  nullable    = false
}

variable "worker_replica_count" {
  description = "Replicas of the worker Deployment. Only used when worker_enabled is true."
  type        = number
  default     = 1
  nullable    = false

  validation {
    condition     = var.worker_replica_count >= 1 && floor(var.worker_replica_count) == var.worker_replica_count
    error_message = "worker_replica_count must be a whole number >= 1 (a web/worker split needs at least one worker)."
  }
}

variable "resources" {
  description = "Container resources of the web and worker pods (requests and limits). Only the CPU limit is optional: leaving it unset avoids CPU throttling. /tmp spooling uses node ephemeral storage (see tmp_size_limit), not memory."
  type = object({
    requests = object({
      cpu    = string
      memory = string
    })
    limits = object({
      cpu    = optional(string)
      memory = string
    })
  })
  default = {
    requests = {
      cpu    = "500m"
      memory = "1Gi"
    }
    limits = {
      memory = "2Gi"
    }
  }
  nullable = false
}

variable "autoscaling" {
  description = "Horizontal Pod Autoscaler of the web Deployment (chart autoscaling.*). When enabled it owns the replica count and replica_count is ignored."
  type = object({
    enabled            = optional(bool, false)
    min_replicas       = optional(number, 2)
    max_replicas       = optional(number, 6)
    cpu_target_percent = optional(number, 70)
  })
  default  = {}
  nullable = false

  validation {
    condition     = var.autoscaling.min_replicas >= 1 && var.autoscaling.max_replicas >= var.autoscaling.min_replicas && var.autoscaling.cpu_target_percent >= 1 && var.autoscaling.cpu_target_percent <= 100
    error_message = "autoscaling needs min_replicas >= 1, max_replicas >= min_replicas and cpu_target_percent between 1 and 100."
  }
}

variable "pod_disruption_budget_enabled" {
  description = "Create a PodDisruptionBudget (maxUnavailable 1) for the web Deployment. The chart only renders it when more than one replica can run."
  type        = bool
  default     = true
  nullable    = false
}

variable "spread_across_zones" {
  description = "Add a topology spread constraint (maxSkew 1, ScheduleAnyway) that spreads the pods over the availability zones, so one zone outage keeps the service up."
  type        = bool
  default     = true
  nullable    = false
}

variable "pod_annotations" {
  description = "Extra annotations of the OpenArtifact pods, for example to opt in to a secret-reload controller."
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "shutdown_delay_seconds" {
  description = "Seconds the server keeps serving after SIGTERM, with /ready answering 503, before it closes the listener (config.shutdownDelay). It covers the time the ALB and the Service need to stop routing to the terminating pod."
  type        = number
  default     = 15
  nullable    = false

  validation {
    condition     = var.shutdown_delay_seconds >= 0 && var.shutdown_delay_seconds <= 120 && floor(var.shutdown_delay_seconds) == var.shutdown_delay_seconds
    error_message = "shutdown_delay_seconds must be a whole number between 0 and 120."
  }
}

variable "shutdown_timeout_seconds" {
  description = "Seconds in-flight requests get to finish after the listener closes (config.shutdownTimeout, at least 1)."
  type        = number
  default     = 60
  nullable    = false

  validation {
    condition     = var.shutdown_timeout_seconds >= 1 && var.shutdown_timeout_seconds <= 600 && floor(var.shutdown_timeout_seconds) == var.shutdown_timeout_seconds
    error_message = "shutdown_timeout_seconds must be a whole number between 1 and 600."
  }
}

variable "termination_grace_period_seconds" {
  description = "terminationGracePeriodSeconds of the pods. null derives it as shutdown_delay_seconds + shutdown_timeout_seconds + 45 (the chart documents 25 seconds for background-job cancellation, audit and telemetry flush, plus headroom). An explicit value must be at least shutdown_delay_seconds + shutdown_timeout_seconds + 25."
  type        = number
  default     = null

  validation {
    condition     = var.termination_grace_period_seconds == null || coalesce(var.termination_grace_period_seconds, 0) >= var.shutdown_delay_seconds + var.shutdown_timeout_seconds + 25
    error_message = "termination_grace_period_seconds must be at least shutdown_delay_seconds + shutdown_timeout_seconds + 25, or the kubelet kills the server in the middle of its graceful shutdown."
  }
}

variable "tmp_size_limit" {
  description = "Size limit (Kubernetes quantity, for example 50Gi) of the emptyDir mounted at /tmp, where large uploads and proxy downloads are spooled before they reach S3. It uses node ephemeral storage; a pod that exceeds it is evicted."
  type        = string
  default     = "50Gi"
  nullable    = false

  validation {
    condition     = can(regex("^[1-9][0-9]*(Ki|Mi|Gi|Ti)$", var.tmp_size_limit))
    error_message = "tmp_size_limit must be a Kubernetes quantity with a binary suffix, for example 50Gi."
  }
}

variable "enable_metrics_token" {
  description = "Expose /metrics, protected by a bearer token (chart metrics.enabled, METRICS_AUTH_TOKEN) that is generated and stored in Secrets Manager."
  type        = bool
  default     = true
  nullable    = false
}

variable "bootstrap_admin_password_enabled" {
  description = "Create the first admin account from a generated password (chart bootstrap.existingSecret, key admin-password). The server applies it only to an EMPTY database and only reads it from a mounted file. false makes the server print a random password once in its log."
  type        = bool
  default     = true
  nullable    = false
}

variable "bootstrap_admin_token_enabled" {
  description = "Also create an admin API token named bootstrap from a generated secret (chart bootstrap.adminToken.enabled, key admin-token), so automation works on the first sync. Needs bootstrap_admin_password_enabled."
  type        = bool
  default     = false
  nullable    = false

  validation {
    condition     = !var.bootstrap_admin_token_enabled || var.bootstrap_admin_password_enabled
    error_message = "bootstrap_admin_token_enabled requires bootstrap_admin_password_enabled = true (the chart mounts both keys from one secret)."
  }
}

# ---------------------------------------------------------------------------
# Ingress (AWS Load Balancer Controller)
# ---------------------------------------------------------------------------

variable "allowed_ingress_cidrs" {
  description = "CIDRs allowed to reach the load balancer (alb.ingress.kubernetes.io/inbound-cidrs; IPv4 or IPv6). Required, with no default, so the registry is never opened to the Internet by accident: list 0.0.0.0/0 explicitly if you really want a public registry."
  type        = list(string)
  nullable    = false

  validation {
    condition     = length(var.allowed_ingress_cidrs) > 0 && alltrue([for c in var.allowed_ingress_cidrs : can(cidrhost(c, 0))])
    error_message = "allowed_ingress_cidrs must be a non-empty list of valid CIDRs, for example [\"203.0.113.0/24\"]."
  }
}

variable "ingress" {
  description = <<-EOT
    Exposure through the AWS Load Balancer Controller (an ALB, target-type ip). Disabled by default: the Service is then ClusterIP only.
    - enabled: render the chart Ingress.
    - class_name: ingressClassName of the controller (default alb).
    - host: public host name (required when enabled).
    - certificate_arn: ACM certificate ARN for the HTTPS listener (required when enabled).
    - scheme: internet-facing or internal.
    - group_name: share one ALB between Ingresses (alb.ingress.kubernetes.io/group.name).
    - wafv2_acl_arn: WAFv2 web ACL to attach.
    - subnets: subnet IDs or names for the ALB; empty uses the controller's tag-based discovery.
    - ssl_policy: ELB security policy, TLS 1.3 variants only.
    - idle_timeout_seconds: ALB idle timeout; keep it high for large uploads.
    - deletion_protection: ALB deletion protection.
    - annotations: extra annotations merged last (they win over the generated ones).
  EOT
  type = object({
    enabled              = optional(bool, false)
    class_name           = optional(string, "alb")
    host                 = optional(string)
    certificate_arn      = optional(string)
    scheme               = optional(string, "internet-facing")
    group_name           = optional(string)
    wafv2_acl_arn        = optional(string)
    subnets              = optional(list(string), [])
    ssl_policy           = optional(string, "ELBSecurityPolicy-TLS13-1-2-2021-06")
    idle_timeout_seconds = optional(number, 300)
    deletion_protection  = optional(bool, true)
    annotations          = optional(map(string), {})
  })
  default  = {}
  nullable = false

  validation {
    condition     = !var.ingress.enabled || can(regex("^([a-z0-9]([-a-z0-9]*[a-z0-9])?\\.)+[a-z]{2,}$", coalesce(var.ingress.host, "x")))
    error_message = "ingress.host must be a fully qualified lower-case host name when the ingress is enabled."
  }

  validation {
    condition     = !var.ingress.enabled || can(regex("^arn:aws[a-z-]*:acm:[a-z0-9-]+:[0-9]{12}:certificate/[0-9a-f-]+$", coalesce(var.ingress.certificate_arn, "x")))
    error_message = "ingress.certificate_arn must be an ACM certificate ARN when the ingress is enabled."
  }

  validation {
    condition     = contains(["internet-facing", "internal"], var.ingress.scheme)
    error_message = "ingress.scheme must be \"internet-facing\" or \"internal\"."
  }

  validation {
    condition     = can(regex("^ELBSecurityPolicy-TLS13-[0-9A-Za-z-]+$", var.ingress.ssl_policy))
    error_message = "ingress.ssl_policy must be a TLS 1.3 ELB security policy (ELBSecurityPolicy-TLS13-...)."
  }

  validation {
    condition     = var.ingress.idle_timeout_seconds >= 1 && var.ingress.idle_timeout_seconds <= 4000 && floor(var.ingress.idle_timeout_seconds) == var.ingress.idle_timeout_seconds
    error_message = "ingress.idle_timeout_seconds must be a whole number between 1 and 4000."
  }

  validation {
    condition     = var.ingress.wafv2_acl_arn == null || can(regex("^arn:aws[a-z-]*:wafv2:[a-z0-9-]+:[0-9]{12}:regional/webacl/.+$", coalesce(var.ingress.wafv2_acl_arn, "x")))
    error_message = "ingress.wafv2_acl_arn must be a regional WAFv2 web ACL ARN."
  }
}

# ---------------------------------------------------------------------------
# Secret delivery
# ---------------------------------------------------------------------------

variable "secret_delivery" {
  description = <<-EOT
    How the application secrets reach the cluster. They are always generated into AWS Secrets Manager (ephemeral values, never in state) except in "existing".
    - external_secrets: ExternalSecret objects (external-secrets.io/v1) sync Secrets Manager into Kubernetes Secrets. Values never touch Terraform state or the Terraform runner. Needs the External Secrets Operator, a (Cluster)SecretStore (secret_store_name) and the CRDs reachable at plan time.
    - terraform_write_only: Terraform reads the values with an ephemeral resource and writes the Kubernetes Secrets with write-only arguments (data_wo). Values never enter state or plan, but pass through the Terraform runner, and nothing refreshes them: rotation (including the RDS-managed database password) needs secret_data_revision bumped.
    - existing: you create the Kubernetes Secrets (existing_secret_name, existing_db_secret_name, existing_bootstrap_secret_name); this module creates no Secrets Manager secrets.
  EOT
  type        = string
  default     = "external_secrets"
  nullable    = false

  validation {
    condition     = contains(["external_secrets", "terraform_write_only", "existing"], var.secret_delivery)
    error_message = "secret_delivery must be \"external_secrets\", \"terraform_write_only\" or \"existing\"."
  }
}

variable "secret_store_name" {
  description = "Name of the SecretStore or ClusterSecretStore (provider aws, service SecretsManager) the ExternalSecrets read from. Required when secret_delivery is external_secrets. Its identity (Pod Identity or IRSA) needs the policy in the external_secrets_policy_json output."
  type        = string
  default     = null

  validation {
    condition     = var.secret_delivery != "external_secrets" || (var.secret_store_name != null && can(regex("^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$", coalesce(var.secret_store_name, "-"))))
    error_message = "secret_store_name (a DNS-1123 subdomain) is required when secret_delivery is \"external_secrets\"."
  }
}

variable "secret_store_kind" {
  description = "Kind of the store referenced by secret_store_name."
  type        = string
  default     = "ClusterSecretStore"
  nullable    = false

  validation {
    condition     = contains(["SecretStore", "ClusterSecretStore"], var.secret_store_kind)
    error_message = "secret_store_kind must be \"SecretStore\" or \"ClusterSecretStore\"."
  }
}

variable "refresh_interval" {
  description = "How often the External Secrets Operator re-reads Secrets Manager (Go duration, for example 1h). RDS rotates the database password about every 7 days; the pods only read it at start, see the README."
  type        = string
  default     = "1h"
  nullable    = false

  validation {
    condition     = can(regex("^([0-9]+(ms|s|m|h))+$", var.refresh_interval))
    error_message = "refresh_interval must be a Go duration such as 30m or 1h."
  }
}

variable "existing_secret_name" {
  description = "secret_delivery = existing: name of the Kubernetes Secret (in the release namespace) loaded with envFrom, with the keys AUTH_HMAC_KEY, OPENARTIFACT_SECRET_KEY and, with enable_metrics_token, METRICS_AUTH_TOKEN."
  type        = string
  default     = null

  validation {
    condition     = var.secret_delivery != "existing" || can(regex("^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$", coalesce(var.existing_secret_name, "-")))
    error_message = "existing_secret_name (a DNS-1123 subdomain) is required when secret_delivery is \"existing\"."
  }
}

variable "existing_db_secret_name" {
  description = "secret_delivery = existing: name of the Kubernetes Secret holding the database password under the key \"password\" (copy it from the RDS-managed secret, database_master_secret_arn output)."
  type        = string
  default     = null

  validation {
    condition     = var.secret_delivery != "existing" || can(regex("^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$", coalesce(var.existing_db_secret_name, "-")))
    error_message = "existing_db_secret_name (a DNS-1123 subdomain) is required when secret_delivery is \"existing\"."
  }
}

variable "existing_bootstrap_secret_name" {
  description = "secret_delivery = existing: name of the Kubernetes Secret with the keys admin-password and, with bootstrap_admin_token_enabled, admin-token. Required when bootstrap_admin_password_enabled is true."
  type        = string
  default     = null

  validation {
    condition     = var.secret_delivery != "existing" || !var.bootstrap_admin_password_enabled || can(regex("^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$", coalesce(var.existing_bootstrap_secret_name, "-")))
    error_message = "existing_bootstrap_secret_name (a DNS-1123 subdomain) is required when secret_delivery is \"existing\" and bootstrap_admin_password_enabled is true."
  }
}

variable "secret_data_revision" {
  description = "secret_delivery = terraform_write_only: revision counter of the Kubernetes Secrets (data_wo_revision). Write-only values cannot be compared, so Terraform only rewrites the Secrets when this number changes: bump it after the secrets or the RDS-managed database password changed."
  type        = number
  default     = 1
  nullable    = false

  validation {
    condition     = var.secret_data_revision >= 1 && floor(var.secret_data_revision) == var.secret_data_revision
    error_message = "secret_data_revision must be a whole number >= 1."
  }
}

variable "existing_secret_arns" {
  description = "Bring-your-own Secrets Manager secrets (same shape as modules/secrets): every attribute that is set is used as-is and no secret is generated for it. The value must be the plain string the setting expects, not JSON. Ignored when secret_delivery is existing."
  type = object({
    secret_key               = optional(string)
    hmac_key                 = optional(string)
    metrics_token            = optional(string)
    bootstrap_admin_password = optional(string)
    bootstrap_admin_token    = optional(string)
  })
  default  = {}
  nullable = false
}

variable "secret_version" {
  description = "Rotation counter of the generated metrics token, HMAC key and bootstrap secrets (see modules/secrets). It never touches OPENARTIFACT_SECRET_KEY: replacing that key makes every credential OpenArtifact stored permanently unreadable."
  type        = number
  default     = 1
  nullable    = false

  validation {
    condition     = var.secret_version >= 1 && floor(var.secret_version) == var.secret_version
    error_message = "secret_version must be a whole number >= 1."
  }
}

variable "secrets_kms_key_arn" {
  description = "Customer managed KMS key that encrypts the generated secrets. null uses the AWS managed aws/secretsmanager key. The identity that reads them (the External Secrets Operator or the Terraform runner) needs kms:Decrypt on a customer managed key."
  type        = string
  default     = null
}

variable "secrets_recovery_window_in_days" {
  description = "Days Secrets Manager keeps a deleted secret recoverable (7-30), or 0 to delete immediately. Keep the default: a deleted OPENARTIFACT_SECRET_KEY can only be restored inside this window."
  type        = number
  default     = 30
  nullable    = false
}

# ---------------------------------------------------------------------------
# Database (modules/database)
# ---------------------------------------------------------------------------

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.medium"
  nullable    = false
}

variable "db_allocated_storage" {
  description = "Initial RDS storage in GiB."
  type        = number
  default     = 50
  nullable    = false
}

variable "db_max_allocated_storage" {
  description = "Upper limit in GiB for RDS storage autoscaling; 0 disables it."
  type        = number
  default     = 200
  nullable    = false
}

variable "db_engine_version" {
  description = "PostgreSQL major version (16, 17 or 18)."
  type        = string
  default     = "17"
  nullable    = false
}

variable "db_multi_az" {
  description = "Deploy a synchronous standby in a second Availability Zone."
  type        = bool
  default     = true
  nullable    = false
}

variable "db_backup_retention_period" {
  description = "Days to keep automated RDS backups (1-35)."
  type        = number
  default     = 14
  nullable    = false
}

variable "db_deletion_protection" {
  description = "Block deletion of the DB instance through the API."
  type        = bool
  default     = true
  nullable    = false
}

variable "db_skip_final_snapshot" {
  description = "Skip the final DB snapshot on destroy. Keep false in production."
  type        = bool
  default     = false
  nullable    = false
}

variable "db_performance_insights_enabled" {
  description = "Enable Performance Insights (not supported on db.t4g.micro and db.t4g.small)."
  type        = bool
  default     = true
  nullable    = false
}

variable "db_monitoring_interval" {
  description = "Seconds between Enhanced Monitoring samples (0 disables it)."
  type        = number
  default     = 0
  nullable    = false
}

variable "db_apply_immediately" {
  description = "Apply RDS modifications immediately instead of in the maintenance window."
  type        = bool
  default     = false
  nullable    = false
}

variable "db_max_open_conns" {
  description = "Maximum open database connections per pod (chart database.maxOpenConns). Size it so replicas x this value stays below the RDS max_connections. The chart requires 0 (unlimited) or at least 4 because the storage tier mover pins connections."
  type        = number
  default     = 25
  nullable    = false

  validation {
    condition     = var.db_max_open_conns == 0 || (var.db_max_open_conns >= 4 && floor(var.db_max_open_conns) == var.db_max_open_conns)
    error_message = "db_max_open_conns must be 0 or a whole number >= 4."
  }
}

variable "db_sslmode" {
  description = "PostgreSQL SSL mode (DB_SSLMODE). \"require\" encrypts the connection (rds.force_ssl is on) without verifying the server. \"verify-full\" also needs the RDS CA bundle inside the pod, which the shell-less image does not ship: mount it through extra_values (extraVolumes and the PGSSLROOTCERT/sslrootcert setting) before choosing it."
  type        = string
  default     = "require"
  nullable    = false

  validation {
    condition     = contains(["require", "verify-full"], var.db_sslmode)
    error_message = "db_sslmode must be \"require\" or \"verify-full\"."
  }
}

# ---------------------------------------------------------------------------
# Storage (modules/storage)
# ---------------------------------------------------------------------------

variable "s3_bucket_name" {
  description = "Explicit S3 bucket name. null names it \"<name>-blobs-<account_id>-<region>\"."
  type        = string
  default     = null
}

variable "s3_kms_mode" {
  description = "Bucket encryption key: \"cmk\" (dedicated customer managed key, rotation on) or \"aws_managed\" (aws/s3)."
  type        = string
  default     = "cmk"
  nullable    = false
}

variable "s3_versioning_enabled" {
  description = "Keep previous object versions."
  type        = bool
  default     = true
  nullable    = false
}

variable "s3_noncurrent_version_expiration_days" {
  description = "Days after which noncurrent object versions are deleted (needs s3_versioning_enabled)."
  type        = number
  default     = 30
  nullable    = false
}

variable "s3_force_destroy" {
  description = "Delete the bucket with all objects on destroy. Leave false: the bucket holds every stored artifact."
  type        = bool
  default     = false
  nullable    = false
}

variable "s3_access_logging" {
  description = "S3 server access logging to an existing bucket (target_bucket, optional target_prefix); null disables it."
  type = object({
    target_bucket = string
    target_prefix = optional(string, "s3/")
  })
  default = null
}
