# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_region" "current" {}

locals {
  container_name = "openartifact"

  # An empty strategy means Fargate (launch_type); otherwise the tasks run on EC2 container
  # instances behind the given capacity providers.
  fargate = length(var.capacity_provider_strategy) == 0

  # The image entrypoint (docker/Dockerfile: COPY ... /app/openartifact, CMD ["/app/openartifact"])
  # and the image's own HEALTHCHECK use the same absolute path; the image is shell-less, so the
  # health check must be the exec form (CMD), never CMD-SHELL.
  binary_path = "/app/openartifact"

  # Fargate allows a stopTimeout of at most 120 seconds.
  stop_timeout = coalesce(var.stop_timeout_seconds, min(120, var.shutdown_delay_seconds + var.shutdown_timeout_seconds + 5))

  # Module-controlled variables win over var.environment.
  environment = merge(var.environment, {
    OPENARTIFACT_ROLE       = var.role
    SERVER_PORT             = tostring(var.container_port)
    SERVER_SHUTDOWN_DELAY   = tostring(var.shutdown_delay_seconds)
    SERVER_SHUTDOWN_TIMEOUT = tostring(var.shutdown_timeout_seconds)
  })

  # keys() returns the names in lexicographic order, so the lists are deterministic.
  environment_list = [for key in keys(local.environment) : { name = key, value = local.environment[key] }]
  secrets_list     = [for key in keys(var.secrets) : { name = key, valueFrom = var.secrets[key] }]

  container_definitions = [
    {
      name                   = local.container_name
      image                  = var.image
      essential              = true
      user                   = "10001:10001"
      privileged             = false
      readonlyRootFilesystem = true
      stopTimeout            = local.stop_timeout

      linuxParameters = {
        initProcessEnabled = true
        capabilities = {
          drop = ["ALL"]
        }
      }

      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]

      # /tmp (task ephemeral storage, or a task-scoped Docker volume on EC2) is the only writable
      # path of the root filesystem, plus the EFS volumes when the caller supplies any; see the
      # README.
      mountPoints = concat(
        [
          {
            sourceVolume  = "tmp"
            containerPath = "/tmp"
            readOnly      = false
          }
        ],
        [
          for volume in var.efs_volumes : {
            sourceVolume  = volume.name
            containerPath = volume.container_path
            readOnly      = false
          }
        ],
      )

      healthCheck = {
        command     = ["CMD", local.binary_path, "-healthcheck"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = var.container_health_check_start_period
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.this.name
          "awslogs-region"        = data.aws_region.current.region
          "awslogs-stream-prefix" = local.container_name
        }
      }

      environment = local.environment_list
      secrets     = local.secrets_list
    }
  ]
}

resource "aws_ecs_task_definition" "this" {
  family                   = var.name
  requires_compatibilities = local.fargate ? ["FARGATE"] : ["EC2"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.cpu)
  memory                   = tostring(var.memory)
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn
  container_definitions    = jsonencode(local.container_definitions)
  track_latest             = false

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  # Fargate only: on EC2 the scratch space is the instance disk (the tmp Docker volume below).
  dynamic "ephemeral_storage" {
    for_each = local.fargate ? [var.ephemeral_storage_gib] : []

    content {
      size_in_gib = ephemeral_storage.value
    }
  }

  volume {
    name = "tmp"

    # Task-scoped local Docker volume: created empty with the permissions of the image's /tmp when
    # the task starts and deleted when it stops, like Fargate ephemeral storage.
    dynamic "docker_volume_configuration" {
      for_each = local.fargate ? [] : [1]

      content {
        scope  = "task"
        driver = "local"
      }
    }
  }

  # Encrypted in transit and authorized with the task role; the access point fixes the POSIX
  # identity and the root directory.
  dynamic "volume" {
    for_each = var.efs_volumes

    content {
      name = volume.value.name

      efs_volume_configuration {
        file_system_id     = volume.value.file_system_id
        transit_encryption = "ENABLED"

        authorization_config {
          access_point_id = volume.value.access_point_id
          iam             = "ENABLED"
        }
      }
    }
  }

  tags = merge(var.tags, { Name = var.name })

  depends_on = [
    aws_iam_role_policy.execution,
    aws_iam_role_policy.task_storage,
    aws_iam_role_policy.task_efs,
  ]
}

resource "aws_ecs_service" "this" {
  name                               = var.name
  cluster                            = var.cluster_arn
  task_definition                    = aws_ecs_task_definition.this.arn
  desired_count                      = var.desired_count
  launch_type                        = local.fargate ? "FARGATE" : null
  platform_version                   = local.fargate ? "LATEST" : null
  enable_execute_command             = var.enable_execute_command
  enable_ecs_managed_tags            = true
  propagate_tags                     = "SERVICE"
  deployment_minimum_healthy_percent = var.deployment_minimum_healthy_percent
  deployment_maximum_percent         = var.deployment_maximum_percent
  health_check_grace_period_seconds  = var.target_group_arn != null ? var.health_check_grace_period_seconds : null
  wait_for_steady_state              = false

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets         = var.subnet_ids
    security_groups = [aws_security_group.this.id]
    # Tasks on EC2 instances cannot get a public address.
    assign_public_ip = local.fargate ? var.assign_public_ip : null
  }

  dynamic "capacity_provider_strategy" {
    for_each = var.capacity_provider_strategy

    content {
      capacity_provider = capacity_provider_strategy.value.capacity_provider
      weight            = capacity_provider_strategy.value.weight
      base              = capacity_provider_strategy.value.base
    }
  }

  dynamic "load_balancer" {
    for_each = var.target_group_arn != null ? [var.target_group_arn] : []

    content {
      target_group_arn = load_balancer.value
      container_name   = local.container_name
      container_port   = var.container_port
    }
  }

  tags = merge(var.tags, { Name = var.name })

  # Application Auto Scaling (or an operator) owns the task count after creation.
  lifecycle {
    ignore_changes = [desired_count]
  }

  depends_on = [
    aws_iam_role_policy.execution,
    aws_iam_role_policy.task_storage,
    aws_iam_role_policy.task_efs,
    aws_cloudwatch_log_group.this,
    aws_vpc_security_group_ingress_rule.container_port,
    aws_vpc_security_group_egress_rule.https_cidr,
    aws_vpc_security_group_egress_rule.https_prefix_list,
    aws_vpc_security_group_egress_rule.to_security_group,
  ]
}

resource "aws_security_group" "this" {
  name_prefix = "${var.name}-"
  description = "OpenArtifact ${var.name} ECS tasks"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = var.name })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "container_port" {
  count = length(var.ingress_security_group_ids)

  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = var.ingress_security_group_ids[count.index]
  description                  = "OpenArtifact HTTP from allowed security group"
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port

  tags = merge(var.tags, { Name = "${var.name}-ingress-${count.index}" })
}

#trivy:ignore:AVD-AWS-0104 Proxy repositories fetch from arbitrary upstream registries and the tasks reach ghcr.io and the AWS APIs on 443; the default is overridable with egress_https_cidr_blocks.
resource "aws_vpc_security_group_egress_rule" "https_cidr" {
  #checkov:skip=CKV_AWS_382: HTTPS-only (443) egress to arbitrary upstreams is required by proxy repositories; narrowable with egress_https_cidr_blocks.
  count = length(var.egress_https_cidr_blocks)

  security_group_id = aws_security_group.this.id
  cidr_ipv4         = var.egress_https_cidr_blocks[count.index]
  description       = "HTTPS to upstream registries, image registry and AWS APIs"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443

  tags = merge(var.tags, { Name = "${var.name}-egress-https-${count.index}" })
}

resource "aws_vpc_security_group_egress_rule" "https_prefix_list" {
  count = length(var.egress_https_prefix_list_ids)

  security_group_id = aws_security_group.this.id
  prefix_list_id    = var.egress_https_prefix_list_ids[count.index]
  description       = "HTTPS to managed prefix list"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443

  tags = merge(var.tags, { Name = "${var.name}-egress-pl-${count.index}" })
}

resource "aws_vpc_security_group_egress_rule" "to_security_group" {
  count = length(var.egress_security_group_rules)

  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = var.egress_security_group_rules[count.index].security_group_id
  description                  = var.egress_security_group_rules[count.index].description
  ip_protocol                  = "tcp"
  from_port                    = var.egress_security_group_rules[count.index].port
  to_port                      = var.egress_security_group_rules[count.index].port

  tags = merge(var.tags, { Name = "${var.name}-egress-sg-${count.index}" })
}
