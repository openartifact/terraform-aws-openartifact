<!--
SPDX-FileCopyrightText: The OpenArtifact Authors

SPDX-License-Identifier: MPL-2.0
-->

# storage

S3 blob store for OpenArtifact (`STORAGE_BACKEND=s3`): a private, versioned, KMS-encrypted bucket plus the least-privilege IAM policy the OpenArtifact workload needs to use it.

The module creates:

- the bucket, with ACLs disabled (`BucketOwnerEnforced`) and all four public access block settings on;
- default encryption with SSE-KMS and the S3 bucket key (fewer KMS requests, lower cost), using either a dedicated customer managed key with automatic rotation (`kms_mode = "cmk"`, the default) or the AWS managed `aws/s3` key (`kms_mode = "aws_managed"`);
- versioning and a lifecycle policy that aborts incomplete multipart uploads, expires noncurrent versions and removes expired delete markers;
- a bucket policy that denies non-TLS access, TLS older than 1.2, and uploads that explicitly ask for another encryption algorithm or (with a CMK) another KMS key;
- optional S3 server access logging;
- an `access_policy_json` output: a ready-to-attach IAM policy scoped to this bucket and key.

## Usage

```hcl
module "storage" {
  source  = "openartifact/openartifact/aws//modules/storage"
  version = "~> 0.1"

  name = "openartifact"
}

# Attach the least-privilege policy to the workload role (ECS task role,
# IRSA or EKS Pod Identity role).
resource "aws_iam_role_policy" "blobs" {
  name   = "openartifact-blobs"
  role   = aws_iam_role.openartifact.id
  policy = module.storage.access_policy_json
}
```

Until a release is published, use the Git source instead:
`git::https://github.com/openartifact/terraform-aws-openartifact.git//modules/storage?ref=vX.Y.Z`.

Point the application at the bucket with `STORAGE_BACKEND=s3`, `STORAGE_BUCKET=<bucket_id>` and `STORAGE_REGION=<bucket_region>`. No access keys are needed or created: the application uses the workload's IAM role.

## Security notes

- **Customer managed key by default.** The key policy only delegates to IAM through the account root principal (no wildcard principals), so only identities with explicit `kms:*` permissions, such as the role that receives `access_policy_json`, can use it. Rotation is enabled. Destroying the module schedules key deletion after `kms_key_deletion_window_days` (default 30); data encrypted with a deleted key is unrecoverable.
- **`aws_managed` mode** avoids the key cost but gives no key policy control and no per-key CloudTrail separation. The `aws/s3` key policy already allows every principal in the account to use it through S3, so `access_policy_json` contains no KMS statement in this mode.
- **Reads need KMS permissions.** Any additional principal that reads blobs (backup jobs, replication roles, presigned-URL signers) needs `kms:Decrypt` on `kms_key_arn` in addition to `s3:GetObject`.
- **Encryption deny statements use `...IfExists`.** Uploads that carry no encryption header fall back to the bucket default (SSE-KMS with the module key) and are accepted; uploads that explicitly request SSE-S3 or SSE-C, or another KMS key, are rejected.
- **Versioning.** With `versioning_enabled = true` deleted or overwritten blobs remain recoverable for `noncurrent_version_expiration_days`. S3 cannot return a versioned bucket to the unversioned state, so disabling versioning later sets it to `Suspended`.
- **`force_destroy` defaults to `false`.** The bucket holds every artifact; a `terraform destroy` fails while it is not empty, which is the safe behaviour.
- **Access logging** needs an existing target bucket that allows `logging.s3.amazonaws.com` to write; the module does not manage the log bucket.
- Cross-region replication and S3 Object Lock are out of scope; configure them in the consuming stack if your recovery objectives require them.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 6.72 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_aws"></a> [aws](#provider\_aws) | ~> 6.72 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_kms_alias.blobs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.blobs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_s3_bucket.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_logging.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_logging) | resource |
| [aws_s3_bucket_ownership_controls.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_abort_incomplete_multipart_days"></a> [abort\_incomplete\_multipart\_days](#input\_abort\_incomplete\_multipart\_days) | Days after which incomplete multipart uploads are aborted and their parts deleted. | `number` | `7` | no |
| <a name="input_access_logging"></a> [access\_logging](#input\_access\_logging) | S3 server access logging. Set target\_bucket to an existing bucket that grants the S3 logging service principal (logging.s3.amazonaws.com) PutObject; null disables access logging. | <pre>object({<br/>    target_bucket = string<br/>    target_prefix = optional(string, "s3/")<br/>  })</pre> | `null` | no |
| <a name="input_bucket_name"></a> [bucket\_name](#input\_bucket\_name) | Explicit S3 bucket name. When null the bucket is named "<name>-blobs-<account\_id>-<region>". | `string` | `null` | no |
| <a name="input_force_destroy"></a> [force\_destroy](#input\_force\_destroy) | Delete the bucket with all objects (and versions) on destroy. Leave false in production: the bucket holds every stored artifact. | `bool` | `false` | no |
| <a name="input_kms_key_deletion_window_days"></a> [kms\_key\_deletion\_window\_days](#input\_kms\_key\_deletion\_window\_days) | Waiting period in days before the dedicated KMS key is deleted after destroy (7-30). Only used when kms\_mode is "cmk". | `number` | `30` | no |
| <a name="input_kms_mode"></a> [kms\_mode](#input\_kms\_mode) | Server-side encryption key: "cmk" creates a dedicated customer managed KMS key (rotation on, recommended); "aws\_managed" uses the AWS managed aws/s3 key (no key to manage, but no key-policy control or per-key audit trail). | `string` | `"cmk"` | no |
| <a name="input_name"></a> [name](#input\_name) | Name prefix for the bucket, KMS alias and tags (lowercase letters, digits and hyphens, 3-24 characters). | `string` | n/a | yes |
| <a name="input_noncurrent_version_expiration_days"></a> [noncurrent\_version\_expiration\_days](#input\_noncurrent\_version\_expiration\_days) | Days after which noncurrent object versions are permanently deleted. Only used when versioning\_enabled is true. | `number` | `30` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to every resource. | `map(string)` | `{}` | no |
| <a name="input_versioning_enabled"></a> [versioning\_enabled](#input\_versioning\_enabled) | Keep previous object versions. Recommended: it protects blobs against accidental or malicious deletes. When false, versioning is set to Suspended (S3 cannot return to the never-versioned state). | `bool` | `true` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_access_policy_json"></a> [access\_policy\_json](#output\_access\_policy\_json) | Least-privilege IAM policy (JSON) for the OpenArtifact workload identity: list/read/write/delete objects and multipart uploads in the bucket plus use of the dedicated KMS key. Attach it to the ECS task role or the EKS IRSA/Pod Identity role. |
| <a name="output_bucket_arn"></a> [bucket\_arn](#output\_bucket\_arn) | ARN of the S3 bucket. |
| <a name="output_bucket_id"></a> [bucket\_id](#output\_bucket\_id) | Name (ID) of the S3 bucket. |
| <a name="output_bucket_region"></a> [bucket\_region](#output\_bucket\_region) | AWS region of the S3 bucket. |
| <a name="output_kms_key_arn"></a> [kms\_key\_arn](#output\_kms\_key\_arn) | ARN of the dedicated customer managed KMS key; null when kms\_mode is "aws\_managed". |
| <a name="output_kms_key_id"></a> [kms\_key\_id](#output\_kms\_key\_id) | ID of the dedicated customer managed KMS key; null when kms\_mode is "aws\_managed". |
<!-- END_TF_DOCS -->
