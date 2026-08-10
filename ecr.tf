# Data source for existing ECR repository (if not creating new one)
data "aws_ecr_repository" "existing" {
  count = var.registry_enabled ? 0 : (var.ecr_repository_name != null ? 1 : 0)
  name  = var.ecr_repository_name
}

# Local values for ECR repository attributes
locals {
  ecr_repository_url  = var.registry_enabled ? aws_ecr_repository.main[0].repository_url : (var.ecr_repository_name != null ? data.aws_ecr_repository.existing[0].repository_url : null)
  ecr_repository_arn  = var.registry_enabled ? aws_ecr_repository.main[0].arn : (var.ecr_repository_name != null ? data.aws_ecr_repository.existing[0].arn : null)
  ecr_repository_name = var.registry_enabled ? aws_ecr_repository.main[0].name : (var.ecr_repository_name != null ? data.aws_ecr_repository.existing[0].name : null)
}

# ECR Repository (create new)
resource "aws_ecr_repository" "main" {
  count = var.registry_enabled ? 1 : 0

  name                 = local.resource_names.ecr
  image_tag_mutability = var.ecr_image_tag_mutability

  image_scanning_configuration {
    scan_on_push = var.ecr_scan_on_push
  }

  encryption_configuration {
    encryption_type = var.ecr_encryption_type
    kms_key         = var.ecr_encryption_type == "KMS" ? aws_kms_key.ecr[0].arn : null
  }

  tags = local.common_tags
}

# ECR Lifecycle Policy (only for newly created repositories)
resource "aws_ecr_lifecycle_policy" "main" {
  count      = var.registry_enabled ? 1 : 0
  repository = aws_ecr_repository.main[0].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last ${var.ecr_lifecycle_policy.keep_prod_images} production images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["prod"]
          countType     = "imageCountMoreThan"
          countNumber   = var.ecr_lifecycle_policy.keep_prod_images
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Keep last ${var.ecr_lifecycle_policy.keep_latest_images} any tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["dev", "stg", "latest"]
          countType     = "imageCountMoreThan"
          countNumber   = var.ecr_lifecycle_policy.keep_latest_images
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 3
        description  = "Expire untagged images after ${var.ecr_lifecycle_policy.expire_untagged} days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.ecr_lifecycle_policy.expire_untagged
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
