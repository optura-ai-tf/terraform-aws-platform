# =============================================================================
# EKS Pod Identity — IAM Roles, Policies, and Associations
#
# Each entry in var.pod_identity_roles creates an EKS Pod Identity Association
# (namespace + ServiceAccount → IAM role). Entries with policy_statements are
# fully managed here: this module also creates the IAM role (trusted by
# pods.eks.amazonaws.com) and its IAM policy. Entries with role_arn bind to a
# pre-existing, externally-managed role and create only the association.
#
# The Pod Identity Agent addon (eks-addons.tf) must be installed for
# credentials to be injected into pods.
#
# Pod Identity requires exact-match (namespace, service_account)
# tuples — wildcards are not supported by the AWS API. For wildcard
# namespace matching (when namespaces churn at the Kubernetes layer
# without a terraform apply), see irsa.tf.
# =============================================================================

locals {
  # Entries this module fully manages (creates IAM role + policy). Entries that
  # set role_arn instead bind to an externally-managed role — association only.
  pod_identity_managed = { for k, v in var.pod_identity_roles : k => v if v.role_arn == null }
}

# --- IAM Role per service ---
# Trust policy allows EKS Pod Identity to assume the role and tag sessions.

resource "aws_iam_role" "pod_identity" {
  for_each = local.pod_identity_managed

  name = "eks-pod-${each.key}-${local.name_prefix}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com"
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
        Condition = {
          ArnLike = {
            "aws:SourceArn" = aws_eks_cluster.main.arn
          }
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })

  tags = merge(
    local.common_tags,
    {
      Name    = "eks-pod-${each.key}-${local.name_prefix}"
      Service = each.key
    }
  )
}

# --- IAM Policy per service ---
# Permissions are defined by the entry's policy_statements.

resource "aws_iam_policy" "pod_identity" {
  for_each = local.pod_identity_managed

  name        = "eks-pod-${each.key}-${local.name_prefix}"
  description = "Pod Identity policy for ${each.key} on ${local.name_prefix}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      for stmt in each.value.policy_statements : {
        Sid      = stmt.sid
        Effect   = "Allow"
        Action   = stmt.actions
        Resource = stmt.resources
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "pod_identity" {
  for_each = local.pod_identity_managed

  role       = aws_iam_role.pod_identity[each.key].name
  policy_arn = aws_iam_policy.pod_identity[each.key].arn
}

# --- Pod Identity Association per service ---
# Links a Kubernetes ServiceAccount to an IAM role. The Pod Identity Agent
# on the node intercepts the credential chain and injects temporary
# credentials into pods running under that ServiceAccount.

resource "aws_eks_pod_identity_association" "pod_identity" {
  for_each = var.pod_identity_roles

  cluster_name    = aws_eks_cluster.main.name
  namespace       = each.value.namespace
  service_account = each.value.service_account
  role_arn        = coalesce(each.value.role_arn, try(aws_iam_role.pod_identity[each.key].arn, null))

  tags = merge(
    local.common_tags,
    {
      Name    = "eks-pod-${each.key}-${local.name_prefix}"
      Service = each.key
    }
  )

  depends_on = [
    aws_eks_addon.pod_identity_agent
  ]
}
