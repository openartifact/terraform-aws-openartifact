# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# Plan-only tests for the root module (ECS Fargate): the defaults a user gets with the minimum
# input must be the secure ones. No AWS access: the provider is mocked.
# Run: terraform test -filter=tests/root-secure-defaults.tftest.hcl   (or tofu test)

mock_provider "aws" {
  # OpenTofu fills computed attributes with mock values at plan time and the provider schema
  # validates some of them, so ARNs must look like ARNs.
  mock_resource "aws_kms_key" {
    defaults = {
      arn    = "arn:aws:kms:eu-west-1:123456789012:key/00000000-0000-0000-0000-000000000000"
      key_id = "00000000-0000-0000-0000-000000000000"
    }
  }

  mock_resource "aws_security_group" {
    defaults = {
      id  = "sg-0123456789abcdef0"
      arn = "arn:aws:ec2:eu-west-1:123456789012:security-group/sg-0123456789abcdef0"
    }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:eu-west-1:123456789012:log-group:/ecs/oa-test"
    }
  }

  mock_resource "aws_sfn_state_machine" {
    defaults = {
      arn = "arn:aws:states:eu-west-1:123456789012:stateMachine:oa-test-redeploy"
    }
  }

  mock_resource "aws_cloudwatch_event_rule" {
    defaults = {
      arn = "arn:aws:events:eu-west-1:123456789012:rule/oa-test-redeploy"
    }
  }

  mock_resource "aws_s3_bucket" {
    defaults = {
      arn    = "arn:aws:s3:::oa-test-blobs-123456789012-eu-west-1"
      region = "eu-west-1"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/oa-test"
    }
  }

  mock_resource "aws_secretsmanager_secret" {
    defaults = {
      arn = "arn:aws:secretsmanager:eu-west-1:123456789012:secret:oa-test/secret-AbCdEf"
    }
  }

  mock_resource "aws_db_instance" {
    defaults = {
      address = "oa-test.abcdefghijkl.eu-west-1.rds.amazonaws.com"
      master_user_secret = [{
        kms_key_id    = "00000000-0000-0000-0000-000000000000"
        secret_arn    = "arn:aws:secretsmanager:eu-west-1:123456789012:secret:rds!db-00000000-AbCdEf"
        secret_status = "active"
      }]
    }
  }

  mock_resource "aws_lb" {
    defaults = {
      arn        = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:loadbalancer/app/oa-test/0123456789abcdef"
      arn_suffix = "app/oa-test/0123456789abcdef"
      dns_name   = "oa-test-123456.eu-west-1.elb.amazonaws.com"
    }
  }

  mock_resource "aws_lb_listener" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:listener/app/oa-test/0123456789abcdef/0123456789abcdef"
    }
  }

  mock_resource "aws_lb_target_group" {
    defaults = {
      arn        = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:targetgroup/oa-test/0123456789abcdef"
      arn_suffix = "targetgroup/oa-test/0123456789abcdef"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/test"
      user_id    = "AIDATEST"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "eu-west-1"
    }
  }

  mock_data "aws_vpc" {
    defaults = {
      cidr_block = "10.0.0.0/16"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"s3:GetObject\",\"Resource\":\"arn:aws:s3:::bucket/*\"}]}"
    }
  }
}

variables {
  name                  = "oa-test"
  vpc_id                = "vpc-0123456789abcdef0"
  private_subnet_ids    = ["subnet-0aaaaaaaaaaaaaaa1", "subnet-0bbbbbbbbbbbbbbb2"]
  public_subnet_ids     = ["subnet-0ccccccccccccccc3", "subnet-0ddddddddddddddd4"]
  certificate_arn       = "arn:aws:acm:eu-west-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
  allowed_ingress_cidrs = ["203.0.113.0/24"]
}

run "alb_is_https_only_and_hardened" {
  command = plan

  assert {
    condition     = aws_lb.this.load_balancer_type == "application" && aws_lb.this.internal == false
    error_message = "The default is an internet-facing application load balancer."
  }

  assert {
    condition     = aws_lb.this.drop_invalid_header_fields == true
    error_message = "The ALB must drop invalid header fields."
  }

  assert {
    condition     = aws_lb.this.enable_deletion_protection == true
    error_message = "ALB deletion protection must default to true."
  }

  assert {
    condition     = aws_lb.this.idle_timeout == 300
    error_message = "The ALB idle timeout must default to 300 seconds."
  }

  assert {
    condition     = length(aws_lb.this.access_logs) == 0
    error_message = "Access logs must be off unless a bucket is given."
  }

  assert {
    condition     = toset(aws_lb.this.subnets) == toset(var.public_subnet_ids)
    error_message = "An internet-facing ALB must be placed in the public subnets."
  }

  assert {
    condition     = aws_lb_listener.https.port == 443 && aws_lb_listener.https.protocol == "HTTPS"
    error_message = "The main listener must be HTTPS on 443."
  }

  assert {
    condition     = aws_lb_listener.https.ssl_policy == "ELBSecurityPolicy-TLS13-1-2-2021-06"
    error_message = "The HTTPS listener must use a TLS 1.3 security policy by default."
  }

  assert {
    condition     = aws_lb_listener.https.certificate_arn == var.certificate_arn
    error_message = "The HTTPS listener must serve the given certificate."
  }

  assert {
    condition     = aws_lb_listener.http_redirect.port == 80 && aws_lb_listener.http_redirect.protocol == "HTTP"
    error_message = "Port 80 must have a listener, only to redirect."
  }

  assert {
    condition = (
      length(aws_lb_listener.http_redirect.default_action) == 1
      && aws_lb_listener.http_redirect.default_action[0].type == "redirect"
      && aws_lb_listener.http_redirect.default_action[0].redirect[0].protocol == "HTTPS"
      && aws_lb_listener.http_redirect.default_action[0].redirect[0].port == "443"
      && aws_lb_listener.http_redirect.default_action[0].redirect[0].status_code == "HTTP_301"
    )
    error_message = "The HTTP listener must permanently redirect (HTTP_301) to HTTPS on 443 and never forward."
  }

  assert {
    condition     = length(aws_wafv2_web_acl_association.this) == 0 && length(aws_lb_listener_certificate.additional) == 0
    error_message = "No WAF association or additional certificates by default."
  }
}

run "target_group_and_security_groups" {
  command = plan

  assert {
    condition     = aws_lb_target_group.web.target_type == "ip" && aws_lb_target_group.web.port == 8080 && aws_lb_target_group.web.protocol == "HTTP"
    error_message = "The target group must register task IPs on port 8080."
  }

  assert {
    condition     = aws_lb_target_group.web.health_check[0].path == "/ready" && aws_lb_target_group.web.health_check[0].matcher == "200"
    error_message = "The ALB health check must call /ready and expect 200."
  }

  assert {
    condition     = aws_lb_target_group.web.stickiness[0].enabled == false
    error_message = "Session stickiness must be off."
  }

  assert {
    condition     = aws_lb_target_group.web.deregistration_delay == "75"
    error_message = "The deregistration delay must default to shutdown delay + shutdown timeout (15 + 60)."
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.https_ipv4) == 1 && length(aws_vpc_security_group_ingress_rule.http_redirect_ipv4) == 1
    error_message = "One 443 and one 80 ingress rule per allowed CIDR."
  }

  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.https_ipv4[0].cidr_ipv4 == "203.0.113.0/24"
      && aws_vpc_security_group_ingress_rule.https_ipv4[0].from_port == 443
      && aws_vpc_security_group_ingress_rule.https_ipv4[0].to_port == 443
      && aws_vpc_security_group_ingress_rule.http_redirect_ipv4[0].cidr_ipv4 == "203.0.113.0/24"
      && aws_vpc_security_group_ingress_rule.http_redirect_ipv4[0].from_port == 80
    )
    error_message = "The ALB ingress rules must allow only the given CIDR on 443 and 80."
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.https_ipv6) == 0 && length(aws_vpc_security_group_ingress_rule.http_redirect_ipv6) == 0
    error_message = "No IPv6 ingress rules unless allowed_ingress_ipv6_cidrs is set."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.to_web.from_port == 8080 && aws_vpc_security_group_egress_rule.to_web.to_port == 8080 && aws_vpc_security_group_egress_rule.to_web.ip_protocol == "tcp"
    error_message = "The ALB may only egress to the web tasks on port 8080."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.to_web.cidr_ipv4 == null && aws_vpc_security_group_egress_rule.to_web.cidr_ipv6 == null
    error_message = "The ALB egress rule must reference the web security group, not a CIDR."
  }
}

# Terraform leaves the computed attributes of mocked resources unknown during plan (OpenTofu fills
# them in), and the container definitions embed the database endpoint, so the rest of this file
# applies against the mocked provider. Nothing touches AWS.
run "container_is_hardened_and_has_no_static_credentials" {
  command = apply

  assert {
    condition     = jsondecode(module.web.container_definitions)[0].readonlyRootFilesystem == true
    error_message = "The container root filesystem must be read-only."
  }

  assert {
    condition     = jsondecode(module.web.container_definitions)[0].user == "10001:10001" && jsondecode(module.web.container_definitions)[0].privileged == false
    error_message = "The container must run as 10001:10001 and not privileged."
  }

  assert {
    condition = !anytrue([
      for e in jsondecode(module.web.container_definitions)[0].environment :
      contains(["STORAGE_ACCESS_KEY", "STORAGE_SECRET_KEY", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN"], e.name)
    ])
    error_message = "No static AWS credentials may be passed to the container."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(module.web.container_definitions)[0].secrets : startswith(s.valueFrom, "arn:aws:secretsmanager:")
    ])
    error_message = "Every secret must be injected with valueFrom pointing at Secrets Manager."
  }

  assert {
    condition = (
      contains([for s in jsondecode(module.web.container_definitions)[0].secrets : s.name], "DB_PASSWORD")
      && contains([for s in jsondecode(module.web.container_definitions)[0].secrets : s.name], "OPENARTIFACT_SECRET_KEY")
      && contains([for s in jsondecode(module.web.container_definitions)[0].secrets : s.name], "AUTH_HMAC_KEY")
    )
    error_message = "DB_PASSWORD, OPENARTIFACT_SECRET_KEY and AUTH_HMAC_KEY must come from Secrets Manager."
  }

  assert {
    condition = alltrue([
      for e in jsondecode(module.web.container_definitions)[0].environment :
      !contains(["DB_PASSWORD", "OPENARTIFACT_SECRET_KEY", "AUTH_HMAC_KEY", "METRICS_AUTH_TOKEN", "OPENARTIFACT_BOOTSTRAP_ADMIN_PASSWORD"], e.name)
    ])
    error_message = "Secret values must never be plain environment variables."
  }
}

run "database_is_private_and_encrypted" {
  command = apply

  assert {
    condition     = module.secrets.secret_key_arn != null && module.secrets.hmac_key_arn != null
    error_message = "The application secrets must be created by default."
  }

  assert {
    condition     = module.secrets.metrics_token_arn != null && module.secrets.bootstrap_admin_password_arn != null && module.secrets.bootstrap_admin_token_arn == null
    error_message = "The metrics token and bootstrap admin password are on by default; the admin token is unsupported on ECS."
  }

  assert {
    condition     = module.database.kms_key_arn != null && module.database.master_user_secret_arn != null
    error_message = "The database must use a customer-managed KMS key and an RDS-managed master secret."
  }

  assert {
    condition     = module.storage.kms_key_arn != null
    error_message = "The blob bucket must use a customer-managed KMS key by default."
  }

  assert {
    condition     = output.kms_key_arns.storage != null && output.kms_key_arns.database != null
    error_message = "The kms_key_arns output must list the storage and database keys."
  }
}

# The root passes only the defaults of the storage and database variables through; these runs
# check the settings behind them with the variables the root passes, from the module's own
# resources (the root cannot address resources inside a module).

run "bucket_is_private_and_kms_encrypted" {
  command = plan

  module {
    source = "./modules/storage"
  }

  variables {
    name = "oa-test"
  }

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.this.block_public_acls,
      aws_s3_bucket_public_access_block.this.block_public_policy,
      aws_s3_bucket_public_access_block.this.ignore_public_acls,
      aws_s3_bucket_public_access_block.this.restrict_public_buckets,
    ])
    error_message = "All four public access block settings must be true."
  }

  assert {
    condition = (
      one(aws_s3_bucket_server_side_encryption_configuration.this.rule).apply_server_side_encryption_by_default[0].sse_algorithm == "aws:kms"
      && length(aws_kms_key.blobs) == 1
    )
    error_message = "The bucket must be encrypted with a customer-managed KMS key."
  }

  assert {
    condition     = aws_s3_bucket.this.force_destroy == false
    error_message = "The root must not force-destroy the bucket by default."
  }
}

run "rds_is_encrypted_protected_and_password_managed" {
  command = plan

  module {
    source = "./modules/database"
  }

  variables {
    name       = "oa-test"
    vpc_id     = "vpc-0123456789abcdef0"
    subnet_ids = ["subnet-0aaaaaaaaaaaaaaa1", "subnet-0bbbbbbbbbbbbbbb2"]
  }

  assert {
    condition     = aws_db_instance.this.storage_encrypted == true && aws_db_instance.this.publicly_accessible == false
    error_message = "RDS must be encrypted and not publicly accessible."
  }

  assert {
    condition     = aws_db_instance.this.deletion_protection == true && aws_db_instance.this.skip_final_snapshot == false
    error_message = "RDS must keep deletion protection and a final snapshot by default."
  }

  assert {
    condition     = aws_db_instance.this.manage_master_user_password == true && aws_db_instance.this.password == null
    error_message = "The master password must be managed by RDS, never set in configuration."
  }
}
