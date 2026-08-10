# ===== EKS Cluster IAM Role =====

resource "aws_iam_role" "eks_cluster" {
  name = "eks-cluster-${local.name_prefix}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

resource "aws_iam_role_policy_attachment" "eks_vpc_resource_controller" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
  role       = aws_iam_role.eks_cluster.name
}

# ===== EKS Node Group IAM Role =====

resource "aws_iam_role" "eks_nodes" {
  name = "eks-node-group-${local.name_prefix}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_nodes.name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_nodes.name
}

resource "aws_iam_role_policy_attachment" "eks_container_registry_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_nodes.name
}

resource "aws_iam_role_policy_attachment" "eks_ssm_managed_instance_core" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.eks_nodes.name
}

# ===== OIDC Provider for IRSA =====

data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer

  tags = local.common_tags
}

# ===== AWS Load Balancer Controller IAM Role (IRSA) =====

data "aws_iam_policy_document" "aws_lb_controller_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "aws_lb_controller" {
  count              = var.install_aws_lb_controller ? 1 : 0
  name               = "eks-aws-lb-controller-${local.name_prefix}"
  assume_role_policy = data.aws_iam_policy_document.aws_lb_controller_assume_role.json

  tags = local.common_tags
}

# Fetch AWS Load Balancer Controller IAM policy from official source
data "http" "aws_lb_controller_policy" {
  count = var.install_aws_lb_controller ? 1 : 0
  url   = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json"
}

resource "aws_iam_policy" "aws_lb_controller" {
  count       = var.install_aws_lb_controller ? 1 : 0
  name        = "AWSLoadBalancerController-${local.name_prefix}"
  description = "IAM policy for AWS Load Balancer Controller"

  policy = data.http.aws_lb_controller_policy[0].response_body
}

resource "aws_iam_role_policy_attachment" "aws_lb_controller" {
  count      = var.install_aws_lb_controller ? 1 : 0
  policy_arn = aws_iam_policy.aws_lb_controller[0].arn
  role       = aws_iam_role.aws_lb_controller[0].name
}

# ===== EBS CSI Driver IAM Role (IRSA) =====

data "aws_iam_policy_document" "ebs_csi_driver_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi_driver" {
  name               = "eks-ebs-csi-driver-${local.name_prefix}"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_driver_assume_role.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi_driver" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.ebs_csi_driver.name
}

# ===== Cluster Autoscaler IAM Role (IRSA) =====

data "aws_iam_policy_document" "cluster_autoscaler_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:cluster-autoscaler"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster_autoscaler" {
  name               = "eks-cluster-autoscaler-${local.name_prefix}"
  assume_role_policy = data.aws_iam_policy_document.cluster_autoscaler_assume_role.json

  tags = local.common_tags
}

data "aws_iam_policy_document" "cluster_autoscaler" {
  statement {
    sid    = "ClusterAutoscalerAll"
    effect = "Allow"

    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeScalingActivities",
      "ec2:DescribeImages",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:GetInstanceTypesFromInstanceRequirements",
      "eks:DescribeNodegroup"
    ]

    resources = ["*"]
  }

  statement {
    sid    = "ClusterAutoscalerOwn"
    effect = "Allow"

    actions = [
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup"
    ]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/${aws_eks_cluster.main.name}"
      values   = ["owned"]
    }
  }
}

resource "aws_iam_policy" "cluster_autoscaler" {
  name        = "EKSClusterAutoscaler-${local.name_prefix}"
  description = "IAM policy for EKS Cluster Autoscaler"

  policy = data.aws_iam_policy_document.cluster_autoscaler.json
}

resource "aws_iam_role_policy_attachment" "cluster_autoscaler" {
  policy_arn = aws_iam_policy.cluster_autoscaler.arn
  role       = aws_iam_role.cluster_autoscaler.name
}

# ===== Teleport Database Agent IAM Role (IRSA) =====

data "aws_iam_policy_document" "teleport_db_agent_assume_role" {
  count = var.access_mode == "teleport" && var.teleport_db_enabled && var.rds_enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:teleport-agent:teleport-kube-agent"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "teleport_db_agent" {
  count              = var.access_mode == "teleport" && var.teleport_db_enabled && var.rds_enabled ? 1 : 0
  name               = "eks-teleport-db-agent-${local.name_prefix}"
  assume_role_policy = data.aws_iam_policy_document.teleport_db_agent_assume_role[0].json

  tags = local.common_tags
}

data "aws_iam_policy_document" "teleport_db_agent_rds" {
  count = var.access_mode == "teleport" && var.teleport_db_enabled && var.rds_enabled ? 1 : 0

  statement {
    sid    = "RDSIAMAuth"
    effect = "Allow"

    actions = ["rds-db:connect"]

    # Grant rds-db:connect on every database in var.databases (RDS instances
    # and Aurora clusters alike) so the Teleport DB agent can authenticate to
    # non-core databases (e.g. "temporal") via IAM. local.db_resource_ids
    # normalizes aws_db_instance.resource_id and aws_rds_cluster.cluster_resource_id
    # into one map. Without this, only "core" would be reachable.
    resources = [
      for k, rid in local.db_resource_ids :
      "arn:aws:rds-db:${var.region}:${data.aws_caller_identity.current.account_id}:dbuser:${rid}/*"
    ]
  }
}

resource "aws_iam_policy" "teleport_db_agent_rds" {
  count       = var.access_mode == "teleport" && var.teleport_db_enabled && var.rds_enabled ? 1 : 0
  name        = "TeleportDBAgentRDS-${local.name_prefix}"
  description = "IAM policy for Teleport database agent RDS IAM authentication"

  policy = data.aws_iam_policy_document.teleport_db_agent_rds[0].json
}

resource "aws_iam_role_policy_attachment" "teleport_db_agent_rds" {
  count      = var.access_mode == "teleport" && var.teleport_db_enabled && var.rds_enabled ? 1 : 0
  policy_arn = aws_iam_policy.teleport_db_agent_rds[0].arn
  role       = aws_iam_role.teleport_db_agent[0].name
}
