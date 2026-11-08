# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: MPL-2.0

resource "aws_ecs_cluster" "this" {
  name = var.name

  setting {
    name  = "containerInsights"
    value = var.container_insights
  }

  tags = merge(var.tags, { Name = var.name })
}

module "storage" {
  source = "./modules/storage"

  name                               = var.name
  bucket_name                        = var.s3_bucket_name
  kms_mode                           = var.s3_kms_mode
  versioning_enabled                 = var.s3_versioning_enabled
  noncurrent_version_expiration_days = var.s3_noncurrent_version_expiration_days
  access_logging                     = var.s3_access_logging
  force_destroy                      = var.s3_force_destroy
  tags                               = var.tags
}

module "secrets" {
  source = "./modules/secrets"

  name                             = var.name
  kms_key_arn                      = var.secrets_kms_key_arn
  recovery_window_in_days          = var.secrets_recovery_window_in_days
  secret_version                   = var.secret_version
  existing_secret_arns             = var.existing_secret_arns
  metrics_token_enabled            = var.enable_metrics_token
  bootstrap_admin_password_enabled = var.bootstrap_admin_password_enabled
  # The server reads the admin token only from a file, which a Fargate task cannot mount.
  bootstrap_admin_token_enabled = false
  tags                          = var.tags
}

module "database" {
  source = "./modules/database"

  name       = var.name
  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids
  # The service security groups are created by modules/ecs-service; their IDs are only known after
  # apply, so the module relies on the list length (count), never on the values.
  allowed_security_group_ids   = concat([module.web.security_group_id], module.worker[*].security_group_id)
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

# ECS on EC2: the container instances and their capacity providers. Created only with
# capacity_type = "EC2"; with Fargate the cluster has no capacity providers at all.
module "ec2_capacity" {
  source = "./modules/ecs-ec2-capacity"
  count  = local.ec2 ? 1 : 0

  name             = var.name
  cluster_name     = aws_ecs_cluster.this.name
  vpc_id           = var.vpc_id
  subnet_ids       = var.private_subnet_ids
  cpu_architecture = var.cpu_architecture

  instance_types       = var.ec2_capacity.instance_types
  ami_id               = var.ec2_capacity.ami_id
  min_size             = var.ec2_capacity.min_size
  max_size             = var.ec2_capacity.max_size
  spot_enabled         = var.ec2_capacity.spot_percentage.web > 0
  root_volume_size_gib = var.ec2_capacity.root_volume_size_gib
  kms_key_arn          = var.ec2_capacity.kms_key_arn
  target_capacity      = var.ec2_capacity.target_capacity

  # The agent mounts EFS volumes on the instance, so NFS leaves the instance security group.
  egress_security_group_rules = var.persistent_volume.enabled ? [
    {
      security_group_id = module.efs[0].security_group_id
      port              = 2049
      description       = "NFS to the EFS mount targets"
    }
  ] : []

  tags = var.tags
}

# Optional persistent volume shared by the web and worker tasks.
module "efs" {
  source = "./modules/efs"
  count  = var.persistent_volume.enabled ? 1 : 0

  name       = var.name
  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids
  # The security groups are created by modules/ecs-service and modules/ecs-ec2-capacity; their IDs
  # are only known after apply, so the module relies on the list length (count), never on the values.
  allowed_security_group_ids      = local.efs_allowed_security_group_ids
  kms_key_arn                     = var.persistent_volume.kms_key_arn
  performance_mode                = var.persistent_volume.performance_mode
  throughput_mode                 = var.persistent_volume.throughput_mode
  provisioned_throughput_in_mibps = var.persistent_volume.provisioned_throughput_in_mibps
  transition_to_ia                = var.persistent_volume.transition_to_ia
  backup_policy_enabled           = var.persistent_volume.backup_policy_enabled
  tags                            = var.tags

  access_points = {
    for name, use in local.persistent_uses : use.access_point => { path = use.path }
  }
}

module "web" {
  source = "./modules/ecs-service"

  name                              = var.name
  cluster_arn                       = aws_ecs_cluster.this.arn
  cluster_name                      = aws_ecs_cluster.this.name
  vpc_id                            = var.vpc_id
  subnet_ids                        = var.private_subnet_ids
  assign_public_ip                  = var.assign_public_ip
  capacity_provider_strategy        = local.web_capacity_provider_strategy
  efs_volumes                       = local.efs_volumes
  image                             = local.image
  role                              = local.web_role
  cpu_architecture                  = var.cpu_architecture
  cpu                               = var.web_cpu
  memory                            = var.web_memory
  ephemeral_storage_gib             = var.ephemeral_storage_gib
  container_port                    = local.container_port
  desired_count                     = var.web_desired_count
  environment                       = local.environment
  secrets                           = local.secrets
  execution_secret_arns             = local.execution_secret_arns
  execution_kms_key_arns            = local.execution_kms_key_arns
  task_role_policy_json             = module.storage.access_policy_json
  target_group_arn                  = local.web_target_group_arn
  ingress_security_group_ids        = [aws_security_group.alb.id]
  egress_security_group_rules       = local.database_egress_rules
  shutdown_delay_seconds            = var.shutdown_delay_seconds
  shutdown_timeout_seconds          = var.shutdown_timeout_seconds
  health_check_grace_period_seconds = var.health_check_grace_period_seconds
  log_retention_days                = var.log_retention_days
  log_kms_key_arn                   = var.log_kms_key_arn
  enable_execute_command            = var.enable_execute_command
  redeploy_on_secret_rotation_arns  = local.redeploy_on_secret_rotation_arns
  tags                              = var.tags

  autoscaling = {
    enabled               = var.web_autoscaling.enabled
    min_capacity          = var.web_autoscaling.min_capacity
    max_capacity          = var.web_autoscaling.max_capacity
    cpu_target_percent    = var.web_autoscaling.cpu_target_percent
    memory_target_percent = var.web_autoscaling.memory_target_percent
    requests_per_target   = var.web_autoscaling.requests_per_target
    alb_resource_label    = var.web_autoscaling.requests_per_target != null ? local.alb_resource_label : null
    scale_in_cooldown     = var.web_autoscaling.scale_in_cooldown
    scale_out_cooldown    = var.web_autoscaling.scale_out_cooldown
  }
}

module "worker" {
  source = "./modules/ecs-service"
  count  = var.worker_enabled ? 1 : 0

  name                             = "${var.name}-worker"
  cluster_arn                      = aws_ecs_cluster.this.arn
  cluster_name                     = aws_ecs_cluster.this.name
  vpc_id                           = var.vpc_id
  subnet_ids                       = var.private_subnet_ids
  assign_public_ip                 = var.assign_public_ip
  capacity_provider_strategy       = local.worker_capacity_provider_strategy
  efs_volumes                      = local.efs_volumes
  image                            = local.image
  role                             = "worker"
  cpu_architecture                 = var.cpu_architecture
  cpu                              = var.worker_cpu
  memory                           = var.worker_memory
  ephemeral_storage_gib            = var.ephemeral_storage_gib
  container_port                   = local.container_port
  desired_count                    = var.worker_desired_count
  environment                      = local.environment
  secrets                          = local.secrets
  execution_secret_arns            = local.execution_secret_arns
  execution_kms_key_arns           = local.execution_kms_key_arns
  task_role_policy_json            = module.storage.access_policy_json
  target_group_arn                 = null
  egress_security_group_rules      = local.database_egress_rules
  shutdown_delay_seconds           = var.shutdown_delay_seconds
  shutdown_timeout_seconds         = var.shutdown_timeout_seconds
  log_retention_days               = var.log_retention_days
  log_kms_key_arn                  = var.log_kms_key_arn
  enable_execute_command           = var.enable_execute_command
  redeploy_on_secret_rotation_arns = local.redeploy_on_secret_rotation_arns
  tags                             = var.tags

  autoscaling = {
    enabled               = var.worker_autoscaling.enabled
    min_capacity          = var.worker_autoscaling.min_capacity
    max_capacity          = var.worker_autoscaling.max_capacity
    cpu_target_percent    = var.worker_autoscaling.cpu_target_percent
    memory_target_percent = var.worker_autoscaling.memory_target_percent
    scale_in_cooldown     = var.worker_autoscaling.scale_in_cooldown
    scale_out_cooldown    = var.worker_autoscaling.scale_out_cooldown
  }
}
