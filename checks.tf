# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# Non-fatal checks: they surface warnings in plan and apply but never block them.

check "base_url_is_https" {
  assert {
    condition     = var.base_url == null || startswith(var.base_url, "https://")
    error_message = "base_url should use https://: the ALB only serves HTTPS (HTTP is redirected), so an http:// base URL makes generated links and SSO redirects point at the redirect."
  }
}

check "ingress_not_open_to_the_internet" {
  assert {
    condition     = !contains(var.allowed_ingress_cidrs, "0.0.0.0/0") && !contains(var.allowed_ingress_ipv6_cidrs, "::/0")
    error_message = "allowed_ingress_cidrs or allowed_ingress_ipv6_cidrs opens the ALB to the whole internet. That is only appropriate for a public repository; otherwise list your office, VPN and CI egress ranges."
  }
}

check "internal_alb_ignores_public_subnets" {
  assert {
    condition     = !var.internal || length(var.public_subnet_ids) == 0
    error_message = "internal is true, so the ALB is placed in private_subnet_ids and public_subnet_ids is ignored."
  }
}

check "trusted_proxies_not_open" {
  assert {
    condition     = var.trusted_proxy_cidrs == null || !contains(coalesce(var.trusted_proxy_cidrs, []), "0.0.0.0/0")
    error_message = "trusted_proxy_cidrs contains 0.0.0.0/0: every client could then spoof X-Forwarded-For and X-Forwarded-Host. Trust only the ALB subnets or the VPC CIDR."
  }
}

check "worker_autoscaling_needs_worker" {
  assert {
    condition     = var.worker_enabled || !var.worker_autoscaling.enabled
    error_message = "worker_autoscaling.enabled has no effect while worker_enabled is false."
  }
}
