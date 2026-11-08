# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: MPL-2.0

data "aws_partition" "current" {}

# The recommended ECS-optimized Amazon Linux 2023 image. Resolved at plan time, so a new AMI
# release shows up as a launch template change (and an instance refresh) on the next apply, never
# silently on a scale-out. ARM64 has its own path; the unqualified path is x86_64.
data "aws_ssm_parameter" "ecs_ami" {
  count = var.ami_id == null ? 1 : 0

  name = var.cpu_architecture == "ARM64" ? "/aws/service/ecs/optimized-ami/amazon-linux-2023/arm64/recommended/image_id" : "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id"
}

locals {
  partition = data.aws_partition.current.partition

  ami_id = var.ami_id != null ? var.ami_id : one(data.aws_ssm_parameter.ecs_ami[*].insecure_value)

  # General purpose defaults: two tasks of 1 vCPU / 2 GiB fill one
  # 2 vCPU / 8 GiB instance, which is also what its three network interfaces allow in awsvpc mode
  # (one for the instance, one per task) unless ENI trunking is on. The first entry is preferred
  # for On-Demand capacity.
  default_instance_types = {
    ARM64  = ["m7g.large", "m6g.large"]
    X86_64 = ["m7i.large", "m6i.large"]
  }
  instance_types = coalesce(var.instance_types, local.default_instance_types[var.cpu_architecture])

  # One Auto Scaling group and capacity provider per purchase option. Spot exists only when asked
  # for, and starts from zero instances: ECS managed scaling adds them when tasks are placed.
  pools = merge(
    {
      on_demand = {
        name                 = "${var.name}-ondemand"
        min_size             = var.min_size
        on_demand_percentage = 100
      }
    },
    var.spot_enabled ? {
      spot = {
        name                 = "${var.name}-spot"
        min_size             = 0
        on_demand_percentage = 0
      }
    } : {},
  )

  # Everything the instance configures about itself. No SSH, no key pair: shell access is SSM
  # Session Manager. ECS_AWSVPC_BLOCK_IMDS keeps awsvpc tasks away from the instance credentials
  # (their task role still works: it is served by the agent, not by IMDS).
  ecs_config = [
    "ECS_CLUSTER=${var.cluster_name}",
    "ECS_ENABLE_CONTAINER_METADATA=true",
    "ECS_AWSVPC_BLOCK_IMDS=true",
    "ECS_ENABLE_SPOT_INSTANCE_DRAINING=true",
    # Stopped tasks keep their EFS mount credentials until cleanup; AWS recommends a wait shorter
    # than the one hour default.
    "ECS_ENGINE_TASK_CLEANUP_WAIT_DURATION=10m",
  ]

  # ECS sets AmazonECSManaged on the group when it becomes a capacity provider; declaring it
  # avoids a permanent diff.
  group_tags = merge(var.tags, { Name = "${var.name}-ecs-instance", AmazonECSManaged = "true" })

  user_data = "#!/bin/bash\ncat <<'EOF' >> /etc/ecs/ecs.config\n${join("\n", local.ecs_config)}\nEOF\n"
}

# ---------------------------------------------------------------------------
# Instance identity: the ECS agent role and SSM, nothing else
# ---------------------------------------------------------------------------

resource "aws_iam_role" "instance" {
  name_prefix = "${var.name}-ecs-instance-"
  description = "OpenArtifact ${var.name} ECS container instances"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "Ec2AssumeRole"
        Effect    = "Allow"
        Action    = "sts:AssumeRole"
        Principal = { Service = "ec2.amazonaws.com" }
      }
    ]
  })

  tags = merge(var.tags, { Name = "${var.name}-ecs-instance" })
}

# The AWS managed policies: the agent registers instances, pulls images and ships logs; SSM
# Session Manager replaces SSH. Tasks never use this role (see ECS_AWSVPC_BLOCK_IMDS).
resource "aws_iam_role_policy_attachment" "instance" {
  for_each = {
    ecs = "arn:${local.partition}:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
    ssm = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  role       = aws_iam_role.instance.name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "this" {
  name_prefix = "${var.name}-ecs-instance-"
  role        = aws_iam_role.instance.name

  tags = merge(var.tags, { Name = "${var.name}-ecs-instance" })
}

# ---------------------------------------------------------------------------
# Network: the instances only talk out. Tasks have their own security groups (awsvpc).
# ---------------------------------------------------------------------------

resource "aws_security_group" "instance" {
  name_prefix = "${var.name}-ecs-instance-"
  description = "OpenArtifact ${var.name} ECS container instances: outbound only"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-ecs-instance" })

  lifecycle {
    create_before_destroy = true
  }
}

# The agent and the Docker daemon on the instance (not the tasks) reach ECS, ghcr.io, CloudWatch
# Logs and Secrets Manager: image pulls, log shipping and secret injection run on the host.
#trivy:ignore:AVD-AWS-0104 The instance pulls images from ghcr.io and talks to the AWS APIs on 443; the default is overridable with egress_https_cidr_blocks.
resource "aws_vpc_security_group_egress_rule" "https_cidr" {
  #checkov:skip=CKV_AWS_382: HTTPS-only (443) egress is required for image pulls and the AWS APIs; narrowable with egress_https_cidr_blocks.
  count = length(var.egress_https_cidr_blocks)

  security_group_id = aws_security_group.instance.id
  cidr_ipv4         = var.egress_https_cidr_blocks[count.index]
  description       = "HTTPS to the ECS control plane, image registry and AWS APIs"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443

  tags = merge(var.tags, { Name = "${var.name}-ecs-instance-egress-https-${count.index}" })
}

resource "aws_vpc_security_group_egress_rule" "https_prefix_list" {
  count = length(var.egress_https_prefix_list_ids)

  security_group_id = aws_security_group.instance.id
  prefix_list_id    = var.egress_https_prefix_list_ids[count.index]
  description       = "HTTPS to managed prefix list"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443

  tags = merge(var.tags, { Name = "${var.name}-ecs-instance-egress-pl-${count.index}" })
}

# The ECS agent mounts EFS volumes on the instance, so NFS leaves the instance, not the task.
resource "aws_vpc_security_group_egress_rule" "to_security_group" {
  count = length(var.egress_security_group_rules)

  security_group_id            = aws_security_group.instance.id
  referenced_security_group_id = var.egress_security_group_rules[count.index].security_group_id
  description                  = var.egress_security_group_rules[count.index].description
  ip_protocol                  = "tcp"
  from_port                    = var.egress_security_group_rules[count.index].port
  to_port                      = var.egress_security_group_rules[count.index].port

  tags = merge(var.tags, { Name = "${var.name}-ecs-instance-egress-sg-${count.index}" })
}

# ---------------------------------------------------------------------------
# Launch template
# ---------------------------------------------------------------------------

resource "aws_launch_template" "this" {
  name_prefix            = "${var.name}-ecs-"
  description            = "OpenArtifact ${var.name} ECS container instances"
  image_id               = local.ami_id
  ebs_optimized          = true
  update_default_version = true
  user_data              = base64encode(local.user_data)

  iam_instance_profile {
    arn = aws_iam_instance_profile.this.arn
  }

  # IMDSv2 only. Hop limit 1: the ECS agent runs in the host network namespace, and a container
  # behind a bridge cannot get a token. awsvpc tasks are additionally blocked by
  # ECS_AWSVPC_BLOCK_IMDS in the agent configuration.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  # An explicit interface is the only way to force "no public IP" regardless of the subnet's
  # map_public_ip_on_launch setting.
  network_interfaces {
    device_index                = 0
    associate_public_ip_address = false
    delete_on_termination       = true
    security_groups             = [aws_security_group.instance.id]
  }

  # One disk for the OS, the Docker images and the task scratch volumes (/tmp of every task).
  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      encrypted             = true
      kms_key_id            = var.kms_key_arn
      volume_size           = var.root_volume_size_gib
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${var.name}-ecs-instance" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.tags, { Name = "${var.name}-ecs-instance" })
  }

  tags = merge(var.tags, { Name = "${var.name}-ecs-instance" })
}

# ---------------------------------------------------------------------------
# Auto Scaling groups and capacity providers
# ---------------------------------------------------------------------------

resource "aws_autoscaling_group" "this" {
  for_each = local.pools

  name                  = each.value.name
  min_size              = each.value.min_size
  max_size              = var.max_size
  vpc_zone_identifier   = var.subnet_ids
  health_check_type     = "EC2"
  protect_from_scale_in = true # ECS managed termination protection needs it
  # Destroy must not wait for scale-in protected instances; the services are gone by then.
  force_delete = true

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = each.value.on_demand_percentage
      on_demand_allocation_strategy            = "prioritized"
      spot_allocation_strategy                 = "price-capacity-optimized"
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.this.id
        version            = aws_launch_template.this.latest_version
      }

      dynamic "override" {
        for_each = local.instance_types

        content {
          instance_type = override.value
        }
      }
    }
  }

  # A new launch template version (AMI, user data, volume) replaces the instances. Managed draining
  # moves the tasks away first, so protected instances can be refreshed.
  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage       = 90
      scale_in_protected_instances = "Refresh"
    }
  }

  dynamic "tag" {
    for_each = local.group_tags

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
}

resource "aws_ecs_capacity_provider" "this" {
  for_each = local.pools

  name = each.value.name

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.this[each.key].arn
    managed_termination_protection = "ENABLED"
    managed_draining               = "ENABLED"

    managed_scaling {
      status          = "ENABLED"
      target_capacity = var.target_capacity
    }
  }

  tags = merge(var.tags, { Name = each.value.name })
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = var.cluster_name
  capacity_providers = [for key in sort(keys(aws_ecs_capacity_provider.this)) : aws_ecs_capacity_provider.this[key].name]

  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.this["on_demand"].name
    weight            = 1
    base              = 0
  }
}
