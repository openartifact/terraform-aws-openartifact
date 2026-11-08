<!--
SPDX-FileCopyrightText: The OpenArtifact Authors

SPDX-License-Identifier: MPL-2.0
-->

# efs

An encrypted [EFS](https://docs.aws.amazon.com/efs/latest/ug/whatisefs.html) file system for the OpenArtifact ECS tasks: a persistent, shared, writable directory for the scanner database cache (`OPENARTIFACT_SCANNER_CACHE_DIR`) and the in-application backups (`OPENARTIFACT_BACKUP_DIR`), which the read-only root filesystem of the image cannot offer.

The root module creates it when `persistent_volume.enabled` is set and mounts it through `modules/ecs-service` (`efs_volumes`). You can use it on its own with any ECS service or other NFS client that mounts through TLS and IAM.

## Usage

```hcl
module "efs" {
  source  = "openartifact/openartifact/aws//modules/efs"
  version = "~> 0.2"

  name       = "openartifact"
  vpc_id     = "vpc-0123456789abcdef0"
  subnet_ids = ["subnet-0aaaaaaaaaaaaaaa1", "subnet-0bbbbbbbbbbbbbbb2"] # private subnets

  # Security groups of the clients that mount the file system (ECS tasks, and on EC2 the
  # container instances).
  allowed_security_group_ids = [aws_security_group.app.id]

  access_points = {
    scanner_cache = { path = "/scanner-cache" }
    backups       = { path = "/backups" }
  }
}
```

## What it creates

- The file system: always encrypted (the AWS managed `aws/elasticfilesystem` key, or `kms_key_arn`), elastic throughput by default, automatic backups (AWS Backup) on by default, optional tiering to Infrequent Access (`transition_to_ia`, with a return to Standard on first access).
- One access point per entry of `access_points`: the client is forced to POSIX user and group `10001:10001` (the image user) and rooted in its own directory, created with mode `0750` (`uid`, `gid` and `permissions` can be changed per access point).
- One mount target per subnet and a security group that accepts NFS (TCP 2049) only from `allowed_security_group_ids`. It has no egress rule.
- A file system policy with `Deny` statements only: every request without TLS (`aws:SecureTransport = false`) and every mount, write or root access that does not use an access point. Access itself is granted by the identity policy of the client role (`modules/ecs-service` adds `ClientMount` and `ClientWrite`, scoped to the file system and the access point).

The outputs `file_system_id` and `access_points` wait for the mount targets, the policy and the ingress rules, so a service that consumes them is created only when the file system is reachable.

## Notes

- With a customer-managed `kms_key_arn`, the key policy must allow the principals that use the file system to use the key through EFS (`kms:ViaService`); see the EFS encryption documentation. This module does not edit the key policy.
- Mount targets, security-group rules and the ingress allow-list are driven by list lengths, so subnet and security group IDs may be unknown at plan time (the same pattern as `modules/database`).
- Backups written into the file system are not an off-site copy: the file system lives in one region. Keep `backup_policy_enabled` on and copy what matters elsewhere.

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
| [aws_efs_access_point.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/efs_access_point) | resource |
| [aws_efs_backup_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/efs_backup_policy) | resource |
| [aws_efs_file_system.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/efs_file_system) | resource |
| [aws_efs_file_system_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/efs_file_system_policy) | resource |
| [aws_efs_mount_target.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/efs_mount_target) | resource |
| [aws_security_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_vpc_security_group_ingress_rule.nfs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_access_points"></a> [access\_points](#input\_access\_points) | Access points to create, keyed by a short name (used in Name tags and as the key of the access\_points output). Each enforces the POSIX identity uid:gid for every request and roots the client at path, which is created with the given owner and permissions when missing. The defaults match the OpenArtifact image user (10001:10001) and a 0750 directory. | <pre>map(object({<br/>    path        = string<br/>    uid         = optional(number, 10001)<br/>    gid         = optional(number, 10001)<br/>    permissions = optional(string, "0750")<br/>  }))</pre> | `{}` | no |
| <a name="input_allowed_security_group_ids"></a> [allowed\_security\_group\_ids](#input\_allowed\_security\_group\_ids) | IDs of the security groups allowed to reach the mount targets on TCP 2049 (the ECS task security groups, and the container instance security group when the tasks run on EC2: there the ECS agent mounts the file system on the instance). One ingress rule is created per entry; only the list length must be known at plan time. | `list(string)` | `[]` | no |
| <a name="input_backup_policy_enabled"></a> [backup\_policy\_enabled](#input\_backup\_policy\_enabled) | Enable the EFS automatic backup policy (daily backups by AWS Backup, 35 days retention, no backup plan to manage). Costs per GB-month of backup storage. | `bool` | `true` | no |
| <a name="input_kms_key_arn"></a> [kms\_key\_arn](#input\_kms\_key\_arn) | ARN (or alias ARN) of a customer-managed KMS key that encrypts the file system, or null for the AWS managed key aws/elasticfilesystem. The file system is always encrypted. The key policy must allow the principals that create and mount the file system to use the key through Amazon EFS (condition kms:ViaService = elasticfilesystem.<region>.amazonaws.com). | `string` | `null` | no |
| <a name="input_name"></a> [name](#input\_name) | Name prefix for every resource of the file system (Name tags, security group). Must be 3-24 characters, lowercase letters, digits and hyphens. | `string` | n/a | yes |
| <a name="input_performance_mode"></a> [performance\_mode](#input\_performance\_mode) | EFS performance mode: generalPurpose (the default, required for elastic throughput) or maxIO (legacy, higher latency, only with bursting or provisioned throughput). Cannot be changed after creation. | `string` | `"generalPurpose"` | no |
| <a name="input_provisioned_throughput_in_mibps"></a> [provisioned\_throughput\_in\_mibps](#input\_provisioned\_throughput\_in\_mibps) | Provisioned throughput in MiB/s. Required when throughput\_mode is provisioned, and rejected otherwise. | `number` | `null` | no |
| <a name="input_subnet_ids"></a> [subnet\_ids](#input\_subnet\_ids) | IDs of the private subnets that get a mount target, one per Availability Zone (EFS allows one mount target per zone). Only the list length must be known at plan time. | `list(string)` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to every resource of the module that supports tags. | `map(string)` | `{}` | no |
| <a name="input_throughput_mode"></a> [throughput\_mode](#input\_throughput\_mode) | EFS throughput mode: elastic (the default: scales with the workload, pay per use), bursting or provisioned (set provisioned\_throughput\_in\_mibps). | `string` | `"elastic"` | no |
| <a name="input_transition_to_ia"></a> [transition\_to\_ia](#input\_transition\_to\_ia) | Move files not accessed for this long to the Infrequent Access storage class: AFTER\_1\_DAY, AFTER\_7\_DAYS, AFTER\_14\_DAYS, AFTER\_30\_DAYS, AFTER\_60\_DAYS, AFTER\_90\_DAYS, AFTER\_180\_DAYS, AFTER\_270\_DAYS or AFTER\_365\_DAYS. Files return to Standard on their first access. Null keeps everything in Standard storage. | `string` | `null` | no |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | ID of the VPC the mount target security group is created in. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_access_points"></a> [access\_points](#output\_access\_points) | ID and ARN of every access point, keyed like the access\_points variable. Available once the mount targets exist. |
| <a name="output_file_system_arn"></a> [file\_system\_arn](#output\_file\_system\_arn) | ARN of the file system, for IAM policies. |
| <a name="output_file_system_id"></a> [file\_system\_id](#output\_file\_system\_id) | ID of the file system. Available once the mount targets and the file system policy exist, so consumers (ECS services) wait for them. |
| <a name="output_ingress_security_group_ids"></a> [ingress\_security\_group\_ids](#output\_ingress\_security\_group\_ids) | IDs of the security groups that may reach the mount targets on NFS (TCP 2049), as granted by the ingress rules. Nothing else can. |
| <a name="output_security_group_id"></a> [security\_group\_id](#output\_security\_group\_id) | ID of the mount target security group. |
<!-- END_TF_DOCS -->