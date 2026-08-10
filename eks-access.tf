# ===================================================================
# EKS Cluster Access Control via aws-auth ConfigMap
# ===================================================================
#
# This module manages IAM principal access to the EKS cluster using
# the aws-auth ConfigMap (standard approach for EKS).
#
# Usage:
#   Set var.cluster_admin_arns to a list of IAM user/role ARNs.
#   Each principal will be granted cluster-admin access (system:masters).
#
# Example in tfvars:
#   # IAM users and roles
#   cluster_admin_arns = [
#     "arn:aws:iam::123456789012:user/alice",
#     "arn:aws:iam::123456789012:role/DevOpsTeam"
#   ]
#
#   # AWS SSO (IAM Identity Center) roles
#   cluster_admin_arns = [
#     "arn:aws:iam::123456789012:role/aws-reserved/sso.amazonaws.com/us-east-1/AWSReservedSSO_AdministratorAccess_abc123"
#   ]
#
# For AWS SSO setup, see: AWS_SSO_SETUP.md
#
# Important Notes:
# - The IAM principal that creates the cluster (terraform apply) gets
#   implicit system:masters access and does NOT need to be in this list
# - Empty list (default) = no additional admins beyond cluster creator
# - Uses aws-auth ConfigMap in kube-system namespace
#
# ===================================================================

# Create aws-auth ConfigMap with node groups and additional admins
resource "kubernetes_config_map_v1_data" "aws_auth" {
  force = true

  metadata {
    name      = "aws-auth"
    namespace = "kube-system"
  }

  data = {
    mapRoles = yamlencode(concat(
      # Node group IAM role mapping (required for nodes to join)
      [{
        rolearn  = aws_iam_role.eks_nodes.arn
        username = "system:node:{{EC2PrivateDNSName}}"
        groups = [
          "system:bootstrappers",
          "system:nodes"
        ]
      }],
      # Additional admin roles/users
      [
        for arn in var.cluster_admin_arns : {
          rolearn  = arn
          username = split("/", arn)[length(split("/", arn)) - 1]
          groups   = ["system:masters"]
        }
      ]
    ))
  }

  depends_on = [
    aws_eks_cluster.main,
    aws_eks_addon.coredns,
    aws_eks_addon.kube_proxy,
    aws_eks_addon.vpc_cni
  ]
}
