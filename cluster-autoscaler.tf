# Cluster Autoscaler via Helm
resource "helm_release" "cluster_autoscaler" {
  count = var.install_cluster_autoscaler ? 1 : 0

  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  namespace  = "kube-system"
  version    = var.cluster_autoscaler_version

  set = concat([
    {
      name  = "autoDiscovery.clusterName"
      value = aws_eks_cluster.main.name
    },
    {
      name  = "awsRegion"
      value = var.region
    },
    {
      name  = "rbac.serviceAccount.create"
      value = "true"
    },
    {
      name  = "rbac.serviceAccount.name"
      value = "cluster-autoscaler"
    },
    {
      name  = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
      value = aws_iam_role.cluster_autoscaler.arn
    },
    {
      name  = "extraArgs.balance-similar-node-groups"
      value = "true"
    },
    {
      name  = "extraArgs.skip-nodes-with-system-pods"
      value = "false"
    }
    ],
    # Node scheduling — prefer support nodes (shared with teleport-kube-agent)
    local.support_node_affinity_set,
  )

  depends_on = [
    aws_eks_node_group.main,
    aws_eks_addon.coredns,
    aws_iam_role.cluster_autoscaler
  ]
}
