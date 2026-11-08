# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: MPL-2.0

# Plan-only behaviour tests for modules/ecs-service (no AWS credentials needed).
# Run: terraform test -filter=tests/ecs-service.tftest.hcl   (or tofu test)

mock_provider "aws" {
  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/test"
      user_id    = "AIDAEXAMPLE"
    }
  }

  override_data {
    target = data.aws_partition.current
    values = {
      partition          = "aws"
      dns_suffix         = "amazonaws.com"
      reverse_dns_prefix = "com.amazonaws"
    }
  }

  # OpenTofu fills computed attributes with random strings at plan time and validates ARN
  # arguments, so the ARNs consumed by other resources need valid mock defaults.
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock"
    }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:eu-west-1:123456789012:log-group:/mock"
    }
  }

  mock_resource "aws_sfn_state_machine" {
    defaults = {
      arn = "arn:aws:states:eu-west-1:123456789012:stateMachine:mock"
    }
  }

  override_data {
    target = data.aws_region.current
    values = {
      region = "eu-west-1"
      name   = "eu-west-1"
    }
  }
}

variables {
  name                  = "oa-web"
  cluster_arn           = "arn:aws:ecs:eu-west-1:123456789012:cluster/openartifact"
  cluster_name          = "openartifact"
  vpc_id                = "vpc-0123456789abcdef0"
  subnet_ids            = ["subnet-0aaa1111", "subnet-0bbb2222"]
  image                 = "ghcr.io/openartifact/openartifact:0.19.2"
  role                  = "web"
  desired_count         = 2
  target_group_arn      = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:targetgroup/oa/0123456789abcdef"
  task_role_policy_json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"s3:GetObject\",\"Resource\":\"arn:aws:s3:::bucket/*\"}]}"
  environment = {
    STORAGE_BACKEND = "s3"
    STORAGE_BUCKET  = "bucket"
    DB_HOST         = "db.example.internal"
  }
  secrets = {
    DB_PASSWORD             = "arn:aws:secretsmanager:eu-west-1:123456789012:secret:rds!db-abc-AbCdEf:password::"
    OPENARTIFACT_SECRET_KEY = "arn:aws:secretsmanager:eu-west-1:123456789012:secret:oa-key-AbCdEf"
  }
  execution_secret_arns = [
    "arn:aws:secretsmanager:eu-west-1:123456789012:secret:rds!db-abc-AbCdEf",
    "arn:aws:secretsmanager:eu-west-1:123456789012:secret:oa-key-AbCdEf",
  ]
  ingress_security_group_ids = ["sg-0alb0000"]
}

run "container_is_hardened" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  assert {
    condition     = jsondecode(output.container_definitions)[0].readonlyRootFilesystem == true
    error_message = "The container root filesystem must be read-only."
  }

  assert {
    condition     = jsondecode(output.container_definitions)[0].user == "10001:10001" && jsondecode(output.container_definitions)[0].privileged == false
    error_message = "The container must run as 10001:10001 and not privileged."
  }

  assert {
    condition     = jsondecode(output.container_definitions)[0].linuxParameters.initProcessEnabled == true && jsondecode(output.container_definitions)[0].linuxParameters.capabilities.drop == ["ALL"]
    error_message = "The container must use an init process and drop all capabilities."
  }

  assert {
    condition     = jsondecode(output.container_definitions)[0].mountPoints == [{ sourceVolume = "tmp", containerPath = "/tmp", readOnly = false }]
    error_message = "/tmp must be the only writable mount, backed by the tmp volume."
  }

  assert {
    condition     = jsondecode(output.container_definitions)[0].healthCheck.command == ["CMD", "/app/openartifact", "-healthcheck"]
    error_message = "The health check must use the exec form with the image entrypoint path."
  }

  assert {
    condition     = jsondecode(output.container_definitions)[0].stopTimeout == 80
    error_message = "stopTimeout must default to shutdown delay (15) + timeout (60) + 5."
  }

  assert {
    condition     = jsondecode(output.container_definitions)[0].logConfiguration.options["awslogs-group"] == "/ecs/oa-web" && jsondecode(output.container_definitions)[0].logConfiguration.options["awslogs-region"] == "eu-west-1"
    error_message = "The container must log to /ecs/<name> in the current region."
  }

  assert {
    condition     = aws_ecs_task_definition.this.network_mode == "awsvpc" && aws_ecs_task_definition.this.runtime_platform[0].cpu_architecture == "ARM64"
    error_message = "The task must use awsvpc networking and ARM64 by default."
  }
}

run "environment_and_secrets" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  assert {
    condition     = jsonencode([for e in jsondecode(output.container_definitions)[0].environment : e.name]) == jsonencode(sort([for e in jsondecode(output.container_definitions)[0].environment : e.name]))
    error_message = "The environment list must be sorted by name."
  }

  assert {
    condition     = { for e in jsondecode(output.container_definitions)[0].environment : e.name => e.value }["OPENARTIFACT_ROLE"] == "web"
    error_message = "OPENARTIFACT_ROLE must carry the role variable."
  }

  assert {
    condition     = { for e in jsondecode(output.container_definitions)[0].environment : e.name => e.value }["SERVER_PORT"] == "8080"
    error_message = "SERVER_PORT must be injected."
  }

  assert {
    condition = (
      { for e in jsondecode(output.container_definitions)[0].environment : e.name => e.value }["SERVER_SHUTDOWN_DELAY"] == "15"
      && { for e in jsondecode(output.container_definitions)[0].environment : e.name => e.value }["SERVER_SHUTDOWN_TIMEOUT"] == "60"
    )
    error_message = "The shutdown delay and timeout must be injected."
  }

  assert {
    condition = length(setintersection(
      toset([for e in jsondecode(output.container_definitions)[0].environment : e.name]),
      toset(["STORAGE_ACCESS_KEY", "STORAGE_SECRET_KEY"])
      )) == 0 && length(setintersection(
      toset([for s in jsondecode(output.container_definitions)[0].secrets : s.name]),
      toset(["STORAGE_ACCESS_KEY", "STORAGE_SECRET_KEY"])
    )) == 0
    error_message = "No static S3 credentials may be injected."
  }

  assert {
    condition     = { for s in jsondecode(output.container_definitions)[0].secrets : s.name => s.valueFrom }["DB_PASSWORD"] == "arn:aws:secretsmanager:eu-west-1:123456789012:secret:rds!db-abc-AbCdEf:password::"
    error_message = "Secrets must be passed as valueFrom references, including the json key suffix."
  }

  assert {
    condition     = alltrue([for s in jsondecode(output.container_definitions)[0].secrets : length(keys(s)) == 2 && contains(keys(s), "valueFrom")])
    error_message = "Secrets must only carry name and valueFrom, never a value."
  }
}

run "role_is_injected" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  variables {
    role             = "all"
    target_group_arn = null
  }

  assert {
    condition     = { for e in jsondecode(output.container_definitions)[0].environment : e.name => e.value }["OPENARTIFACT_ROLE"] == "all"
    error_message = "OPENARTIFACT_ROLE must be all."
  }
}

run "module_controlled_environment_wins" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  variables {
    environment = {
      OPENARTIFACT_ROLE = "worker"
      SERVER_PORT       = "9999"
    }
    secrets = {}
  }

  assert {
    condition     = { for e in jsondecode(output.container_definitions)[0].environment : e.name => e.value }["OPENARTIFACT_ROLE"] == "web"
    error_message = "The role variable must win over environment."
  }

  assert {
    condition     = { for e in jsondecode(output.container_definitions)[0].environment : e.name => e.value }["SERVER_PORT"] == "8080"
    error_message = "container_port must win over environment."
  }
}

run "worker_has_no_load_balancer" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  variables {
    role             = "worker"
    target_group_arn = null
  }

  assert {
    condition     = { for e in jsondecode(output.container_definitions)[0].environment : e.name => e.value }["OPENARTIFACT_ROLE"] == "worker"
    error_message = "OPENARTIFACT_ROLE must be worker."
  }

  assert {
    condition     = length(aws_ecs_service.this.load_balancer) == 0
    error_message = "A worker must not register with a load balancer."
  }

  assert {
    condition     = aws_ecs_service.this.health_check_grace_period_seconds == null
    error_message = "The health check grace period applies only with a load balancer."
  }
}

run "web_has_load_balancer" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  assert {
    condition     = length(aws_ecs_service.this.load_balancer) == 1
    error_message = "A web service must register with the target group."
  }

  assert {
    condition     = one(aws_ecs_service.this.load_balancer).container_name == "openartifact" && one(aws_ecs_service.this.load_balancer).container_port == 8080
    error_message = "The load balancer must target the openartifact container on the container port."
  }

  assert {
    condition     = aws_ecs_service.this.health_check_grace_period_seconds == 60
    error_message = "The health check grace period must apply with a load balancer."
  }
}

run "service_settings" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  assert {
    condition     = aws_ecs_service.this.deployment_circuit_breaker[0].enable == true && aws_ecs_service.this.deployment_circuit_breaker[0].rollback == true
    error_message = "The deployment circuit breaker must be enabled with rollback."
  }

  assert {
    condition     = aws_ecs_service.this.enable_execute_command == false
    error_message = "ECS Exec must be disabled by default."
  }

  assert {
    condition     = length(aws_iam_role_policy.task_execute_command) == 0
    error_message = "The ssmmessages permissions must not exist without ECS Exec."
  }

  assert {
    condition     = aws_ecs_service.this.launch_type == "FARGATE" && aws_ecs_service.this.propagate_tags == "SERVICE" && aws_ecs_service.this.deployment_minimum_healthy_percent == 100 && aws_ecs_service.this.deployment_maximum_percent == 200
    error_message = "Fargate launch type, SERVICE tag propagation and 100/200 deployment limits are expected."
  }

  assert {
    condition     = aws_ecs_service.this.network_configuration[0].assign_public_ip == false
    error_message = "Tasks must not get a public IP by default."
  }

  assert {
    condition     = aws_ecs_task_definition.this.ephemeral_storage[0].size_in_gib == 21
    error_message = "The ephemeral storage default is 21 GiB."
  }
}

run "execute_command_adds_ssm_permissions" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  variables {
    enable_execute_command = true
  }

  assert {
    condition     = aws_ecs_service.this.enable_execute_command == true
    error_message = "ECS Exec must be enabled."
  }

  assert {
    condition     = length(aws_iam_role_policy.task_execute_command) == 1 && contains(jsondecode(aws_iam_role_policy.task_execute_command[0].policy).Statement[0].Action, "ssmmessages:OpenDataChannel")
    error_message = "ECS Exec must add the ssmmessages permissions to the task role."
  }
}

run "execution_role_is_scoped" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  assert {
    condition     = jsondecode(aws_iam_role.execution.assume_role_policy).Statement[0].Principal.Service == "ecs-tasks.amazonaws.com" && jsondecode(aws_iam_role.execution.assume_role_policy).Statement[0].Condition.StringEquals["aws:SourceAccount"] == "123456789012"
    error_message = "The execution role trust policy must name ecs-tasks and the source account."
  }

  assert {
    condition     = !contains(flatten([for s in jsondecode(aws_iam_role_policy.execution.policy).Statement : s.Resource]), "*")
    error_message = "The execution role policy must not use a wildcard resource."
  }

  assert {
    condition     = jsonencode([for s in jsondecode(aws_iam_role_policy.execution.policy).Statement : s if s.Sid == "ReadContainerSecrets"][0].Resource) == jsonencode(var.execution_secret_arns)
    error_message = "GetSecretValue must be limited to execution_secret_arns."
  }

  assert {
    condition     = [for s in jsondecode(aws_iam_role_policy.execution.policy).Statement : s if s.Sid == "WriteContainerLogs"][0].Resource == "arn:aws:logs:eu-west-1:123456789012:log-group:/ecs/oa-web:*"
    error_message = "Log permissions must be limited to the service log group."
  }

  assert {
    condition     = length([for s in jsondecode(aws_iam_role_policy.execution.policy).Statement : s if contains(keys(s), "Action") && contains(tolist(s.Action), "kms:Decrypt")]) == 0
    error_message = "kms:Decrypt must not be granted without execution_kms_key_arns."
  }
}

run "execution_role_kms_decrypt" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  variables {
    execution_kms_key_arns = ["arn:aws:kms:eu-west-1:123456789012:key/11111111-2222-3333-4444-555555555555"]
  }

  assert {
    condition     = [for s in jsondecode(aws_iam_role_policy.execution.policy).Statement : s if s.Sid == "DecryptContainerSecrets"][0].Resource == ["arn:aws:kms:eu-west-1:123456789012:key/11111111-2222-3333-4444-555555555555"]
    error_message = "kms:Decrypt must be limited to execution_kms_key_arns."
  }
}

run "execution_role_without_secrets" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  variables {
    secrets               = {}
    execution_secret_arns = []
  }

  assert {
    condition     = length(jsondecode(aws_iam_role_policy.execution.policy).Statement) == 1
    error_message = "Only the log statement may remain without secrets."
  }
}

run "task_role_carries_only_supplied_policy" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  assert {
    condition     = aws_iam_role_policy.task_storage.policy == var.task_role_policy_json
    error_message = "The task role inline policy must be exactly task_role_policy_json."
  }

  assert {
    condition     = jsondecode(aws_iam_role.task.assume_role_policy).Statement[0].Principal.Service == "ecs-tasks.amazonaws.com"
    error_message = "The task role must trust ecs-tasks."
  }
}

run "security_group_rules" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  variables {
    egress_security_group_rules = [
      { security_group_id = "sg-0db000000", port = 5432, description = "PostgreSQL" },
    ]
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.container_port) == 1 && aws_vpc_security_group_ingress_rule.container_port[0].from_port == 8080 && aws_vpc_security_group_ingress_rule.container_port[0].to_port == 8080
    error_message = "One ingress rule on the container port per allowed security group."
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.https_cidr) == 1 && aws_vpc_security_group_egress_rule.https_cidr[0].from_port == 443 && aws_vpc_security_group_egress_rule.https_cidr[0].cidr_ipv4 == "0.0.0.0/0"
    error_message = "HTTPS egress to 0.0.0.0/0 is the default."
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.to_security_group) == 1 && aws_vpc_security_group_egress_rule.to_security_group[0].from_port == 5432
    error_message = "The database egress rule must be created."
  }
}

run "egress_can_be_narrowed" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  variables {
    egress_https_cidr_blocks     = ["10.0.0.0/16"]
    egress_https_prefix_list_ids = ["pl-63a5400a"]
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.https_cidr) == 1 && aws_vpc_security_group_egress_rule.https_cidr[0].cidr_ipv4 == "10.0.0.0/16"
    error_message = "egress_https_cidr_blocks must replace the default."
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.https_prefix_list) == 1
    error_message = "A prefix list egress rule must be created per entry."
  }
}

run "image_digest_is_passed_through" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  variables {
    image = "ghcr.io/openartifact/openartifact@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  }

  assert {
    condition     = jsondecode(output.container_definitions)[0].image == "ghcr.io/openartifact/openartifact@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    error_message = "An image digest reference must reach the container definition unchanged."
  }
}

run "autoscaling_disabled_by_default" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  assert {
    condition     = length(aws_appautoscaling_target.this) == 0 && length(aws_appautoscaling_policy.cpu) == 0 && length(aws_appautoscaling_policy.memory) == 0 && length(aws_appautoscaling_policy.requests) == 0
    error_message = "No autoscaling resources without autoscaling.enabled."
  }
}

run "autoscaling_cpu_only" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  variables {
    autoscaling = {
      enabled      = true
      min_capacity = 2
      max_capacity = 6
    }
  }

  assert {
    condition     = length(aws_appautoscaling_target.this) == 1 && aws_appautoscaling_target.this[0].min_capacity == 2 && aws_appautoscaling_target.this[0].max_capacity == 6 && aws_appautoscaling_target.this[0].resource_id == "service/openartifact/oa-web"
    error_message = "The scalable target must cover the service with the configured bounds."
  }

  assert {
    condition     = length(aws_appautoscaling_policy.cpu) == 1 && length(aws_appautoscaling_policy.memory) == 0 && length(aws_appautoscaling_policy.requests) == 0
    error_message = "Only the CPU policy is created by default."
  }

  assert {
    condition     = aws_appautoscaling_policy.cpu[0].target_tracking_scaling_policy_configuration[0].predefined_metric_specification[0].predefined_metric_type == "ECSServiceAverageCPUUtilization" && aws_appautoscaling_policy.cpu[0].target_tracking_scaling_policy_configuration[0].target_value == 60
    error_message = "The CPU policy must track ECSServiceAverageCPUUtilization at 60 percent."
  }
}

run "autoscaling_all_policies" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  variables {
    autoscaling = {
      enabled               = true
      min_capacity          = 2
      max_capacity          = 6
      memory_target_percent = 70
      requests_per_target   = 500
      alb_resource_label    = "app/oa/0123456789abcdef/targetgroup/oa/0123456789abcdef"
    }
  }

  assert {
    condition     = length(aws_appautoscaling_policy.memory) == 1 && length(aws_appautoscaling_policy.requests) == 1
    error_message = "Memory and request count policies must be created when configured."
  }

  assert {
    condition     = aws_appautoscaling_policy.requests[0].target_tracking_scaling_policy_configuration[0].predefined_metric_specification[0].resource_label == "app/oa/0123456789abcdef/targetgroup/oa/0123456789abcdef"
    error_message = "The request count policy must use the ALB resource label."
  }
}

run "no_redeployer_by_default" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  assert {
    condition     = length(aws_cloudwatch_event_rule.redeploy) == 0 && length(aws_sfn_state_machine.redeploy) == 0 && length(aws_iam_role.redeploy_events) == 0 && length(aws_iam_role.redeploy_sfn) == 0
    error_message = "No redeployer resources without redeploy_on_secret_rotation_arns."
  }

  assert {
    condition     = output.redeploy_state_machine_arn == null
    error_message = "The state machine output must be null without a redeployer."
  }
}

run "redeployer_when_arns_given" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  variables {
    redeploy_on_secret_rotation_arns = ["arn:aws:secretsmanager:eu-west-1:123456789012:secret:rds!db-abc-AbCdEf"]
  }

  assert {
    condition     = length(aws_cloudwatch_event_rule.redeploy) == 1 && length(aws_cloudwatch_event_target.redeploy) == 1 && length(aws_sfn_state_machine.redeploy) == 1 && length(aws_cloudwatch_log_group.redeploy) == 1
    error_message = "The redeployer resources must be created."
  }

  assert {
    condition = (
      jsondecode(aws_cloudwatch_event_rule.redeploy[0].event_pattern).source == ["aws.secretsmanager"]
      && jsondecode(aws_cloudwatch_event_rule.redeploy[0].event_pattern)["detail-type"] == ["Secret Label Updated"]
      && jsondecode(aws_cloudwatch_event_rule.redeploy[0].event_pattern).detail.labelUpdated == ["AWSCURRENT"]
      && jsonencode(jsondecode(aws_cloudwatch_event_rule.redeploy[0].event_pattern).resources) == jsonencode(var.redeploy_on_secret_rotation_arns)
    )
    error_message = "The rule must match the native Secret Label Updated event for the AWSCURRENT label of the given secrets only."
  }

  assert {
    condition = (
      jsondecode(aws_sfn_state_machine.redeploy[0].definition).States.ForceNewDeployment.Resource == "arn:aws:states:::aws-sdk:ecs:updateService"
      && jsondecode(aws_sfn_state_machine.redeploy[0].definition).States.ForceNewDeployment.Parameters.ForceNewDeployment == true
      && jsondecode(aws_sfn_state_machine.redeploy[0].definition).States.ForceNewDeployment.Parameters.Service == "oa-web"
      && jsondecode(aws_sfn_state_machine.redeploy[0].definition).States.ForceNewDeployment.Parameters.Cluster == "arn:aws:ecs:eu-west-1:123456789012:cluster/openartifact"
    )
    error_message = "The state machine must force a new deployment of this service on this cluster."
  }

  assert {
    condition     = aws_sfn_state_machine.redeploy[0].tracing_configuration[0].enabled == false && aws_sfn_state_machine.redeploy[0].type == "STANDARD"
    error_message = "X-Ray tracing must be off."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.redeploy_events[0].policy).Statement[0].Action == ["states:StartExecution"] && jsondecode(aws_iam_role_policy.redeploy_events[0].policy).Statement[0].Resource == "arn:aws:states:eu-west-1:123456789012:stateMachine:oa-web-redeploy"
    error_message = "The EventBridge role may only start the redeploy state machine."
  }

  assert {
    condition = (
      jsonencode([for s in jsondecode(aws_iam_role_policy.redeploy_sfn[0].policy).Statement : s if s.Sid == "ForceNewDeployment"][0].Action) == jsonencode(["ecs:UpdateService"])
      && [for s in jsondecode(aws_iam_role_policy.redeploy_sfn[0].policy).Statement : s if s.Sid == "ForceNewDeployment"][0].Resource == "arn:aws:ecs:eu-west-1:123456789012:service/openartifact/oa-web"
    )
    error_message = "The state machine role may only update this service (scoped to its ARN)."
  }
}

run "fargate_combination_rejected" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  variables {
    cpu    = 256
    memory = 4096
  }

  expect_failures = [var.memory]
}

run "fargate_combination_accepted" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  variables {
    cpu    = 4096
    memory = 30720
  }

  assert {
    condition     = aws_ecs_task_definition.this.cpu == "4096" && aws_ecs_task_definition.this.memory == "30720"
    error_message = "A valid Fargate combination must be accepted."
  }
}

run "ephemeral_storage_too_small_rejected" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  variables {
    ephemeral_storage_gib = 20
  }

  expect_failures = [var.ephemeral_storage_gib]
}

run "ephemeral_storage_too_large_rejected" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  variables {
    ephemeral_storage_gib = 201
  }

  expect_failures = [var.ephemeral_storage_gib]
}

run "worker_with_target_group_rejected" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  variables {
    role = "worker"
  }

  expect_failures = [var.target_group_arn]
}

run "invalid_role_rejected" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  variables {
    role = "api"
  }

  expect_failures = [var.role]
}

run "negative_desired_count_rejected" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  variables {
    desired_count = -1
  }

  expect_failures = [var.desired_count]
}

run "empty_image_rejected" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  variables {
    image = ""
  }

  expect_failures = [var.image]
}

run "unsupported_log_retention_rejected" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  variables {
    log_retention_days = 91
  }

  expect_failures = [var.log_retention_days]
}

run "static_s3_credentials_rejected" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  variables {
    environment = {
      STORAGE_ACCESS_KEY = "AKIAEXAMPLE"
    }
    secrets = {}
  }

  expect_failures = [var.environment]
}

run "secret_also_in_environment_rejected" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  variables {
    environment = {
      DB_PASSWORD = "plain"
    }
  }

  expect_failures = [var.secrets]
}

run "autoscaling_min_above_max_rejected" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  variables {
    autoscaling = {
      enabled      = true
      min_capacity = 5
      max_capacity = 2
    }
  }

  expect_failures = [var.autoscaling]
}

run "autoscaling_requests_without_label_rejected" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  variables {
    autoscaling = {
      enabled             = true
      requests_per_target = 500
    }
  }

  expect_failures = [var.autoscaling]
}

run "shutdown_budget_over_stop_timeout_rejected" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  variables {
    shutdown_timeout_seconds = 110
  }

  expect_failures = [var.shutdown_timeout_seconds]
}

# ---------------------------------------------------------------------------
# Fargate stays exactly as before
# ---------------------------------------------------------------------------

run "fargate_is_the_default_compute" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  assert {
    condition     = aws_ecs_service.this.launch_type == "FARGATE" && aws_ecs_service.this.platform_version == "LATEST" && length(aws_ecs_service.this.capacity_provider_strategy) == 0
    error_message = "Without a capacity provider strategy the service must run on Fargate (launch type FARGATE, platform LATEST), with no strategy."
  }

  assert {
    condition     = aws_ecs_task_definition.this.requires_compatibilities == toset(["FARGATE"]) && aws_ecs_task_definition.this.network_mode == "awsvpc"
    error_message = "The task definition must be Fargate-only with awsvpc networking."
  }

  assert {
    condition     = length(aws_ecs_task_definition.this.ephemeral_storage) == 1 && aws_ecs_task_definition.this.ephemeral_storage[0].size_in_gib == 21
    error_message = "Fargate tasks must configure ephemeral storage (21 GiB by default)."
  }

  assert {
    condition     = length(aws_ecs_task_definition.this.volume) == 1 && [for v in aws_ecs_task_definition.this.volume : v.name][0] == "tmp" && length([for v in aws_ecs_task_definition.this.volume : v.docker_volume_configuration if v.name == "tmp"][0]) == 0
    error_message = "Fargate tasks must have exactly the tmp volume, without a Docker volume configuration (Fargate rejects it)."
  }

  assert {
    condition     = aws_ecs_service.this.network_configuration[0].assign_public_ip == false
    error_message = "assign_public_ip must stay false by default."
  }

  assert {
    condition     = length(aws_iam_role_policy.task_efs) == 0
    error_message = "Without EFS volumes the task role must get no EFS policy."
  }

  assert {
    condition     = length(jsondecode(output.container_definitions)[0].mountPoints) == 1
    error_message = "Without EFS volumes /tmp must be the only mount point."
  }
}

# ---------------------------------------------------------------------------
# EC2 capacity providers
# ---------------------------------------------------------------------------

run "capacity_providers_replace_the_launch_type" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  variables {
    capacity_provider_strategy = [
      { capacity_provider = "oa-ondemand", weight = 30, base = 1 },
      { capacity_provider = "oa-spot", weight = 70 },
    ]
  }

  assert {
    condition     = toset([for s in aws_ecs_service.this.capacity_provider_strategy : "${s.capacity_provider}:${s.weight}:${s.base}"]) == toset(["oa-ondemand:30:1", "oa-spot:70:0"])
    error_message = "The strategy must carry the providers with their weight and base (base defaults to 0)."
  }

  assert {
    condition     = aws_ecs_task_definition.this.requires_compatibilities == toset(["EC2"]) && aws_ecs_task_definition.this.network_mode == "awsvpc"
    error_message = "The task definition must require EC2 and keep awsvpc networking."
  }

  assert {
    condition     = length(aws_ecs_task_definition.this.ephemeral_storage) == 0
    error_message = "Ephemeral storage is Fargate-only and must not be set for EC2 tasks."
  }

  assert {
    condition     = jsondecode(output.container_definitions)[0].readonlyRootFilesystem == true && jsondecode(output.container_definitions)[0].user == "10001:10001"
    error_message = "EC2 tasks must keep the read-only root filesystem and the non-root user."
  }

  # launch_type, platform_version and assign_public_ip are computed when unset, so a mocked plan
  # cannot show that they are null; the AWS provider rejects launch_type together with a strategy.
}

run "ec2_scratch_space_is_a_task_scoped_docker_volume" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  variables {
    capacity_provider_strategy = [{ capacity_provider = "oa-ondemand" }]
  }

  assert {
    condition = (
      length([for v in aws_ecs_task_definition.this.volume : v if v.name == "tmp"]) == 1
      && [for v in aws_ecs_task_definition.this.volume : v.docker_volume_configuration[0].scope if v.name == "tmp"][0] == "task"
      && [for v in aws_ecs_task_definition.this.volume : v.docker_volume_configuration[0].driver if v.name == "tmp"][0] == "local"
    )
    error_message = "/tmp on EC2 must be a task-scoped local Docker volume (removed when the task stops)."
  }

  assert {
    condition     = jsondecode(output.container_definitions)[0].mountPoints == [{ sourceVolume = "tmp", containerPath = "/tmp", readOnly = false }]
    error_message = "/tmp must still be the only writable mount."
  }
}

run "capacity_provider_strategy_rejects_two_bases" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  variables {
    capacity_provider_strategy = [
      { capacity_provider = "a", base = 1 },
      { capacity_provider = "b", base = 2 },
    ]
  }

  expect_failures = [var.capacity_provider_strategy]
}

run "capacity_provider_strategy_needs_a_positive_weight" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  variables {
    capacity_provider_strategy = [{ capacity_provider = "a", weight = 0 }]
  }

  expect_failures = [var.capacity_provider_strategy]
}

run "public_ip_is_rejected_on_ec2" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  variables {
    assign_public_ip           = true
    capacity_provider_strategy = [{ capacity_provider = "oa-ondemand" }]
  }

  expect_failures = [var.assign_public_ip]
}

# ---------------------------------------------------------------------------
# EFS volumes
# ---------------------------------------------------------------------------

run "efs_volumes_are_encrypted_authorized_and_mounted" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  variables {
    efs_volumes = [
      {
        name             = "scanner-cache"
        container_path   = "/var/cache/openartifact/scanners"
        file_system_id   = "fs-0123456789abcdef0"
        file_system_arn  = "arn:aws:elasticfilesystem:eu-west-1:123456789012:file-system/fs-0123456789abcdef0"
        access_point_id  = "fsap-0aaaaaaaaaaaaaaa1"
        access_point_arn = "arn:aws:elasticfilesystem:eu-west-1:123456789012:access-point/fsap-0aaaaaaaaaaaaaaa1"
      },
      {
        name             = "backups"
        container_path   = "/var/lib/openartifact/backups"
        file_system_id   = "fs-0123456789abcdef0"
        file_system_arn  = "arn:aws:elasticfilesystem:eu-west-1:123456789012:file-system/fs-0123456789abcdef0"
        access_point_id  = "fsap-0bbbbbbbbbbbbbbb2"
        access_point_arn = "arn:aws:elasticfilesystem:eu-west-1:123456789012:access-point/fsap-0bbbbbbbbbbbbbbb2"
      },
    ]
  }

  assert {
    condition = alltrue([
      for v in aws_ecs_task_definition.this.volume : (
        v.efs_volume_configuration[0].transit_encryption == "ENABLED"
        && v.efs_volume_configuration[0].authorization_config[0].iam == "ENABLED"
        && v.efs_volume_configuration[0].file_system_id == "fs-0123456789abcdef0"
      ) if v.name != "tmp"
    ])
    error_message = "Every EFS volume must use TLS (transit_encryption ENABLED) and IAM authorization."
  }

  assert {
    condition     = { for v in aws_ecs_task_definition.this.volume : v.name => v.efs_volume_configuration[0].authorization_config[0].access_point_id if v.name != "tmp" } == { scanner-cache = "fsap-0aaaaaaaaaaaaaaa1", backups = "fsap-0bbbbbbbbbbbbbbb2" }
    error_message = "Every EFS volume must be mounted through its own access point."
  }

  assert {
    condition     = alltrue([for v in aws_ecs_task_definition.this.volume : v.efs_volume_configuration[0].root_directory == null if v.name != "tmp"])
    error_message = "With an access point the volume must not set a root directory (the access point owns it)."
  }

  assert {
    condition = (
      { for m in jsondecode(output.container_definitions)[0].mountPoints : m.sourceVolume => m.containerPath }
      == { tmp = "/tmp", scanner-cache = "/var/cache/openartifact/scanners", backups = "/var/lib/openartifact/backups" }
    )
    error_message = "The volumes must be mounted at their container paths next to /tmp."
  }

  assert {
    condition     = jsondecode(output.container_definitions)[0].readonlyRootFilesystem == true
    error_message = "The root filesystem must stay read-only with EFS volumes."
  }

  assert {
    condition = (
      length(jsondecode(aws_iam_role_policy.task_efs[0].policy).Statement) == 2
      && alltrue([
        for s in jsondecode(aws_iam_role_policy.task_efs[0].policy).Statement : (
          s.Effect == "Allow"
          && toset(s.Action) == toset(["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite"])
          && s.Resource == "arn:aws:elasticfilesystem:eu-west-1:123456789012:file-system/fs-0123456789abcdef0"
        )
      ])
      && toset([for s in jsondecode(aws_iam_role_policy.task_efs[0].policy).Statement : s.Condition.StringEquals["elasticfilesystem:AccessPointArn"]]) == toset([
        "arn:aws:elasticfilesystem:eu-west-1:123456789012:access-point/fsap-0aaaaaaaaaaaaaaa1",
        "arn:aws:elasticfilesystem:eu-west-1:123456789012:access-point/fsap-0bbbbbbbbbbbbbbb2",
      ])
    )
    error_message = "The task role must get ClientMount and ClientWrite on the file system only, restricted to each access point, and nothing else (no ClientRootAccess, no wildcard)."
  }
}

run "efs_volume_cannot_shadow_tmp" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  variables {
    efs_volumes = [{
      name             = "tmp"
      container_path   = "/data"
      file_system_id   = "fs-0123456789abcdef0"
      file_system_arn  = "arn:aws:elasticfilesystem:eu-west-1:123456789012:file-system/fs-0123456789abcdef0"
      access_point_id  = "fsap-0aaaaaaaaaaaaaaa1"
      access_point_arn = "arn:aws:elasticfilesystem:eu-west-1:123456789012:access-point/fsap-0aaaaaaaaaaaaaaa1"
    }]
  }

  expect_failures = [var.efs_volumes]
}

run "efs_volume_cannot_mount_over_tmp" {
  command = plan

  module {
    source = "./modules/ecs-service"
  }

  variables {
    efs_volumes = [{
      name             = "data"
      container_path   = "/tmp"
      file_system_id   = "fs-0123456789abcdef0"
      file_system_arn  = "arn:aws:elasticfilesystem:eu-west-1:123456789012:file-system/fs-0123456789abcdef0"
      access_point_id  = "fsap-0aaaaaaaaaaaaaaa1"
      access_point_arn = "arn:aws:elasticfilesystem:eu-west-1:123456789012:access-point/fsap-0aaaaaaaaaaaaaaa1"
    }]
  }

  expect_failures = [var.efs_volumes]
}
