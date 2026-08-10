# ===================================================================
# State migration: single-DB → multi-DB (var.databases fanout)
# ===================================================================
#
# These `moved` blocks rename every previously count-gated [0] address
# to its for_each-keyed ["core"] equivalent so existing customers
# upgrade with zero destroy/create on the legacy primary database.
#
# See docs/plans/2026-04-26-multi-database-provisioning-state-migration.md
# §2 for the full inventory and §4 for the recreation enumeration.
#
# Adding new keys to var.databases (e.g. "temporal") is a pure add —
# no `moved` block is required for those.
#
# If a customer never had var.rds_enabled = true (or the resource was
# otherwise absent), the moved block is a no-op (Terraform handles
# absent-source addresses silently).
# ===================================================================

moved {
  from = random_password.rds[0]
  to   = random_password.rds["core"]
}

moved {
  from = aws_kms_key.rds[0]
  to   = aws_kms_key.rds["core"]
}

moved {
  from = aws_kms_alias.rds[0]
  to   = aws_kms_alias.rds["core"]
}

moved {
  from = aws_security_group.rds[0]
  to   = aws_security_group.rds["core"]
}

moved {
  from = aws_security_group_rule.rds_from_eks_nodes[0]
  to   = aws_security_group_rule.rds_from_eks_nodes["core"]
}

moved {
  from = aws_security_group_rule.rds_from_vpc[0]
  to   = aws_security_group_rule.rds_from_vpc["core"]
}

moved {
  from = aws_security_group_rule.rds_egress[0]
  to   = aws_security_group_rule.rds_egress["core"]
}

moved {
  from = aws_iam_role.rds_monitoring[0]
  to   = aws_iam_role.rds_monitoring["core"]
}

moved {
  from = aws_iam_role_policy_attachment.rds_monitoring[0]
  to   = aws_iam_role_policy_attachment.rds_monitoring["core"]
}

moved {
  from = aws_db_instance.postgresql[0]
  to   = aws_db_instance.postgresql["core"]
}

moved {
  from = kubernetes_config_map.rds_iam_setup[0]
  to   = kubernetes_config_map.rds_iam_setup["core"]
}

moved {
  from = kubernetes_secret.rds_bootstrap_creds[0]
  to   = kubernetes_secret.rds_bootstrap_creds["core"]
}

moved {
  from = kubernetes_job_v1.rds_iam_bootstrap[0]
  to   = kubernetes_job_v1.rds_iam_bootstrap["core"]
}

# ===================================================================
# State migration: dedicated node SG made optional (count-gated)
# ===================================================================
#
# aws_security_group.eks_nodes and its singleton rules gained a
# `count` (dedicated_node_sg_enabled, default true). These blocks
# rename the pre-count unindexed addresses to [0] so existing clusters
# upgrade with zero diff at the default. When dedicated_node_sg_enabled
# = false, the [0] instances are then destroyed as intended.
# rds_from_eks_nodes is already for_each-keyed (see the ["core"] block
# above) so it needs no entry here.
# ===================================================================

moved {
  from = aws_security_group.eks_nodes
  to   = aws_security_group.eks_nodes[0]
}

moved {
  from = aws_security_group_rule.nodes_internal
  to   = aws_security_group_rule.nodes_internal[0]
}

moved {
  from = aws_security_group_rule.nodes_to_cluster
  to   = aws_security_group_rule.nodes_to_cluster[0]
}

moved {
  from = aws_security_group_rule.cluster_to_nodes
  to   = aws_security_group_rule.cluster_to_nodes[0]
}

moved {
  from = aws_security_group_rule.nodes_egress
  to   = aws_security_group_rule.nodes_egress[0]
}
