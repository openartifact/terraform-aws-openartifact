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
<!-- END_TF_DOCS -->
