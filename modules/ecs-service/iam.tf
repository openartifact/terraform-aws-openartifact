# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region

  # Known at plan time (the name is an input), unlike aws_cloudwatch_log_group.this.arn.
  log_group_arn = "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/ecs/${var.name}"

  ecs_tasks_assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EcsTasksAssumeRole"
        Effect    = "Allow"
        Action    = "sts:AssumeRole"
        Principal = { Service = "ecs-tasks.amazonaws.com" }
        Condition = {
          StringEquals = { "aws:SourceAccount" = local.account_id }
          ArnLike      = { "aws:SourceArn" = "arn:${local.partition}:ecs:${local.region}:${local.account_id}:*" }
        }
      }
    ]
  })

  execution_policy_statements = concat(
    [
      {
        Sid      = "WriteContainerLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${local.log_group_arn}:*"
      }
    ],
    length(var.execution_secret_arns) > 0 ? [
      {
        Sid      = "ReadContainerSecrets"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = var.execution_secret_arns
      }
    ] : [],
    length(var.execution_kms_key_arns) > 0 ? [
      {
        Sid      = "DecryptContainerSecrets"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = var.execution_kms_key_arns
      }
    ] : [],
  )
}

# Execution role: used by the ECS agent (not the application) to start the task. The image is public
# (ghcr.io), so no registry permissions are granted; a private ECR mirror needs an extra policy
# attached to the role by the caller (see the execution_role_arn output).
resource "aws_iam_role" "execution" {
  name_prefix        = "${var.name}-exec-"
  description        = "OpenArtifact ${var.name} ECS task execution role"
  assume_role_policy = local.ecs_tasks_assume_role_policy

  tags = merge(var.tags, { Name = "${var.name}-execution" })
}

resource "aws_iam_role_policy" "execution" {
  name = "task-execution"
  role = aws_iam_role.execution.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.execution_policy_statements
  })
}

# Task role: assumed by the OpenArtifact process. Only the caller-supplied policy (S3/KMS access) and,
# when ECS Exec is on, the SSM channel actions.
resource "aws_iam_role" "task" {
  name_prefix        = "${var.name}-task-"
  description        = "OpenArtifact ${var.name} ECS task role"
  assume_role_policy = local.ecs_tasks_assume_role_policy

  tags = merge(var.tags, { Name = "${var.name}-task" })
}

resource "aws_iam_role_policy" "task_storage" {
  name   = "storage"
  role   = aws_iam_role.task.id
  policy = var.task_role_policy_json
}

# The ssmmessages actions do not support resource-level permissions.
#trivy:ignore:AVD-AWS-0057 ssmmessages channel actions only support Resource "*"; the policy exists only when enable_execute_command is true.
resource "aws_iam_role_policy" "task_execute_command" {
  #checkov:skip=CKV_AWS_355: ssmmessages channel actions only support Resource "*"; only created when enable_execute_command is true.
  #checkov:skip=CKV_AWS_290: ssmmessages channel actions do not support resource-level permissions.
  count = var.enable_execute_command ? 1 : 0

  name = "ecs-exec"
  role = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EcsExecSsmChannels"
        Effect = "Allow"
        Action = [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel",
        ]
        Resource = "*"
      }
    ]
  })
}
