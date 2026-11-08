# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: MPL-2.0

# Non-fatal checks: they surface warnings in plan and apply but never block them.

check "base_url_is_https" {
  assert {
    condition     = startswith(var.base_url == null ? "https://" : var.base_url, "https://")
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

check "ec2_instance_types_match_cpu_architecture" {
  assert {
    # Graviton families end their generation digit(s) with g (m7g, c6gd, t4g, m8g, r7gn) plus a1.
    condition = !local.ec2 || var.ec2_capacity.instance_types == null || alltrue([
      for t in coalesce(var.ec2_capacity.instance_types, []) :
      can(regex("^([a-z]+[0-9]+(g|gd|gn|gen)|a1)\\.", t)) == (var.cpu_architecture == "ARM64")
    ])
    error_message = "ec2_capacity.instance_types contains an instance type of the wrong CPU architecture for cpu_architecture: tasks and AMI are ${var.cpu_architecture}, and ECS cannot place them on the other architecture (Graviton families end in g, such as m7g)."
  }
}

check "ephemeral_storage_is_fargate_only" {
  assert {
    condition     = !local.ec2 || var.ephemeral_storage_gib == 50 # the default of ephemeral_storage_gib
    error_message = "ephemeral_storage_gib has no effect with capacity_type EC2: /tmp lives on the instance disk, sized by ec2_capacity.root_volume_size_gib."
  }
}
