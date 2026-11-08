<!--
SPDX-FileCopyrightText: The OpenArtifact Authors

SPDX-License-Identifier: MPL-2.0
-->

# OpenArtifact on an existing EKS cluster (Helm)

Deploys OpenArtifact onto an **existing** EKS cluster with the official Helm
chart (`oci://ghcr.io/openartifact/charts/openartifact`, pinned by
`chart_version`) and creates the AWS resources around it: the S3 bucket for the
blobs (with KMS), the RDS PostgreSQL database, the generated application
secrets in Secrets Manager, and an IAM role for the pods through
**EKS Pod Identity**. The module does not create the cluster, the VPC, the load
balancer controller or the External Secrets Operator.

The module is part of [terraform-aws-openartifact](../../README.md). See
[examples/eks](../../examples/eks) for a complete configuration including the
provider setup.

## Usage

```hcl
module "openartifact" {
  source  = "openartifact/openartifact/aws//modules/eks"
  version = "~> 0.1"

  cluster_name = "prod-eks"
  vpc_id       = "vpc-0123456789abcdef0"

  database_subnet_ids         = ["subnet-0aaaaaaaaaaaaaaa1", "subnet-0bbbbbbbbbbbbbbb2"] # private subnets
  workload_security_group_ids = [data.aws_eks_cluster.this.vpc_config[0].cluster_security_group_id]

  allowed_ingress_cidrs = ["203.0.113.0/24"] # who may reach the ALB: no default, no 0.0.0.0/0 by accident

  secret_store_name = "aws-secretsmanager" # ClusterSecretStore of the External Secrets Operator

  ingress = {
    enabled         = true
    host            = "artifacts.example.com"
    certificate_arn = "arn:aws:acm:eu-west-1:123456789012:certificate/..."
  }

  tags = { Project = "openartifact" }
}
```

The `helm` and `kubernetes` providers must be configured by the caller for the
target cluster, and `kubernetes_manifest` (used for the `ExternalSecret`
objects) talks to the cluster already at **plan** time: the cluster API must be
reachable from where you run Terraform and the External Secrets Operator CRDs
must exist. The example shows the wiring.

## Prerequisites

- Kubernetes 1.29 or newer (the chart requires it).
- **EKS Pod Identity**: the `eks-pod-identity-agent` add-on installed (not
  needed on EKS Auto Mode). The module only warns, through a `check` block, when
  the add-on is missing.
- **AWS Load Balancer Controller**, when `ingress.enabled`.
- **External Secrets Operator** with a (Cluster)SecretStore for AWS Secrets
  Manager, when `secret_delivery = "external_secrets"` (the default). The
  identity of the store needs the policy in the output
  `external_secrets_policy_json`; the module does not attach it, the role belongs
  to whoever installed the operator.
- The pods must reach the database: pass the node (or pod) security groups in
  `workload_security_group_ids`.

## What is created

| Piece | Where |
|---|---|
| S3 blob bucket + KMS key | `modules/storage` |
| RDS PostgreSQL, master password managed and rotated by RDS | `modules/database` |
| Generated `OPENARTIFACT_SECRET_KEY`, `AUTH_HMAC_KEY`, metrics token, bootstrap admin password in Secrets Manager | `modules/secrets` (not with `secret_delivery = "existing"`) |
| IAM role (trust: `pods.eks.amazonaws.com`, limited to this cluster, namespace and service account) with the storage policy, and the Pod Identity association | `iam.tf` |
| Namespace (Pod Security Standard `restricted` enforced by default) | `main.tf` |
| `ExternalSecret`s or write-only Kubernetes Secrets | `secrets.tf` |
| The Helm release | `helm.tf` |

The pods are stateless: blobs live in S3 and all state in PostgreSQL, so no
persistent volume is created and replicas can be scaled freely.

## Secrets: three delivery modes

No secret value ever appears in the Helm values or in the Terraform state
(generated values are ephemeral). The chart only gets the **names** of the
Kubernetes Secrets, `<release>-app`, `<release>-db` and `<release>-bootstrap`
(or your own names with `existing`).

| `secret_delivery` | How the Kubernetes Secrets are filled | Trade-offs |
|---|---|---|
| `external_secrets` (default) | `ExternalSecret` objects; the operator syncs from Secrets Manager every `refresh_interval`, including the RDS-rotated database password. | Needs the operator and its IAM policy, and a reachable cluster at plan time. Keeps secrets out of Terraform entirely. |
| `terraform_write_only` | Terraform reads the secrets with ephemeral resources and writes the Kubernetes Secrets with write-only arguments (`data_wo`). | No operator, but nothing refreshes the Secrets: bump `secret_data_revision` to rewrite them (for example after an RDS password rotation). Needs Terraform 1.11+ / OpenTofu 1.11+ and the Terraform identity to read the secrets. |
| `existing` | Nothing: you create the Secrets (`existing_secret_name`, `existing_db_secret_name`, `existing_bootstrap_secret_name`) before the first apply. | No Secrets Manager secrets are generated. The database password must be copied from `database_master_secret_arn` yourself. |

The Secrets use these keys: `<release>-app`: `OPENARTIFACT_SECRET_KEY`,
`AUTH_HMAC_KEY` (and `METRICS_AUTH_TOKEN` with `enable_metrics_token`),
`<release>-db`: `password`, `<release>-bootstrap`: `admin-password` (and
`admin-token`, which must start with `oa_pat_`, with
`bootstrap_admin_token_enabled`).

## Operational notes

- **`OPENARTIFACT_SECRET_KEY` must stay stable.** It encrypts data at rest;
  losing or replacing it makes stored secrets unreadable. Do not destroy the
  generated secret (`secrets_recovery_window_in_days` gives you a window), and
  keep a backup.
- **Database password rotation.** RDS rotates the master password about every 7
  days. OpenArtifact reads `DB_PASSWORD` once at start, so the pods must be
  restarted after a rotation (`kubectl rollout restart deployment/<release> -n
  <namespace>`), for example with a reloader controller. Until then new
  connections fail. With `terraform_write_only` bump `secret_data_revision`
  first.
- **ALB host name.** The load balancer is created by the controller, so its DNS
  name is not a Terraform output. Read it with `kubectl get ingress -n
  <namespace>` and point your DNS record at it.
- **Graceful shutdown.** `shutdown_delay_seconds`, `shutdown_timeout_seconds` and
  `termination_grace_period_seconds` feed the chart, and the ALB deregistration
  delay is derived from them, so rolling updates do not drop requests.
- **`db_sslmode`.** The default is `require`. `verify-full` needs the RDS CA
  bundle in the image, which the stock chart does not provide.
- **Service account token.** The chart's service account has
  `automountServiceAccountToken: false`. Pod Identity credentials are delivered by
  the EKS Pod Identity webhook through its own projected volume. [INFERENCE:
  from the AWS documentation, not exercised on a live cluster.]
- **Edge protection.** `allowed_ingress_cidrs` becomes the ALB's
  `inbound-cidrs`. Attach a WAFv2 ACL with `ingress.wafv2_acl_arn` for
  internet-facing deployments.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 6.72 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 3.3 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 3.5 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_aws"></a> [aws](#provider\_aws) | ~> 6.72 |
| <a name="provider_helm"></a> [helm](#provider\_helm) | ~> 3.3 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | ~> 3.5 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_database"></a> [database](#module\_database) | ../database | n/a |
| <a name="module_secrets"></a> [secrets](#module\_secrets) | ../secrets | n/a |
| <a name="module_storage"></a> [storage](#module\_storage) | ../storage | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_eks_pod_identity_association.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_iam_role.pod_identity](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.blob_storage](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [helm_release.openartifact](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [kubernetes_manifest.external_secret](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/manifest) | resource |
| [kubernetes_namespace_v1.this](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace_v1) | resource |
| [kubernetes_secret_v1.app](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_secret_v1.bootstrap](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_secret_v1.database](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_allowed_ingress_cidrs"></a> [allowed\_ingress\_cidrs](#input\_allowed\_ingress\_cidrs) | CIDRs allowed to reach the load balancer (alb.ingress.kubernetes.io/inbound-cidrs; IPv4 or IPv6). Required, with no default, so the registry is never opened to the Internet by accident: list 0.0.0.0/0 explicitly if you really want a public registry. | `list(string)` | n/a | yes |
| <a name="input_autoscaling"></a> [autoscaling](#input\_autoscaling) | Horizontal Pod Autoscaler of the web Deployment (chart autoscaling.*). When enabled it owns the replica count and replica\_count is ignored. | <pre>object({<br/>    enabled            = optional(bool, false)<br/>    min_replicas       = optional(number, 2)<br/>    max_replicas       = optional(number, 6)<br/>    cpu_target_percent = optional(number, 70)<br/>  })</pre> | `{}` | no |
| <a name="input_base_url"></a> [base\_url](#input\_base\_url) | Public base URL of OpenArtifact (BASE\_URL), for example https://artifacts.example.com. Required for SSO (OIDC/SAML) callbacks and webhook links; the SAML identifiers derive from it, so do not change it afterwards. null uses https://<ingress.host> when the ingress is enabled, otherwise it is left unset. | `string` | `null` | no |
| <a name="input_bootstrap_admin_password_enabled"></a> [bootstrap\_admin\_password\_enabled](#input\_bootstrap\_admin\_password\_enabled) | Create the first admin account from a generated password (chart bootstrap.existingSecret, key admin-password). The server applies it only to an EMPTY database and only reads it from a mounted file. false makes the server print a random password once in its log. | `bool` | `true` | no |
| <a name="input_bootstrap_admin_token_enabled"></a> [bootstrap\_admin\_token\_enabled](#input\_bootstrap\_admin\_token\_enabled) | Also create an admin API token named bootstrap from a generated secret (chart bootstrap.adminToken.enabled, key admin-token), so automation works on the first sync. Needs bootstrap\_admin\_password\_enabled. | `bool` | `false` | no |
| <a name="input_chart_repository"></a> [chart\_repository](#input\_chart\_repository) | Helm repository of the OpenArtifact chart. The official chart is published as an OCI artifact: oci://ghcr.io/openartifact/charts/openartifact. | `string` | `"oci://ghcr.io/openartifact/charts"` | no |
| <a name="input_chart_version"></a> [chart\_version](#input\_chart\_version) | Version of the OpenArtifact Helm chart (semantic version, no leading v). Pinned on purpose: chart upgrades can change the default image and need a database backup first. 0.16.2 ships OpenArtifact 0.19.2. | `string` | `"0.16.2"` | no |
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | Name of the EXISTING EKS cluster to deploy onto. The helm and kubernetes providers configured by the caller must point at this cluster. | `string` | n/a | yes |
| <a name="input_create_namespace"></a> [create\_namespace](#input\_create\_namespace) | Create the namespace with a kubernetes\_namespace\_v1 resource (before the secrets and the release, which both need it). Set to false when the namespace already exists. | `bool` | `true` | no |
| <a name="input_database_subnet_ids"></a> [database\_subnet\_ids](#input\_database\_subnet\_ids) | IDs of the private subnets for the RDS subnet group. At least two subnets in different Availability Zones are required by RDS; they must be routable from the pods. | `list(string)` | n/a | yes |
| <a name="input_db_allocated_storage"></a> [db\_allocated\_storage](#input\_db\_allocated\_storage) | Initial RDS storage in GiB. | `number` | `50` | no |
| <a name="input_db_apply_immediately"></a> [db\_apply\_immediately](#input\_db\_apply\_immediately) | Apply RDS modifications immediately instead of in the maintenance window. | `bool` | `false` | no |
| <a name="input_db_backup_retention_period"></a> [db\_backup\_retention\_period](#input\_db\_backup\_retention\_period) | Days to keep automated RDS backups (1-35). | `number` | `14` | no |
| <a name="input_db_deletion_protection"></a> [db\_deletion\_protection](#input\_db\_deletion\_protection) | Block deletion of the DB instance through the API. | `bool` | `true` | no |
| <a name="input_db_engine_version"></a> [db\_engine\_version](#input\_db\_engine\_version) | PostgreSQL major version (16, 17 or 18). | `string` | `"17"` | no |
| <a name="input_db_instance_class"></a> [db\_instance\_class](#input\_db\_instance\_class) | RDS instance class. | `string` | `"db.t4g.medium"` | no |
| <a name="input_db_max_allocated_storage"></a> [db\_max\_allocated\_storage](#input\_db\_max\_allocated\_storage) | Upper limit in GiB for RDS storage autoscaling; 0 disables it. | `number` | `200` | no |
| <a name="input_db_max_open_conns"></a> [db\_max\_open\_conns](#input\_db\_max\_open\_conns) | Maximum open database connections per pod (chart database.maxOpenConns). Size it so replicas x this value stays below the RDS max\_connections. The chart requires 0 (unlimited) or at least 4 because the storage tier mover pins connections. | `number` | `25` | no |
| <a name="input_db_monitoring_interval"></a> [db\_monitoring\_interval](#input\_db\_monitoring\_interval) | Seconds between Enhanced Monitoring samples (0 disables it). | `number` | `0` | no |
| <a name="input_db_multi_az"></a> [db\_multi\_az](#input\_db\_multi\_az) | Deploy a synchronous standby in a second Availability Zone. | `bool` | `true` | no |
| <a name="input_db_performance_insights_enabled"></a> [db\_performance\_insights\_enabled](#input\_db\_performance\_insights\_enabled) | Enable Performance Insights (not supported on db.t4g.micro and db.t4g.small). | `bool` | `true` | no |
| <a name="input_db_skip_final_snapshot"></a> [db\_skip\_final\_snapshot](#input\_db\_skip\_final\_snapshot) | Skip the final DB snapshot on destroy. Keep false in production. | `bool` | `false` | no |
| <a name="input_db_sslmode"></a> [db\_sslmode](#input\_db\_sslmode) | PostgreSQL SSL mode (DB\_SSLMODE). "require" encrypts the connection (rds.force\_ssl is on) without verifying the server. "verify-full" also needs the RDS CA bundle inside the pod, which the shell-less image does not ship: mount it through extra\_values (extraVolumes and the PGSSLROOTCERT/sslrootcert setting) before choosing it. | `string` | `"require"` | no |
| <a name="input_enable_metrics_token"></a> [enable\_metrics\_token](#input\_enable\_metrics\_token) | Expose /metrics, protected by a bearer token (chart metrics.enabled, METRICS\_AUTH\_TOKEN) that is generated and stored in Secrets Manager. | `bool` | `true` | no |
| <a name="input_existing_bootstrap_secret_name"></a> [existing\_bootstrap\_secret\_name](#input\_existing\_bootstrap\_secret\_name) | secret\_delivery = existing: name of the Kubernetes Secret with the keys admin-password and, with bootstrap\_admin\_token\_enabled, admin-token. Required when bootstrap\_admin\_password\_enabled is true. | `string` | `null` | no |
| <a name="input_existing_db_secret_name"></a> [existing\_db\_secret\_name](#input\_existing\_db\_secret\_name) | secret\_delivery = existing: name of the Kubernetes Secret holding the database password under the key "password" (copy it from the RDS-managed secret, database\_master\_secret\_arn output). | `string` | `null` | no |
| <a name="input_existing_secret_arns"></a> [existing\_secret\_arns](#input\_existing\_secret\_arns) | Bring-your-own Secrets Manager secrets (same shape as modules/secrets): every attribute that is set is used as-is and no secret is generated for it. The value must be the plain string the setting expects, not JSON. Ignored when secret\_delivery is existing. | <pre>object({<br/>    secret_key               = optional(string)<br/>    hmac_key                 = optional(string)<br/>    metrics_token            = optional(string)<br/>    bootstrap_admin_password = optional(string)<br/>    bootstrap_admin_token    = optional(string)<br/>  })</pre> | `{}` | no |
| <a name="input_existing_secret_name"></a> [existing\_secret\_name](#input\_existing\_secret\_name) | secret\_delivery = existing: name of the Kubernetes Secret (in the release namespace) loaded with envFrom, with the keys AUTH\_HMAC\_KEY, OPENARTIFACT\_SECRET\_KEY and, with enable\_metrics\_token, METRICS\_AUTH\_TOKEN. | `string` | `null` | no |
| <a name="input_extra_values"></a> [extra\_values](#input\_extra\_values) | Additional Helm values documents (YAML strings), merged after the values this module generates (later documents win, maps are merged deeply). Use it for chart options the module does not expose. NEVER put secret material here: it is stored in Terraform state. | `list(string)` | `[]` | no |
| <a name="input_helm_timeout_seconds"></a> [helm\_timeout\_seconds](#input\_helm\_timeout\_seconds) | Seconds the Helm release waits for the Deployments to become ready (the release is atomic: it rolls back on failure). | `number` | `600` | no |
| <a name="input_iam_role_permissions_boundary_arn"></a> [iam\_role\_permissions\_boundary\_arn](#input\_iam\_role\_permissions\_boundary\_arn) | ARN of an IAM permissions boundary policy for the Pod Identity role. null attaches none. | `string` | `null` | no |
| <a name="input_image_digest"></a> [image\_digest](#input\_image\_digest) | Container image digest (sha256:<64 hex>). When set it wins over image\_tag and pins the exact image. | `string` | `null` | no |
| <a name="input_image_tag"></a> [image\_tag](#input\_image\_tag) | Container image tag. null uses the chart's appVersion (0.19.2 for chart 0.16.2). Ignored when image\_digest is set. | `string` | `null` | no |
| <a name="input_ingress"></a> [ingress](#input\_ingress) | Exposure through the AWS Load Balancer Controller (an ALB, target-type ip). Disabled by default: the Service is then ClusterIP only.<br/>- enabled: render the chart Ingress.<br/>- class\_name: ingressClassName of the controller (default alb).<br/>- host: public host name (required when enabled).<br/>- certificate\_arn: ACM certificate ARN for the HTTPS listener (required when enabled).<br/>- scheme: internet-facing or internal.<br/>- group\_name: share one ALB between Ingresses (alb.ingress.kubernetes.io/group.name).<br/>- wafv2\_acl\_arn: WAFv2 web ACL to attach.<br/>- subnets: subnet IDs or names for the ALB; empty uses the controller's tag-based discovery.<br/>- ssl\_policy: ELB security policy, TLS 1.3 variants only.<br/>- idle\_timeout\_seconds: ALB idle timeout; keep it high for large uploads.<br/>- deletion\_protection: ALB deletion protection.<br/>- annotations: extra annotations merged last (they win over the generated ones). | <pre>object({<br/>    enabled              = optional(bool, false)<br/>    class_name           = optional(string, "alb")<br/>    host                 = optional(string)<br/>    certificate_arn      = optional(string)<br/>    scheme               = optional(string, "internet-facing")<br/>    group_name           = optional(string)<br/>    wafv2_acl_arn        = optional(string)<br/>    subnets              = optional(list(string), [])<br/>    ssl_policy           = optional(string, "ELBSecurityPolicy-TLS13-1-2-2021-06")<br/>    idle_timeout_seconds = optional(number, 300)<br/>    deletion_protection  = optional(bool, true)<br/>    annotations          = optional(map(string), {})<br/>  })</pre> | `{}` | no |
| <a name="input_name"></a> [name](#input\_name) | Name prefix for the AWS resources this module creates (S3 bucket, KMS aliases, RDS instance, IAM role, Secrets Manager secrets). Lowercase letters, digits and hyphens, 3-24 characters. | `string` | `"openartifact"` | no |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | Kubernetes namespace of the release, of the Pod Identity association, of the ExternalSecrets and of the secrets this module writes. | `string` | `"openartifact"` | no |
| <a name="input_namespace_labels"></a> [namespace\_labels](#input\_namespace\_labels) | Labels of the namespace created by this module. The default enforces the Pod Security Standard "restricted", which the chart's pods satisfy (non-root uid 10001, read-only root filesystem, all capabilities dropped, RuntimeDefault seccomp). Ignored when create\_namespace is false. | `map(string)` | <pre>{<br/>  "pod-security.kubernetes.io/enforce": "restricted"<br/>}</pre> | no |
| <a name="input_pod_annotations"></a> [pod\_annotations](#input\_pod\_annotations) | Extra annotations of the OpenArtifact pods, for example to opt in to a secret-reload controller. | `map(string)` | `{}` | no |
| <a name="input_pod_disruption_budget_enabled"></a> [pod\_disruption\_budget\_enabled](#input\_pod\_disruption\_budget\_enabled) | Create a PodDisruptionBudget (maxUnavailable 1) for the web Deployment. The chart only renders it when more than one replica can run. | `bool` | `true` | no |
| <a name="input_refresh_interval"></a> [refresh\_interval](#input\_refresh\_interval) | How often the External Secrets Operator re-reads Secrets Manager (Go duration, for example 1h). RDS rotates the database password about every 7 days; the pods only read it at start, see the README. | `string` | `"1h"` | no |
| <a name="input_release_name"></a> [release\_name](#input\_release\_name) | Helm release name. It is also the Kubernetes service account name (serviceAccount.name) that the EKS Pod Identity association binds to the IAM role. | `string` | `"openartifact"` | no |
| <a name="input_replica_count"></a> [replica\_count](#input\_replica\_count) | Replicas of the web Deployment (the whole server when worker\_enabled is false). More than one is fine: blobs live in S3 and the state in PostgreSQL. Ignored while autoscaling.enabled is true. | `number` | `2` | no |
| <a name="input_resources"></a> [resources](#input\_resources) | Container resources of the web and worker pods (requests and limits). Only the CPU limit is optional: leaving it unset avoids CPU throttling. /tmp spooling uses node ephemeral storage (see tmp\_size\_limit), not memory. | <pre>object({<br/>    requests = object({<br/>      cpu    = string<br/>      memory = string<br/>    })<br/>    limits = object({<br/>      cpu    = optional(string)<br/>      memory = string<br/>    })<br/>  })</pre> | <pre>{<br/>  "limits": {<br/>    "memory": "2Gi"<br/>  },<br/>  "requests": {<br/>    "cpu": "500m",<br/>    "memory": "1Gi"<br/>  }<br/>}</pre> | no |
| <a name="input_s3_access_logging"></a> [s3\_access\_logging](#input\_s3\_access\_logging) | S3 server access logging to an existing bucket (target\_bucket, optional target\_prefix); null disables it. | <pre>object({<br/>    target_bucket = string<br/>    target_prefix = optional(string, "s3/")<br/>  })</pre> | `null` | no |
| <a name="input_s3_bucket_name"></a> [s3\_bucket\_name](#input\_s3\_bucket\_name) | Explicit S3 bucket name. null names it "<name>-blobs-<account\_id>-<region>". | `string` | `null` | no |
| <a name="input_s3_force_destroy"></a> [s3\_force\_destroy](#input\_s3\_force\_destroy) | Delete the bucket with all objects on destroy. Leave false: the bucket holds every stored artifact. | `bool` | `false` | no |
| <a name="input_s3_kms_mode"></a> [s3\_kms\_mode](#input\_s3\_kms\_mode) | Bucket encryption key: "cmk" (dedicated customer managed key, rotation on) or "aws\_managed" (aws/s3). | `string` | `"cmk"` | no |
| <a name="input_s3_noncurrent_version_expiration_days"></a> [s3\_noncurrent\_version\_expiration\_days](#input\_s3\_noncurrent\_version\_expiration\_days) | Days after which noncurrent object versions are deleted (needs s3\_versioning\_enabled). | `number` | `30` | no |
| <a name="input_s3_versioning_enabled"></a> [s3\_versioning\_enabled](#input\_s3\_versioning\_enabled) | Keep previous object versions. | `bool` | `true` | no |
| <a name="input_secret_data_revision"></a> [secret\_data\_revision](#input\_secret\_data\_revision) | secret\_delivery = terraform\_write\_only: revision counter of the Kubernetes Secrets (data\_wo\_revision). Write-only values cannot be compared, so Terraform only rewrites the Secrets when this number changes: bump it after the secrets or the RDS-managed database password changed. | `number` | `1` | no |
| <a name="input_secret_delivery"></a> [secret\_delivery](#input\_secret\_delivery) | How the application secrets reach the cluster. They are always generated into AWS Secrets Manager (ephemeral values, never in state) except in "existing".<br/>- external\_secrets: ExternalSecret objects (external-secrets.io/v1) sync Secrets Manager into Kubernetes Secrets. Values never touch Terraform state or the Terraform runner. Needs the External Secrets Operator, a (Cluster)SecretStore (secret\_store\_name) and the CRDs reachable at plan time.<br/>- terraform\_write\_only: Terraform reads the values with an ephemeral resource and writes the Kubernetes Secrets with write-only arguments (data\_wo). Values never enter state or plan, but pass through the Terraform runner, and nothing refreshes them: rotation (including the RDS-managed database password) needs secret\_data\_revision bumped.<br/>- existing: you create the Kubernetes Secrets (existing\_secret\_name, existing\_db\_secret\_name, existing\_bootstrap\_secret\_name); this module creates no Secrets Manager secrets. | `string` | `"external_secrets"` | no |
| <a name="input_secret_store_kind"></a> [secret\_store\_kind](#input\_secret\_store\_kind) | Kind of the store referenced by secret\_store\_name. | `string` | `"ClusterSecretStore"` | no |
| <a name="input_secret_store_name"></a> [secret\_store\_name](#input\_secret\_store\_name) | Name of the SecretStore or ClusterSecretStore (provider aws, service SecretsManager) the ExternalSecrets read from. Required when secret\_delivery is external\_secrets. Its identity (Pod Identity or IRSA) needs the policy in the external\_secrets\_policy\_json output. | `string` | `null` | no |
| <a name="input_secret_version"></a> [secret\_version](#input\_secret\_version) | Rotation counter of the generated metrics token, HMAC key and bootstrap secrets (see modules/secrets). It never touches OPENARTIFACT\_SECRET\_KEY: replacing that key makes every credential OpenArtifact stored permanently unreadable. | `number` | `1` | no |
| <a name="input_secrets_kms_key_arn"></a> [secrets\_kms\_key\_arn](#input\_secrets\_kms\_key\_arn) | Customer managed KMS key that encrypts the generated secrets. null uses the AWS managed aws/secretsmanager key. The identity that reads them (the External Secrets Operator or the Terraform runner) needs kms:Decrypt on a customer managed key. | `string` | `null` | no |
| <a name="input_secrets_recovery_window_in_days"></a> [secrets\_recovery\_window\_in\_days](#input\_secrets\_recovery\_window\_in\_days) | Days Secrets Manager keeps a deleted secret recoverable (7-30), or 0 to delete immediately. Keep the default: a deleted OPENARTIFACT\_SECRET\_KEY can only be restored inside this window. | `number` | `30` | no |
| <a name="input_shutdown_delay_seconds"></a> [shutdown\_delay\_seconds](#input\_shutdown\_delay\_seconds) | Seconds the server keeps serving after SIGTERM, with /ready answering 503, before it closes the listener (config.shutdownDelay). It covers the time the ALB and the Service need to stop routing to the terminating pod. | `number` | `15` | no |
| <a name="input_shutdown_timeout_seconds"></a> [shutdown\_timeout\_seconds](#input\_shutdown\_timeout\_seconds) | Seconds in-flight requests get to finish after the listener closes (config.shutdownTimeout, at least 1). | `number` | `60` | no |
| <a name="input_spread_across_zones"></a> [spread\_across\_zones](#input\_spread\_across\_zones) | Add a topology spread constraint (maxSkew 1, ScheduleAnyway) that spreads the pods over the availability zones, so one zone outage keeps the service up. | `bool` | `true` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to every AWS resource this module creates. | `map(string)` | `{}` | no |
| <a name="input_termination_grace_period_seconds"></a> [termination\_grace\_period\_seconds](#input\_termination\_grace\_period\_seconds) | terminationGracePeriodSeconds of the pods. null derives it as shutdown\_delay\_seconds + shutdown\_timeout\_seconds + 45 (the chart documents 25 seconds for background-job cancellation, audit and telemetry flush, plus headroom). An explicit value must be at least shutdown\_delay\_seconds + shutdown\_timeout\_seconds + 25. | `number` | `null` | no |
| <a name="input_tmp_size_limit"></a> [tmp\_size\_limit](#input\_tmp\_size\_limit) | Size limit (Kubernetes quantity, for example 50Gi) of the emptyDir mounted at /tmp, where large uploads and proxy downloads are spooled before they reach S3. It uses node ephemeral storage; a pod that exceeds it is evicted. | `string` | `"50Gi"` | no |
| <a name="input_trusted_proxy_cidrs"></a> [trusted\_proxy\_cidrs](#input\_trusted\_proxy\_cidrs) | CIDRs of the reverse proxies whose X-Forwarded-* headers OpenArtifact trusts (OPENARTIFACT\_TRUSTED\_PROXIES). null uses the CIDR of the VPC, which covers an ALB in target-type ip mode because it forwards from addresses in the VPC subnets. Narrow it to the ALB subnets when other workloads in the VPC can reach the pods. | `list(string)` | `null` | no |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | ID of the VPC of the cluster. The database security group is created in it and the VPC CIDR is the default for trusted\_proxy\_cidrs. | `string` | n/a | yes |
| <a name="input_worker_enabled"></a> [worker\_enabled](#input\_worker\_enabled) | Run the background workers (metadata regeneration, webhooks, scans, federation sync, schedulers) in a separate Deployment with OPENARTIFACT\_ROLE=worker; the main Deployment then runs role web. false runs everything in one Deployment (role all). | `bool` | `false` | no |
| <a name="input_worker_replica_count"></a> [worker\_replica\_count](#input\_worker\_replica\_count) | Replicas of the worker Deployment. Only used when worker\_enabled is true. | `number` | `1` | no |
| <a name="input_workload_security_group_ids"></a> [workload\_security\_group\_ids](#input\_workload\_security\_group\_ids) | IDs of the security groups the OpenArtifact pods egress from (the node security group, or the pod security groups when you use security groups for pods). Each one is allowed to reach the database on port 5432. | `list(string)` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_bucket_arn"></a> [bucket\_arn](#output\_bucket\_arn) | ARN of the S3 bucket that holds the artifact blobs. |
| <a name="output_bucket_name"></a> [bucket\_name](#output\_bucket\_name) | Name of the S3 bucket that holds the artifact blobs. |
| <a name="output_chart_version"></a> [chart\_version](#output\_chart\_version) | Version of the OpenArtifact Helm chart that was deployed. |
| <a name="output_database_endpoint"></a> [database\_endpoint](#output\_database\_endpoint) | DNS address of the RDS instance (host name only). |
| <a name="output_database_master_secret_arn"></a> [database\_master\_secret\_arn](#output\_database\_master\_secret\_arn) | ARN of the RDS-managed Secrets Manager secret with the master credentials as JSON {username, password}. RDS rotates it about every 7 days; the pods read the password only at start, so restart them after a rotation (see the README). |
| <a name="output_database_port"></a> [database\_port](#output\_database\_port) | Port of the RDS instance. |
| <a name="output_database_security_group_id"></a> [database\_security\_group\_id](#output\_database\_security\_group\_id) | ID of the database security group. Add further ingress rules only through aws\_vpc\_security\_group\_ingress\_rule. |
| <a name="output_external_secrets_policy_json"></a> [external\_secrets\_policy\_json](#output\_external\_secrets\_policy\_json) | IAM policy (JSON) that lets the External Secrets Operator's identity read the secrets listed above and the RDS-managed database secret, plus kms:Decrypt on their keys. Attach it to the role of the SecretStore. Not attached by this module. |
| <a name="output_kms_key_arns"></a> [kms\_key\_arns](#output\_kms\_key\_arns) | ARNs of the customer managed KMS keys by purpose: s3 (null with s3\_kms\_mode = aws\_managed) and database. |
| <a name="output_kubernetes_secret_names"></a> [kubernetes\_secret\_names](#output\_kubernetes\_secret\_names) | Names of the Kubernetes Secrets the chart reads: app (envFrom: OPENARTIFACT\_SECRET\_KEY, AUTH\_HMAC\_KEY, METRICS\_AUTH\_TOKEN), database (key password) and bootstrap (keys admin-password, admin-token; null when bootstrap\_admin\_password\_enabled is false). |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Kubernetes namespace of the release. |
| <a name="output_pod_identity_association_arn"></a> [pod\_identity\_association\_arn](#output\_pod\_identity\_association\_arn) | ARN of the EKS Pod Identity association. |
| <a name="output_pod_identity_role_arn"></a> [pod\_identity\_role\_arn](#output\_pod\_identity\_role\_arn) | ARN of the IAM role the pods assume through EKS Pod Identity (S3 blob storage and its KMS key only). |
| <a name="output_pod_identity_role_name"></a> [pod\_identity\_role\_name](#output\_pod\_identity\_role\_name) | Name of the IAM role the pods assume through EKS Pod Identity. |
| <a name="output_release_name"></a> [release\_name](#output\_release\_name) | Name of the Helm release. |
| <a name="output_secret_arns"></a> [secret\_arns](#output\_secret\_arns) | ARNs of the generated or bring-your-own Secrets Manager secrets by logical name (secret\_key, hmac\_key, metrics\_token, bootstrap\_admin\_password, bootstrap\_admin\_token; only the enabled ones). Empty when secret\_delivery is existing. |
| <a name="output_service_account_name"></a> [service\_account\_name](#output\_service\_account\_name) | Kubernetes service account the web and worker pods run as; the EKS Pod Identity association binds the IAM role to it. |
| <a name="output_url"></a> [url](#output\_url) | Public base URL (BASE\_URL) configured on the release: base\_url, else https://<ingress.host>; null when neither is set. The ALB host name is assigned by the AWS Load Balancer Controller: read it with kubectl get ingress -n <namespace>. |
<!-- END_TF_DOCS -->
