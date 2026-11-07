<!--
SPDX-FileCopyrightText: The OpenArtifact Authors

SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ecs-ec2-capacity

EC2 container instances for an ECS cluster, as an alternative to Fargate: a launch template from the ECS-optimized Amazon Linux 2023 AMI, an Auto Scaling group per purchase option (On-Demand always, Spot optionally) and an ECS capacity provider for each, attached to the cluster.

The root module creates it when `capacity_type = "EC2"` and passes the capacity provider names to the web and worker services (`capacity_provider_strategy` of `modules/ecs-service`). You can use it on its own with any ECS cluster whose tasks use `awsvpc` networking.

## Usage

```hcl
module "ec2_capacity" {
  source  = "openartifact/openartifact/aws//modules/ecs-ec2-capacity"
  version = "~> 0.2"

  name         = "openartifact"
  cluster_name = aws_ecs_cluster.this.name
  vpc_id       = "vpc-0123456789abcdef0"
  subnet_ids   = ["subnet-0aaaaaaaaaaaaaaa1", "subnet-0bbbbbbbbbbbbbbb2"] # private subnets

  cpu_architecture = "ARM64"
  min_size         = 1
  max_size         = 4
}

module "service" {
  source = "openartifact/openartifact/aws//modules/ecs-service"
  # ...
  capacity_provider_strategy = [
    { capacity_provider = module.ec2_capacity.capacity_provider_names.on_demand, weight = 1 },
  ]
}
```

The module attaches its capacity providers to the cluster with `aws_ecs_cluster_capacity_providers`, which owns the whole list: do not manage other capacity providers of the same cluster separately.

## Security model

- **Identity.** The instance role has `AmazonEC2ContainerServiceforEC2Role` (agent registration, image pulls, logs) and `AmazonSSMManagedInstanceCore` (Session Manager) and nothing else. There is no SSH, no key pair and no inbound rule: use `aws ssm start-session`.
- **Instance metadata.** IMDSv2 is required (`http_tokens = "required"`), with a hop limit of 1: the ECS agent runs in the host network namespace and needs no more. awsvpc tasks are additionally blocked from the instance metadata service by `ECS_AWSVPC_BLOCK_IMDS=true`; their task role is served by the agent, not by IMDS. The hop limit of 1 is a reasoned choice that was not verified against a live cluster.
- **Network.** No public IP, forced through an explicit network interface. The security group allows HTTPS egress only (`egress_https_cidr_blocks`, `egress_https_prefix_list_ids`: image pulls, ECS, CloudWatch Logs, Secrets Manager and SSM calls happen on the host) plus the rules you add in `egress_security_group_rules` (NFS to the EFS mount targets: the agent mounts EFS volumes on the instance). Tasks keep their own security groups.
- **Disk.** The gp3 root volume is encrypted (AWS managed key or `kms_key_arn`). The key policy must allow the Auto Scaling service-linked role.
- **User data** only appends the ECS agent configuration (`ECS_CLUSTER`, `ECS_ENABLE_CONTAINER_METADATA`, `ECS_AWSVPC_BLOCK_IMDS`, `ECS_ENABLE_SPOT_INSTANCE_DRAINING`, `ECS_ENGINE_TASK_CLEANUP_WAIT_DURATION`) to `/etc/ecs/ecs.config`.

## Scaling and lifecycle

- Capacity providers use managed scaling (`target_capacity`), managed termination protection (the groups protect their instances from scale-in) and managed draining: tasks are moved away before an instance is terminated, which also lets the instance refresh replace protected instances.
- A new launch template version (a new AMI release, other user data or volume) starts a rolling instance refresh with `min_healthy_percentage = 90`. The AMI is resolved from the public SSM parameter at plan time, so it only changes when you run `apply`; this module does not patch instances in between. Pass `ami_id` to pin one.
- `min_size` applies to the On-Demand group; the Spot group (`spot_enabled`) starts from zero. Both scale to `max_size`.
- The groups are created with `force_delete`, so destroying the stack is not blocked by scale-in protected instances.

## Sizing

The default instance types are `m7g.large` and `m6g.large` (`m7i.large` and `m6i.large` for `X86_64`): 2 vCPU and 8 GiB hold two 1 vCPU / 2 GiB tasks. In `awsvpc` mode each task needs its own network interface and the instance uses one, so a type with three interfaces fits two tasks. ENI trunking (the `awsvpcTrunking` account setting, available on selected instance types) raises that limit; it is an account-wide setting this module does not manage. Instance types must all match `cpu_architecture`.

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
| [aws_autoscaling_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/autoscaling_group) | resource |
| [aws_ecs_capacity_provider.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_capacity_provider) | resource |
| [aws_ecs_cluster_capacity_providers.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_cluster_capacity_providers) | resource |
| [aws_iam_instance_profile.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_instance_profile) | resource |
| [aws_iam_role.instance](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.instance](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_launch_template.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/launch_template) | resource |
| [aws_security_group.instance](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_vpc_security_group_egress_rule.https_cidr](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_egress_rule.https_prefix_list](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_egress_rule.to_security_group](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_ami_id"></a> [ami\_id](#input\_ami\_id) | ID of the AMI of the instances: an ECS-optimized Amazon Linux 2023 image (or a derivative with the ECS agent and the SSM agent) of the architecture cpu\_architecture. Null resolves the recommended ECS-optimized AMI from the public SSM parameter at plan time, which needs ssm:GetParameter on /aws/service/ecs/optimized-ami/*. | `string` | `null` | no |
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | Name of the ECS cluster the instances join. The module attaches its capacity providers to it (aws\_ecs\_cluster\_capacity\_providers), so no other resource may manage the capacity providers of this cluster. | `string` | n/a | yes |
| <a name="input_cpu_architecture"></a> [cpu\_architecture](#input\_cpu\_architecture) | CPU architecture of the instances: ARM64 (Graviton, the default) or X86\_64. It selects the AMI and the default instance types, and must match the architecture of the tasks and of every entry in instance\_types. | `string` | `"ARM64"` | no |
| <a name="input_egress_https_cidr_blocks"></a> [egress\_https\_cidr\_blocks](#input\_egress\_https\_cidr\_blocks) | IPv4 CIDR blocks the instances may reach on TCP 443: the ECS control plane, ghcr.io (image pulls happen on the instance), CloudWatch Logs, Secrets Manager and SSM. Narrow it only with VPC endpoints and a mirrored image registry. | `list(string)` | <pre>[<br/>  "0.0.0.0/0"<br/>]</pre> | no |
| <a name="input_egress_https_prefix_list_ids"></a> [egress\_https\_prefix\_list\_ids](#input\_egress\_https\_prefix\_list\_ids) | IDs of the managed prefix lists the instances may reach on TCP 443, for example the S3 gateway endpoint prefix list when egress\_https\_cidr\_blocks is narrowed. | `list(string)` | `[]` | no |
| <a name="input_egress_security_group_rules"></a> [egress\_security\_group\_rules](#input\_egress\_security\_group\_rules) | Additional egress rules towards other security groups, one per entry, for example the EFS mount target security group on port 2049 (the ECS agent mounts EFS volumes on the instance). Only the list length must be known at plan time. | <pre>list(object({<br/>    security_group_id = string<br/>    port              = number<br/>    description       = string<br/>  }))</pre> | `[]` | no |
| <a name="input_instance_types"></a> [instance\_types](#input\_instance\_types) | EC2 instance types of the fleet in order of preference (at most 20), all of the architecture cpu\_architecture. Null uses m7g.large and m6g.large for ARM64, m7i.large and m6i.large for X86\_64: two 1 vCPU / 2 GiB tasks fill a 2 vCPU / 8 GiB instance. In awsvpc mode every task needs its own network interface (instance types allow 2 to 15; three on the large sizes above, one used by the instance itself), so small types fit few tasks unless ENI trunking is enabled for the account (awsvpcTrunking, only on supported types). | `list(string)` | `null` | no |
| <a name="input_kms_key_arn"></a> [kms\_key\_arn](#input\_kms\_key\_arn) | ARN of a customer-managed KMS key for the EBS volumes, or null for the AWS managed key aws/ebs. The volumes are always encrypted. The key policy must allow the Auto Scaling service-linked role (AWSServiceRoleForAutoScaling) to use the key and create grants, otherwise instances fail to launch. | `string` | `null` | no |
| <a name="input_max_size"></a> [max\_size](#input\_max\_size) | Maximum number of instances of each Auto Scaling group (On-Demand and, when enabled, Spot). | `number` | `4` | no |
| <a name="input_min_size"></a> [min\_size](#input\_min\_size) | Minimum number of On-Demand instances. ECS managed scaling raises the group above it when tasks do not fit and lowers it again, never below this value. 0 allows the cluster to scale to zero; a service then waits for its first instance after a deployment. | `number` | `1` | no |
| <a name="input_name"></a> [name](#input\_name) | Name prefix for every resource (IAM role, instance profile, security group, launch template, Auto Scaling groups and capacity providers). Must be 3-24 characters, lowercase letters, digits and hyphens, and must not start with aws, ecs or fargate: ECS reserves those prefixes for capacity provider names. | `string` | n/a | yes |
| <a name="input_root_volume_size_gib"></a> [root\_volume\_size\_gib](#input\_root\_volume\_size\_gib) | Size in GiB of the encrypted gp3 root volume. It holds the OS, the Docker images and the /tmp scratch volume of every task on the instance, so size it for the largest blob you expect times the concurrent transfers of all tasks that share an instance. | `number` | `100` | no |
| <a name="input_spot_enabled"></a> [spot\_enabled](#input\_spot\_enabled) | Create a second Auto Scaling group and capacity provider of Spot instances (starting from zero instances, up to max\_size). They only receive the tasks a capacity provider strategy sends to the spot provider; interrupted tasks are drained (ECS\_ENABLE\_SPOT\_INSTANCE\_DRAINING) and rescheduled. | `bool` | `false` | no |
| <a name="input_subnet_ids"></a> [subnet\_ids](#input\_subnet\_ids) | IDs of the private subnets the instances run in (at least two, in different Availability Zones, with a NAT gateway or VPC endpoints for ECS, S3, Secrets Manager, CloudWatch Logs and SSM). The instances never get a public IP address. | `list(string)` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to every resource of the module that supports tags, and propagated to the instances and their volumes. | `map(string)` | `{}` | no |
| <a name="input_target_capacity"></a> [target\_capacity](#input\_target\_capacity) | Target utilization in percent of the instances that ECS managed scaling aims for (1-100). 100 packs tasks tightly and keeps no spare instance; lower values keep headroom for faster scale-out and rolling deployments. | `number` | `100` | no |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | ID of the VPC the instance security group is created in. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_ami_id"></a> [ami\_id](#output\_ami\_id) | ID of the AMI the instances launch from. |
| <a name="output_autoscaling_group_names"></a> [autoscaling\_group\_names](#output\_autoscaling\_group\_names) | Names of the Auto Scaling groups: on\_demand, and spot (null unless spot\_enabled). |
| <a name="output_capacity_provider_names"></a> [capacity\_provider\_names](#output\_capacity\_provider\_names) | Names of the capacity providers for a service capacity\_provider\_strategy: on\_demand, and spot (null unless spot\_enabled). Available once they are attached to the cluster. |
| <a name="output_instance_role_arn"></a> [instance\_role\_arn](#output\_instance\_role\_arn) | ARN of the instance role (AmazonEC2ContainerServiceforEC2Role and AmazonSSMManagedInstanceCore only). |
| <a name="output_launch_template_id"></a> [launch\_template\_id](#output\_launch\_template\_id) | ID of the launch template of the instances. |
| <a name="output_security_group_id"></a> [security\_group\_id](#output\_security\_group\_id) | ID of the instance security group (outbound only), for example to allow it on the EFS mount target security group. |
| <a name="output_user_data"></a> [user\_data](#output\_user\_data) | Plain-text user data of the instances (it only writes /etc/ecs/ecs.config), exposed for tests and review. |
<!-- END_TF_DOCS -->