# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: MPL-2.0

# The minimal deployment on ECS container instances instead of Fargate (capacity_type = "EC2"),
# with an EFS volume (persistent_volume) for the scanner database cache and the in-application
# backups, which Fargate-only deployments do not have. Deletion protection stays ON (database, load
# balancer): to tear the example down, add db_deletion_protection = false and
# alb_deletion_protection = false (and db_skip_final_snapshot = true to skip the final snapshot) to
# the module call, apply, then destroy.

module "network" {
  # Registry: source = "openartifact/openartifact/aws//modules/network" with version = "~> 0.2"
  source = "../../modules/network"

  name = var.name

  # One NAT gateway is the cheapest layout. Its Availability Zone is a single point of failure for
  # outbound traffic (proxy repositories, image pulls); see examples/complete for one per AZ.
  az_count         = 2
  nat_gateway_mode = "single"

  flow_logs_retention_days = 30
}

module "openartifact" {
  # Registry: source = "openartifact/openartifact/aws" with version = "~> 0.2"
  source = "../.."

  name = var.name

  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids
  public_subnet_ids  = module.network.public_subnet_ids

  certificate_arn       = var.certificate_arn
  allowed_ingress_cidrs = var.allowed_ingress_cidrs
  base_url              = var.base_url

  # Tasks run on Graviton container instances in an Auto Scaling group behind an ECS capacity
  # provider. ECS managed scaling adds and removes instances as tasks need them.
  capacity_type    = "EC2"
  cpu_architecture = "ARM64"

  ec2_capacity = {
    # Preferred type first. A large instance (2 vCPU, 8 GiB, three network interfaces) fits two
    # 1 vCPU / 2 GiB awsvpc tasks: one interface per task plus the instance's own.
    instance_types       = ["m7g.large", "m6g.large"]
    min_size             = 1
    max_size             = 3
    root_volume_size_gib = 100

    # Spot for a share of the web tasks beyond the first (never the worker):
    # spot_percentage = { web = 50 }
  }

  # Encrypted EFS volume shared by every task: scanner databases (about 5 GB with Trivy and
  # Grype) and backups survive task and instance replacement.
  persistent_volume = {
    enabled              = true
    scanner_auto_install = true # the server downloads trivy and grype into the volume
  }

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
