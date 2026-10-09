# Changelog

All notable changes to the AWS EKS platform module are documented here. This
module is versioned independently of the rest of the repository; tags are of the
form `aws/platform/vX.Y.Z`.

## Unreleased

## 0.6.5 — 2026-10-09

### Fixed

- **Karpenter controller: `iam:ListInstanceProfiles`.** The
  `instanceprofile.garbagecollection` controller lists every instance profile
  in the account on each reconcile, and the action takes no resource-level
  permissions, so it cannot be scoped to the module's own profile. Without it
  that controller logged an `AccessDenied` every reconcile and orphaned
  profiles were never collected. Read-only and additive — no other behaviour
  changes.


## 0.6.4 — 2026-10-07

### Removed

- **`platform_workload_tolerations`** — dropped. The `workload-type` toleration
  each platform workload carries is already the taint a Karpenter NodePool
  applies, so the input only duplicated it in the pod spec. Nothing set it to
  anything else. `platform_workload_type` is unchanged and still selects the
  tier.


## 0.6.3 — 2026-10-07

### Added

- **`platform_workload_type` / `platform_workload_tolerations`** — repoint the
  Terraform-managed platform workloads (metrics-server, teleport-kube-agent,
  cluster-autoscaler, tfc-agent, aws-load-balancer-controller) off the
  `support` tier, e.g. onto a Karpenter NodePool, whose nodes are tainted and
  so need a toleration as well as a selector. `platform_workload_tolerations`
  APPENDS to the `workload-type` toleration each workload carries rather than
  replacing it, and its `operator`/`effect` are validated at plan time.
  Defaults (`"support"`, `[]`) keep every existing cluster on `support`.
  Placement style is unchanged per workload: soft node affinity for
  metrics-server / teleport-kube-agent / cluster-autoscaler / the LB
  controller, a hard `nodeSelector` for tfc-agent.

### Changed

- **tfc-agent now carries a `workload-type` toleration** matching its
  `nodeSelector`. It previously had the selector alone, so pointing it at a
  tainted node pool left it Pending. Adds one toleration to the pod spec —
  inert on the untainted `support` group every cluster runs today, but it is
  a diff on the next apply.
- **The AWS Load Balancer Controller is now placed** with the same soft node
  affinity as teleport-kube-agent and cluster-autoscaler. It previously had no
  placement config. Soft (preferred, not required) so clusters without a
  `support` node group keep scheduling it.

## 0.6.2 — 2026-10-06

### Added

- **`waf_web_acls[*].label_rules` — act on a label, except on one route.** Blocks
  (or counts) requests carrying a label an earlier rule emitted, except on URI
  paths matching `exempt_path_regex`, which the module anchors as `^(…)$`.
  Paired with a managed rule overridden to `count`, it keeps that rule
  enforcing everywhere except the route it false-positives on, instead of
  counting it ACL-wide. Names and priorities share the ACL-wide uniqueness
  checks; regex syntax is checked at plan. Covered by mocked-provider plan
  tests (`tests/`), now run in CI. Additive: ACLs without `label_rules` see no
  diff.
- **`cluster_autoscaler_scale_down_utilization_threshold`** — sets Cluster
  Autoscaler's `--scale-down-utilization-threshold`. Defaults to `0.5`, CA's own
  default, so existing clusters see only the explicit flag added to the Helm
  release, no behavior change.

## 0.6.1 — 2026-10-05

### Fixed

- **EKS access entries for AWS SSO admin roles.** An SSO permission-set role
  has an IAM path, and the two access mechanisms disagree on it: aws-auth
  accepts the path-stripped ARN, while `CreateAccessEntry` rejects it as
  `invalid principal`. Under `API` or `API_AND_CONFIG_MAP`, an admin supplied
  in the aws-auth form therefore got no access entry. `cluster_admin_arns`
  keeps that form — no caller change — and the path is now rebuilt for the
  entry. Only the `:role/AWSReservedSSO_` prefix is rewritten, so the account
  ID in the supplied ARN is carried through: an admin is granted access in the
  account their ARN names, never the provider's.

### Added

- **`sso_instance_region` — region segment of the rebuilt SSO path.** Empty by
  default, which is correct for an IAM Identity Center hosted in `us-east-1`:
  AWS omits the region from those role ARNs. Set it to the Identity Center's
  region otherwise. Separate from `var.region`, since the Identity Center need
  not live in the cluster's region.

## 0.6.0 — 2026-10-01

### Added

- **`cluster_authentication_mode` — EKS access entries, opt-in.** Defaults to
  `CONFIG_MAP`, which is what every existing cluster uses, so this release is a
  no-op for them. `API_AND_CONFIG_MAP` writes access entries *and* aws-auth so a
  live cluster can migrate without a window where nodes cannot join; `API`
  writes entries only and skips the aws-auth ConfigMap entirely (the cluster
  ignores it in that mode, and leaving one behind would read like live access
  control). AWS rejects narrowing the mode, so `CONFIG_MAP` → `API_AND_CONFIG_MAP`
  → `API` is one-way.

  Admin principals from `cluster_admin_arns` get an entry plus
  `AmazonEKSClusterAdminPolicy`. The managed node-group role gets an `EC2_LINUX`
  entry only under `API`: under `API_AND_CONFIG_MAP` aws-auth already maps it,
  and AWS rejects an entry for a principal aws-auth also maps.

- **`karpenter_enabled` — Karpenter IAM prerequisites, opt-in (default off).**
  Creates a controller role bound to `karpenter/karpenter` by Pod Identity, a
  node role for the instances Karpenter launches, an instance profile, and the
  node's `EC2_LINUX` access entry. The controller, NodePools and EC2NodeClasses
  are deployed from the gitops repo.

  Requires `cluster_authentication_mode` other than `CONFIG_MAP` (validated): Karpenter
  nodes join through an access entry, which aws-auth cannot express for
  instances the module never sees.

  The controller policy scopes `TerminateInstances`/`DeleteLaunchTemplate` to
  resources tagged `kubernetes.io/cluster/<name>=owned`, `ec2:CreateTags` to
  that tag at creation time or on already-owned resources, and `iam:PassRole`
  to the node role alone — so none of them can reach another cluster in a
  shared account.

  The EC2NodeClass must use `spec.instanceProfile` (the
  `karpenter_node_instance_profile` output): the profile is created here and
  the controller holds only `iam:GetInstanceProfile` on it — the read Karpenter
  needs to resolve the NodeClass — and no instance-profile WRITE permissions,
  so `spec.role`, where Karpenter creates its own profile, will not work.

  New outputs: `karpenter_node_instance_profile`, `karpenter_node_role_name`,
  `karpenter_node_role_arn`, `karpenter_controller_role_arn`,
  `cluster_authentication_mode`.

  `karpenter_node_role_additional_policies` attaches extra managed policies to
  the node role.
## 0.5.5 — 2026-10-02

### Added

- **`storage_general_cors_origins` — browser access to the general bucket.**
  A presigned PUT is issued by the app but sent by the browser, so S3 answers
  the CORS preflight itself. A bucket with no CORS rule answers that preflight
  with 403 and no `Access-Control-Allow-Origin`, and the browser drops the
  upload before it is sent — the signature and the IAM grants are never
  reached. Set this to the app origins that upload (e.g.
  `["https://app.example.com"]`) to allow `GET`/`HEAD`/`PUT` and expose
  `ETag`. Defaults to `[]`, which creates no CORS configuration and leaves
  existing buckets untouched.

## 0.5.4 — 2026-09-28

### Fixed

- **VPC CNI addon: corrected `AWS_VPC_K8S_CNI_EXTERNAL_SNAT` to `AWS_VPC_K8S_CNI_EXTERNALSNAT`.**
  The env var set on the `vpc-cni` addon's `configuration_values` when
  `pod_isolation_enabled = true` was misspelled with an extra underscore — the
  real VPC CNI variable has never had one. Addon versions that validate
  `configuration_values` against the CNI's JSON schema reject the misspelled
  key outright (`ConfigurationValue provided in request is not supported`),
  failing `aws_eks_addon.vpc_cni` at apply. Only affects deployments with
  `pod_isolation_enabled = true`; deployments with it `false` never send this
  key and are unaffected. No input or output changes — just the corrected env
  var name.

## 0.5.3 — 2026-09-21

### Changed

- **`scope_down.exempt_when_header` is now `exempt_when_headers`**, a map of
  header name to exact value, so an exemption can require more than one header.
  Released in 0.5.2 as a single `{ name, value }` object; renamed before any
  consumer adopted it.

  Every condition — the IP list and each header — must match for a request to
  be exempt, so each one added narrows the exemption further. Two or more
  render a negated `and_statement`; a lone condition nests directly under the
  `not_statement`, since WAF requires at least two statements in an
  `and_statement`. Header values must be non-empty, and names must be unique
  after lowercasing — WAF matches header names case-insensitively, so `Host`
  and `host` would otherwise render two conditions on the same header that can
  never both match, silently disabling the exemption.

  ```hcl
  scope_down = {
    exempt_when_ips = ["198.51.100.0/28"]
    exempt_when_headers = {
      "Host"       = "app.example.com"
      "User-Agent" = "my-test-harness/1"
    }
  }
  ```

  Motivating case: pinning a CI exemption to the runner egress IPs, the host CI
  is allowed to reach, *and* the harness's own User-Agent — so other jobs
  sharing those runners do not inherit it. Headers remain client-supplied and
  are for narrowing an exemption, never for authenticating it.

## 0.5.2 — 2026-09-21

### Added

- **`waf_web_acls[*].managed_rule_groups[*].scope_down`** — narrow which requests
  a managed rule group inspects, so known-good traffic can skip **that one
  group** while every other group and rate limit in the ACL still applies.

  ```hcl
  { name = "AWSManagedRulesAnonymousIpList", priority = 70,
    scope_down = {
      exempt_when_ips    = ["198.51.100.0/28"]
      exempt_when_header = { name = "Host", value = "app.example.com" }
    } }
  ```

  Set either condition or both; both means the request must match **both** to be
  exempt. Note that a header is client-supplied, so `exempt_when_header` alone
  is not a trust boundary — pair it with `exempt_when_ips` when the exemption
  itself must be trustworthy. The module renders a negated `and_statement` (or the single condition
  directly — WAF requires at least two statements in an `and_statement`), and
  creates an `aws_wafv2_ip_set` per group that uses `exempt_when_ips`, keyed
  `<acl>/<group>` so the same group name in two ACLs cannot collide. Header
  values are matched case-insensitively.

  **Use this rather than an allow rule.** An allow rule terminates evaluation,
  so the exempted traffic would skip CRS, SQLi, KnownBadInputs and the rate
  limits as well. A scope-down narrows exactly one group and nothing else.

  Motivating case: GitHub-hosted CI runners egress from cloud provider ranges
  and are blocked by `AWSManagedRulesAnonymousIpList` / `HostingProviderIPList`.
  Exempting the runners' static egress IPs, qualified by the `Host` they are
  allowed to reach, lets CI through that group while everything else still
  inspects it. Entries without `scope_down` are completely unaffected.

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
