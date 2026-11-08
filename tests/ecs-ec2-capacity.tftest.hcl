# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: MPL-2.0

# Tests for modules/ecs-ec2-capacity against a mocked provider (no AWS credentials, nothing is
# created). The AMI comes from a mocked public SSM parameter.
# Run: terraform test -filter=tests/ecs-ec2-capacity.tftest.hcl   (or tofu test)

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }

  mock_data "aws_ssm_parameter" {
    defaults = {
      insecure_value = "ami-0123456789abcdef0"
      value          = "ami-0123456789abcdef0"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/oa-test-ecs-instance"
    }
  }

  mock_resource "aws_iam_instance_profile" {
    defaults = {
      arn = "arn:aws:iam::123456789012:instance-profile/oa-test-ecs-instance"
    }
  }

  mock_resource "aws_launch_template" {
    defaults = {
      id             = "lt-0123456789abcdef0"
      latest_version = 1
    }
  }

  mock_resource "aws_autoscaling_group" {
    defaults = {
      arn = "arn:aws:autoscaling:eu-west-1:123456789012:autoScalingGroup:00000000-0000-0000-0000-000000000000:autoScalingGroupName/oa-test"
    }
  }

  mock_resource "aws_ecs_capacity_provider" {
    defaults = {
      arn = "arn:aws:ecs:eu-west-1:123456789012:capacity-provider/oa-test"
    }
  }

  mock_resource "aws_security_group" {
    defaults = {
      id  = "sg-0123456789abcdef0"
      arn = "arn:aws:ec2:eu-west-1:123456789012:security-group/sg-0123456789abcdef0"
    }
  }
}

variables {
  name         = "oa-test"
  cluster_name = "oa-test"
  vpc_id       = "vpc-0123456789abcdef0"
  subnet_ids   = ["subnet-0aaaaaaaaaaaaaaa1", "subnet-0bbbbbbbbbbbbbbb2"]
}

run "instances_are_hardened" {
  command = apply

  module {
    source = "./modules/ecs-ec2-capacity"
  }

  assert {
    condition = (
      aws_launch_template.this.metadata_options[0].http_tokens == "required"
      && aws_launch_template.this.metadata_options[0].http_endpoint == "enabled"
      && aws_launch_template.this.metadata_options[0].http_put_response_hop_limit == 1
    )
    error_message = "The launch template must require IMDSv2 (http_tokens required) with a hop limit of 1."
  }

  assert {
    condition     = length(aws_launch_template.this.network_interfaces) == 1 && aws_launch_template.this.network_interfaces[0].associate_public_ip_address == "false"
    error_message = "The instances must not get a public IP address."
  }

  assert {
    condition = (
      length(aws_launch_template.this.block_device_mappings) == 1
      && aws_launch_template.this.block_device_mappings[0].ebs[0].encrypted == "true"
      && aws_launch_template.this.block_device_mappings[0].ebs[0].volume_type == "gp3"
      && aws_launch_template.this.block_device_mappings[0].ebs[0].volume_size == 100
    )
    error_message = "The root volume must be an encrypted gp3 volume of 100 GiB by default."
  }

  assert {
    condition     = aws_launch_template.this.key_name == null || aws_launch_template.this.key_name == ""
    error_message = "The instances must not have an SSH key pair."
  }

  assert {
    condition     = aws_launch_template.this.image_id == "ami-0123456789abcdef0" && output.ami_id == "ami-0123456789abcdef0"
    error_message = "The AMI must come from the recommended ECS-optimized image parameter."
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.https_cidr) == 1 && aws_vpc_security_group_egress_rule.https_cidr[0].from_port == 443 && aws_vpc_security_group_egress_rule.https_cidr[0].to_port == 443
    error_message = "Egress must be limited to HTTPS by default."
  }
}

run "user_data_only_configures_the_agent" {
  command = apply

  module {
    source = "./modules/ecs-ec2-capacity"
  }

  assert {
    condition     = strcontains(base64decode(aws_launch_template.this.user_data), "ECS_CLUSTER=oa-test")
    error_message = "User data must join the ECS cluster."
  }

  assert {
    condition     = strcontains(base64decode(aws_launch_template.this.user_data), "ECS_AWSVPC_BLOCK_IMDS=true")
    error_message = "User data must block awsvpc tasks from the instance metadata service."
  }

  assert {
    condition     = strcontains(base64decode(aws_launch_template.this.user_data), "ECS_ENABLE_CONTAINER_METADATA=true")
    error_message = "User data must enable the container metadata file."
  }

  assert {
    condition = alltrue([
      for line in split("\n", trimspace(base64decode(aws_launch_template.this.user_data))) :
      line == "#!/bin/bash" || line == "EOF" || line == "cat <<'EOF' >> /etc/ecs/ecs.config" || can(regex("^ECS_[A-Z_]+=[A-Za-z0-9._-]+$", line))
    ])
    error_message = "User data must contain nothing but the ECS agent configuration lines."
  }
}

run "ami_is_arm64_for_graviton_and_unqualified_for_x86" {
  command = apply

  module {
    source = "./modules/ecs-ec2-capacity"
  }

  assert {
    condition     = data.aws_ssm_parameter.ecs_ami[0].name == "/aws/service/ecs/optimized-ami/amazon-linux-2023/arm64/recommended/image_id"
    error_message = "ARM64 must resolve the arm64 ECS-optimized Amazon Linux 2023 image."
  }
}

run "x86_ami_and_default_types" {
  command = apply

  module {
    source = "./modules/ecs-ec2-capacity"
  }

  variables {
    cpu_architecture = "X86_64"
  }

  assert {
    condition     = data.aws_ssm_parameter.ecs_ami[0].name == "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id"
    error_message = "X86_64 must resolve the unqualified (x86_64) ECS-optimized Amazon Linux 2023 image."
  }

  assert {
    condition     = [for o in aws_autoscaling_group.this["on_demand"].mixed_instances_policy[0].launch_template[0].override : o.instance_type] == ["m7i.large", "m6i.large"]
    error_message = "X86_64 must default to m7i.large, then m6i.large."
  }
}

run "explicit_ami_skips_the_parameter" {
  command = apply

  module {
    source = "./modules/ecs-ec2-capacity"
  }

  variables {
    ami_id = "ami-0fedcba9876543210"
  }

  assert {
    condition     = length(data.aws_ssm_parameter.ecs_ami) == 0 && aws_launch_template.this.image_id == "ami-0fedcba9876543210"
    error_message = "An explicit ami_id must be used as is, without reading the public SSM parameter."
  }
}

run "instance_role_has_only_the_two_managed_policies" {
  command = apply

  module {
    source = "./modules/ecs-ec2-capacity"
  }

  assert {
    condition = toset([for a in aws_iam_role_policy_attachment.instance : a.policy_arn]) == toset([
      "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role",
      "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    ])
    error_message = "The instance role must carry exactly AmazonEC2ContainerServiceforEC2Role and AmazonSSMManagedInstanceCore."
  }

  assert {
    condition     = jsondecode(aws_iam_role.instance.assume_role_policy).Statement[0].Principal.Service == "ec2.amazonaws.com" && length(jsondecode(aws_iam_role.instance.assume_role_policy).Statement) == 1
    error_message = "Only EC2 may assume the instance role."
  }

  assert {
    condition     = aws_iam_instance_profile.this.role == aws_iam_role.instance.name
    error_message = "The instance profile must wrap the instance role."
  }
}

run "no_inbound_rules_and_optional_egress_targets" {
  command = apply

  module {
    source = "./modules/ecs-ec2-capacity"
  }

  variables {
    egress_https_cidr_blocks     = []
    egress_https_prefix_list_ids = ["pl-0123456789abcdef0"]
    egress_security_group_rules = [{
      security_group_id = "sg-0aaaaaaaaaaaaaaa1"
      port              = 2049
      description       = "NFS to the EFS mount targets"
    }]
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.https_cidr) == 0 && length(aws_vpc_security_group_egress_rule.https_prefix_list) == 1 && aws_vpc_security_group_egress_rule.https_prefix_list[0].prefix_list_id == "pl-0123456789abcdef0"
    error_message = "Narrowed egress must use the prefix list and no CIDR block."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.to_security_group[0].referenced_security_group_id == "sg-0aaaaaaaaaaaaaaa1" && aws_vpc_security_group_egress_rule.to_security_group[0].from_port == 2049
    error_message = "NFS egress must target the given security group on its port."
  }
}

run "capacity_provider_is_managed_and_protected" {
  command = apply

  module {
    source = "./modules/ecs-ec2-capacity"
  }

  assert {
    condition = (
      aws_ecs_capacity_provider.this["on_demand"].auto_scaling_group_provider[0].managed_termination_protection == "ENABLED"
      && aws_ecs_capacity_provider.this["on_demand"].auto_scaling_group_provider[0].managed_draining == "ENABLED"
      && aws_ecs_capacity_provider.this["on_demand"].auto_scaling_group_provider[0].managed_scaling[0].status == "ENABLED"
      && aws_ecs_capacity_provider.this["on_demand"].auto_scaling_group_provider[0].managed_scaling[0].target_capacity == 100
    )
    error_message = "The capacity provider must use managed scaling (target 100), managed termination protection and managed draining."
  }

  assert {
    condition     = aws_autoscaling_group.this["on_demand"].protect_from_scale_in == true
    error_message = "Instances must be protected from scale-in, as managed termination protection requires."
  }

  assert {
    condition     = aws_autoscaling_group.this["on_demand"].instance_refresh[0].strategy == "Rolling" && aws_autoscaling_group.this["on_demand"].instance_refresh[0].preferences[0].scale_in_protected_instances == "Refresh"
    error_message = "Launch template changes must roll the instances, including the scale-in protected ones."
  }

  assert {
    condition = (
      aws_autoscaling_group.this["on_demand"].min_size == 1
      && aws_autoscaling_group.this["on_demand"].max_size == 4
      && aws_autoscaling_group.this["on_demand"].vpc_zone_identifier == toset(["subnet-0aaaaaaaaaaaaaaa1", "subnet-0bbbbbbbbbbbbbbb2"])
    )
    error_message = "The group must span the given subnets and scale between 1 and 4 instances."
  }

  assert {
    condition = (
      aws_autoscaling_group.this["on_demand"].mixed_instances_policy[0].instances_distribution[0].on_demand_percentage_above_base_capacity == 100
      && [for o in aws_autoscaling_group.this["on_demand"].mixed_instances_policy[0].launch_template[0].override : o.instance_type] == ["m7g.large", "m6g.large"]
    )
    error_message = "The default group must be 100% On-Demand Graviton: m7g.large, then m6g.large."
  }

  assert {
    condition     = length(aws_ecs_capacity_provider.this) == 1 && output.capacity_provider_names.spot == null && output.capacity_provider_names.on_demand == "oa-test-ondemand"
    error_message = "Without spot_enabled only the On-Demand provider must exist."
  }

  assert {
    condition     = aws_ecs_cluster_capacity_providers.this.cluster_name == "oa-test" && [for s in aws_ecs_cluster_capacity_providers.this.default_capacity_provider_strategy : s.capacity_provider] == ["oa-test-ondemand"]
    error_message = "The providers must be attached to the cluster with On-Demand as the default."
  }
}

run "spot_group_is_separate_and_starts_empty" {
  command = apply

  module {
    source = "./modules/ecs-ec2-capacity"
  }

  variables {
    spot_enabled   = true
    min_size       = 2
    max_size       = 6
    instance_types = ["c7g.large", "c6g.large", "m7g.large"]
  }

  assert {
    condition = (
      aws_autoscaling_group.this["spot"].min_size == 0
      && aws_autoscaling_group.this["spot"].mixed_instances_policy[0].instances_distribution[0].on_demand_percentage_above_base_capacity == 0
      && aws_autoscaling_group.this["spot"].mixed_instances_policy[0].instances_distribution[0].spot_allocation_strategy == "price-capacity-optimized"
    )
    error_message = "The Spot group must be 100% Spot, start from zero and use price-capacity-optimized."
  }

  assert {
    condition     = aws_autoscaling_group.this["on_demand"].min_size == 2 && aws_autoscaling_group.this["on_demand"].max_size == 6 && aws_autoscaling_group.this["spot"].max_size == 6
    error_message = "min_size applies to the On-Demand group only; max_size to both."
  }

  assert {
    condition     = [for o in aws_autoscaling_group.this["spot"].mixed_instances_policy[0].launch_template[0].override : o.instance_type] == ["c7g.large", "c6g.large", "m7g.large"]
    error_message = "A diversified instance type list must be passed to the group in order."
  }

  assert {
    condition     = output.capacity_provider_names.spot == "oa-test-spot" && output.capacity_provider_names.on_demand == "oa-test-ondemand"
    error_message = "Both capacity providers must be exported."
  }

  assert {
    condition     = strcontains(base64decode(aws_launch_template.this.user_data), "ECS_ENABLE_SPOT_INSTANCE_DRAINING=true")
    error_message = "Spot interruption draining must be on."
  }
}

run "customer_managed_key_encrypts_the_volume" {
  command = apply

  module {
    source = "./modules/ecs-ec2-capacity"
  }

  variables {
    kms_key_arn          = "arn:aws:kms:eu-west-1:123456789012:key/00000000-0000-0000-0000-000000000000"
    root_volume_size_gib = 200
  }

  assert {
    condition     = aws_launch_template.this.block_device_mappings[0].ebs[0].kms_key_id == "arn:aws:kms:eu-west-1:123456789012:key/00000000-0000-0000-0000-000000000000" && aws_launch_template.this.block_device_mappings[0].ebs[0].volume_size == 200
    error_message = "The CMK and the volume size must reach the root volume."
  }
}

run "empty_instance_types_rejected" {
  command = plan

  module {
    source = "./modules/ecs-ec2-capacity"
  }

  variables {
    instance_types = []
  }

  expect_failures = [var.instance_types]
}

run "malformed_instance_type_rejected" {
  command = plan

  module {
    source = "./modules/ecs-ec2-capacity"
  }

  variables {
    instance_types = ["m7g"]
  }

  expect_failures = [var.instance_types]
}

run "reserved_name_prefix_rejected" {
  command = plan

  module {
    source = "./modules/ecs-ec2-capacity"
  }

  variables {
    name = "aws-oa"
  }

  expect_failures = [var.name]
}

run "min_above_max_rejected" {
  command = plan

  module {
    source = "./modules/ecs-ec2-capacity"
  }

  variables {
    min_size = 5
    max_size = 2
  }

  expect_failures = [var.min_size]
}

run "unknown_architecture_rejected" {
  command = plan

  module {
    source = "./modules/ecs-ec2-capacity"
  }

  variables {
    cpu_architecture = "RISCV"
  }

  expect_failures = [var.cpu_architecture]
}

run "small_root_volume_rejected" {
  command = plan

  module {
    source = "./modules/ecs-ec2-capacity"
  }

  variables {
    root_volume_size_gib = 8
  }

  expect_failures = [var.root_volume_size_gib]
}
