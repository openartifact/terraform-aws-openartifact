<!--
SPDX-FileCopyrightText: The OpenArtifact Authors

SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Minimal example

The smallest complete OpenArtifact deployment on ECS Fargate: a new VPC (two Availability Zones, one NAT gateway), one web task behind an HTTPS Application Load Balancer, a single-AZ PostgreSQL database and a private, encrypted S3 bucket. Suitable for evaluation and non-production; for a production-shaped setup see [`../complete`](../complete).

What it deliberately trades away to keep the cost low:

- one NAT gateway (outbound traffic stops if its Availability Zone is down);
- one web task and no autoscaling;
- a single-AZ `db.t4g.micro` database without Performance Insights.

Deletion protection of the database and the load balancer stays on, so a `terraform destroy` fails until you turn it off (see the comment in `main.tf`).

## Usage

```sh
cp terraform.tfvars.example terraform.tfvars   # set certificate_arn and allowed_ingress_cidrs
terraform init
terraform apply
```

The module call, as you would write it with the registry source:

```hcl
module "openartifact" {
  source  = "openartifact/openartifact/aws"
  version = "~> 0.1"

  name = "openartifact"

  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids
  public_subnet_ids  = module.network.public_subnet_ids

  certificate_arn       = "arn:aws:acm:eu-west-1:111122223333:certificate/..."
  allowed_ingress_cidrs = ["203.0.113.0/24"]

  web_desired_count = 1
  web_autoscaling   = { enabled = false }
  db_multi_az       = false
}
```

After the apply, point your DNS name at `alb_dns_name` (a CNAME, or an alias record with `alb_zone_id`) and read the initial admin password from the `bootstrap_admin_password_secret_arn` secret. The example needs an ACM certificate in the same region and has no default for `allowed_ingress_cidrs`: you decide who may reach the repository.

The state is kept locally unless you uncomment the `backend "s3"` block in `versions.tf` (native S3 locking, no DynamoDB table).

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 6.72 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_network"></a> [network](#module\_network) | ../../modules/network | n/a |
| <a name="module_openartifact"></a> [openartifact](#module\_openartifact) | ../.. | n/a |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_allowed_ingress_cidrs"></a> [allowed\_ingress\_cidrs](#input\_allowed\_ingress\_cidrs) | IPv4 CIDR blocks allowed to reach the ALB, for example your office or VPN range. No default: decide who may reach your artifact repository. | `list(string)` | n/a | yes |
| <a name="input_base_url"></a> [base\_url](#input\_base\_url) | Public URL of the repository, for example https://artifacts.example.com. Null falls back to the ALB DNS name. | `string` | `null` | no |
| <a name="input_certificate_arn"></a> [certificate\_arn](#input\_certificate\_arn) | ARN of the ACM certificate for the HTTPS listener, in the same region. It must cover the host name of base\_url (or the ALB DNS name when base\_url is null). | `string` | n/a | yes |
| <a name="input_name"></a> [name](#input\_name) | Name of the deployment and prefix of every resource (3-17 characters: lowercase letters, digits and hyphens). | `string` | `"openartifact"` | no |
| <a name="input_region"></a> [region](#input\_region) | AWS region to deploy into. The ACM certificate must be in the same region. | `string` | `"eu-west-1"` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Extra tags for every resource, merged into the provider default\_tags. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_alb_dns_name"></a> [alb\_dns\_name](#output\_alb\_dns\_name) | DNS name of the ALB: create a CNAME (or alias record) from your host name to it. |
| <a name="output_alb_zone_id"></a> [alb\_zone\_id](#output\_alb\_zone\_id) | Route 53 hosted zone ID of the ALB, for alias records. |
| <a name="output_bootstrap_admin_password_secret_arn"></a> [bootstrap\_admin\_password\_secret\_arn](#output\_bootstrap\_admin\_password\_secret\_arn) | Secret holding the initial admin password: aws secretsmanager get-secret-value --secret-id <arn> --query SecretString --output text. Used only on an empty instance; change it after the first login. |
| <a name="output_nat_gateway_public_ips"></a> [nat\_gateway\_public\_ips](#output\_nat\_gateway\_public\_ips) | Source addresses of all outbound traffic of the deployment, useful for upstream allow-lists of proxy repositories. |
| <a name="output_url"></a> [url](#output\_url) | URL to open in the browser (base\_url, or the ALB DNS name when base\_url is null). |
<!-- END_TF_DOCS -->
