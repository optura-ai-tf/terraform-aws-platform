# Plans aws_eks_addon.vpc_cni.configuration_values against mocked providers.
# The value is assembled from independent fragments, so each toggle is asserted
# alone and in combination, and the all-off case must stay null: emitting "{}"
# instead would put a diff on every cluster running the defaults.
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
}

run "all_cni_options_off_leaves_configuration_values_null" {
  command = plan
  variables {
    pod_isolation_enabled         = false
    cni_prefix_delegation_enabled = false
    cni_network_policy_enabled    = false
  }

  assert {
    condition     = length(local.vpc_cni_config) == 0
    error_message = "with every CNI feature off the add-on must send no configuration_values, so clusters on the defaults see no diff"
  }
}

run "network_policy_alone" {
  command = plan
  variables {
    pod_isolation_enabled         = false
    cni_prefix_delegation_enabled = false
    cni_network_policy_enabled    = true
  }

  assert {
    condition     = local.vpc_cni_config.enableNetworkPolicy == "true"
    error_message = "cni_network_policy_enabled must set enableNetworkPolicy"
  }
  assert {
    condition     = !can(local.vpc_cni_config.env)
    error_message = "with no env fragments set the env key must be absent entirely"
  }
}

run "network_policy_alongside_existing_cni_settings" {
  command = plan
  variables {
    pod_isolation_enabled         = true
    cni_prefix_delegation_enabled = true
    cni_network_policy_enabled    = true
  }

  assert {
    condition     = local.vpc_cni_config.enableNetworkPolicy == "true"
    error_message = "enableNetworkPolicy must survive alongside the env fragments"
  }
  assert {
    condition = (
      local.vpc_cni_config.env.AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG == "true" &&
      local.vpc_cni_config.env.ENI_CONFIG_LABEL_DEF == "topology.kubernetes.io/zone" &&
      local.vpc_cni_config.env.AWS_VPC_K8S_CNI_EXTERNALSNAT == "false"
    )
    error_message = "enableNetworkPolicy must not displace the pod-isolation env keys"
  }
  assert {
    condition = (
      local.vpc_cni_config.env.ENABLE_PREFIX_DELEGATION == "true" &&
      local.vpc_cni_config.env.WARM_PREFIX_TARGET == "1"
    )
    error_message = "enableNetworkPolicy must not displace the prefix-delegation env keys"
  }
}

run "network_policy_off_preserves_existing_cni_settings" {
  command = plan
  variables {
    pod_isolation_enabled         = true
    cni_prefix_delegation_enabled = true
    cni_network_policy_enabled    = false
  }

  assert {
    condition     = !can(local.vpc_cni_config.enableNetworkPolicy)
    error_message = "the key must be absent when the toggle is off, not sent as \"false\""
  }
  assert {
    condition = (
      local.vpc_cni_config.env.AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG == "true" &&
      local.vpc_cni_config.env.ENABLE_PREFIX_DELEGATION == "true"
    )
    error_message = "turning the new toggle off must leave the pre-existing env fragments untouched"
  }
}
