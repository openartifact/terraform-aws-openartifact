<!--
SPDX-FileCopyrightText: The OpenArtifact Authors

SPDX-License-Identifier: MPL-2.0
-->

# Agent skills

Vendored, unmodified, so updates are a plain re-copy:

- `terraform-skill`: [antonbabenko/terraform-skill](https://github.com/antonbabenko/terraform-skill) at commit `9c1e92d` (v1.17.2), Apache-2.0 (`LICENSES/Apache-2.0.txt`, copyright Anton Babenko). Only `skills/terraform-skill/` (`SKILL.md` and `references/`) is kept.
- `terraform-style-guide`, `terraform-test`, `terraform-policy`, `refactor-module`: [hashicorp/agent-skills](https://github.com/hashicorp/agent-skills) (`plugins/terraform/skills/`) at commit `5e30fa5`, MPL-2.0 (`LICENSES/MPL-2.0.txt`, copyright IBM Corp.). Whole skill directories are kept, except the 16 `*.sentinel` files under `terraform-policy/examples/conversion/`: upstream licenses them BUSL-1.1, which is not an open-source licence and is not compatible with this repository's REUSE setup. The matching `*.policy.hcl` conversions (MPL-2.0) are kept.

Licence and copyright of these files are declared in `REUSE.toml` (they carry no OpenArtifact header).

| Skill | Use for |
|---|---|
| `terraform-skill` | Module and root layout, naming, variables/outputs, state, testing strategy, CI, security and compliance patterns; the default skill for any `.tf` change |
| `terraform-style-guide` | HCL formatting, file organisation, resource/variable/output conventions, secure defaults |
| `terraform-test` | Writing and running native `.tftest.hcl` tests: `mock_provider`, `override_data`, `expect_failures`, plan vs apply runs |
| `terraform-policy` | Authoring and testing Terraform Policy (`.policy.hcl`, `.policytest.hcl`) and converting Sentinel policies |
| `refactor-module` | Turning loose resources into a reusable module; `moved` blocks and state-safe refactors |

When to load them and how they rank against repo conventions: see "Skills" in `AGENTS.md`.

Update: copy the skill from a reviewed upstream commit and bump the commit above. Do not track upstream `main` automatically.
