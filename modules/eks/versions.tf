# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: MPL-2.0

terraform {
  required_version = ">= 1.11"

  # The random provider (~> 3.9) is required by modules/secrets, which generates the
  # application secrets with ephemeral resources; this module does not use it directly.
  # Providers are configured by the caller (see examples/eks): the cluster must be reachable
  # at plan time for the kubernetes provider.
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.72"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.5"
    }
  }
}
