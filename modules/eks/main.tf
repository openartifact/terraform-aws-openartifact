# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

data "aws_region" "current" {}

data "aws_vpc" "selected" {
  id = var.vpc_id
}

# ---------------------------------------------------------------------------
# AWS building blocks: blob storage, database, generated secrets
# ---------------------------------------------------------------------------

module "storage" {
  source = "../storage"

  name                               = var.name
  bucket_name                        = var.s3_bucket_name
  kms_mode                           = var.s3_kms_mode
  versioning_enabled                 = var.s3_versioning_enabled
  noncurrent_version_expiration_days = var.s3_noncurrent_version_expiration_days
  access_logging                     = var.s3_access_logging
  force_destroy                      = var.s3_force_destroy
  tags                               = var.tags
}

module "database" {
  source = "../database"

  name                         = var.name
  vpc_id                       = var.vpc_id
  subnet_ids                   = var.database_subnet_ids
  allowed_security_group_ids   = var.workload_security_group_ids
  engine_version               = var.db_engine_version
  instance_class               = var.db_instance_class
  allocated_storage            = var.db_allocated_storage
  max_allocated_storage        = var.db_max_allocated_storage
  multi_az                     = var.db_multi_az
  backup_retention_period      = var.db_backup_retention_period
  deletion_protection          = var.db_deletion_protection
  skip_final_snapshot          = var.db_skip_final_snapshot
  performance_insights_enabled = var.db_performance_insights_enabled
  monitoring_interval          = var.db_monitoring_interval
  apply_immediately            = var.db_apply_immediately
  tags                         = var.tags
}

# With secret_delivery = "existing" the caller owns the Kubernetes Secrets, so nothing is
# generated in Secrets Manager.
module "secrets" {
  source = "../secrets"
  count  = local.existing_secrets ? 0 : 1

  name                             = var.name
  kms_key_arn                      = var.secrets_kms_key_arn
  recovery_window_in_days          = var.secrets_recovery_window_in_days
  secret_version                   = var.secret_version
  existing_secret_arns             = var.existing_secret_arns
  metrics_token_enabled            = var.enable_metrics_token
  bootstrap_admin_password_enabled = var.bootstrap_admin_password_enabled
  bootstrap_admin_token_enabled    = var.bootstrap_admin_token_enabled
  tags                             = var.tags
}

# ---------------------------------------------------------------------------
# Namespace
# ---------------------------------------------------------------------------

# Created here (not by helm_release.create_namespace) because the ExternalSecrets or the
# write-only Secrets must exist in it before the chart's pods start.
resource "kubernetes_namespace_v1" "this" {
  count = var.create_namespace ? 1 : 0

  metadata {
    name   = var.namespace
    labels = var.namespace_labels
  }
}

# ---------------------------------------------------------------------------
# Non-fatal preflight checks (warnings, never errors)
# ---------------------------------------------------------------------------

check "pod_identity_agent_addon" {
  # A failing scoped data source is reported as a warning only.
  data "aws_eks_addon" "pod_identity_agent" {
    cluster_name = var.cluster_name
    addon_name   = "eks-pod-identity-agent"
  }

  assert {
    condition     = data.aws_eks_addon.pod_identity_agent.addon_version != ""
    error_message = "The eks-pod-identity-agent add-on was not found on cluster ${var.cluster_name}. Without it the pods get no AWS credentials and cannot reach S3. Install the add-on (not needed on EKS Auto Mode, which has the agent built in)."
  }
}

check "base_url_https" {
  assert {
    condition     = var.base_url == null || startswith(coalesce(var.base_url, ""), "https://")
    error_message = "base_url is not an https:// URL. Session cookies are only marked Secure over HTTPS and SSO callbacks need HTTPS."
  }
}

check "public_exposure" {
  assert {
    condition     = !var.ingress.enabled || var.ingress.scheme != "internet-facing" || !contains(var.allowed_ingress_cidrs, "0.0.0.0/0")
    error_message = "The ingress is internet-facing and allowed_ingress_cidrs contains 0.0.0.0/0: the registry login and API are reachable from the whole Internet. Restrict the CIDRs or put a WAF in front (ingress.wafv2_acl_arn)."
  }
}
