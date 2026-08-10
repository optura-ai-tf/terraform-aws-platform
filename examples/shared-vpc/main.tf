# Example: bring-your-own / RAM-shared VPC (create_vpc = false).
#
# The VPC, its subnets, routing, IGW/NAT, Transit Gateway attachment, the 100.64
# pod secondary CIDR, and the S3 gateway endpoint are all owned by another
# account (e.g. shared in via AWS RAM). This module creates NO network resources
# — it only consumes the supplied subnet IDs and builds the EKS cluster, node
# groups, security groups, addons, RDS, and the pod ENIConfigs on top.
#
# See README.md for the OWNER-ACCOUNT CHECKLIST the owning account must satisfy
# before this module can apply. The subnet IDs below are placeholders.
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

  # ----- Consume an externally-owned (RAM-shared) VPC -----
  create_vpc = false
  vpc_id     = "[REPLACE]"

  # One subnet per AZ in each tier, supplied by the owner account. The module
  # creates no subnets, no secondary CIDR, and no routing of its own.
  node_subnet_ids     = ["[REPLACE]", "[REPLACE]", "[REPLACE]"]
  lb_subnet_ids       = ["[REPLACE]", "[REPLACE]", "[REPLACE]"]
  database_subnet_ids = ["[REPLACE]", "[REPLACE]", "[REPLACE]"]

  # Pods run on the owner-associated 100.64 secondary CIDR via these existing
  # pod subnets; the module points ENIConfigs at them rather than creating them.
  pod_isolation_enabled = true
  pod_subnet_ids        = ["[REPLACE]", "[REPLACE]", "[REPLACE]"]

  # ----- Access -----
  access_mode                     = "teleport"
  teleport_proxy_address          = "[REPLACE]:443"
  teleport_agent_chart_repository = "https://charts.releases.teleport.dev"
  # teleport_join_token sourced from the environment:
  #   export TF_VAR_teleport_join_token="..."
}
