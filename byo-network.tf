# Consumer mode for an externally-owned (RAM-shared) VPC.
#
# When the VPC is shared from another account, the owner account owns the VPC,
# its subnets, routing, IGW/NAT, and any TGW attachment. This module then only
# consumes subnet IDs and creates no network resources — the cluster, node
# groups, security groups, addons, RDS, and ENIConfigs are all still managed
# here. The owner is responsible for egress, peering, and on-prem reachability.

# Read the consumed VPC so CIDR-scoped security-group rules have a real CIDR
# without the caller having to restate it; in create mode the value comes from
# the module's own aws_vpc resource instead.
data "aws_vpc" "shared" {
  count = var.create_vpc ? 0 : 1
  id    = var.vpc_id
}

# Per-AZ ENIConfig needs each pod subnet's availability zone, and the RDS
# ingress rule needs each subnet's real CIDR. Whenever the pod subnets are
# supplied rather than module-created (BYO/shared VPC, or own-VPC-with-BYO-pods),
# their IDs are opaque, so read both attributes back from the API. Module-owned
# subnets need no lookup — the CIDRs and AZ ordering are known locally.
data "aws_subnet" "pod" {
  for_each = var.pod_isolation_enabled && !local.pod_owns ? toset(local.pod_subnet_ids_effective) : toset([])
  id       = each.value
}

# Consumer-mode node subnets are opaque IDs, so read their AZs back from the API
# to validate the cluster's AZ span (EKS needs >= 2) and that every node AZ has a
# matching pod subnet (ENIConfigs are keyed by AZ). Module-owned subnets use
# local.azs directly and need no lookup.
data "aws_subnet" "node" {
  for_each = var.create_vpc ? toset([]) : toset(var.node_subnet_ids)
  id       = each.value
}

locals {
  # The routable VPC CIDR, sourced from whichever side owns the VPC. Used by the
  # CIDR-scoped RDS/endpoint rules so they cover the whole VPC in both modes.
  vpc_cidr_block = var.create_vpc ? aws_vpc.main[0].cidr_block : data.aws_vpc.shared[0].cidr_block

  # Distinct AZs of the consumer-supplied node and pod subnets, read from the
  # API. Empty in create mode (subnets are module-owned and use local.azs).
  byo_node_azs = var.create_vpc ? [] : distinct([for id in var.node_subnet_ids : data.aws_subnet.node[id].availability_zone])
  byo_pod_azs = (var.create_vpc || local.pod_owns || !var.pod_isolation_enabled) ? [] : distinct([
    for id in local.pod_subnet_ids_effective : data.aws_subnet.pod[id].availability_zone
  ])
}

# Cross-variable invariants that single-variable validation blocks cannot
# express. Surfaced at plan time as preconditions so a misconfigured consumer
# mode fails fast and clearly rather than at apply against the cloud API.
resource "terraform_data" "network_mode_guard" {
  lifecycle {
    precondition {
      condition     = var.create_vpc || var.vpc_id != null
      error_message = "vpc_id is required when create_vpc = false (the ID of the shared VPC to consume)."
    }

    # cluster_public_subnets_enabled only has effect when the module owns a
    # public tier to add. Without this, setting it on a private (igw_enabled =
    # false) or consumer (create_vpc = false) VPC is a silent no-op.
    precondition {
      condition     = !var.cluster_public_subnets_enabled || (var.create_vpc && var.igw_enabled)
      error_message = "cluster_public_subnets_enabled = true requires create_vpc = true and igw_enabled = true (there must be a module-owned public subnet tier to add to the control-plane list)."
    }

    # In consumer mode the *_subnet_cidrs vars are unused, so node_subnet_ids —
    # not node_subnet_cidrs — is the per-AZ anchor every other tier matches. It
    # must be non-empty: anchoring to node_subnet_cidrs would let a caller who
    # zeroes the (unused) CIDR vars pass every length check with zero subnets,
    # planning the cluster/node groups with empty subnet_ids and failing at
    # apply with an opaque AWS error instead of here.
    precondition {
      condition     = var.create_vpc || length(var.node_subnet_ids) > 0
      error_message = "node_subnet_ids must list at least one subnet (one per AZ) when create_vpc = false — it is the per-AZ anchor every other tier is matched against."
    }

    # EKS requires the cluster's subnets to span at least two AZs. A single-AZ
    # node set passes the length checks above but fails at cluster create with an
    # opaque AWS error, so reject it here.
    precondition {
      condition     = var.create_vpc || length(local.byo_node_azs) >= 2
      error_message = "node_subnet_ids must span at least two availability zones when create_vpc = false (EKS requires a multi-AZ subnet set)."
    }

    precondition {
      condition     = var.create_vpc || !var.lb_subnet_enabled || length(var.lb_subnet_ids) == length(var.node_subnet_ids)
      error_message = "lb_subnet_ids must have one entry per node subnet (matching node_subnet_ids length) when create_vpc = false and lb_subnet_enabled = true."
    }

    precondition {
      condition     = var.create_vpc || !var.rds_enabled || length(var.database_subnet_ids) == length(var.node_subnet_ids)
      error_message = "database_subnet_ids must have one entry per node subnet (matching node_subnet_ids length) when create_vpc = false and rds_enabled = true."
    }

    precondition {
      condition     = var.create_vpc || !var.pod_isolation_enabled || length(var.pod_subnet_ids) == length(var.node_subnet_ids)
      error_message = "pod_subnet_ids must have one entry per node subnet (matching node_subnet_ids length) when create_vpc = false and pod_isolation_enabled = true."
    }

    # The create-mode subnet CIDRs and the consumer-mode subnet IDs are two
    # mutually exclusive ways to describe the network; supplying IDs in create
    # mode is a configuration mistake that would otherwise be silently ignored.
    precondition {
      condition     = !var.create_vpc || (length(var.node_subnet_ids) == 0 && length(var.lb_subnet_ids) == 0 && length(var.database_subnet_ids) == 0)
      error_message = "node_subnet_ids, lb_subnet_ids, and database_subnet_ids must be empty when create_vpc = true. Use the *_subnet_cidrs variables to size the module-owned subnets instead."
    }

    # NAT gateways live in the public subnets and route out through the IGW, so a
    # module-owned VPC cannot do NAT egress without the public tier. Disabling the
    # IGW requires a different egress path.
    precondition {
      condition     = !var.create_vpc || var.igw_enabled || var.egress_mode != "nat"
      error_message = "igw_enabled = false is incompatible with egress_mode = \"nat\": NAT gateways need a public subnet and an internet gateway. Use egress_mode = \"transit_gateway\" or \"none\" for a VPC with no internet gateway."
    }

    # egress_mode = "nat" with enable_nat_gateway = false builds private route
    # tables with no default route (nat_enabled becomes false, see vpc.tf), so
    # nodes silently lose internet/ECR/control-plane reachability with no error
    # at plan or apply. If NAT egress is unwanted, choose a different egress_mode
    # rather than disabling the gateway under "nat".
    precondition {
      condition     = !var.create_vpc || var.egress_mode != "nat" || var.enable_nat_gateway
      error_message = "egress_mode = \"nat\" requires enable_nat_gateway = true. To disable NAT egress use egress_mode = \"transit_gateway\" or \"none\"."
    }

    # The Transit Gateway default route has nowhere to point without an attachment.
    # Only enforced when the module owns routing; in consumer mode egress_mode is
    # unused (the owner account manages the route tables).
    precondition {
      condition     = !var.create_vpc || var.egress_mode != "transit_gateway" || var.transit_gateway_id != null
      error_message = "egress_mode = \"transit_gateway\" requires transit_gateway_id to be set (the TGW the 0.0.0.0/0 default route points at)."
    }

    # egress_mode = "none" is air-gapped (no default route), so the only path to
    # AWS APIs is VPC endpoints. With endpoints also disabled, nodes can't pull
    # the CNI/kube-proxy/CoreDNS images from ECR, register via EC2, or resolve
    # IRSA via STS — the cluster bootstraps but its addons never come ready.
    precondition {
      condition     = !var.create_vpc || var.egress_mode != "none" || var.enable_vpc_endpoints
      error_message = "egress_mode = \"none\" requires enable_vpc_endpoints = true: an air-gapped VPC has no internet path, so nodes need the ECR, EC2, and STS interface endpoints to pull images and obtain credentials."
    }

    # Supplied pod subnets must each be in a distinct AZ: the per-AZ ENIConfig map
    # is keyed by zone, so two subnets in the same AZ would silently collapse to
    # one ENIConfig and leave a zone unconfigured. Caught here with a clear message
    # rather than as an opaque duplicate-key error.
    precondition {
      condition = !var.pod_isolation_enabled || local.pod_owns || length(distinct([
        for id in local.pod_subnet_ids_effective : data.aws_subnet.pod[id].availability_zone
      ])) == length(local.pod_subnet_ids_effective)
      error_message = "Each supplied pod subnet must be in a distinct availability zone (one pod subnet per AZ)."
    }

    # ENIConfigs are keyed by pod-subnet AZ, so every AZ that runs nodes must
    # also have a pod subnet. A node in an AZ with no matching ENIConfig silently
    # falls back to node-subnet IPs, so isolation looks enabled but is broken for
    # those nodes. Require the node AZ set to be covered by the pod AZ set.
    precondition {
      condition = var.create_vpc || !var.pod_isolation_enabled || alltrue([
        for az in local.byo_node_azs : contains(local.byo_pod_azs, az)
      ])
      error_message = "Every availability zone with a node subnet must also have a pod subnet when create_vpc = false and pod_isolation_enabled = true (ENIConfigs are keyed by AZ; a node AZ with no pod subnet silently loses isolation)."
    }

    # Prefix delegation (cni_prefix_delegation_enabled) carves /28 blocks. With
    # pod_isolation_enabled = false, pods run in the node subnets rather than the
    # /23 pod subnets, and a default /27 node subnet fits at most one /28 —
    # WARM_PREFIX_TARGET = 1 pre-warms a prefix per ENI, so the CNI exhausts the
    # subnet and stalls with no error at plan or apply. Require node subnets of
    # at least /25 for that combination. Checks node_subnet_cidrs in create mode
    # and the read-back CIDRs of the supplied node subnets in consumer mode.
    precondition {
      condition = var.pod_isolation_enabled || !var.cni_prefix_delegation_enabled || alltrue([
        for c in(var.create_vpc ? var.node_subnet_cidrs : [for id in var.node_subnet_ids : data.aws_subnet.node[id].cidr_block]) :
        tonumber(split("/", c)[1]) <= 25
      ])
      error_message = "pod_isolation_enabled = false with cni_prefix_delegation_enabled = true requires node subnets of at least /25: prefix delegation carves /28 blocks and a /27 node subnet holds only one, so the VPC CNI exhausts the subnet and stalls. Either set cni_prefix_delegation_enabled = false, keep pod_isolation_enabled = true, or widen the node subnets to /25 or larger."
    }

    # Mirror of the guard above for the create_vpc = true + BYO-pod-subnets case
    # (pod_owns = false): node subnets are module-created in the first
    # length(node_subnet_cidrs) of local.azs, but the supplied pod subnets might
    # not cover all those AZs. data.aws_subnet.pod is populated here (its for_each
    # includes !pod_owns), so verify every module-owned node AZ has a pod subnet.
    precondition {
      condition = !var.create_vpc || local.pod_owns || !var.pod_isolation_enabled || alltrue([
        for az in slice(local.azs, 0, min(length(var.node_subnet_cidrs), length(local.azs))) :
        contains([for id in local.pod_subnet_ids_effective : data.aws_subnet.pod[id].availability_zone], az)
      ])
      error_message = "When pod_subnet_ids is supplied with create_vpc = true, every AZ used by the module-owned node subnets must also have a supplied pod subnet (ENIConfigs are keyed by AZ; an uncovered node AZ silently loses isolation)."
    }
  }
}
