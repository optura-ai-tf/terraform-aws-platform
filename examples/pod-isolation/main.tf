# Corp-connected, fully-private cluster where THIS module owns the VPC.
#
# The VPC has no internet gateway: egress hairpins through the customer network
# over a Transit Gateway, and pods live on a non-routed 100.64 secondary CIDR so
# only the node + internal-LB tiers consume routable address space. The corp
# network only ever sees the routable /24 worth of node + LB IPs; pod and
# database IPs stay hidden inside the VPC. See README.md for the layout.
#
# Fill in the `[REPLACE]` placeholders below with your own values before
# `terraform apply`; other values are sizing/architecture defaults.

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

module "platform" {
  source = "../../"

  # ----- Required -----
  environment  = "prod"
  region       = "us-east-1"
  project_name = "replaceme" # [REPLACE] — 3-12 lowercase alphanumeric

  # Replace with a real IAM principal from `aws sts get-caller-identity`.
  # The role used to apply terraform owns the cluster, this gives additional
  # roles or users admin access to the cluster.
  cluster_admin_arns = ["arn:aws:iam::000000000000:role/[REPLACE]"]

  # ----- Network: module owns a fully-private /24 VPC -----
  # No internet gateway and no public subnet tier; the only off-VPC path is the
  # Transit Gateway (and VPC endpoints for AWS APIs).
  igw_enabled = false
  egress_mode = "transit_gateway"

  # Routable tier — only node ENIs and internal load balancers draw from it.
  vpc_cidr          = "10.0.0.0/24"
  node_subnet_cidrs = ["10.0.0.0/27", "10.0.0.32/27", "10.0.0.64/27"]
  lb_subnet_cidrs   = ["10.0.0.96/28", "10.0.0.112/28", "10.0.0.128/28"]

  # Database tier — RDS/Aurora ENIs only, hidden from the corp network.
  database_subnet_cidrs = ["10.0.0.192/28", "10.0.0.208/28", "10.0.0.224/28"]

  # Pods on a non-routed 100.64 secondary CIDR (RFC 6598). The corp network never
  # has to account for pod IPs because they are never advertised to the TGW.
  pod_isolation_enabled = true
  pod_secondary_cidr    = "100.64.0.0/21"
  pod_subnet_cidrs      = ["100.64.0.0/23", "100.64.2.0/23", "100.64.4.0/23"]

  # ----- Transit Gateway -----
  # Attach to the shared corp TGW and route the listed corp/on-prem CIDRs through
  # it. Only the node + LB tiers are advertised; the database stays opt-in.
  transit_gateway_id          = "[REPLACE]"
  transit_gateway_cidr_blocks = ["10.10.0.0/16", "192.168.0.0/16"]

  # Database is NOT exposed over the TGW by default — application traffic to it
  # stays in-VPC and admin access goes through Teleport. Flip to true only if an
  # external network genuinely needs a direct database path.
  expose_database_to_transit_gateway = false

  # ----- Private API endpoint -----
  # Make the cluster genuinely private: no public API endpoint. The API is then
  # reachable only from inside the VPC and from the corp CIDRs that arrive over
  # the TGW. private_network_access_cidrs opens 443 to those CIDRs so Terraform
  # and operators can drive the API without attaching the node security group to
  # the runner. Apply from an in-VPC runner (bastion / CI) — a private cluster
  # cannot be reached on its first apply from outside the network.
  private_cluster_enabled      = true
  private_network_access_cidrs = ["10.10.0.0/16", "192.168.0.0/16"] # match transit_gateway_cidr_blocks

  # ----- Access -----
  access_mode                     = "teleport"
  teleport_proxy_address          = "[REPLACE]:443"
  teleport_agent_chart_repository = "https://charts.releases.teleport.dev"
  # teleport_join_token sourced from the environment:
  #   export TF_VAR_teleport_join_token="..."
}
