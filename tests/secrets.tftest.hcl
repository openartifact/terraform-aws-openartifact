# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# Plan-only tests for modules/secrets (no AWS credentials needed). The random
# provider is real: the ephemeral random_password resources are opened at plan
# time; ephemeral values cannot be referenced from assertions (and never reach
# the plan or state), so the tests assert on the write-only wiring instead.

mock_provider "aws" {}

variables {
  name = "oa-test"
}

run "defaults" {
  command = plan

  module {
    source = "./modules/secrets"
  }

  assert {
    condition     = toset(keys(aws_secretsmanager_secret.generated)) == toset(["secret_key", "hmac_key", "metrics_token", "bootstrap_admin_password"])
    error_message = "By default the encryption key, HMAC key, metrics token and bootstrap admin password are created (not the admin token)."
  }

  assert {
    condition     = toset(keys(aws_secretsmanager_secret_version.generated)) == toset(keys(aws_secretsmanager_secret.generated))
    error_message = "Every created secret must get a generated version."
  }

  assert {
    condition     = aws_secretsmanager_secret.generated["secret_key"].name == "oa-test/secret-key" && aws_secretsmanager_secret.generated["hmac_key"].name == "oa-test/hmac-key"
    error_message = "Secrets must be named <name>/<path>."
  }

  assert {
    condition     = alltrue([for s in values(aws_secretsmanager_secret.generated) : s.recovery_window_in_days == 30])
    error_message = "Recovery window must default to 30 days."
  }

  assert {
    condition     = alltrue([for s in values(aws_secretsmanager_secret.generated) : s.kms_key_id == null])
    error_message = "Without kms_key_arn the AWS managed aws/secretsmanager key is used (kms_key_id null)."
  }

  assert {
    condition     = alltrue([for v in values(aws_secretsmanager_secret_version.generated) : v.secret_string_wo_version == 1])
    error_message = "All secret_string_wo_version values must start at 1."
  }

  assert {
    condition     = alltrue([for v in values(aws_secretsmanager_secret_version.generated) : v.secret_string == null])
    error_message = "The plaintext secret_string argument must never be used (value would reach the state)."
  }

  assert {
    condition     = toset(keys(output.secret_arns_by_env)) == toset(["OPENARTIFACT_SECRET_KEY", "AUTH_HMAC_KEY", "METRICS_AUTH_TOKEN", "OPENARTIFACT_BOOTSTRAP_ADMIN_PASSWORD"])
    error_message = "secret_arns_by_env must map the four enabled environment variables."
  }

  assert {
    condition     = length(output.secret_arns) == 4
    error_message = "secret_arns must list the four enabled secrets."
  }

  assert {
    condition     = output.bootstrap_admin_token_arn == null
    error_message = "The bootstrap admin token is disabled by default."
  }
}

run "disabled_optional_secrets" {
  command = plan

  module {
    source = "./modules/secrets"
  }

  variables {
    metrics_token_enabled            = false
    bootstrap_admin_password_enabled = false
  }

  assert {
    condition     = toset(keys(aws_secretsmanager_secret.generated)) == toset(["secret_key", "hmac_key"])
    error_message = "Disabled secrets must not be created."
  }

  assert {
    condition     = output.metrics_token_arn == null && output.bootstrap_admin_password_arn == null
    error_message = "Disabled secrets must output null."
  }

  assert {
    condition     = toset(keys(output.secret_arns_by_env)) == toset(["OPENARTIFACT_SECRET_KEY", "AUTH_HMAC_KEY"])
    error_message = "Only enabled secrets appear in secret_arns_by_env."
  }

  assert {
    condition     = length(output.secret_arns) == 2
    error_message = "Only enabled secrets appear in secret_arns."
  }
}

run "bootstrap_admin_token" {
  command = plan

  module {
    source = "./modules/secrets"
  }

  variables {
    bootstrap_admin_token_enabled = true
  }

  assert {
    condition     = contains(keys(aws_secretsmanager_secret.generated), "bootstrap_admin_token")
    error_message = "The bootstrap admin token must be created when enabled."
  }

  assert {
    condition     = !contains(keys(output.secret_arns_by_env), "OPENARTIFACT_BOOTSTRAP_ADMIN_TOKEN") && length(output.secret_arns) == 5
    error_message = "The token has no env var on ECS: it is in secret_arns but not in secret_arns_by_env."
  }
}

run "bring_your_own_arns_skip_creation" {
  command = plan

  module {
    source = "./modules/secrets"
  }

  variables {
    existing_secret_arns = {
      secret_key    = "arn:aws:secretsmanager:eu-west-1:123456789012:secret:byo-secret-key-AbCdEf"
      metrics_token = "arn:aws:secretsmanager:eu-west-1:123456789012:secret:byo-metrics-AbCdEf"
    }
  }

  assert {
    condition     = toset(keys(aws_secretsmanager_secret.generated)) == toset(["hmac_key", "bootstrap_admin_password"])
    error_message = "Secrets with a bring-your-own ARN must not be created."
  }

  assert {
    condition     = toset(keys(aws_secretsmanager_secret_version.generated)) == toset(["hmac_key", "bootstrap_admin_password"])
    error_message = "No value may be written for a bring-your-own secret."
  }

  assert {
    condition     = output.secret_key_arn == "arn:aws:secretsmanager:eu-west-1:123456789012:secret:byo-secret-key-AbCdEf"
    error_message = "The bring-your-own ARN must be passed through."
  }

  assert {
    condition     = output.secret_arns_by_env["METRICS_AUTH_TOKEN"] == "arn:aws:secretsmanager:eu-west-1:123456789012:secret:byo-metrics-AbCdEf" && contains(output.secret_arns, output.secret_key_arn)
    error_message = "Bring-your-own ARNs must appear in the aggregate outputs."
  }
}

run "bring_your_own_ignored_when_disabled" {
  command = plan

  module {
    source = "./modules/secrets"
  }

  variables {
    metrics_token_enabled = false
    existing_secret_arns = {
      metrics_token = "arn:aws:secretsmanager:eu-west-1:123456789012:secret:byo-metrics-AbCdEf"
    }
  }

  assert {
    condition     = output.metrics_token_arn == null
    error_message = "A disabled secret outputs null even when an ARN was supplied."
  }
}

run "secret_version_rotation_spares_encryption_key" {
  command = plan

  module {
    source = "./modules/secrets"
  }

  variables {
    secret_version                = 3
    bootstrap_admin_token_enabled = true
  }

  assert {
    condition     = aws_secretsmanager_secret_version.generated["secret_key"].secret_string_wo_version == 1
    error_message = "Bumping secret_version must never rotate OPENARTIFACT_SECRET_KEY."
  }

  assert {
    condition = alltrue([
      for k, v in aws_secretsmanager_secret_version.generated : v.secret_string_wo_version == 3 if k != "secret_key"
    ])
    error_message = "Bumping secret_version must rotate every other generated secret."
  }
}

run "customer_managed_key_and_recovery_window" {
  command = plan

  module {
    source = "./modules/secrets"
  }

  variables {
    kms_key_arn             = "arn:aws:kms:eu-west-1:123456789012:key/11111111-2222-3333-4444-555555555555"
    recovery_window_in_days = 7
    tags                    = { Env = "test" }
  }

  assert {
    condition = alltrue([
      for s in values(aws_secretsmanager_secret.generated) :
      s.kms_key_id == "arn:aws:kms:eu-west-1:123456789012:key/11111111-2222-3333-4444-555555555555" && s.recovery_window_in_days == 7 && s.tags["Env"] == "test"
    ])
    error_message = "KMS key, recovery window and tags must be applied to every secret."
  }
}

run "rejects_invalid_recovery_window" {
  command = plan

  module {
    source = "./modules/secrets"
  }

  variables {
    recovery_window_in_days = 3
  }

  expect_failures = [var.recovery_window_in_days]
}

run "rejects_invalid_existing_arn" {
  command = plan

  module {
    source = "./modules/secrets"
  }

  variables {
    existing_secret_arns = {
      hmac_key = "not-an-arn"
    }
  }

  expect_failures = [var.existing_secret_arns]
}

run "rejects_invalid_secret_version" {
  command = plan

  module {
    source = "./modules/secrets"
  }

  variables {
    secret_version = 0
  }

  expect_failures = [var.secret_version]
}

run "rejects_invalid_name" {
  command = plan

  module {
    source = "./modules/secrets"
  }

  variables {
    name = "X"
  }

  expect_failures = [var.name]
}
