# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: MPL-2.0

# Plan-only tests for modules/storage (no AWS credentials needed).

mock_provider "aws" {
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

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  name = "oa-test"
}

run "secure_defaults" {
  command = plan

  module {
    source = "./modules/storage"
  }

  assert {
    condition     = aws_s3_bucket.this.bucket == "oa-test-blobs-123456789012-eu-west-1"
    error_message = "Default bucket name must be <name>-blobs-<account_id>-<region>."
  }

  assert {
    condition     = aws_s3_bucket.this.force_destroy == false
    error_message = "force_destroy must default to false."
  }

  assert {
    condition     = aws_s3_bucket_ownership_controls.this.rule[0].object_ownership == "BucketOwnerEnforced"
    error_message = "ACLs must be disabled with BucketOwnerEnforced."
  }

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.this.block_public_acls,
      aws_s3_bucket_public_access_block.this.block_public_policy,
      aws_s3_bucket_public_access_block.this.ignore_public_acls,
      aws_s3_bucket_public_access_block.this.restrict_public_buckets,
    ])
    error_message = "All four public access block settings must be true."
  }

  assert {
    condition     = length(aws_kms_key.blobs) == 1 && aws_kms_key.blobs[0].enable_key_rotation == true
    error_message = "A dedicated CMK with automatic rotation must be created by default."
  }

  assert {
    condition     = aws_kms_key.blobs[0].deletion_window_in_days == 30
    error_message = "KMS deletion window must default to 30 days."
  }

  assert {
    condition     = aws_kms_alias.blobs[0].name == "alias/oa-test-storage"
    error_message = "KMS alias must be alias/<name>-storage."
  }

  assert {
    condition = (
      one(aws_s3_bucket_server_side_encryption_configuration.this.rule).apply_server_side_encryption_by_default[0].sse_algorithm == "aws:kms"
      && one(aws_s3_bucket_server_side_encryption_configuration.this.rule).bucket_key_enabled == true
    )
    error_message = "Default encryption must be aws:kms with the S3 bucket key enabled."
  }

  assert {
    condition     = aws_s3_bucket_versioning.this.versioning_configuration[0].status == "Enabled"
    error_message = "Versioning must be enabled by default."
  }

  assert {
    condition     = toset([for r in aws_s3_bucket_lifecycle_configuration.this.rule : r.id]) == toset(["abort-incomplete-multipart-uploads", "expire-noncurrent-versions", "remove-expired-delete-markers"])
    error_message = "Lifecycle must abort multipart uploads, expire noncurrent versions and remove expired delete markers."
  }

  assert {
    condition     = length(aws_s3_bucket_logging.this) == 0
    error_message = "Access logging must be off unless configured."
  }

  assert {
    condition     = toset([for s in data.aws_iam_policy_document.bucket.statement : s.sid]) == toset(["DenyInsecureTransport", "DenyTlsBelow12", "DenyWrongServerSideEncryption", "DenyWrongKmsKey"])
    error_message = "Bucket policy must deny insecure transport, old TLS, wrong SSE algorithm and wrong KMS key."
  }

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.bucket.statement : s.effect == "Deny"
    ])
    error_message = "Every bucket policy statement must be a Deny."
  }

  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.bucket.statement :
      s.sid == "DenyInsecureTransport" && anytrue([for c in s.condition : c.variable == "aws:SecureTransport" && toset(c.values) == toset(["false"])])
    ])
    error_message = "DenyInsecureTransport must match aws:SecureTransport = false."
  }

  assert {
    condition     = length(data.aws_iam_policy_document.kms_key) == 1 && length(data.aws_iam_policy_document.kms_key[0].statement) == 1
    error_message = "The key policy must contain exactly the account-root statement."
  }

  assert {
    condition = alltrue([
      for p in data.aws_iam_policy_document.kms_key[0].statement[0].principals : !contains(p.identifiers, "*")
    ])
    error_message = "The key policy must not use wildcard principals."
  }

  assert {
    condition     = toset([for s in data.aws_iam_policy_document.access.statement : s.sid]) == toset(["ListBucket", "ReadWriteObjects", "UseBucketKey"])
    error_message = "Access policy must cover bucket listing, object IO and the KMS key when a CMK is used."
  }

  assert {
    condition = alltrue(flatten([
      for s in data.aws_iam_policy_document.access.statement : [for a in s.actions : !endswith(a, ":*")]
    ]))
    error_message = "The access policy must not grant service-wide wildcards."
  }
}

run "aws_managed_key" {
  command = plan

  module {
    source = "./modules/storage"
  }

  variables {
    kms_mode = "aws_managed"
  }

  assert {
    condition     = length(aws_kms_key.blobs) == 0 && length(aws_kms_alias.blobs) == 0
    error_message = "No CMK may be created in aws_managed mode."
  }

  assert {
    condition     = one(aws_s3_bucket_server_side_encryption_configuration.this.rule).apply_server_side_encryption_by_default[0].sse_algorithm == "aws:kms"
    error_message = "aws_managed mode must still use aws:kms (aws/s3 key)."
  }

  assert {
    condition     = output.kms_key_arn == null && output.kms_key_id == null
    error_message = "kms_key_arn and kms_key_id must be null in aws_managed mode."
  }

  assert {
    condition     = toset([for s in data.aws_iam_policy_document.access.statement : s.sid]) == toset(["ListBucket", "ReadWriteObjects"])
    error_message = "No KMS statement is expected in the access policy in aws_managed mode."
  }

  assert {
    condition     = !contains([for s in data.aws_iam_policy_document.bucket.statement : s.sid], "DenyWrongKmsKey")
    error_message = "The KMS key pin must not exist without a CMK."
  }
}

run "versioning_disabled" {
  command = plan

  module {
    source = "./modules/storage"
  }

  variables {
    versioning_enabled = false
  }

  assert {
    condition     = aws_s3_bucket_versioning.this.versioning_configuration[0].status == "Suspended"
    error_message = "Disabled versioning must map to Suspended."
  }

  assert {
    condition     = toset([for r in aws_s3_bucket_lifecycle_configuration.this.rule : r.id]) == toset(["abort-incomplete-multipart-uploads"])
    error_message = "Noncurrent expiry and delete-marker cleanup only apply with versioning."
  }
}

run "custom_bucket_logging_and_force_destroy" {
  command = plan

  module {
    source = "./modules/storage"
  }

  variables {
    bucket_name   = "my-custom-bucket"
    force_destroy = true
    access_logging = {
      target_bucket = "central-logs"
    }
    noncurrent_version_expiration_days = 14
    abort_incomplete_multipart_days    = 3
    tags                               = { Env = "test" }
  }

  assert {
    condition     = aws_s3_bucket.this.bucket == "my-custom-bucket" && aws_s3_bucket.this.force_destroy == true
    error_message = "Explicit bucket name and force_destroy must be honoured."
  }

  assert {
    condition     = length(aws_s3_bucket_logging.this) == 1 && aws_s3_bucket_logging.this[0].target_bucket == "central-logs" && aws_s3_bucket_logging.this[0].target_prefix == "s3/"
    error_message = "Access logging must target the given bucket with the default s3/ prefix."
  }

  assert {
    condition = (
      one([for r in aws_s3_bucket_lifecycle_configuration.this.rule : r.noncurrent_version_expiration[0].noncurrent_days if r.id == "expire-noncurrent-versions"]) == 14
      && one([for r in aws_s3_bucket_lifecycle_configuration.this.rule : r.abort_incomplete_multipart_upload[0].days_after_initiation if r.id == "abort-incomplete-multipart-uploads"]) == 3
    )
    error_message = "Lifecycle day variables must be applied."
  }

  assert {
    condition     = aws_s3_bucket.this.tags["Env"] == "test" && aws_kms_key.blobs[0].tags["Env"] == "test"
    error_message = "Tags must propagate to the bucket and the key."
  }
}

run "rejects_invalid_kms_mode" {
  command = plan

  module {
    source = "./modules/storage"
  }

  variables {
    kms_mode = "none"
  }

  expect_failures = [var.kms_mode]
}

run "rejects_invalid_name" {
  command = plan

  module {
    source = "./modules/storage"
  }

  variables {
    name = "Bad_Name"
  }

  expect_failures = [var.name]
}

run "rejects_short_deletion_window" {
  command = plan

  module {
    source = "./modules/storage"
  }

  variables {
    kms_key_deletion_window_days = 3
  }

  expect_failures = [var.kms_key_deletion_window_days]
}

run "rejects_empty_logging_target" {
  command = plan

  module {
    source = "./modules/storage"
  }

  variables {
    access_logging = {
      target_bucket = ""
    }
  }

  expect_failures = [var.access_logging]
}
