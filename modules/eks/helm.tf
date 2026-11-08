# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: MPL-2.0

locals {
  base_url            = var.base_url != null ? var.base_url : (var.ingress.enabled ? "https://${var.ingress.host}" : "")
  trusted_proxy_cidrs = var.trusted_proxy_cidrs != null ? var.trusted_proxy_cidrs : [data.aws_vpc.selected.cidr_block]

  # Delay (pod not ready, still serving) + request drain + background-job cancellation, audit and
  # telemetry flush (25 s per the chart) + 20 s headroom: with the 10/30 chart defaults this is
  # the chart's own 85.
  termination_grace_period_seconds = coalesce(
    var.termination_grace_period_seconds,
    var.shutdown_delay_seconds + var.shutdown_timeout_seconds + 45,
  )

  resources_values = {
    requests = var.resources.requests
    limits   = { for k, v in { cpu = var.resources.limits.cpu, memory = var.resources.limits.memory } : k => v if v != null }
  }

  # Selector of the web pods (chart labels; nameOverride is not set).
  spread_constraints = var.spread_across_zones ? [
    {
      maxSkew           = 1
      topologyKey       = "topology.kubernetes.io/zone"
      whenUnsatisfiable = "ScheduleAnyway"
      labelSelector = {
        matchLabels = {
          "app.kubernetes.io/name"     = "openartifact"
          "app.kubernetes.io/instance" = var.release_name
        }
      }
    },
  ] : []

  # AWS Load Balancer Controller annotations (ingress class alb, target-type ip).
  ingress_annotations = !var.ingress.enabled ? {} : merge(
    {
      "alb.ingress.kubernetes.io/scheme"                  = var.ingress.scheme
      "alb.ingress.kubernetes.io/target-type"             = "ip"
      "alb.ingress.kubernetes.io/certificate-arn"         = var.ingress.certificate_arn
      "alb.ingress.kubernetes.io/listen-ports"            = jsonencode([{ HTTP = 80 }, { HTTPS = 443 }])
      "alb.ingress.kubernetes.io/ssl-redirect"            = "443"
      "alb.ingress.kubernetes.io/ssl-policy"              = var.ingress.ssl_policy
      "alb.ingress.kubernetes.io/healthcheck-path"        = "/ready"
      "alb.ingress.kubernetes.io/inbound-cidrs"           = join(",", var.allowed_ingress_cidrs)
      "alb.ingress.kubernetes.io/target-group-attributes" = "deregistration_delay.timeout_seconds=${min(3600, var.shutdown_delay_seconds + var.shutdown_timeout_seconds)}"
      "alb.ingress.kubernetes.io/load-balancer-attributes" = join(",", [
        "idle_timeout.timeout_seconds=${var.ingress.idle_timeout_seconds}",
        "routing.http.drop_invalid_header_fields.enabled=true",
        "deletion_protection.enabled=${var.ingress.deletion_protection}",
      ])
    },
    var.ingress.group_name == null ? {} : { "alb.ingress.kubernetes.io/group.name" = var.ingress.group_name },
    var.ingress.wafv2_acl_arn == null ? {} : { "alb.ingress.kubernetes.io/wafv2-acl-arn" = var.ingress.wafv2_acl_arn },
    length(var.ingress.subnets) == 0 ? {} : { "alb.ingress.kubernetes.io/subnets" = join(",", var.ingress.subnets) },
    var.ingress.annotations,
  )

  # Chart values. They hold references (Secret names, ARN-free endpoints) and never a secret
  # value: the Secrets are delivered out of band (see secrets.tf).
  values = {
    image = merge(
      var.image_tag == null ? {} : { tag = var.image_tag },
      var.image_digest == null ? {} : { digest = var.image_digest },
    )

    baseUrl = local.base_url

    replicaCount = var.replica_count
    worker = {
      enabled      = var.worker_enabled
      replicaCount = var.worker_replica_count
    }

    autoscaling = {
      enabled                        = var.autoscaling.enabled
      minReplicas                    = var.autoscaling.min_replicas
      maxReplicas                    = var.autoscaling.max_replicas
      targetCPUUtilizationPercentage = var.autoscaling.cpu_target_percent
    }
    podDisruptionBudget = {
      enabled        = var.pod_disruption_budget_enabled
      maxUnavailable = 1
    }

    resources                 = local.resources_values
    topologySpreadConstraints = local.spread_constraints
    podAnnotations            = var.pod_annotations

    terminationGracePeriodSeconds = local.termination_grace_period_seconds

    config = {
      logFormat       = "json"
      trustedProxies  = local.trusted_proxy_cidrs
      shutdownDelay   = var.shutdown_delay_seconds
      shutdownTimeout = var.shutdown_timeout_seconds
    }

    # Blobs live in S3 (credentials from EKS Pod Identity: no keys in the chart) and the state in
    # PostgreSQL, so the pods are stateless: no PVC is rendered for the object storage backend and
    # the scratch volumes are emptyDirs.
    storage = {
      type   = "s3"
      bucket = module.storage.bucket_id
      region = module.storage.bucket_region
    }
    persistence = {
      enabled = false
    }
    tmp = {
      sizeLimit = var.tmp_size_limit
    }

    database = {
      sslMode      = var.db_sslmode
      maxOpenConns = var.db_max_open_conns
      external = {
        host                      = module.database.endpoint
        port                      = module.database.port
        name                      = module.database.database_name
        user                      = module.database.master_username
        existingSecret            = local.db_secret_name
        existingSecretPasswordKey = local.db_password_key
      }
    }

    # Secrets are Kubernetes Secrets named here and filled elsewhere: no value in these values.
    secrets = {
      existingSecret = local.app_secret_name
    }
    bootstrap = merge(
      var.bootstrap_admin_password_enabled ? { existingSecret = local.bootstrap_secret_name } : {},
      { adminToken = { enabled = var.bootstrap_admin_token_enabled } },
    )
    metrics = {
      enabled = var.enable_metrics_token
    }

    # Pod Identity binds the IAM role to this service account name. The EKS Pod Identity webhook
    # injects its own projected token volume, so the API token needs no automount.
    serviceAccount = {
      create                       = true
      name                         = local.service_account_name
      automountServiceAccountToken = false
    }

    ingress = {
      enabled     = var.ingress.enabled
      className   = var.ingress.class_name
      annotations = local.ingress_annotations
      hosts = var.ingress.enabled ? [
        {
          host  = var.ingress.host
          paths = [{ path = "/", pathType = "Prefix" }]
        },
      ] : []
    }
  }
}

resource "helm_release" "openartifact" {
  name       = var.release_name
  namespace  = var.namespace
  repository = var.chart_repository
  chart      = "openartifact"
  version    = var.chart_version

  # The namespace is created by kubernetes_namespace_v1 (the secrets need it first).
  create_namespace = false
  wait             = true
  atomic           = true
  cleanup_on_fail  = true
  timeout          = var.helm_timeout_seconds
  max_history      = 10

  values = concat([yamlencode(local.values)], var.extra_values)

  # The pods need the Pod Identity association (S3) and their Secrets to become ready.
  depends_on = [
    kubernetes_namespace_v1.this,
    aws_eks_pod_identity_association.this,
    aws_iam_role_policy.blob_storage,
    kubernetes_manifest.external_secret,
    kubernetes_secret_v1.app,
    kubernetes_secret_v1.database,
    kubernetes_secret_v1.bootstrap,
    module.database,
  ]
}
