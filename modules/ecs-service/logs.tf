# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# Without a customer-managed key (log_kms_key_arn) CloudWatch Logs still encrypts the data at rest.
resource "aws_cloudwatch_log_group" "this" {
  #checkov:skip=CKV_AWS_338: Retention is configurable (log_retention_days, default 90); one year is a deployment policy decision.
  #checkov:skip=CKV_AWS_158: Customer-managed key is optional (log_kms_key_arn); its key policy must allow logs.<region>.amazonaws.com.
  name              = "/ecs/${var.name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.log_kms_key_arn

  tags = merge(var.tags, { Name = "/ecs/${var.name}" })
}
