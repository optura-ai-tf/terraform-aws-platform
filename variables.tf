# ===== Global Configuration =====

variable "region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (dev, stg, uat, prod)"
  type        = string
  validation {
    condition     = contains(["dev", "stg", "uat", "prod"], var.environment)
    error_message = "Environment must be one of: 'dev', 'stg', 'uat', or 'prod'."
  }
}

variable "project_name" {
  description = "Project name used in resource naming"
  type        = string
  default     = "optura"
  validation {
    condition     = can(regex("^[a-z0-9-]{3,12}$", var.project_name))
    error_message = "Project name must be lowercase alphanumeric with hyphens, 3-12 characters."
  }
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default     = {}
}

variable "ignore_tag_keys" {
  description = <<-EOT
    Tag keys owned outside Terraform, ignored on every resource this module
    manages. default_tags makes Terraform the owner of each resource's whole
    tag map, so a key written by something else (AWS stamps aws-apn-id onto
    RDS instances for partner attribution) shows up as a deletion in every
    plan. Listing it here leaves it alone: never added, never removed.
    Empty (the default) ignores nothing.
  EOT
  type        = list(string)
  default     = []
}

# ===== Network Configuration =====

# When the VPC is shared from another account (AWS RAM / VPC Sharing), the owner
# account holds the VPC, subnets, route tables, IGW/NAT, and TGW attachment; this
# module must consume those subnet IDs and create no network resources of its own.
# create_vpc = false switches the module into that consumer mode. In create mode
# (the default) the *_subnet_ids vars stay empty and the module owns everything.
variable "create_vpc" {
  description = "Create the VPC and all network resources (true), or consume an externally-owned/shared VPC by ID and create no network resources (false). When false, supply vpc_id and the *_subnet_ids vars; the *_subnet_cidrs and egress/NAT/IGW/TGW settings are unused."
  type        = bool
  default     = true
}

variable "vpc_id" {
  description = "ID of an existing (typically RAM-shared) VPC to consume when create_vpc = false. Ignored when create_vpc = true."
  type        = string
  default     = null
}

variable "node_subnet_ids" {
  description = "Existing node subnet IDs (one per AZ) to consume when create_vpc = false. Ignored when create_vpc = true."
  type        = list(string)
  default     = []
}

variable "lb_subnet_ids" {
  description = "Existing internal load balancer subnet IDs (one per AZ) to consume when create_vpc = false. Ignored when create_vpc = true."
  type        = list(string)
  default     = []
}

variable "database_subnet_ids" {
  description = "Existing database subnet IDs (one per AZ) to consume when create_vpc = false and rds_enabled = true. Ignored when create_vpc = true."
  type        = list(string)
  default     = []
}

variable "vpc_cidr" {
  description = "Primary (routable) CIDR block for the VPC. Pods do not draw from this range when pod isolation is enabled — they live in var.pod_secondary_cidr — so the routable tier only needs room for node ENIs, load balancers, database ENIs, and VPC endpoints. A /24 holds the default layout (node /27 + lb/public/database /28 per AZ) with a spare /28; widen only if you disable pod isolation (pods then re-enter the node subnets) or run many nodes/AZ."
  type        = string
  default     = "10.0.0.0/24"
}

variable "node_subnet_cidrs" {
  description = "CIDR blocks for node subnets (one per AZ). EKS worker-node ENIs live here (roughly one primary IP per node), alongside the four interface VPC endpoint ENIs (ECR API, ECR DKR, EC2, STS — one each per AZ), the EKS control-plane cross-account ENIs (~2 per AZ), and secondary IPs for pods only when pod isolation is disabled. A /27 has 27 usable IPs (32 minus AWS's 5 reserved); after the ~6 endpoint + control-plane ENIs that leaves ~21 for actual worker nodes — comfortable for the default node groups with pod isolation on. Widen to /26 or larger if you run many nodes per AZ or disable pod isolation (pods then also draw from this tier)."
  type        = list(string)
  default     = ["10.0.0.0/27", "10.0.0.32/27", "10.0.0.64/27"]

  # node_subnet_cidrs is the per-AZ anchor (count of AZs the module deploys
  # into). EKS requires the cluster's subnets to span at least two AZs, so a
  # single-entry list is rejected at plan time rather than failing at cluster
  # create. Mirrors the consumer-mode `length(byo_node_azs) >= 2` guard.
  validation {
    condition     = length(var.node_subnet_cidrs) >= 2
    error_message = "node_subnet_cidrs must have at least 2 entries — EKS requires subnets in at least 2 availability zones."
  }

  # Every routable subnet must fall within vpc_cidr, mirroring the
  # pod_subnet_cidrs containment check against pod_secondary_cidr. Without it, a
  # caller who customizes vpc_cidr but leaves the default 10.0.x subnet CIDRs
  # gets an opaque AWS "range not in VPC" error at apply instead of a clear
  # plan-time failure. Containment requires the subnet be no larger than the VPC
  # (prefix >= vpc's) and, masked to the vpc's prefix, resolve to its network.
  validation {
    condition = alltrue([
      for cidr in var.node_subnet_cidrs :
      tonumber(split("/", cidr)[1]) >= tonumber(split("/", var.vpc_cidr)[1]) &&
      cidrhost("${cidrhost(cidr, 0)}/${split("/", var.vpc_cidr)[1]}", 0) == cidrhost(var.vpc_cidr, 0)
    ])
    error_message = "Every entry in node_subnet_cidrs must fall within vpc_cidr. A subnet carved outside the primary VPC CIDR fails at apply with an opaque AWS error; keep the subnet CIDRs inside vpc_cidr (or widen vpc_cidr)."
  }
}

# The dedicated internal-LB subnet tier is a v0.3 addition. Disabling it
# collapses to the pre-0.3 flat layout: no separate lb subnets, and internal
# load balancers land in the node subnets (which then carry the internal-elb
# role tag). Kept opt-in (default true) so the split-tier layout is unchanged;
# false is used when adopting an existing single-private-subnet cluster.
variable "lb_subnet_enabled" {
  description = "Create a dedicated internal load-balancer subnet tier. When false, internal LBs are placed in the node subnets instead — in create mode no lb subnets are created and the node subnets receive the kubernetes.io/role/internal-elb tag; in consumer mode lb_subnet_ids resolves to the node subnets and its precondition is relaxed (the caller tags their own node subnets)."
  type        = bool
  default     = true
}

variable "dedicated_node_sg_enabled" {
  description = "Manage a dedicated node security group (aws_security_group.eks_nodes) and attach it to pod ENIs (custom networking) and TGW node ingress. True (default) is the deployed behavior. When false, the SG and its rules are dropped and pod ENIs plus TGW ingress use the EKS-managed cluster security group that every node already carries. WARNING: flipping this from true to false on a cluster with pod_isolation_enabled = true requires a node recycle. The ENIConfig change only governs new pod ENIs, so already-running pods keep the old SG and would block its deletion (a DependencyViolation) until the nodes are recycled. See the module README migration note."
  type        = bool
  default     = true
}

variable "lb_subnet_cidrs" {
  description = "CIDR blocks for internal load balancer subnets (one per AZ). Internal ALBs/NLBs live in their own small subnets so nodes never compete with load balancers for address space. /28 each holds plenty of internal LB ENIs. Ignored when lb_subnet_enabled = false."
  type        = list(string)
  default     = ["10.0.0.96/28", "10.0.0.112/28", "10.0.0.128/28"]

  # node_subnet_cidrs is the canonical per-AZ count; every other per-AZ list
  # must match it so subnet indexing stays one-to-one across tiers. Skipped when
  # the lb tier is disabled — lb_subnet_cidrs is then unused.
  validation {
    condition     = !var.lb_subnet_enabled || length(var.lb_subnet_cidrs) == length(var.node_subnet_cidrs)
    error_message = "lb_subnet_cidrs must have the same number of entries as node_subnet_cidrs (one subnet per AZ)."
  }

  # Containment within vpc_cidr — see node_subnet_cidrs for the rationale.
  # Skipped when the lb tier is disabled (lb_subnet_cidrs is then unused).
  validation {
    condition = !var.lb_subnet_enabled || alltrue([
      for cidr in var.lb_subnet_cidrs :
      tonumber(split("/", cidr)[1]) >= tonumber(split("/", var.vpc_cidr)[1]) &&
      cidrhost("${cidrhost(cidr, 0)}/${split("/", var.vpc_cidr)[1]}", 0) == cidrhost(var.vpc_cidr, 0)
    ])
    error_message = "Every entry in lb_subnet_cidrs must fall within vpc_cidr. A subnet carved outside the primary VPC CIDR fails at apply with an opaque AWS error; keep the subnet CIDRs inside vpc_cidr (or widen vpc_cidr)."
  }
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (one per AZ). Host internet-facing load balancers and NAT gateways only; /28 each is ample."
  type        = list(string)
  default     = ["10.0.0.144/28", "10.0.0.160/28", "10.0.0.176/28"]

  validation {
    condition     = length(var.public_subnet_cidrs) == length(var.node_subnet_cidrs)
    error_message = "public_subnet_cidrs must have the same number of entries as node_subnet_cidrs (one subnet per AZ)."
  }

  # Containment within vpc_cidr — see node_subnet_cidrs for the rationale.
  validation {
    condition = alltrue([
      for cidr in var.public_subnet_cidrs :
      tonumber(split("/", cidr)[1]) >= tonumber(split("/", var.vpc_cidr)[1]) &&
      cidrhost("${cidrhost(cidr, 0)}/${split("/", var.vpc_cidr)[1]}", 0) == cidrhost(var.vpc_cidr, 0)
    ])
    error_message = "Every entry in public_subnet_cidrs must fall within vpc_cidr. A subnet carved outside the primary VPC CIDR fails at apply with an opaque AWS error; keep the subnet CIDRs inside vpc_cidr (or widen vpc_cidr)."
  }
}

variable "database_subnet_cidrs" {
  description = "CIDR blocks for database subnets (one per AZ). Only RDS/Aurora instance ENIs live here (~1 IP per instance per AZ); a /28 (11 usable after AWS's 5 reserved) comfortably covers a handful of databases. RDS Proxy is heavier: it reserves >=2 IPs per AZ per proxy endpoint and consumes more as its connection pool scales under load/failover, so two proxy endpoints already claim ~4 of a /28's 11 usable IPs. Use /26 or larger if you run RDS Proxy against multiple databases or many instances per AZ."
  type        = list(string)
  default     = ["10.0.0.192/28", "10.0.0.208/28", "10.0.0.224/28"]

  validation {
    condition     = length(var.database_subnet_cidrs) == length(var.node_subnet_cidrs)
    error_message = "database_subnet_cidrs must have the same number of entries as node_subnet_cidrs (one subnet per AZ)."
  }

  # Containment within vpc_cidr — see node_subnet_cidrs for the rationale.
  validation {
    condition = alltrue([
      for cidr in var.database_subnet_cidrs :
      tonumber(split("/", cidr)[1]) >= tonumber(split("/", var.vpc_cidr)[1]) &&
      cidrhost("${cidrhost(cidr, 0)}/${split("/", var.vpc_cidr)[1]}", 0) == cidrhost(var.vpc_cidr, 0)
    ])
    error_message = "Every entry in database_subnet_cidrs must fall within vpc_cidr. A subnet carved outside the primary VPC CIDR fails at apply with an opaque AWS error; keep the subnet CIDRs inside vpc_cidr (or widen vpc_cidr)."
  }
}

# ===== Pod Network Isolation =====
#
# By default pods draw their IPs from a non-routed secondary CIDR
# (100.64.0.0/10, RFC 6598) attached to the VPC, via VPC CNI custom
# networking. This keeps pod churn out of the routable address space so the
# primary CIDR can stay small and pods never consume routable IPs that peered
# networks would otherwise have to account for. Set pod_isolation_enabled =
# false to fall back to pods sharing node-subnet IPs (the pre-0.3 behavior).

variable "pod_isolation_enabled" {
  description = "Run pods on a non-routed secondary CIDR via VPC CNI custom networking, keeping pod IPs out of the routable address space. When false, pods draw IPs from the node subnets and no secondary CIDR, pod subnets, or ENIConfigs are created."
  type        = bool
  default     = true
}

variable "pod_secondary_cidr" {
  description = "Secondary CIDR (carved from the RFC 6598 100.64.0.0/10 shared-address space) associated with the VPC for pod IPs when this module owns the pod subnets. Must not overlap var.vpc_cidr. Ignored when pod_isolation_enabled = false or when bringing your own pod subnets."
  type        = string
  default     = "100.64.0.0/21"

  validation {
    # Pods on a routed CIDR would defeat the isolation; reject an overlap up
    # front rather than failing at apply when AWS rejects the association. Two
    # CIDRs overlap iff, masked to the shorter of their two prefixes, they
    # resolve to the same network address.
    condition = (
      cidrhost("${cidrhost(var.pod_secondary_cidr, 0)}/${min(tonumber(split("/", var.pod_secondary_cidr)[1]), tonumber(split("/", var.vpc_cidr)[1]))}", 0)
      !=
      cidrhost("${cidrhost(var.vpc_cidr, 0)}/${min(tonumber(split("/", var.pod_secondary_cidr)[1]), tonumber(split("/", var.vpc_cidr)[1]))}", 0)
    )
    error_message = "pod_secondary_cidr must not overlap vpc_cidr. Use a non-routed range (e.g. carved from 100.64.0.0/10) that is disjoint from the primary VPC CIDR."
  }
}

variable "pod_subnet_cidrs" {
  description = "CIDR blocks for pod subnets (one per AZ), carved from var.pod_secondary_cidr. A /23 per AZ yields 512 pod IPs per AZ. Used only when the module owns the pod subnets (pod_isolation_enabled = true and pod_subnet_ids is empty)."
  type        = list(string)
  default     = ["100.64.0.0/23", "100.64.2.0/23", "100.64.4.0/23"]

  # Enforced only in the module-owns case (pod isolation on, no BYO subnets):
  # one pod subnet per AZ so ENIConfigs map cleanly to availability zones.
  validation {
    condition     = !var.pod_isolation_enabled || length(var.pod_subnet_ids) > 0 || length(var.pod_subnet_cidrs) == length(var.node_subnet_cidrs)
    error_message = "pod_subnet_cidrs must have the same number of entries as node_subnet_cidrs (one subnet per AZ) when pod_isolation_enabled = true and pod_subnet_ids is empty."
  }

  # Each module-owned pod subnet must fall within pod_secondary_cidr. A subnet
  # carved outside it lands in the routable VPC tier (defeating isolation) and
  # the aws_vpc_ipv4_cidr_block_association fails only at apply with an opaque
  # AWS error. Containment requires two things: the subnet must be no larger
  # than the secondary (prefix length >= secondary's), and once masked to the
  # secondary's prefix it must resolve to the secondary's network address. The
  # prefix-length guard is what stops a subnet larger than the secondary (e.g. a
  # /20 sharing the /21's network address) from passing this check.
  validation {
    condition = !var.pod_isolation_enabled || length(var.pod_subnet_ids) > 0 || alltrue([
      for cidr in var.pod_subnet_cidrs :
      tonumber(split("/", cidr)[1]) >= tonumber(split("/", var.pod_secondary_cidr)[1]) &&
      cidrhost("${cidrhost(cidr, 0)}/${split("/", var.pod_secondary_cidr)[1]}", 0) == cidrhost(var.pod_secondary_cidr, 0)
    ])
    error_message = "Every entry in pod_subnet_cidrs must fall within pod_secondary_cidr. Subnets carved outside the secondary range land in the routable VPC tier and defeat pod isolation."
  }
}

variable "pod_subnet_ids" {
  description = "Bring-your-own pod subnet IDs (one per AZ) for VPC CNI custom networking. When set, the module does not create the secondary CIDR or pod subnets and instead points ENIConfigs at these existing subnets. Leave empty to have the module own the pod subnets. Routing caveat: the module only associates route tables with pod subnets it creates. When these are supplied with create_vpc = true, the module does NOT associate them with its private route tables — the caller must ensure each supplied pod subnet has a default route (to the module's NAT gateway or the Transit Gateway) or pods lose egress to ECR, STS, and off-VPC destinations. In consumer mode (create_vpc = false) routing is the owner account's responsibility."
  type        = list(string)
  default     = []

  # Enforced only in the bring-your-own case: one subnet per AZ. Anchor to the
  # per-AZ count that actually applies — node_subnet_ids in consumer mode
  # (node_subnet_cidrs is unused there, so anchoring to it would reject valid
  # non-3-AZ consumer layouts), falling back to node_subnet_cidrs in create mode.
  validation {
    condition     = !var.pod_isolation_enabled || length(var.pod_subnet_ids) == 0 || length(var.pod_subnet_ids) == (length(var.node_subnet_ids) > 0 ? length(var.node_subnet_ids) : length(var.node_subnet_cidrs))
    error_message = "pod_subnet_ids must have one entry per AZ — matching node_subnet_ids in consumer mode (create_vpc = false) or node_subnet_cidrs in create mode — when supplied with pod_isolation_enabled = true."
  }
}


# Most corp-connected clusters hairpin egress through the customer's own network
# (a Transit Gateway to a centralized firewall/proxy) rather than a NAT gateway,
# and air-gapped clusters have no internet egress at all. The egress path is
# therefore a first-class choice, not just an on/off NAT toggle.
variable "egress_mode" {
  description = "How node/private subnets reach the internet. \"nat\" routes 0.0.0.0/0 through module-owned NAT gateways (the default). \"transit_gateway\" routes the default route to var.transit_gateway_id (no NAT created — egress hairpins through the customer network). \"none\" installs no default route (air-gapped; reach AWS APIs via VPC endpoints)."
  type        = string
  default     = "nat"
  validation {
    condition     = contains(["nat", "transit_gateway", "none"], var.egress_mode)
    error_message = "egress_mode must be one of: \"nat\", \"transit_gateway\", \"none\"."
  }
}

variable "enable_nat_gateway" {
  description = "Enable NAT Gateway for private subnets (only honored when egress_mode = \"nat\")"
  type        = bool
  default     = true
}

# Prefix delegation lets the VPC CNI assign /28 prefixes to ENIs instead of
# individual secondary IPs, raising max-pods-per-node and cutting EC2 API churn
# on dense nodes. It is an independent CNI tunable from pod isolation — useful
# with or without custom networking — so it gets its own toggle.
#
# Defaulted on: with pod_isolation_enabled = true (the default) custom
# networking takes the primary ENI out of pod service, lowering effective
# max-pods below the AMI default. Without prefix delegation the scheduler
# over-commits nodes on a bare `terraform apply` and excess pods stall in
# ContainerCreating. Prefix delegation is supported on all Nitro instance
# types (the default node family qualifies) and is the AWS-recommended path
# for custom networking. Set false only for non-Nitro instance types.
variable "cni_prefix_delegation_enabled" {
  description = "Enable VPC CNI prefix delegation (ENABLE_PREFIX_DELEGATION) to raise pod density per node. Defaults true; requires Nitro instance types. Set false only for non-Nitro nodes. Interacts with pod_isolation_enabled: when isolation is on (the default) pods draw from the /23 pod subnets where /28 prefix allocation is comfortable, but when pod_isolation_enabled = false pods return to the node subnets — and prefix delegation carves /28 blocks that a default /27 node subnet cannot hold (WARM_PREFIX_TARGET = 1 pre-warms a prefix per ENI and exhausts the subnet, stalling the CNI). For that combination either set this false or widen node subnets to /25 or larger (the module enforces this — see aws/byo-network.tf)."
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "Use single NAT Gateway (cost savings for dev)"
  type        = bool
  default     = false
}

# A separate axis from create_vpc: a module-owned VPC can be built with no
# internet gateway at all (the public tier only exists to host internet-facing
# load balancers and NAT). Disabling it produces a fully private VPC whose only
# off-VPC path is the Transit Gateway or VPC endpoints — the shape most enterprise
# landing zones mandate.
variable "igw_enabled" {
  description = "Create the internet gateway and the public subnet tier (public subnets, their route table, and associations). Only consulted when create_vpc = true. Set false for a fully private module-owned VPC with no internet gateway; requires egress_mode != \"nat\" since NAT needs a public subnet + IGW."
  type        = bool
  default     = true
}

variable "enable_vpc_endpoints" {
  description = "Enable VPC endpoints for S3, ECR, EC2"
  type        = bool
  default     = true
}

variable "transit_gateway_id" {
  description = "ID of an existing Transit Gateway to attach the VPC to (null = no TGW attachment)"
  type        = string
  default     = null
  validation {
    condition     = var.transit_gateway_id == null || can(regex("^tgw-[0-9a-f]{17}$", var.transit_gateway_id))
    error_message = "transit_gateway_id must be null or a valid Transit Gateway ID (e.g. \"tgw-0123456789abcdef0\")."
  }
}

variable "transit_gateway_cidr_blocks" {
  description = "CIDR blocks reachable via the Transit Gateway (other VPCs, on-prem networks). Routes and security-group ingress rules are created per CIDR."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for cidr in var.transit_gateway_cidr_blocks : can(cidrnetmask(cidr))])
    error_message = "Each transit_gateway_cidr_blocks entry must be a valid IPv4 CIDR block (e.g. \"10.1.0.0/16\"). IPv6 is not supported — TGW routes set destination_cidr_block (IPv4) only."
  }
}

variable "transit_gateway_subnet_ids" {
  description = "Subnet IDs for the TGW attachment ENIs (null = use the private subnets). One per AZ is recommended for HA."
  type        = list(string)
  default     = null
  validation {
    condition     = var.transit_gateway_subnet_ids == null || length(var.transit_gateway_subnet_ids) > 0
    error_message = "transit_gateway_subnet_ids must be null or a non-empty list (AWS requires at least one subnet for the TGW attachment)."
  }
}

variable "transit_gateway_default_route_table_association" {
  description = "Associate the VPC attachment with the TGW's default route table. Set false to manage associations separately (e.g. segregated route tables in a hub-and-spoke topology)."
  type        = bool
  default     = true
}

variable "transit_gateway_default_route_table_propagation" {
  description = "Propagate routes to the TGW's default route table. Set false to manage propagation separately."
  type        = bool
  default     = true
}

variable "expose_database_to_transit_gateway" {
  description = "Allow the transit_gateway_cidr_blocks to reach RDS/Aurora directly over the Transit Gateway (opens the database security groups on 5432). Default false: application traffic to the database stays in-VPC, and human/admin database access goes through Teleport rather than the corp network, so the database tier is not advertised to the TGW. Set true only when an external network genuinely needs a direct database path."
  type        = bool
  default     = false
}

variable "transit_gateway_node_ingress" {
  description = "Port ranges to allow from each transit_gateway_cidr_blocks entry to the EKS nodes. Empty list (default) allows all traffic (protocol \"-1\"); set explicit ranges to restrict cross-VPC node access (e.g. NodePorts, kubelet)."
  type = list(object({
    from_port = number
    to_port   = number
    protocol  = optional(string, "tcp")
  }))
  default = []
  validation {
    condition = alltrue([
      for r in var.transit_gateway_node_ingress :
      r.from_port >= 0 && r.to_port <= 65535 && r.from_port <= r.to_port
    ])
    error_message = "Each transit_gateway_node_ingress entry must satisfy 0 <= from_port <= to_port <= 65535."
  }
}

# ===== EKS Configuration =====

variable "kubernetes_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.35"
}

variable "api_server_authorized_cidrs" {
  description = "Authorized CIDR blocks for API server access (only applies when private_cluster_enabled = false, empty = open)"
  type        = list(string)
  default     = []
}

variable "private_network_access_cidrs" {
  description = <<-EOT
    CIDR blocks permitted to reach the private EKS API endpoint on 443.
    Only applies when private_cluster_enabled = true; ignored otherwise
    (public access is governed by api_server_authorized_cidrs). Empty
    (the default) creates no rule, so the private endpoint is reachable
    only from the node security group. Populate with the CIDR(s) of an
    in-VPC bastion / CI runner or a corp network reaching the endpoint
    over DX/VPN so Terraform (and operators) can drive the API without
    attaching the node security group to the runner.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for cidr in var.private_network_access_cidrs : can(cidrhost(cidr, 0))])
    error_message = "Every entry in private_network_access_cidrs must be a valid CIDR block (e.g. \"10.0.1.5/32\")."
  }
}

variable "enable_cluster_encryption" {
  description = "Enable EKS secrets encryption with KMS"
  type        = bool
  default     = true
}

# By default the control plane's cross-account ENIs are placed only in the node
# subnets (the intended layout). Enabling this also lists the public subnets in
# the cluster's vpc_config.subnet_ids — the pre-0.3 behavior — so an existing
# cluster built that way adopts with no change to its subnet set.
variable "cluster_public_subnets_enabled" {
  description = "Also place EKS control-plane ENIs in the public subnets (legacy layout). Default false = node subnets only. Only consulted when create_vpc = true and the public tier exists."
  type        = bool
  default     = false
}

# EKS-managed add-ons default to the most-recent version for the cluster's
# Kubernetes version. Pin any add-on here to hold a specific version instead —
# e.g. to adopt an existing cluster with no version change, or to control
# add-on upgrades deliberately. Keys: coredns, kube_proxy, vpc_cni,
# ebs_csi_driver, metrics_server, pod_identity_agent. Empty = most-recent (the
# prior behavior).
variable "eks_addon_versions" {
  description = "Optional per-add-on version pins (map of add-on key -> version). Unset keys use the most-recent version for the cluster's Kubernetes version."
  type        = map(string)
  default     = {}

  # A pin only takes effect for a recognized key, and coalesce() treats "" the
  # same as null — so an unknown key (typo) or an empty value would silently
  # fall back to most-recent, defeating the point. Reject both at plan time.
  validation {
    condition     = length(setsubtract(keys(var.eks_addon_versions), ["coredns", "kube_proxy", "vpc_cni", "ebs_csi_driver", "metrics_server", "pod_identity_agent"])) == 0
    error_message = "eks_addon_versions keys must be a subset of: coredns, kube_proxy, vpc_cni, ebs_csi_driver, metrics_server, pod_identity_agent."
  }

  validation {
    condition     = alltrue([for v in values(var.eks_addon_versions) : length(trimspace(v)) > 0])
    error_message = "eks_addon_versions values must be non-empty version strings (an empty value silently falls back to most-recent)."
  }
}

# ===== Node Group Configuration =====

variable "node_groups" {
  description = "Configuration for EKS managed node groups"
  type = map(object({
    instance_types  = list(string)
    min_size        = number
    max_size        = number
    desired_size    = number
    disk_size       = number
    ami_type        = optional(string)
    release_version = optional(string)
    labels          = map(string)
    taints = list(object({
      key    = string
      value  = string
      effect = string
    }))
  }))
  default = {
    system = {
      instance_types = ["t3a.medium"]
      min_size       = 2
      max_size       = 4
      desired_size   = 2
      disk_size      = 50
      labels = {
        "workload-type" = "system"
      }
      taints = [{
        key    = "CriticalAddonsOnly"
        value  = "true"
        effect = "NO_SCHEDULE"
      }]
    }
    support = {
      instance_types = ["t3a.medium"]
      min_size       = 1
      max_size       = 4
      desired_size   = 1
      disk_size      = 50
      labels = {
        "workload-type" = "support"
      }
      taints = []
    }
    application = {
      instance_types = ["t3a.medium"]
      min_size       = 2
      max_size       = 6
      desired_size   = 2
      disk_size      = 100
      labels = {
        "workload-type" = "application"
      }
      taints = []
    }
  }
}

# ===== ECR Configuration =====

variable "registry_enabled" {
  description = "Create new ECR repository (false to use existing)"
  type        = bool
  default     = false
}

variable "ecr_repository_name" {
  description = "Name of existing ECR repository (only used if registry_enabled = false)"
  type        = string
  default     = null
}

variable "ecr_image_tag_mutability" {
  description = "Image tag mutability (MUTABLE or IMMUTABLE)"
  type        = string
  default     = "IMMUTABLE"
  validation {
    condition     = contains(["MUTABLE", "IMMUTABLE"], var.ecr_image_tag_mutability)
    error_message = "Must be MUTABLE or IMMUTABLE."
  }
}

variable "ecr_scan_on_push" {
  description = "Enable image scanning on push"
  type        = bool
  default     = true
}

variable "ecr_encryption_type" {
  description = "Encryption type (AES256 or KMS)"
  type        = string
  default     = "AES256"
  validation {
    condition     = contains(["AES256", "KMS"], var.ecr_encryption_type)
    error_message = "Must be AES256 or KMS."
  }
}

variable "ecr_lifecycle_policy" {
  description = "Lifecycle policy configuration"
  type = object({
    keep_prod_images   = number
    keep_latest_images = number
    expire_untagged    = number
  })
  default = {
    keep_prod_images   = 5
    keep_latest_images = 3
    expire_untagged    = 3
  }
}

# ===== ACM Certificate Configuration =====

variable "acm_create" {
  description = "Create new ACM certificate (false to use existing or skip)"
  type        = bool
  default     = false
}

variable "acm_certificate_arn" {
  description = "ARN of existing ACM certificate (only used if acm_create = false)"
  type        = string
  default     = null
}

variable "acm_domain_name" {
  description = "Domain name for the certificate. Use '*.example.com' for wildcard certificates or 'example.com' for non-wildcard certificates."
  type        = string
  default     = null
  validation {
    condition     = var.acm_domain_name == null || can(regex("^(\\*\\.)?([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.acm_domain_name))
    error_message = "Domain name must be a valid format like 'example.com', 'api.example.com', or '*.example.com'. Must contain at least one dot and valid domain labels."
  }
}

variable "acm_subject_alternative_names" {
  description = "Additional domain names for the certificate (e.g., ['*.example.com', 'www.example.com'])"
  type        = list(string)
  default     = []
}

variable "acm_validation_method" {
  description = "Certificate validation method (DNS or EMAIL)"
  type        = string
  default     = "DNS"
  validation {
    condition     = contains(["DNS", "EMAIL"], var.acm_validation_method)
    error_message = "Must be DNS or EMAIL."
  }
}

variable "acm_route53_zone_id" {
  description = "Route53 hosted zone ID for DNS validation (required for automatic DNS validation)"
  type        = string
  default     = null
}

# ===== RDS Configuration =====

variable "rds_enabled" {
  description = "Deploy RDS PostgreSQL"
  type        = bool
  default     = true
}

variable "rds_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t4g.micro"
}

variable "rds_engine_version" {
  description = "PostgreSQL engine version"
  type        = string
  default     = "17.10"
}

variable "rds_allocated_storage" {
  description = "Allocated storage in GB"
  type        = number
  default     = 20
}

variable "rds_max_allocated_storage" {
  description = "Maximum storage for autoscaling in GB"
  type        = number
  default     = 100
}

variable "rds_multi_az" {
  description = "Enable Multi-AZ deployment"
  type        = bool
  default     = false
}

variable "rds_backup_retention_period" {
  description = "Backup retention period in days"
  type        = number
  default     = 7
  validation {
    condition     = var.rds_backup_retention_period >= 0 && var.rds_backup_retention_period <= 35
    error_message = "Backup retention must be between 0 and 35 days."
  }
}

variable "rds_skip_final_snapshot" {
  description = "Skip final snapshot on deletion (set false for prod)"
  type        = bool
  default     = true
}

variable "rds_deletion_protection" {
  description = "Enable deletion protection"
  type        = bool
  default     = false
}

variable "rds_admin_username" {
  description = "RDS master username"
  type        = string
  default     = "psqladmin"
  sensitive   = true
}

variable "rds_database_name" {
  description = "Initial database name"
  type        = string
  default     = "optura"
}

# ===== RDS Multi-Database Configuration =====

variable "databases" {
  description = <<-EOT
    Map of named RDS PostgreSQL instances to provision. Each key becomes part of
    the cloud-side identifier. The "core" key is reserved for the legacy primary
    database and its on-cloud identifier is preserved (no -core suffix); every
    other key produces a suffixed instance ($${base}-$${each.key}).

    Engine selection (per database):
      - engine = "rds"               → standalone RDS PostgreSQL instance (default)
      - engine = "aurora"            → Aurora PostgreSQL provisioned cluster
      - engine = "aurora-serverless" → Aurora PostgreSQL Serverless v2 cluster

    The "core" key defaults to "rds" so existing deployments are untouched.
    NOTE: switching an existing key between engine families (e.g. rds →
    aurora) is a DESTROY + RECREATE of the database — Terraform cannot morph
    an aws_db_instance into an aws_rds_cluster, and the data move is a
    separate snapshot-restore / DMS operation. Only switch engines on a
    database with no data you need to keep. See aws/README.md.

    Per-entry overrides (all optional — fall back to top-level defaults when
    omitted):
      - engine                    (string)  — "rds" | "aurora" | "aurora-serverless"
      - engine_version            (string)  — PostgreSQL engine version
                                              (rds → var.rds_engine_version,
                                               aurora* → var.aurora_engine_version)
      - instance_class            (string)  — instance class. RDS → var.rds_instance_class;
                                              aurora → var.aurora_instance_class;
                                              aurora-serverless forces "db.serverless".
      - instance_count            (number)  — Aurora cluster instances (writer + readers);
                                              default 1. Ignored for engine = "rds".
      - serverless_min_capacity   (number)  — Aurora Serverless v2 min ACUs
                                              (default var.aurora_serverless_min_capacity)
      - serverless_max_capacity   (number)  — Aurora Serverless v2 max ACUs
                                              (default var.aurora_serverless_max_capacity)
      - allocated_storage         (number)  — Allocated storage in GB (RDS only; Aurora storage is managed)
      - max_allocated_storage     (number)  — Storage autoscaling cap in GB (RDS only)
      - multi_az                  (bool)    — Multi-AZ deployment (RDS only; Aurora HA = instance_count > 1)
      - backup_retention_period   (number)  — Backup retention in days
      - deletion_protection       (bool)    — Enable deletion protection
      - skip_final_snapshot       (bool)    — Skip final snapshot on destroy
      - admin_username            (string)  — Master username
      - db_name                   (string)  — Initial database name
  EOT
  type = map(object({
    engine                  = optional(string, "rds")
    engine_version          = optional(string)
    instance_class          = optional(string)
    instance_count          = optional(number)
    serverless_min_capacity = optional(number)
    serverless_max_capacity = optional(number)
    allocated_storage       = optional(number)
    max_allocated_storage   = optional(number)
    multi_az                = optional(bool)
    backup_retention_period = optional(number)
    deletion_protection     = optional(bool)
    skip_final_snapshot     = optional(bool)
    admin_username          = optional(string)
    db_name                 = optional(string)
  }))
  # Default ships only `core` so existing deployments do not see a surprise
  # second instance on upgrade. Add `temporal = {}` (or any other key) in your
  # tfvars when you actually need it — see example.tfvars.
  default = {
    core = {}
  }

  validation {
    condition     = contains(keys(var.databases), "core")
    error_message = "databases must include a \"core\" key. The \"core\" key is required because removing it would destroy the existing primary RDS instance (the legacy single-DB deployment migrates to var.databases[\"core\"] via a moved block). See aws/README.md 'Upgrading from single-DB' section for migration guidance."
  }

  validation {
    condition = alltrue([
      for k, v in var.databases : contains(["rds", "aurora", "aurora-serverless"], v.engine)
    ])
    error_message = "Each databases[*].engine must be one of: \"rds\", \"aurora\", \"aurora-serverless\"."
  }

  validation {
    condition = alltrue([
      for k, v in var.databases :
      v.instance_count == null || v.instance_count >= 1
    ])
    error_message = "databases[*].instance_count must be >= 1 (0 creates an Aurora cluster with no instances, which cannot accept connections)."
  }

  validation {
    condition = alltrue([
      for k, v in var.databases :
      v.engine != "aurora-serverless" ||
      v.serverless_min_capacity == null ||
      v.serverless_max_capacity == null ||
      v.serverless_min_capacity <= v.serverless_max_capacity
    ])
    error_message = "databases[*].serverless_min_capacity must be <= serverless_max_capacity for aurora-serverless databases."
  }

  validation {
    condition = alltrue([
      for k, v in var.databases :
      !contains(["aurora", "aurora-serverless"], v.engine) ||
      v.backup_retention_period == null ||
      v.backup_retention_period >= 1
    ])
    error_message = "databases[*].backup_retention_period must be >= 1 for aurora and aurora-serverless engines (AWS rejects CreateDBCluster with 0). Standalone RDS permits 0; Aurora does not."
  }

  validation {
    condition = alltrue([
      for k, v in var.databases :
      v.engine != "aurora" || v.instance_class != "db.serverless"
    ])
    error_message = "databases[*].instance_class cannot be \"db.serverless\" when engine = \"aurora\" (provisioned). db.serverless requires a serverlessv2_scaling_configuration block, which is only set for engine = \"aurora-serverless\". Use engine = \"aurora-serverless\" for Serverless v2."
  }

  validation {
    # Aurora cluster instances are named "<rds_base><suffix>-<index>", where
    # suffix is "" for the "core" key and "-<key>" otherwise. An "rds" key K
    # produces "<rds_base>-<K>", so it collides when "-<K>" == "<suffix>-<index>":
    #   - aurora "core"  (empty suffix) → forbidden rds key matches "^[0-9]+$"
    #   - aurora "<key>" (suffix -key)  → forbidden rds key matches "^<key>-[0-9]+$"
    # AWS shares one identifier namespace across DB instances and cluster
    # instances, so a collision fails at apply with DBInstanceAlreadyExists.
    condition = alltrue(flatten([
      for rds_k, rds_v in var.databases :
      rds_v.engine == "rds" ? [
        for aur_k, aur_v in var.databases :
        contains(["aurora", "aurora-serverless"], aur_v.engine) ?
        !can(regex("^${aur_k == "core" ? "" : "${aur_k}-"}[0-9]+$", rds_k)) : true
      ] : [true]
    ]))
    error_message = "An \"rds\" databases key must not match an Aurora cluster's instance identifier pattern. AWS shares one identifier namespace across DB instances and cluster instances: an rds key \"temporal-0\" collides with aurora cluster \"temporal\" instance 0, and an rds key \"0\" collides with aurora \"core\" instance 0 (core has no key segment). Both fail at apply with DBInstanceAlreadyExists."
  }
}

# ===== Aurora Configuration =====
#
# Top-level defaults for databases whose engine is "aurora" or
# "aurora-serverless". Per-database overrides live in var.databases.

variable "aurora_engine_version" {
  description = "Aurora PostgreSQL engine version, aligned to the PostgreSQL 17 major (matching var.rds_engine_version). Aurora and RDS never share an exact minor, so this tracks the major; confirm the exact minor available in your Region with `aws rds describe-db-engine-versions --engine aurora-postgresql`."
  type        = string
  default     = "17.9"
}

variable "aurora_instance_class" {
  description = "Instance class for Aurora provisioned (engine = \"aurora\") cluster instances. Ignored for aurora-serverless (forced to db.serverless)."
  type        = string
  default     = "db.t4g.medium"
}

variable "aurora_serverless_min_capacity" {
  description = "Aurora Serverless v2 minimum capacity in ACUs (0.5 increments). 0 allows scale-to-zero pause on supported versions."
  type        = number
  default     = 0.5
}

variable "aurora_serverless_max_capacity" {
  description = "Aurora Serverless v2 maximum capacity in ACUs."
  type        = number
  default     = 4
}

# ===== AWS Load Balancer Controller =====

variable "install_aws_lb_controller" {
  description = "Install AWS Load Balancer Controller via Helm"
  type        = bool
  default     = true
}

variable "aws_lb_controller_version" {
  description = "AWS Load Balancer Controller Helm chart version"
  type        = string
  default     = "1.16.0"
}

# ===== AWS WAF =====

variable "waf_web_acls" {
  description = <<-EOT
    AWS WAFv2 Web ACLs, keyed by an arbitrary name (typically an env).
    Empty by default (opt-in). One entry = one Web ACL; its ARN is returned under
    the same key in waf_web_acl_arns. Attach it to a controller-managed ALB in
    gitops via the alb.ingress.kubernetes.io/wafv2-acl-arn annotation; use
    associate_resource_arns only for ALBs provisioned outside the controller.
    Set scope = "CLOUDFRONT" for an edge ACL attached to a CloudFront
    distribution's web_acl_id — those require the module to run in us-east-1.
    Rule names and priorities must each be unique across all rule kinds in an ACL.
    Set `name` to override the derived Web ACL name (default `<project>-<environment>-<key>`)
    when the ACL is not env-specific (e.g. one ACL shared across environments).
    See the README WAF feature section for full field docs and examples.
  EOT
  type = map(object({
    name           = optional(string)
    default_action = optional(string, "allow")
    scope          = optional(string, "REGIONAL")

    rate_based_rules = optional(list(object({
      name                      = string
      priority                  = number
      limit                     = number
      evaluation_window_seconds = optional(number, 300)
      action                    = optional(string, "block")
      path_prefix               = optional(string)
      aggregate_key_type        = optional(string, "IP")
      forwarded_ip_header       = optional(string, "X-Forwarded-For")
      forwarded_ip_fallback     = optional(string, "MATCH")
    })), [])

    managed_rule_groups = optional(list(object({
      name              = string
      priority          = number
      vendor_name       = optional(string, "AWS")
      version           = optional(string)
      override_to_count = optional(bool, false)
      rule_action_overrides = optional(list(object({
        name          = string
        action_to_use = string
      })), [])

      # Narrow WHICH requests this group inspects. The group is evaluated for
      # everything EXCEPT requests matching every condition set here — so this
      # exempts known-good traffic from one group without letting it skip the
      # rest of the ACL, which is what a standalone allow rule would do.
      #
      # exempt_when_headers maps header name => exact value. Every condition
      # set — the IP list and each header — must match for a request to be
      # exempt, so more conditions means a narrower exemption. At least one is
      # required. Comparison is case-insensitive on both name and value.
      #
      # Headers are supplied by the client, so they are NOT a trust boundary on
      # their own — anyone can send them. They are for narrowing an exemption
      # to a specific host, route or caller; pair them with exempt_when_ips
      # whenever the exemption itself needs to be trustworthy.
      scope_down = optional(object({
        exempt_when_ips     = optional(list(string))
        exempt_when_headers = optional(map(string))
      }))
    })), [])

    ip_rules = optional(list(object({
      name       = string
      priority   = number
      addresses  = list(string)
      action     = optional(string, "block")
      ip_version = optional(string, "IPV4")
    })), [])

    geo_rules = optional(list(object({
      name          = string
      priority      = number
      country_codes = list(string)
      action        = optional(string, "block")
      negate        = optional(bool, false)
    })), [])

    associate_resource_arns = optional(list(string), [])

    logging = optional(object({
      enabled               = optional(bool, false)
      destination_arn       = optional(string)
      retention_days        = optional(number, 365)
      kms_key_arn           = optional(string)
      redacted_header_names = optional(list(string), ["authorization", "cookie"])
      only_blocked          = optional(bool, false)
    }), {})
  }))
  default = {}

  # Keys become part of the Web ACL name (<prefix>-<key>) and CloudWatch metric
  # names, which WAF restricts to this charset.
  validation {
    condition     = alltrue([for k, acl in var.waf_web_acls : can(regex("^[a-zA-Z0-9_-]+$", k))])
    error_message = "waf_web_acls keys must match ^[a-zA-Z0-9_-]+$ (each key is used in the Web ACL and CloudWatch metric names)."
  }

  # Optional per-ACL name override, when set, must satisfy WAFv2's name charset.
  validation {
    condition     = alltrue([for k, acl in var.waf_web_acls : acl.name == null || can(regex("^[a-zA-Z0-9_-]{1,128}$", acl.name))])
    error_message = "waf_web_acls[*].name, when set, must match ^[a-zA-Z0-9_-]{1,128}$."
  }

  # Effective Web ACL names (explicit `name`, else derived
  # <project>-<environment>-<key>) must be unique — AWS rejects duplicate regional
  # Web ACL names (and the module would emit duplicate log-group names) at apply.
  validation {
    condition = length(distinct([
      for k, acl in var.waf_web_acls : coalesce(acl.name, "${var.project_name}-${var.environment}-${k}")
    ])) == length(var.waf_web_acls)
    error_message = "waf_web_acls: effective Web ACL names must be unique — an explicit `name` must not equal another entry's `name` or derived `<project>-<environment>-<key>` name."
  }

  # WAFv2 caps the Web ACL name and every CloudWatch metric name at 128 chars.
  # Metrics are the ACL name (ACL level) and "<acl-name>-<rule-name>" (rule level),
  # so a long `name`/key plus a rule name can overflow even when `name` alone
  # validates. Guard the composed names here (covers long keys too, pre-existing).
  validation {
    condition = alltrue([
      for k, acl in var.waf_web_acls : alltrue([
        for nm in concat(
          [coalesce(acl.name, "${var.project_name}-${var.environment}-${k}")],
          [for r in acl.rate_based_rules : "${coalesce(acl.name, "${var.project_name}-${var.environment}-${k}")}-${r.name}"],
          [for r in acl.managed_rule_groups : "${coalesce(acl.name, "${var.project_name}-${var.environment}-${k}")}-${r.name}"],
          [for r in acl.ip_rules : "${coalesce(acl.name, "${var.project_name}-${var.environment}-${k}")}-${r.name}"],
          [for r in acl.geo_rules : "${coalesce(acl.name, "${var.project_name}-${var.environment}-${k}")}-${r.name}"],
        ) : length(nm) <= 128
      ])
    ])
    error_message = "waf_web_acls: the Web ACL name and each rule's CloudWatch metric name \"<acl-name>-<rule-name>\" must be <= 128 chars (WAFv2 limit). Shorten the ACL `name`/key or the rule names."
  }

  validation {
    condition     = alltrue([for k, acl in var.waf_web_acls : contains(["allow", "block"], acl.default_action)])
    error_message = "waf_web_acls[*].default_action must be either \"allow\" or \"block\"."
  }

  # Changing scope on an existing ACL forces replacement; the default keeps every
  # already-deployed entry REGIONAL.
  validation {
    condition     = alltrue([for k, acl in var.waf_web_acls : contains(["REGIONAL", "CLOUDFRONT"], acl.scope)])
    error_message = "waf_web_acls[*].scope must be either \"REGIONAL\" or \"CLOUDFRONT\"."
  }

  # A CLOUDFRONT-scope ACL cannot be associated with an ALB — CloudFront takes it
  # via the distribution's web_acl_id instead.
  validation {
    condition = alltrue([
      for k, acl in var.waf_web_acls :
      acl.scope == "REGIONAL" || length(acl.associate_resource_arns) == 0
    ])
    error_message = "waf_web_acls[*].associate_resource_arns is only valid when scope = \"REGIONAL\"; attach a CLOUDFRONT-scope ACL via the distribution's web_acl_id."
  }

  # Rule names must be unique across all rule kinds within one ACL.
  validation {
    condition = alltrue([
      for k, acl in var.waf_web_acls :
      length(distinct(concat(
        [for r in acl.rate_based_rules : r.name],
        [for r in acl.managed_rule_groups : r.name],
        [for r in acl.ip_rules : r.name],
        [for r in acl.geo_rules : r.name],
        ))) == length(concat(
        [for r in acl.rate_based_rules : r.name],
        [for r in acl.managed_rule_groups : r.name],
        [for r in acl.ip_rules : r.name],
        [for r in acl.geo_rules : r.name],
      ))
    ])
    error_message = "Within each waf_web_acls entry, rule names must be unique across ALL rule kinds (rate_based_rules, managed_rule_groups, ip_rules, geo_rules)."
  }

  # Priorities must be unique across all rule kinds within one ACL.
  validation {
    condition = alltrue([
      for k, acl in var.waf_web_acls :
      length(distinct(concat(
        [for r in acl.rate_based_rules : r.priority],
        [for r in acl.managed_rule_groups : r.priority],
        [for r in acl.ip_rules : r.priority],
        [for r in acl.geo_rules : r.priority],
        ))) == length(concat(
        [for r in acl.rate_based_rules : r.priority],
        [for r in acl.managed_rule_groups : r.priority],
        [for r in acl.ip_rules : r.priority],
        [for r in acl.geo_rules : r.priority],
      ))
    ])
    error_message = "Within each waf_web_acls entry, rule priorities must be unique across ALL rule kinds — a Web ACL has a single evaluation-order space."
  }

  # All rule names (any kind) must be valid WAF/metric names.
  validation {
    condition = alltrue([
      for k, acl in var.waf_web_acls : alltrue([
        for n in concat(
          [for r in acl.rate_based_rules : r.name],
          [for r in acl.managed_rule_groups : r.name],
          [for r in acl.ip_rules : r.name],
          [for r in acl.geo_rules : r.name],
        ) : can(regex("^[a-zA-Z0-9_-]+$", n))
      ])
    ])
    error_message = "waf_web_acls[*] rule names must match ^[a-zA-Z0-9_-]+$ (they are reused as CloudWatch metric names)."
  }

  # --- rate_based_rules field validation ---
  validation {
    condition     = alltrue([for k, acl in var.waf_web_acls : alltrue([for r in acl.rate_based_rules : r.limit >= 10 && r.limit <= 2000000000])])
    error_message = "waf_web_acls[*].rate_based_rules[].limit must be between 10 and 2000000000 (AWS WAF rate-based rule bounds)."
  }
  validation {
    condition     = alltrue([for k, acl in var.waf_web_acls : alltrue([for r in acl.rate_based_rules : contains([60, 120, 300, 600], r.evaluation_window_seconds)])])
    error_message = "waf_web_acls[*].rate_based_rules[].evaluation_window_seconds must be one of 60, 120, 300, or 600."
  }
  validation {
    condition     = alltrue([for k, acl in var.waf_web_acls : alltrue([for r in acl.rate_based_rules : contains(["block", "count"], r.action)])])
    error_message = "waf_web_acls[*].rate_based_rules[].action must be either \"block\" or \"count\"."
  }
  validation {
    condition     = alltrue([for k, acl in var.waf_web_acls : alltrue([for r in acl.rate_based_rules : contains(["IP", "FORWARDED_IP"], r.aggregate_key_type)])])
    error_message = "waf_web_acls[*].rate_based_rules[].aggregate_key_type must be either \"IP\" or \"FORWARDED_IP\"."
  }
  validation {
    condition     = alltrue([for k, acl in var.waf_web_acls : alltrue([for r in acl.rate_based_rules : contains(["MATCH", "NO_MATCH"], r.forwarded_ip_fallback)])])
    error_message = "waf_web_acls[*].rate_based_rules[].forwarded_ip_fallback must be either \"MATCH\" or \"NO_MATCH\"."
  }
  validation {
    condition     = alltrue([for k, acl in var.waf_web_acls : alltrue([for r in acl.rate_based_rules : r.aggregate_key_type != "FORWARDED_IP" || length(r.forwarded_ip_header) > 0])])
    error_message = "waf_web_acls[*].rate_based_rules[].forwarded_ip_header must be non-empty when aggregate_key_type is \"FORWARDED_IP\"."
  }
  validation {
    condition     = alltrue([for k, acl in var.waf_web_acls : alltrue([for r in acl.rate_based_rules : r.path_prefix == null ? true : startswith(r.path_prefix, "/")])])
    error_message = "waf_web_acls[*].rate_based_rules[].path_prefix, when set, must start with \"/\"."
  }

  # --- managed_rule_groups field validation ---
  validation {
    condition     = alltrue([for k, acl in var.waf_web_acls : alltrue([for g in acl.managed_rule_groups : alltrue([for o in g.rule_action_overrides : contains(["allow", "block", "count"], o.action_to_use)])])])
    error_message = "waf_web_acls[*].managed_rule_groups[].rule_action_overrides[].action_to_use must be one of \"allow\", \"block\", or \"count\"."
  }

  # --- ip_rules field validation ---
  validation {
    condition     = alltrue([for k, acl in var.waf_web_acls : alltrue([for r in acl.ip_rules : contains(["block", "allow", "count"], r.action)])])
    error_message = "waf_web_acls[*].ip_rules[].action must be one of \"block\", \"allow\", or \"count\"."
  }
  validation {
    condition     = alltrue([for k, acl in var.waf_web_acls : alltrue([for r in acl.ip_rules : contains(["IPV4", "IPV6"], r.ip_version)])])
    error_message = "waf_web_acls[*].ip_rules[].ip_version must be either \"IPV4\" or \"IPV6\"."
  }
  validation {
    condition     = alltrue([for k, acl in var.waf_web_acls : alltrue([for r in acl.ip_rules : alltrue([for a in r.addresses : can(regex("/", a))])])])
    error_message = "waf_web_acls[*].ip_rules[].addresses must be CIDRs with a prefix length (e.g. 203.0.113.0/24, or /32 for a single host)."
  }

  # --- geo_rules field validation ---
  validation {
    condition     = alltrue([for k, acl in var.waf_web_acls : alltrue([for r in acl.geo_rules : contains(["block", "allow", "count"], r.action)])])
    error_message = "waf_web_acls[*].geo_rules[].action must be one of \"block\", \"allow\", or \"count\"."
  }
  validation {
    condition     = alltrue([for k, acl in var.waf_web_acls : alltrue([for r in acl.geo_rules : length(r.country_codes) > 0 && alltrue([for c in r.country_codes : can(regex("^[A-Z]{2}$", c))])])])
    error_message = "waf_web_acls[*].geo_rules[].country_codes must be non-empty and each a two-letter uppercase ISO 3166-1 alpha-2 code."
  }

  # --- associate_resource_arns validation ---
  validation {
    condition     = alltrue([for k, acl in var.waf_web_acls : alltrue([for a in acl.associate_resource_arns : can(regex("^arn:aws[a-z-]*:", a))])])
    error_message = "waf_web_acls[*].associate_resource_arns entries must be valid AWS ARNs."
  }
  validation {
    condition     = length(flatten([for k, acl in var.waf_web_acls : acl.associate_resource_arns])) == length(distinct(flatten([for k, acl in var.waf_web_acls : acl.associate_resource_arns])))
    error_message = "A resource ARN may appear in associate_resource_arns of only one waf_web_acls entry — a resource can be associated with a single Web ACL."
  }

  # --- logging validation ---
  validation {
    condition     = alltrue([for k, acl in var.waf_web_acls : contains([0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], acl.logging.retention_days)])
    error_message = "waf_web_acls[*].logging.retention_days must be a valid CloudWatch Logs retention value (0 = never expire, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653)."
  }
  validation {
    condition     = alltrue([for k, acl in var.waf_web_acls : acl.logging.destination_arn == null || can(regex("^arn:aws[a-z-]*:", acl.logging.destination_arn))])
    error_message = "waf_web_acls[*].logging.destination_arn must be a valid AWS ARN when set."
  }
  validation {
    condition     = alltrue([for k, acl in var.waf_web_acls : acl.logging.kms_key_arn == null || can(regex("^arn:aws[a-z-]*:kms:", acl.logging.kms_key_arn))])
    error_message = "waf_web_acls[*].logging.kms_key_arn must be a valid KMS key ARN when set."
  }

  # ---- managed_rule_groups[*].scope_down ----

  validation {
    condition = alltrue([
      for k, acl in var.waf_web_acls : alltrue([
        for g in acl.managed_rule_groups :
        g.scope_down == null ? true : (
          g.scope_down.exempt_when_ips != null ||
          (g.scope_down.exempt_when_headers != null && length(coalesce(g.scope_down.exempt_when_headers, {})) > 0)
        )
      ])
    ])
    error_message = "waf_web_acls[*].managed_rule_groups[*].scope_down: set at least one of exempt_when_ips or a non-empty exempt_when_headers. An empty scope_down would exempt nothing and is almost certainly a mistake."
  }

  validation {
    condition = alltrue([
      for k, acl in var.waf_web_acls : alltrue([
        for g in acl.managed_rule_groups :
        g.scope_down == null ? true : (
          g.scope_down.exempt_when_ips == null ? true : (
            length(g.scope_down.exempt_when_ips) > 0 &&
            alltrue([for c in g.scope_down.exempt_when_ips : can(cidrnetmask(c))])
          )
        )
      ])
    ])
    error_message = "waf_web_acls[*].managed_rule_groups[*].scope_down.exempt_when_ips must be a non-empty list of valid IPv4 CIDRs."
  }

  validation {
    condition = alltrue([
      for k, acl in var.waf_web_acls : alltrue([
        for g in acl.managed_rule_groups :
        g.scope_down == null ? true : alltrue([
          for hv in values(coalesce(g.scope_down.exempt_when_headers, {})) : length(hv) > 0
        ])
      ])
    ])
    error_message = "waf_web_acls[*].managed_rule_groups[*].scope_down.exempt_when_headers values must be non-empty — an empty string would match nothing."
  }

  validation {
    condition = alltrue([
      for k, acl in var.waf_web_acls : alltrue([
        for g in acl.managed_rule_groups :
        g.scope_down == null ? true : (
          length(distinct([for hn in keys(coalesce(g.scope_down.exempt_when_headers, {})) : lower(hn)])) ==
          length(coalesce(g.scope_down.exempt_when_headers, {}))
        )
      ])
    ])
    error_message = "waf_web_acls[*].managed_rule_groups[*].scope_down.exempt_when_headers names must be unique after lowercasing. WAF matches header names case-insensitively, so e.g. \"Host\" and \"host\" would render two conditions on the same header that can never both match, silently disabling the exemption."
  }
}

# ===== Cluster Autoscaler =====

variable "install_cluster_autoscaler" {
  description = "Install Cluster Autoscaler via Helm"
  type        = bool
  default     = true
}

variable "cluster_autoscaler_version" {
  description = "Cluster Autoscaler Helm chart version"
  type        = string
  default     = "9.58.0"
}

# ===== Storage Configuration =====

# Logging Storage (for Loki, Fluentd, etc.)
variable "storage_logging_enabled" {
  description = "Create storage for centralized log storage"
  type        = bool
  default     = false
}

variable "storage_logging_bucket_name" {
  description = "Override bucket name for logging storage (default: {project}-{environment}-logging)"
  type        = string
  default     = null
}

variable "storage_logging_namespace" {
  description = "Kubernetes namespace for logging service account"
  type        = string
  default     = "monitoring"
}

variable "storage_logging_service_account" {
  description = "Kubernetes service account name for logging access"
  type        = string
  default     = "loki"
}

variable "storage_logging_lifecycle" {
  description = "Lifecycle policy for logging storage"
  type = object({
    transition_to_ia_days      = number
    transition_to_glacier_days = number
    expiration_days            = number
  })
  default = {
    transition_to_ia_days      = 30  # Move to IA after 30 days
    transition_to_glacier_days = 90  # Move to Glacier after 90 days
    expiration_days            = 365 # Delete after 1 year
  }
}

# General Purpose Storage
variable "storage_general_enabled" {
  description = "Create general purpose storage"
  type        = bool
  default     = true
}

variable "storage_general_bucket_name" {
  description = "Override bucket name for general storage (default: {project}-{environment}-storage)"
  type        = string
  default     = null
}

variable "storage_general_namespace" {
  description = "Kubernetes namespace for storage service account"
  type        = string
  default     = "default"
}

variable "storage_general_service_account" {
  description = "Kubernetes service account name for storage access"
  type        = string
  default     = "app-storage"
}

variable "storage_general_versioning" {
  description = "Enable versioning on storage"
  type        = bool
  default     = true
}

variable "storage_general_encryption_type" {
  description = "Encryption type for storage (AES256 or aws:kms)"
  type        = string
  default     = "AES256"
  validation {
    condition     = contains(["AES256", "aws:kms"], var.storage_general_encryption_type)
    error_message = "Must be AES256 or aws:kms."
  }
}

variable "storage_general_cors_origins" {
  description = "Browser origins allowed to call the general storage bucket directly (presigned uploads). Empty disables CORS, which blocks every browser upload."
  type        = list(string)
  default     = []
}

variable "storage_general_lifecycle_enabled" {
  description = "Enable lifecycle policies on storage"
  type        = bool
  default     = true
}

variable "storage_general_lifecycle" {
  description = "Lifecycle policy for storage"
  type = object({
    transition_to_ia_days              = number
    noncurrent_version_expiration_days = number
  })
  default = {
    transition_to_ia_days              = 90 # Move to Intelligent Tiering after 90 days
    noncurrent_version_expiration_days = 30 # Delete old versions after 30 days
  }
}

# ===== Teleport Access Configuration =====

variable "access_mode" {
  description = "K8s API access mode (teleport or vpn)"
  type        = string
  default     = "teleport"
  validation {
    condition     = contains(["teleport", "vpn"], var.access_mode)
    error_message = "access_mode must be 'teleport' or 'vpn'"
  }
}

variable "vpn_gateway_ips" {
  description = "VPN gateway IPs (legacy, for vpn mode)"
  type        = list(string)
  default     = []
}

variable "teleport_proxy_address" {
  description = "Teleport proxy address as host:port (required when access_mode = teleport). Defaults to empty — supply your own Teleport proxy."
  type        = string
  default     = ""
}

variable "teleport_join_token" {
  description = "Teleport agent join token (used for all services: kube, app, db, discovery)"
  type        = string
  default     = null
  sensitive   = true
}

variable "teleport_ca_pin" {
  description = "Teleport CA pin (optional, recommended for prod)"
  type        = string
  default     = null
  sensitive   = true
}

variable "teleport_version" {
  description = "Teleport version"
  type        = string
  default     = "18.5.1"
}

variable "teleport_agent_chart_repository" {
  description = "Helm repository for the teleport-kube-agent chart (e.g. https://charts.releases.teleport.dev or oci://your-registry/charts). Required when access_mode = teleport — supply your own."
  type        = string
  default     = ""
}

variable "teleport_agent_image" {
  description = "Container image reference for the Teleport agent (e.g. your-registry/teleport-distroless). Leave empty to use the chart's default image; set to pull from your own registry (required for egress-restricted clusters)."
  type        = string
  default     = ""
}

variable "teleport_gateway_ip" {
  description = "Static IP of the egress gateway proxy. When set, hostAliases route the Teleport proxy hostname through this IP so all agent traffic exits via a single static IP. Defaults to null (disabled) — supply your deployment's egress IP."
  type        = string
  default     = null
}

variable "teleport_db_enabled" {
  description = "Enable Teleport database service for RDS"
  type        = bool
  default     = true
}

# ===== EKS Access Control =====

variable "cluster_admin_arns" {
  description = "List of IAM user/role ARNs to grant cluster admin access (system:masters). Empty list = no additional admins. Supports AWS SSO roles."
  type        = list(string)
  default     = []
  validation {
    condition = alltrue([
      for arn in var.cluster_admin_arns :
      can(regex("^arn:aws:iam::[0-9]{12}:(user|role)/", arn))
    ])
    error_message = "Each ARN must be a valid IAM user or role ARN. Examples: arn:aws:iam::123456789012:user/username, arn:aws:iam::123456789012:role/rolename, or arn:aws:iam::123456789012:role/aws-reserved/sso.amazonaws.com/region/AWSReservedSSO_PermissionSetName_suffix"
  }
}

# ===== Terraform Cloud Agent Configuration =====

variable "tfc_agent_enabled" {
  description = "Deploy Terraform Cloud Agent for private cluster access"
  type        = bool
  default     = false
}

variable "tfc_agent_token" {
  description = "Terraform Cloud Agent token (sensitive, set via TF_VAR_tfc_agent_token)"
  type        = string
  default     = null
  sensitive   = true
}

variable "tfc_agent_version" {
  description = "TFC Agent container image tag"
  type        = string
  default     = "1.28.5"
}

# ===== Private Cluster Configuration =====

variable "private_cluster_enabled" {
  description = <<-EOT
    Enable fully private cluster API (no public endpoint). The private
    endpoint is reachable from inside the VPC (the node security group is
    allowed by default); grant additional in-VPC or DX/VPN sources with
    private_network_access_cidrs. Terraform must then drive the API from a
    source with a path to the private endpoint — an in-VPC bastion / CI
    runner, or the in-cluster TFC agent (tfc_agent_enabled). This is no
    longer coupled to tfc_agent_enabled: any in-VPC runner works.
  EOT
  type        = bool
  default     = false
}

# ===== Workload Identity =====
#
# Pod Identity and IRSA are NOT mutually exclusive — AWS supports both
# on the same cluster, selected per workload. Populate pod_identity_roles
# for services that want EKS-level associations (exact namespace match),
# irsa_roles for services that need wildcard namespace patterns via the
# OIDC trust policy. Either map empty = that mechanism produces no
# resources. The Pod Identity Agent addon is installed automatically
# whenever pod_identity_roles is non-empty (see eks-addons.tf).

variable "pod_identity_roles" {
  description = <<-EOT
    Map of service names to Pod Identity configurations. Each entry
    creates an EKS Pod Identity Association linking the ServiceAccount
    to an IAM role. Provide EITHER:
    - policy_statements → this module creates the IAM role (with the
      pods.eks.amazonaws.com trust) and an IAM policy from the
      statements, or
    - role_arn → bind to a pre-existing, externally-managed IAM role
      (its trust + permissions are managed outside this module; the
      module creates only the association).

    Pod Identity bindings require an exact match on (namespace,
    service_account) — wildcards are not supported by the AWS API.
    For wildcard namespace matching, use irsa_roles instead.

    Independent of irsa_roles — both may be populated on the same
    cluster. A non-empty map also installs the Pod Identity Agent addon.
  EOT
  type = map(object({
    namespace       = string
    service_account = string
    role_arn        = optional(string)
    policy_statements = optional(list(object({
      sid       = string
      actions   = list(string)
      resources = list(string)
    })), [])
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, v in var.pod_identity_roles :
      (v.role_arn != null) != (length(v.policy_statements) > 0)
    ])
    error_message = "Each pod_identity_roles entry must set exactly one of: role_arn (bind to an externally-managed role) or a non-empty policy_statements list (module creates the role)."
  }

  validation {
    condition = alltrue([
      for k, v in var.pod_identity_roles :
      v.role_arn == null || can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/.+$", v.role_arn))
    ])
    error_message = "pod_identity_roles[].role_arn must be a valid IAM role ARN (arn:aws:iam::<account-id>:role/<name>) when set. This also rejects an empty string, which would otherwise surface as an opaque coalesce() error at apply time."
  }

  validation {
    condition     = alltrue([for k, v in var.pod_identity_roles : alltrue([for s in v.policy_statements : can(regex("^[A-Za-z0-9]+$", s.sid))])])
    error_message = "pod_identity_roles[].policy_statements[].sid must be non-empty and match [A-Za-z0-9]+ (IAM Sid constraint — no hyphens, spaces, or underscores)."
  }

  validation {
    condition     = alltrue([for k, v in var.pod_identity_roles : alltrue([for s in v.policy_statements : length(s.actions) > 0 && length(s.resources) > 0])])
    error_message = "pod_identity_roles[].policy_statements[].actions and .resources must each be non-empty (IAM rejects empty Action/Resource arrays as MalformedPolicyDocument at apply time)."
  }

  validation {
    condition     = alltrue([for k, v in var.pod_identity_roles : length(v.namespace) > 0])
    error_message = "pod_identity_roles[].namespace must be non-empty."
  }

  validation {
    condition     = alltrue([for k, v in var.pod_identity_roles : length(v.service_account) > 0])
    error_message = "pod_identity_roles[].service_account must be non-empty."
  }
}

# ===== IRSA (IAM Roles for Service Accounts) =====
# IRSA is the older OIDC-based mechanism that complements Pod
# Identity. Use IRSA when you need wildcard semantics on the
# namespace — Pod Identity requires exact-match (namespace,
# service_account) tuples while IRSA's IAM trust policy can match
# `system:serviceaccount:<namespace_pattern>:<service_account>` via
# `StringLike`. This makes IRSA the right tool when namespaces are
# created or removed at the Kubernetes level without an accompanying
# terraform apply (for example, tenant-per-namespace patterns).

variable "irsa_roles" {
  description = <<-EOT
    Map of service names to IRSA (IAM Roles for Service Accounts)
    configurations. Each entry creates:
    - An IAM role with a federated trust policy referencing the
      cluster's OIDC provider, using `StringLike` on the `:sub` claim
      so wildcards in `namespace_pattern` are honored
    - An IAM policy with the entry's policy_statements

    The K8s ServiceAccount(s) that match the namespace_pattern must
    be created separately (typically via your manifests / GitOps)
    with the annotation `eks.amazonaws.com/role-arn = <role_arn>`
    (the role ARN is exposed in the `irsa` output). Once that's in
    place, adding a new matching namespace does NOT require a
    terraform apply — the wildcard already covers it.

    `namespace_pattern` supports IAM `StringLike` glob syntax: `*`
    matches any sequence of characters, `?` matches a single
    character. Example values: "core" (exact match), "tenant-*",
    "*-prod".

    Independent of pod_identity_roles — both may be populated on the
    same cluster.
  EOT
  type = map(object({
    namespace_pattern = string
    service_account   = string
    policy_statements = list(object({
      sid       = string
      actions   = list(string)
      resources = list(string)
    }))
  }))
  default = {}

  validation {
    condition     = alltrue([for k, v in var.irsa_roles : length(v.policy_statements) > 0])
    error_message = "Each irsa_roles entry must have at least one policy_statement."
  }

  validation {
    condition     = alltrue([for k, v in var.irsa_roles : alltrue([for s in v.policy_statements : can(regex("^[A-Za-z0-9]+$", s.sid))])])
    error_message = "irsa_roles[].policy_statements[].sid must be non-empty and match [A-Za-z0-9]+ (IAM Sid constraint — no hyphens, spaces, or underscores)."
  }

  validation {
    condition     = alltrue([for k, v in var.irsa_roles : alltrue([for s in v.policy_statements : length(s.actions) > 0 && length(s.resources) > 0])])
    error_message = "irsa_roles[].policy_statements[].actions and .resources must each be non-empty (IAM rejects empty Action/Resource arrays as MalformedPolicyDocument at apply time)."
  }

  validation {
    condition     = alltrue([for k, v in var.irsa_roles : length(v.namespace_pattern) > 0])
    error_message = "irsa_roles[].namespace_pattern must be non-empty (use \"*\" to match any namespace, though that is rarely a good idea)."
  }

  validation {
    condition     = alltrue([for k, v in var.irsa_roles : length(v.service_account) > 0 && !strcontains(v.service_account, "*") && !strcontains(v.service_account, "?")])
    error_message = "irsa_roles[].service_account must be a non-empty exact name — wildcards (`*` or `?`) are not allowed. An empty value produces a trust-policy `:sub` of `system:serviceaccount:<ns>:` which never matches a real ServiceAccount; a wildcard like `*` produces `system:serviceaccount:<ns>:*` which grants ANY ServiceAccount in the matching namespaces, defeating the per-SA blast-radius isolation. Use `namespace_pattern` for wildcard matching."
  }
}

# ===== Karpenter =====

variable "karpenter_enabled" {
  description = <<-EOT
    Create the IAM prerequisites for Karpenter: a controller role bound by Pod
    Identity to the karpenter/karpenter ServiceAccount, and a node role +
    instance profile for the EC2 instances Karpenter launches.

    This creates IAM and the node access entry ONLY. The controller, NodePools
    and EC2NodeClasses are deployed from the gitops repo, which references the
    `karpenter_node_instance_profile` output as EC2NodeClass
    `spec.instanceProfile`.

    Requires cluster_authentication_mode = "API" or "API_AND_CONFIG_MAP":
    the Karpenter node role joins via an access entry.
  EOT
  type        = bool
  default     = false
}

variable "karpenter_node_role_additional_policies" {
  description = <<-EOT
    Extra managed-policy ARNs to attach to the Karpenter node role, on top of
    the four an EKS worker always needs (WorkerNode, CNI, ECR read, SSM core).
  EOT
  type        = list(string)
  default     = []
}

# ===== EKS access mode =====

variable "cluster_authentication_mode" {
  description = <<-EOT
    How IAM principals are granted access to the cluster.

    - CONFIG_MAP      aws-auth ConfigMap only (default; what every existing
                      cluster uses).
    - API             EKS access entries only. aws-auth is ignored by the
                      cluster — do not pick this for a cluster whose nodes
                      currently map through aws-auth.
    - API_AND_CONFIG_MAP  Both. The migration path: entries take effect while
                      aws-auth keeps working, so a cluster can move over
                      without a window where nodes cannot join.

    AWS does not allow narrowing this (API_AND_CONFIG_MAP -> CONFIG_MAP, or
    API -> anything). Widening is in-place and safe.
  EOT
  type        = string
  default     = "CONFIG_MAP"

  validation {
    condition     = contains(["CONFIG_MAP", "API", "API_AND_CONFIG_MAP"], var.cluster_authentication_mode)
    error_message = "cluster_authentication_mode must be CONFIG_MAP, API, or API_AND_CONFIG_MAP."
  }
}
