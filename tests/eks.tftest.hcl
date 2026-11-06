# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# Plan-only behaviour tests for modules/eks (no AWS credentials, no cluster needed).
#
# - helm and kubernetes are mock providers.
# - aws is a REAL provider configured with dummy credentials and every endpoint pointed at a
#   closed local port, because Terraform's provider mocking does not support ephemeral resource
#   types and the module reads secrets with ephemeral "aws_secretsmanager_secret_version" (write-only
#   delivery). Nothing here ever talks to AWS: data sources are overridden and the storage and
#   database sub-modules are replaced by their outputs (override_module) so the generated Helm
#   values are known at plan time. The ephemeral read is never reached in these runs (see
#   eks-write-only.tftest.hcl, which has no module overrides).
# - random is real (ephemeral passwords of modules/secrets).
# Run: terraform test -filter=tests/eks.tftest.hcl   (or tofu test)

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

override_module {
  target = module.storage
  outputs = {
    bucket_id          = "oa-blobs-123456789012-eu-west-1"
    bucket_arn         = "arn:aws:s3:::oa-blobs-123456789012-eu-west-1"
    bucket_region      = "eu-west-1"
    kms_key_arn        = "arn:aws:kms:eu-west-1:123456789012:key/11111111-2222-3333-4444-555555555555"
    kms_key_id         = "11111111-2222-3333-4444-555555555555"
    access_policy_json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"s3:GetObject\",\"Resource\":\"arn:aws:s3:::oa-blobs-123456789012-eu-west-1/*\"}]}"
  }
}

override_module {
  target = module.database
  outputs = {
    endpoint               = "oa-db.abcdefghijkl.eu-west-1.rds.amazonaws.com"
    port                   = 5432
    database_name          = "openartifact"
    master_username        = "openartifact"
    master_user_secret_arn = "arn:aws:secretsmanager:eu-west-1:123456789012:secret:rds!db-abc-AbCdEf"
    kms_key_arn            = "arn:aws:kms:eu-west-1:123456789012:key/66666666-7777-8888-9999-000000000000"
    security_group_id      = "sg-0db00000000000000"
    instance_arn           = "arn:aws:rds:eu-west-1:123456789012:db:oa-db"
    instance_id            = "oa-db"
  }
}

variables {
  name                        = "oa-eks"
  cluster_name                = "prod-eks"
  vpc_id                      = "vpc-0123456789abcdef0"
  database_subnet_ids         = ["subnet-0aaa1111", "subnet-0bbb2222"]
  workload_security_group_ids = ["sg-0a0b0c0d0e0f00000"]
  allowed_ingress_cidrs       = ["203.0.113.0/24"]
  secret_store_name           = "aws-secretsmanager"
}

run "defaults" {
  command = plan

  module {
    source = "./modules/eks"
  }

  assert {
    condition     = helm_release.openartifact.chart == "openartifact" && helm_release.openartifact.repository == "oci://ghcr.io/openartifact/charts" && helm_release.openartifact.version == "0.16.2"
    error_message = "The release must install the pinned official OCI chart 0.16.2."
  }

  assert {
    condition     = helm_release.openartifact.atomic && helm_release.openartifact.wait && helm_release.openartifact.cleanup_on_fail && helm_release.openartifact.timeout == 600
    error_message = "The release must be atomic, wait for readiness, clean up on failure and time out after 600 s."
  }

  assert {
    condition     = yamldecode(helm_release.openartifact.values[0]).storage.type == "s3" && yamldecode(helm_release.openartifact.values[0]).storage.bucket == "oa-blobs-123456789012-eu-west-1" && yamldecode(helm_release.openartifact.values[0]).storage.region == "eu-west-1"
    error_message = "Blob storage must be the S3 bucket of the storage module."
  }

  assert {
    condition     = yamldecode(helm_release.openartifact.values[0]).persistence.enabled == false
    error_message = "The pods must be stateless: no persistent volume."
  }

  assert {
    condition     = yamldecode(helm_release.openartifact.values[0]).database.external.host == "oa-db.abcdefghijkl.eu-west-1.rds.amazonaws.com" && yamldecode(helm_release.openartifact.values[0]).database.external.existingSecret == "openartifact-db" && yamldecode(helm_release.openartifact.values[0]).database.external.existingSecretPasswordKey == "password" && yamldecode(helm_release.openartifact.values[0]).database.sslMode == "require"
    error_message = "The database must come from the database module, with the password read from the existing Secret."
  }

  assert {
    condition     = yamldecode(helm_release.openartifact.values[0]).secrets.existingSecret == "openartifact-app" && yamldecode(helm_release.openartifact.values[0]).bootstrap.existingSecret == "openartifact-bootstrap" && yamldecode(helm_release.openartifact.values[0]).metrics.enabled == true
    error_message = "Application and bootstrap secrets must be referenced by Secret name."
  }

  assert {
    condition     = yamldecode(helm_release.openartifact.values[0]).config.trustedProxies == ["10.20.0.0/16"]
    error_message = "trustedProxies must default to the VPC CIDR."
  }

  assert {
    condition     = yamldecode(helm_release.openartifact.values[0]).config.shutdownDelay == 15 && yamldecode(helm_release.openartifact.values[0]).config.shutdownTimeout == 60 && yamldecode(helm_release.openartifact.values[0]).terminationGracePeriodSeconds == 120
    error_message = "terminationGracePeriodSeconds must cover shutdownDelay + shutdownTimeout + 45."
  }

  assert {
    condition     = yamldecode(helm_release.openartifact.values[0]).replicaCount == 2 && yamldecode(helm_release.openartifact.values[0]).worker.enabled == false && yamldecode(helm_release.openartifact.values[0]).podDisruptionBudget.enabled == true && length(yamldecode(helm_release.openartifact.values[0]).topologySpreadConstraints) == 1
    error_message = "Two web replicas with a PodDisruptionBudget and zone spreading are expected by default."
  }

  assert {
    condition     = yamldecode(helm_release.openartifact.values[0]).ingress.enabled == false
    error_message = "The ingress must be off by default."
  }

  assert {
    condition     = !can(yamldecode(helm_release.openartifact.values[0]).image.tag)
    error_message = "Without image_tag the chart's appVersion must be used."
  }

  assert {
    condition     = kubernetes_namespace_v1.this[0].metadata[0].name == "openartifact" && kubernetes_namespace_v1.this[0].metadata[0].labels["pod-security.kubernetes.io/enforce"] == "restricted"
    error_message = "The namespace must be created with the restricted Pod Security Standard."
  }
}

run "no_secret_material_in_values" {
  command = plan

  module {
    source = "./modules/eks"
  }

  variables {
    bootstrap_admin_token_enabled = true
  }

  assert {
    condition = alltrue([
      for key in ["password", "authToken", "hmacKey", "encryptionKey", "apiKey", "extra", "accessKey", "secretKey"] :
      !strcontains(helm_release.openartifact.values[0], "${key}:")
    ])
    error_message = "The generated values must reference Secrets by name only: none of the chart's secret value keys may be present."
  }

  assert {
    condition     = !strcontains(helm_release.openartifact.values[0], "oa_pat_") && !strcontains(helm_release.openartifact.values[0], "AbCdEf")
    error_message = "The values must not contain any secret value or Secrets Manager ARN."
  }

  assert {
    condition     = yamldecode(helm_release.openartifact.values[0]).bootstrap.adminToken.enabled == true
    error_message = "bootstrap_admin_token_enabled must enable the chart's admin token."
  }
}

run "pod_identity" {
  command = plan

  module {
    source = "./modules/eks"
  }

  assert {
    condition     = aws_eks_pod_identity_association.this.cluster_name == "prod-eks" && aws_eks_pod_identity_association.this.namespace == "openartifact" && aws_eks_pod_identity_association.this.service_account == "openartifact"
    error_message = "The association must target the cluster, namespace and the release's service account."
  }

  assert {
    condition     = yamldecode(helm_release.openartifact.values[0]).serviceAccount.create == true && yamldecode(helm_release.openartifact.values[0]).serviceAccount.name == aws_eks_pod_identity_association.this.service_account
    error_message = "The chart must create the service account the association binds to."
  }

  assert {
    condition     = jsondecode(aws_iam_role.pod_identity.assume_role_policy).Statement[0].Principal.Service == "pods.eks.amazonaws.com" && contains(jsondecode(aws_iam_role.pod_identity.assume_role_policy).Statement[0].Action, "sts:AssumeRole") && contains(jsondecode(aws_iam_role.pod_identity.assume_role_policy).Statement[0].Action, "sts:TagSession")
    error_message = "The role must trust pods.eks.amazonaws.com for sts:AssumeRole and sts:TagSession."
  }

  assert {
    condition     = jsondecode(aws_iam_role.pod_identity.assume_role_policy).Statement[0].Condition.StringEquals["aws:RequestTag/kubernetes-service-account"] == "openartifact" && jsondecode(aws_iam_role.pod_identity.assume_role_policy).Statement[0].Condition.StringEquals["aws:RequestTag/kubernetes-namespace"] == "openartifact" && jsondecode(aws_iam_role.pod_identity.assume_role_policy).Statement[0].Condition.StringEquals["aws:RequestTag/eks-cluster-name"] == "prod-eks"
    error_message = "The trust policy must be limited to this cluster, namespace and service account."
  }

  assert {
    condition     = aws_iam_role_policy.blob_storage.name == "blob-storage" && aws_iam_role.pod_identity.name == "oa-eks-eks-eu-west-1" && aws_iam_role.pod_identity.tags["Name"] == "oa-eks-eks-eu-west-1"
    error_message = "The pod role must carry the blob-storage inline policy and a region-qualified name."
  }
}

run "external_secrets_default" {
  command = plan

  module {
    source = "./modules/eks"
  }

  assert {
    condition     = toset(keys(kubernetes_manifest.external_secret)) == toset(["app", "database", "bootstrap"])
    error_message = "ExternalSecrets for the app, database and bootstrap Secrets must be created by default."
  }

  assert {
    condition     = kubernetes_manifest.external_secret["app"].manifest.apiVersion == "external-secrets.io/v1" && kubernetes_manifest.external_secret["app"].manifest.kind == "ExternalSecret" && kubernetes_manifest.external_secret["app"].manifest.spec.secretStoreRef.name == "aws-secretsmanager" && kubernetes_manifest.external_secret["app"].manifest.spec.secretStoreRef.kind == "ClusterSecretStore"
    error_message = "The ExternalSecrets must reference the caller's ClusterSecretStore."
  }

  assert {
    condition     = toset([for d in kubernetes_manifest.external_secret["app"].manifest.spec.data : d.secretKey]) == toset(["OPENARTIFACT_SECRET_KEY", "AUTH_HMAC_KEY", "METRICS_AUTH_TOKEN"])
    error_message = "The app Secret must carry the encryption key, the HMAC key and the metrics token under their environment variable names."
  }

  assert {
    condition     = toset([for d in kubernetes_manifest.external_secret["bootstrap"].manifest.spec.data : d.secretKey]) == toset(["admin-password"])
    error_message = "The bootstrap Secret must carry admin-password (no token by default)."
  }

  assert {
    condition     = one(kubernetes_manifest.external_secret["database"].manifest.spec.data).secretKey == "password" && one(kubernetes_manifest.external_secret["database"].manifest.spec.data).remoteRef.property == "password" && kubernetes_manifest.external_secret["database"].manifest.spec.target.name == "openartifact-db"
    error_message = "The database Secret must hold the password property of the RDS-managed JSON secret."
  }

  assert {
    condition     = length(kubernetes_secret_v1.app) == 0 && length(kubernetes_secret_v1.database) == 0 && length(kubernetes_secret_v1.bootstrap) == 0
    error_message = "No write-only Secret may exist in external_secrets mode."
  }
}

run "existing_delivery" {
  command = plan

  module {
    source = "./modules/eks"
  }

  variables {
    secret_delivery                = "existing"
    secret_store_name              = null
    existing_secret_name           = "oa-env"
    existing_db_secret_name        = "oa-dbpass"
    existing_bootstrap_secret_name = "oa-first-admin"
  }

  assert {
    condition     = length(kubernetes_manifest.external_secret) == 0 && length(kubernetes_secret_v1.app) == 0 && length(kubernetes_secret_v1.database) == 0 && length(kubernetes_secret_v1.bootstrap) == 0
    error_message = "Nothing may create Secrets when secret_delivery is existing."
  }

  assert {
    condition     = length(module.secrets) == 0
    error_message = "No Secrets Manager secret may be generated when the caller brings the Kubernetes Secrets."
  }

  assert {
    condition     = yamldecode(helm_release.openartifact.values[0]).secrets.existingSecret == "oa-env" && yamldecode(helm_release.openartifact.values[0]).database.external.existingSecret == "oa-dbpass" && yamldecode(helm_release.openartifact.values[0]).bootstrap.existingSecret == "oa-first-admin"
    error_message = "The chart must reference the caller's Secret names."
  }
}

run "ingress_alb_annotations" {
  command = plan

  module {
    source = "./modules/eks"
  }

  variables {
    ingress = {
      enabled         = true
      host            = "artifacts.example.com"
      certificate_arn = "arn:aws:acm:eu-west-1:123456789012:certificate/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
      group_name      = "shared"
      wafv2_acl_arn   = "arn:aws:wafv2:eu-west-1:123456789012:regional/webacl/oa/11111111-2222-3333-4444-555555555555"
    }
    allowed_ingress_cidrs = ["203.0.113.0/24", "198.51.100.7/32"]
  }

  assert {
    condition     = yamldecode(helm_release.openartifact.values[0]).ingress.className == "alb" && yamldecode(helm_release.openartifact.values[0]).ingress.hosts[0].host == "artifacts.example.com"
    error_message = "The ingress must use the alb class and the configured host."
  }

  assert {
    condition     = yamldecode(helm_release.openartifact.values[0]).ingress.annotations["alb.ingress.kubernetes.io/ssl-policy"] == "ELBSecurityPolicy-TLS13-1-2-2021-06" && yamldecode(helm_release.openartifact.values[0]).ingress.annotations["alb.ingress.kubernetes.io/ssl-redirect"] == "443"
    error_message = "The ALB must use the TLS 1.3 policy and redirect HTTP to HTTPS."
  }

  assert {
    condition     = yamldecode(helm_release.openartifact.values[0]).ingress.annotations["alb.ingress.kubernetes.io/target-type"] == "ip" && yamldecode(helm_release.openartifact.values[0]).ingress.annotations["alb.ingress.kubernetes.io/healthcheck-path"] == "/ready" && yamldecode(helm_release.openartifact.values[0]).ingress.annotations["alb.ingress.kubernetes.io/group.name"] == "shared"
    error_message = "The ALB must use ip targets, the /ready health check and the configured group."
  }

  assert {
    condition     = yamldecode(helm_release.openartifact.values[0]).ingress.annotations["alb.ingress.kubernetes.io/inbound-cidrs"] == "203.0.113.0/24,198.51.100.7/32" && !strcontains(yamldecode(helm_release.openartifact.values[0]).ingress.annotations["alb.ingress.kubernetes.io/inbound-cidrs"], "0.0.0.0/0")
    error_message = "inbound-cidrs must be exactly allowed_ingress_cidrs."
  }

  assert {
    condition     = strcontains(yamldecode(helm_release.openartifact.values[0]).ingress.annotations["alb.ingress.kubernetes.io/load-balancer-attributes"], "idle_timeout.timeout_seconds=300") && strcontains(yamldecode(helm_release.openartifact.values[0]).ingress.annotations["alb.ingress.kubernetes.io/load-balancer-attributes"], "routing.http.drop_invalid_header_fields.enabled=true") && strcontains(yamldecode(helm_release.openartifact.values[0]).ingress.annotations["alb.ingress.kubernetes.io/load-balancer-attributes"], "deletion_protection.enabled=true")
    error_message = "The ALB attributes must set the idle timeout, drop invalid headers and enable deletion protection."
  }

  assert {
    condition     = yamldecode(helm_release.openartifact.values[0]).ingress.annotations["alb.ingress.kubernetes.io/wafv2-acl-arn"] == "arn:aws:wafv2:eu-west-1:123456789012:regional/webacl/oa/11111111-2222-3333-4444-555555555555" && yamldecode(helm_release.openartifact.values[0]).ingress.annotations["alb.ingress.kubernetes.io/listen-ports"] == "[{\"HTTP\":80},{\"HTTPS\":443}]"
    error_message = "The WAF ACL and the HTTP/HTTPS listeners must be configured."
  }

  assert {
    condition     = yamldecode(helm_release.openartifact.values[0]).baseUrl == "https://artifacts.example.com"
    error_message = "baseUrl must default to https://<ingress host>."
  }
}

run "worker_split_and_image_pin" {
  command = plan

  module {
    source = "./modules/eks"
  }

  variables {
    worker_enabled       = true
    worker_replica_count = 2
    replica_count        = 3
    image_tag            = "0.19.2"
    image_digest         = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    chart_version        = "0.16.1"
    release_name         = "oa"
  }

  assert {
    condition     = yamldecode(helm_release.openartifact.values[0]).worker.enabled == true && yamldecode(helm_release.openartifact.values[0]).worker.replicaCount == 2 && yamldecode(helm_release.openartifact.values[0]).replicaCount == 3
    error_message = "The worker split and the replica counts must reach the chart."
  }

  assert {
    condition     = yamldecode(helm_release.openartifact.values[0]).image.tag == "0.19.2" && yamldecode(helm_release.openartifact.values[0]).image.digest == "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    error_message = "The image tag and digest must reach the chart."
  }

  assert {
    condition     = helm_release.openartifact.version == "0.16.1" && helm_release.openartifact.name == "oa" && aws_eks_pod_identity_association.this.service_account == "oa"
    error_message = "A custom release name must also be the service account of the association."
  }
}

run "rejects_missing_secret_store" {
  command = plan

  module {
    source = "./modules/eks"
  }

  variables {
    secret_store_name = null
  }

  expect_failures = [var.secret_store_name]
}

run "rejects_existing_without_names" {
  command = plan

  module {
    source = "./modules/eks"
  }

  variables {
    secret_delivery   = "existing"
    secret_store_name = null
  }

  expect_failures = [
    var.existing_secret_name,
    var.existing_db_secret_name,
    var.existing_bootstrap_secret_name,
  ]
}

run "rejects_empty_ingress_cidrs" {
  command = plan

  module {
    source = "./modules/eks"
  }

  variables {
    allowed_ingress_cidrs = []
  }

  expect_failures = [var.allowed_ingress_cidrs]
}

run "rejects_invalid_ingress_cidr" {
  command = plan

  module {
    source = "./modules/eks"
  }

  variables {
    allowed_ingress_cidrs = ["not-a-cidr"]
  }

  expect_failures = [var.allowed_ingress_cidrs]
}

run "rejects_bad_chart_version" {
  command = plan

  module {
    source = "./modules/eks"
  }

  variables {
    chart_version = "v0.16"
  }

  expect_failures = [var.chart_version]
}

run "rejects_ingress_without_certificate" {
  command = plan

  module {
    source = "./modules/eks"
  }

  variables {
    ingress = {
      enabled = true
      host    = "artifacts.example.com"
    }
  }

  expect_failures = [var.ingress]
}

run "rejects_weak_tls_policy" {
  command = plan

  module {
    source = "./modules/eks"
  }

  variables {
    ingress = {
      enabled         = true
      host            = "artifacts.example.com"
      certificate_arn = "arn:aws:acm:eu-west-1:123456789012:certificate/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
      ssl_policy      = "ELBSecurityPolicy-2016-08"
    }
  }

  expect_failures = [var.ingress]
}

run "rejects_short_termination_grace" {
  command = plan

  module {
    source = "./modules/eks"
  }

  variables {
    termination_grace_period_seconds = 30
  }

  expect_failures = [var.termination_grace_period_seconds]
}

run "rejects_invalid_namespace" {
  command = plan

  module {
    source = "./modules/eks"
  }

  variables {
    namespace = "Open_Artifact"
  }

  expect_failures = [var.namespace]
}

run "rejects_admin_token_without_password" {
  command = plan

  module {
    source = "./modules/eks"
  }

  variables {
    bootstrap_admin_password_enabled = false
    bootstrap_admin_token_enabled    = true
  }

  expect_failures = [var.bootstrap_admin_token_enabled]
}
