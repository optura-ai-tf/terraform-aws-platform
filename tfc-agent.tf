# Terraform Cloud Agent Deployment
# Deploys hashicorp/tfc-agent directly to enable private cluster access

# ===== Validation =====

locals {
  validate_tfc_agent = (
    var.tfc_agent_enabled &&
    (var.tfc_agent_token == null || var.tfc_agent_token == "")
  ) ? file("ERROR: When tfc_agent_enabled is true, tfc_agent_token must be provided.") : "valid"
}

# Force evaluation of TFC agent validation at plan time
# Without this resource, the validate_tfc_agent local is never referenced
# and Terraform skips evaluating it entirely
resource "terraform_data" "tfc_agent_validation" {
  count = var.tfc_agent_enabled ? 1 : 0

  input = local.validate_tfc_agent
}

# ===== TFC Agent Resources =====

locals {
  tfc_agent_namespace = "terraform-cloud"
}

# Create namespace for TFC Agent
resource "kubectl_manifest" "tfc_agent_namespace" {
  count = var.tfc_agent_enabled ? 1 : 0

  server_side_apply = true
  force_conflicts   = true
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = local.tfc_agent_namespace
    }
  })
}

# ServiceAccount for TFC Agent
# This SA is used by the agent pod and needs cluster-admin for Terraform to manage K8s resources
resource "kubectl_manifest" "tfc_agent_service_account" {
  count = var.tfc_agent_enabled ? 1 : 0

  server_side_apply = true
  force_conflicts   = true
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ServiceAccount"
    metadata = {
      name      = "tfc-agent"
      namespace = local.tfc_agent_namespace
    }
  })

  depends_on = [kubectl_manifest.tfc_agent_namespace]
}

# ClusterRoleBinding for TFC Agent
# Grants cluster-admin to the TFC agent SA so Terraform can manage all K8s resources
resource "kubectl_manifest" "tfc_agent_cluster_role_binding" {
  count = var.tfc_agent_enabled ? 1 : 0

  server_side_apply = true
  force_conflicts   = true
  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRoleBinding"
    metadata = {
      name = "tfc-agent-cluster-admin"
    }
    roleRef = {
      apiGroup = "rbac.authorization.k8s.io"
      kind     = "ClusterRole"
      name     = "cluster-admin"
    }
    subjects = [{
      kind      = "ServiceAccount"
      name      = "tfc-agent"
      namespace = local.tfc_agent_namespace
    }]
  })

  depends_on = [kubectl_manifest.tfc_agent_service_account]
}

# Kubernetes Secret for TFC Agent token
resource "kubectl_manifest" "tfc_agent_token" {
  count = var.tfc_agent_enabled ? 1 : 0

  server_side_apply = true
  force_conflicts   = true
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    type       = "Opaque"
    metadata = {
      name      = "tfc-agent-token"
      namespace = local.tfc_agent_namespace
    }
    data = {
      token = base64encode(var.tfc_agent_token)
    }
  })

  depends_on = [kubectl_manifest.tfc_agent_namespace]
}

# TFC Agent Deployment
resource "kubectl_manifest" "tfc_agent" {
  count = var.tfc_agent_enabled ? 1 : 0

  server_side_apply = true
  force_conflicts   = true
  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = "tfc-agent"
      namespace = local.tfc_agent_namespace
      labels = {
        app = "tfc-agent"
      }
    }
    spec = {
      replicas = 1
      selector = {
        matchLabels = {
          app = "tfc-agent"
        }
      }
      template = {
        metadata = {
          labels = {
            app = "tfc-agent"
          }
        }
        spec = {
          serviceAccountName = "tfc-agent"
          nodeSelector = {
            "workload-type" = var.platform_workload_type
          }
          # Matches the workload-type taint a Karpenter NodePool puts on its
          # nodes, so the selector above is actually schedulable there. Inert on
          # an untainted node group, which is what every cluster runs today.
          tolerations = [{
            key      = "workload-type"
            operator = "Equal"
            value    = var.platform_workload_type
            effect   = "NoSchedule"
          }]
          containers = [{
            name  = "tfc-agent"
            image = "hashicorp/tfc-agent:${var.tfc_agent_version}"
            env = [
              {
                name = "TFC_AGENT_TOKEN"
                valueFrom = {
                  # optional = false matches what kubernetes_deployment set, so
                  # taking over an existing agent doesn't roll its pod.
                  secretKeyRef = {
                    name     = "tfc-agent-token"
                    key      = "token"
                    optional = false
                  }
                }
              },
              # Use pod name for unique agent naming (includes random suffix)
              {
                name = "TFC_AGENT_NAME"
                valueFrom = {
                  fieldRef = {
                    fieldPath = "metadata.name"
                  }
                }
              },
            ]
            resources = {
              requests = {
                cpu    = "250m"
                memory = "512Mi"
              }
              limits = {
                cpu    = "1000m"
                memory = "2Gi"
              }
            }
          }]
        }
      }
    }
  })

  depends_on = [
    aws_eks_node_group.main,
    kubectl_manifest.tfc_agent_token,
    kubectl_manifest.tfc_agent_cluster_role_binding,
  ]
}
