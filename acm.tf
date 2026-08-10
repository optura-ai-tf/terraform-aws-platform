# ===== ACM Certificate Configuration =====

# Data source for existing ACM certificate (if not creating new one)
data "aws_acm_certificate" "existing" {
  count    = var.acm_create ? 0 : (var.acm_certificate_arn != null ? 1 : 0)
  domain   = var.acm_domain_name
  statuses = ["ISSUED"]
}

# ACM Certificate (create certificate based on acm_domain_name)
resource "aws_acm_certificate" "main" {
  count = var.acm_create && var.acm_domain_name != null ? 1 : 0

  # Use acm_domain_name as-is (supports both wildcard and non-wildcard)
  # Examples: *.example.com (wildcard) or example.com (non-wildcard)
  domain_name = var.acm_domain_name

  subject_alternative_names = var.acm_subject_alternative_names
  validation_method         = var.acm_validation_method

  tags = merge(
    local.common_tags,
    {
      Name = "${local.name_prefix}-acm-cert"
    }
  )

  lifecycle {
    create_before_destroy = true
  }
}

# Route53 records for DNS validation (if using DNS validation and Route53)
data "aws_route53_zone" "main" {
  count = var.acm_create && var.acm_validation_method == "DNS" && var.acm_route53_zone_id != null ? 1 : 0

  zone_id = var.acm_route53_zone_id
}

# Route53 validation records (validated against parent domain)
resource "aws_route53_record" "acm_validation" {
  for_each = var.acm_create && var.acm_validation_method == "DNS" && var.acm_route53_zone_id != null ? {
    for dvo in aws_acm_certificate.main[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.main[0].zone_id
}

# Certificate validation
resource "aws_acm_certificate_validation" "main" {
  count = var.acm_create && var.acm_validation_method == "DNS" && var.acm_route53_zone_id != null ? 1 : 0

  certificate_arn         = aws_acm_certificate.main[0].arn
  validation_record_fqdns = [for record in aws_route53_record.acm_validation : record.fqdn]

  timeouts {
    create = "30m"
  }
}

# Local values for ACM certificate attributes
locals {
  acm_certificate_arn = var.acm_create && var.acm_domain_name != null ? aws_acm_certificate.main[0].arn : (
    var.acm_certificate_arn != null ? var.acm_certificate_arn : null
  )
}
