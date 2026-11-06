# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

terraform {
  required_version = ">= 1.11"

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

  # Keep the state in a versioned, encrypted S3 bucket with native locking (no DynamoDB table
  # needed). Uncomment, fill in your bucket and run `terraform init -migrate-state`.
  # backend "s3" {
  #   bucket       = "my-terraform-state"
  #   key          = "openartifact/eks/terraform.tfstate"
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
        Example     = "eks"
        ManagedBy   = "terraform"
      },
      var.tags,
    )
  }
}

# The cluster must already exist and its API must be reachable from where Terraform runs: the
# kubernetes provider talks to it at plan time (ExternalSecret objects). Credentials come from
# `aws eks get-token`, which needs the AWS CLI and an identity that is mapped to a Kubernetes
# role that may create namespaces, secrets and the chart's objects (for example through an EKS
# access entry).
data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region]
    }
  }
}
