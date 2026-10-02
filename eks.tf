# EKS Cluster
resource "aws_eks_cluster" "main" {
  name     = local.resource_names.eks
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.kubernetes_version

  vpc_config {
    # Only the node subnets: EKS drops a cross-account control-plane ENI (one per
    # AZ) into every subnet listed here. The internal-LB subnets are a tight /28
    # and the AWS Load Balancer Controller discovers them by tag, not via this
    # config, so listing them here would just let control-plane ENIs consume LB
    # address space. Node subnets (/27) span all AZs and have room.
    # cluster_public_subnets_enabled adds the public subnets too (legacy layout)
    # so a pre-0.3 cluster built that way adopts with no subnet-set change.
    subnet_ids              = concat(local.node_subnet_ids, var.cluster_public_subnets_enabled ? aws_subnet.public[*].id : [])
    endpoint_private_access = true
    endpoint_public_access  = !var.private_cluster_enabled
    public_access_cidrs     = var.private_cluster_enabled ? null : (length(var.api_server_authorized_cidrs) > 0 ? var.api_server_authorized_cidrs : ["0.0.0.0/0"])
    security_group_ids      = [aws_security_group.eks_cluster_additional.id]
  }

  # CONFIG_MAP (default) keeps every existing cluster on aws-auth. Narrowing
  # this is rejected by AWS, so a cluster can move CONFIG_MAP ->
  # API_AND_CONFIG_MAP -> API but never back.
  access_config {
    authentication_mode = var.cluster_authentication_mode
  }

  # bootstrap_cluster_creator_admin_permissions is deliberately NOT set:
  # it is create-time only (ForceNew), so adding it to a cluster whose state
  # predates access_config can plan a REPLACEMENT of the live cluster. AWS
  # defaults it to true at create time, which is what we want anyway.
  lifecycle {
    ignore_changes = [access_config[0].bootstrap_cluster_creator_admin_permissions]
  }

  # Encryption configuration
  dynamic "encryption_config" {
    for_each = var.enable_cluster_encryption ? [1] : []
    content {
      provider {
        key_arn = aws_kms_key.eks[0].arn
      }
      resources = ["secrets"]
    }
  }

  # Enable control plane logging
  enabled_cluster_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler"
  ]

  tags = local.common_tags

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_vpc_resource_controller,
  ]
}

# CloudWatch Log Group for EKS cluster logs
resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/${local.resource_names.eks}/cluster"
  retention_in_days = var.environment == "prod" ? 30 : 7

  tags = local.common_tags
}
