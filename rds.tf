# Per-key name suffix used by every supporting resource (SG, KMS alias, IAM
# role, K8s ConfigMap/Secret/Job, …). "core" resolves to "" so the legacy
# unsuffixed names are preserved on upgrade — avoiding ForceNew replacement
# of resources whose `name` is immutable. Future keys are suffixed
# unconditionally so they cannot collide with "core".
locals {
  db_name_suffix = {
    for k in keys(var.databases) : k => k == "core" ? "" : "-${k}"
  }

  # Split var.databases by engine family. RDS keys provision a standalone
  # aws_db_instance; aurora/aurora-serverless keys provision an aws_rds_cluster
  # (+ cluster instances). Engine-agnostic supporting resources (KMS, SG,
  # random_password, IAM monitoring role, bootstrap Job) keep iterating the
  # full var.databases map — only the database resource itself splits.
  rds_databases    = { for k, v in var.databases : k => v if v.engine == "rds" }
  aurora_databases = { for k, v in var.databases : k => v if v.engine == "aurora" || v.engine == "aurora-serverless" }

  # One aws_rds_cluster_instance per (aurora cluster, instance index). Keyed
  # "<dbkey>-<idx>" so each cluster gets `instance_count` instances (default 1).
  aurora_instances = merge([
    for k, v in local.aurora_databases : {
      for i in range(coalesce(v.instance_count, 1)) :
      "${k}-${i}" => { db_key = k, index = i }
    }
  ]...)

  # Normalized per-key views over BOTH engine families so downstream code
  # (IAM rds-db:connect ARNs, Teleport DB registrations, outputs, the IAM
  # bootstrap Job) reads one map instead of branching on engine. RDS exposes
  # host via `.address`; Aurora exposes the writer host via `.endpoint`.
  db_hosts = merge(
    { for k, v in aws_db_instance.postgresql : k => v.address },
    { for k, v in aws_rds_cluster.aurora : k => v.endpoint },
  )
  # Reader endpoint as host:port — same format as db_endpoints so downstream
  # consumers can treat writer and reader outputs uniformly. Only aurora keys
  # have a reader endpoint; RDS keys are absent from this map.
  db_reader_endpoints = {
    for k, v in aws_rds_cluster.aurora : k => "${v.reader_endpoint}:${v.port}"
  }
  db_ports = merge(
    { for k, v in aws_db_instance.postgresql : k => v.port },
    { for k, v in aws_rds_cluster.aurora : k => v.port },
  )
  db_resource_ids = merge(
    { for k, v in aws_db_instance.postgresql : k => v.resource_id },
    { for k, v in aws_rds_cluster.aurora : k => v.cluster_resource_id },
  )
  db_names = merge(
    { for k, v in aws_db_instance.postgresql : k => v.db_name },
    { for k, v in aws_rds_cluster.aurora : k => v.database_name },
  )
  db_usernames = merge(
    { for k, v in aws_db_instance.postgresql : k => v.username },
    { for k, v in aws_rds_cluster.aurora : k => v.master_username },
  )
  db_identifiers = merge(
    { for k, v in aws_db_instance.postgresql : k => v.identifier },
    { for k, v in aws_rds_cluster.aurora : k => v.cluster_identifier },
  )

  # endpoint as host:port — preserves the legacy aws_db_instance.endpoint
  # format (which already included the port) for outputs and Teleport URIs.
  # Iterates db_hosts (resource-derived) so it is empty when rds_enabled =
  # false rather than indexing a missing key.
  db_endpoints = {
    for k, h in local.db_hosts : k => "${h}:${local.db_ports[k]}"
  }
}

# Random password for RDS (one per named database)
# Excludes characters not allowed by RDS: / @ " and space
# NOTE: No `keepers` argument — adding a new entry to var.databases must
# never rotate existing per-key passwords. Per-key isolation is provided by
# for_each itself (each key has its own random_password instance).
resource "random_password" "rds" {
  for_each         = var.rds_enabled ? var.databases : {}
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}|<>:?"
}

# RDS PostgreSQL Instance (one per named database with engine = "rds")
resource "aws_db_instance" "postgresql" {
  for_each = var.rds_enabled ? local.rds_databases : {}

  # Identifier: legacy "core" preserves the unsuffixed name so the existing
  # cloud resource is not recreated. All other keys are unconditionally
  # suffixed so future keys (e.g. "core2") cannot collide with "core".
  identifier     = "${local.resource_names.rds}${local.db_name_suffix[each.key]}"
  engine         = "postgres"
  engine_version = coalesce(each.value.engine_version, var.rds_engine_version)
  instance_class = coalesce(each.value.instance_class, var.rds_instance_class)

  # Storage configuration with KMS encryption
  allocated_storage     = coalesce(each.value.allocated_storage, var.rds_allocated_storage)
  max_allocated_storage = coalesce(each.value.max_allocated_storage, var.rds_max_allocated_storage)
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.rds[each.key].arn

  # Database
  db_name                             = coalesce(each.value.db_name, var.rds_database_name)
  username                            = coalesce(each.value.admin_username, var.rds_admin_username)
  password                            = random_password.rds[each.key].result
  iam_database_authentication_enabled = true

  # Network
  db_subnet_group_name   = aws_db_subnet_group.main[0].name
  vpc_security_group_ids = [aws_security_group.rds[each.key].id]
  publicly_accessible    = false

  # High Availability
  multi_az = coalesce(each.value.multi_az, var.rds_multi_az)

  # Backups
  backup_retention_period = coalesce(each.value.backup_retention_period, var.rds_backup_retention_period)
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:00-sun:05:00"

  # Monitoring with Performance Insights KMS encryption
  enabled_cloudwatch_logs_exports       = ["postgresql", "upgrade"]
  performance_insights_enabled          = true
  performance_insights_kms_key_id       = aws_kms_key.rds[each.key].arn
  performance_insights_retention_period = var.environment == "prod" ? 731 : 7
  monitoring_interval                   = 60
  monitoring_role_arn                   = aws_iam_role.rds_monitoring[each.key].arn

  # Deletion protection
  deletion_protection       = coalesce(each.value.deletion_protection, var.rds_deletion_protection)
  skip_final_snapshot       = coalesce(each.value.skip_final_snapshot, var.rds_skip_final_snapshot)
  final_snapshot_identifier = coalesce(each.value.skip_final_snapshot, var.rds_skip_final_snapshot) ? null : "${local.resource_names.rds}${local.db_name_suffix[each.key]}-final-${formatdate("YYYY-MM-DD-hhmm", timestamp())}"

  # Auto minor version upgrades
  auto_minor_version_upgrade = true

  # Delete automated backups on instance deletion (dev only)
  delete_automated_backups = var.environment == "dev"

  tags = local.common_tags

  lifecycle {
    ignore_changes = [
      final_snapshot_identifier
    ]
  }
}

# Aurora PostgreSQL Cluster (one per named database with engine = "aurora"
# or "aurora-serverless"). Serverless v2 uses engine_mode = "provisioned"
# plus a serverlessv2_scaling_configuration block and db.serverless instances.
resource "aws_rds_cluster" "aurora" {
  for_each = var.rds_enabled ? local.aurora_databases : {}

  # Same identifier scheme as the RDS instance so naming is consistent across
  # engines. "core" stays unsuffixed; other keys are suffixed.
  cluster_identifier = "${local.resource_names.rds}${local.db_name_suffix[each.key]}"
  engine             = "aurora-postgresql"
  engine_mode        = "provisioned"
  engine_version     = coalesce(each.value.engine_version, var.aurora_engine_version)

  # Database
  database_name                       = coalesce(each.value.db_name, var.rds_database_name)
  master_username                     = coalesce(each.value.admin_username, var.rds_admin_username)
  master_password                     = random_password.rds[each.key].result
  iam_database_authentication_enabled = true

  # Storage encryption (Aurora storage itself is managed — no allocated_storage)
  storage_encrypted = true
  kms_key_id        = aws_kms_key.rds[each.key].arn

  # Network
  db_subnet_group_name   = aws_db_subnet_group.main[0].name
  vpc_security_group_ids = [aws_security_group.rds[each.key].id]

  # Backups
  backup_retention_period      = coalesce(each.value.backup_retention_period, var.rds_backup_retention_period)
  preferred_backup_window      = "03:00-04:00"
  preferred_maintenance_window = "sun:04:00-sun:05:00"

  # Logs (Aurora PostgreSQL supports the "postgresql" export; "upgrade" is RDS-only)
  enabled_cloudwatch_logs_exports = ["postgresql"]

  # Deletion protection
  deletion_protection       = coalesce(each.value.deletion_protection, var.rds_deletion_protection)
  skip_final_snapshot       = coalesce(each.value.skip_final_snapshot, var.rds_skip_final_snapshot)
  final_snapshot_identifier = coalesce(each.value.skip_final_snapshot, var.rds_skip_final_snapshot) ? null : "${local.resource_names.rds}${local.db_name_suffix[each.key]}-final-${formatdate("YYYY-MM-DD-hhmm", timestamp())}"

  # Serverless v2 scaling — only for engine = "aurora-serverless"
  dynamic "serverlessv2_scaling_configuration" {
    for_each = each.value.engine == "aurora-serverless" ? [1] : []
    content {
      min_capacity = coalesce(each.value.serverless_min_capacity, var.aurora_serverless_min_capacity)
      max_capacity = coalesce(each.value.serverless_max_capacity, var.aurora_serverless_max_capacity)
    }
  }

  tags = local.common_tags

  lifecycle {
    # Catches the global-default case a var.databases validation cannot see:
    # validation blocks can't cross-reference var.rds_backup_retention_period,
    # so a caller setting rds_backup_retention_period = 0 (legal for standalone
    # RDS) with any Aurora database would otherwise fail at apply with a cryptic
    # AWS API error. This surfaces it at plan time on the resolved value.
    precondition {
      condition     = coalesce(each.value.backup_retention_period, var.rds_backup_retention_period) >= 1
      error_message = "Aurora requires backup_retention_period >= 1 for both provisioned and serverless clusters (key: ${each.key}). Standalone RDS permits 0; Aurora does not. Set a per-entry backup_retention_period >= 1 or raise var.rds_backup_retention_period."
    }
    # The var.databases validation only compares min<=max when BOTH are set
    # explicitly. A caller setting only serverless_min_capacity (leaving max at
    # var.aurora_serverless_max_capacity) bypasses it and fails at apply. This
    # checks the resolved values, which a validation block cannot reach.
    precondition {
      condition = each.value.engine != "aurora-serverless" || (
        coalesce(each.value.serverless_min_capacity, var.aurora_serverless_min_capacity) <=
        coalesce(each.value.serverless_max_capacity, var.aurora_serverless_max_capacity)
      )
      error_message = "Aurora Serverless v2 requires serverless_min_capacity <= serverless_max_capacity (key: ${each.key}), comparing resolved values including the var.aurora_serverless_{min,max}_capacity defaults."
    }
    ignore_changes = [
      final_snapshot_identifier
    ]
  }
}

# Aurora cluster instances (writer + optional readers). One per (cluster,
# index) via local.aurora_instances. Serverless v2 instances use the
# db.serverless class; provisioned Aurora uses var.aurora_instance_class.
resource "aws_rds_cluster_instance" "aurora" {
  for_each = var.rds_enabled ? local.aurora_instances : {}

  identifier         = "${local.resource_names.rds}${local.db_name_suffix[each.value.db_key]}-${each.value.index}"
  cluster_identifier = aws_rds_cluster.aurora[each.value.db_key].id
  engine             = aws_rds_cluster.aurora[each.value.db_key].engine
  engine_version     = aws_rds_cluster.aurora[each.value.db_key].engine_version

  instance_class = var.databases[each.value.db_key].engine == "aurora-serverless" ? "db.serverless" : coalesce(var.databases[each.value.db_key].instance_class, var.aurora_instance_class)

  db_subnet_group_name = aws_db_subnet_group.main[0].name
  publicly_accessible  = false

  # Monitoring with Performance Insights KMS encryption (instance-level on Aurora)
  performance_insights_enabled          = true
  performance_insights_kms_key_id       = aws_kms_key.rds[each.value.db_key].arn
  performance_insights_retention_period = var.environment == "prod" ? 731 : 7
  monitoring_interval                   = 60
  monitoring_role_arn                   = aws_iam_role.rds_monitoring[each.value.db_key].arn

  auto_minor_version_upgrade = true

  tags = local.common_tags
}

# IAM Role for RDS Enhanced Monitoring (per-server)
resource "aws_iam_role" "rds_monitoring" {
  for_each = var.rds_enabled ? var.databases : {}
  name     = "rds-monitoring-${local.name_prefix}${local.db_name_suffix[each.key]}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "monitoring.rds.amazonaws.com"
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  for_each   = var.rds_enabled ? var.databases : {}
  role       = aws_iam_role.rds_monitoring[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# ===================================================================
# RDS IAM Authentication Bootstrap (per named database)
# ===================================================================
#
# WHY THIS IS NEEDED:
#
# To use IAM authentication with RDS, PostgreSQL users must have the
# special 'rds_iam' role granted to them. This is a database-level
# permission that cannot be set via AWS APIs or Terraform's AWS provider.
#
# THE PROBLEM:
# - RDS is in a private network (no public access)
# - Terraform runs externally and cannot reach the database
# - The PostgreSQL Terraform provider cannot connect to grant the role
#
# THE SOLUTION:
# - Deploy a Kubernetes Job per named DB that runs INSIDE the cluster
# - The Job has network access to the private RDS instance
# - It connects using password authentication (one time with psqladmin)
# - It creates a dedicated 'teleport_admin' user with CREATEROLE permission
# - It grants 'rds_iam' and 'rds_superuser' roles to teleport_admin
# - Job automatically cleans up after completion
#
# DEDICATED USER APPROACH:
# - Creates 'teleport_admin' specifically for Teleport database access
# - Grants CREATEROLE permission for Teleport auto-user provisioning
# - Grants CREATEDB permission for database creation capabilities
# - The 'psqladmin' master user remains untouched for emergency access
# - Separates operational access (Teleport) from break-glass access (master)
#
# WHEN IT RUNS:
# - Automatically during 'terraform apply' when RDS is created
# - Runs once per named DB (each.key) per environment
# - If the user already exists, the commands are idempotent
#
# AFTER THIS:
# - IAM authentication works for the teleport_admin user
# - Teleport can connect to RDS using IAM credentials
# - Teleport can auto-provision temporary database users
# - Users access databases through Teleport (no passwords needed)
#
# ===================================================================

# ConfigMap containing SQL script to grant rds_iam role (per-server)
resource "kubernetes_config_map" "rds_iam_setup" {
  for_each = var.rds_enabled ? var.databases : {}

  metadata {
    name      = "rds-iam-setup-${var.environment}${local.db_name_suffix[each.key]}"
    namespace = "kube-system"
  }

  data = {
    "setup.sql" = <<-SQL
      -- Create dedicated user for Teleport database access
      -- This user will have CREATEROLE permission for auto-provisioning
      -- Commands are idempotent (safe to run multiple times)
      DO $$
      BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'teleport_admin') THEN
          CREATE USER teleport_admin WITH CREATEROLE CREATEDB LOGIN;
          RAISE NOTICE 'Created user: teleport_admin';
        ELSE
          -- Ensure existing user has CREATEDB permission
          ALTER USER teleport_admin WITH CREATEDB;
          RAISE NOTICE 'User teleport_admin already exists, ensured CREATEDB permission';
        END IF;
      END
      $$;

      -- Grant rds_iam role to enable IAM authentication
      GRANT rds_iam TO teleport_admin;

      -- Grant necessary permissions for Teleport auto-provisioning
      -- rds_superuser allows managing user permissions and database operations
      GRANT rds_superuser TO teleport_admin;

      -- Verify the setup
      SELECT
        r.rolname,
        r.rolcanlogin,
        r.rolcreaterole,
        array_agg(m.rolname) AS member_of
      FROM pg_roles r
      LEFT JOIN pg_auth_members am ON r.oid = am.member
      LEFT JOIN pg_roles m ON am.roleid = m.oid
      WHERE r.rolname = 'teleport_admin'
      GROUP BY r.rolname, r.rolcanlogin, r.rolcreaterole;
    SQL
  }

  depends_on = [aws_db_instance.postgresql, aws_rds_cluster_instance.aurora]
}

# Secret containing database credentials for bootstrap connection (per-server)
resource "kubernetes_secret" "rds_bootstrap_creds" {
  for_each = var.rds_enabled ? var.databases : {}

  metadata {
    name      = "rds-bootstrap-credentials-${var.environment}${local.db_name_suffix[each.key]}"
    namespace = "kube-system"
  }

  data = {
    username = coalesce(each.value.admin_username, var.rds_admin_username)
    password = random_password.rds[each.key].result
    host     = local.db_hosts[each.key]
  }

  type = "Opaque"

  depends_on = [aws_db_instance.postgresql, aws_rds_cluster_instance.aurora]
}

# Re-running the bootstrap Job when its ConfigMap SQL changes is non-trivial:
# spec.template is immutable on a K8s Job, so a pod-template annotation
# (e.g. sha256 of the SQL) is silently dropped by the API server and never
# triggers a re-run. Instead we hash the SQL into a `terraform_data` resource
# and use `lifecycle.replace_triggered_by` on the Job — when the hash changes,
# Terraform performs a full delete + create on the Job. Mirrors the Azure
# pattern in azure/postgresql.tf.
resource "terraform_data" "rds_iam_setup_hash" {
  for_each = var.rds_enabled ? var.databases : {}

  # `triggers_replace` (not `input`) so a SQL change renders as `-/+` in plan
  # output — clearer than the `~` update an `input` change would produce.
  # Re-run the bootstrap Job on a SQL change OR when the DB endpoint changes.
  # The host changes when a key switches engine families (rds <-> aurora), which
  # destroys+recreates the database under a new cluster/instance. Without the
  # host in the trigger, an already-completed Job would never re-apply the IAM
  # grants / teleport_admin role on the new engine.
  triggers_replace = [
    sha256(kubernetes_config_map.rds_iam_setup[each.key].data["setup.sql"]),
    local.db_hosts[each.key],
  ]
}

# Kubernetes Job to grant rds_iam role (runs once per named DB after RDS creation)
resource "kubernetes_job_v1" "rds_iam_bootstrap" {
  for_each = var.rds_enabled ? var.databases : {}

  metadata {
    name      = "rds-iam-bootstrap-${var.environment}${local.db_name_suffix[each.key]}"
    namespace = "kube-system"
  }

  spec {
    template {
      metadata {
        labels = {
          app = "rds-iam-bootstrap"
        }
      }

      spec {
        restart_policy = "Never"

        container {
          name    = "bootstrap"
          image   = "postgres:17-alpine"
          command = ["/bin/sh"]
          args = [
            "-c",
            <<-SCRIPT
              set -e
              echo "=========================================="
              echo "RDS IAM Authentication Bootstrap"
              echo "=========================================="
              echo "Waiting for RDS to accept connections..."

              # Wait for RDS to be ready (max 5 minutes)
              RETRIES=60
              until pg_isready -h $PGHOST -U $PGUSER || [ $RETRIES -eq 0 ]; do
                echo "  Attempt $((60 - RETRIES + 1))/60: Waiting..."
                RETRIES=$((RETRIES - 1))
                sleep 5
              done

              if [ $RETRIES -eq 0 ]; then
                echo "ERROR: RDS did not become ready in time"
                exit 1
              fi

              echo "RDS is ready! Creating teleport_admin user..."
              psql -f /scripts/setup.sql

              echo "=========================================="
              echo "Bootstrap completed successfully!"
              echo "- Created 'teleport_admin' user with CREATEROLE and CREATEDB"
              echo "- Granted rds_iam and rds_superuser roles"
              echo "- IAM authentication enabled for Teleport"
              echo "- Master user 'psqladmin' unchanged"
              echo "=========================================="
            SCRIPT
          ]

          env {
            name = "PGHOST"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.rds_bootstrap_creds[each.key].metadata[0].name
                key  = "host"
              }
            }
          }

          env {
            name = "PGUSER"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.rds_bootstrap_creds[each.key].metadata[0].name
                key  = "username"
              }
            }
          }

          env {
            name = "PGPASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.rds_bootstrap_creds[each.key].metadata[0].name
                key  = "password"
              }
            }
          }

          env {
            name  = "PGDATABASE"
            value = coalesce(each.value.db_name, var.rds_database_name)
          }

          env {
            name  = "PGSSLMODE"
            value = "require"
          }

          volume_mount {
            name       = "scripts"
            mount_path = "/scripts"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "256Mi"
            }
          }
        }

        volume {
          name = "scripts"
          config_map {
            name = kubernetes_config_map.rds_iam_setup[each.key].metadata[0].name
          }
        }

        # Schedule on support nodes
        node_selector = {
          "workload-type" = "support"
        }

        toleration {
          key      = "workload-type"
          operator = "Equal"
          value    = "support"
          effect   = "NoSchedule"
        }
      }
    }

    # Retry up to 3 times if it fails
    backoff_limit = 3

    # Keep the job after completion (don't auto-delete)
    # This prevents Terraform from recreating it on every apply
    # The job will remain in "Completed" state as a record of the bootstrap
    # ttl_seconds_after_finished = 600  # Disabled to prevent recreation
  }

  # Wait for job to complete before proceeding
  # This ensures rds_iam role is granted before Teleport agent starts
  wait_for_completion = true
  timeouts {
    create = "10m"
    update = "10m"
  }

  depends_on = [
    aws_eks_node_group.main,
    aws_db_instance.postgresql,
    aws_rds_cluster_instance.aurora,
    kubernetes_config_map.rds_iam_setup,
    kubernetes_secret.rds_bootstrap_creds
  ]

  # Re-run the Job whenever the SQL hash changes. See `terraform_data.rds_iam_setup_hash`
  # above for the rationale (spec.template is immutable on K8s Jobs).
  lifecycle {
    replace_triggered_by = [
      terraform_data.rds_iam_setup_hash[each.key]
    ]
  }
}
