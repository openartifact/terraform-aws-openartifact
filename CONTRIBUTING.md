<!--
SPDX-FileCopyrightText: The OpenArtifact Authors

SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Contributing

Thanks for helping. Issues and pull requests are welcome. Security problems go to the private channel in [SECURITY.md](SECURITY.md), never to a public issue.

## Tooling

Terraform and OpenTofu `>= 1.11`, `tflint`, `terraform-docs`, `trivy`, `checkov`, `reuse`, `actionlint`, `make`. Optional: `pre-commit install` runs the formatters and linters on commit (`.pre-commit-config.yaml`).

## Make targets

| Target | What it does |
|---|---|
| `make fmt` / `make fmt-check` | `terraform fmt -recursive` / fail on unformatted files |
| `make validate` | `init -backend=false` + `validate` for the root, `modules/*` and `examples/*` |
| `make tofu-validate` | the same with OpenTofu, in a throwaway copy (`.tofu/work`) so Terraform's `.terraform/` and lock files are never touched |
| `make lock` | refresh `examples/*/.terraform.lock.hcl` with hashes for linux, macOS and Windows (the example lock files are committed; `make validate` runs them with `-lockfile=readonly`) |
| `make lint` | `tflint --recursive` (terraform + aws rulesets) |
| `make test` / `make tofu-test` | native `tests/*.tftest.hcl` (plan-only, mocked provider, no AWS credentials) |
| `make docs` / `make docs-check` | regenerate / verify the terraform-docs sections of every README |
| `make security` | Trivy (HIGH/CRITICAL) and Checkov |
| `make reuse` | `reuse lint` |
| `make all` | everything CI runs with Terraform |

Never run `apply` (or a plan against real AWS) as part of development or in CI.

## Conventions

- Commits and PR titles follow [Conventional Commits](https://www.conventionalcommits.org/): `feat(ecs-service): ...`, `fix(database): ...`, `docs: ...`, `ci: ...`, `chore: ...`. Mark breaking changes with `!` and describe the upgrade in `CHANGELOG.md`.
- Every `.tf`, `.tftest.hcl`, `.yml` and `.sh` file starts with the SPDX header (`SPDX-FileCopyrightText: The OpenArtifact Authors`, `SPDX-License-Identifier: AGPL-3.0-or-later`); Markdown uses the HTML comment form. `make reuse` must pass.
- Every variable has `description` and `type`, validates its input where a bad value is possible, and uses `nullable = false` unless `null` is meaningful. Every output has a `description`.
- `versions.tf` declares `required_version = ">= 1.11"` and only the providers the directory uses. Modules never configure providers; examples do.
- Security group rules use `aws_vpc_security_group_{ingress,egress}_rule`; never mix `count` and `for_each` on one resource.
- Secret values must not reach state: use ephemeral resources and write-only attributes, or ARNs of existing secrets.
- Scanner findings are suppressed inline with a justification (`#trivy:ignore:AVD-AWS-xxxx` or `#checkov:skip=CKV_AWS_xxx: reason`), never with a blanket ignore.
- README of each module: hand-written intro, usage, security notes, then the generated `<!-- BEGIN_TF_DOCS -->` block. Run `make docs`; do not edit the block by hand.

## Tests

Each module has `tests/<module>.tftest.hcl`: plan-only runs against `mock_provider "aws" {}` with `override_data` giving valid JSON for `aws_iam_policy_document`. Assert behaviour (resource attributes, outputs) and use `expect_failures` to prove that validations reject bad input. Tests must pass with both `terraform test` and `tofu test`.

## Agent skills

`.agents/skills/` vendors Terraform skills for AI coding agents (see `.agents/skills/README.md` and `AGENTS.md`). Treat them as read-only upstream content; to update, re-copy from a reviewed upstream commit.
