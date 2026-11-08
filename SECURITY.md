<!--
SPDX-FileCopyrightText: The OpenArtifact Authors

SPDX-License-Identifier: MPL-2.0
-->

# Security Policy

## Reporting a vulnerability

Please report vulnerabilities in this repository **privately**, never in a public issue or pull request. Use the OpenArtifact security policy, which applies to every repository of the project:

- <https://github.com/openartifact/openartifact/security/policy> (private GitHub security advisory), or
- email **morf3089@gmail.com**.

Include the affected module and release tag, the Terraform/OpenTofu and AWS provider versions, and steps to reproduce (redact account IDs and secrets).

You will receive an acknowledgement within **3 days** and an initial assessment within **14 days**. Medium or higher severity issues are fixed within **60 days** of confirmation, critical ones as fast as possible. Reporters are credited in the release notes unless they ask to stay anonymous.

For vulnerabilities in OpenArtifact itself (the application and container image), follow the [main repository policy](https://github.com/openartifact/openartifact/blob/main/SECURITY.md).

## Supported versions

Security fixes are applied to the latest release only.

## Scope and hardening

The modules ship secure defaults (see the "Security posture" section of the README). Trivy and Checkov run in CI and on a weekly schedule; a suppressed finding always has an inline justification. Misconfigurations that weaken a default, leak secret values into state or logs, or widen IAM beyond what is needed are in scope.
