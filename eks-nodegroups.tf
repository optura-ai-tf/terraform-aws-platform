# EKS Managed Node Groups
resource "aws_eks_node_group" "main" {
  for_each = var.node_groups

  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${each.key}-${local.name_prefix}"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = local.node_subnet_ids

  # Instance configuration
  instance_types = each.value.instance_types
  disk_size      = each.value.disk_size
  ami_type       = try(each.value.ami_type, null)

  # Per-group AMI pin; must be valid for the group's ami_type. null = EKS latest
  # at launch only — unset tracks no drift, so no auto-patching until pinned.
  # Intentionally NOT in ignore_changes: Terraform owns the pin so a bump rolls.
  release_version = try(each.value.release_version, null)

  # Scaling configuration
  scaling_config {
    desired_size = each.value.desired_size
    min_size     = each.value.min_size
    max_size     = each.value.max_size
  }

  # Update configuration
  update_config {
    max_unavailable_percentage = 33
  }

  # Labels
  labels = merge(
    each.value.labels,
    {
      "node-group" = each.key
    }
  )

  # Taints
  dynamic "taint" {
    for_each = each.value.taints
    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  tags = merge(
    local.common_tags,
    {
      Name                                                     = "${each.key}-${local.name_prefix}"
      "k8s.io/cluster-autoscaler/${aws_eks_cluster.main.name}" = "owned"
      "k8s.io/cluster-autoscaler/enabled"                      = "true"
    }
  )

  lifecycle {
    create_before_destroy = false
    ignore_changes        = [scaling_config[0].desired_size]
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_container_registry_policy,
    # ENIConfigs must exist before nodes launch, otherwise pods come up on
    # node-subnet IPs and never migrate to the isolated pod subnets. No-op
    # when pod isolation is disabled (the resource expands to nothing).
    kubectl_manifest.eniconfig,
  ]
}
