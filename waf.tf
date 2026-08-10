# WAFv2 Web ACLs, one per var.waf_web_acls entry, at REGIONAL (default) or
# CLOUDFRONT scope. Creation is split from attachment: controller-managed ALBs
# are attached in gitops via the alb.ingress.kubernetes.io/wafv2-acl-arn
# annotation using waf_web_acl_arns; a CLOUDFRONT-scope ACL is attached by
# setting web_acl_id on the aws_cloudfront_distribution.
# associate_resource_arns is only for ALBs provisioned outside the controller.

locals {
  # Effective Web ACL name: explicit `name` override, else the derived
  # "<project>-<environment>-<key>". Reused for metrics, log group and tags so
  # they all stay in sync. coalesce falls back to the exact legacy name, so
  # entries that don't set `name` see no diff.
  waf_acl_name = {
    for acl_key, acl in var.waf_web_acls : acl_key => coalesce(acl.name, "${local.name_prefix}-${acl_key}")
  }

  waf_ip_sets = merge([
    for acl_key, acl in var.waf_web_acls : {
      for r in acl.ip_rules : "${acl_key}/${r.name}" => {
        name       = r.name
        addresses  = r.addresses
        ip_version = r.ip_version
        # An IP set must share the scope of every ACL that references it.
        scope = acl.scope
      }
    }
  ]...)

  waf_log_groups = {
    for acl_key, acl in var.waf_web_acls : acl_key => acl
    if acl.logging.enabled && acl.logging.destination_arn == null
  }

  waf_logging = {
    for acl_key, acl in var.waf_web_acls : acl_key => acl
    if acl.logging.enabled
  }

  # CLOUDFRONT-scope ACLs are attached via the distribution's web_acl_id, not an
  # association resource — AssociateWebACL rejects them.
  waf_associations = merge([
    for acl_key, acl in var.waf_web_acls : {
      for arn in acl.associate_resource_arns : "${acl_key}/${arn}" => {
        acl_key = acl_key
        arn     = arn
      }
    } if acl.scope == "REGIONAL"
  ]...)
}

resource "aws_wafv2_ip_set" "main" {
  for_each = local.waf_ip_sets

  # each.key is "<acl>/<rule>"; the ACL key must be in the AWS name so the same
  # ip_rule name reused across ACLs does not collide (WAFDuplicateItemException).
  name               = "${local.name_prefix}-${replace(each.key, "/", "-")}"
  scope              = each.value.scope
  ip_address_version = each.value.ip_version
  addresses          = each.value.addresses

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-${replace(each.key, "/", "-")}" })
}

resource "aws_wafv2_web_acl" "main" {
  for_each = var.waf_web_acls

  name = local.waf_acl_name[each.key]
  # WAFv2 description charset excludes parentheses (word chars + =:#@/-,. and spaces only).
  description = "${each.value.scope == "CLOUDFRONT" ? "Edge" : "Regional"} WAF for ${each.value.name != null ? each.value.name : "${local.name_prefix} - ${each.key}"}"
  scope       = each.value.scope

  default_action {
    dynamic "allow" {
      for_each = each.value.default_action == "allow" ? [1] : []
      content {}
    }
    dynamic "block" {
      for_each = each.value.default_action == "block" ? [1] : []
      content {}
    }
  }

  dynamic "rule" {
    for_each = { for r in each.value.rate_based_rules : r.name => r }

    content {
      name     = rule.value.name
      priority = rule.value.priority

      action {
        dynamic "block" {
          for_each = rule.value.action == "block" ? [1] : []
          content {}
        }
        dynamic "count" {
          for_each = rule.value.action == "count" ? [1] : []
          content {}
        }
      }

      statement {
        rate_based_statement {
          limit                 = rule.value.limit
          evaluation_window_sec = rule.value.evaluation_window_seconds
          aggregate_key_type    = rule.value.aggregate_key_type

          dynamic "forwarded_ip_config" {
            for_each = rule.value.aggregate_key_type == "FORWARDED_IP" ? [1] : []
            content {
              header_name       = rule.value.forwarded_ip_header
              fallback_behavior = rule.value.forwarded_ip_fallback
            }
          }

          dynamic "scope_down_statement" {
            for_each = rule.value.path_prefix == null ? [] : [rule.value.path_prefix]
            content {
              byte_match_statement {
                positional_constraint = "STARTS_WITH"
                search_string         = scope_down_statement.value

                field_to_match {
                  uri_path {}
                }

                text_transformation {
                  priority = 0
                  type     = "URL_DECODE"
                }
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${local.waf_acl_name[each.key]}-${rule.value.name}"
        sampled_requests_enabled   = true
      }
    }
  }

  dynamic "rule" {
    for_each = { for g in each.value.managed_rule_groups : g.name => g }

    content {
      name     = rule.value.name
      priority = rule.value.priority

      override_action {
        dynamic "none" {
          for_each = rule.value.override_to_count ? [] : [1]
          content {}
        }
        dynamic "count" {
          for_each = rule.value.override_to_count ? [1] : []
          content {}
        }
      }

      statement {
        managed_rule_group_statement {
          name        = rule.value.name
          vendor_name = rule.value.vendor_name
          version     = rule.value.version

          dynamic "rule_action_override" {
            for_each = { for o in rule.value.rule_action_overrides : o.name => o }
            content {
              name = rule_action_override.value.name
              action_to_use {
                dynamic "allow" {
                  for_each = rule_action_override.value.action_to_use == "allow" ? [1] : []
                  content {}
                }
                dynamic "block" {
                  for_each = rule_action_override.value.action_to_use == "block" ? [1] : []
                  content {}
                }
                dynamic "count" {
                  for_each = rule_action_override.value.action_to_use == "count" ? [1] : []
                  content {}
                }
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${local.waf_acl_name[each.key]}-${rule.value.name}"
        sampled_requests_enabled   = true
      }
    }
  }

  dynamic "rule" {
    for_each = { for r in each.value.ip_rules : r.name => r }

    content {
      name     = rule.value.name
      priority = rule.value.priority

      action {
        dynamic "allow" {
          for_each = rule.value.action == "allow" ? [1] : []
          content {}
        }
        dynamic "block" {
          for_each = rule.value.action == "block" ? [1] : []
          content {}
        }
        dynamic "count" {
          for_each = rule.value.action == "count" ? [1] : []
          content {}
        }
      }

      statement {
        ip_set_reference_statement {
          arn = aws_wafv2_ip_set.main["${each.key}/${rule.value.name}"].arn
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${local.waf_acl_name[each.key]}-${rule.value.name}"
        sampled_requests_enabled   = true
      }
    }
  }

  dynamic "rule" {
    for_each = { for r in each.value.geo_rules : r.name => r }

    content {
      name     = rule.value.name
      priority = rule.value.priority

      action {
        dynamic "allow" {
          for_each = rule.value.action == "allow" ? [1] : []
          content {}
        }
        dynamic "block" {
          for_each = rule.value.action == "block" ? [1] : []
          content {}
        }
        dynamic "count" {
          for_each = rule.value.action == "count" ? [1] : []
          content {}
        }
      }

      # negate = true matches every country NOT listed (e.g. block non-US).
      statement {
        dynamic "geo_match_statement" {
          for_each = rule.value.negate ? [] : [1]
          content {
            country_codes = rule.value.country_codes
          }
        }
        dynamic "not_statement" {
          for_each = rule.value.negate ? [1] : []
          content {
            statement {
              geo_match_statement {
                country_codes = rule.value.country_codes
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${local.waf_acl_name[each.key]}-${rule.value.name}"
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = local.waf_acl_name[each.key]
    sampled_requests_enabled   = true
  }

  tags = merge(local.common_tags, { Name = local.waf_acl_name[each.key] })
}

# Log group created without KMS unless logging.kms_key_arn is set, matching the
# module's existing CloudWatch precedent (aws_cloudwatch_log_group.eks).
resource "aws_cloudwatch_log_group" "waf" {
  for_each = local.waf_log_groups

  name              = "aws-waf-logs-${local.waf_acl_name[each.key]}"
  retention_in_days = each.value.logging.retention_days
  kms_key_id        = each.value.logging.kms_key_arn

  tags = merge(local.common_tags, { Name = "aws-waf-logs-${local.waf_acl_name[each.key]}" })
}

# WAFv2 delivery to a CloudWatch log group needs a resource policy on the group;
# without it PutLoggingConfiguration is denied.
data "aws_iam_policy_document" "waf_logs" {
  count = length(local.waf_log_groups) > 0 ? 1 : 0

  statement {
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [for k in keys(local.waf_log_groups) : "${aws_cloudwatch_log_group.waf[k].arn}:*"]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "waf" {
  count = length(local.waf_log_groups) > 0 ? 1 : 0

  policy_name     = "${local.name_prefix}-waf-logs"
  policy_document = data.aws_iam_policy_document.waf_logs[0].json
}

resource "aws_wafv2_web_acl_logging_configuration" "main" {
  for_each = local.waf_logging

  depends_on = [aws_cloudwatch_log_resource_policy.waf]

  resource_arn = aws_wafv2_web_acl.main[each.key].arn
  log_destination_configs = [
    each.value.logging.destination_arn != null ? each.value.logging.destination_arn : try(aws_cloudwatch_log_group.waf[each.key].arn, null)
  ]

  dynamic "redacted_fields" {
    for_each = toset(each.value.logging.redacted_header_names)
    content {
      single_header {
        name = lower(redacted_fields.value)
      }
    }
  }

  dynamic "logging_filter" {
    for_each = each.value.logging.only_blocked ? [1] : []
    content {
      default_behavior = "DROP"
      filter {
        behavior    = "KEEP"
        requirement = "MEETS_ANY"
        condition {
          action_condition {
            action = "BLOCK"
          }
        }
      }
    }
  }
}

resource "aws_wafv2_web_acl_association" "direct" {
  for_each = local.waf_associations

  resource_arn = each.value.arn
  web_acl_arn  = aws_wafv2_web_acl.main[each.value.acl_key].arn
}
