# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: MPL-2.0

terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.72"
    }
  }

  # Keep the state in a versioned, encrypted S3 bucket with native locking (no DynamoDB table
  # needed). Uncomment, fill in your bucket and run `terraform init -migrate-state`.
  # backend "s3" {
  #   bucket       = "my-terraform-state"
  #   key          = "openartifact/complete/terraform.tfstate"
  #   region       = "eu-west-1"
  #   encrypt      = true
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = merge(
      {
        Application = "openartifact"
        Example     = "complete"
        ManagedBy   = "terraform"
      },
      var.tags,
    )
  }
}
