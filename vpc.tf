locals {
  # NAT gateways and the public tier only make sense when egress goes through a
  # module-owned NAT. Both compose with the existing create_vpc / enable_nat_gateway
  # toggles so prior behavior is unchanged at the default egress_mode = "nat".
  egress_via_nat = var.egress_mode == "nat"
  nat_enabled    = var.create_vpc && local.egress_via_nat && var.enable_nat_gateway

  # The public tier (IGW, public subnets, public route table) is gated by
  # igw_enabled as a separate axis from create_vpc, so a module-owned VPC can be
  # built with no internet gateway at all.
  public_tier_enabled = var.create_vpc && var.igw_enabled

  # Canonical per-AZ count for module-owned tiers. node_subnet_cidrs is the
  # anchor every other tier's CIDR list is validated against (variables.tf), so
  # its length is the number of AZs in use. Per-AZ resources (NAT gateways, EIPs,
  # private route tables) must size from this rather than the AZ list — the AZ
  # list is fixed at the region's first 3 zones, so a layout with fewer subnets
  # would otherwise plan 3 NAT gateways against only 2 public subnets and fail
  # apply.
  az_count = length(var.node_subnet_cidrs)
}

# VPC
resource "aws_vpc" "main" {
  count                = var.create_vpc ? 1 : 0
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(
    local.common_tags,
    {
      Name = local.resource_names.vpc
    }
  )
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  count  = local.public_tier_enabled ? 1 : 0
  vpc_id = aws_vpc.main[0].id

  tags = merge(
    local.common_tags,
    {
      Name = "igw-${local.name_prefix}"
    }
  )
}

# Public Subnets
resource "aws_subnet" "public" {
  count                   = local.public_tier_enabled ? length(var.public_subnet_cidrs) : 0
  vpc_id                  = aws_vpc.main[0].id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(
    local.common_tags,
    {
      Name                                                = "subnet-public-${local.name_prefix}-${local.azs[count.index]}"
      "kubernetes.io/role/elb"                            = "1"
      "kubernetes.io/cluster/${local.resource_names.eks}" = "shared"
    }
  )
}

# Node Subnets — EKS worker-node ENIs. Tagged for cluster discovery but NOT
# with an LB role tag, so the load balancer controller never places ELBs here.
resource "aws_subnet" "node" {
  count             = var.create_vpc ? length(var.node_subnet_cidrs) : 0
  vpc_id            = aws_vpc.main[0].id
  cidr_block        = var.node_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(
    local.common_tags,
    {
      Name                                                = "subnet-node-${local.name_prefix}-${local.azs[count.index]}"
      "kubernetes.io/cluster/${local.resource_names.eks}" = "shared"
    },
    # With no dedicated lb tier, internal LBs land in the node subnets, so carry
    # the role tag here for the load balancer controller's auto-discovery.
    var.lb_subnet_enabled ? {} : { "kubernetes.io/role/internal-elb" = "1" }
  )
}

# Internal load balancer subnets — small, dedicated address space so internal
# ALBs/NLBs never compete with worker nodes for IPs. The internal-elb role tag
# is what makes the load balancer controller pick these for internal schemes.
resource "aws_subnet" "lb" {
  count             = var.create_vpc && var.lb_subnet_enabled ? length(var.lb_subnet_cidrs) : 0
  vpc_id            = aws_vpc.main[0].id
  cidr_block        = var.lb_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(
    local.common_tags,
    {
      Name                              = "subnet-lb-${local.name_prefix}-${local.azs[count.index]}"
      "kubernetes.io/role/internal-elb" = "1"
      # The AWS Load Balancer Controller selects internal-LB subnets by the
      # intersection of the role tag (above) and the cluster discovery tag. The
      # role tag alone is not enough — without this the LB tier never passes
      # auto-discovery. Matches the public subnet tagging.
      "kubernetes.io/cluster/${local.resource_names.eks}" = "shared"
    }
  )
}

# Database Subnets
resource "aws_subnet" "database" {
  count             = var.create_vpc && var.rds_enabled ? length(var.database_subnet_cidrs) : 0
  vpc_id            = aws_vpc.main[0].id
  cidr_block        = var.database_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(
    local.common_tags,
    {
      Name = "subnet-database-${local.name_prefix}-${local.azs[count.index]}"
    }
  )
}

# Elastic IPs for NAT Gateways
resource "aws_eip" "nat" {
  count  = local.nat_enabled ? (var.single_nat_gateway ? 1 : local.az_count) : 0
  domain = "vpc"

  tags = merge(
    local.common_tags,
    {
      Name = "eip-nat-${local.name_prefix}-${count.index + 1}"
    }
  )

  depends_on = [aws_internet_gateway.main]
}

# NAT Gateways
resource "aws_nat_gateway" "main" {
  count         = local.nat_enabled ? (var.single_nat_gateway ? 1 : local.az_count) : 0
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(
    local.common_tags,
    {
      Name = "nat-${local.name_prefix}-${local.azs[count.index]}"
    }
  )

  depends_on = [aws_internet_gateway.main]
}

# Public Route Table
resource "aws_route_table" "public" {
  count  = local.public_tier_enabled ? 1 : 0
  vpc_id = aws_vpc.main[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main[0].id
  }

  tags = merge(
    local.common_tags,
    {
      Name = "rt-public-${local.name_prefix}"
    }
  )
}

# Public Route Table Associations
resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

# Private Route Tables
resource "aws_route_table" "private" {
  count  = var.create_vpc ? (local.nat_enabled && var.single_nat_gateway ? 1 : local.az_count) : 0
  vpc_id = aws_vpc.main[0].id

  # The default route is the egress selector. With NAT it targets this AZ's NAT
  # gateway; with a Transit Gateway it hairpins 0.0.0.0/0 through the customer
  # network; with "none" there is no default route at all (air-gapped).
  dynamic "route" {
    for_each = local.nat_enabled ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = var.single_nat_gateway ? aws_nat_gateway.main[0].id : aws_nat_gateway.main[count.index].id
    }
  }

  dynamic "route" {
    for_each = var.create_vpc && var.egress_mode == "transit_gateway" ? [1] : []
    content {
      cidr_block         = "0.0.0.0/0"
      transit_gateway_id = var.transit_gateway_id
    }
  }

  tags = merge(
    local.common_tags,
    {
      Name = "rt-private-${local.name_prefix}-${count.index + 1}"
    }
  )

  # A 0.0.0.0/0 route to a Transit Gateway is only valid once the VPC is attached;
  # without this the route can be created before the attachment exists.
  depends_on = [aws_ec2_transit_gateway_vpc_attachment.main]
}

# Node Route Table Associations (use the private/NAT-routed route tables)
resource "aws_route_table_association" "node" {
  count          = length(aws_subnet.node)
  subnet_id      = aws_subnet.node[count.index].id
  route_table_id = aws_route_table.private[(local.nat_enabled && var.single_nat_gateway) ? 0 : count.index].id
}

# Internal LB Route Table Associations (use the private/routable route tables).
# Internal ALBs/NLBs must reach corp over the Transit Gateway and corp must reach
# them, so the LB subnets share the routable tier's route tables (and thus its
# TGW routes) alongside the node subnets — they are not left on the local-only
# main route table.
resource "aws_route_table_association" "lb" {
  count          = length(aws_subnet.lb)
  subnet_id      = aws_subnet.lb[count.index].id
  route_table_id = aws_route_table.private[(local.nat_enabled && var.single_nat_gateway) ? 0 : count.index].id
}

# Database Route Table Associations (use private route tables)
resource "aws_route_table_association" "database" {
  count          = var.rds_enabled ? length(aws_subnet.database) : 0
  subnet_id      = aws_subnet.database[count.index].id
  route_table_id = aws_route_table.private[(local.nat_enabled && var.single_nat_gateway) ? 0 : count.index].id
}

# Database Subnet Group
resource "aws_db_subnet_group" "main" {
  count      = var.rds_enabled ? 1 : 0
  name       = "dbsubnet-${local.name_prefix}"
  subnet_ids = local.database_subnet_ids

  tags = merge(
    local.common_tags,
    {
      Name = "dbsubnet-${local.name_prefix}"
    }
  )
}
