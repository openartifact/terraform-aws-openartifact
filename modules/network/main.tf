# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

data "aws_region" "current" {}

data "aws_partition" "current" {}

data "aws_availability_zones" "available" {
  state = "available"

  # Skip Local Zones and Wavelength Zones: they lack NAT gateways and many services.
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs      = slice(data.aws_availability_zones.available.names, 0, min(var.az_count, length(data.aws_availability_zones.available.names)))
  az_index = { for index, az in local.azs : az => index }

  # Private subnets take the first three quarters of the VPC range, public
  # subnets are carved out of the last quarter.
  private_cidrs = { for az, index in local.az_index : az => cidrsubnet(var.cidr, 2, index) }
  public_cidrs  = { for az, index in local.az_index : az => cidrsubnet(cidrsubnet(var.cidr, 2, 3), 2, index) }

  # AZs that host a NAT gateway.
  nat_azs = var.nat_gateway_mode == "per_az" ? local.azs : slice(local.azs, 0, 1)
  # AZ whose NAT gateway serves each private route table.
  nat_az_for = { for az in local.azs : az => var.nat_gateway_mode == "per_az" ? az : local.azs[0] }

  s3_service_name = "com.amazonaws.${data.aws_region.current.region}.s3"
}

# ------------------------------------------------------------------------------
# VPC
# ------------------------------------------------------------------------------

resource "aws_vpc" "this" {
  cidr_block           = var.cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = var.name })

  lifecycle {
    precondition {
      condition     = length(data.aws_availability_zones.available.names) >= var.az_count
      error_message = "The region offers fewer than az_count available availability zones; lower az_count."
    }
  }
}

# The default security group is adopted and stripped of all rules so nothing
# can accidentally rely on it; workloads use dedicated security groups.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-default-unused" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = var.name })
}

# ------------------------------------------------------------------------------
# Subnets
# ------------------------------------------------------------------------------

# Public subnets host the load balancer and the NAT gateways only. Instances
# launched here do NOT get a public IP by default.
resource "aws_subnet" "public" {
  for_each = local.public_cidrs

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = each.value
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "${var.name}-public-${each.key}"
    Tier = "public"
  })
}

resource "aws_subnet" "private" {
  for_each = local.private_cidrs

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = each.value
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "${var.name}-private-${each.key}"
    Tier = "private"
  })
}

# ------------------------------------------------------------------------------
# Routing
# ------------------------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-public" })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  for_each = toset(local.nat_azs)

  domain = "vpc"

  tags = merge(var.tags, { Name = "${var.name}-nat-${each.key}" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  for_each = toset(local.nat_azs)

  allocation_id     = aws_eip.nat[each.key].id
  subnet_id         = aws_subnet.public[each.key].id
  connectivity_type = "public"

  tags = merge(var.tags, { Name = "${var.name}-${each.key}" })

  depends_on = [aws_internet_gateway.this]
}

# One private route table per AZ so "per_az" mode keeps egress inside the AZ.
resource "aws_route_table" "private" {
  for_each = toset(local.azs)

  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-private-${each.key}" })
}

resource "aws_route" "private_nat" {
  for_each = aws_route_table.private

  route_table_id         = each.value.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[local.nat_az_for[each.key]].id
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

# Gateway endpoint: S3 traffic (the artifact blobs) bypasses the NAT gateway,
# which removes NAT data-processing charges and keeps the traffic on the AWS network.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = local.s3_service_name
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [for az in local.azs : aws_route_table.private[az].id]

  tags = merge(var.tags, { Name = "${var.name}-s3" })
}

# ------------------------------------------------------------------------------
# Flow logs
# ------------------------------------------------------------------------------

locals {
  flow_logs_count = var.flow_logs_enabled ? 1 : 0
}

#trivy:ignore:AVD-AWS-0017 encryption with a customer managed key is opt-in through flow_logs_kms_key_arn because the key policy must grant the CloudWatch Logs service principal access
resource "aws_cloudwatch_log_group" "flow_logs" {
  #checkov:skip=CKV_AWS_338: retention is configurable through flow_logs_retention_days; the default of 90 days is a cost/audit trade-off
  #checkov:skip=CKV_AWS_158: encryption with a customer managed key is opt-in through flow_logs_kms_key_arn because the key policy must grant the CloudWatch Logs service principal access
  count = local.flow_logs_count

  name              = "/aws/vpc/${var.name}/flow-logs"
  retention_in_days = var.flow_logs_retention_days
  kms_key_id        = var.flow_logs_kms_key_arn

  tags = merge(var.tags, { Name = "${var.name}-flow-logs" })
}

data "aws_iam_policy_document" "flow_logs_assume" {
  count = local.flow_logs_count

  statement {
    sid     = "VpcFlowLogsAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [aws_vpc.this.owner_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:${aws_vpc.this.owner_id}:vpc-flow-log/*"]
    }
  }
}

data "aws_iam_policy_document" "flow_logs_write" {
  count = local.flow_logs_count

  statement {
    sid    = "WriteFlowLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents",
    ]
    resources = [aws_cloudwatch_log_group.flow_logs[0].arn, "${aws_cloudwatch_log_group.flow_logs[0].arn}:*"]
  }
}

resource "aws_iam_role" "flow_logs" {
  count = local.flow_logs_count

  name               = "${var.name}-vpc-flow-logs"
  description        = "Lets VPC flow logs of ${var.name} write to CloudWatch Logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume[0].json

  tags = merge(var.tags, { Name = "${var.name}-vpc-flow-logs" })
}

resource "aws_iam_role_policy" "flow_logs" {
  count = local.flow_logs_count

  name   = "write-flow-logs"
  role   = aws_iam_role.flow_logs[0].id
  policy = data.aws_iam_policy_document.flow_logs_write[0].json
}

resource "aws_flow_log" "this" {
  count = local.flow_logs_count

  vpc_id                   = aws_vpc.this.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow_logs[0].arn
  iam_role_arn             = aws_iam_role.flow_logs[0].arn
  max_aggregation_interval = 60

  tags = merge(var.tags, { Name = "${var.name}-flow-logs" })

  depends_on = [aws_iam_role_policy.flow_logs]
}
