# Permissive provider floors: consumers pin exact versions via their own
# lockfile. Backends and provider auth are owned by the root configuration
# that calls this module, never declared here.
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.30"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
    http = {
      source  = "hashicorp/http"
      version = ">= 3.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.0"
    }
  }
}

# AWS Provider
provider "aws" {
  region = var.region

  default_tags {
    tags = local.common_tags
  }
}

# Auto-detect if running inside Kubernetes cluster (TFC agent pod)
# When true, use in-cluster service account auth; otherwise use external EKS auth
locals {
  _sa_token_path = "/var/run/secrets/kubernetes.io/serviceaccount/token"
  _sa_ca_path    = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
  is_in_cluster  = fileexists(local._sa_token_path)
}

# In-cluster service account files — only read when running inside a K8s pod.
# Using counted data sources avoids file() evaluation entirely on remote runners,
# which prevents TFC plan/apply phase inconsistencies ("function returned an
# inconsistent result") without masking real errors when actually in-cluster.
data "local_sensitive_file" "sa_token" {
  count    = local.is_in_cluster ? 1 : 0
  filename = local._sa_token_path
}

data "local_file" "sa_ca_cert" {
  count    = local.is_in_cluster ? 1 : 0
  filename = local._sa_ca_path
}

# EKS cluster authentication data source
# Only used when NOT running in-cluster (i.e. TFC remote runner)
data "aws_eks_cluster_auth" "main" {
  count = local.is_in_cluster ? 0 : 1
  name  = aws_eks_cluster.main.name
}

# Kubernetes/Helm authentication locals
locals {
  k8s_host    = local.is_in_cluster ? "https://kubernetes.default.svc" : aws_eks_cluster.main.endpoint
  k8s_ca_cert = local.is_in_cluster ? data.local_file.sa_ca_cert[0].content : base64decode(aws_eks_cluster.main.certificate_authority[0].data)
  k8s_token   = local.is_in_cluster ? data.local_sensitive_file.sa_token[0].content : data.aws_eks_cluster_auth.main[0].token
}

# Kubernetes Provider
provider "kubernetes" {
  host                   = local.k8s_host
  cluster_ca_certificate = local.k8s_ca_cert
  token                  = local.k8s_token
}

# Helm Provider
provider "helm" {
  kubernetes = {
    host                   = local.k8s_host
    cluster_ca_certificate = local.k8s_ca_cert
    token                  = local.k8s_token
  }
}

# kubectl Provider — applies the ENIConfig CRDs that drive VPC CNI custom
# networking. The hashicorp/kubernetes provider cannot apply arbitrary CRDs
# without a typed schema, so the raw-manifest provider handles them.
provider "kubectl" {
  host                   = local.k8s_host
  cluster_ca_certificate = local.k8s_ca_cert
  token                  = local.k8s_token
  load_config_file       = false
}

# Data sources
data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

# Naming convention locals
locals {
  name_prefix = "${var.project_name}-${var.environment}"

  resource_names = {
    vpc = "vpc-${local.name_prefix}"
    eks = "eks-${local.name_prefix}"
    ecr = "${var.project_name}-${var.environment}"
    rds = "psql-${local.name_prefix}"
  }

  common_tags = merge(
    var.tags,
    {
      Environment = var.environment
      ManagedBy   = "Terraform"
      Project     = var.project_name
      Terraform   = "true"
    }
  )

  # Select first 3 AZs
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
}

# Network indirection layer. Downstream resources reference these locals rather
# than the subnet/VPC resources directly, so consuming an externally-owned
# (RAM-shared) VPC is a matter of repointing them at the caller's IDs without
# touching every consumer. In create mode they resolve to the module's own
# resources; in consumer mode they resolve to the supplied IDs.
locals {
  vpc_id          = var.create_vpc ? aws_vpc.main[0].id : var.vpc_id
  node_subnet_ids = var.create_vpc ? aws_subnet.node[*].id : var.node_subnet_ids
  # With the lb tier disabled, internal LBs live in the node subnets — in both
  # create and consumer mode. Otherwise they use the dedicated lb subnets
  # (module-created in create mode, caller-supplied in consumer mode).
  lb_subnet_ids       = var.lb_subnet_enabled ? (var.create_vpc ? aws_subnet.lb[*].id : var.lb_subnet_ids) : local.node_subnet_ids
  database_subnet_ids = var.create_vpc ? aws_subnet.database[*].id : var.database_subnet_ids
}
