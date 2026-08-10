# Inputs for the corp-connected, module-owned private-VPC example.
#
# main.tf already wires these values inline; this file mirrors them so you can
# copy the example and drive it with `-var-file=example.tfvars` if you prefer
# tfvars over inline module arguments. The Teleport join token is sensitive —
# supply it at runtime via TF_VAR_teleport_join_token, never in this file.
#
# Fill in the `[REPLACE]` placeholders below with your own values.

environment  = "prod"
region       = "us-east-1"
project_name = "replaceme" # [REPLACE] — 3-12 lowercase alphanumeric

cluster_admin_arns = ["arn:aws:iam::000000000000:role/[REPLACE]"]

# Fully-private VPC: no internet gateway, egress hairpins through the corp TGW.
igw_enabled = false
egress_mode = "transit_gateway"

# Routable tier (node + internal LB only).
vpc_cidr          = "10.0.0.0/24"
node_subnet_cidrs = ["10.0.0.0/27", "10.0.0.32/27", "10.0.0.64/27"]
lb_subnet_cidrs   = ["10.0.0.96/28", "10.0.0.112/28", "10.0.0.128/28"]

# Database tier (hidden from the corp network).
database_subnet_cidrs = ["10.0.0.192/28", "10.0.0.208/28", "10.0.0.224/28"]

# Pods on a non-routed 100.64 secondary CIDR.
pod_isolation_enabled = true
pod_secondary_cidr    = "100.64.0.0/21"
pod_subnet_cidrs      = ["100.64.0.0/23", "100.64.2.0/23", "100.64.4.0/23"]

# Transit Gateway: advertise only node + LB; database stays opt-in.
transit_gateway_id                 = "[REPLACE]"
transit_gateway_cidr_blocks        = ["10.10.0.0/16", "192.168.0.0/16"]
expose_database_to_transit_gateway = false

access_mode                     = "teleport"
teleport_proxy_address          = "[REPLACE]:443"
teleport_agent_chart_repository = "https://charts.releases.teleport.dev"
