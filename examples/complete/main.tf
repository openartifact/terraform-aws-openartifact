# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: MPL-2.0

# A production-shaped deployment: three Availability Zones with a NAT gateway each, separate web
# and worker services with autoscaling, a Multi-AZ database with Performance Insights and Enhanced
# Monitoring, a WAFv2 web ACL on the ALB, and access logs for the load balancer and the blob bucket
# in dedicated buckets, with customer-managed KMS keys for logs and secrets (see logging.tf and
# waf.tf).

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  # The blob bucket name is spelled out (the module's default) so the access log bucket policy
  # can name its source without depending on the module.
  blob_bucket_name = "${var.name}-blobs-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.region}"
}

module "network" {
  # Registry: source = "openartifact/openartifact/aws//modules/network" with version = "~> 0.1"
  source = "../../modules/network"

  name = var.name

  az_count         = 3
  nat_gateway_mode = "per_az"

  flow_logs_retention_days = 365
  flow_logs_kms_key_arn    = aws_kms_key.logs.arn
}

module "openartifact" {
  # Registry: source = "openartifact/openartifact/aws" with version = "~> 0.1"
  source = "../.."

  name = var.name

  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids
  public_subnet_ids  = module.network.public_subnet_ids

  # Load balancer: HTTPS with a WAF in front and access logs. The bucket policy exists before the
  # ALB because the bucket name is taken from the policy resource.
  certificate_arn        = var.certificate_arn
  allowed_ingress_cidrs  = var.allowed_ingress_cidrs
  waf_acl_arn            = aws_wafv2_web_acl.this.arn
  waf_acl_enabled        = true # the ARN is only known after apply
  alb_access_logs_bucket = { bucket = aws_s3_bucket_policy.access_logs["alb"].bucket, prefix = "alb" }

  base_url     = var.base_url
  image_digest = var.image_digest

  # Web and worker run as separate services; the web service autoscales on CPU and on requests
  # per target (the module builds the ALB resource label).
  worker_enabled       = true
  worker_desired_count = 2
  web_cpu              = 2048
  web_memory           = 4096
  worker_cpu           = 1024
  worker_memory        = 2048

  web_desired_count = 3
  web_autoscaling = {
    enabled             = true
    min_capacity        = 3
    max_capacity        = 12
    cpu_target_percent  = 60
    requests_per_target = 1000
  }

  # Multi-AZ database (the module default) with Performance Insights and Enhanced Monitoring.
  db_instance_class               = "db.m7g.large"
  db_multi_az                     = true
  db_performance_insights_enabled = true
  db_monitoring_interval          = 60
  db_backup_retention_period      = 35

  # Customer-managed keys for the application secrets and every log group of the services.
  secrets_kms_key_arn = aws_kms_key.secrets.arn
  log_kms_key_arn     = aws_kms_key.logs.arn
  log_retention_days  = var.log_retention_days

  # Server access logs of the blob bucket go to the dedicated bucket.
  s3_bucket_name = local.blob_bucket_name
  s3_access_logging = {
    target_bucket = aws_s3_bucket_policy.access_logs["s3"].bucket
    target_prefix = "blobs/"
  }
}
