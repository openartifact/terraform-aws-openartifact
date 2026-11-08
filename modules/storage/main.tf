# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: MPL-2.0

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_region" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  partition   = data.aws_partition.current.partition
  region      = data.aws_region.current.region
  cmk_enabled = var.kms_mode == "cmk"

  bucket_name = var.bucket_name != null ? var.bucket_name : "${var.name}-blobs-${local.account_id}-${local.region}"
}

# ------------------------------------------------------------------------------
# Encryption key
# ------------------------------------------------------------------------------

# Key policy: the account root principal delegates access control to IAM, so
# only identities that hold explicit kms:* IAM permissions (for example the
# task role created from access_policy_json) can use the key. No wildcard
# principals; no service principals are needed because S3 calls KMS on behalf
# of the requesting IAM principal.
data "aws_iam_policy_document" "kms_key" {
  #checkov:skip=CKV_AWS_109: a KMS key policy must grant the account root kms:*; it only delegates to IAM and the key policy resource "*" refers to this key itself
  #checkov:skip=CKV_AWS_111: a KMS key policy must grant the account root kms:*; it only delegates to IAM and the key policy resource "*" refers to this key itself
  #checkov:skip=CKV_AWS_356: in a key policy the resource "*" means this key itself
  count = local.cmk_enabled ? 1 : 0

  statement {
    sid       = "EnableIAMPolicies"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }
}

resource "aws_kms_key" "blobs" {
  count = local.cmk_enabled ? 1 : 0

  description             = "OpenArtifact ${var.name} blob storage (S3 SSE-KMS)"
  enable_key_rotation     = true
  deletion_window_in_days = var.kms_key_deletion_window_days
  policy                  = data.aws_iam_policy_document.kms_key[0].json

  tags = merge(var.tags, { Name = "${var.name}-storage" })
}

resource "aws_kms_alias" "blobs" {
  count = local.cmk_enabled ? 1 : 0

  name          = "alias/${var.name}-storage"
  target_key_id = aws_kms_key.blobs[0].key_id
}

# ------------------------------------------------------------------------------
# Bucket
# ------------------------------------------------------------------------------

#trivy:ignore:AVD-AWS-0089 access logging is opt-in through var.access_logging because it needs a pre-existing log bucket
resource "aws_s3_bucket" "this" {
  #checkov:skip=CKV_AWS_18: access logging is opt-in through var.access_logging because it needs a pre-existing log bucket
  #checkov:skip=CKV_AWS_144: cross-region replication is out of scope for this module; configure S3 replication in the consuming stack
  #checkov:skip=CKV2_AWS_62: event notifications are not used by OpenArtifact
  bucket        = local.bucket_name
  force_destroy = var.force_destroy

  tags = merge(var.tags, { Name = local.bucket_name })
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    bucket_key_enabled = true

    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = local.cmk_enabled ? aws_kms_key.blobs[0].arn : null
    }
  }
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = var.versioning_enabled ? "Enabled" : "Suspended"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  #checkov:skip=CKV_AWS_300: the unconditional rule "abort-incomplete-multipart-uploads" sets the abort period; the check cannot see it next to dynamic rule blocks
  bucket = aws_s3_bucket.this.id

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = var.abort_incomplete_multipart_days
    }
  }

  dynamic "rule" {
    for_each = var.versioning_enabled ? [1] : []

    content {
      id     = "expire-noncurrent-versions"
      status = "Enabled"

      filter {}

      noncurrent_version_expiration {
        noncurrent_days = var.noncurrent_version_expiration_days
      }
    }
  }

  dynamic "rule" {
    for_each = var.versioning_enabled ? [1] : []

    content {
      id     = "remove-expired-delete-markers"
      status = "Enabled"

      filter {}

      expiration {
        expired_object_delete_marker = true
      }
    }
  }

  # The provider documents that lifecycle rules must be applied after
  # versioning is configured.
  depends_on = [aws_s3_bucket_versioning.this]
}

resource "aws_s3_bucket_logging" "this" {
  count = var.access_logging == null ? 0 : 1

  bucket        = aws_s3_bucket.this.id
  target_bucket = var.access_logging.target_bucket
  target_prefix = var.access_logging.target_prefix
}

# ------------------------------------------------------------------------------
# Bucket policy
# ------------------------------------------------------------------------------

data "aws_iam_policy_document" "bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]

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

  statement {
    sid       = "DenyTlsBelow12"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "NumericLessThan"
      variable = "s3:TlsVersion"
      values   = ["1.2"]
    }
  }

  # "...IfExists": requests without an explicit SSE header are accepted and
  # fall back to the bucket default (SSE-KMS); requests that explicitly ask for
  # any other algorithm (SSE-S3, SSE-C) are rejected.
  statement {
    sid       = "DenyWrongServerSideEncryption"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.this.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "StringNotEqualsIfExists"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
  }

  dynamic "statement" {
    for_each = local.cmk_enabled ? [1] : []

    content {
      sid       = "DenyWrongKmsKey"
      effect    = "Deny"
      actions   = ["s3:PutObject"]
      resources = ["${aws_s3_bucket.this.arn}/*"]

      principals {
        type        = "*"
        identifiers = ["*"]
      }

      condition {
        test     = "StringNotEqualsIfExists"
        variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
        values   = [aws_kms_key.blobs[0].arn]
      }
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.bucket.json

  # A bucket policy cannot be attached while the public access block is being
  # changed concurrently.
  depends_on = [aws_s3_bucket_public_access_block.this]
}

# ------------------------------------------------------------------------------
# Least-privilege access policy for the OpenArtifact task/pod role
# ------------------------------------------------------------------------------

data "aws_iam_policy_document" "access" {
  statement {
    sid = "ListBucket"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
    ]
    resources = [aws_s3_bucket.this.arn]
  }

  statement {
    sid = "ReadWriteObjects"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:ListMultipartUploadParts",
      "s3:PutObject",
    ]
    resources = ["${aws_s3_bucket.this.arn}/*"]
  }

  dynamic "statement" {
    for_each = local.cmk_enabled ? [1] : []

    content {
      sid = "UseBucketKey"
      actions = [
        "kms:Decrypt",
        "kms:DescribeKey",
        "kms:Encrypt",
        "kms:GenerateDataKey",
        "kms:ReEncrypt*",
      ]
      resources = [aws_kms_key.blobs[0].arn]
    }
  }
}
