# Plans the pod_identity_roles / irsa_roles IAM policies against mocked
# providers. A statement without effect or conditions must render exactly as it
# did before those fields existed (Allow, no Condition key), or every existing
# role would see a policy diff. A Deny with conditions must group them as
# Condition[test][variable].
# Run: terraform test

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

  pod_identity_roles = {
    intent = {
      namespace       = "intent"
      service_account = "intent"
      policy_statements = [
        {
          sid       = "SendEmail"
          actions   = ["ses:SendEmail", "ses:SendRawEmail"]
          resources = ["*"]
        },
        {
          sid       = "DenyExternalRecipients"
          effect    = "Deny"
          actions   = ["ses:SendEmail", "ses:SendRawEmail"]
          resources = ["*"]
          conditions = [
            { test = "ForAnyValue:StringNotLike", variable = "ses:Recipients", values = ["*@example.com"] },
            { test = "StringEquals", variable = "aws:RequestedRegion", values = ["us-east-1"] },
            { test = "StringEquals", variable = "ses:FromAddress", values = ["noreply@example.com"] },
          ]
        },
      ]
    }
  }

  irsa_roles = {
    loadtest = {
      namespace_pattern = "loadtest"
      service_account   = "intent"
      policy_statements = [
        {
          sid       = "SendEmail"
          actions   = ["ses:SendEmail"]
          resources = ["*"]
        },
        {
          sid       = "DenyExternalRecipients"
          effect    = "Deny"
          actions   = ["ses:SendEmail"]
          resources = ["*"]
          conditions = [
            { test = "ForAnyValue:StringNotLike", variable = "ses:Recipients", values = ["*@example.com"] },
          ]
        },
      ]
    }
  }
}

run "statement_without_effect_or_conditions_is_unchanged" {
  command = plan

  assert {
    condition = jsondecode(aws_iam_policy.pod_identity["intent"].policy).Statement[0] == {
      Sid      = "SendEmail"
      Effect   = "Allow"
      Action   = ["ses:SendEmail", "ses:SendRawEmail"]
      Resource = ["*"]
    }
    error_message = "a statement with no effect or conditions must render as Allow with no Condition key"
  }

  assert {
    condition = jsondecode(aws_iam_policy.irsa["loadtest"].policy).Statement[0] == {
      Sid      = "SendEmail"
      Effect   = "Allow"
      Action   = ["ses:SendEmail"]
      Resource = ["*"]
    }
    error_message = "irsa: a statement with no effect or conditions must render as Allow with no Condition key"
  }
}

run "deny_with_conditions" {
  command = plan

  assert {
    condition     = jsondecode(aws_iam_policy.pod_identity["intent"].policy).Statement[1].Effect == "Deny"
    error_message = "effect must be passed through"
  }

  assert {
    condition = jsondecode(aws_iam_policy.pod_identity["intent"].policy).Statement[1].Condition == {
      "ForAnyValue:StringNotLike" = { "ses:Recipients" = ["*@example.com"] }
      StringEquals = {
        "aws:RequestedRegion" = ["us-east-1"]
        "ses:FromAddress"     = ["noreply@example.com"]
      }
    }
    error_message = "conditions must be grouped as Condition[test][variable], merging variables that share a test"
  }

  assert {
    condition = jsondecode(aws_iam_policy.irsa["loadtest"].policy).Statement[1] == {
      Sid       = "DenyExternalRecipients"
      Effect    = "Deny"
      Action    = ["ses:SendEmail"]
      Resource  = ["*"]
      Condition = { "ForAnyValue:StringNotLike" = { "ses:Recipients" = ["*@example.com"] } }
    }
    error_message = "irsa: Deny with conditions must render effect and Condition"
  }
}

run "rejects_unknown_effect" {
  command = plan

  variables {
    irsa_roles = {
      loadtest = {
        namespace_pattern = "loadtest"
        service_account   = "intent"
        policy_statements = [{ sid = "S", effect = "deny", actions = ["ses:SendEmail"], resources = ["*"] }]
      }
    }
  }

  expect_failures = [var.irsa_roles]
}

run "rejects_empty_condition_values" {
  command = plan

  variables {
    pod_identity_roles = {
      intent = {
        namespace       = "intent"
        service_account = "intent"
        policy_statements = [{
          sid        = "S"
          effect     = "Deny"
          actions    = ["ses:SendEmail"]
          resources  = ["*"]
          conditions = [{ test = "ForAnyValue:StringNotLike", variable = "ses:Recipients", values = [] }]
        }]
      }
    }
  }

  expect_failures = [var.pod_identity_roles]
}

run "rejects_repeated_test_variable_pair" {
  command = plan

  variables {
    pod_identity_roles = {
      intent = {
        namespace       = "intent"
        service_account = "intent"
        policy_statements = [{
          sid       = "S"
          effect    = "Deny"
          actions   = ["ses:SendEmail"]
          resources = ["*"]
          conditions = [
            { test = "ForAnyValue:StringNotLike", variable = "ses:Recipients", values = ["*@example.com"] },
            { test = "ForAnyValue:StringNotLike", variable = "ses:Recipients", values = ["*@example.org"] },
          ]
        }]
      }
    }
  }

  expect_failures = [var.pod_identity_roles]
}
