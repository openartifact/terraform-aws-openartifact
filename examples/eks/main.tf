# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: MPL-2.0

# OpenArtifact on an existing EKS cluster: S3 + RDS + secrets in AWS, the Helm chart in the
# cluster, EKS Pod Identity for the pods' AWS access. Prerequisites in the cluster: the EKS Pod
# Identity agent add-on (not needed on EKS Auto Mode), the AWS Load Balancer Controller and the
# External Secrets Operator with a ClusterSecretStore for AWS Secrets Manager.
#
# Deletion protection stays ON (database, load balancer). To tear the example down, set
# db_deletion_protection and ingress.deletion_protection to false, apply, then destroy.

module "openartifact" {
  # Registry: source = "openartifact/openartifact/aws//modules/eks" with version = "~> 0.1"
  source = "../../modules/eks"

  name         = var.name
  cluster_name = var.cluster_name

  # The VPC of the cluster, read from the cluster itself.
  vpc_id              = data.aws_eks_cluster.this.vpc_config[0].vpc_id
  database_subnet_ids = var.database_subnet_ids

  # The security group EKS attaches to managed node groups and Fargate pods; pods running on
  # nodes with other security groups (custom networking, security groups for pods) need those
  # IDs here instead.
  workload_security_group_ids = [data.aws_eks_cluster.this.vpc_config[0].cluster_security_group_id]

  allowed_ingress_cidrs = var.allowed_ingress_cidrs

  ingress = {
    enabled         = true
    host            = var.ingress_host
    certificate_arn = var.certificate_arn
  }

  secret_store_name = var.secret_store_name

  tags = var.tags
}
