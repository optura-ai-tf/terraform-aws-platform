# ===================================================================
# Teleport Access Configuration (AWS EKS)
# ===================================================================
#
# This module provides secure access to Kubernetes and RDS via Teleport
# using the official teleport-kube-agent Helm chart.
#
# Components:
# 1. User-facing RBAC - Two roles (admin, viewer)
# 2. Teleport agent - Kubernetes + Database services via Helm
#
# ===================================================================

locals {
  teleport_cluster_name = "${var.project_name}-${var.environment}-eks"

  # EKS cluster DNS service IP
  # Note: This should match the kube-dns service ClusterIP
  # Verify with: kubectl get svc -n kube-system kube-dns -o jsonpath='{.spec.clusterIP}'
  # EKS default service CIDR is 172.20.0.0/16, DNS is at .20.0.10
  eks_dns_service_ip = "172.20.0.10"

  # Soft placement onto support nodes — shared by the teleport-kube-agent and
  # cluster-autoscaler Helm releases (Helm `set` dot-notation entries). Preferred
  # (not required) so clusters without a support node group fall back gracefully.
  # The workload-type toleration is index 0; var.platform_workload_tolerations
  # appends from index 1, so an override never displaces it.
  # `type = "string"` on every user-supplied value: Helm coerces an untyped
  # `set` value, so a legitimate toleration value of "true" or "2" would reach
  # the chart as a bool/number and fail schema validation. The affinity weight
  # stays untyped — it is genuinely numeric.
  support_node_affinity_set = concat([
    { name = "affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].weight", value = "100" },
    { name = "affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].preference.matchExpressions[0].key", value = "workload-type", type = "string" },
    { name = "affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].preference.matchExpressions[0].operator", value = "In", type = "string" },
    { name = "affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].preference.matchExpressions[0].values[0]", value = var.platform_workload_type, type = "string" },
    { name = "tolerations[0].key", value = "workload-type", type = "string" },
    { name = "tolerations[0].operator", value = "Equal", type = "string" },
    { name = "tolerations[0].value", value = var.platform_workload_type, type = "string" },
    { name = "tolerations[0].effect", value = "NoSchedule", type = "string" },
    ],
    flatten([
      for i, t in var.platform_workload_tolerations : [
        { name = "tolerations[${i + 1}].key", value = t.key, type = "string" },
        { name = "tolerations[${i + 1}].operator", value = t.operator, type = "string" },
        { name = "tolerations[${i + 1}].value", value = t.value, type = "string" },
        { name = "tolerations[${i + 1}].effect", value = t.effect, type = "string" },
      ]
  ]))

  # Validation logic - will fail at plan time if condition is not met
  validate_teleport = (
    var.access_mode == "teleport" &&
    (
      var.teleport_proxy_address == null || var.teleport_proxy_address == "" ||
      var.teleport_join_token == null || var.teleport_join_token == "" ||
      var.teleport_agent_chart_repository == null || var.teleport_agent_chart_repository == ""
    )
  ) ? file("ERROR: When access_mode is 'teleport', teleport_proxy_address, teleport_join_token, and teleport_agent_chart_repository must be provided.") : "valid"
}

# Force evaluation of teleport validation at plan time
# Without this resource, the validate_teleport local is never referenced
# and Terraform skips evaluating it entirely
resource "terraform_data" "teleport_validation" {
  count = var.access_mode == "teleport" ? 1 : 0

  input = local.validate_teleport
}

# ===== SECTION 1: User-Facing RBAC Roles =====

## Role 1: Cluster Admin (Full Access)
resource "kubernetes_cluster_role" "teleport_admin" {
  count = var.access_mode == "teleport" ? 1 : 0
  metadata {
    name = "teleport-cluster-admin"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "teleport.dev/role"            = "admin"
    }
  }
  rule {
    api_groups = ["*"]
    resources  = ["*"]
    verbs      = ["*"]
  }
  rule {
    non_resource_urls = ["*"]
    verbs             = ["*"]
  }
}

resource "kubernetes_cluster_role_binding" "teleport_admin" {
  count = var.access_mode == "teleport" ? 1 : 0
  metadata {
    name = "teleport-cluster-admin"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.teleport_admin[0].metadata[0].name
  }
  subject {
    kind      = "Group"
    name      = "teleport-admins"
    api_group = "rbac.authorization.k8s.io"
  }
}

## Role 2: Viewer (Read-Only)
resource "kubernetes_cluster_role" "teleport_viewer" {
  count = var.access_mode == "teleport" ? 1 : 0
  metadata {
    name = "teleport-viewer"
  }
  rule {
    api_groups = ["", "apps", "batch", "extensions"]
    resources = [
      "pods", "pods/log", "pods/status",
      "services", "endpoints",
      "deployments", "replicasets", "statefulsets", "daemonsets",
      "jobs", "cronjobs",
      "configmaps", "secrets",
      "persistentvolumes", "persistentvolumeclaims",
      "namespaces", "nodes"
    ]
    verbs = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["rbac.authorization.k8s.io"]
    resources  = ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding" "teleport_viewer" {
  count = var.access_mode == "teleport" ? 1 : 0
  metadata {
    name = "teleport-viewer"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.teleport_viewer[0].metadata[0].name
  }
  subject {
    kind      = "Group"
    name      = "teleport-viewers"
    api_group = "rbac.authorization.k8s.io"
  }
}

# ===== SECTION 2: Teleport Agent via Helm =====

# Teleport Kube Agent Helm Release
resource "helm_release" "teleport_kube_agent" {
  count = var.access_mode == "teleport" ? 1 : 0

  name             = "teleport-kube-agent"
  repository       = var.teleport_agent_chart_repository
  chart            = "teleport-kube-agent"
  namespace        = "teleport-agent"
  version          = var.teleport_version
  create_namespace = true

  # Core configuration
  set = concat(
    # Custom agent image (e.g. a private-registry mirror) — omit to use the chart's default image
    var.teleport_agent_image != null && var.teleport_agent_image != "" ? [
      {
        name  = "image"
        value = var.teleport_agent_image
      }
    ] : [],
    [
      {
        name  = "roles"
        value = var.teleport_db_enabled && var.rds_enabled ? "kube\\,app\\,discovery\\,db" : "kube\\,app\\,discovery"
      },
      # Enable app_service to allow header forwarding
      {
        name  = "teleportConfig.app_service.enabled"
        value = "true"
      },
      {
        name  = "proxyAddr"
        value = var.teleport_proxy_address
      },
      {
        name  = "authToken"
        value = var.teleport_join_token
      },
      {
        name  = "kubeClusterName"
        value = local.teleport_cluster_name
      },
      # App service resource matcher - only serve apps from THIS cluster
      # This prevents cross-cluster routing where AKS agent tries to serve EKS apps
      {
        name  = "appResources[0].labels.teleport\\.dev/kubernetes-cluster"
        value = local.teleport_cluster_name
      },
      # Kubernetes discovery configuration (filter by label)
      {
        name  = "kubernetesDiscovery[0].types[0]"
        value = "app"
      },
      {
        name  = "kubernetesDiscovery[0].namespaces[0]"
        value = "*"
      },
      {
        name  = "kubernetesDiscovery[0].labels.teleport\\.dev/discover"
        value = "true"
      },
      # Labels for Teleport RBAC
      {
        name  = "labels.env"
        value = var.environment
      },
      {
        name  = "labels.region"
        value = var.region
      },
      {
        name  = "labels.cloud"
        value = "aws"
      },
      {
        name  = "labels.customer"
        value = var.project_name
      },
      {
        name  = "labels.type"
        value = "kubernetes"
      },
      # Resource limits
      {
        name  = "resources.requests.cpu"
        value = "100m"
      },
      {
        name  = "resources.requests.memory"
        value = "256Mi"
      },
      {
        name  = "resources.limits.cpu"
        value = "500m"
      },
      {
        name  = "resources.limits.memory"
        value = "512Mi"
      },
      # DNS Configuration (fix for internal service resolution)
      # See: https://github.com/gravitational/teleport/discussions/34743
      # Force pods to use only the cluster DNS server to resolve *.svc.cluster.local names
      {
        name  = "dnsPolicy"
        value = "None"
      },
      {
        name  = "dnsConfig.nameservers[0]"
        value = local.eks_dns_service_ip
      },
      {
        name  = "dnsConfig.searches[0]"
        value = "teleport-agent.svc.cluster.local"
      },
      {
        name  = "dnsConfig.searches[1]"
        value = "svc.cluster.local"
      },
      {
        name  = "dnsConfig.searches[2]"
        value = "cluster.local"
      },
      {
        name  = "dnsConfig.options[0].name"
        value = "ndots"
      },
      {
        name  = "dnsConfig.options[0].value"
        value = "2"
        type  = "string"
      }
    ],
    # Node scheduling — prefer support nodes (shared with cluster-autoscaler)
    local.support_node_affinity_set,
    # CA Pin (optional, recommended for production)
    var.teleport_ca_pin != null ? [
      {
        name  = "caPin"
        value = var.teleport_ca_pin
      }
    ] : [],
    # Database configuration (if enabled) — one Teleport DB registration per
    # entry in var.databases (RDS instances and Aurora clusters alike, via the
    # engine-agnostic local.db_endpoints map). The "core" key produces a name
    # byte-identical to the legacy single-server registration so existing
    # Teleport DB resources are not recreated.
    #
    # Stability note: `keys()` returns lexicographically-sorted keys, so the
    # databases[N] index is stable for any given key set. Inserting a new key
    # that sorts before an existing one (e.g. `analytics` before `core`) will
    # shift all subsequent indices and trigger a brief Teleport DB agent
    # reconnect for every database — no data loss, but operationally visible.
    # Prefer adding new keys with names that sort *after* every existing key.
    var.teleport_db_enabled && var.rds_enabled ? flatten([
      for idx, k in keys(local.db_endpoints) : [
        {
          name  = "databases[${idx}].name"
          value = k == "core" ? "${var.project_name}-${var.environment}-rds" : "${var.project_name}-${var.environment}-rds-${k}"
        },
        {
          name  = "databases[${idx}].protocol"
          value = "postgres"
        },
        {
          name  = "databases[${idx}].uri"
          value = local.db_endpoints[k]
        },
        {
          name  = "databases[${idx}].aws.region"
          value = var.region
        },
        {
          name  = "databases[${idx}].static_labels.env"
          value = var.environment
        },
        {
          name  = "databases[${idx}].static_labels.cloud"
          value = "aws"
        },
        {
          name  = "databases[${idx}].static_labels.customer"
          value = var.project_name
        },
        {
          name  = "databases[${idx}].static_labels.type"
          value = "database"
        },
        {
          name  = "databases[${idx}].static_labels.db"
          value = k
        }
      ]
    ]) : [],
    # Service account annotation for IRSA (Teleport DB agent)
    var.access_mode == "teleport" && var.teleport_db_enabled && var.rds_enabled ? [
      {
        name  = "annotations.serviceAccount.eks\\.amazonaws\\.com/role-arn"
        value = aws_iam_role.teleport_db_agent[0].arn
      }
    ] : [],
    # hostAliases — route Teleport proxy hostname through the gateway proxy
    # so all agent traffic (including reverse tunnel) exits via a single static IP
    var.teleport_gateway_ip != null ? [
      {
        name  = "hostAliases[0].ip"
        value = var.teleport_gateway_ip
      },
      {
        name  = "hostAliases[0].hostnames[0]"
        value = split(":", var.teleport_proxy_address)[0]
      }
    ] : []
  )

  depends_on = [
    aws_eks_node_group.main,
    aws_eks_addon.coredns,
    aws_iam_role.teleport_db_agent,
    kubernetes_job_v1.rds_iam_bootstrap
  ]
}
