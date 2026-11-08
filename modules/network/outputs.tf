# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: MPL-2.0

output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "IPv4 CIDR block of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "IDs of the public subnets (for load balancers), in availability zone order."
  value       = [for az in local.azs : aws_subnet.public[az].id]
}

output "private_subnet_ids" {
  description = "IDs of the private subnets (for tasks, pods and the database), in availability zone order."
  value       = [for az in local.azs : aws_subnet.private[az].id]
}

output "private_route_table_ids" {
  description = "IDs of the private route tables, in availability zone order."
  value       = [for az in local.azs : aws_route_table.private[az].id]
}

output "nat_gateway_public_ips" {
  description = "Public IPs (elastic IPs) of the NAT gateways: the source addresses of all outbound traffic, useful for upstream allow-lists."
  value       = [for az in local.nat_azs : aws_eip.nat[az].public_ip]
}

output "s3_gateway_endpoint_id" {
  description = "ID of the S3 gateway VPC endpoint attached to the private route tables."
  value       = aws_vpc_endpoint.s3.id
}

output "availability_zones" {
  description = "Names of the availability zones in use, in subnet order."
  value       = local.azs
}
