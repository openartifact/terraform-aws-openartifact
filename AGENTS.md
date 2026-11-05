<!--
SPDX-FileCopyrightText: The OpenArtifact Authors

SPDX-License-Identifier: AGPL-3.0-or-later
-->

# AGENTS.md

Terraform/OpenTofu modules deploying OpenArtifact on AWS (published as `openartifact/openartifact/aws`). Read `CONTRIBUTING.md` for the full conventions; this file is the short version for coding agents.

## Layout

- `/` root module: ECS Fargate deployment (ALB, web and optional worker, RDS, S3, Secrets Manager, KMS).
- `modules/{network,storage,secrets,database,ecs-service,eks}`: reusable building blocks.
- `examples/*`: complete configurations; use `source = "../.."` with a comment showing the registry source.
- `tests/<module>.tftest.hcl`: native plan-only tests, one file per module plus the root.
- `.agents/skills/`: vendored upstream skills (read-only).

## Commands

```sh
export TF_PLUGIN_CACHE_DIR=$HOME/.terraform.d/plugin-cache   # mkdir -p it first
make fmt lint validate test docs security reuse               # same as CI
make tofu-validate tofu-test                                  # OpenTofu
make docs-check                                               # fails on README drift
```

## Conventions

- Every `.tf`, `.tftest.hcl`, `.yml`, `.sh` file starts with the SPDX header (`# SPDX-FileCopyrightText: The OpenArtifact Authors`, blank `#`, `# SPDX-License-Identifier: AGPL-3.0-or-later`); Markdown uses an HTML comment. Commits are Conventional Commits.
- `required_version = ">= 1.11"`, `aws ~> 6.72`, `random ~> 3.9`, `helm ~> 3.3` (attribute syntax: `kubernetes = {...}`, `set = [...]`), `kubernetes ~> 3.5`. A directory declares only the providers it uses. Modules never configure providers.
- Variable attribute order: description, type, default, validation, nullable (`false`), sensitive. Every variable has `description` and `type`; every output a `description`. `var.name` matches `^[a-z][a-z0-9-]{1,22}[a-z0-9]$`.
- Resource names are descriptive; `this` only for a module's singleton. Never mix `count` and `for_each` on one resource. Security groups only through `aws_vpc_security_group_{ingress,egress}_rule`. Tag every resource (`tags = var.tags` merged with `Name`).
- Secrets: generated with `ephemeral "random_password"` into write-only attributes; never in state. No static AWS keys.
- Scanner suppressions inline only, with a reason: `#trivy:ignore:AVD-AWS-xxxx`, `#checkov:skip=CKV_AWS_xxx: reason`.
- README per directory: hand-written text, then `<!-- BEGIN_TF_DOCS -->` / `<!-- END_TF_DOCS -->` filled by `make docs`. Never hand-write the tables.

## Skills

Load from `.agents/skills/` (each has a `SKILL.md`; start there, open `references/` on demand):

| Task | Skill |
|---|---|
| Writing or restructuring any module, variables, outputs, state, CI patterns | `terraform-skill` |
| HCL formatting, file organisation, naming, secure defaults | `terraform-style-guide` |
| Writing or fixing `tests/*.tftest.hcl` (mocks, `expect_failures`) | `terraform-test` |
| Terraform Policy (`.policy.hcl`) authoring or testing | `terraform-policy` |
| Extracting or reshaping a module, `moved` blocks | `refactor-module` |

Where a skill disagrees with the conventions above or the repository's existing code, the repository wins.

## Gotchas

- **Never run `apply`**, or `plan` against real AWS. Validation and tests are offline.
- Tests mock the AWS provider (`mock_provider "aws" {}`); give `aws_iam_policy_document` a valid JSON through `override_data`/`mock_data`. The `random` provider is local and needs no mock. Tests must pass on both `terraform test` and `tofu test`.
- `.terraform/` and `.terraform.lock.hcl` are not committed.
- Keep `OPENARTIFACT_SECRET_KEY` stable: changing it makes stored credentials unreadable. `secret_version` bumps must never touch it implicitly.
- ECS: the image is shell-less and has no file mounts, so only `OPENARTIFACT_BOOTSTRAP_ADMIN_PASSWORD` (env from a secret) is supported; the admin token is file-only and works on EKS only.
- RDS rotates its managed master password; tasks read env only at start, hence the redeploy-on-rotation mechanism in `modules/ecs-service`.
- ALB health check path is `/ready`; the container health check runs `/app/openartifact -healthcheck`. Port 8080. Autoscaling owns `desired_count` after creation (`ignore_changes`).
- The only suppression mechanism for Trivy/Checkov findings is inline with justification; do not add blanket skips to `trivy.yaml` or `.checkov.yaml`.
- Vendored skills are unmodified upstream content: do not edit them, and do not restore the BUSL-1.1 `*.sentinel` files dropped from `terraform-policy`.
