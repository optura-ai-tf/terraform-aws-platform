# KMS Key for EKS Secrets Encryption
resource "aws_kms_key" "eks" {
  count                   = var.enable_cluster_encryption ? 1 : 0
  description             = "KMS key for EKS cluster ${local.resource_names.eks} secrets encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 10

  tags = merge(
    local.common_tags,
    {
      Name = "kms-eks-${local.name_prefix}"
    }
  )
}

resource "aws_kms_alias" "eks" {
  count         = var.enable_cluster_encryption ? 1 : 0
  name          = "alias/eks-${local.name_prefix}"
  target_key_id = aws_kms_key.eks[0].key_id
}

# KMS Key for RDS Encryption (per named database)
resource "aws_kms_key" "rds" {
  for_each                = var.rds_enabled ? var.databases : {}
  description             = "KMS key for RDS ${local.resource_names.rds}${local.db_name_suffix[each.key]}"
  enable_key_rotation     = true
  deletion_window_in_days = 10

  tags = merge(
    local.common_tags,
    {
      Name = "kms-rds-${local.name_prefix}${local.db_name_suffix[each.key]}"
    }
  )
}

resource "aws_kms_alias" "rds" {
  for_each      = var.rds_enabled ? var.databases : {}
  name          = "alias/rds-${local.name_prefix}${local.db_name_suffix[each.key]}"
  target_key_id = aws_kms_key.rds[each.key].key_id
}

# KMS Key for ECR Encryption
resource "aws_kms_key" "ecr" {
  count                   = var.registry_enabled && var.ecr_encryption_type == "KMS" ? 1 : 0
  description             = "KMS key for ECR ${local.resource_names.ecr}"
  enable_key_rotation     = true
  deletion_window_in_days = 10

  tags = merge(
    local.common_tags,
    {
      Name = "kms-ecr-${local.name_prefix}"
    }
  )
}

resource "aws_kms_alias" "ecr" {
  count         = var.registry_enabled && var.ecr_encryption_type == "KMS" ? 1 : 0
  name          = "alias/ecr-${local.name_prefix}"
  target_key_id = aws_kms_key.ecr[0].key_id
}

# KMS Key for S3 Logging Bucket Encryption
resource "aws_kms_key" "s3_logging" {
  count                   = var.storage_logging_enabled ? 1 : 0
  description             = "KMS key for S3 logging bucket ${local.name_prefix}"
  enable_key_rotation     = true
  deletion_window_in_days = 10

  tags = merge(
    local.common_tags,
    {
      Name = "kms-s3-logging-${local.name_prefix}"
    }
  )
}

resource "aws_kms_alias" "s3_logging" {
  count         = var.storage_logging_enabled ? 1 : 0
  name          = "alias/s3-logging-${local.name_prefix}"
  target_key_id = aws_kms_key.s3_logging[0].key_id
}
