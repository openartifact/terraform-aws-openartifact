# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: MPL-2.0

output "bucket_id" {
  description = "Name (ID) of the S3 bucket."
  value       = aws_s3_bucket.this.id
}

output "bucket_arn" {
  description = "ARN of the S3 bucket."
  value       = aws_s3_bucket.this.arn
}

output "bucket_region" {
  description = "AWS region of the S3 bucket."
  value       = aws_s3_bucket.this.region
}

output "kms_key_arn" {
  description = "ARN of the dedicated customer managed KMS key; null when kms_mode is \"aws_managed\"."
  value       = one(aws_kms_key.blobs[*].arn)
}

output "kms_key_id" {
  description = "ID of the dedicated customer managed KMS key; null when kms_mode is \"aws_managed\"."
  value       = one(aws_kms_key.blobs[*].key_id)
}

output "access_policy_json" {
  description = "Least-privilege IAM policy (JSON) for the OpenArtifact workload identity: list/read/write/delete objects and multipart uploads in the bucket plus use of the dedicated KMS key. Attach it to the ECS task role or the EKS IRSA/Pod Identity role."
  value       = data.aws_iam_policy_document.access.json
}
