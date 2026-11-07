<!--
SPDX-FileCopyrightText: The OpenArtifact Authors

SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Changelog

All notable changes are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The release workflow refuses a `vX.Y.Z` tag without a non-empty `## [X.Y.Z]` section.

## [Unreleased]

## [0.2.0] - Unreleased

### Added

- `capacity_type = "EC2"` runs the ECS tasks on EC2 container instances instead of Fargate (`FARGATE` stays the default, no change for existing deployments). New `modules/ecs-ec2-capacity`: ECS-optimized Amazon Linux 2023 AMI (ARM64 or x86_64) from the public SSM parameter, IMDSv2 only, no public IP, no SSH or key pair, encrypted gp3 root volume, instance role limited to `AmazonEC2ContainerServiceforEC2Role` and `AmazonSSMManagedInstanceCore`, `ECS_AWSVPC_BLOCK_IMDS=true`, Auto Scaling groups with instance refresh behind capacity providers with managed scaling, managed termination protection and managed draining. Settings in `ec2_capacity` (instance types, size bounds, root volume, KMS key, target capacity, optional Spot share for the web service only).
- `persistent_volume` adds an optional encrypted EFS file system (new `modules/efs`) mounted into the web and worker tasks, on Fargate and on EC2, for the scanner cache and the in-application backups. TLS and IAM authorization, one access point per use as 10001:10001 with mode 0750, NFS only from the service security groups, a file system policy that denies non-TLS and access-point-less requests, optional customer-managed key, AWS Backup toggle and Infrequent Access tiering. `OPENARTIFACT_SCANNER_CACHE_DIR`, `OPENARTIFACT_BACKUP_DIR` and, with `scanner_auto_install`, `OPENARTIFACT_TRIVY_INSTALL`/`OPENARTIFACT_GRYPE_INSTALL` are set only when mounted.
- `modules/ecs-service` inputs `capacity_provider_strategy` and `efs_volumes`; output `capacity_provider_strategy`.
- Root outputs `capacity_type`, `ecs_capacity_provider_names`, `ecs_autoscaling_group_names`, `ecs_instance_role_arn`, `ecs_instance_security_group_id`, `efs_file_system_id`, `efs_access_point_arns`, `efs_security_group_id`.
- `examples/ec2-capacity`.

### Changed

- With EC2 capacity the task definition is EC2-compatible only and `/tmp` is a task-scoped Docker volume on the instance disk; Fargate task definitions are unchanged.
- The README no longer states that backups and the scanner cache cannot work on ECS: they need `persistent_volume`.

## [0.1.0] - Unreleased

### Added

- Root module deploying OpenArtifact on ECS Fargate: ALB (HTTPS, HTTP redirect, optional WAF), web service and optional worker service, RDS PostgreSQL, S3 blob bucket, Secrets Manager, KMS.
- `modules/network`, `modules/storage`, `modules/secrets`, `modules/database`, `modules/ecs-service` usable on their own.
- `modules/eks` for existing EKS clusters (Helm chart, Pod Identity, External Secrets or write-only secret delivery).
- Generated application secrets use ephemeral resources and write-only attributes; values are never stored in state.
- Automatic redeploy of ECS services after an RDS managed master password rotation.
- Examples, native plan-only tests (Terraform and OpenTofu), tflint, Trivy, Checkov, terraform-docs and REUSE checks in CI.

[Unreleased]: https://github.com/openartifact/terraform-aws-openartifact/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/openartifact/terraform-aws-openartifact/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/openartifact/terraform-aws-openartifact/commits/v0.1.0
