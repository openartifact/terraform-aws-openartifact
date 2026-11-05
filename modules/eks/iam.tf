# SPDX-FileCopyrightText: The OpenArtifact Authors
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# ---------------------------------------------------------------------------
# EKS Pod Identity: the chart's service account (web and worker pods) gets an IAM role that can
# use the blob bucket and its KMS key, nothing else. No static AWS keys, no OIDC provider.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "pod_identity" {
  name                 = "${var.name}-eks-${local.region}"
  description          = "OpenArtifact on EKS cluster ${var.cluster_name}: S3 blob storage access through EKS Pod Identity."
  permissions_boundary = var.iam_role_permissions_boundary_arn

  # Trust: only the EKS Pod Identity service principal, and only for this cluster, namespace and
  # service account (the session tags EKS Pod Identity adds to every assumption).
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEksAuthToAssumeRoleForPodIdentity"
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com"
        }
        Action = ["sts:AssumeRole", "sts:TagSession"]
        Condition = {
          StringEquals = {
            "aws:RequestTag/eks-cluster-name"           = var.cluster_name
            "aws:RequestTag/kubernetes-namespace"       = var.namespace
            "aws:RequestTag/kubernetes-service-account" = local.service_account_name
          }
        }
      },
    ]
  })

  tags = merge(var.tags, { Name = "${var.name}-eks-${local.region}" })
}

resource "aws_iam_role_policy" "blob_storage" {
  name   = "blob-storage"
  role   = aws_iam_role.pod_identity.id
  policy = module.storage.access_policy_json
}

resource "aws_eks_pod_identity_association" "this" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = local.service_account_name
  role_arn        = aws_iam_role.pod_identity.arn

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Policy for the identity of the External Secrets Operator (or any other reader of the
# secrets). Not attached to anything here: the operator's role belongs to whoever installed it.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "external_secrets" {
  statement {
    sid    = "ReadOpenArtifactSecrets"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = local.readable_secret_arns
  }

  statement {
    sid       = "DecryptOpenArtifactSecrets"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = local.readable_kms_key_arns

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${local.region}.amazonaws.com"]
    }
  }
}
