<!--
SPDX-FileCopyrightText: The OpenArtifact Authors

SPDX-License-Identifier: AGPL-3.0-or-later
-->

# OpenArtifact database (RDS PostgreSQL)

Creates the PostgreSQL database OpenArtifact needs: an encrypted, Multi-AZ,
private RDS for PostgreSQL instance with its subnet group, parameter group,
security group and (optionally) a dedicated KMS key. The master password is
generated and rotated by RDS in AWS Secrets Manager. It is never written to
Terraform configuration or state.

The module is part of [terraform-aws-openartifact](../../README.md) and is used
by the root module and the EKS example. You can also use it on its own.

## Usage

```hcl
module "database" {
  source  = "openartifact/openartifact/aws//modules/database"
  version = "~> 0.1"

  name       = "openartifact"
  vpc_id     = "vpc-0123456789abcdef0"
  subnet_ids = ["subnet-0aaaaaaaaaaaaaaa1", "subnet-0bbbbbbbbbbbbbbb2"] # private subnets

  # Security groups of the workloads that connect (ECS tasks, EKS nodes/pods).
  allowed_security_group_ids = [aws_security_group.app.id]

  tags = { Project = "openartifact" }
}
```

To use an unreleased version, point the source at git instead:
`git::https://github.com/openartifact/terraform-aws-openartifact.git//modules/database?ref=vX.Y.Z`.

Point OpenArtifact at the database with these environment variables:

| Variable | Value |
|---|---|
| `DB_HOST` | `module.database.endpoint` (host name only) |
| `DB_PORT` | `module.database.port` |
| `DB_NAME` | `module.database.database_name` |
| `DB_USER` | `module.database.master_username` |
| `DB_PASSWORD` | the `password` key of `module.database.master_user_secret_arn` (on ECS: `valueFrom = "<secret arn>:password::"`) |
| `DB_SSLMODE` | `require` |

## Security notes

- **No password in Terraform.** The instance uses
  `manage_master_user_password = true`. RDS creates a Secrets Manager secret
  (JSON `{"username": ..., "password": ...}`) encrypted with the module KMS
  key and **rotates it about every 7 days**. Rotation takes effect on the
  server only; OpenArtifact reads `DB_PASSWORD` once at start, so **consumers
  must be redeployed or restarted after each rotation** (the ECS service module
  can do this automatically, see its `redeploy_on_secret_rotation` input). Until
  then new connections made with the old password fail after RDS has switched
  the password, so schedule or automate the restart. The secret and its KMS key
  cannot be changed once RDS manages the credentials.
- **Encryption.** Storage, snapshots, Performance Insights and the master secret
  use one customer-managed KMS key (rotation enabled), created by the module
  unless you pass `kms_key_arn`. Its key policy delegates to IAM in the account
  and additionally lets principals of the account use the key only through
  RDS and Secrets Manager (`kms:ViaService`). A key you supply must allow the
  same (`kms:CreateGrant`, `kms:Decrypt`, `kms:GenerateDataKey*`,
  `kms:DescribeKey` for RDS and Secrets Manager); it must be known at plan time
  and must be a key ARN, not an alias. Whoever applies the module needs
  `kms:DescribeKey`, `kms:Decrypt`, `kms:GenerateDataKey`, `kms:CreateGrant` on it
  and `secretsmanager:CreateSecret`, `secretsmanager:TagResource`.
- **TLS only.** The parameter group forces `rds.force_ssl = 1`. It is merged
  last, so `parameters` cannot turn it off. The shell-less OpenArtifact image has
  no RDS CA bundle, so use `DB_SSLMODE=require` (encrypts, does not verify the
  server certificate). `verify-full` needs the bundle added to the image.
- **Private only.** `publicly_accessible = false` and the security group has
  ingress on 5432 solely from `allowed_security_group_ids` (one rule per
  security group) and **no egress rules**. Use private subnets without a route
  to an internet gateway.
- **Data protection.** Deletion protection is on, a final snapshot is taken on
  destroy (`<name>-final-<random hex>`; the suffix is generated once and kept in
  state, so re-creating a database of the same name never collides with an
  older snapshot) and tags are copied to snapshots. Automated backups are kept
  for `backup_retention_period` days (1-35). To destroy the database, first
  apply `deletion_protection = false`.
- **Logs.** `postgresql` and `upgrade` logs are exported to CloudWatch Logs.
  Add `log_min_duration_statement = "1000"` through `parameters` to log slow
  queries.

## Engine version and upgrades

`engine_version` is a **major** version (`16`, `17` or `18`: OpenArtifact's
integration harness runs on 16 and its CI, compose file and documentation on
18). Only the major is sent to RDS. With `auto_minor_version_upgrade = true`
the AWS provider matches the configured major against the running minor
(`engine_version_actual`), so RDS applying minor upgrades in the maintenance
window causes no Terraform diff and no `ignore_changes` is needed. Keep
`auto_minor_version_upgrade` on: the provider documents major-prefix matching
only for that case, and the module accepts no full version.

Changing the major version is **not** an in-place operation here: the module
does not set `allow_major_version_upgrade`, so a major bump fails at apply
instead of upgrading silently. Plan major upgrades deliberately (snapshot,
RDS console/CLI upgrade, then update the variable).

## Parameter changes

Parameters from `parameters` are applied with `apply_method = pending-reboot`
so static parameters also work; they take effect at the next reboot, which RDS
reports as `pending-reboot` on the instance. `rds.force_ssl` is dynamic and
applied immediately.

## Notes

- `performance_insights_enabled` is not supported on `db.t4g.micro`/`db.t4g.small`;
  set it to `false` for those classes.
- Storage autoscaling: with `max_allocated_storage > 0` RDS can grow the volume
  and the provider ignores the resulting `allocated_storage` drift.
  `max_allocated_storage = 0` disables autoscaling.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 6.72 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.9 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_aws"></a> [aws](#provider\_aws) | ~> 6.72 |
| <a name="provider_random"></a> [random](#provider\_random) | ~> 3.9 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_db_instance.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_instance) | resource |
| [aws_db_parameter_group.database](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_parameter_group) | resource |
| [aws_db_subnet_group.database](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_subnet_group) | resource |
| [aws_iam_role.monitoring](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.monitoring](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_kms_alias.database](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.database](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_security_group.database](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_vpc_security_group_ingress_rule.postgres_from_allowed](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [random_id.final_snapshot](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/id) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_allocated_storage"></a> [allocated\_storage](#input\_allocated\_storage) | Initial allocated storage in GiB. | `number` | `50` | no |
| <a name="input_allowed_security_group_ids"></a> [allowed\_security\_group\_ids](#input\_allowed\_security\_group\_ids) | IDs of the security groups (for example the ECS tasks or EKS nodes/pods) allowed to reach the database on port 5432. One ingress rule is created per entry. | `list(string)` | `[]` | no |
| <a name="input_apply_immediately"></a> [apply\_immediately](#input\_apply\_immediately) | Apply modifications immediately instead of in the next maintenance window. Some changes (instance class, Multi-AZ, storage) cause a brief outage when applied immediately. | `bool` | `false` | no |
| <a name="input_auto_minor_version_upgrade"></a> [auto\_minor\_version\_upgrade](#input\_auto\_minor\_version\_upgrade) | Apply PostgreSQL minor version upgrades automatically during the maintenance window. Required for the major-only engine\_version to track minors without a Terraform diff. | `bool` | `true` | no |
| <a name="input_backup_retention_period"></a> [backup\_retention\_period](#input\_backup\_retention\_period) | Days to keep automated backups (1-35). Backups cannot be disabled because they also enable point-in-time recovery. | `number` | `14` | no |
| <a name="input_backup_window"></a> [backup\_window](#input\_backup\_window) | Daily UTC time range (hh24:mi-hh24:mi) for automated backups. Must not overlap maintenance\_window. | `string` | `"02:00-03:00"` | no |
| <a name="input_ca_cert_identifier"></a> [ca\_cert\_identifier](#input\_ca\_cert\_identifier) | Identifier of the CA certificate for the DB instance server certificate. | `string` | `"rds-ca-rsa2048-g1"` | no |
| <a name="input_database_name"></a> [database\_name](#input\_database\_name) | Name of the initial database created on the instance. | `string` | `"openartifact"` | no |
| <a name="input_deletion_protection"></a> [deletion\_protection](#input\_deletion\_protection) | Block deletion of the DB instance through the API. Disable it (and apply) before destroying the database. | `bool` | `true` | no |
| <a name="input_enabled_cloudwatch_logs_exports"></a> [enabled\_cloudwatch\_logs\_exports](#input\_enabled\_cloudwatch\_logs\_exports) | Log types exported to CloudWatch Logs. | `list(string)` | <pre>[<br/>  "postgresql",<br/>  "upgrade"<br/>]</pre> | no |
| <a name="input_engine_version"></a> [engine\_version](#input\_engine\_version) | PostgreSQL major version. Only the major is passed to RDS, so minor upgrades are picked up automatically while auto\_minor\_version\_upgrade is true. OpenArtifact runs CI against PostgreSQL 18 and its integration harness against 16. | `string` | `"17"` | no |
| <a name="input_instance_class"></a> [instance\_class](#input\_instance\_class) | RDS instance class, for example db.t4g.medium. | `string` | `"db.t4g.medium"` | no |
| <a name="input_kms_key_arn"></a> [kms\_key\_arn](#input\_kms\_key\_arn) | ARN of an existing customer-managed KMS key used for storage, Performance Insights and the master-user secret. null creates a dedicated key with annual rotation. A supplied key must be known at plan time and its key policy must let RDS and Secrets Manager use it (see README). | `string` | `null` | no |
| <a name="input_maintenance_window"></a> [maintenance\_window](#input\_maintenance\_window) | Weekly UTC time range (ddd:hh24:mi-ddd:hh24:mi, lowercase day names) for maintenance. Must not overlap backup\_window. | `string` | `"sun:04:00-sun:05:00"` | no |
| <a name="input_master_username"></a> [master\_username](#input\_master\_username) | Master user name. The password is generated and rotated by RDS in Secrets Manager; it never enters Terraform state or configuration. | `string` | `"openartifact"` | no |
| <a name="input_max_allocated_storage"></a> [max\_allocated\_storage](#input\_max\_allocated\_storage) | Upper limit in GiB for RDS storage autoscaling. 0 disables autoscaling; otherwise it must be at least allocated\_storage. | `number` | `200` | no |
| <a name="input_monitoring_interval"></a> [monitoring\_interval](#input\_monitoring\_interval) | Seconds between Enhanced Monitoring samples (0, 1, 5, 10, 15, 30 or 60). 0 disables Enhanced Monitoring; any other value creates the monitoring IAM role. | `number` | `0` | no |
| <a name="input_multi_az"></a> [multi\_az](#input\_multi\_az) | Deploy a synchronous standby in a second Availability Zone. | `bool` | `true` | no |
| <a name="input_name"></a> [name](#input\_name) | Name prefix for every resource of the database (DB instance identifier, subnet group, parameter group, security group, KMS alias). Must be 3-24 characters, lowercase letters, digits and hyphens. | `string` | n/a | yes |
| <a name="input_parameters"></a> [parameters](#input\_parameters) | Extra DB parameter group parameters (name => value), for example log\_min\_duration\_statement = "1000". Applied with apply\_method pending-reboot so static parameters work too. rds.force\_ssl is always 1 and cannot be overridden. | `map(string)` | `{}` | no |
| <a name="input_performance_insights_enabled"></a> [performance\_insights\_enabled](#input\_performance\_insights\_enabled) | Enable Performance Insights, encrypted with the module KMS key. Not supported on the smallest burstable classes (db.t4g.micro, db.t4g.small). | `bool` | `true` | no |
| <a name="input_performance_insights_retention_period"></a> [performance\_insights\_retention\_period](#input\_performance\_insights\_retention\_period) | Days to retain Performance Insights data: 7, 731, or a multiple of 31 up to 713. Ignored when performance\_insights\_enabled is false. | `number` | `7` | no |
| <a name="input_skip_final_snapshot"></a> [skip\_final\_snapshot](#input\_skip\_final\_snapshot) | Skip the final DB snapshot when the instance is destroyed. Keep false in production so the data survives an accidental destroy. | `bool` | `false` | no |
| <a name="input_storage_type"></a> [storage\_type](#input\_storage\_type) | Storage type of the DB instance. Provisioned-IOPS types are not offered because the module has no iops input. | `string` | `"gp3"` | no |
| <a name="input_subnet_ids"></a> [subnet\_ids](#input\_subnet\_ids) | IDs of the private subnets for the DB subnet group. At least two subnets in different Availability Zones are required by RDS. | `list(string)` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to every resource. | `map(string)` | `{}` | no |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | ID of the VPC the database security group is created in. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_database_name"></a> [database\_name](#output\_database\_name) | Name of the initial database. |
| <a name="output_endpoint"></a> [endpoint](#output\_endpoint) | DNS address of the DB instance (host name only, without the port). |
| <a name="output_instance_arn"></a> [instance\_arn](#output\_instance\_arn) | ARN of the DB instance. |
| <a name="output_instance_id"></a> [instance\_id](#output\_instance\_id) | Identifier of the DB instance. |
| <a name="output_kms_key_arn"></a> [kms\_key\_arn](#output\_kms\_key\_arn) | ARN of the KMS key encrypting the storage, Performance Insights and the master-user secret (the module-created key or var.kms\_key\_arn). |
| <a name="output_master_user_secret_arn"></a> [master\_user\_secret\_arn](#output\_master\_user\_secret\_arn) | ARN of the RDS-managed Secrets Manager secret holding the master credentials as JSON {username, password}. RDS rotates the password about every 7 days: consumers that read it only at start must be redeployed after rotation. |
| <a name="output_master_username"></a> [master\_username](#output\_master\_username) | Master user name. |
| <a name="output_port"></a> [port](#output\_port) | Port the database listens on. |
| <a name="output_security_group_id"></a> [security\_group\_id](#output\_security\_group\_id) | ID of the database security group. Add further ingress rules to it only through aws\_vpc\_security\_group\_ingress\_rule. |
<!-- END_TF_DOCS -->
