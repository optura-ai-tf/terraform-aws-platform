# Runnable reference configuration exercising every populated input the module
# accepts. Values mirror a cost-optimized dev environment; copy and adjust for
# your own account before applying.
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
  environment  = "dev"
  region       = "us-east-1"
  project_name = "replaceme" # [REPLACE] — 3-12 lowercase alphanumeric

  tags = {
    CostCenter  = "Engineering"
    Owner       = "Platform Team"
    Environment = "dev"
  }

  # Replace with a real IAM principal from `aws sts get-caller-identity`.
  # The role used to apply terraform owns the cluster, this gives additional
  # roles or users admin access to the cluster.
  cluster_admin_arns = ["arn:aws:iam::000000000000:role/[REPLACE]"]

  # ----- Node Groups -----
  node_groups = {
    system = {
      instance_types = ["t3a.medium"]
      min_size       = 1
      max_size       = 2
      desired_size   = 1
      disk_size      = 50
      labels         = { "workload-type" = "system" }
      taints         = [{ key = "CriticalAddonsOnly", value = "true", effect = "NO_SCHEDULE" }]
    }
    support = {
      instance_types = ["t3a.medium"]
      min_size       = 0
      max_size       = 2
      desired_size   = 1
      disk_size      = 50
      labels         = { "workload-type" = "support" }
      taints         = []
    }
    application = {
      instance_types = ["t3a.medium"]
      min_size       = 0
      max_size       = 5
      desired_size   = 1
      disk_size      = 100
      labels         = { "workload-type" = "application" }
      taints         = []
    }
  }

  # ----- Network (v0.3.0 default layout) -----
  # A tight /24 routable VPC split into a small node tier and an even smaller
  # internal-LB tier (public + database default to /28s in the same /24). Pods do
  # NOT draw from this routable space — they live in a non-routed 100.64
  # secondary CIDR via VPC CNI custom networking (default on).
  vpc_cidr          = "10.0.0.0/24"
  node_subnet_cidrs = ["10.0.0.0/27", "10.0.0.32/27", "10.0.0.64/27"]
  lb_subnet_cidrs   = ["10.0.0.96/28", "10.0.0.112/28", "10.0.0.128/28"]

  # Pods on a non-routed secondary CIDR (the default). Keeps pod churn out of
  # the routable address space so the primary CIDR can stay a /24.
  pod_isolation_enabled = true
  pod_secondary_cidr    = "100.64.0.0/21"
  pod_subnet_cidrs      = ["100.64.0.0/23", "100.64.2.0/23", "100.64.4.0/23"]

  single_nat_gateway = true

  # Optional: attach the VPC to an existing Transit Gateway (off by default).
  # transit_gateway_id          = "tgw-0123456789abcdef0"
  # transit_gateway_cidr_blocks = ["10.1.0.0/16", "10.2.0.0/16"]

  # ----- EKS -----
  enable_cluster_encryption = false

  # ----- Database -----
  rds_instance_class      = "db.t4g.micro"
  rds_multi_az            = false
  rds_deletion_protection = false
  rds_skip_final_snapshot = true

  # ----- Access Mode -----
  access_mode                     = "teleport"
  teleport_proxy_address          = "[REPLACE]:443"
  teleport_agent_chart_repository = "https://charts.releases.teleport.dev"
  # teleport_join_token sourced from the environment:
  #   export TF_VAR_teleport_join_token="..."

  # ----- WAF (off by default) -----
  # One regional Web ACL per key. Attach waf_web_acl_arns["prod"] to the
  # controller-managed ALB in gitops via alb.ingress.kubernetes.io/wafv2-acl-arn.
  waf_web_acls = {
    prod = {
      geo_rules = [{
        name          = "block-non-us"
        priority      = 1
        action        = "block"
        country_codes = ["US"]
        negate        = true
      }]

      rate_based_rules = [{
        name     = "global-rate-limit"
        priority = 0
        limit    = 2000
      }]

      managed_rule_groups = [
        # CrossSiteScripting_BODY -> count so it only emits its label; the
        # label_rules entry below re-blocks on it outside the upload route.
        {
          name     = "AWSManagedRulesCommonRuleSet"
          priority = 10
          rule_action_overrides = [
            { name = "CrossSiteScripting_BODY", action_to_use = "count" },
          ]
        },
        { name = "AWSManagedRulesKnownBadInputsRuleSet", priority = 20 },
        # SQLi_BODY -> count, so the sqli-body-except-import label rule below
        # gets to run; a blocking emitter would terminate the request first.
        {
          name     = "AWSManagedRulesSQLiRuleSet"
          priority = 30
          rule_action_overrides = [
            { name = "SQLi_BODY", action_to_use = "count" },
          ]
        },
        { name = "AWSManagedRulesLinuxRuleSet", priority = 40 },
        { name = "AWSManagedRulesUnixRuleSet", priority = 50 },
        { name = "AWSManagedRulesAmazonIpReputationList", priority = 60 },
        # scope_down, multi-condition: inspect everything except requests from
        # these IPs, to this host, from this client. Every condition must match,
        # so each one narrows the exemption. Renders a negated and_statement.
        {
          name     = "AWSManagedRulesAnonymousIpList"
          priority = 70
          scope_down = {
            exempt_when_ips = ["198.51.100.0/28"]
            exempt_when_headers = {
              "Host"       = "app.example.com"
              "User-Agent" = "my-test-harness/1"
            }
          }
        },
        # scope_down, single condition: nested directly under not_statement,
        # since WAF requires at least two statements in an and_statement.
        {
          name       = "AWSManagedRulesAdminProtectionRuleSet"
          priority   = 80
          scope_down = { exempt_when_headers = { "Host" = "admin.example.com" } }
        },
      ]

      label_rules = [
        # Block on the label everywhere except the upload route. The module
        # anchors the regex as ^(...)$.
        {
          name              = "xss-body-except-uploads"
          priority          = 11
          label             = "awswaf:managed:aws:core-rule-set:CrossSiteScripting_Body"
          exempt_path_regex = "/files/[^/]+/upload"
        },
        {
          name              = "sqli-body-except-import"
          priority          = 31
          label             = "awswaf:managed:aws:sql-database:SQLi_Body"
          exempt_path_regex = "/import"
        },
      ]

      logging = { enabled = true, only_blocked = true }
    }
  }
}
