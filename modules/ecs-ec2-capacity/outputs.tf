# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: MPL-2.0

# Services must not be created before the providers are attached to the cluster and before the
# instances may reach their file systems, so the capacity provider names are only handed out then.

output "capacity_provider_names" {
  description = "Names of the capacity providers for a service capacity_provider_strategy: on_demand, and spot (null unless spot_enabled). Available once they are attached to the cluster."
  value = {
    on_demand = aws_ecs_capacity_provider.this["on_demand"].name
    spot      = one([for key, provider in aws_ecs_capacity_provider.this : provider.name if key == "spot"])
  }

  depends_on = [
    aws_ecs_cluster_capacity_providers.this,
    aws_vpc_security_group_egress_rule.https_cidr,
    aws_vpc_security_group_egress_rule.https_prefix_list,
    aws_vpc_security_group_egress_rule.to_security_group,
  ]
}

output "autoscaling_group_names" {
  description = "Names of the Auto Scaling groups: on_demand, and spot (null unless spot_enabled)."
  value = {
    on_demand = aws_autoscaling_group.this["on_demand"].name
    spot      = one([for key, group in aws_autoscaling_group.this : group.name if key == "spot"])
  }
}

output "security_group_id" {
  description = "ID of the instance security group (outbound only), for example to allow it on the EFS mount target security group."
  value       = aws_security_group.instance.id
}

output "instance_role_arn" {
  description = "ARN of the instance role (AmazonEC2ContainerServiceforEC2Role and AmazonSSMManagedInstanceCore only)."
  value       = aws_iam_role.instance.arn
}

output "launch_template_id" {
  description = "ID of the launch template of the instances."
  value       = aws_launch_template.this.id
}

output "ami_id" {
  description = "ID of the AMI the instances launch from."
  value       = local.ami_id
}

output "user_data" {
  description = "Plain-text user data of the instances (it only writes /etc/ecs/ecs.config), exposed for tests and review."
  value       = local.user_data
}
