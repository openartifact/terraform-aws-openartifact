# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

output "service_name" {
  description = "Name of the ECS service."
  value       = aws_ecs_service.this.name
}

output "service_arn" {
  description = "ARN of the ECS service."
  value       = aws_ecs_service.this.id
}

output "task_definition_arn" {
  description = "ARN of the task definition revision the service runs."
  value       = aws_ecs_task_definition.this.arn
}

output "task_role_arn" {
  description = "ARN of the task role assumed by the OpenArtifact process."
  value       = aws_iam_role.task.arn
}

output "execution_role_arn" {
  description = "ARN of the task execution role used by the ECS agent (logs, secrets)."
  value       = aws_iam_role.execution.arn
}

output "security_group_id" {
  description = "ID of the task security group, for example to allow it on the database security group."
  value       = aws_security_group.this.id
}

output "log_group_name" {
  description = "Name of the CloudWatch log group of the container."
  value       = aws_cloudwatch_log_group.this.name
}

output "log_group_arn" {
  description = "ARN of the CloudWatch log group of the container."
  value       = aws_cloudwatch_log_group.this.arn
}

output "container_definitions" {
  description = "Rendered container definitions JSON of the task definition (read-only/user/health check/environment/secrets), exposed for tests and review."
  value       = aws_ecs_task_definition.this.container_definitions
}

output "redeploy_state_machine_arn" {
  description = "ARN of the Step Functions state machine that force-redeploys the service on secret rotation, or null when redeploy_on_secret_rotation_arns is empty."
  value       = one(aws_sfn_state_machine.redeploy[*].arn)
}

output "capacity_provider_strategy" {
  description = "Capacity provider strategy of the service as ECS holds it, empty on Fargate."
  value       = aws_ecs_service.this.capacity_provider_strategy
}
