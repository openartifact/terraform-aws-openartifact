# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# Tests for ECS on EC2 capacity in the root module: the default stays Fargate, EC2 mode creates the
# container instances and sends the services to their capacity providers. The module itself is
# covered by tests/ecs-ec2-capacity.tftest.hcl. These runs apply against the mocked provider;
# nothing touches AWS.
# Run: terraform test -filter=tests/root-ec2-capacity.tftest.hcl   (or tofu test)

mock_provider "aws" {
  # OpenTofu fills computed attributes with mock values at plan time and the provider schema
  # validates some of them, so ARNs must look like ARNs.
  mock_resource "aws_kms_key" {
    defaults = {
      arn    = "arn:aws:kms:eu-west-1:123456789012:key/00000000-0000-0000-0000-000000000000"
      key_id = "00000000-0000-0000-0000-000000000000"
    }
  }

  mock_resource "aws_security_group" {
    defaults = {
      id  = "sg-0123456789abcdef0"
      arn = "arn:aws:ec2:eu-west-1:123456789012:security-group/sg-0123456789abcdef0"
    }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:eu-west-1:123456789012:log-group:/ecs/oa-test"
    }
  }

  mock_resource "aws_sfn_state_machine" {
    defaults = {
      arn = "arn:aws:states:eu-west-1:123456789012:stateMachine:oa-test-redeploy"
    }
  }

  mock_resource "aws_cloudwatch_event_rule" {
    defaults = {
      arn = "arn:aws:events:eu-west-1:123456789012:rule/oa-test-redeploy"
    }
  }

  mock_resource "aws_s3_bucket" {
    defaults = {
      arn    = "arn:aws:s3:::oa-test-blobs-123456789012-eu-west-1"
      region = "eu-west-1"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/oa-test"
    }
  }

  mock_resource "aws_secretsmanager_secret" {
    defaults = {
      arn = "arn:aws:secretsmanager:eu-west-1:123456789012:secret:oa-test/secret-AbCdEf"
    }
  }

  mock_resource "aws_db_instance" {
    defaults = {
      address = "oa-test.abcdefghijkl.eu-west-1.rds.amazonaws.com"
      master_user_secret = [{
        kms_key_id    = "00000000-0000-0000-0000-000000000000"
        secret_arn    = "arn:aws:secretsmanager:eu-west-1:123456789012:secret:rds!db-00000000-AbCdEf"
        secret_status = "active"
      }]
    }
  }

  mock_resource "aws_lb" {
    defaults = {
      arn        = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:loadbalancer/app/oa-test/0123456789abcdef"
      arn_suffix = "app/oa-test/0123456789abcdef"
      dns_name   = "oa-test-123456.eu-west-1.elb.amazonaws.com"
    }
  }

  mock_resource "aws_lb_listener" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:listener/app/oa-test/0123456789abcdef/0123456789abcdef"
    }
  }

  mock_resource "aws_lb_target_group" {
    defaults = {
      arn        = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:targetgroup/oa-test/0123456789abcdef"
      arn_suffix = "targetgroup/oa-test/0123456789abcdef"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/test"
      user_id    = "AIDATEST"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "eu-west-1"
    }
  }

  mock_data "aws_vpc" {
    defaults = {
      cidr_block = "10.0.0.0/16"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"s3:GetObject\",\"Resource\":\"arn:aws:s3:::bucket/*\"}]}"
    }
  }

  mock_resource "aws_efs_file_system" {
    defaults = {
      arn = "arn:aws:elasticfilesystem:eu-west-1:123456789012:file-system/fs-0123456789abcdef0"
      id  = "fs-0123456789abcdef0"
    }
  }

  mock_resource "aws_efs_access_point" {
    defaults = {
      arn = "arn:aws:elasticfilesystem:eu-west-1:123456789012:access-point/fsap-0123456789abcdef0"
      id  = "fsap-0123456789abcdef0"
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

  mock_data "aws_ssm_parameter" {
    defaults = {
      insecure_value = "ami-0123456789abcdef0"
      value          = "ami-0123456789abcdef0"
    }
  }
}

variables {
  name                  = "oa-test"
  vpc_id                = "vpc-0123456789abcdef0"
  private_subnet_ids    = ["subnet-0aaaaaaaaaaaaaaa1", "subnet-0bbbbbbbbbbbbbbb2"]
  public_subnet_ids     = ["subnet-0ccccccccccccccc3", "subnet-0ddddddddddddddd4"]
  certificate_arn       = "arn:aws:acm:eu-west-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
  allowed_ingress_cidrs = ["203.0.113.0/24"]
}

run "fargate_is_the_default" {
  command = apply

  variables {
    worker_enabled = true
  }

  assert {
    condition     = length(module.ec2_capacity) == 0 && output.capacity_type == "FARGATE" && output.ecs_capacity_provider_names == null && output.ecs_autoscaling_group_names == null && output.ecs_instance_role_arn == null && output.ecs_instance_security_group_id == null
    error_message = "Without capacity_type EC2 no container instance resource and no EC2 output may exist."
  }

  assert {
    condition     = length(module.web.capacity_provider_strategy) == 0 && length(module.worker[0].capacity_provider_strategy) == 0
    error_message = "On Fargate the services must not use a capacity provider strategy."
  }
}

run "ec2_places_both_services_on_the_on_demand_provider" {
  command = apply

  variables {
    capacity_type  = "EC2"
    worker_enabled = true
  }

  assert {
    condition     = length(module.ec2_capacity) == 1 && output.capacity_type == "EC2" && output.ecs_capacity_provider_names.on_demand == "oa-test-ondemand" && output.ecs_capacity_provider_names.spot == null
    error_message = "EC2 must create the container instances with an On-Demand capacity provider and no Spot one."
  }

  assert {
    condition = alltrue([
      for service in [module.web, module.worker[0]] :
      [for s in service.capacity_provider_strategy : "${s.capacity_provider}:${s.weight}:${s.base}"] == ["oa-test-ondemand:1:0"]
    ])
    error_message = "Both services must run on the On-Demand capacity provider."
  }

  assert {
    condition     = output.ecs_instance_role_arn != null && output.ecs_instance_security_group_id != null && output.ecs_autoscaling_group_names.on_demand == "oa-test-ondemand" && output.ecs_autoscaling_group_names.spot == null
    error_message = "The instance role, the instance security group and the Auto Scaling group names must be exported."
  }

  assert {
    condition     = jsondecode(module.web.container_definitions)[0].readonlyRootFilesystem == true
    error_message = "The tasks must keep the read-only root filesystem on EC2."
  }
}

run "spot_applies_to_the_web_service_only" {
  command = apply

  variables {
    capacity_type  = "EC2"
    worker_enabled = true
    ec2_capacity = {
      spot_percentage = { web = 70 }
    }
  }

  assert {
    condition     = output.ecs_capacity_provider_names.spot == "oa-test-spot" && output.ecs_autoscaling_group_names.spot == "oa-test-spot"
    error_message = "A web spot share must create the Spot capacity provider."
  }

  assert {
    condition     = toset([for s in module.web.capacity_provider_strategy : "${s.capacity_provider}:${s.weight}:${s.base}"]) == toset(["oa-test-ondemand:30:1", "oa-test-spot:70:0"])
    error_message = "The web service must keep one On-Demand task (base 1) and split the rest 30/70 between On-Demand and Spot."
  }

  assert {
    condition     = [for s in module.worker[0].capacity_provider_strategy : s.capacity_provider] == ["oa-test-ondemand"]
    error_message = "The worker must never be placed on Spot."
  }
}

run "ec2_with_efs_lets_the_instances_mount_the_volume" {
  command = apply

  variables {
    capacity_type     = "EC2"
    worker_enabled    = true
    persistent_volume = { enabled = true }
  }

  assert {
    condition     = length(module.efs[0].ingress_security_group_ids) == 3
    error_message = "On EC2 the mount targets must accept the web, the worker and the container instance security group: the ECS agent mounts the file system on the instance."
  }

  assert {
    condition     = contains([for m in jsondecode(module.web.container_definitions)[0].mountPoints : m.containerPath], "/var/cache/openartifact/scanners")
    error_message = "The volume must be mounted into EC2 tasks too."
  }
}

run "ec2_instances_join_the_deployment_cluster" {
  command = apply

  variables {
    capacity_type    = "EC2"
    cpu_architecture = "X86_64"
    ec2_capacity = {
      instance_types = ["m7i.xlarge"]
      min_size       = 2
      max_size       = 3
    }
  }

  assert {
    condition     = module.ec2_capacity[0].ami_id == "ami-0123456789abcdef0" && strcontains(module.ec2_capacity[0].user_data, "ECS_CLUSTER=oa-test")
    error_message = "The instances must join the deployment's cluster."
  }
}

run "unknown_capacity_type_rejected" {
  command = plan

  variables {
    capacity_type = "LAMBDA"
  }

  expect_failures = [var.capacity_type]
}

run "lowercase_capacity_type_rejected" {
  command = plan

  variables {
    capacity_type = "ec2"
  }

  expect_failures = [var.capacity_type]
}

run "spot_on_the_worker_rejected" {
  command = plan

  variables {
    capacity_type  = "EC2"
    worker_enabled = true
    ec2_capacity = {
      spot_percentage = { worker = 50 }
    }
  }

  expect_failures = [var.ec2_capacity]
}

run "spot_above_100_rejected" {
  command = plan

  variables {
    capacity_type = "EC2"
    ec2_capacity = {
      spot_percentage = { web = 101 }
    }
  }

  expect_failures = [var.ec2_capacity]
}

run "empty_instance_types_rejected" {
  command = plan

  variables {
    capacity_type = "EC2"
    ec2_capacity  = { instance_types = [] }
  }

  expect_failures = [var.ec2_capacity]
}

run "min_above_max_rejected" {
  command = plan

  variables {
    capacity_type = "EC2"
    ec2_capacity  = { min_size = 3, max_size = 2 }
  }

  expect_failures = [var.ec2_capacity]
}

run "public_ip_rejected_on_ec2" {
  command = plan

  variables {
    capacity_type    = "EC2"
    assign_public_ip = true
  }

  expect_failures = [var.capacity_type]
}

run "reserved_name_prefix_rejected_on_ec2" {
  command = plan

  variables {
    capacity_type = "EC2"
    name          = "aws-oa"
  }

  expect_failures = [var.capacity_type]
}

run "reserved_name_prefix_stays_valid_on_fargate" {
  command = plan

  variables {
    name = "aws-oa"
  }
}

run "wrong_architecture_instance_types_warn" {
  command = plan

  variables {
    capacity_type = "EC2"
    ec2_capacity  = { instance_types = ["m7i.large"] }
  }

  expect_failures = [check.ec2_instance_types_match_cpu_architecture]
}

run "matching_architecture_instance_types_do_not_warn" {
  command = plan

  variables {
    capacity_type    = "EC2"
    cpu_architecture = "X86_64"
    ec2_capacity     = { instance_types = ["m7i.large", "c6i.xlarge"] }
  }
}

run "ephemeral_storage_on_ec2_warns" {
  command = plan

  variables {
    capacity_type         = "EC2"
    ephemeral_storage_gib = 100
  }

  expect_failures = [check.ephemeral_storage_is_fargate_only]
}
