# Pod network isolation via VPC CNI custom networking.
#
# Pods draw IPs from a non-routed secondary CIDR (RFC 6598 100.64.0.0/10)
# rather than the routable VPC CIDR, so pod churn never consumes routable
# address space and peered/on-prem networks don't have to account for pod IPs.
# The mechanism: attach a secondary CIDR to the VPC, carve a pod subnet per AZ,
# and publish an ENIConfig per AZ that tells the CNI which subnet + security
# group to use for the secondary ENIs it attaches to nodes.
#
# Every resource here is gated so that with pod_isolation_enabled = false the
# whole feature disappears — no secondary CIDR, no pod subnets, no ENIConfigs —
# and pods fall back to node-subnet IPs.

locals {
  # The module provisions the pod subnets only when it owns the VPC, isolation
  # is on, AND the caller hasn't supplied their own. A shared-VPC consumer never
  # creates subnets, so the secondary CIDR and pod subnets there always come
  # from the owner; we just point ENIConfigs at the supplied subnet IDs.
  pod_owns = var.create_vpc && var.pod_isolation_enabled && length(var.pod_subnet_ids) == 0

  # The subnets the CNI actually places pods in, regardless of who owns them.
  pod_subnet_ids_effective = local.pod_owns ? aws_subnet.pod[*].id : var.pod_subnet_ids

  # Pod source ranges for security-group rules. When the module owns the
  # subnets we know the CIDRs directly; when they are supplied (BYO / shared
  # VPC) the real CIDRs are read back from the API so the rule matches the
  # owner's actual pod subnets rather than assuming the default secondary range.
  pod_cidr_blocks = !var.pod_isolation_enabled ? [] : (
    local.pod_owns ? var.pod_subnet_cidrs : [
      for id in local.pod_subnet_ids_effective : data.aws_subnet.pod[id].cidr_block
    ]
  )

  # ENIConfig name must equal the node's topology.kubernetes.io/zone label, so
  # each pod subnet has to be keyed by its AZ. When the module carves the
  # subnets it knows them in local.azs order; when they are supplied the IDs are
  # opaque, so each one's AZ is read back from the API.
  pod_subnet_az = !var.pod_isolation_enabled ? {} : (local.pod_owns ? {
    # Iterate the pod subnets themselves (one per pod_subnet_cidrs entry), keyed
    # by the AZ each was created in (local.azs[idx], matching aws_subnet.pod).
    # Iterating local.azs instead would index past the created subnets in a
    # layout that uses fewer than length(local.azs) zones.
    for idx, id in local.pod_subnet_ids_effective : local.azs[idx] => id
    } : {
    for id in local.pod_subnet_ids_effective : data.aws_subnet.pod[id].availability_zone => id
  })

  # One ENIConfig per AZ, keyed by AZ name (the CNI matches ENIConfig name to
  # the node's topology.kubernetes.io/zone label, see ENI_CONFIG_LABEL_DEF).
  eniconfig_yaml = var.pod_isolation_enabled ? {
    for az, subnet_id in local.pod_subnet_az : az => yamlencode({
      apiVersion = "crd.k8s.amazonaws.com/v1alpha1"
      kind       = "ENIConfig"
      metadata = {
        name = az
      }
      spec = {
        # Pod secondary ENIs carry the dedicated node SG when enabled, otherwise
        # the EKS-managed cluster SG (see local.node_workload_sg_id). Both give
        # pods node-equivalent connectivity.
        subnet         = subnet_id
        securityGroups = [local.node_workload_sg_id]
      }
    })
  } : {}
}

# Secondary CIDR for pod IPs. Only created when the module owns the pod
# subnets; BYO callers attach their own secondary CIDR out of band.
resource "aws_vpc_ipv4_cidr_block_association" "pods" {
  count      = local.pod_owns ? 1 : 0
  vpc_id     = local.vpc_id
  cidr_block = var.pod_secondary_cidr
}

# Pod subnets, one per AZ, carved from the secondary CIDR. Tagged for cluster
# discovery but with no LB role tag — load balancers never belong here.
resource "aws_subnet" "pod" {
  count             = local.pod_owns ? length(var.pod_subnet_cidrs) : 0
  vpc_id            = local.vpc_id
  cidr_block        = var.pod_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(
    local.common_tags,
    {
      Name                                                = "subnet-pod-${local.name_prefix}-${local.azs[count.index]}"
      "kubernetes.io/cluster/${local.resource_names.eks}" = "shared"
    }
  )

  # The subnet's CIDR comes from the association above; create it first or the
  # subnet create races the CIDR being recognized on the VPC.
  depends_on = [aws_vpc_ipv4_cidr_block_association.pods]
}

# Pod subnets route like the node subnets (egress via NAT / TGW), so they share
# the private route tables. Per-AZ association keeps the single-NAT collapse to
# table index 0 consistent with the node associations.
resource "aws_route_table_association" "pod" {
  count          = local.pod_owns ? length(aws_subnet.pod) : 0
  subnet_id      = aws_subnet.pod[count.index].id
  route_table_id = aws_route_table.private[(local.nat_enabled && var.single_nat_gateway) ? 0 : count.index].id
}

# ENIConfig CRDs consumed by the VPC CNI. Applied after the vpc-cni addon so
# the CRD type exists before we create instances of it.
resource "kubectl_manifest" "eniconfig" {
  for_each = var.pod_isolation_enabled ? local.eniconfig_yaml : {}

  yaml_body = each.value

  depends_on = [aws_eks_addon.vpc_cni]
}
