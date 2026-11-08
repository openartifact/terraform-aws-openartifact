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
  description = "ARN of the ACM certificate for the HTTPS listener, in the same region. It must cover the host name of base_url (or the ALB DNS name when base_url is null)."
  type        = string
  nullable    = false
}

variable "allowed_ingress_cidrs" {
  description = "IPv4 CIDR blocks allowed to reach the ALB, for example your office or VPN range. No default: decide who may reach your artifact repository."
  type        = list(string)
  nullable    = false
}

variable "base_url" {
  description = "Public URL of the repository, for example https://artifacts.example.com. Null falls back to the ALB DNS name."
  type        = string
  default     = null
}

variable "tags" {
  description = "Extra tags for every resource, merged into the provider default_tags."
  type        = map(string)
  default     = {}
  nullable    = false
}
