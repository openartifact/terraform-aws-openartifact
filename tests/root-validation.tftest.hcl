# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# Input validation of the root module: invalid values must be rejected at plan time, valid edge
# cases must be accepted. Plan-only, no AWS access: the provider is mocked.
# Run: terraform test -filter=tests/root-validation.tftest.hcl   (or tofu test)

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

run "rejects_malformed_image_digest" {
  command = plan

  variables {
    image_digest = "sha256:not-a-digest"
  }

  expect_failures = [var.image_digest]
}

run "rejects_uppercase_or_short_image_digest" {
  command = plan

  variables {
    image_digest = "sha256:0123456789ABCDEF"
  }

  expect_failures = [var.image_digest]
}

run "rejects_digest_without_algorithm" {
  command = plan

  variables {
    image_digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  }

  expect_failures = [var.image_digest]
}

run "rejects_empty_allowed_ingress_cidrs" {
  command = plan

  variables {
    allowed_ingress_cidrs = []
  }

  expect_failures = [var.allowed_ingress_cidrs]
}

run "rejects_invalid_cidr_text" {
  command = plan

  variables {
    allowed_ingress_cidrs = ["office"]
  }

  expect_failures = [var.allowed_ingress_cidrs]
}

run "rejects_cidr_with_host_bits" {
  command = plan

  variables {
    allowed_ingress_cidrs = ["203.0.113.7/24"]
  }

  expect_failures = [var.allowed_ingress_cidrs]
}

run "rejects_ipv6_in_the_ipv4_list" {
  command = plan

  variables {
    allowed_ingress_cidrs = ["2001:db8::/32"]
  }

  expect_failures = [var.allowed_ingress_cidrs]
}

run "rejects_ipv4_in_the_ipv6_list" {
  command = plan

  variables {
    allowed_ingress_ipv6_cidrs = ["203.0.113.0/24"]
  }

  expect_failures = [var.allowed_ingress_ipv6_cidrs]
}

run "rejects_invalid_fargate_cpu_memory_combination_for_web" {
  command = plan

  variables {
    web_cpu    = 256
    web_memory = 4096
  }

  expect_failures = [var.web_memory]
}

run "rejects_unknown_web_cpu" {
  command = plan

  variables {
    web_cpu = 300
  }

  expect_failures = [var.web_cpu]
}

run "rejects_invalid_fargate_cpu_memory_combination_for_worker" {
  command = plan

  variables {
    worker_enabled = true
    worker_cpu     = 512
    worker_memory  = 8192
  }

  expect_failures = [var.worker_memory]
}

run "rejects_missing_public_subnets_for_an_internet_facing_alb" {
  command = plan

  variables {
    public_subnet_ids = []
  }

  expect_failures = [var.public_subnet_ids]
}

run "rejects_a_single_public_subnet" {
  command = plan

  variables {
    public_subnet_ids = ["subnet-0ccccccccccccccc3"]
  }

  expect_failures = [var.public_subnet_ids]
}

run "rejects_a_single_private_subnet" {
  command = plan

  variables {
    private_subnet_ids = ["subnet-0aaaaaaaaaaaaaaa1"]
  }

  expect_failures = [var.private_subnet_ids]
}

run "rejects_shutdown_delay_and_timeout_that_exceed_the_stop_timeout" {
  command = plan

  variables {
    shutdown_delay_seconds   = 30
    shutdown_timeout_seconds = 90
  }

  expect_failures = [var.shutdown_timeout_seconds]
}

run "rejects_worker_enabled_with_zero_workers" {
  command = plan

  variables {
    worker_enabled       = true
    worker_desired_count = 0
  }

  expect_failures = [var.worker_desired_count]
}

run "rejects_reserved_db_key_in_extra_environment" {
  command = plan

  variables {
    extra_environment = { DB_HOST = "evil.example.com" }
  }

  expect_failures = [var.extra_environment]
}

run "rejects_static_storage_credentials_in_extra_environment" {
  command = plan

  variables {
    extra_environment = { STORAGE_ACCESS_KEY = "AKIAEXAMPLE" }
  }

  expect_failures = [var.extra_environment]
}

run "rejects_static_aws_credentials_in_extra_environment" {
  command = plan

  variables {
    extra_environment = { AWS_SECRET_ACCESS_KEY = "secret" }
  }

  expect_failures = [var.extra_environment]
}

run "rejects_role_override_in_extra_environment" {
  command = plan

  variables {
    extra_environment = { OPENARTIFACT_ROLE = "worker" }
  }

  expect_failures = [var.extra_environment]
}

run "rejects_secret_key_override_in_extra_environment" {
  command = plan

  variables {
    extra_environment = { OPENARTIFACT_SECRET_KEY = "plain-text-key" }
  }

  expect_failures = [var.extra_environment]
}

run "rejects_base_url_in_extra_environment" {
  command = plan

  variables {
    extra_environment = { BASE_URL = "https://other.example.com" }
  }

  expect_failures = [var.extra_environment]
}

run "rejects_invalid_environment_variable_name" {
  command = plan

  variables {
    extra_environment = { "1BAD-NAME" = "x" }
  }

  expect_failures = [var.extra_environment]
}

run "rejects_non_tls13_ssl_policy" {
  command = plan

  variables {
    ssl_policy = "ELBSecurityPolicy-2016-08"
  }

  expect_failures = [var.ssl_policy]
}

run "rejects_tls12_only_ssl_policy" {
  command = plan

  variables {
    ssl_policy = "ELBSecurityPolicy-TLS-1-2-2017-01"
  }

  expect_failures = [var.ssl_policy]
}

run "rejects_db_sslmode_disable" {
  command = plan

  variables {
    db_sslmode = "disable"
  }

  expect_failures = [var.db_sslmode]
}

run "rejects_db_sslmode_prefer" {
  command = plan

  variables {
    db_sslmode = "prefer"
  }

  expect_failures = [var.db_sslmode]
}

run "rejects_alb_idle_timeout_zero" {
  command = plan

  variables {
    alb_idle_timeout = 0
  }

  expect_failures = [var.alb_idle_timeout]
}

run "rejects_alb_idle_timeout_above_4000" {
  command = plan

  variables {
    alb_idle_timeout = 4001
  }

  expect_failures = [var.alb_idle_timeout]
}

run "rejects_uppercase_name" {
  command = plan

  variables {
    name = "OpenArtifact"
  }

  expect_failures = [var.name]
}

run "rejects_name_with_underscore" {
  command = plan

  variables {
    name = "open_artifact"
  }

  expect_failures = [var.name]
}

run "rejects_name_ending_with_hyphen" {
  command = plan

  variables {
    name = "openartifact-"
  }

  expect_failures = [var.name]
}

run "rejects_name_that_leaves_no_room_for_the_worker_suffix" {
  command = plan

  variables {
    name = "openartifact-prod-eu"
  }

  expect_failures = [var.name]
}

run "rejects_too_short_name" {
  command = plan

  variables {
    name = "oa"
  }

  expect_failures = [var.name]
}

run "rejects_invalid_vpc_id" {
  command = plan

  variables {
    vpc_id = "not-a-vpc"
  }

  expect_failures = [var.vpc_id]
}

run "rejects_certificate_that_is_not_an_acm_arn" {
  command = plan

  variables {
    certificate_arn = "arn:aws:iam::123456789012:role/not-a-certificate"
  }

  expect_failures = [var.certificate_arn]
}

run "rejects_base_url_without_scheme" {
  command = plan

  variables {
    base_url = "artifacts.example.com"
  }

  expect_failures = [var.base_url]
}

run "rejects_invalid_trusted_proxy_cidr" {
  command = plan

  variables {
    trusted_proxy_cidrs = ["proxy"]
  }

  expect_failures = [var.trusted_proxy_cidrs]
}

run "rejects_web_autoscaling_min_above_max" {
  command = plan

  variables {
    web_autoscaling = { min_capacity = 5, max_capacity = 3 }
  }

  expect_failures = [var.web_autoscaling]
}

run "rejects_web_autoscaling_zero_minimum" {
  command = plan

  variables {
    web_autoscaling = { min_capacity = 0, max_capacity = 3 }
  }

  expect_failures = [var.web_autoscaling]
}

run "rejects_unknown_container_insights_mode" {
  command = plan

  variables {
    container_insights = "on"
  }

  expect_failures = [var.container_insights]
}

run "rejects_unsupported_postgres_major" {
  command = plan

  variables {
    db_engine_version = "12"
  }

  expect_failures = [var.db_engine_version]
}

run "rejects_max_storage_below_allocated_storage" {
  command = plan

  variables {
    db_allocated_storage     = 100
    db_max_allocated_storage = 50
  }

  expect_failures = [var.db_max_allocated_storage]
}

run "rejects_log_retention_that_cloudwatch_does_not_accept" {
  command = plan

  variables {
    log_retention_days = 45
  }

  expect_failures = [var.log_retention_days]
}

run "rejects_never_expire_log_retention" {
  command = plan

  variables {
    log_retention_days = 0
  }

  expect_failures = [var.log_retention_days]
}

run "rejects_secrets_kms_key_that_is_not_an_arn" {
  command = plan

  variables {
    secrets_kms_key_arn = "alias/my-key"
  }

  expect_failures = [var.secrets_kms_key_arn]
}

run "rejects_image_repository_with_a_tag" {
  command = plan

  variables {
    image_repository = "ghcr.io/openartifact/openartifact:latest"
  }

  expect_failures = [var.image_repository]
}

run "rejects_waf_acl_that_is_not_a_regional_web_acl" {
  command = plan

  variables {
    waf_acl_arn = "arn:aws:wafv2:eu-west-1:123456789012:global/webacl/x/00000000-0000-0000-0000-000000000000"
  }

  expect_failures = [var.waf_acl_arn]
}

run "rejects_waf_enabled_without_an_acl" {
  command = plan

  variables {
    waf_acl_enabled = true
  }

  expect_failures = [var.waf_acl_enabled]
}

run "accepts_the_waf_switched_off_with_an_acl_given" {
  command = plan

  variables {
    waf_acl_arn     = "arn:aws:wafv2:eu-west-1:123456789012:regional/webacl/oa/00000000-0000-0000-0000-000000000000"
    waf_acl_enabled = false
  }

  assert {
    condition     = length(aws_wafv2_web_acl_association.this) == 0
    error_message = "waf_acl_enabled = false must not associate the ACL."
  }
}

run "accepts_an_internal_alb_without_public_subnets" {
  command = plan

  variables {
    internal          = true
    public_subnet_ids = []
  }

  assert {
    condition     = aws_lb.this.internal == true && toset(aws_lb.this.subnets) == toset(var.private_subnet_ids)
    error_message = "An internal ALB must be placed in the private subnets and needs no public subnets."
  }
}

run "accepts_ipv6_cidrs_and_switches_the_alb_to_dualstack" {
  command = plan

  variables {
    allowed_ingress_ipv6_cidrs = ["2001:db8::/32"]
  }

  assert {
    condition     = aws_lb.this.ip_address_type == "dualstack"
    error_message = "IPv6 ingress CIDRs require a dualstack ALB."
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.https_ipv6) == 1 && length(aws_vpc_security_group_ingress_rule.http_redirect_ipv6) == 1
    error_message = "One 443 and one 80 ingress rule per allowed IPv6 CIDR."
  }
}

run "accepts_an_explicit_open_cidr_but_warns" {
  command = plan

  variables {
    allowed_ingress_cidrs = ["0.0.0.0/0"]
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.https_ipv4[0].cidr_ipv4 == "0.0.0.0/0"
    error_message = "0.0.0.0/0 is accepted when the caller lists it explicitly."
  }

  expect_failures = [check.ingress_not_open_to_the_internet]
}

run "accepts_the_shutdown_budget_exactly_at_the_limit" {
  command = plan

  variables {
    shutdown_delay_seconds   = 55
    shutdown_timeout_seconds = 60
  }

  assert {
    condition     = aws_lb_target_group.web.deregistration_delay == "115"
    error_message = "55 + 60 + 5 = 120 is the largest accepted shutdown budget."
  }
}

run "explicit_deregistration_delay_wins" {
  command = plan

  variables {
    alb_deregistration_delay_seconds = 30
  }

  assert {
    condition     = aws_lb_target_group.web.deregistration_delay == "30"
    error_message = "alb_deregistration_delay_seconds must override the computed delay."
  }
}

run "accepts_the_largest_fargate_combination" {
  command = plan

  variables {
    web_cpu    = 16384
    web_memory = 122880
  }

  assert {
    condition     = aws_lb.this.name == "oa-test"
    error_message = "A valid 16 vCPU / 120 GiB combination must plan."
  }
}

run "warns_about_an_http_base_url" {
  command = plan

  variables {
    base_url = "http://artifacts.example.com"
  }

  expect_failures = [check.base_url_is_https]
}

run "warns_when_public_subnets_are_ignored" {
  command = plan

  variables {
    internal = true
  }

  expect_failures = [check.internal_alb_ignores_public_subnets]
}

run "optional_load_balancer_features" {
  command = plan

  variables {
    additional_certificate_arns = ["arn:aws:acm:eu-west-1:123456789012:certificate/11111111-1111-1111-1111-111111111111"]
    waf_acl_arn                 = "arn:aws:wafv2:eu-west-1:123456789012:regional/webacl/oa/00000000-0000-0000-0000-000000000000"
    alb_access_logs_bucket = {
      bucket = "oa-alb-logs"
      prefix = "oa"
    }
  }

  assert {
    condition     = length(aws_lb_listener_certificate.additional) == 1 && length(aws_wafv2_web_acl_association.this) == 1
    error_message = "An additional certificate and a WAF association must be created when given."
  }

  assert {
    condition     = aws_lb.this.access_logs[0].enabled == true && aws_lb.this.access_logs[0].bucket == "oa-alb-logs" && aws_lb.this.access_logs[0].prefix == "oa"
    error_message = "ALB access logs must be enabled for the given bucket and prefix."
  }
}
