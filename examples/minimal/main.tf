# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# The smallest complete deployment: a new VPC with one NAT gateway, one web task, a single-AZ
# database. Good for evaluation and non-production. Deletion protection stays ON (database, load
# balancer): to tear the example down, add db_deletion_protection = false and
# alb_deletion_protection = false (and db_skip_final_snapshot = true to skip the final snapshot) to
# the module call, apply, then destroy.

module "network" {
  # Registry: source = "openartifact/openartifact/aws//modules/network" with version = "~> 0.1"
  source = "../../modules/network"

  name = var.name

  # One NAT gateway is the cheapest layout. Its Availability Zone is a single point of failure for
  # outbound traffic (proxy repositories, image pulls); see examples/complete for one per AZ.
  az_count         = 2
  nat_gateway_mode = "single"

  flow_logs_retention_days = 30
}

module "openartifact" {
  # Registry: source = "openartifact/openartifact/aws" with version = "~> 0.1"
  source = "../.."

  name = var.name

  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids
  public_subnet_ids  = module.network.public_subnet_ids

  certificate_arn       = var.certificate_arn
  allowed_ingress_cidrs = var.allowed_ingress_cidrs
  base_url              = var.base_url

  # One web task, no autoscaling.
  web_desired_count = 1
  web_autoscaling   = { enabled = false }

  # Smallest database: single AZ, no Performance Insights (not available on db.t4g.micro).
  db_instance_class               = "db.t4g.micro"
  db_multi_az                     = false
  db_allocated_storage            = 20
  db_max_allocated_storage        = 100
  db_backup_retention_period      = 7
  db_performance_insights_enabled = false

  log_retention_days = 30
}
