# Plans waf_web_acls[*].label_rules against mocked providers and asserts the
# statement tree each shape renders. Run: terraform test

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-1a", "us-east-1b", "us-east-1c"], zone_ids = ["use1-az1", "use1-az2", "use1-az3"] }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "000000000000" }
  }
}
mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "kubectl" {}
mock_provider "random" {}
mock_provider "local" {}
mock_provider "tls" {}
mock_provider "http" {
  mock_data "http" {
    defaults = { response_body = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  environment  = "dev"
  region       = "us-east-1"
  project_name = "test"
  access_mode  = "vpn"

  waf_web_acls = {
    t = {
      managed_rule_groups = [{
        name     = "AWSManagedRulesCommonRuleSet"
        priority = 10
        rule_action_overrides = [
          { name = "CrossSiteScripting_BODY", action_to_use = "count" },
        ]
      }]
      label_rules = [
        { name = "exempt", priority = 11, label = "awswaf:managed:aws:core-rule-set:CrossSiteScripting_Body", exempt_path_regex = "/upload|/files/[^/]+/import" },
        { name = "bare", priority = 12, label = "x:bare", action = "count" },
      ]
    }
  }
}

run "renders_each_shape" {
  command = plan

  # exempt_path_regex: label AND NOT(path matches ^(...)$).
  assert {
    condition     = one([for r in aws_wafv2_web_acl.main["t"].rule : r if r.name == "exempt"]).statement[0].and_statement[0].statement[0].label_match_statement[0].key == "awswaf:managed:aws:core-rule-set:CrossSiteScripting_Body"
    error_message = "exempt: first statement must match the label"
  }
  assert {
    condition     = one([for r in aws_wafv2_web_acl.main["t"].rule : r if r.name == "exempt"]).statement[0].and_statement[0].statement[1].not_statement[0].statement[0].regex_match_statement[0].regex_string == "^(/upload|/files/[^/]+/import)$"
    error_message = "exempt: path regex must be wrapped as ^(...)$ so every alternative is anchored"
  }
  assert {
    condition     = one(one([for r in aws_wafv2_web_acl.main["t"].rule : r if r.name == "exempt"]).statement[0].and_statement[0].statement[1].not_statement[0].statement[0].regex_match_statement[0].text_transformation).type == "NONE"
    error_message = "exempt: path must not be URL-decoded"
  }
  assert {
    condition     = length(one([for r in aws_wafv2_web_acl.main["t"].rule : r if r.name == "exempt"]).action[0].block) == 1
    error_message = "exempt: action defaults to block"
  }

  # No exempt_path_regex: a bare label match.
  assert {
    condition = (
      length(one([for r in aws_wafv2_web_acl.main["t"].rule : r if r.name == "bare"]).statement[0].and_statement) == 0 &&
      one([for r in aws_wafv2_web_acl.main["t"].rule : r if r.name == "bare"]).statement[0].label_match_statement[0].key == "x:bare" &&
      length(one([for r in aws_wafv2_web_acl.main["t"].rule : r if r.name == "bare"]).action[0].count) == 1
    )
    error_message = "bare: expected a bare label_match_statement with a count action"
  }
}

run "rejects_invalid_path_regex" {
  command = plan
  variables {
    waf_web_acls = { t = { label_rules = [{ name = "a", priority = 1, label = "x:y", exempt_path_regex = "/(upload" }] } }
  }
  expect_failures = [var.waf_web_acls]
}

run "rejects_bad_label" {
  command = plan
  variables {
    waf_web_acls = { t = { label_rules = [{ name = "a", priority = 1, label = "x y" }] } }
  }
  expect_failures = [var.waf_web_acls]
}

run "rejects_allow_action" {
  command = plan
  variables {
    waf_web_acls = { t = { label_rules = [{ name = "a", priority = 1, label = "x:y", action = "allow" }] } }
  }
  expect_failures = [var.waf_web_acls]
}

run "rejects_priority_shared_with_other_kind" {
  command = plan
  variables {
    waf_web_acls = { t = {
      geo_rules   = [{ name = "g", priority = 1, country_codes = ["US"] }]
      label_rules = [{ name = "a", priority = 1, label = "x:y" }]
    } }
  }
  expect_failures = [var.waf_web_acls]
}
