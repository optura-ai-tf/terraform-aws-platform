# VPC endpoints are provisioned only when the module owns the VPC
# (create_vpc = true). In consumer / RAM-shared mode the owner account controls
# the network and creates the endpoints it needs (S3 gateway + any interface
# endpoints) — the shared-vpc checklist says so. The module must not also create
# interface endpoints there: only one interface endpoint per service per VPC may
# have private DNS enabled, so an owner-created endpoint plus a module-created
# one would collide and fail apply. All endpoints below are gated on create_vpc.
resource "aws_vpc_endpoint" "s3" {
  count        = var.create_vpc && var.enable_vpc_endpoints ? 1 : 0
  vpc_id       = local.vpc_id
  service_name = "com.amazonaws.${var.region}.s3"

  # public route table exists only when the internet gateway is enabled; the
  # splat yields an empty list (not an index error) when there is no public tier.
  route_table_ids = concat(
    aws_route_table.public[*].id,
    aws_route_table.private[*].id
  )

  tags = merge(
    local.common_tags,
    {
      Name = "vpce-s3-${local.name_prefix}"
    }
  )
}

# ECR API VPC Endpoint (Interface type)
resource "aws_vpc_endpoint" "ecr_api" {
  count               = var.create_vpc && var.enable_vpc_endpoints ? 1 : 0
  vpc_id              = local.vpc_id
  service_name        = "com.amazonaws.${var.region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.node_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = merge(
    local.common_tags,
    {
      Name = "vpce-ecr-api-${local.name_prefix}"
    }
  )
}

# ECR DKR VPC Endpoint (Interface type)
resource "aws_vpc_endpoint" "ecr_dkr" {
  count               = var.create_vpc && var.enable_vpc_endpoints ? 1 : 0
  vpc_id              = local.vpc_id
  service_name        = "com.amazonaws.${var.region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.node_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = merge(
    local.common_tags,
    {
      Name = "vpce-ecr-dkr-${local.name_prefix}"
    }
  )
}

# EC2 VPC Endpoint (for EKS)
resource "aws_vpc_endpoint" "ec2" {
  count               = var.create_vpc && var.enable_vpc_endpoints ? 1 : 0
  vpc_id              = local.vpc_id
  service_name        = "com.amazonaws.${var.region}.ec2"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.node_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = merge(
    local.common_tags,
    {
      Name = "vpce-ec2-${local.name_prefix}"
    }
  )
}

# STS VPC Endpoint (for IAM role assumption)
resource "aws_vpc_endpoint" "sts" {
  count               = var.create_vpc && var.enable_vpc_endpoints ? 1 : 0
  vpc_id              = local.vpc_id
  service_name        = "com.amazonaws.${var.region}.sts"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.node_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = merge(
    local.common_tags,
    {
      Name = "vpce-sts-${local.name_prefix}"
    }
  )
}
