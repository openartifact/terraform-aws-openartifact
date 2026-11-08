# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: MPL-2.0

# Plan-only test of modules/eks with secret_delivery = "terraform_write_only". Kept apart from
# tests/eks.tftest.hcl because the ephemeral "aws_secretsmanager_secret_version" is opened at
# plan time as soon as its secret_id is known, so here the database module is NOT replaced by
# override_module: its (planned, not created) secret ARN stays unknown and the read is deferred
# to apply. Nothing talks to AWS: the aws provider is real with dummy credentials and endpoints
# on a closed local port (Terraform's provider mocking does not support ephemeral resources),
# and every data source that would call AWS is overridden.
# Run: terraform test -filter=tests/eks-write-only.tftest.hcl   (or tofu test)

provider "aws" {
  region                      = "eu-west-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_requesting_account_id  = true

  endpoints {
    ec2            = "http://127.0.0.1:9"
    eks            = "http://127.0.0.1:9"
    iam            = "http://127.0.0.1:9"
    secretsmanager = "http://127.0.0.1:9"
    sts            = "http://127.0.0.1:9"
  }
}

mock_provider "helm" {}

mock_provider "kubernetes" {}

override_data {
  target = data.aws_region.current
  values = {
    region = "eu-west-1"
    name   = "eu-west-1"
  }
}

override_data {
  target = data.aws_vpc.selected
  values = {
    cidr_block = "10.20.0.0/16"
  }
}

override_data {
  target = data.aws_eks_addon.pod_identity_agent
  values = {
    addon_version = "v1.3.5-eksbuild.1"
  }
}

override_data {
  target = module.storage.data.aws_caller_identity.current
  values = {
    account_id = "123456789012"
    arn        = "arn:aws:iam::123456789012:user/test"
    user_id    = "AIDAEXAMPLE"
  }
}

override_data {
  target = module.storage.data.aws_partition.current
  values = {
    partition  = "aws"
    dns_suffix = "amazonaws.com"
  }
}

override_data {
  target = module.storage.data.aws_region.current
  values = {
    region = "eu-west-1"
    name   = "eu-west-1"
  }
}

override_data {
  target = module.database.data.aws_caller_identity.current
  values = {
    account_id = "123456789012"
    arn        = "arn:aws:iam::123456789012:user/test"
    user_id    = "AIDAEXAMPLE"
  }
}

override_data {
  target = module.database.data.aws_partition.current
  values = {
    partition  = "aws"
    dns_suffix = "amazonaws.com"
  }
}

override_data {
  target = module.database.data.aws_region.current
  values = {
    region = "eu-west-1"
    name   = "eu-west-1"
  }
}

variables {
  name                        = "oa-eks"
  cluster_name                = "prod-eks"
  vpc_id                      = "vpc-0123456789abcdef0"
  database_subnet_ids         = ["subnet-0aaa1111", "subnet-0bbb2222"]
  workload_security_group_ids = ["sg-0a0b0c0d0e0f00000"]
  allowed_ingress_cidrs       = ["203.0.113.0/24"]
  secret_delivery             = "terraform_write_only"
}

run "write_only_delivery" {
  command = plan

  module {
    source = "./modules/eks"
  }

  assert {
    condition     = length(kubernetes_manifest.external_secret) == 0
    error_message = "No ExternalSecret may exist when secret_delivery is terraform_write_only."
  }

  assert {
    condition     = length(kubernetes_secret_v1.app) == 1 && length(kubernetes_secret_v1.database) == 1 && length(kubernetes_secret_v1.bootstrap) == 1
    error_message = "The write-only Secrets must be created."
  }

  assert {
    condition     = kubernetes_secret_v1.app[0].metadata[0].name == "openartifact-app" && kubernetes_secret_v1.database[0].metadata[0].name == "openartifact-db" && kubernetes_secret_v1.bootstrap[0].metadata[0].name == "openartifact-bootstrap"
    error_message = "The write-only Secrets must have the names the chart references."
  }

  assert {
    condition     = kubernetes_secret_v1.app[0].data_wo_revision == 1 && kubernetes_secret_v1.database[0].data_wo_revision == 1
    error_message = "The write-only Secrets must carry the revision (default 1)."
  }
}

run "write_only_revision_bump" {
  command = plan

  module {
    source = "./modules/eks"
  }

  variables {
    secret_data_revision = 3
  }

  assert {
    condition     = kubernetes_secret_v1.app[0].data_wo_revision == 3 && kubernetes_secret_v1.database[0].data_wo_revision == 3 && kubernetes_secret_v1.bootstrap[0].data_wo_revision == 3
    error_message = "secret_data_revision must reach every write-only Secret (it is what triggers a rewrite)."
  }
}
