# ===================================================================
# Karpenter — IAM only (var.karpenter_enabled)
# ===================================================================
#
# Two identities:
#   controller  Pod Identity -> karpenter/karpenter ServiceAccount. Reads EC2
#               inventory, launches and terminates instances, passes the node
#               role to them.
#   nodes       Assumed by the EC2 instances Karpenter launches. Same four
#               managed policies an EKS worker always needs; joins via the
#               access entry in eks-access-entries.tf.
#
# The controller, NodePools and EC2NodeClasses live in the gitops repo. The
# EC2NodeClass references `spec.instanceProfile` (karpenter_node_instance_profile
# output) — the profile is created here, so the controller holds no
# iam:*InstanceProfile permissions.
# ===================================================================

locals {
  karpenter_count = var.karpenter_enabled ? 1 : 0

  pod_identity_agent_required = length(var.pod_identity_roles) > 0 || var.karpenter_enabled
}

# --- Node role: assumed by Karpenter-launched instances ---

resource "aws_iam_role" "karpenter_nodes" {
  count = local.karpenter_count

  name = "karpenter-node-${local.name_prefix}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = merge(local.common_tags, { Name = "karpenter-node-${local.name_prefix}" })
}

resource "aws_iam_role_policy_attachment" "karpenter_nodes" {
  for_each = var.karpenter_enabled ? toset(concat([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ], var.karpenter_node_role_additional_policies)) : toset([])

  role       = aws_iam_role.karpenter_nodes[0].name
  policy_arn = each.value
}

# EC2NodeClass `spec.instanceProfile`.
resource "aws_iam_instance_profile" "karpenter_nodes" {
  count = local.karpenter_count

  name = "karpenter-node-${local.name_prefix}"
  role = aws_iam_role.karpenter_nodes[0].name

  tags = local.common_tags
}

# --- Controller role: Pod Identity -> karpenter/karpenter ---

resource "aws_iam_role" "karpenter_controller" {
  count = local.karpenter_count

  name = "karpenter-controller-${local.name_prefix}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Condition = {
        ArnLike      = { "aws:SourceArn" = aws_eks_cluster.main.arn }
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })

  tags = merge(local.common_tags, { Name = "karpenter-controller-${local.name_prefix}" })
}

resource "aws_iam_policy" "karpenter_controller" {
  count = local.karpenter_count

  name        = "karpenter-controller-${local.name_prefix}"
  description = "Karpenter controller for ${local.name_prefix}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadEC2Inventory"
        Effect = "Allow"
        Action = [
          "ec2:DescribeImages",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeSubnets",
          "ec2:DescribeAvailabilityZones",
        ]
        Resource = "*"
      },
      {
        Sid    = "LaunchInstances"
        Effect = "Allow"
        Action = [
          "ec2:CreateFleet",
          "ec2:CreateLaunchTemplate",
          "ec2:RunInstances",
        ]
        Resource = "*"
      },
      {
        # Tagging is split from the launch actions so TerminateOwnedResources
        # below cannot be defeated: with a blanket ec2:CreateTags the controller
        # could stamp the ownership tag onto an unrelated instance and then
        # terminate it. RequestTag restricts this to stamping OUR cluster's tag,
        # and ec2:CreateAction to the moment of creation.
        Sid      = "TagOnCreate"
        Effect   = "Allow"
        Action   = ["ec2:CreateTags"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestTag/kubernetes.io/cluster/${aws_eks_cluster.main.name}" = "owned"
            "ec2:CreateAction"                                                  = ["RunInstances", "CreateFleet", "CreateLaunchTemplate"]
          }
        }
      },
      {
        # Re-tagging resources this cluster already owns (Karpenter updates
        # nodeclaim tags on drift).
        Sid      = "TagOwnedResources"
        Effect   = "Allow"
        Action   = ["ec2:CreateTags"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${aws_eks_cluster.main.name}" = "owned"
          }
        }
      },
      {
        # Scoped to resources this cluster owns: Karpenter tags everything it
        # creates with kubernetes.io/cluster/<name>=owned, so an unscoped
        # Terminate/Delete here could reach another cluster's nodes in a shared
        # account.
        Sid    = "TerminateOwnedResources"
        Effect = "Allow"
        Action = [
          "ec2:TerminateInstances",
          "ec2:DeleteLaunchTemplate",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${aws_eks_cluster.main.name}" = "owned"
          }
        }
      },
      {
        # Karpenter resolves the AMI for a NodeClass from the EKS-published SSM
        # parameters rather than hardcoding AMI IDs.
        Sid      = "ReadAMIParameters"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "pricing:GetProducts"]
        Resource = "*"
      },
      {
        Sid      = "ReadCluster"
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = aws_eks_cluster.main.arn
      },
      {
        # Handing the node role to an instance. Scoped to that one role so the
        # controller cannot bootstrap an instance as anything more privileged.
        Sid      = "PassNodeRole"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = aws_iam_role.karpenter_nodes[0].arn
        Condition = {
          StringEquals = { "iam:PassedToService" = "ec2.amazonaws.com" }
        }
      },
      {
        # Karpenter resolves an EC2NodeClass `spec.instanceProfile` by calling
        # GetInstanceProfile; without it the NodeClass never goes Ready. Scoped
        # to the one profile created here, so this stays read-only and the
        # controller still holds no instance-profile WRITE permissions.
        Sid      = "ReadNodeInstanceProfile"
        Effect   = "Allow"
        Action   = ["iam:GetInstanceProfile"]
        Resource = aws_iam_instance_profile.karpenter_nodes[0].arn
      },
      {
        # The instanceprofile.garbagecollection controller lists every profile
        # in the account each reconcile; iam:ListInstanceProfiles takes no
        # resource-level permissions, so it cannot be scoped. Read-only.
        Sid      = "ListInstanceProfiles"
        Effect   = "Allow"
        Action   = ["iam:ListInstanceProfiles"]
        Resource = "*"
      },
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "karpenter_controller" {
  count = local.karpenter_count

  role       = aws_iam_role.karpenter_controller[0].name
  policy_arn = aws_iam_policy.karpenter_controller[0].arn
}

resource "aws_eks_pod_identity_association" "karpenter_controller" {
  count = local.karpenter_count

  cluster_name    = aws_eks_cluster.main.name
  namespace       = "karpenter"
  service_account = "karpenter"
  role_arn        = aws_iam_role.karpenter_controller[0].arn

  tags = merge(local.common_tags, { Name = "karpenter-controller-${local.name_prefix}" })

  depends_on = [aws_eks_addon.pod_identity_agent]
}

# Forces the EKS access mode to support access entries (API or API_AND_CONFIG_MAP) for Karpenter to work.
resource "terraform_data" "karpenter_access_mode_guard" {
  count = local.karpenter_count

  lifecycle {
    precondition {
      condition     = var.cluster_authentication_mode != "CONFIG_MAP"
      error_message = "karpenter_enabled requires cluster_authentication_mode API or API_AND_CONFIG_MAP."
    }
  }
}
