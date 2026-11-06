<!--
SPDX-FileCopyrightText: The OpenArtifact Authors

SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Complete example

A production-shaped OpenArtifact deployment on ECS Fargate, built from the `network` module and the root module plus the supporting resources a real environment needs:

- **Network**: three Availability Zones with one NAT gateway each (`per_az`), flow logs encrypted with a customer-managed key.
- **Services**: separate `web` and `worker` services (`worker_enabled`), the web service autoscaling on CPU and on requests per target.
- **Database**: Multi-AZ PostgreSQL with Performance Insights, Enhanced Monitoring and 35 days of backups.
- **WAFv2** (`waf.tf`): a regional web ACL with the AWS managed Common, Known Bad Inputs and IP Reputation rule groups plus a per-IP rate limit, associated with the ALB through `waf_acl_arn` and `waf_acl_enabled`.
- **Logging** (`logging.tf`): ALB access logs and S3 server access logs of the blob bucket delivered to two dedicated, private buckets; CloudWatch log groups encrypted with a customer-managed key.
- **Encryption**: customer-managed KMS keys for logs and application secrets (the storage and database keys are created by the module).

## Usage

```sh
cp terraform.tfvars.example terraform.tfvars   # set certificate_arn, allowed_ingress_cidrs and base_url
terraform init
terraform apply
```

Notes:

- The WAF rate limit counts requests per source IP over five minutes. CI runners usually share a few NAT addresses, so size `waf_rate_limit` for your busiest client. The `SizeRestrictions_BODY` rule of the Common rule set is set to count: artifact uploads are large request bodies and would otherwise be blocked. Run new WAF rules in count mode first and read the sampled requests before blocking.
- WAF request logging is not configured: it needs a log group named `aws-waf-logs-*` and a log resource policy, which depend on your logging setup.
- ALB access logs and S3 server access logs cannot be delivered to a bucket encrypted with a KMS key, so the two log buckets use SSE-S3; everything else uses customer-managed keys.
- Deletion protection of the database and the load balancer stays on; to destroy the example, add `db_deletion_protection = false` and `alb_deletion_protection = false` to the module call and apply first.
- The state is kept locally unless you uncomment the `backend "s3"` block in `versions.tf`.

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

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_network"></a> [network](#module\_network) | ../../modules/network | n/a |
| <a name="module_openartifact"></a> [openartifact](#module\_openartifact) | ../.. | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_kms_alias.logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_alias.secrets](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_kms_key.secrets](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_s3_bucket.access_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.access_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_ownership_controls.access_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_policy.access_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.access_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.access_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.access_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_wafv2_web_acl.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/wafv2_web_acl) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_allowed_ingress_cidrs"></a> [allowed\_ingress\_cidrs](#input\_allowed\_ingress\_cidrs) | IPv4 CIDR blocks allowed to reach the ALB (before the WAF), for example your office, VPN and CI egress ranges. No default: decide who may reach your artifact repository. | `list(string)` | n/a | yes |
| <a name="input_base_url"></a> [base\_url](#input\_base\_url) | Public URL of the repository, for example https://artifacts.example.com. Required for SSO, SAML and webhooks. | `string` | n/a | yes |
| <a name="input_certificate_arn"></a> [certificate\_arn](#input\_certificate\_arn) | ARN of the ACM certificate for the HTTPS listener, in the same region. It must cover the host name of base\_url. | `string` | n/a | yes |
| <a name="input_image_digest"></a> [image\_digest](#input\_image\_digest) | Image digest (sha256:<64 hex>) to pin the exact OpenArtifact image; wins over the default tag. Null deploys the module's default tag. | `string` | `null` | no |
| <a name="input_log_retention_days"></a> [log\_retention\_days](#input\_log\_retention\_days) | Retention in days of the CloudWatch log groups and of the objects in the access log buckets. | `number` | `90` | no |
| <a name="input_name"></a> [name](#input\_name) | Name of the deployment and prefix of every resource (3-17 characters: lowercase letters, digits and hyphens). | `string` | `"openartifact"` | no |
| <a name="input_region"></a> [region](#input\_region) | AWS region to deploy into. The ACM certificate must be in the same region. | `string` | `"eu-west-1"` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Extra tags for every resource, merged into the provider default\_tags. | `map(string)` | `{}` | no |
| <a name="input_waf_rate_limit"></a> [waf\_rate\_limit](#input\_waf\_rate\_limit) | Maximum number of requests from one IP address within the 5-minute WAF window before it is blocked. Package managers are chatty and CI runners share NAT addresses, so size it for your busiest client. | `number` | `10000` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_access_log_buckets"></a> [access\_log\_buckets](#output\_access\_log\_buckets) | Names of the buckets that receive the ALB access logs (alb) and the blob bucket server access logs (s3). |
| <a name="output_alb_dns_name"></a> [alb\_dns\_name](#output\_alb\_dns\_name) | DNS name of the ALB: create a CNAME (or alias record) from your host name to it. |
| <a name="output_alb_zone_id"></a> [alb\_zone\_id](#output\_alb\_zone\_id) | Route 53 hosted zone ID of the ALB, for alias records. |
| <a name="output_bootstrap_admin_password_secret_arn"></a> [bootstrap\_admin\_password\_secret\_arn](#output\_bootstrap\_admin\_password\_secret\_arn) | Secret holding the initial admin password: aws secretsmanager get-secret-value --secret-id <arn> --query SecretString --output text. Used only on an empty instance; change it after the first login. |
| <a name="output_kms_key_arns"></a> [kms\_key\_arns](#output\_kms\_key\_arns) | ARNs of the customer-managed KMS keys: storage, database (from the module), secrets and logs (from this example). |
| <a name="output_nat_gateway_public_ips"></a> [nat\_gateway\_public\_ips](#output\_nat\_gateway\_public\_ips) | Source addresses of all outbound traffic of the deployment (one NAT gateway per AZ), useful for upstream allow-lists of proxy repositories. |
| <a name="output_url"></a> [url](#output\_url) | Public URL of the repository (base\_url). |
| <a name="output_web_acl_arn"></a> [web\_acl\_arn](#output\_web\_acl\_arn) | ARN of the WAFv2 web ACL associated with the ALB. |
| <a name="output_web_service_name"></a> [web\_service\_name](#output\_web\_service\_name) | Name of the web ECS service. |
| <a name="output_worker_service_name"></a> [worker\_service\_name](#output\_worker\_service\_name) | Name of the worker ECS service. |
<!-- END_TF_DOCS -->
