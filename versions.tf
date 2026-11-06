# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

terraform {
  required_version = ">= 1.11"

  # The random provider (~> 3.9) is required by modules/secrets, which generates the
  # application secrets with ephemeral resources; this module does not use it directly.
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.72"
    }
  }
}
