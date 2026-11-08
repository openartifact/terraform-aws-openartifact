# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: MPL-2.0

variable "region" {
  description = "AWS region to deploy into. The ACM certificate must be in the same region."
  type        = string
  default     = "eu-west-1"
  nullable    = false
}

variable "name" {
  description = "Name of the deployment and prefix of every resource (3-17 characters: lowercase letters, digits and hyphens)."
  type        = string
  default     = "openartifact"
  nullable    = false
}

variable "certificate_arn" {
  description = "ARN of the ACM certificate for the HTTPS listener, in the same region. It must cover the host name of base_url."
  type        = string
  nullable    = false
}

variable "allowed_ingress_cidrs" {
  description = "IPv4 CIDR blocks allowed to reach the ALB (before the WAF), for example your office, VPN and CI egress ranges. No default: decide who may reach your artifact repository."
  type        = list(string)
  nullable    = false
}

variable "base_url" {
  description = "Public URL of the repository, for example https://artifacts.example.com. Required for SSO, SAML and webhooks."
  type        = string
  nullable    = false
}

variable "image_digest" {
  description = "Image digest (sha256:<64 hex>) to pin the exact OpenArtifact image; wins over the default tag. Null deploys the module's default tag."
  type        = string
  default     = null
}

variable "waf_rate_limit" {
  description = "Maximum number of requests from one IP address within the 5-minute WAF window before it is blocked. Package managers are chatty and CI runners share NAT addresses, so size it for your busiest client."
  type        = number
  default     = 10000
  nullable    = false

  validation {
    condition     = var.waf_rate_limit >= 10 && var.waf_rate_limit <= 2000000000
    error_message = "waf_rate_limit must be between 10 and 2000000000."
  }
}

variable "log_retention_days" {
  description = "Retention in days of the CloudWatch log groups and of the objects in the access log buckets."
  type        = number
  default     = 90
  nullable    = false
}

variable "tags" {
  description = "Extra tags for every resource, merged into the provider default_tags."
  type        = map(string)
  default     = {}
  nullable    = false
}
