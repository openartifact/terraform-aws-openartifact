<!--
SPDX-FileCopyrightText: The OpenArtifact Authors

SPDX-License-Identifier: AGPL-3.0-or-later
-->

## What and why

<!-- What does this change, and why? Link the issue. -->

## Checklist

- [ ] Commit messages and the PR title follow [Conventional Commits](https://www.conventionalcommits.org/)
- [ ] `make fmt lint validate test docs security reuse` pass locally (`make tofu-validate tofu-test` for OpenTofu)
- [ ] New or changed variables validate their input; new variables/outputs have descriptions
- [ ] `terraform-docs` sections regenerated (`make docs`); new files carry the SPDX header
- [ ] Breaking change: noted in `CHANGELOG.md` with upgrade instructions
- [ ] No secret values in state, variables defaults or examples
