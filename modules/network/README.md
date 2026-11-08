<!--
SPDX-FileCopyrightText: The OpenArtifact Authors

SPDX-License-Identifier: MPL-2.0
-->

# network

A small, production-shaped VPC for OpenArtifact: public subnets for the load balancer and NAT gateways, private subnets for tasks, pods and the database, an S3 gateway endpoint and VPC flow logs. Use it when you do not already have a VPC; every other module only needs a VPC ID and subnet IDs, so an existing network works just as well.

## Layout

`az_count` (2 or 3) availability zones, each with one private and one public subnet:

| Subnets | Placement inside `cidr` | Size with a /16 |
| --- | --- | --- |
| private | the first three quarters, one per AZ | /18 |
| public | carved from the last quarter, one per AZ | /20 |

Public subnets route to the internet gateway; private subnets route `0.0.0.0/0` to a NAT gateway (`nat_gateway_mode = "single"` shares one in the first AZ, `"per_az"` creates one per AZ and keeps egress inside its AZ) and S3 traffic through a gateway endpoint that is attached to every private route table.

## Usage

```hcl
module "network" {
  source  = "openartifact/openartifact/aws//modules/network"
  version = "~> 0.1"

  name             = "openartifact"
  cidr             = "10.20.0.0/16"
  az_count         = 3
  nat_gateway_mode = "per_az"
}
```

Until a release is published, use the Git source instead:
`git::https://github.com/openartifact/terraform-aws-openartifact.git//modules/network?ref=vX.Y.Z`.

Feed `private_subnet_ids` to the application and database, `public_subnet_ids` to an internet-facing load balancer, and allow `nat_gateway_public_ips` in the allow-lists of upstream registries you proxy.

## Security notes

- **The default security group is stripped of all rules** (`aws_default_security_group` without rule blocks), so nothing can silently depend on it. Create dedicated security groups.
- **No public IPs on launch**, not even in the public subnets: only the load balancer nodes and NAT gateways are reachable from the internet. Tasks and databases live in private subnets.
- **Flow logs** capture ALL traffic at 60-second aggregation into a CloudWatch Logs group (default 90 days retention). The IAM role that delivers them can only be assumed by the VPC flow logs service for this account and is limited to this log group. Pass `flow_logs_kms_key_arn` to encrypt the log group with your own key; its key policy must allow `logs.<region>.amazonaws.com`.
- **NAT cost and availability.** `single` mode is cheaper but all private egress fails if the AZ hosting the NAT gateway fails; use `per_az` for production.
- The S3 gateway endpoint uses the default (full access) endpoint policy; restrict access with the bucket policy of the storage module.
- IPv6 and interface endpoints (ECR, Secrets Manager, CloudWatch Logs) are not created; add them in the consuming stack if you want to avoid NAT traffic for those services.

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
| [aws_cloudwatch_log_group.flow_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_default_security_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/default_security_group) | resource |
| [aws_eip.nat](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eip) | resource |
| [aws_flow_log.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/flow_log) | resource |
| [aws_iam_role.flow_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.flow_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_internet_gateway.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/internet_gateway) | resource |
| [aws_nat_gateway.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/nat_gateway) | resource |
| [aws_route.private_nat](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route) | resource |
| [aws_route.public_internet](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route) | resource |
| [aws_route_table.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table) | resource |
| [aws_route_table.public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table) | resource |
| [aws_route_table_association.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table_association) | resource |
| [aws_route_table_association.public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table_association) | resource |
| [aws_subnet.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet) | resource |
| [aws_subnet.public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet) | resource |
| [aws_vpc.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc) | resource |
| [aws_vpc_endpoint.s3](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_endpoint) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_az_count"></a> [az\_count](#input\_az\_count) | Number of availability zones to spread public and private subnets across (2 or 3). | `number` | `2` | no |
| <a name="input_cidr"></a> [cidr](#input\_cidr) | IPv4 CIDR block of the VPC, a network address with a prefix length between /16 and /22. The first three quarters hold one private subnet per AZ (prefix + 2 bits); the last quarter holds the public subnets (prefix + 4 bits). | `string` | `"10.0.0.0/16"` | no |
| <a name="input_flow_logs_enabled"></a> [flow\_logs\_enabled](#input\_flow\_logs\_enabled) | Send VPC flow logs (all traffic) to a CloudWatch Logs group. | `bool` | `true` | no |
| <a name="input_flow_logs_kms_key_arn"></a> [flow\_logs\_kms\_key\_arn](#input\_flow\_logs\_kms\_key\_arn) | ARN of a KMS key to encrypt the flow log group. The key policy must allow the CloudWatch Logs service principal (logs.<region>.amazonaws.com) to use it. null leaves the log group with the default CloudWatch Logs encryption. | `string` | `null` | no |
| <a name="input_flow_logs_retention_days"></a> [flow\_logs\_retention\_days](#input\_flow\_logs\_retention\_days) | Retention in days of the flow log group. Must be a value CloudWatch Logs accepts; 0 (never expire) is not allowed. | `number` | `90` | no |
| <a name="input_name"></a> [name](#input\_name) | Name prefix for the VPC and its resources (lowercase letters, digits and hyphens, 3-24 characters). | `string` | n/a | yes |
| <a name="input_nat_gateway_mode"></a> [nat\_gateway\_mode](#input\_nat\_gateway\_mode) | "single" shares one NAT gateway (cheaper, but the AZ hosting it is a single point of failure for egress); "per\_az" creates one NAT gateway per AZ (highly available, one NAT gateway charge per AZ). | `string` | `"single"` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to every resource. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_availability_zones"></a> [availability\_zones](#output\_availability\_zones) | Names of the availability zones in use, in subnet order. |
| <a name="output_nat_gateway_public_ips"></a> [nat\_gateway\_public\_ips](#output\_nat\_gateway\_public\_ips) | Public IPs (elastic IPs) of the NAT gateways: the source addresses of all outbound traffic, useful for upstream allow-lists. |
| <a name="output_private_route_table_ids"></a> [private\_route\_table\_ids](#output\_private\_route\_table\_ids) | IDs of the private route tables, in availability zone order. |
| <a name="output_private_subnet_ids"></a> [private\_subnet\_ids](#output\_private\_subnet\_ids) | IDs of the private subnets (for tasks, pods and the database), in availability zone order. |
| <a name="output_public_subnet_ids"></a> [public\_subnet\_ids](#output\_public\_subnet\_ids) | IDs of the public subnets (for load balancers), in availability zone order. |
| <a name="output_s3_gateway_endpoint_id"></a> [s3\_gateway\_endpoint\_id](#output\_s3\_gateway\_endpoint\_id) | ID of the S3 gateway VPC endpoint attached to the private route tables. |
| <a name="output_vpc_cidr_block"></a> [vpc\_cidr\_block](#output\_vpc\_cidr\_block) | IPv4 CIDR block of the VPC. |
| <a name="output_vpc_id"></a> [vpc\_id](#output\_vpc\_id) | ID of the VPC. |
<!-- END_TF_DOCS -->
