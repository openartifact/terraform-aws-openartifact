# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: MPL-2.0

# Tests for the web/worker split, the image reference and the environment of the root module.
# Terraform leaves the computed attributes of mocked resources unknown during plan (OpenTofu fills
# them in) and the container definitions embed the database endpoint, so these runs apply
# against the mocked provider. Nothing touches AWS.
# Run: terraform test -filter=tests/root-worker-split.tftest.hcl   (or tofu test)

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

run "single_service_runs_every_role" {
  command = apply

  assert {
    condition     = length(module.worker) == 0
    error_message = "No worker service must exist unless worker_enabled is true."
  }

  assert {
    condition     = [for e in jsondecode(module.web.container_definitions)[0].environment : e.value if e.name == "OPENARTIFACT_ROLE"] == ["all"]
    error_message = "Without a worker the single service must run with OPENARTIFACT_ROLE=all."
  }

  assert {
    condition     = output.web_service_name == "oa-test" && output.worker_service_name == null
    error_message = "worker_service_name must be null and the web service must carry the deployment name."
  }

  assert {
    condition     = output.log_group_names.worker == null && output.security_group_ids.worker == null && output.task_role_arns.worker == null && output.execution_role_arns.worker == null
    error_message = "Every worker entry of the map outputs must be null when the worker is disabled."
  }

  assert {
    condition     = output.log_group_names.web == "/ecs/oa-test"
    error_message = "The web log group must be /ecs/<name>."
  }
}

run "worker_split_gives_web_and_worker_roles" {
  command = apply

  variables {
    worker_enabled       = true
    worker_desired_count = 2
    worker_cpu           = 512
    worker_memory        = 1024
  }

  assert {
    condition     = length(module.worker) == 1
    error_message = "worker_enabled must create exactly one worker service."
  }

  assert {
    condition     = [for e in jsondecode(module.web.container_definitions)[0].environment : e.value if e.name == "OPENARTIFACT_ROLE"] == ["web"]
    error_message = "With a worker the web service must run with OPENARTIFACT_ROLE=web."
  }

  assert {
    condition     = [for e in jsondecode(module.worker[0].container_definitions)[0].environment : e.value if e.name == "OPENARTIFACT_ROLE"] == ["worker"]
    error_message = "The worker service must run with OPENARTIFACT_ROLE=worker."
  }

  assert {
    condition     = output.web_service_name == "oa-test" && output.worker_service_name == "oa-test-worker"
    error_message = "The worker service must be named <name>-worker next to the web service <name>."
  }

  assert {
    condition     = output.log_group_names.worker == "/ecs/oa-test-worker" && output.log_group_names.web == "/ecs/oa-test"
    error_message = "Each service needs its own log group."
  }

  assert {
    condition     = output.security_group_ids.worker != null && output.task_role_arns.worker != null && output.execution_role_arns.worker != null
    error_message = "The worker must have its own security group and roles."
  }

  assert {
    condition = (
      jsondecode(module.worker[0].container_definitions)[0].image == jsondecode(module.web.container_definitions)[0].image
      && jsondecode(module.worker[0].container_definitions)[0].secrets == jsondecode(module.web.container_definitions)[0].secrets
    )
    error_message = "Web and worker must run the same image and receive the same secrets."
  }

  assert {
    condition = alltrue([
      for e in jsondecode(module.worker[0].container_definitions)[0].environment :
      !contains(["STORAGE_ACCESS_KEY", "STORAGE_SECRET_KEY"], e.name)
    ])
    error_message = "The worker must not receive static credentials either."
  }
}

run "back_to_a_single_service" {
  command = apply

  variables {
    worker_enabled = false
  }

  assert {
    condition     = length(module.worker) == 0 && output.worker_service_name == null
    error_message = "Disabling the worker must remove the worker service."
  }

  assert {
    condition     = [for e in jsondecode(module.web.container_definitions)[0].environment : e.value if e.name == "OPENARTIFACT_ROLE"] == ["all"]
    error_message = "Disabling the worker must return the web service to OPENARTIFACT_ROLE=all."
  }
}

run "tag_is_used_without_a_digest" {
  command = apply

  variables {
    image_tag = "0.20.0"
  }

  assert {
    condition     = jsondecode(module.web.container_definitions)[0].image == "ghcr.io/openartifact/openartifact:0.20.0"
    error_message = "Without image_digest the image must be <image_repository>:<image_tag>."
  }
}

run "default_tag_matches_the_documented_release" {
  command = apply

  assert {
    condition     = jsondecode(module.web.container_definitions)[0].image == "ghcr.io/openartifact/openartifact:0.19.2"
    error_message = "The default image must be ghcr.io/openartifact/openartifact:0.19.2."
  }
}

run "digest_wins_over_tag" {
  command = apply

  variables {
    worker_enabled = true
    image_tag      = "0.20.0"
    image_digest   = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  }

  assert {
    condition     = jsondecode(module.web.container_definitions)[0].image == "ghcr.io/openartifact/openartifact@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    error_message = "image_digest must win over image_tag: the image must be <image_repository>@<digest>."
  }

  assert {
    condition     = jsondecode(module.worker[0].container_definitions)[0].image == jsondecode(module.web.container_definitions)[0].image
    error_message = "The worker must run the same pinned image as the web service."
  }

  assert {
    condition     = !strcontains(jsondecode(module.web.container_definitions)[0].image, "0.20.0")
    error_message = "The tag must not appear in an image pinned by digest."
  }
}

run "custom_repository" {
  command = apply

  variables {
    image_repository = "registry.example.com:5000/mirror/openartifact"
  }

  assert {
    condition     = jsondecode(module.web.container_definitions)[0].image == "registry.example.com:5000/mirror/openartifact:0.19.2"
    error_message = "image_repository must replace the default registry and path."
  }
}

run "environment_is_wired_from_the_stack" {
  command = apply

  variables {
    db_max_open_conns = 40
    alb_idle_timeout  = 120
    extra_environment = {
      LOG_LEVEL = "debug"
    }
  }

  assert {
    condition = alltrue([
      for pair in [
        ["STORAGE_BACKEND", "s3"],
        ["STORAGE_REGION", "eu-west-1"],
        ["DB_PORT", "5432"],
        ["DB_NAME", "openartifact"],
        ["DB_USER", "openartifact"],
        ["DB_SSLMODE", "require"],
        ["DB_MAX_OPEN_CONNS", "40"],
        ["LOG_FORMAT", "json"],
        ["LOG_LEVEL", "debug"],
        ["OPENARTIFACT_TRUSTED_PROXIES", "10.0.0.0/16"],
        ["SERVER_PORT", "8080"],
        ["SERVER_SHUTDOWN_DELAY", "15"],
        ["SERVER_SHUTDOWN_TIMEOUT", "60"],
      ] :
      anytrue([for e in jsondecode(module.web.container_definitions)[0].environment : e.name == pair[0] && e.value == pair[1]])
    ])
    error_message = "The container environment must carry the storage, database, logging, proxy and shutdown settings of the stack."
  }

  assert {
    condition     = [for e in jsondecode(module.web.container_definitions)[0].environment : e.value if e.name == "SERVER_IDLE_TIMEOUT"] == ["180"]
    error_message = "SERVER_IDLE_TIMEOUT must be the ALB idle timeout plus 60 seconds."
  }

  assert {
    condition     = !contains([for e in jsondecode(module.web.container_definitions)[0].environment : e.name], "BASE_URL")
    error_message = "BASE_URL must not be set when base_url is null."
  }

  assert {
    condition     = output.url == "https://${aws_lb.this.dns_name}"
    error_message = "Without base_url the url output must fall back to the ALB DNS name."
  }
}

run "base_url_and_trusted_proxies_are_passed_through" {
  command = apply

  variables {
    base_url            = "https://artifacts.example.com"
    trusted_proxy_cidrs = ["10.1.0.0/24", "10.1.1.0/24"]
  }

  assert {
    condition     = [for e in jsondecode(module.web.container_definitions)[0].environment : e.value if e.name == "BASE_URL"] == ["https://artifacts.example.com"]
    error_message = "base_url must be injected as BASE_URL."
  }

  assert {
    condition     = [for e in jsondecode(module.web.container_definitions)[0].environment : e.value if e.name == "OPENARTIFACT_TRUSTED_PROXIES"] == ["10.1.0.0/24,10.1.1.0/24"]
    error_message = "trusted_proxy_cidrs must be injected as a comma-separated OPENARTIFACT_TRUSTED_PROXIES."
  }

  assert {
    condition     = output.url == "https://artifacts.example.com"
    error_message = "The url output must be base_url when set."
  }
}

run "empty_trusted_proxies_sets_nothing" {
  command = apply

  variables {
    trusted_proxy_cidrs = []
  }

  assert {
    condition     = !contains([for e in jsondecode(module.web.container_definitions)[0].environment : e.name], "OPENARTIFACT_TRUSTED_PROXIES")
    error_message = "An empty trusted_proxy_cidrs must not set OPENARTIFACT_TRUSTED_PROXIES."
  }
}

run "secrets_follow_the_toggles" {
  command = apply

  variables {
    enable_metrics_token             = false
    bootstrap_admin_password_enabled = false
  }

  assert {
    condition     = toset([for s in jsondecode(module.web.container_definitions)[0].secrets : s.name]) == toset(["AUTH_HMAC_KEY", "DB_PASSWORD", "OPENARTIFACT_SECRET_KEY"])
    error_message = "With the optional secrets disabled only the keys and the database password are injected."
  }

  assert {
    condition     = [for s in jsondecode(module.web.container_definitions)[0].secrets : endswith(s.valueFrom, ":password::") if s.name == "DB_PASSWORD"] == [true]
    error_message = "DB_PASSWORD must reference the password key of the RDS-managed JSON secret (<arn>:password::)."
  }
}
