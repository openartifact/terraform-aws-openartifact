# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

data "aws_partition" "current" {}

# ---------------------------------------------------------------------------
# Customer-managed KMS keys
# ---------------------------------------------------------------------------

# Key policy of the secrets key: the account root delegates access control to IAM, so only
# identities with an explicit IAM permission (the task execution roles get kms:Decrypt from the
# module) can use it. No wildcard principals.
data "aws_iam_policy_document" "secrets_key" {
  #checkov:skip=CKV_AWS_109: a KMS key policy must grant the account root kms:*; it only delegates to IAM and the key policy resource "*" refers to this key itself
  #checkov:skip=CKV_AWS_111: a KMS key policy must grant the account root kms:*; it only delegates to IAM and the key policy resource "*" refers to this key itself
  #checkov:skip=CKV_AWS_356: in a key policy the resource "*" means this key itself
  statement {
    sid       = "EnableIAMPolicies"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}

# Key policy of the logs key: the same delegation plus CloudWatch Logs, restricted to log groups of
# this account and region. Used by the service log groups, the VPC flow logs and the state machine
# logs of the redeploy-on-rotation mechanism.
data "aws_iam_policy_document" "logs_key" {
  #checkov:skip=CKV_AWS_109: a KMS key policy must grant the account root kms:*; it only delegates to IAM and the key policy resource "*" refers to this key itself
  #checkov:skip=CKV_AWS_111: a KMS key policy must grant the account root kms:*; it only delegates to IAM and the key policy resource "*" refers to this key itself
  #checkov:skip=CKV_AWS_356: in a key policy the resource "*" means this key itself
  statement {
    sid       = "EnableIAMPolicies"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid    = "AllowCloudWatchLogs"
    effect = "Allow"
    actions = [
      "kms:Encrypt*",
      "kms:Decrypt*",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${data.aws_region.current.region}.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:*"]
    }
  }
}

resource "aws_kms_key" "secrets" {
  description             = "OpenArtifact ${var.name} application secrets"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.secrets_key.json

  tags = { Name = "${var.name}-secrets" }
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${var.name}-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

resource "aws_kms_key" "logs" {
  description             = "OpenArtifact ${var.name} CloudWatch log groups"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.logs_key.json

  tags = { Name = "${var.name}-logs" }
}

resource "aws_kms_alias" "logs" {
  name          = "alias/${var.name}-logs"
  target_key_id = aws_kms_key.logs.key_id
}

# ---------------------------------------------------------------------------
# Access log buckets
# ---------------------------------------------------------------------------

# Two private buckets: "alb" receives the load balancer access logs and "s3" the server access
# logs of the blob bucket. Both services only support SSE-S3 (AES256) on the target bucket, not
# SSE-KMS, so the buckets cannot use the customer-managed key.
locals {
  access_log_buckets = {
    alb = "${var.name}-alb-logs-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.region}"
    s3  = "${var.name}-s3-logs-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.region}"
  }
}

#trivy:ignore:AVD-AWS-0089 These buckets are themselves the log targets; logging them would need a further bucket, ad infinitum.
resource "aws_s3_bucket" "access_logs" {
  #checkov:skip=CKV_AWS_18: These buckets are themselves the log targets; logging them would need a further bucket, ad infinitum.
  #checkov:skip=CKV_AWS_144: Cross-region replication of access logs is out of scope for this example.
  #checkov:skip=CKV_AWS_145: ALB access logs and S3 server access logs can only be delivered to an SSE-S3 (AES256) encrypted bucket; SSE-KMS is not supported by either service.
  #checkov:skip=CKV2_AWS_62: Event notifications are not used.
  #checkov:skip=CKV2_AWS_61: The lifecycle configuration below expires the log objects.
  for_each = local.access_log_buckets

  bucket = each.value

  tags = { Name = each.value }
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  for_each = local.access_log_buckets

  bucket                  = aws_s3_bucket.access_logs[each.key].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "access_logs" {
  for_each = local.access_log_buckets

  bucket = aws_s3_bucket.access_logs[each.key].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

#trivy:ignore:AVD-AWS-0132 ALB access logs and S3 server access logs can only be delivered to a bucket encrypted with SSE-S3; SSE-KMS is not supported by either service.
resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  for_each = local.access_log_buckets

  bucket = aws_s3_bucket.access_logs[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "access_logs" {
  for_each = local.access_log_buckets

  bucket = aws_s3_bucket.access_logs[each.key].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  for_each = local.access_log_buckets

  bucket = aws_s3_bucket.access_logs[each.key].id

  rule {
    id     = "expire-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = var.log_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.access_logs]
}

# Statement shared by both buckets: refuse plain HTTP.
data "aws_iam_policy_document" "access_logs_tls" {
  for_each = local.access_log_buckets

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.access_logs[each.key].arn, "${aws_s3_bucket.access_logs[each.key].arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

# ELB log delivery (service principal valid in every region), only for load balancers of this
# account and region, and only below this account's AWSLogs prefix.
data "aws_iam_policy_document" "alb_log_delivery" {
  source_policy_documents = [data.aws_iam_policy_document.access_logs_tls["alb"].json]

  statement {
    sid       = "AllowELBLogDelivery"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.access_logs["alb"].arn}/alb/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    principals {
      type        = "Service"
      identifiers = ["logdelivery.elasticloadbalancing.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:elasticloadbalancing:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:loadbalancer/*"]
    }
  }
}

# S3 server access logging of the blob bucket, only from that bucket.
data "aws_iam_policy_document" "s3_log_delivery" {
  source_policy_documents = [data.aws_iam_policy_document.access_logs_tls["s3"].json]

  statement {
    sid       = "AllowS3ServerAccessLogs"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.access_logs["s3"].arn}/blobs/*"]

    principals {
      type        = "Service"
      identifiers = ["logging.s3.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:s3:::${local.blob_bucket_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_s3_bucket_policy" "access_logs" {
  for_each = {
    alb = data.aws_iam_policy_document.alb_log_delivery.json
    s3  = data.aws_iam_policy_document.s3_log_delivery.json
  }

  bucket = aws_s3_bucket.access_logs[each.key].id
  policy = each.value

  # The policy must not race the public access block.
  depends_on = [aws_s3_bucket_public_access_block.access_logs]
}
