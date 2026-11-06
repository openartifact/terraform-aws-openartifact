# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

variable "region" {
  description = "AWS region of the cluster. The ACM certificate must be in the same region."
  type        = string
  default     = "eu-west-1"
  nullable    = false
}

variable "cluster_name" {
  description = "Name of the existing EKS cluster to deploy onto."
  type        = string
  nullable    = false
}

variable "name" {
  description = "Name of the deployment and prefix of the AWS resources (3-24 characters: lowercase letters, digits and hyphens)."
  type        = string
  default     = "openartifact"
  nullable    = false
}

variable "database_subnet_ids" {
  description = "Private subnet IDs in at least two Availability Zones for the RDS instance, in the cluster's VPC."
  type        = list(string)
  nullable    = false
}

variable "allowed_ingress_cidrs" {
  description = "IPv4 CIDR blocks allowed to reach the ALB, for example your office or VPN range. No default: decide who may reach your artifact repository."
  type        = list(string)
  nullable    = false
}

variable "ingress_host" {
  description = "Public host name of the repository, for example artifacts.example.com. Point a DNS record at the ALB created by the AWS Load Balancer Controller."
  type        = string
  nullable    = false
}

variable "certificate_arn" {
  description = "ARN of the ACM certificate for the HTTPS listener, in the same region. It must cover ingress_host."
  type        = string
  nullable    = false
}

variable "secret_store_name" {
  description = "Name of the External Secrets Operator ClusterSecretStore for AWS Secrets Manager. Its identity needs the policy in the external_secrets_policy_json output."
  type        = string
  default     = "aws-secretsmanager"
  nullable    = false
}

variable "tags" {
  description = "Extra tags for every AWS resource, merged into the provider default_tags."
  type        = map(string)
  default     = {}
  nullable    = false
}
