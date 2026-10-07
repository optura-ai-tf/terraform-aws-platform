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

# Create namespace for TFC Agent
resource "kubernetes_namespace" "tfc_agent" {
  count = var.tfc_agent_enabled ? 1 : 0

  metadata {
    name = "terraform-cloud"
  }
}

# ServiceAccount for TFC Agent
# This SA is used by the agent pod and needs cluster-admin for Terraform to manage K8s resources
resource "kubernetes_service_account" "tfc_agent" {
  count = var.tfc_agent_enabled ? 1 : 0

  metadata {
    name      = "tfc-agent"
    namespace = kubernetes_namespace.tfc_agent[0].metadata[0].name
  }

  depends_on = [kubernetes_namespace.tfc_agent]
}

# ClusterRoleBinding for TFC Agent
# Grants cluster-admin to the TFC agent SA so Terraform can manage all K8s resources
resource "kubernetes_cluster_role_binding" "tfc_agent" {
  count = var.tfc_agent_enabled ? 1 : 0

  metadata {
    name = "tfc-agent-cluster-admin"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.tfc_agent[0].metadata[0].name
    namespace = kubernetes_namespace.tfc_agent[0].metadata[0].name
  }

  depends_on = [kubernetes_service_account.tfc_agent]
}

# Kubernetes Secret for TFC Agent token
resource "kubernetes_secret" "tfc_agent_token" {
  count = var.tfc_agent_enabled ? 1 : 0

  metadata {
    name      = "tfc-agent-token"
    namespace = kubernetes_namespace.tfc_agent[0].metadata[0].name
  }

  data = {
    token = var.tfc_agent_token
  }

  depends_on = [
    kubernetes_namespace.tfc_agent,
  ]
}

# TFC Agent Deployment
resource "kubernetes_deployment" "tfc_agent" {
  count = var.tfc_agent_enabled ? 1 : 0

  metadata {
    name      = "tfc-agent"
    namespace = kubernetes_namespace.tfc_agent[0].metadata[0].name
    labels = {
      app = "tfc-agent"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "tfc-agent"
      }
    }

    template {
      metadata {
        labels = {
          app = "tfc-agent"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.tfc_agent[0].metadata[0].name

        node_selector = {
          "workload-type" = var.platform_workload_type
        }

        # Matches the workload-type taint a Karpenter NodePool puts on its
        # nodes, so the selector above is actually schedulable there. Inert on
        # an untainted node group, which is what every cluster runs today.
        toleration {
          key      = "workload-type"
          operator = "Equal"
          value    = var.platform_workload_type
          effect   = "NoSchedule"
        }

        dynamic "toleration" {
          for_each = var.platform_workload_tolerations
          content {
            key      = toleration.value.key
            operator = toleration.value.operator
            value    = toleration.value.value
            effect   = toleration.value.effect
          }
        }

        container {
          name  = "tfc-agent"
          image = "hashicorp/tfc-agent:${var.tfc_agent_version}"

          env {
            name = "TFC_AGENT_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.tfc_agent_token[0].metadata[0].name
                key  = "token"
              }
            }
          }

          # Use pod name for unique agent naming (includes random suffix)
          env {
            name = "TFC_AGENT_NAME"
            value_from {
              field_ref {
                field_path = "metadata.name"
              }
            }
          }

          resources {
            requests = {
              cpu    = "250m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "2Gi"
            }
          }
        }
      }
    }
  }

  depends_on = [
    aws_eks_node_group.main,
    kubernetes_secret.tfc_agent_token,
    kubernetes_cluster_role_binding.tfc_agent,
  ]
}
