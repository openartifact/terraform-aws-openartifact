# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# Restarts the tasks when a watched secret rotates (OpenArtifact reads DB_PASSWORD only at start):
#
#   Secrets Manager --(native "Secret Label Updated" event, default event bus)--> EventBridge rule
#   --> Step Functions state machine --(aws-sdk:ecs:updateService, forceNewDeployment)--> this service
#
# The native event needs no CloudTrail trail and is enabled by default for all secrets. Its shape
# (source aws.secretsmanager, detail-type "Secret Label Updated", detail.labelUpdated, resources[]
# = secret ARN) is taken from the AWS Secrets Manager User Guide; it has not been exercised against
# a live account by this module (see the README).

locals {
  redeploy_enabled = length(var.redeploy_on_secret_rotation_arns) > 0

  redeploy_name = "${var.name}-redeploy"

  # The state machine ARN is built from its (input-derived) name to avoid a dependency cycle with
  # its own role, whose trust policy is scoped to it.
  redeploy_state_machine_arn = "arn:${local.partition}:states:${local.region}:${local.account_id}:stateMachine:${local.redeploy_name}"

  # ARN of this service (new ARN format), known at plan time.
  service_arn = "arn:${local.partition}:ecs:${local.region}:${local.account_id}:service/${var.cluster_name}/${var.name}"

  redeploy_event_pattern = {
    source        = ["aws.secretsmanager"]
    "detail-type" = ["Secret Label Updated"]
    resources     = var.redeploy_on_secret_rotation_arns
    detail = {
      labelUpdated = ["AWSCURRENT"]
    }
  }

  redeploy_definition = {
    Comment = "Force a new deployment of ${var.name} after a secret rotation."
    StartAt = "ForceNewDeployment"
    States = {
      ForceNewDeployment = {
        Type     = "Task"
        Resource = "arn:${local.partition}:states:::aws-sdk:ecs:updateService"
        Parameters = {
          Cluster            = var.cluster_arn
          Service            = var.name
          ForceNewDeployment = true
        }
        Retry = [
          {
            ErrorEquals     = ["States.TaskFailed"]
            IntervalSeconds = 30
            MaxAttempts     = 3
            BackoffRate     = 2
          }
        ]
        End = true
      }
    }
  }
}

resource "aws_cloudwatch_event_rule" "redeploy" {
  count = local.redeploy_enabled ? 1 : 0

  name          = "${local.redeploy_name}-on-rotation"
  description   = "Force a new deployment of ECS service ${var.name} when a watched secret's AWSCURRENT version changes."
  event_pattern = jsonencode(local.redeploy_event_pattern)

  tags = merge(var.tags, { Name = "${local.redeploy_name}-on-rotation" })
}

resource "aws_cloudwatch_event_target" "redeploy" {
  count = local.redeploy_enabled ? 1 : 0

  rule     = aws_cloudwatch_event_rule.redeploy[0].name
  arn      = aws_sfn_state_machine.redeploy[0].arn
  role_arn = aws_iam_role.redeploy_events[0].arn

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 3
  }
}

resource "aws_cloudwatch_log_group" "redeploy" {
  #checkov:skip=CKV_AWS_338: Retention is configurable (log_retention_days, default 90); one year is a deployment policy decision.
  #checkov:skip=CKV_AWS_158: Customer-managed key is optional (log_kms_key_arn); its key policy must allow logs.<region>.amazonaws.com.
  count = local.redeploy_enabled ? 1 : 0

  # The /aws/vendedlogs/states/ prefix keeps the log delivery resource policy small.
  name              = "/aws/vendedlogs/states/${local.redeploy_name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.log_kms_key_arn

  tags = merge(var.tags, { Name = "/aws/vendedlogs/states/${local.redeploy_name}" })
}

resource "aws_sfn_state_machine" "redeploy" {
  #checkov:skip=CKV_AWS_284: X-Ray tracing is intentionally off; the state machine is a single SDK call, covered by its error logs.
  count = local.redeploy_enabled ? 1 : 0

  name       = local.redeploy_name
  type       = "STANDARD"
  role_arn   = aws_iam_role.redeploy_sfn[0].arn
  definition = jsonencode(local.redeploy_definition)

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.redeploy[0].arn}:*"
    include_execution_data = true
    level                  = "ERROR"
  }

  tracing_configuration {
    enabled = false
  }

  tags = merge(var.tags, { Name = local.redeploy_name })

  depends_on = [aws_iam_role_policy.redeploy_sfn]
}

# EventBridge -> Step Functions: may only start this state machine, and only for this rule.
resource "aws_iam_role" "redeploy_events" {
  count = local.redeploy_enabled ? 1 : 0

  name_prefix = "${var.name}-rd-events-"
  description = "EventBridge rule role starting the ${local.redeploy_name} state machine"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EventBridgeAssumeRole"
        Effect    = "Allow"
        Action    = "sts:AssumeRole"
        Principal = { Service = "events.amazonaws.com" }
        Condition = {
          StringEquals = { "aws:SourceAccount" = local.account_id }
          ArnEquals    = { "aws:SourceArn" = "arn:${local.partition}:events:${local.region}:${local.account_id}:rule/${local.redeploy_name}-on-rotation" }
        }
      }
    ]
  })

  tags = merge(var.tags, { Name = "${var.name}-redeploy-events" })
}

resource "aws_iam_role_policy" "redeploy_events" {
  count = local.redeploy_enabled ? 1 : 0

  name = "start-execution"
  role = aws_iam_role.redeploy_events[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "StartRedeployExecution"
        Effect   = "Allow"
        Action   = ["states:StartExecution"]
        Resource = local.redeploy_state_machine_arn
      }
    ]
  })
}

# State machine role: may only call ecs:UpdateService on this service, plus the CloudWatch Logs
# delivery actions Step Functions logging requires.
resource "aws_iam_role" "redeploy_sfn" {
  count = local.redeploy_enabled ? 1 : 0

  name_prefix = "${var.name}-rd-sfn-"
  description = "Step Functions role of the ${local.redeploy_name} state machine"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "StatesAssumeRole"
        Effect    = "Allow"
        Action    = "sts:AssumeRole"
        Principal = { Service = "states.amazonaws.com" }
        Condition = {
          StringEquals = { "aws:SourceAccount" = local.account_id }
          ArnEquals    = { "aws:SourceArn" = local.redeploy_state_machine_arn }
        }
      }
    ]
  })

  tags = merge(var.tags, { Name = "${var.name}-redeploy-sfn" })
}

# The CloudWatch Logs delivery actions do not support resource-level permissions (AWS Step Functions
# Developer Guide, "IAM policies for logging to CloudWatch Logs").
resource "aws_iam_role_policy" "redeploy_sfn" {
  #checkov:skip=CKV_AWS_355: CloudWatch Logs delivery actions only support Resource "*"; ecs:UpdateService is scoped to the service ARN.
  #checkov:skip=CKV_AWS_290: CloudWatch Logs delivery actions do not support resource-level permissions.
  count = local.redeploy_enabled ? 1 : 0

  name = "update-service"
  role = aws_iam_role.redeploy_sfn[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ForceNewDeployment"
        Effect   = "Allow"
        Action   = ["ecs:UpdateService"]
        Resource = local.service_arn
      },
      {
        Sid    = "DeliverStateMachineLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery",
          "logs:GetLogDelivery",
          "logs:UpdateLogDelivery",
          "logs:DeleteLogDelivery",
          "logs:ListLogDeliveries",
          "logs:PutResourcePolicy",
          "logs:DescribeResourcePolicies",
          "logs:DescribeLogGroups",
        ]
        Resource = "*"
      }
    ]
  })
}
