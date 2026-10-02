# ===================================================================
# EKS Access Entries (cluster_authentication_mode API / API_AND_CONFIG_MAP)
# ===================================================================
#
# The access-entry equivalent of eks-access.tf's aws-auth ConfigMap. Both are
# written under API_AND_CONFIG_MAP so a cluster can migrate without a window
# where nodes cannot join; only entries are written under API.
#
# Karpenter's node role MUST be an access entry: aws-auth maps a role to
# system:nodes statically, which works for managed node groups the module
# declares, but Karpenter launches instances the module never sees. The
# EC2_LINUX entry type grants exactly the node-bootstrap permissions.
# ===================================================================

locals {
  access_entries_enabled = var.cluster_authentication_mode != "CONFIG_MAP"
}

# --- Cluster admins ---

resource "aws_eks_access_entry" "admin" {
  for_each = local.access_entries_enabled ? toset(var.cluster_admin_arns) : toset([])

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = each.value
  type          = "STANDARD"

  tags = local.common_tags
}

resource "aws_eks_access_policy_association" "admin" {
  for_each = local.access_entries_enabled ? toset(var.cluster_admin_arns) : toset([])

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = each.value
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin]
}

# --- Managed node group role ---
# No entry here. EKS creates and manages an EC2_LINUX entry for a managed node
# group's role itself on an access-entry-enabled cluster, and a second one for
# the same principal fails the apply. Karpenter's role below is different: those
# instances are not a managed node group, so nothing creates its entry for us.

# --- Karpenter node role ---
# Always an entry (never aws-auth): the instances do not exist at apply time.

resource "aws_eks_access_entry" "karpenter_nodes" {
  count = var.karpenter_enabled ? 1 : 0

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.karpenter_nodes[0].arn
  type          = "EC2_LINUX"

  tags = local.common_tags
}
