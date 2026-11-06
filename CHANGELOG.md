<!--
SPDX-FileCopyrightText: The OpenArtifact Authors

SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Changelog

All notable changes are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The release workflow refuses a `vX.Y.Z` tag without a non-empty `## [X.Y.Z]` section.

## [Unreleased]

## [0.1.0] - Unreleased

### Added

- Root module deploying OpenArtifact on ECS Fargate: ALB (HTTPS, HTTP redirect, optional WAF), web service and optional worker service, RDS PostgreSQL, S3 blob bucket, Secrets Manager, KMS.
- `modules/network`, `modules/storage`, `modules/secrets`, `modules/database`, `modules/ecs-service` usable on their own.
- `modules/eks` for existing EKS clusters (Helm chart, Pod Identity, External Secrets or write-only secret delivery).
- Generated application secrets use ephemeral resources and write-only attributes; values are never stored in state.
- Automatic redeploy of ECS services after an RDS managed master password rotation.
- Examples, native plan-only tests (Terraform and OpenTofu), tflint, Trivy, Checkov, terraform-docs and REUSE checks in CI.

[Unreleased]: https://github.com/openartifact/terraform-aws-openartifact/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/openartifact/terraform-aws-openartifact/commits/v0.1.0
