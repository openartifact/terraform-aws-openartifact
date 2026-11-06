# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# Plan-only tests for modules/network (no AWS credentials needed).

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
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

  # OpenTofu fills computed attributes with mock values at plan time (Terraform
  # only does so on apply); the flow log validates these as ARNs.
  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:eu-west-1:123456789012:log-group:/aws/vpc/oa-test/flow-logs"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/oa-test-vpc-flow-logs"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  name = "oa-test"
}

run "secure_defaults" {
  command = plan

  module {
    source = "./modules/network"
  }

  assert {
    condition     = aws_vpc.this.cidr_block == "10.0.0.0/16" && aws_vpc.this.enable_dns_support == true && aws_vpc.this.enable_dns_hostnames == true
    error_message = "VPC must use 10.0.0.0/16 with DNS support and hostnames enabled."
  }

  assert {
    condition     = join(",", output.availability_zones) == "eu-west-1a,eu-west-1b"
    error_message = "Two AZs must be used by default."
  }

  assert {
    condition     = length(aws_subnet.public) == 2 && length(aws_subnet.private) == 2
    error_message = "One public and one private subnet per AZ are expected."
  }

  assert {
    condition     = alltrue([for s in values(aws_subnet.public) : s.map_public_ip_on_launch == false])
    error_message = "Public subnets must not auto-assign public IPs."
  }

  assert {
    condition     = alltrue([for s in values(aws_subnet.private) : s.map_public_ip_on_launch == false])
    error_message = "Private subnets must not auto-assign public IPs."
  }

  assert {
    condition = (
      aws_subnet.private["eu-west-1a"].cidr_block == "10.0.0.0/18"
      && aws_subnet.private["eu-west-1b"].cidr_block == "10.0.64.0/18"
      && aws_subnet.public["eu-west-1a"].cidr_block == "10.0.192.0/20"
      && aws_subnet.public["eu-west-1b"].cidr_block == "10.0.208.0/20"
    )
    error_message = "Subnet CIDRs must be derived deterministically from the VPC CIDR without overlap."
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 1 && length(aws_eip.nat) == 1 && contains(keys(aws_nat_gateway.this), "eu-west-1a")
    error_message = "single mode must create exactly one NAT gateway, in the first AZ."
  }

  assert {
    condition     = length(aws_route_table.private) == 2 && length(aws_route.private_nat) == 2 && length(aws_route_table_association.private) == 2
    error_message = "Each private subnet needs its own route table with a default route via NAT."
  }

  assert {
    condition     = length(aws_route_table_association.public) == 2 && aws_route.public_internet.destination_cidr_block == "0.0.0.0/0"
    error_message = "Public subnets must route 0.0.0.0/0 to the internet gateway."
  }

  assert {
    condition     = aws_vpc_endpoint.s3.service_name == "com.amazonaws.eu-west-1.s3" && aws_vpc_endpoint.s3.vpc_endpoint_type == "Gateway"
    error_message = "An S3 gateway endpoint must exist."
  }

  assert {
    condition     = length(output.private_route_table_ids) == 2 && length(output.private_subnet_ids) == 2 && length(output.public_subnet_ids) == 2
    error_message = "Outputs must list one private route table, private subnet and public subnet per AZ."
  }

  assert {
    condition     = length(aws_flow_log.this) == 1 && aws_flow_log.this[0].traffic_type == "ALL" && aws_flow_log.this[0].log_destination_type == "cloud-watch-logs"
    error_message = "Flow logs for all traffic to CloudWatch Logs must be on by default."
  }

  assert {
    condition     = aws_cloudwatch_log_group.flow_logs[0].retention_in_days == 90 && aws_cloudwatch_log_group.flow_logs[0].name == "/aws/vpc/oa-test/flow-logs"
    error_message = "Flow log group must keep 90 days by default."
  }

  assert {
    condition     = aws_cloudwatch_log_group.flow_logs[0].kms_key_id == null
    error_message = "No KMS key is set unless flow_logs_kms_key_arn is given."
  }

  assert {
    condition = (
      one([for p in data.aws_iam_policy_document.flow_logs_assume[0].statement[0].principals : p.identifiers]) == toset(["vpc-flow-logs.amazonaws.com"])
      && toset([for c in data.aws_iam_policy_document.flow_logs_assume[0].statement[0].condition : c.variable]) == toset(["aws:SourceAccount", "aws:SourceArn"])
    )
    error_message = "Only the flow logs service, scoped to this account and its flow logs, may assume the role."
  }

  assert {
    condition = alltrue(flatten([
      for s in data.aws_iam_policy_document.flow_logs_write[0].statement : [for a in s.actions : !endswith(a, "*")]
    ]))
    error_message = "The flow log role must not use wildcard actions."
  }
}

run "three_azs_nat_per_az" {
  command = plan

  module {
    source = "./modules/network"
  }

  variables {
    az_count         = 3
    nat_gateway_mode = "per_az"
    cidr             = "172.16.0.0/20"
  }

  assert {
    condition     = length(aws_subnet.public) == 3 && length(aws_subnet.private) == 3 && length(aws_route_table.private) == 3
    error_message = "Three AZs must yield three public and three private subnets."
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 3 && length(aws_eip.nat) == 3
    error_message = "per_az mode must create one NAT gateway and EIP per AZ."
  }

  assert {
    condition     = join(",", output.availability_zones) == "eu-west-1a,eu-west-1b,eu-west-1c"
    error_message = "Three AZs must be reported."
  }

  assert {
    condition = (
      aws_subnet.private["eu-west-1c"].cidr_block == "172.16.8.0/22"
      && aws_subnet.public["eu-west-1c"].cidr_block == "172.16.14.0/24"
    )
    error_message = "Subnets must scale with a non-default VPC CIDR."
  }
}

run "flow_logs_disabled" {
  command = plan

  module {
    source = "./modules/network"
  }

  variables {
    flow_logs_enabled = false
  }

  assert {
    condition = (
      length(aws_flow_log.this) == 0
      && length(aws_cloudwatch_log_group.flow_logs) == 0
      && length(aws_iam_role.flow_logs) == 0
      && length(aws_iam_role_policy.flow_logs) == 0
    )
    error_message = "Disabling flow logs must remove the log group, role and flow log."
  }
}

run "flow_logs_custom_retention_and_kms" {
  command = plan

  module {
    source = "./modules/network"
  }

  variables {
    flow_logs_retention_days = 365
    flow_logs_kms_key_arn    = "arn:aws:kms:eu-west-1:123456789012:key/11111111-2222-3333-4444-555555555555"
    tags                     = { Env = "test" }
  }

  assert {
    condition = (
      aws_cloudwatch_log_group.flow_logs[0].retention_in_days == 365
      && aws_cloudwatch_log_group.flow_logs[0].kms_key_id == "arn:aws:kms:eu-west-1:123456789012:key/11111111-2222-3333-4444-555555555555"
    )
    error_message = "Retention and KMS key must be applied to the flow log group."
  }

  assert {
    condition     = aws_vpc.this.tags["Env"] == "test" && aws_subnet.private["eu-west-1a"].tags["Env"] == "test" && aws_cloudwatch_log_group.flow_logs[0].tags["Env"] == "test"
    error_message = "Tags must propagate to every resource."
  }
}

run "fails_when_region_has_too_few_azs" {
  command = plan

  module {
    source = "./modules/network"
  }

  override_data {
    target = data.aws_availability_zones.available
    values = {
      names = ["eu-west-1a"]
    }
  }

  expect_failures = [aws_vpc.this]
}

run "rejects_cidr_too_large" {
  command = plan

  module {
    source = "./modules/network"
  }

  variables {
    cidr = "10.0.0.0/8"
  }

  expect_failures = [var.cidr]
}

run "rejects_cidr_too_small" {
  command = plan

  module {
    source = "./modules/network"
  }

  variables {
    cidr = "10.0.0.0/24"
  }

  expect_failures = [var.cidr]
}

run "rejects_cidr_with_host_bits" {
  command = plan

  module {
    source = "./modules/network"
  }

  variables {
    cidr = "10.0.0.1/16"
  }

  expect_failures = [var.cidr]
}

run "rejects_cidr_garbage" {
  command = plan

  module {
    source = "./modules/network"
  }

  variables {
    cidr = "not-a-cidr"
  }

  expect_failures = [var.cidr]
}

run "rejects_az_count" {
  command = plan

  module {
    source = "./modules/network"
  }

  variables {
    az_count = 4
  }

  expect_failures = [var.az_count]
}

run "rejects_nat_mode" {
  command = plan

  module {
    source = "./modules/network"
  }

  variables {
    nat_gateway_mode = "none"
  }

  expect_failures = [var.nat_gateway_mode]
}

run "rejects_unsupported_retention" {
  command = plan

  module {
    source = "./modules/network"
  }

  variables {
    flow_logs_retention_days = 100
  }

  expect_failures = [var.flow_logs_retention_days]
}

run "rejects_never_expire_retention" {
  command = plan

  module {
    source = "./modules/network"
  }

  variables {
    flow_logs_retention_days = 0
  }

  expect_failures = [var.flow_logs_retention_days]
}

run "rejects_bad_kms_arn" {
  command = plan

  module {
    source = "./modules/network"
  }

  variables {
    flow_logs_kms_key_arn = "alias/foo"
  }

  expect_failures = [var.flow_logs_kms_key_arn]
}

# The default security group is adopted with no rule blocks, which makes the
# provider delete every rule. Rule sets are only known after apply, so this is
# the single run that applies (against the mocked provider, nothing is created).
run "default_security_group_has_no_rules" {
  command = apply

  module {
    source = "./modules/network"
  }

  # Flow log resources validate ARNs, which the mock provider does not generate.
  variables {
    flow_logs_enabled = false
  }

  assert {
    condition     = length(aws_default_security_group.this.ingress) == 0 && length(aws_default_security_group.this.egress) == 0
    error_message = "The default security group must have no rules."
  }
}
