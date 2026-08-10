# Inputs for the bring-your-own / RAM-shared VPC example.
#
# main.tf wires these inline; this file mirrors them so you can copy the example
# and drive it with `-var-file=example.tfvars` if you prefer. Replace every
# placeholder ID with the real VPC and subnet IDs the owner account shared to
# you. Supply the Teleport join token at runtime via TF_VAR_teleport_join_token.
#
# Fill in the `[REPLACE]` placeholders below with your own values.

environment  = "prod"
region       = "us-east-1"
project_name = "replaceme" # [REPLACE] — 3-12 lowercase alphanumeric

cluster_admin_arns = ["arn:aws:iam::000000000000:role/[REPLACE]"]

# Consume the shared VPC; the module creates no network resources.
create_vpc = false
vpc_id     = "[REPLACE]"

node_subnet_ids     = ["[REPLACE]", "[REPLACE]", "[REPLACE]"]
lb_subnet_ids       = ["[REPLACE]", "[REPLACE]", "[REPLACE]"]
database_subnet_ids = ["[REPLACE]", "[REPLACE]", "[REPLACE]"]

pod_isolation_enabled = true
pod_subnet_ids        = ["[REPLACE]", "[REPLACE]", "[REPLACE]"]

access_mode                     = "teleport"
teleport_proxy_address          = "[REPLACE]:443"
teleport_agent_chart_repository = "https://charts.releases.teleport.dev"
