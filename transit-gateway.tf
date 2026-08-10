# Transit Gateway VPC Attachment (opt-in)
#
# Attaches this VPC to a centrally-managed Transit Gateway (typically shared via
# AWS RAM) so EKS nodes and RDS can reach other VPCs / on-prem networks without
# VPC peering. Entirely off by default: with transit_gateway_id = null, this
# file creates zero resources.
#
# Routes and security-group ingress rules are created per destination CIDR in
# var.transit_gateway_cidr_blocks. Both use for_each (not count) so adding or
# removing a CIDR only touches the affected entries — no index churn across the
# rest of the set.

locals {
  tgw_enabled = var.transit_gateway_id != null

  # The attachment and routes are owner-side concerns in a RAM-shared VPC: the
  # owner attaches the VPC to the TGW and manages routing. A consumer still wants
  # the corp-CIDR ingress rules on its node/RDS security groups, so those stay
  # keyed off tgw_enabled while the attachment and routes additionally require
  # create_vpc.
  tgw_owns = local.tgw_enabled && var.create_vpc

  # The attachment lands its ENIs in the node subnets, never the pod subnets:
  # pod egress is SNAT'd to the node primary IP, so the corp side only ever sees
  # node-subnet source addresses and the pod CIDR is never attached or advertised.
  # Internal load balancers live in the node tier's routable space (see their
  # route-table association), so node + LB are reachable from corp; the pod
  # secondary CIDR and the database tier are not.
  tgw_subnet_ids = var.transit_gateway_subnet_ids != null ? var.transit_gateway_subnet_ids : local.node_subnet_ids

  # One route per (private route table, destination CIDR). The route table count
  # is variable-derived (known at plan time), so the for_each keys resolve at
  # plan time even though the route table IDs themselves are known after apply.
  tgw_routes = local.tgw_owns ? {
    for pair in setproduct(range(length(aws_route_table.private)), [
      # 0.0.0.0/0 is the egress default route, owned exclusively by egress_mode
      # via the inline route on each private RT (NAT in "nat" mode, TGW in
      # "transit_gateway" mode, and none at all in "none"/air-gapped mode).
      # tgw_routes carries only specific corp CIDRs and never the default route,
      # so drop any 0.0.0.0/0 entry unconditionally: in nat/transit_gateway modes
      # it would collide with the inline default and fail apply with a duplicate-
      # route error, and in "none" mode it would silently re-introduce a TGW
      # default route and defeat the air-gap that egress_mode = "none" promises.
      for cidr in var.transit_gateway_cidr_blocks : cidr
      if cidr != "0.0.0.0/0"
    ]) :
    "${pair[0]}:${pair[1]}" => {
      route_table_id = aws_route_table.private[pair[0]].id
      destination    = pair[1]
    }
  } : {}

  # Node ingress rules from the TGW CIDRs. With an empty transit_gateway_node_ingress
  # list (the default) we allow all traffic (protocol "-1") — one rule per CIDR,
  # keyed by CIDR. Otherwise one rule per (CIDR, port-range), keyed "<cidr>:<idx>",
  # so callers can restrict cross-VPC node access without churning the all-traffic keys.
  tgw_node_ingress = local.tgw_enabled ? (
    length(var.transit_gateway_node_ingress) == 0
    ? { for cidr in var.transit_gateway_cidr_blocks : cidr => {
      cidr      = cidr
      from_port = 0
      to_port   = 65535
      protocol  = "-1"
    } }
    : { for pair in setproduct(var.transit_gateway_cidr_blocks, range(length(var.transit_gateway_node_ingress))) :
      "${pair[0]}:${pair[1]}" => {
        cidr      = pair[0]
        from_port = var.transit_gateway_node_ingress[pair[1]].from_port
        to_port   = var.transit_gateway_node_ingress[pair[1]].to_port
        protocol  = var.transit_gateway_node_ingress[pair[1]].protocol
    } }
  ) : {}

  # One RDS ingress rule per (named database, destination CIDR). Reaching RDS
  # over the TGW is opt-in: app→DB traffic is in-VPC and admin access is via
  # Teleport, so the database tier stays closed to the corp network unless a
  # caller explicitly asks to expose it.
  tgw_rds_ingress = (local.tgw_enabled && var.rds_enabled && var.expose_database_to_transit_gateway) ? {
    for pair in setproduct(keys(var.databases), var.transit_gateway_cidr_blocks) :
    "${pair[0]}:${pair[1]}" => {
      db   = pair[0]
      cidr = pair[1]
    }
  } : {}
}

resource "aws_ec2_transit_gateway_vpc_attachment" "main" {
  count = local.tgw_owns ? 1 : 0

  transit_gateway_id = var.transit_gateway_id
  vpc_id             = local.vpc_id
  subnet_ids         = local.tgw_subnet_ids

  transit_gateway_default_route_table_association = var.transit_gateway_default_route_table_association
  transit_gateway_default_route_table_propagation = var.transit_gateway_default_route_table_propagation

  tags = merge(
    local.common_tags,
    {
      Name = "tgw-attach-${local.name_prefix}"
    }
  )
}

# Routes from the private (and database, which share them) route tables to the
# TGW for each destination CIDR.
resource "aws_route" "private_to_tgw" {
  for_each = local.tgw_routes

  route_table_id         = each.value.route_table_id
  destination_cidr_block = each.value.destination
  transit_gateway_id     = var.transit_gateway_id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.main]
}
