# =============================================================================
# IRSA — IAM Roles for Service Accounts (OIDC-based)
#
# Older counterpart to Pod Identity (pod-identity.tf). Each entry in
# var.irsa_roles produces:
#   1. IAM role with a federated trust policy referencing the
#      cluster's OIDC provider (aws_iam_openid_connect_provider.eks
#      in iam.tf), gated by a StringLike condition on the `:sub`
#      claim — so wildcards in `namespace_pattern` are honored
#   2. IAM policy with the entry's policy_statements
#
# IRSA is the right tool when the namespace set changes at the
# Kubernetes layer without a terraform apply (for example,
# tenant-per-namespace patterns). Pod Identity requires exact-match
# associations; IRSA's StringLike condition lets one IAM role serve
# every namespace matching a glob (for example "tenant-*").
#
# K8s side (NOT managed by this module): the ServiceAccount in each
# matching namespace must be annotated
#   eks.amazonaws.com/role-arn: <role_arn from outputs>
# typically via your application manifests / GitOps. Once that
# annotation is in place, adding a new matching namespace requires
# only K8s changes — no terraform apply.
# =============================================================================

# --- IAM Role per service ---
# Federated trust policy: the OIDC provider can issue tokens on
# behalf of K8s ServiceAccounts; StringLike on `:sub` lets the
# trust policy match a wildcard namespace pattern. The `:aud` claim
# is pinned to "sts.amazonaws.com" (the audience the IRSA admission
# webhook stamps into the projected service-account token).

resource "aws_iam_role" "irsa" {
  for_each = var.irsa_roles

  name = "eks-irsa-${each.key}-${local.name_prefix}"

  # The OIDC issuer hostname (without https://) is computed inline
  # rather than via a module-level local so the reference to
  # aws_iam_openid_connect_provider.eks.url is only evaluated for
  # instances that actually exist (i.e. when for_each is non-empty).
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.eks.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:${each.value.namespace_pattern}:${each.value.service_account}"
          }
        }
      }
    ]
  })

  tags = merge(
    local.common_tags,
    {
      Name    = "eks-irsa-${each.key}-${local.name_prefix}"
      Service = each.key
    }
  )
}

# --- IAM Policy per service ---
# Permissions are defined by the entry's policy_statements.

resource "aws_iam_policy" "irsa" {
  for_each = var.irsa_roles

  name        = "eks-irsa-${each.key}-${local.name_prefix}"
  description = "IRSA policy for ${each.key} on ${local.name_prefix}"

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

resource "aws_iam_role_policy_attachment" "irsa" {
  for_each = var.irsa_roles

  role       = aws_iam_role.irsa[each.key].name
  policy_arn = aws_iam_policy.irsa[each.key].arn
}
