# ===== Network Outputs =====

output "network_id" {
  description = "ID of the virtual network"
  value       = local.vpc_id
}

output "network_name" {
  description = "Name of the virtual network (the module's Name tag in create mode; the consumed VPC's Name tag in consumer mode)"
  value       = var.create_vpc ? aws_vpc.main[0].tags["Name"] : lookup(data.aws_vpc.shared[0].tags, "Name", null)
}

output "network_cidr" {
  description = "CIDR block of the virtual network"
  value       = local.vpc_cidr_block
}

output "node_subnet_ids" {
  description = "IDs of node subnets (where EKS worker nodes run)"
  value       = local.node_subnet_ids
}

output "cluster_subnet_ids" {
  description = "IDs of node subnets (where EKS worker nodes run). Legacy alias for node_subnet_ids."
  value       = local.node_subnet_ids
}

output "lb_subnet_ids" {
  description = "IDs of internal load balancer subnets"
  value       = local.lb_subnet_ids
}

output "ingress_subnet_ids" {
  description = "IDs of public subnets for internet-facing load balancers. Empty in consumer mode (create_vpc = false): a shared/RAM-shared VPC is private-by-design here — ingress arrives via the corporate network/Transit Gateway and internal LBs, and any public edge is the owner account's concern. There is intentionally no public_subnet_ids consumer input."
  value       = aws_subnet.public[*].id
}

output "database_subnet_ids" {
  description = "IDs of database subnets"
  value       = var.rds_enabled ? local.database_subnet_ids : []
}

output "pod_subnet_ids" {
  description = "IDs of the subnets pods draw IPs from via VPC CNI custom networking (empty when pod isolation is disabled)"
  # Honor the description regardless of what pod_subnet_ids holds: when isolation
  # is off there are no custom-networking pod subnets, so a leftover BYO
  # pod_subnet_ids value must not surface here and mislead automation.
  value = var.pod_isolation_enabled ? local.pod_subnet_ids_effective : []
}

output "pod_secondary_cidr_association_id" {
  description = "ID of the VPC IPv4 CIDR association for the pod secondary CIDR. Non-null only when this module owns the pod subnets (create_vpc = true, pod isolation on, no BYO pod subnets); null when isolation is off or the association is owned externally (shared/BYO VPC)."
  value       = local.pod_owns ? aws_vpc_ipv4_cidr_block_association.pods[0].id : null
}

output "eniconfig_manifests" {
  description = "Map of AZ name → rendered ENIConfig YAML applied to drive VPC CNI custom networking (one per AZ). Empty map when pod isolation is disabled."
  value       = local.eniconfig_yaml
}

output "transit_gateway_id" {
  description = "Transit Gateway ID the VPC is attached to (null if not attached)"
  value       = var.transit_gateway_id
}

output "transit_gateway_attachment_id" {
  description = "Transit Gateway VPC attachment ID (null unless this module owns the attachment)"
  value       = local.tgw_owns ? aws_ec2_transit_gateway_vpc_attachment.main[0].id : null
}

# ===== EKS Cluster Outputs =====

output "cluster_name" {
  description = "Name of the Kubernetes cluster"
  value       = aws_eks_cluster.main.name
}

output "cluster_id" {
  description = "Name of the Kubernetes cluster (EKS uses name as ID)"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "Endpoint for Kubernetes cluster API server"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the cluster"
  value       = aws_security_group.eks_cluster_additional.id
}

output "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL for the cluster"
  value       = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data for cluster"
  value       = aws_eks_cluster.main.certificate_authority[0].data
  sensitive   = true
}

output "kubectl_config_command" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.main.name}"
}

# ===== Container Registry Outputs =====

output "registry_url" {
  description = "URL of the container registry (created or existing, null if not configured)"
  value       = local.ecr_repository_url
}

output "registry_id" {
  description = "ARN of the container registry (created or existing, null if not configured)"
  value       = local.ecr_repository_arn
}

output "registry_name" {
  description = "Name of the container registry (created or existing, null if not configured)"
  value       = local.ecr_repository_name
}

output "registry_created" {
  description = "Whether a new container registry was created"
  value       = var.registry_enabled
}

output "registry_base_url" {
  description = "Base registry URL for the AWS account"
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

# ===== ACM Certificate Outputs =====

output "acm_certificate_arn" {
  description = "ARN of the ACM certificate (created or existing, null if not configured)"
  value       = local.acm_certificate_arn
}

output "acm_certificate_domain" {
  description = "Domain name of the ACM certificate (as specified in acm_domain_name)"
  value       = var.acm_create && var.acm_domain_name != null ? aws_acm_certificate.main[0].domain_name : var.acm_domain_name
}

output "acm_certificate_status" {
  description = "Status of the created ACM certificate (if created)"
  value       = var.acm_create && var.acm_domain_name != null ? aws_acm_certificate.main[0].status : null
}

output "acm_created" {
  description = "Whether a new ACM certificate was created"
  value       = var.acm_create
}

# ===== Database Outputs =====
#
# Multi-database fanout: each named DB in var.databases is exposed via the
# map outputs below (database_endpoints, database_names, etc.). The legacy
# singular outputs (database_endpoint, database_admin_username,
# database_admin_password) are preserved as aliases for the "core" entry so
# existing customers see no change.

# The legacy singular aliases and the map outputs below read from the
# engine-agnostic normalized locals in rds.tf (local.db_*), so they resolve
# identically whether "core" is an RDS instance or an Aurora cluster.

output "database_server_name" {
  description = "Identifier of the \"core\" database server (legacy alias)"
  value       = try(local.db_identifiers["core"], null)
}

output "database_endpoint" {
  description = "Endpoint (host:port) of the \"core\" database server (legacy alias)"
  value       = try(local.db_endpoints["core"], null)
}

output "database_address" {
  description = "Address of the \"core\" database server (without port, legacy alias)"
  value       = try(local.db_hosts["core"], null)
}

output "database_port" {
  description = "Port of the \"core\" database server (legacy alias)"
  value       = try(local.db_ports["core"], null)
}

output "database_name" {
  description = "Initial database name on the \"core\" server (legacy alias)"
  value       = try(local.db_names["core"], null)
}

output "database_admin_username" {
  description = "Administrator username for the \"core\" database (legacy alias)"
  value       = try(local.db_usernames["core"], null)
  sensitive   = true
}

output "database_admin_password" {
  description = "Administrator password for the \"core\" database (legacy alias)"
  value       = try(random_password.rds["core"].result, null)
  sensitive   = true
}

# ===== Multi-database map outputs =====

output "database_endpoints" {
  description = "Map of named DB key → endpoint (host:port). Aurora keys resolve to the cluster writer endpoint."
  value       = local.db_endpoints
}

output "database_reader_endpoints" {
  description = "Map of Aurora DB key → reader endpoint (host:port), matching database_endpoints. Empty for engine = \"rds\" keys, which have no separate reader endpoint."
  value       = local.db_reader_endpoints
}

output "database_names" {
  description = "Map of named DB key → initial database name"
  value       = local.db_names
}

output "database_admin_usernames" {
  description = "Map of named DB key → administrator username"
  value       = local.db_usernames
  sensitive   = true
}

output "database_admin_passwords" {
  description = "Map of named DB key → administrator password"
  value       = { for k, v in random_password.rds : k => v.result }
  sensitive   = true
}

# ===== IAM Outputs =====

output "oidc_provider_arn" {
  description = "ARN of the OIDC provider for IRSA"
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "node_group_role_arn" {
  description = "ARN of the EKS node group IAM role"
  value       = aws_iam_role.eks_nodes.arn
}

# ===== Storage Outputs =====

output "logging_storage_name" {
  description = "Name of the logging storage"
  value       = var.storage_logging_enabled ? aws_s3_bucket.logging[0].id : null
}

output "logging_storage_id" {
  description = "ID/ARN of the logging storage"
  value       = var.storage_logging_enabled ? aws_s3_bucket.logging[0].arn : null
}

output "logging_storage_region" {
  description = "Region of the logging storage"
  value       = var.storage_logging_enabled ? aws_s3_bucket.logging[0].region : null
}

output "logging_storage_role_id" {
  description = "IAM role ARN for logging workload (IRSA)"
  value       = var.storage_logging_enabled ? aws_iam_role.logging[0].arn : null
}

output "general_storage_name" {
  description = "Name of the general storage"
  value       = var.storage_general_enabled ? aws_s3_bucket.storage[0].id : null
}

output "general_storage_id" {
  description = "ID/ARN of the general storage"
  value       = var.storage_general_enabled ? aws_s3_bucket.storage[0].arn : null
}

output "general_storage_region" {
  description = "Region of the general storage"
  value       = var.storage_general_enabled ? aws_s3_bucket.storage[0].region : null
}

output "general_storage_role_id" {
  description = "IAM role ARN for storage workload (IRSA)"
  value       = var.storage_general_enabled ? aws_iam_role.storage[0].arn : null
}

# ===== Cost Estimation =====

output "estimated_monthly_cost" {
  description = "Estimated monthly cost breakdown"
  value       = <<-EOT
    Estimated monthly costs (${var.environment}):
    - EKS Control Plane: $73
    - NAT Gateways: ~$${local.nat_enabled ? (var.single_nat_gateway ? "35" : "100") : "0"}
    - EC2 Nodes: Variable based on node groups
    - RDS: ~$${var.rds_enabled ? (var.rds_multi_az ? "130" : "15-30") : "0"}
    - ECR: ~$1
    - VPC Endpoints: ~$${var.create_vpc && var.enable_vpc_endpoints ? "20" : "0"}
    - Data Transfer: Variable
    --------------------------------
    Base infrastructure: ~$${73 + 1 + (local.nat_enabled ? (var.single_nat_gateway ? 35 : 100) : 0) + (var.create_vpc && var.enable_vpc_endpoints ? 20 : 0)}/month
  EOT
}

# ===== Access Configuration =====

output "access_mode" {
  description = "Current K8s API access mode"
  value       = var.access_mode
}

output "api_endpoint_access_type" {
  description = "Type of access to the K8s API endpoint"
  value       = "Private only - requires ${var.access_mode} connectivity"
}

# ===== Cluster Access Control =====

output "cluster_admin_principals" {
  description = "List of IAM principals granted cluster admin access"
  value       = var.cluster_admin_arns
}

output "cluster_admin_count" {
  description = "Number of additional cluster admins configured"
  value       = length(var.cluster_admin_arns)
}

# ===== Teleport =====

output "teleport_db_agent_role_arn" {
  description = "IAM role ARN for Teleport database agent"
  value       = var.access_mode == "teleport" && var.teleport_db_enabled && var.rds_enabled ? aws_iam_role.teleport_db_agent[0].arn : null
}

# ===== Terraform Cloud Agent =====

output "tfc_agent_status" {
  description = "Terraform Cloud Agent deployment status"
  value = var.tfc_agent_enabled ? {
    enabled   = true
    namespace = "terraform-cloud"
  } : { enabled = false }
}

output "cluster_access_mode" {
  description = "Current cluster API access configuration"
  value = {
    private_cluster = var.private_cluster_enabled
    # A private cluster is driven from inside the VPC. Prefer the in-cluster
    # TFC agent when deployed; otherwise any in-VPC runner reaching the private
    # endpoint (see private_network_access_cidrs). Public clusters are direct.
    access_method = (
      var.private_cluster_enabled
      ? (var.tfc_agent_enabled ? "tfc-agent" : "in-vpc-runner")
      : "direct"
    )
    private_network_access_cidrs = var.private_cluster_enabled ? var.private_network_access_cidrs : []
  }
}

# ===== Pod Identity =====

output "pod_identity" {
  description = "Pod Identity configuration per service — role ARNs and associations (one entry per pod_identity_roles key). policy_arn is null for entries that bind an externally-managed role via role_arn."
  value = {
    for name, config in var.pod_identity_roles : name => {
      # Managed entries resolve to the created role/policy; external (role_arn)
      # entries have no module-managed role or policy — hence coalesce/try.
      role_arn        = coalesce(config.role_arn, try(aws_iam_role.pod_identity[name].arn, null))
      policy_arn      = try(aws_iam_policy.pod_identity[name].arn, null)
      namespace       = config.namespace
      service_account = config.service_account
      association_id  = aws_eks_pod_identity_association.pod_identity[name].association_id
    }
  }
}

# ===== IRSA =====

output "irsa" {
  description = <<-EOT
    IRSA configuration per service — role ARNs and the trust-policy
    pattern (one entry per irsa_roles key). Annotate K8s
    ServiceAccount(s) with `eks.amazonaws.com/role-arn = <role_arn>`
    to use; the trust policy uses StringLike on `:sub` so wildcards
    in namespace_pattern work without terraform apply.
  EOT
  value = {
    for name, config in var.irsa_roles : name => {
      role_arn          = aws_iam_role.irsa[name].arn
      policy_arn        = aws_iam_policy.irsa[name].arn
      namespace_pattern = config.namespace_pattern
      service_account   = config.service_account
      sub_pattern       = "system:serviceaccount:${config.namespace_pattern}:${config.service_account}"
    }
  }
}

# ===== WAF =====

output "waf_web_acl_arns" {
  description = "Map of waf_web_acls key => Web ACL ARN. Feed each ARN to gitops as the alb.ingress.kubernetes.io/wafv2-acl-arn annotation on that env's intent Ingress. Empty map when no ACLs are defined."
  value       = { for k, w in aws_wafv2_web_acl.main : k => w.arn }
}

output "waf_web_acl_ids" {
  description = "Map of waf_web_acls key => Web ACL ID. Empty map when no ACLs are defined."
  value       = { for k, w in aws_wafv2_web_acl.main : k => w.id }
}

output "waf_web_acl_names" {
  description = "Map of waf_web_acls key => Web ACL name. Empty map when no ACLs are defined."
  value       = { for k, w in aws_wafv2_web_acl.main : k => w.name }
}

output "waf_web_acl_capacities" {
  description = "Map of waf_web_acls key => WCU (Web ACL Capacity Units) consumed by that ACL's rules. Watch this against the 1500 WCU default ceiling as managed rule groups are added. Empty map when no ACLs are defined."
  value       = { for k, w in aws_wafv2_web_acl.main : k => w.capacity }
}
