# ===== Logging Bucket =====

resource "aws_s3_bucket" "logging" {
  count  = var.storage_logging_enabled ? 1 : 0
  bucket = var.storage_logging_bucket_name != null ? var.storage_logging_bucket_name : "${local.name_prefix}-logging"

  tags = merge(
    local.common_tags,
    {
      Name    = "s3-logging-${local.name_prefix}"
      Purpose = "Centralized log storage"
    }
  )
}

resource "aws_s3_bucket_versioning" "logging" {
  count  = var.storage_logging_enabled ? 1 : 0
  bucket = aws_s3_bucket.logging[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logging" {
  count  = var.storage_logging_enabled ? 1 : 0
  bucket = aws_s3_bucket.logging[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.s3_logging[0].arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "logging" {
  count  = var.storage_logging_enabled ? 1 : 0
  bucket = aws_s3_bucket.logging[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "logging" {
  count  = var.storage_logging_enabled ? 1 : 0
  bucket = aws_s3_bucket.logging[0].id

  rule {
    id     = "transition-old-logs"
    status = "Enabled"

    transition {
      days          = var.storage_logging_lifecycle.transition_to_ia_days
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = var.storage_logging_lifecycle.transition_to_glacier_days
      storage_class = "GLACIER"
    }

    expiration {
      days = var.storage_logging_lifecycle.expiration_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }
}

# ===== General Purpose Storage Bucket =====

resource "aws_s3_bucket" "storage" {
  count  = var.storage_general_enabled ? 1 : 0
  bucket = var.storage_general_bucket_name != null ? var.storage_general_bucket_name : "${local.name_prefix}-storage"

  tags = merge(
    local.common_tags,
    {
      Name    = "s3-storage-${local.name_prefix}"
      Purpose = "General application storage"
    }
  )
}

resource "aws_s3_bucket_versioning" "storage" {
  count  = var.storage_general_enabled ? 1 : 0
  bucket = aws_s3_bucket.storage[0].id

  versioning_configuration {
    status = var.storage_general_versioning ? "Enabled" : "Suspended"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "storage" {
  count  = var.storage_general_enabled ? 1 : 0
  bucket = aws_s3_bucket.storage[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.storage_general_encryption_type
      kms_master_key_id = var.storage_general_encryption_type == "aws:kms" ? aws_kms_key.s3_storage[0].arn : null
    }
    bucket_key_enabled = var.storage_general_encryption_type == "aws:kms" ? true : false
  }
}

resource "aws_s3_bucket_public_access_block" "storage" {
  count  = var.storage_general_enabled ? 1 : 0
  bucket = aws_s3_bucket.storage[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# A presigned PUT is issued by the app but sent by the browser, so S3 answers
# the preflight itself. Without a rule it returns 403 and the upload never
# leaves the browser.
resource "aws_s3_bucket_cors_configuration" "storage" {
  count  = var.storage_general_enabled && length(var.storage_general_cors_origins) > 0 ? 1 : 0
  bucket = aws_s3_bucket.storage[0].id

  cors_rule {
    allowed_origins = var.storage_general_cors_origins
    allowed_methods = ["GET", "HEAD", "PUT"]
    allowed_headers = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "storage" {
  count  = var.storage_general_enabled && var.storage_general_lifecycle_enabled ? 1 : 0
  bucket = aws_s3_bucket.storage[0].id

  rule {
    id     = "intelligent-tiering"
    status = "Enabled"

    transition {
      days          = var.storage_general_lifecycle.transition_to_ia_days
      storage_class = "INTELLIGENT_TIERING"
    }

    noncurrent_version_expiration {
      noncurrent_days = var.storage_general_lifecycle.noncurrent_version_expiration_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ===== KMS Keys for S3 Encryption =====

resource "aws_kms_key" "s3_storage" {
  count               = var.storage_general_enabled && var.storage_general_encryption_type == "aws:kms" ? 1 : 0
  description         = "KMS key for S3 storage bucket ${local.name_prefix}"
  enable_key_rotation = true

  tags = merge(
    local.common_tags,
    {
      Name = "kms-s3-storage-${local.name_prefix}"
    }
  )
}

resource "aws_kms_alias" "s3_storage" {
  count         = var.storage_general_enabled && var.storage_general_encryption_type == "aws:kms" ? 1 : 0
  name          = "alias/s3-storage-${local.name_prefix}"
  target_key_id = aws_kms_key.s3_storage[0].key_id
}

# ===== IAM Role for Logging (IRSA) =====

data "aws_iam_policy_document" "logging_assume_role" {
  count = var.storage_logging_enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:${var.storage_logging_namespace}:${var.storage_logging_service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "logging" {
  count              = var.storage_logging_enabled ? 1 : 0
  name               = "eks-logging-${local.name_prefix}"
  assume_role_policy = data.aws_iam_policy_document.logging_assume_role[0].json

  tags = local.common_tags
}

data "aws_iam_policy_document" "logging" {
  count = var.storage_logging_enabled ? 1 : 0

  statement {
    sid    = "LoggingS3Access"
    effect = "Allow"

    actions = [
      "s3:ListBucket",
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject"
    ]

    resources = [
      aws_s3_bucket.logging[0].arn,
      "${aws_s3_bucket.logging[0].arn}/*"
    ]
  }

  statement {
    sid    = "LoggingKMSAccess"
    effect = "Allow"

    actions = [
      "kms:Decrypt",
      "kms:Encrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey"
    ]

    resources = [aws_kms_key.s3_logging[0].arn]
  }
}

resource "aws_iam_policy" "logging" {
  count       = var.storage_logging_enabled ? 1 : 0
  name        = "LoggingS3Access-${local.name_prefix}"
  description = "IAM policy for logging tools to access S3 logging bucket"
  policy      = data.aws_iam_policy_document.logging[0].json
}

resource "aws_iam_role_policy_attachment" "logging" {
  count      = var.storage_logging_enabled ? 1 : 0
  policy_arn = aws_iam_policy.logging[0].arn
  role       = aws_iam_role.logging[0].name
}

# ===== IAM Role for General Storage (IRSA) =====

data "aws_iam_policy_document" "storage_assume_role" {
  count = var.storage_general_enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:${var.storage_general_namespace}:${var.storage_general_service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "storage" {
  count              = var.storage_general_enabled ? 1 : 0
  name               = "eks-storage-${local.name_prefix}"
  assume_role_policy = data.aws_iam_policy_document.storage_assume_role[0].json

  tags = local.common_tags
}

data "aws_iam_policy_document" "storage" {
  count = var.storage_general_enabled ? 1 : 0

  statement {
    sid    = "StorageS3Access"
    effect = "Allow"

    actions = [
      "s3:ListBucket",
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject"
    ]

    resources = [
      aws_s3_bucket.storage[0].arn,
      "${aws_s3_bucket.storage[0].arn}/*"
    ]
  }

  # Optional: Add KMS permissions if using KMS encryption
  dynamic "statement" {
    for_each = var.storage_general_encryption_type == "aws:kms" ? [1] : []
    content {
      sid    = "StorageKMSAccess"
      effect = "Allow"

      actions = [
        "kms:Decrypt",
        "kms:Encrypt",
        "kms:GenerateDataKey",
        "kms:DescribeKey"
      ]

      resources = [aws_kms_key.s3_storage[0].arn]
    }
  }
}

resource "aws_iam_policy" "storage" {
  count       = var.storage_general_enabled ? 1 : 0
  name        = "StorageS3Access-${local.name_prefix}"
  description = "IAM policy for applications to access S3 storage bucket"
  policy      = data.aws_iam_policy_document.storage[0].json
}

resource "aws_iam_role_policy_attachment" "storage" {
  count      = var.storage_general_enabled ? 1 : 0
  policy_arn = aws_iam_policy.storage[0].arn
  role       = aws_iam_role.storage[0].name
}
