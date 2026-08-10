# EKS Cluster Security Group (additional rules)
resource "aws_security_group" "eks_cluster_additional" {
  name        = "eks-cluster-${local.name_prefix}"
  description = "Additional security group for EKS cluster ${local.resource_names.eks}"
  vpc_id      = local.vpc_id

  tags = merge(
    local.common_tags,
    {
      Name = "sg-eks-cluster-${local.name_prefix}"
    }
  )
}

locals {
  # Security group that pod ENIs (custom networking) and TGW node ingress attach
  # to. With the dedicated node SG enabled (default) that is aws_security_group.
  # eks_nodes; otherwise it is the EKS-managed cluster SG that EKS already
  # attaches to every node. one() tolerates the count = 0 (disabled) case without
  # an index-out-of-range error.
  node_workload_sg_id = var.dedicated_node_sg_enabled ? one(aws_security_group.eks_nodes[*].id) : aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}

# EKS Node Security Group (additional rules). Optional: EKS already attaches the
# managed cluster SG to every node, so this dedicated SG is only meaningful when
# it is also placed on pod ENIs via custom networking (see pod-networking.tf).
# Disable with dedicated_node_sg_enabled = false to fall back to the cluster SG.
resource "aws_security_group" "eks_nodes" {
  count       = var.dedicated_node_sg_enabled ? 1 : 0
  name        = "eks-nodes-${local.name_prefix}"
  description = "Security group for EKS worker nodes"
  vpc_id      = local.vpc_id

  tags = merge(
    local.common_tags,
    {
      Name                                                = "sg-eks-nodes-${local.name_prefix}"
      "kubernetes.io/cluster/${local.resource_names.eks}" = "owned"
    }
  )
}

# Node to node communication
resource "aws_security_group_rule" "nodes_internal" {
  count                    = var.dedicated_node_sg_enabled ? 1 : 0
  description              = "Allow nodes to communicate with each other"
  type                     = "ingress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "-1"
  security_group_id        = aws_security_group.eks_nodes[0].id
  source_security_group_id = aws_security_group.eks_nodes[0].id
}

# Allow nodes to reach EKS cluster
resource "aws_security_group_rule" "nodes_to_cluster" {
  count                    = var.dedicated_node_sg_enabled ? 1 : 0
  description              = "Allow worker nodes to communicate with cluster API"
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_cluster_additional.id
  source_security_group_id = aws_security_group.eks_nodes[0].id
}

# Allow an in-VPC bastion / CI runner (or a corp network reaching in over
# DX/VPN) to reach the private API endpoint on 443. Only for a private cluster:
# with the public endpoint off, the module otherwise opens 443 to the node SG
# alone, so a runner that isn't a node is dropped at this SG. No-op when
# private_network_access_cidrs is empty.
resource "aws_security_group_rule" "private_network_access" {
  count             = var.private_cluster_enabled && length(var.private_network_access_cidrs) > 0 ? 1 : 0
  description       = "Allow private network CIDRs to reach the EKS API"
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = var.private_network_access_cidrs
  security_group_id = aws_security_group.eks_cluster_additional.id
}

# Allow cluster to reach nodes
resource "aws_security_group_rule" "cluster_to_nodes" {
  count                    = var.dedicated_node_sg_enabled ? 1 : 0
  description              = "Allow cluster API to communicate with worker nodes"
  type                     = "ingress"
  from_port                = 1025
  to_port                  = 65535
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_nodes[0].id
  source_security_group_id = aws_security_group.eks_cluster_additional.id
}

# Allow nodes egress to internet
resource "aws_security_group_rule" "nodes_egress" {
  count             = var.dedicated_node_sg_enabled ? 1 : 0
  description       = "Allow nodes outbound communication"
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.eks_nodes[0].id
}

# Allow pods to scrape the kubelet on :10250 (metrics-server, HPAs).
# Under custom networking the dedicated node SG (eks_nodes) is attached to pod
# ENIs, but the kubelet listens on the node's PRIMARY ENI, which carries the
# EKS-managed cluster SG — not eks_nodes. So the nodes_internal self-rule does
# NOT cover pod->kubelet across nodes: metrics-server can only reach the kubelet
# on its own node, every other scrape times out, and all HPAs read <unknown>
# (ScalingActive=False). This rule opens 10250 on the cluster SG from the pod SG.
# Gated on both flags: only meaningful when pods are isolated onto eks_nodes
# (custom networking + dedicated SG). No-op otherwise — clusters where pods share
# the cluster SG already have this path.
resource "aws_security_group_rule" "kubelet_from_pod_sg" {
  count                    = var.dedicated_node_sg_enabled && var.pod_isolation_enabled ? 1 : 0
  description              = "Allow pods (dedicated node SG on pod ENIs) to scrape kubelet :10250"
  type                     = "ingress"
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
  security_group_id        = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  source_security_group_id = aws_security_group.eks_nodes[0].id
}

# RDS Security Group (per named database)
resource "aws_security_group" "rds" {
  for_each = var.rds_enabled ? var.databases : {}
  name     = "rds-${local.name_prefix}${local.db_name_suffix[each.key]}"
  # `description` is ForceNew on aws_security_group — keep the legacy
  # wording for "core" so existing deployments are not replaced (which would
  # cascade-replace the three SG rules via their ForceNew security_group_id).
  description = each.key == "core" ? "Security group for RDS PostgreSQL" : "Security group for RDS PostgreSQL (${each.key})"
  vpc_id      = local.vpc_id

  tags = merge(
    local.common_tags,
    {
      Name = "sg-rds-${local.name_prefix}${local.db_name_suffix[each.key]}"
    }
  )
}

# Allow PostgreSQL access from EKS nodes (for management/debugging). Only with
# the dedicated node SG; without it, node-originated RDS traffic is covered by
# rds_from_vpc (nodes carry routable VPC-CIDR IPs).
resource "aws_security_group_rule" "rds_from_eks_nodes" {
  for_each                 = var.dedicated_node_sg_enabled && var.rds_enabled ? var.databases : {}
  description              = "Allow PostgreSQL access from EKS nodes"
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds[each.key].id
  source_security_group_id = aws_security_group.eks_nodes[0].id
}

# Allow PostgreSQL access from the routable VPC CIDR. Covers node-subnet
# sources and, when pod isolation is off, pods that share node-subnet IPs.
resource "aws_security_group_rule" "rds_from_vpc" {
  for_each          = var.rds_enabled ? var.databases : {}
  description       = "Allow PostgreSQL access from within the VPC"
  type              = "ingress"
  from_port         = 5432
  to_port           = 5432
  protocol          = "tcp"
  security_group_id = aws_security_group.rds[each.key].id
  cidr_blocks       = [local.vpc_cidr_block]
}

# With pod isolation on, pods carry IPs from the non-routed secondary CIDR
# instead of the VPC CIDR, so the rule above does not cover them. Open the
# pod range explicitly. Created only when pods are isolated and routing to RDS.
resource "aws_security_group_rule" "rds_from_pods" {
  for_each          = var.rds_enabled && var.pod_isolation_enabled ? var.databases : {}
  description       = "Allow PostgreSQL access from isolated pod subnets"
  type              = "ingress"
  from_port         = 5432
  to_port           = 5432
  protocol          = "tcp"
  security_group_id = aws_security_group.rds[each.key].id
  cidr_blocks       = local.pod_cidr_blocks
}

# RDS egress (restricted to VPC CIDR for security)
resource "aws_security_group_rule" "rds_egress" {
  for_each          = var.rds_enabled ? var.databases : {}
  description       = "Allow RDS outbound communication within VPC"
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = [local.vpc_cidr_block]
  security_group_id = aws_security_group.rds[each.key].id
}

# Allow ingress from Transit Gateway network CIDRs to EKS nodes.
# Keyed by CIDR (see local.tgw_node_ingress in transit-gateway.tf) so adding a
# CIDR doesn't reshuffle existing rules.
resource "aws_security_group_rule" "nodes_from_tgw" {
  for_each          = local.tgw_node_ingress
  description       = "Allow traffic from TGW network ${each.value.cidr}"
  type              = "ingress"
  from_port         = each.value.from_port
  to_port           = each.value.to_port
  protocol          = each.value.protocol
  cidr_blocks       = [each.value.cidr]
  security_group_id = local.node_workload_sg_id
}

# Allow ingress from Transit Gateway network CIDRs to each RDS instance.
# Keyed by "<database>:<cidr>" (see local.tgw_rds_ingress in transit-gateway.tf).
resource "aws_security_group_rule" "rds_from_tgw" {
  for_each          = local.tgw_rds_ingress
  description       = "Allow PostgreSQL from TGW network ${each.value.cidr}"
  type              = "ingress"
  from_port         = 5432
  to_port           = 5432
  protocol          = "tcp"
  cidr_blocks       = [each.value.cidr]
  security_group_id = aws_security_group.rds[each.value.db].id
}

# VPC Endpoint Security Group. Created only with the interface endpoints it
# protects — i.e. only when the module owns the VPC (see vpc-endpoints.tf).
resource "aws_security_group" "vpc_endpoints" {
  count       = var.create_vpc && var.enable_vpc_endpoints ? 1 : 0
  name        = "vpc-endpoints-${local.name_prefix}"
  description = "Security group for VPC endpoints"
  vpc_id      = local.vpc_id

  # When pod isolation is on, pods carry IPs from the non-routed secondary CIDR
  # (local.pod_cidr_blocks), not the VPC CIDR. Interface endpoints (STS, ECR,
  # EC2) share this SG, so without the pod ranges every IRSA/STS call and ECR
  # pull from an isolated pod is dropped here before reaching the endpoint ENI.
  # local.pod_cidr_blocks is [] when isolation is off, so compact() degrades
  # this to the prior VPC-CIDR-only behavior.
  ingress {
    description = "HTTPS from VPC and isolated pod subnets"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = compact(concat([local.vpc_cidr_block], local.pod_cidr_blocks))
  }

  tags = merge(
    local.common_tags,
    {
      Name = "sg-vpc-endpoints-${local.name_prefix}"
    }
  )
}
