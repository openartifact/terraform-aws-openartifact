# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: MPL-2.0

locals {
  region               = data.aws_region.current.region
  service_account_name = var.release_name

  external_secrets = var.secret_delivery == "external_secrets"
  write_only       = var.secret_delivery == "terraform_write_only"
  existing_secrets = var.secret_delivery == "existing"

  # Names of the Kubernetes Secrets the chart reads. In "existing" mode they are the caller's;
  # otherwise this module owns them (ExternalSecret targets or write-only Secrets).
  app_secret_name       = local.existing_secrets ? var.existing_secret_name : "${var.release_name}-app"
  db_secret_name        = local.existing_secrets ? var.existing_db_secret_name : "${var.release_name}-db"
  bootstrap_secret_name = local.existing_secrets ? var.existing_bootstrap_secret_name : "${var.release_name}-bootstrap"
  db_password_key       = "password"

  # Kubernetes Secret key -> logical name of the Secrets Manager secret it is read from.
  app_secret_sources = merge(
    {
      OPENARTIFACT_SECRET_KEY = "secret_key"
      AUTH_HMAC_KEY           = "hmac_key"
    },
    var.enable_metrics_token ? { METRICS_AUTH_TOKEN = "metrics_token" } : {},
  )
  bootstrap_secret_sources = merge(
    var.bootstrap_admin_password_enabled ? { "admin-password" = "bootstrap_admin_password" } : {},
    var.bootstrap_admin_token_enabled ? { "admin-token" = "bootstrap_admin_token" } : {},
  )

  # Logical name -> Secrets Manager secret ARN (created or bring-your-own). The keys depend on
  # variables only, so they are known at plan time even while the ARNs are not.
  generated_secret_arns = local.existing_secrets ? {} : merge(
    {
      secret_key = module.secrets[0].secret_key_arn
      hmac_key   = module.secrets[0].hmac_key_arn
    },
    var.enable_metrics_token ? { metrics_token = module.secrets[0].metrics_token_arn } : {},
    var.bootstrap_admin_password_enabled ? { bootstrap_admin_password = module.secrets[0].bootstrap_admin_password_arn } : {},
    var.bootstrap_admin_token_enabled ? { bootstrap_admin_token = module.secrets[0].bootstrap_admin_token_arn } : {},
  )

  # Every Secrets Manager secret the cluster side reads, for the access policy output.
  readable_secret_arns = local.existing_secrets ? [module.database.master_user_secret_arn] : concat(
    values(local.generated_secret_arns),
    [module.database.master_user_secret_arn],
  )
  readable_kms_key_arns = concat(
    [module.database.kms_key_arn],
    local.existing_secrets || var.secrets_kms_key_arn == null ? [] : [var.secrets_kms_key_arn],
  )

  # Shape shared by the ExternalSecret manifests: target Secret name + (key -> remote reference).
  external_secret_specs = local.external_secrets ? merge(
    {
      app = {
        target = local.app_secret_name
        data = {
          for key, logical in local.app_secret_sources :
          key => { key = local.generated_secret_arns[logical], property = "" }
        }
      }
      database = {
        target = local.db_secret_name
        # The RDS-managed secret is JSON {username, password}.
        data = { (local.db_password_key) = { key = module.database.master_user_secret_arn, property = "password" } }
      }
    },
    var.bootstrap_admin_password_enabled ? {
      bootstrap = {
        target = local.bootstrap_secret_name
        data = {
          for key, logical in local.bootstrap_secret_sources :
          key => { key = local.generated_secret_arns[logical], property = "" }
        }
      }
    } : {},
  ) : {}

  # Terraform-write-only delivery: logical name -> ARN read by the ephemeral resource.
  write_only_source_arns = local.write_only ? merge(
    local.generated_secret_arns,
    { db_password = module.database.master_user_secret_arn },
  ) : {}
}
