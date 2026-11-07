# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

data "aws_vpc" "this" {
  # Only needed for the default trusted proxy CIDR; the count depends on a variable, never on a
  # value that is unknown at plan time.
  count = var.trusted_proxy_cidrs == null ? 1 : 0

  id = var.vpc_id
}

locals {
  # The container port is fixed: the image listens on 8080 and the ALB, the security groups and
  # the health checks all use it.
  container_port = 8080

  # Database port of RDS PostgreSQL (modules/database does not make it configurable).
  database_port = 5432

  # An image digest wins over the tag.
  image = var.image_digest != null ? "${var.image_repository}@${var.image_digest}" : "${var.image_repository}:${var.image_tag}"

  # With a separate worker the web service only serves HTTP; otherwise one service does both.
  web_role = var.worker_enabled ? "web" : "all"

  ec2 = var.capacity_type == "EC2"

  # Capacity provider strategies (empty: Fargate). The web service sends spot_percentage.web percent
  # of its tasks beyond the first to the Spot provider; the worker always runs On-Demand.
  spot_web_percentage = local.ec2 ? var.ec2_capacity.spot_percentage.web : 0
  capacity_providers  = local.ec2 ? module.ec2_capacity[0].capacity_provider_names : null
  web_capacity_provider_strategy = !local.ec2 ? [] : (
    local.spot_web_percentage == 0
    ? [{ capacity_provider = local.capacity_providers.on_demand, weight = 1, base = 0 }]
    : [
      { capacity_provider = local.capacity_providers.on_demand, weight = 100 - local.spot_web_percentage, base = 1 },
      { capacity_provider = local.capacity_providers.spot, weight = local.spot_web_percentage, base = 0 },
    ]
  )
  worker_capacity_provider_strategy = !local.ec2 ? [] : [
    { capacity_provider = local.capacity_providers.on_demand, weight = 1, base = 0 }
  ]

  # Persistent EFS volume: one access point and one container path per enabled use. The scanner
  # cache needs exec (auto-installed binaries run from <path>/bin), which EFS mounts allow.
  persistent_uses = var.persistent_volume.enabled ? merge(
    var.persistent_volume.scanner_cache ? {
      scanner-cache = { access_point = "scanner_cache", path = "/scanner-cache", container_path = "/var/cache/openartifact/scanners" }
    } : {},
    var.persistent_volume.backups ? {
      backups = { access_point = "backups", path = "/backups", container_path = "/var/lib/openartifact/backups" }
    } : {},
  ) : {}

  efs_volumes = [
    for name, use in local.persistent_uses : {
      name             = name
      container_path   = use.container_path
      file_system_id   = module.efs[0].file_system_id
      file_system_arn  = module.efs[0].file_system_arn
      access_point_id  = module.efs[0].access_points[use.access_point].id
      access_point_arn = module.efs[0].access_points[use.access_point].arn
    }
  ]

  # Set only when the directory is mounted; user-supplied extra_environment still wins.
  persistent_environment = merge(
    contains(keys(local.persistent_uses), "scanner-cache") ? { OPENARTIFACT_SCANNER_CACHE_DIR = local.persistent_uses["scanner-cache"].container_path } : {},
    contains(keys(local.persistent_uses), "scanner-cache") && var.persistent_volume.scanner_auto_install ? {
      OPENARTIFACT_TRIVY_INSTALL = "auto"
      OPENARTIFACT_GRYPE_INSTALL = "auto"
    } : {},
    contains(keys(local.persistent_uses), "backups") ? { OPENARTIFACT_BACKUP_DIR = local.persistent_uses["backups"].container_path } : {},
  )

  # The EFS mount targets accept the task security groups and, on EC2, the container instances:
  # there the ECS agent mounts the file system on the instance.
  #
  # Index the module instances (never splat the whole module call, which depends on every resource
  # of the module): the services depend on the file system, so a reference to all of module.worker
  # would be a dependency cycle.
  efs_allowed_security_group_ids = concat(
    [module.web.security_group_id],
    var.worker_enabled ? [module.worker[0].security_group_id] : [],
    local.ec2 ? [module.ec2_capacity[0].security_group_id] : [],
  )

  alb_subnet_ids = var.internal ? var.private_subnet_ids : var.public_subnet_ids

  deregistration_delay = coalesce(var.alb_deregistration_delay_seconds, var.shutdown_delay_seconds + var.shutdown_timeout_seconds)

  # The ALB nodes connect from the ALB subnets, which are inside the VPC CIDR.
  trusted_proxy_cidrs = var.trusted_proxy_cidrs != null ? var.trusted_proxy_cidrs : [one(data.aws_vpc.this[*].cidr_block)]

  # Module-managed variables first, then the user's extra_environment (which cannot contain the
  # reserved keys, but may tune LOG_FORMAT, LOG_LEVEL or SERVER_IDLE_TIMEOUT). No static AWS
  # credentials: S3 access uses the ECS task role.
  environment = merge(
    {
      STORAGE_BACKEND = "s3"
      STORAGE_BUCKET  = module.storage.bucket_id
      STORAGE_REGION  = module.storage.bucket_region

      DB_HOST           = module.database.endpoint
      DB_PORT           = tostring(module.database.port)
      DB_NAME           = module.database.database_name
      DB_USER           = module.database.master_username
      DB_SSLMODE        = var.db_sslmode
      DB_MAX_OPEN_CONNS = tostring(var.db_max_open_conns)

      LOG_FORMAT = "json"

      # Keep-alive connections must outlive the ALB idle timeout, otherwise the server closes a
      # connection the ALB is about to reuse and the client sees a 502.
      SERVER_IDLE_TIMEOUT = tostring(var.alb_idle_timeout + 60)
    },
    var.base_url != null ? { BASE_URL = var.base_url } : {},
    length(local.trusted_proxy_cidrs) > 0 ? { OPENARTIFACT_TRUSTED_PROXIES = join(",", local.trusted_proxy_cidrs) } : {},
    local.persistent_environment,
    var.extra_environment,
  )

  # Environment variable name to Secrets Manager valueFrom. The RDS-managed master secret is a
  # JSON document {username, password}; ECS extracts one key with the ":<key>::" suffix.
  secrets = merge(
    module.secrets.secret_arns_by_env,
    { DB_PASSWORD = "${module.database.master_user_secret_arn}:password::" },
  )

  # The execution role reads the generated or existing application secrets and the RDS master
  # secret, and decrypts them with the customer-managed keys. The database key always exists
  # (modules/database creates a dedicated one); the secrets key only when the caller supplies it.
  execution_secret_arns  = concat(module.secrets.secret_arns, [module.database.master_user_secret_arn])
  execution_kms_key_arns = concat([module.database.kms_key_arn], var.secrets_kms_key_arn == null ? [] : [var.secrets_kms_key_arn])

  # The task security groups only reach the database security group on its port (plus HTTPS
  # egress, which modules/ecs-service adds itself).
  database_egress_rules = [
    {
      security_group_id = module.database.security_group_id
      port              = local.database_port
      description       = "PostgreSQL to the database"
    }
  ]

  redeploy_on_secret_rotation_arns = var.redeploy_on_db_secret_rotation ? [module.database.master_user_secret_arn] : []

  # Only the web service has a load balancer, so only it can scale on requests per target.
  alb_resource_label = "${aws_lb.this.arn_suffix}/${aws_lb_target_group.web.arn_suffix}"

  # Registering through the listener's own target_group_arn makes the service depend on the
  # listener: ECS rejects a target group that is not yet attached to a load balancer.
  web_target_group_arn = aws_lb_listener.https.default_action[0].target_group_arn
}
