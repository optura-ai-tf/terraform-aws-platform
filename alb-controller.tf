# AWS Load Balancer Controller via Helm
resource "helm_release" "aws_load_balancer_controller" {
  count = var.install_aws_lb_controller ? 1 : 0

  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = var.aws_lb_controller_version

  set = concat([
    {
      name  = "clusterName"
      value = aws_eks_cluster.main.name
    },
    {
      name  = "serviceAccount.create"
      value = "true"
    },
    {
      name  = "serviceAccount.name"
      value = "aws-load-balancer-controller"
    },
    {
      name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
      value = aws_iam_role.aws_lb_controller[0].arn
    },
    {
      name  = "region"
      value = var.region
    },
    {
      name  = "vpcId"
      value = local.vpc_id
    },
    {
      name  = "clusterSecretsPermissions.allowAllSecrets"
      value = "true"
    }
    ],
    # Soft affinity, not a hard nodeSelector: this controller had no placement
    # before, and clusters without a support node group must keep scheduling.
    local.support_node_affinity_set
  )

  depends_on = [
    aws_eks_node_group.main,
    aws_eks_addon.coredns,
  ]
}
