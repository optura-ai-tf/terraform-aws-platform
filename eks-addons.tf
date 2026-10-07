# VPC CNI Add-on
#
# The CNI env is assembled from independent feature fragments so each toggle
# stands alone. Pod isolation adds the custom-networking keys that route pod
# ENIs onto the secondary-CIDR subnets named by the per-AZ ENIConfigs
# (ENI_CONFIG_LABEL_DEF matches an ENIConfig by the node's zone label). Prefix
# delegation adds ENABLE_PREFIX_DELEGATION on its own axis. With every fragment
# empty the CNI keeps its defaults, so configuration_values stays null.
locals {
  vpc_cni_env = merge(
    var.pod_isolation_enabled ? {
      AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG = "true"
      ENI_CONFIG_LABEL_DEF               = "topology.kubernetes.io/zone"
      # The isolation model relies on pods being SNAT'd to the node's primary
      # (routable) ENI IP when leaving the VPC, so corp/TGW paths only ever see
      # the node subnet range and never the non-routed 100.64 pod CIDR. "false"
      # is the CNI default (SNAT on), but it is load-bearing for that contract,
      # so pin it explicitly to guard against default drift or inherited config.
      AWS_VPC_K8S_CNI_EXTERNALSNAT = "false"
    } : {},
    var.cni_prefix_delegation_enabled ? {
      ENABLE_PREFIX_DELEGATION = "true"
      # Pre-warm one /28 prefix per ENI so the first pods on a freshly launched
      # node don't stall in ContainerCreating while the CNI allocates a prefix
      # on demand. AWS recommends WARM_PREFIX_TARGET = 1 as the conservative
      # minimum whenever prefix delegation is enabled.
      WARM_PREFIX_TARGET = "1"
    } : {},
  )

  # Resolve each add-on version once: an explicit pin from var.eks_addon_versions
  # wins; otherwise the most-recent version for the cluster's Kubernetes version.
  # (pod_identity_agent is resolved inline — its data source is count-gated.)
  addon_version = {
    coredns        = coalesce(lookup(var.eks_addon_versions, "coredns", null), data.aws_eks_addon_version.coredns.version)
    kube_proxy     = coalesce(lookup(var.eks_addon_versions, "kube_proxy", null), data.aws_eks_addon_version.kube_proxy.version)
    vpc_cni        = coalesce(lookup(var.eks_addon_versions, "vpc_cni", null), data.aws_eks_addon_version.vpc_cni.version)
    ebs_csi_driver = coalesce(lookup(var.eks_addon_versions, "ebs_csi_driver", null), data.aws_eks_addon_version.ebs_csi_driver.version)
    metrics_server = coalesce(lookup(var.eks_addon_versions, "metrics_server", null), data.aws_eks_addon_version.metrics_server.version)
  }
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "vpc-cni"
  addon_version               = local.addon_version.vpc_cni
  resolve_conflicts_on_update = "PRESERVE"

  configuration_values = length(local.vpc_cni_env) > 0 ? jsonencode({ env = local.vpc_cni_env }) : null

  tags = local.common_tags
}

data "aws_eks_addon_version" "vpc_cni" {
  addon_name         = "vpc-cni"
  kubernetes_version = aws_eks_cluster.main.version
  most_recent        = true
}

# CoreDNS Add-on
resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "coredns"
  addon_version               = local.addon_version.coredns
  resolve_conflicts_on_update = "PRESERVE"

  tags = local.common_tags

  depends_on = [
    aws_eks_node_group.main
  ]
}

data "aws_eks_addon_version" "coredns" {
  addon_name         = "coredns"
  kubernetes_version = aws_eks_cluster.main.version
  most_recent        = true
}

# kube-proxy Add-on
resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "kube-proxy"
  addon_version               = local.addon_version.kube_proxy
  resolve_conflicts_on_update = "PRESERVE"

  tags = local.common_tags
}

data "aws_eks_addon_version" "kube_proxy" {
  addon_name         = "kube-proxy"
  kubernetes_version = aws_eks_cluster.main.version
  most_recent        = true
}

# EBS CSI Driver Add-on
resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = local.addon_version.ebs_csi_driver
  service_account_role_arn    = aws_iam_role.ebs_csi_driver.arn
  resolve_conflicts_on_update = "PRESERVE"

  tags = local.common_tags

  depends_on = [
    aws_eks_node_group.main
  ]
}

data "aws_eks_addon_version" "ebs_csi_driver" {
  addon_name         = "aws-ebs-csi-driver"
  kubernetes_version = aws_eks_cluster.main.version
  most_recent        = true
}

# EKS Pod Identity Agent Add-on
# Enables workloads to assume IAM roles via Pod Identity Associations
# instead of static AWS access keys. The agent injects temporary credentials
# into pods via the default AWS credential chain.
resource "aws_eks_addon" "pod_identity_agent" {
  # karpenter_enabled creates its own Pod Identity association, so the agent is
  # required even when pod_identity_roles is empty.
  count = local.pod_identity_agent_required ? 1 : 0

  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "eks-pod-identity-agent"
  addon_version               = coalesce(lookup(var.eks_addon_versions, "pod_identity_agent", null), data.aws_eks_addon_version.pod_identity_agent[0].version)
  resolve_conflicts_on_update = "PRESERVE"

  tags = local.common_tags

  depends_on = [
    aws_eks_node_group.main
  ]
}

data "aws_eks_addon_version" "pod_identity_agent" {
  count              = local.pod_identity_agent_required ? 1 : 0
  addon_name         = "eks-pod-identity-agent"
  kubernetes_version = aws_eks_cluster.main.version
  most_recent        = true
}

# Metrics Server Add-on
resource "aws_eks_addon" "metrics_server" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "metrics-server"
  addon_version               = local.addon_version.metrics_server
  resolve_conflicts_on_update = "PRESERVE"

  # Prefer the platform workload tier (soft) — matches teleport-kube-agent /
  # cluster-autoscaler.
  configuration_values = jsonencode({
    affinity = {
      nodeAffinity = {
        preferredDuringSchedulingIgnoredDuringExecution = [{
          weight = 100
          preference = {
            matchExpressions = [{
              key      = "workload-type"
              operator = "In"
              values   = [var.platform_workload_type]
            }]
          }
        }]
      }
    }
    tolerations = [{
      key      = "workload-type"
      operator = "Equal"
      value    = var.platform_workload_type
      effect   = "NoSchedule"
    }]
  })

  tags = local.common_tags

  depends_on = [
    aws_eks_node_group.main
  ]
}

data "aws_eks_addon_version" "metrics_server" {
  addon_name         = "metrics-server"
  kubernetes_version = aws_eks_cluster.main.version
  most_recent        = true
}
