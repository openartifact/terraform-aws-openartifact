<!--
SPDX-FileCopyrightText: The OpenArtifact Authors

SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Example: OpenArtifact on an existing EKS cluster

Deploys OpenArtifact with the official Helm chart onto an **existing** EKS
cluster, using [`modules/eks`](../../modules/eks): S3 blob storage, RDS
PostgreSQL, generated secrets in Secrets Manager (delivered by the External
Secrets Operator) and EKS Pod Identity for the pods' AWS access.

## Prerequisites

- An EKS cluster (Kubernetes 1.29 or newer) whose API is reachable from where
  you run Terraform: the kubernetes provider connects at plan time. The AWS CLI
  must be installed (it provides `aws eks get-token`), and your identity needs
  Kubernetes permissions on the cluster (an EKS access entry).
- The EKS Pod Identity agent add-on (not needed on EKS Auto Mode).
- The AWS Load Balancer Controller.
- The External Secrets Operator with a ClusterSecretStore for AWS Secrets
  Manager. Attach the output `external_secrets_policy_json` to the role the
  store uses.
- An ACM certificate for the host name, in the cluster's region.

## Use

```sh
cp terraform.tfvars.example terraform.tfvars   # edit the values
terraform init
terraform plan
terraform apply
```

Then read the load balancer address with `kubectl get ingress -n openartifact`
and create a DNS record for `ingress_host` pointing at it. The first login uses
the initial admin password from the output `bootstrap_admin_password_secret_arn`;
change it right away.

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

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_openartifact"></a> [openartifact](#module\_openartifact) | ../../modules/eks | n/a |

## Resources

| Name | Type |
| ---- | ---- |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_allowed_ingress_cidrs"></a> [allowed\_ingress\_cidrs](#input\_allowed\_ingress\_cidrs) | IPv4 CIDR blocks allowed to reach the ALB, for example your office or VPN range. No default: decide who may reach your artifact repository. | `list(string)` | n/a | yes |
| <a name="input_certificate_arn"></a> [certificate\_arn](#input\_certificate\_arn) | ARN of the ACM certificate for the HTTPS listener, in the same region. It must cover ingress\_host. | `string` | n/a | yes |
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | Name of the existing EKS cluster to deploy onto. | `string` | n/a | yes |
| <a name="input_database_subnet_ids"></a> [database\_subnet\_ids](#input\_database\_subnet\_ids) | Private subnet IDs in at least two Availability Zones for the RDS instance, in the cluster's VPC. | `list(string)` | n/a | yes |
| <a name="input_ingress_host"></a> [ingress\_host](#input\_ingress\_host) | Public host name of the repository, for example artifacts.example.com. Point a DNS record at the ALB created by the AWS Load Balancer Controller. | `string` | n/a | yes |
| <a name="input_name"></a> [name](#input\_name) | Name of the deployment and prefix of the AWS resources (3-24 characters: lowercase letters, digits and hyphens). | `string` | `"openartifact"` | no |
| <a name="input_region"></a> [region](#input\_region) | AWS region of the cluster. The ACM certificate must be in the same region. | `string` | `"eu-west-1"` | no |
| <a name="input_secret_store_name"></a> [secret\_store\_name](#input\_secret\_store\_name) | Name of the External Secrets Operator ClusterSecretStore for AWS Secrets Manager. Its identity needs the policy in the external\_secrets\_policy\_json output. | `string` | `"aws-secretsmanager"` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Extra tags for every AWS resource, merged into the provider default\_tags. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_bootstrap_admin_password_secret_arn"></a> [bootstrap\_admin\_password\_secret\_arn](#output\_bootstrap\_admin\_password\_secret\_arn) | Secret holding the initial admin password: aws secretsmanager get-secret-value --secret-id <arn> --query SecretString --output text. Used only on an empty instance; change it after the first login. |
| <a name="output_bucket_name"></a> [bucket\_name](#output\_bucket\_name) | S3 bucket with the artifact blobs. |
| <a name="output_external_secrets_policy_json"></a> [external\_secrets\_policy\_json](#output\_external\_secrets\_policy\_json) | IAM policy for the identity of the External Secrets Operator's ClusterSecretStore: it lets the operator read the OpenArtifact secrets. Attach it to the operator's role (not done by this example). |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Kubernetes namespace of the release. |
| <a name="output_pod_identity_role_arn"></a> [pod\_identity\_role\_arn](#output\_pod\_identity\_role\_arn) | IAM role the pods assume through EKS Pod Identity. |
| <a name="output_url"></a> [url](#output\_url) | URL of the repository (https://<ingress\_host>). The host name must point at the ALB: kubectl get ingress -n <namespace>. |
<!-- END_TF_DOCS -->
