# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# ---------------------------------------------------------------------------
# Application Load Balancer
# ---------------------------------------------------------------------------

#trivy:ignore:AVD-AWS-0053 An internet-facing ALB is the default deployment shape; internal = true creates an internal one and allowed_ingress_cidrs (no default) restricts who can reach it.
resource "aws_lb" "this" {
  #checkov:skip=CKV2_AWS_28: A WAFv2 web ACL is attached through waf_acl_arn; creating one is left to the caller because rules are workload specific (see examples/complete).
  #checkov:skip=CKV2_AWS_76: The WebACL, and so its managed rule groups (AWSManagedRulesKnownBadInputsRuleSet covers Log4j), is owned by the caller; examples/complete attaches one that includes it.
  #checkov:skip=CKV_AWS_91: Access logs need a caller-owned bucket with the log delivery policy; enable them with alb_access_logs_bucket (see examples/complete).
  name               = var.name
  load_balancer_type = "application"
  internal           = var.internal
  security_groups    = [aws_security_group.alb.id]
  subnets            = local.alb_subnet_ids
  ip_address_type    = length(var.allowed_ingress_ipv6_cidrs) > 0 ? "dualstack" : "ipv4"

  idle_timeout               = var.alb_idle_timeout
  enable_deletion_protection = var.alb_deletion_protection
  drop_invalid_header_fields = true
  enable_http2               = true

  dynamic "access_logs" {
    for_each = var.alb_access_logs_bucket != null ? [var.alb_access_logs_bucket] : []

    content {
      enabled = true
      bucket  = access_logs.value.bucket
      prefix  = access_logs.value.prefix
    }
  }

  tags = merge(var.tags, { Name = var.name })
}

resource "aws_lb_target_group" "web" {
  name_prefix = substr(var.name, 0, 6)
  vpc_id      = var.vpc_id
  target_type = "ip"
  protocol    = "HTTP"
  port        = local.container_port

  # Seconds a deregistering task keeps serving in-flight requests; matches the server's
  # SERVER_SHUTDOWN_DELAY + SERVER_SHUTDOWN_TIMEOUT.
  deregistration_delay = tostring(local.deregistration_delay)

  # Downloads have very different sizes: send the next request to the task with the fewest in flight.
  load_balancing_algorithm_type = "least_outstanding_requests"

  health_check {
    enabled             = true
    path                = "/ready"
    matcher             = "200"
    protocol            = "HTTP"
    port                = "traffic-port"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  # The server is stateless; no session affinity.
  stickiness {
    enabled = false
    type    = "lb_cookie"
  }

  tags = merge(var.tags, { Name = "${var.name}-web" })

  # A target group cannot be replaced in place while a listener uses it.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = var.ssl_policy
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }

  tags = merge(var.tags, { Name = "${var.name}-https" })
}

resource "aws_lb_listener_certificate" "additional" {
  count = length(var.additional_certificate_arns)

  listener_arn    = aws_lb_listener.https.arn
  certificate_arn = var.additional_certificate_arns[count.index]
}

# Plain HTTP only redirects, permanently, to HTTPS on the same host and path.
resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  tags = merge(var.tags, { Name = "${var.name}-http-redirect" })
}

resource "aws_wafv2_web_acl_association" "this" {
  # waf_acl_enabled is a plain bool so the count stays known when the web ACL is created in the same
  # configuration and its ARN is not.
  count = var.waf_acl_enabled == null ? (var.waf_acl_arn != null ? 1 : 0) : (var.waf_acl_enabled ? 1 : 0)

  resource_arn = aws_lb.this.arn
  web_acl_arn  = var.waf_acl_arn
}

# ---------------------------------------------------------------------------
# ALB security group
# ---------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name_prefix = "${var.name}-alb-"
  description = "OpenArtifact ${var.name} load balancer"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-alb" })

  lifecycle {
    create_before_destroy = true
  }
}

#trivy:ignore:AVD-AWS-0107 The CIDRs come from allowed_ingress_cidrs, which has no default; 0.0.0.0/0 is possible only when the caller lists it explicitly (a check block warns).
resource "aws_vpc_security_group_ingress_rule" "https_ipv4" {
  #checkov:skip=CKV_AWS_260: Port 443 from the CIDRs the caller lists in allowed_ingress_cidrs (no default); 0.0.0.0/0 only when listed explicitly.
  count = length(var.allowed_ingress_cidrs)

  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = var.allowed_ingress_cidrs[count.index]
  description       = "HTTPS from allowed clients"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443

  tags = merge(var.tags, { Name = "${var.name}-alb-https-ipv4-${count.index}" })
}

#trivy:ignore:AVD-AWS-0107 The CIDRs come from allowed_ingress_cidrs, which has no default; 0.0.0.0/0 is possible only when the caller lists it explicitly (a check block warns).
resource "aws_vpc_security_group_ingress_rule" "http_redirect_ipv4" {
  #checkov:skip=CKV_AWS_260: Port 80 only serves the permanent redirect to HTTPS, from the same caller-listed CIDRs as 443.
  count = length(var.allowed_ingress_cidrs)

  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = var.allowed_ingress_cidrs[count.index]
  description       = "HTTP redirect to HTTPS from allowed clients"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80

  tags = merge(var.tags, { Name = "${var.name}-alb-http-ipv4-${count.index}" })
}

resource "aws_vpc_security_group_ingress_rule" "https_ipv6" {
  count = length(var.allowed_ingress_ipv6_cidrs)

  security_group_id = aws_security_group.alb.id
  cidr_ipv6         = var.allowed_ingress_ipv6_cidrs[count.index]
  description       = "HTTPS from allowed clients"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443

  tags = merge(var.tags, { Name = "${var.name}-alb-https-ipv6-${count.index}" })
}

resource "aws_vpc_security_group_ingress_rule" "http_redirect_ipv6" {
  count = length(var.allowed_ingress_ipv6_cidrs)

  security_group_id = aws_security_group.alb.id
  cidr_ipv6         = var.allowed_ingress_ipv6_cidrs[count.index]
  description       = "HTTP redirect to HTTPS from allowed clients"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80

  tags = merge(var.tags, { Name = "${var.name}-alb-http-ipv6-${count.index}" })
}

# The ALB talks only to the web tasks, on the container port.
resource "aws_vpc_security_group_egress_rule" "to_web" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = module.web.security_group_id
  description                  = "To the OpenArtifact web tasks"
  ip_protocol                  = "tcp"
  from_port                    = local.container_port
  to_port                      = local.container_port

  tags = merge(var.tags, { Name = "${var.name}-alb-to-web" })
}
