# Changelog

All notable changes to the AWS EKS platform module are documented here. This
module is versioned independently of the rest of the repository; tags are of the
form `aws/platform/vX.Y.Z`.

## Unreleased

## 0.5.0 — 2026-08-06

### Added

- **`waf_web_acls`** — a map of regional AWS WAFv2 Web ACLs keyed by an arbitrary
  name (typically an environment), so one module instance can emit several ACLs —
  one per env when multiple share a cluster — each with independent rules, metrics,
  logging, and rollout state. Empty (the default) creates nothing. Each ACL supports
  `rate_based_rules` (per-IP throttling, optionally scoped to a URI `path_prefix`),
  `managed_rule_groups` (AWS/marketplace application-firewall groups, with
  group-level count mode and per-rule action overrides for safe rollout), `ip_rules`
  (allow/deny via `aws_wafv2_ip_set`), `geo_rules` (country allow/deny, with
  `negate` to match everything except the listed countries), and per-ACL request
  `logging` (module-created CloudWatch log group or a BYO S3/Firehose/CloudWatch
  destination, with `authorization`/`cookie` header redaction and optional
  blocked-only filtering). Creation is deliberately split from attachment: the
  module exposes each ARN via the new `waf_web_acl_arns` output (plus
  `waf_web_acl_ids`/`_names`/`_capacities`) for gitops to attach to
  controller-managed ALBs via the `alb.ingress.kubernetes.io/wafv2-acl-arn` Ingress
  annotation; use `associate_resource_arns` only for ALBs provisioned outside the
  controller.

- **`private_network_access_cidrs`** — a list of CIDR blocks permitted to reach the
  private EKS API endpoint on `443`. Applies only when `private_cluster_enabled =
  true`; empty (the default) creates no rule, preserving the prior behavior where
  the private endpoint is reachable only from the node security group. Populate it
  with an in-VPC bastion / CI runner CIDR (or a corp network reaching the endpoint
  over Direct Connect / VPN) so Terraform and operators can drive the API without
  attaching the node security group to the runner.

### Changed

- **`private_cluster_enabled` is no longer coupled to `tfc_agent_enabled`.** The
  validation requiring the in-cluster TFC agent has been removed — a private cluster
  can now be operated from any in-VPC runner (bastion / CI) via
  `private_network_access_cidrs`, with the TFC agent remaining one supported option
  rather than a requirement. Existing configs that set both continue to work
  unchanged.

### Removed

- **SES moved out of this module** — `ses.tf`, the `ses_domain_identities`
  variable, and the `ses_*` outputs are gone. SES is an account/region service
  whose lifecycle is independent of any one EKS cluster (and in split-account
  setups lives in accounts with no platform-module instance at all), so it is
  now the standalone `email/ses` module.
  Note that module — like this one before it — only creates the SES identity
  and Easy DKIM: **domain verification still requires the DKIM DNS records to be
  published** (the module does this only when given a Route53 zone, otherwise
  you publish them out of band), and **leaving the SES sandbox is a manual,
  per-account AWS support request** with no Terraform resource. See that
  module's README for the three steps that stay outside Terraform. The
  `ses:SendEmail` permission on the workload role still belongs in `irsa_roles`.

## 0.3.0 — BREAKING

This release reworks the network layout and pod addressing. **It is not an
in-place upgrade for existing clusters** — the new subnet names and sizes would
destroy and recreate subnets under a live cluster. Existing deployments must pin
`< 0.3.0` and follow [`UPGRADING-0.3.md`](UPGRADING-0.3.md) (blue/green rebuild)
before adopting it.

```hcl
# Existing clusters: stay on the 0.2.x line until you migrate.
version = "~> 0.2.2"
```

### Breaking changes

- **New default subnet layout.** The single `private_subnet_cidrs` tier is
  replaced by an explicit split: `node_subnet_cidrs` (EKS worker-node ENIs) and
  `lb_subnet_cidrs` (internal load balancers) now size their own tiers so nodes
  never compete with load balancers for address space. The default routable VPC
  is a tight **`/24`** (`vpc_cidr = "10.0.0.0/24"`) — node subnets default to
  three `/27`, internal-LB, public, and database subnets to three `/28` each
  (the whole layout fits the `/24` with one `/28` to spare). The public tier is
  optional (see `igw_enabled`). Because pods live in the non-routed `100.64`
  secondary CIDR, the routable carve only needs the node + LB + database +
  endpoint tiers — keeping the corporate-routable footprint minimal.
- **Pods default to a non-routed `100.64` secondary CIDR.** With
  `pod_isolation_enabled = true` (the new default), pods draw IPs from an RFC 6598
  `100.64.0.0/10` secondary CIDR associated with the VPC, via VPC CNI custom
  networking — keeping pod churn out of the routable address space so the primary
  CIDR stays small and peered/on-prem networks never have to account for pod IPs.
  Set `pod_isolation_enabled = false` to restore the pre-0.3 behavior of pods
  sharing node-subnet IPs.
- **RDS-over-Transit-Gateway ingress is now OPT-IN.** Previously, attaching the
  VPC to a Transit Gateway opened the database security groups to every
  `transit_gateway_cidr_blocks` entry on `5432`. That ingress is now gated behind
  the new `expose_database_to_transit_gateway` flag, **default `false`**. **This
  is a behavior change for existing TGW + RDS users:** after upgrading, the
  database is no longer reachable directly over the TGW unless you set
  `expose_database_to_transit_gateway = true`. By default, application traffic to
  the database stays in-VPC and human/admin access goes through Teleport.

### Added

- **`create_vpc` BYO / shared-VPC mode.** Set `create_vpc = false` to consume an
  externally-owned (e.g. AWS RAM-shared) VPC: supply `vpc_id`,
  `node_subnet_ids`, `lb_subnet_ids`, `database_subnet_ids`, and (for pod
  isolation) `pod_subnet_ids`. The module then creates no network resources of
  its own — the owner account manages the VPC, subnets, routing, IGW/NAT, TGW
  attachment, the `100.64` secondary CIDR, and the S3 gateway endpoint. See
  [`examples/shared-vpc/`](examples/shared-vpc/).
- **First-class `egress_mode`.** Choose how node/private subnets reach the
  internet: `"nat"` (default; module-owned NAT gateways), `"transit_gateway"`
  (default route hairpins through the customer network via `transit_gateway_id`,
  no NAT created), or `"none"` (air-gapped; no default route — reach AWS APIs via
  VPC endpoints).
- **`igw_enabled`.** When the module owns the VPC, set `igw_enabled = false` for a
  fully private VPC with no internet gateway and no public subnet tier (requires
  `egress_mode != "nat"`). See [`examples/pod-isolation/`](examples/pod-isolation/).
- **`cni_prefix_delegation_enabled`.** Toggle VPC CNI prefix delegation
  (`ENABLE_PREFIX_DELEGATION`) to raise pod density per node. Independent of pod
  isolation. **Default `true`** — with pod isolation on (the new default),
  custom networking lowers effective `max-pods`, so prefix delegation is enabled
  out of the box to keep the scheduler from over-committing nodes. Requires
  Nitro instance types (the default node family qualifies); set `false` for
  non-Nitro nodes and pin `max-pods` instead.
- New networking outputs: `node_subnet_ids`, `lb_subnet_ids`, `pod_subnet_ids`,
  `pod_secondary_cidr_association_id`, and `eniconfig_manifests`.
- New examples: [`examples/pod-isolation/`](examples/pod-isolation/)
  (corp-connected, module-owned private VPC) and
  [`examples/shared-vpc/`](examples/shared-vpc/) (BYO / RAM-shared VPC).

### Changed

- **Default versions refreshed.** Kubernetes `1.34 → 1.35`; RDS PostgreSQL
  `17.2 → 17.10`; Aurora PostgreSQL `16.6 → 17.9` (now aligned to the PostgreSQL
  17 major, matching RDS — Aurora and RDS never share an exact minor, so confirm
  the available minor in your Region with `aws rds describe-db-engine-versions`);
  cluster-autoscaler Helm chart `9.54.0 → 9.58.0`. Default node groups
  right-sized to `t3a.medium` with higher minimums. Bumping `aurora_engine_version`
  drives a major-version upgrade for any existing Aurora cluster; clusters pinned
  `< 0.3.0` are unaffected. (The `aws-load-balancer-controller` chart was left at
  `1.16.0`: the current release line crosses a controller-major boundary and
  needs a values/IAM-policy compatibility pass before adoption.)
- **`storage_logging_enabled` now defaults to `false`** (was `true`). The
  centralized log-storage bucket is opt-in; a bare module instantiation no longer
  provisions it. Set `storage_logging_enabled = true` to restore it.
- **EKS cluster `vpc_config` registers only the node subnets** (previously node +
  internal-LB). The AWS Load Balancer Controller discovers LB subnets by tag, so
  this keeps cross-account control-plane ENIs out of the small `/28` LB tier.

### Upgrading

There is no in-place path from the 0.2.x subnet layout. Adopting 0.3.0 is a
blue/green rebuild — see [`UPGRADING-0.3.md`](UPGRADING-0.3.md).
