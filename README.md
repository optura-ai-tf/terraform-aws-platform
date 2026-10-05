# EKS Platform Module (AWS)

A production-ready Amazon EKS platform packaged as a reusable Terraform module:
VPC across 3 AZs, an EKS cluster with a three-tier managed node-group layout, the
AWS Load Balancer Controller and Cluster Autoscaler, optional ECR, optional RDS /
Aurora PostgreSQL, optional S3 storage buckets wired to workload identities, and
Teleport-based zero-trust cluster access.

One module call provisions one environment. You supply the inputs; the module owns
the AWS, Kubernetes, and Helm provider wiring internally (see [Module notes](#module-notes)).

## Usage

The **consuming root** owns the backend and the AWS credentials. This module
declares neither a backend nor provider authentication — it inherits the AWS
region from the `region` input and configures the Kubernetes/Helm providers itself.

### Terraform Registry

```hcl
module "platform" {
  source  = "optura-ai-tf/platform/aws"
  version = "~> 0.6"

  environment  = "dev"
  region       = "us-east-1"
  project_name = "optura"
  # ... inputs below ...
}
```

Pin `version` to a `~>` range so patch releases flow in but a major bump is opt-in.

### Git source

To pin directly to a tag without the registry:

```hcl
module "platform" {
  source = "git::https://github.com/optura-ai-tf/terraform-aws-platform.git?ref=v0.5.0"

  environment  = "dev"
  region       = "us-east-1"
  project_name = "optura"
  # ... inputs below ...
}
```

Always pin `?ref=` to a tag (never a branch) so the module version is reproducible.

### Complete example

A runnable, end-to-end configuration lives in [`examples/complete/`](examples/complete/).
It exercises the required inputs plus node groups, networking, RDS, and Teleport
access for a cost-optimized dev environment — copy it and adjust for your account:

```hcl
module "platform" {
  source = "../../" # registry or git source in real consumers

  # ----- Required -----
  environment  = "dev"
  region       = "us-east-1"
  project_name = "optura"

  # IAM principals granted system:masters (see Core inputs)
  cluster_admin_arns = ["arn:aws:iam::123456789012:role/AdministratorAccess"]

  # ----- Network -----
  single_nat_gateway = true # one NAT for dev, ~$100/mo saved

  # ----- Database -----
  rds_instance_class      = "db.t4g.micro"
  rds_skip_final_snapshot = true

  # ----- Access -----
  access_mode            = "teleport"
  teleport_proxy_address = "teleport.example.com:443"
  # teleport_join_token sourced from the environment:
  #   export TF_VAR_teleport_join_token="..."
}
```

After a successful apply, configure `kubectl` (the `kubectl_config_command` output
prints the exact command for your cluster):

```bash
aws eks update-kubeconfig --region us-east-1 --name eks-optura-dev
kubectl get nodes
```

The cluster is named `eks-{project_name}-{environment}` (e.g. `eks-optura-dev`).

---

## Module notes

These three behaviors are specific to how this module is packaged. They are not
configurable — they are consequences of the design.

### Path A: provider blocks are retained inside the module

The module declares its own `aws`, `kubernetes`, and `helm` provider blocks. That
choice keeps the consuming root trivially small (no Kubernetes provider plumbing
to author), but it carries the standard "Path A" constraint from HashiCorp's module
guidance: **the module call does not support `count`, `for_each`, or `depends_on`.**

One module call equals one environment. To stand up dev and prod, use two separate
root configurations (or two workspaces) each with a single `module "platform"` call —
do not attempt to loop one call over a map of environments.

### In-cluster provider auto-detection

`main.tf` detects at plan time whether Terraform is running inside the target
cluster — specifically, whether the in-cluster service-account token exists at
`/var/run/secrets/kubernetes.io/serviceaccount/token`:

- **External runner** (your laptop, CI, or an HCP Terraform remote runner): the
  module authenticates the Kubernetes/Helm providers against the EKS public
  endpoint using `aws_eks_cluster_auth`.
- **In-cluster TFC agent pod**: the module uses the pod's own service-account token
  and CA cert, talking to `https://kubernetes.default.svc`.

The consuming root does nothing to select between these — detection is automatic.
This is what makes the private-cluster two-phase bootstrap (below) work: once the
TFC agent runs the apply from inside the cluster, the providers reach the private
API without a public endpoint.

### Provider versions

The module pins **permissive `>=` floors** (Terraform `>= 1.9.0`, AWS `>= 6.0`,
Kubernetes `>= 2.30`, Helm `>= 3.0`, plus `random`, `http`, `local`). Consumers
pin **exact** versions in their own root `.terraform.lock.hcl` so builds are
reproducible. Do not rely on the module to lock a specific provider patch — that
is the root's job.

---

## Inputs by feature

Set these as inputs on the `module "platform"` call. They are grouped by feature —
start with the core inputs, then enable the features you need. Every input's type
and exact default is in the [Reference](#reference) table at the bottom.

### Core inputs

Always set these:

| Input | Required | Default | Description |
|---|---|---|---|
| `environment` | yes | — | `dev`, `stg`, `uat`, or `prod` |
| `region` | no | `us-east-1` | AWS region for all resources |
| `project_name` | no | `optura` | Used in all resource names (`eks-{project_name}-{environment}`) |
| `kubernetes_version` | no | `1.34` | EKS control-plane version |
| `cluster_admin_arns` | recommended | `[]` | IAM user/role ARNs granted `system:masters`. Without this, only the deploying principal has cluster access. Supports AWS SSO roles. |
| `api_server_authorized_cidrs` | no | `[]` (open) | Restrict API server access to specific CIDRs. Only applies when `private_cluster_enabled = false`. |

### Feature: Database (`rds_enabled`)

Default: **`true`** — a PostgreSQL database is provisioned.

Set `rds_enabled = false` to skip the database entirely. The top-level `rds_*`
inputs supply the defaults that each named database inherits (see below):

| Input | Default | Description |
|---|---|---|
| `rds_instance_class` | `db.t4g.micro` | Instance size. Use a larger class for production. |
| `rds_engine_version` | `17.2` | PostgreSQL engine version (standalone RDS) |
| `rds_allocated_storage` | `20` | Initial storage in GB |
| `rds_max_allocated_storage` | `100` | Storage autoscaling cap in GB |
| `rds_multi_az` | `false` | Enable for production HA |
| `rds_skip_final_snapshot` | `true` | Set `false` for production to retain a snapshot on destroy |
| `rds_deletion_protection` | `false` | Set `true` for production |
| `rds_backup_retention_period` | `7` | Days to retain backups (0–35) |
| `rds_admin_username` | `psqladmin` | Master username |
| `rds_database_name` | `optura` | Initial database name |

#### Multiple named databases (`databases`)

The module provisions one database server per entry in the `databases` input
(default: `{ core = {} }`). Each map key becomes part of the cloud-side identifier:

- `core` is reserved for the primary database — its server keeps the unsuffixed
  identifier (`psql-{project}-{env}` / `optura-{env}-rds`) so existing deployments
  do not destroy and recreate the production database.
- Every other key is suffixed unconditionally (e.g. `optura-{env}-rds-temporal`).

Per-entry overrides are all optional and fall back to the top-level `rds_*`
defaults when omitted — a `{}` entry produces the same configuration as a single
legacy database:

```hcl
databases = {
  # core inherits all defaults — leave as {} to mirror a single-DB config
  core = {}

  # temporal sized independently; recommended for dev to keep costs flat
  temporal = {
    instance_class    = "db.t4g.micro"
    allocated_storage = 20
    db_name           = "temporal"
    multi_az          = false
  }
}
```

Supported per-entry fields: `engine`, `engine_version`, `instance_class`,
`instance_count`, `serverless_min_capacity`, `serverless_max_capacity`,
`allocated_storage`, `max_allocated_storage`, `multi_az`, `backup_retention_period`,
`deletion_protection`, `skip_final_snapshot`, `admin_username`, `db_name`.

> **Validation:** `databases` MUST contain a `core` key. Removing it changes the
> state address of the primary instance and Terraform would destroy + recreate it.

##### Engine selection (per database)

Each entry's `engine` field selects the database family:

| `engine` | Provisions | Sizing inputs |
|---|---|---|
| `"rds"` (default) | Standalone RDS PostgreSQL instance | `instance_class` ← `rds_instance_class`; `allocated_storage`, `multi_az` apply |
| `"aurora"` | Aurora PostgreSQL provisioned cluster | `instance_class` ← `aurora_instance_class`; HA via `instance_count > 1` (storage is managed) |
| `"aurora-serverless"` | Aurora PostgreSQL Serverless v2 cluster | `instance_class` forced to `db.serverless`; capacity via `serverless_min_capacity` / `serverless_max_capacity` (ACUs) |

The `core` key defaults to `"rds"` so existing deployments are untouched. Aurora
versions come from `aurora_engine_version` (default `16.6`), distinct from the
standalone `rds_engine_version` (default `17.2`) — Aurora 3.x covers PostgreSQL
15–16, and the `aurora-postgresql17` family must be available in your region before
you set a 17.x Aurora version.

> **Switching engines is destructive.** Changing an existing key from `rds` to
> `aurora` (or vice versa) is a DESTROY + RECREATE — Terraform cannot morph an
> `aws_db_instance` into an `aws_rds_cluster`, and moving the data is a separate
> snapshot-restore / DMS operation. Only switch engines on a database with no data
> you need to keep.

##### Cost impact

Each named database is a full database server (compute, storage, KMS key,
monitoring role). Adding a second entry roughly **doubles** the database line item.
For dev where that cost is unwelcome, size the extra entry down (as in the
`temporal` example above), or keep a single-database topology with
`databases = { core = {} }`.

##### Outputs (singular alias vs. map)

The legacy **singular** outputs are preserved as **aliases for the `core` entry** —
existing automation sees no change:

```hcl
module.platform.database_endpoint        # core host:port
module.platform.database_admin_username  # core master username (sensitive)
module.platform.database_admin_password  # core master password (sensitive)
module.platform.database_name            # core initial db name
```

For multi-DB consumers, the canonical outputs are **maps** keyed by `databases` key:

| Output | Type | Description |
|---|---|---|
| `database_endpoints` | `map(string)` | DB key → endpoint (`host:port`). Aurora keys resolve to the cluster writer endpoint. |
| `database_reader_endpoints` | `map(string)` | Aurora DB key → reader endpoint. Empty for `engine = "rds"` keys. |
| `database_names` | `map(string)` | DB key → initial database name |
| `database_admin_usernames` | `map(string)` (sensitive) | DB key → master username |
| `database_admin_passwords` | `map(string)` (sensitive) | DB key → master password |

```hcl
# From a consuming root, the map outputs look like:
# module.platform.database_endpoints = {
#   "core"     = "optura-prod-rds.abc123.us-east-1.rds.amazonaws.com:5432"
#   "temporal" = "optura-prod-rds-temporal.abc123.us-east-1.rds.amazonaws.com:5432"
# }
```

##### Teleport access for named DBs (known limitation)

When Teleport DB access is enabled, each named database is registered with the
Teleport DB agent under a distinct name (`{project}-{env}-rds-{key}`) and tagged
with a `static_labels.db = <key>` field. **However**, the RBAC roles this module
ships (`teleport-admins`, `teleport-viewers`) grant access to **all** registered
databases — they are not scoped per-DB. Anyone who can connect to `core` can also
connect to `temporal`. The `static_labels.db` field exists as the future hook for
per-DB role restrictions (e.g. a role with `db_labels: { db: ["core"] }`); per-DB
RBAC is a deliberate follow-up.

### Feature: SSL Certificate (`acm_create`)

Default: **`false`** — no certificate is created.

Set `acm_create = true` to provision an ACM certificate. When enabled, also set:

| Input | Required | Description |
|---|---|---|
| `acm_domain_name` | yes | Domain for the certificate (e.g., `*.example.com` for wildcard, `example.com` for non-wildcard) |
| `acm_subject_alternative_names` | no | Additional domains |
| `acm_route53_zone_id` | recommended | Route53 zone ID for automatic DNS validation. If omitted, validate the certificate manually. |

To use an existing certificate instead:

```hcl
acm_create          = false
acm_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/..."
```

### Feature: Container Registry (`registry_enabled`)

Default: **`false`** — no ECR repository is created.

Set `registry_enabled = true` to create a new ECR repository. To point at an
existing repository instead, leave it `false` and set `ecr_repository_name`:

```hcl
registry_enabled    = false
ecr_repository_name = "my-existing-repo"
```

When creating a repository, `ecr_scan_on_push`, `ecr_image_tag_mutability`,
`ecr_encryption_type`, and `ecr_lifecycle_policy` control its behavior.

### Feature: Logging Storage (`storage_logging_enabled`)

Default: **`true`** — an S3 bucket for log storage (Loki) is created and granted to
a workload via IRSA.

Set `storage_logging_enabled = false` to skip. When enabled, configure:

| Input | Default | Description |
|---|---|---|
| `storage_logging_namespace` | `monitoring` | Kubernetes namespace for the logging workload |
| `storage_logging_service_account` | `loki` | Service account granted S3 write access via IRSA |
| `storage_logging_bucket_name` | `{project}-{env}-logging` | Override the bucket name |
| `storage_logging_lifecycle` | IA 30d → Glacier 90d → expire 365d | Lifecycle transitions |

The `logging_storage_role_id` output is the IAM role ARN to annotate the service
account with (`eks.amazonaws.com/role-arn`).

### Feature: General Storage (`storage_general_enabled`)

Default: **`true`** — an S3 bucket for application data is created and granted to a
workload via IRSA.

Set `storage_general_enabled = false` to skip. When enabled, configure:

| Input | Default | Description |
|---|---|---|
| `storage_general_namespace` | `default` | Kubernetes namespace for the storage workload |
| `storage_general_service_account` | `app-storage` | Service account granted S3 access via IRSA |
| `storage_general_versioning` | `true` | Enable S3 object versioning |
| `storage_general_bucket_name` | `{project}-{env}-storage` | Override the bucket name |
| `storage_general_cors_origins` | `[]` | Browser origins allowed to upload directly via a presigned URL |

The `general_storage_role_id` output is the IAM role ARN to annotate the service
account with.

Browser uploads need `storage_general_cors_origins`. The app signs the URL but
the browser sends the PUT, so S3 answers the preflight; with no CORS rule it
returns 403 and the upload never leaves the browser.

### Feature: Cluster Access via Teleport (`access_mode`)

Default: **`teleport`** — the module deploys a Teleport Kubernetes agent for
zero-trust access. Set `access_mode = "vpn"` if you reach the cluster through an
existing VPN / Direct Connect and the public (or authorized-CIDR) endpoint.

When using Teleport, configure:

| Input | Required | Default | Description |
|---|---|---|---|
| `teleport_proxy_address` | yes | `teleport.example.com:443` | The Teleport proxy to connect to |
| `teleport_agent_chart_repository` | yes | — | Helm repo for the teleport-kube-agent chart (e.g. `https://charts.releases.teleport.dev`, or an OCI mirror). |
| `teleport_agent_image` | no | — | Agent image; empty uses the chart's default. Set for a private-registry mirror. |
| `teleport_join_token` | yes | — | Agent join token. Set via `export TF_VAR_teleport_join_token="..."` — never commit it. |
| `teleport_version` | no | `18.5.1` | Teleport agent version |
| `teleport_ca_pin` | recommended (prod) | — | CA pin for secure agent joining |
| `teleport_db_enabled` | no | `true` | Also enable Teleport database access for the provisioned databases. Requires `rds_enabled = true`. |
| `teleport_gateway_ip` | no | `null` | Static egress IP; `hostAliases` route proxy traffic through it so the agent exits via one IP. |

Two RBAC roles ship with the agent:

- `teleport-admins` — full cluster access (all namespaces, all operations)
- `teleport-viewers` — read-only access (all namespaces, view only)

### Feature: Private Cluster (`private_cluster_enabled`)

Default: **`false`** — the API server has a public endpoint.

Set `private_cluster_enabled = true` to remove the public endpoint entirely. The
private endpoint is reachable only from inside the VPC, so Terraform must drive the
API from an in-VPC source. This is **not** coupled to `tfc_agent_enabled` — any of
these work:

- **An in-VPC bastion / CI runner** (or a corp network reaching the endpoint over
  Direct Connect / VPN). Grant it access with `private_network_access_cidrs` (see
  below). This is the simplest option and needs no HCP Terraform.
- **The in-cluster TFC agent** (`tfc_agent_enabled = true`) — Terraform runs as a
  pod on a node, so it reaches the private API with no extra SG rule (see
  [in-cluster auto-detection](#in-cluster-provider-auto-detection)).

#### Granting API access to an in-VPC runner (`private_network_access_cidrs`)

By default a private cluster allows `443` only from the **node** security group, so a
bastion / runner that isn't a node is dropped at the security-group layer. List its
CIDR(s) to open the private endpoint to it:

```hcl
private_cluster_enabled      = true
private_network_access_cidrs = ["10.0.10.25/32"] # bastion / CI runner (or corp CIDR over DX/VPN)
```

Empty (the default) creates no rule. The variable is ignored when
`private_cluster_enabled = false` (public access is governed by
`api_server_authorized_cidrs`). Network reachability is only half the story — the
runner's IAM principal must also have a cluster access entry (`cluster_admin_arns`)
to authenticate. DNS must resolve the endpoint to the private IPs from the runner
(in-VPC uses the VPC resolver automatically; a corp network needs a Route 53
Resolver inbound endpoint + conditional forwarding — owner-account responsibility).

**Two-phase bootstrap.** A private cluster cannot be reached on its first apply
(the access path doesn't exist yet), so bring it up public, then lock it down.

**Phase 1 — Bootstrap with a public API**, then provision your access path (an
in-VPC runner, or the in-cluster TFC agent):

```hcl
module "platform" {
  # ...
  private_cluster_enabled = false # keep public during bootstrap
}
```

```bash
terraform apply
```

**Phase 2 — Lock down.** Re-apply from your in-VPC runner (with its CIDR in
`private_network_access_cidrs`), or from the in-cluster TFC agent if you deployed one:

```hcl
private_cluster_enabled      = true
private_network_access_cidrs = ["10.0.10.25/32"]
```

```bash
terraform apply # from an in-VPC runner that can reach the private endpoint
```

> **Using the in-cluster TFC agent instead?** Set `tfc_agent_enabled = true` (plus
> `tfc_agent_token`), verify the agent with `kubectl get pods -n terraform-cloud`,
> switch the HCP Terraform workspace to Agent execution mode, then flip
> `private_cluster_enabled = true`. No `private_network_access_cidrs` needed.

### Node Groups (`node_groups`)

The `node_groups` input defaults to a three-tier layout. All clusters built from
this module follow the system / support / application model, and **every workload
manifest must set `nodeSelector.workload-type`** to land on the right pool:

1. **system** (`workload-type=system`) — core cluster services (CoreDNS,
   metrics-server). Tainted `CriticalAddonsOnly=true:NoSchedule`. Smallest pool.
2. **support** (`workload-type=support`) — ingress, monitoring, logging (ALB
   Controller, Prometheus, Loki). Medium pool.
3. **application** (`workload-type=application`) — user-facing APIs, services, batch
   jobs. Largest pool, most aggressive autoscaling.

Override for production sizing:

```hcl
node_groups = {
  system = {
    instance_types = ["t3a.medium"]
    min_size       = 2
    max_size       = 4
    desired_size   = 2
    disk_size      = 50
    labels         = { "workload-type" = "system" }
    taints         = [{ key = "CriticalAddonsOnly", value = "true", effect = "NO_SCHEDULE" }]
  }
  support = {
    instance_types = ["t3a.large"]
    min_size       = 1
    max_size       = 4
    desired_size   = 2
    disk_size      = 50
    labels         = { "workload-type" = "support" }
    taints         = []
  }
  application = {
    instance_types = ["m6i.xlarge"]
    min_size       = 2
    max_size       = 10
    desired_size   = 3
    disk_size      = 100
    labels         = { "workload-type" = "application" }
    taints         = []
  }
}
```

Every deployment you target at this cluster needs:

```yaml
spec:
  template:
    spec:
      nodeSelector:
        workload-type: application # or support, system
```

#### Changing the node AMI type (Bottlerocket, ARM/AMD)

Each node group takes an optional `ami_type`. Leave it unset (the default) and EKS
uses the standard Amazon Linux 2023 AMI for x86 (`AL2023_x86_64_STANDARD`). Set it
explicitly to switch operating system or CPU architecture.

> [!IMPORTANT]
> `ami_type` and `instance_types` **must agree on architecture**. An `*_ARM_64`
> AMI only boots on Graviton (`*g`) instances (`t4g`, `m7g`, `c7g`, …); an
> `*_x86_64` AMI only boots on x86 instances (`t3a`, `m6i`, `c6i`, …). A mismatch
> is rejected by the EKS API at apply time.

Common values (see the [EKS `ami_type` reference](https://docs.aws.amazon.com/eks/latest/APIReference/API_Nodegroup.html#AmazonEKS-Type-Nodegroup-amiType) for the full list):

| `ami_type` | OS | Arch | Pair with |
|---|---|---|---|
| `AL2023_x86_64_STANDARD` (default) | Amazon Linux 2023 | x86_64 | `t3a.*`, `m6i.*`, `c6i.*` |
| `AL2023_ARM_64_STANDARD` | Amazon Linux 2023 | arm64 | `t4g.*`, `m7g.*`, `c7g.*` |
| `BOTTLEROCKET_x86_64` | Bottlerocket | x86_64 | `t3a.*`, `m6i.*`, `c6i.*` |
| `BOTTLEROCKET_ARM_64` | Bottlerocket | arm64 | `t4g.*`, `m7g.*`, `c7g.*` |

[Bottlerocket](https://bottlerocket.dev/) is a minimal, container-optimized OS with
an immutable root filesystem and no SSH/shell or package manager (admin access is
via the out-of-band [admin container](https://github.com/bottlerocket-os/bottlerocket#exploring-the-filesystem)).
It pairs well with Graviton for cost/perf wins.

**Bottlerocket on x86 (AMD64):**

```hcl
node_groups = {
  application = {
    instance_types = ["m6i.xlarge"] # x86 instances
    ami_type       = "BOTTLEROCKET_x86_64"
    min_size       = 2
    max_size       = 10
    desired_size   = 3
    disk_size      = 100
    labels         = { "workload-type" = "application" }
    taints         = []
  }
}
```

**Bottlerocket on ARM (Graviton):**

```hcl
node_groups = {
  application = {
    instance_types = ["m7g.xlarge"] # Graviton (arm64) instances
    ami_type       = "BOTTLEROCKET_ARM_64"
    min_size       = 2
    max_size       = 10
    desired_size   = 3
    disk_size      = 100
    labels         = { "workload-type" = "application" }
    taints         = []
  }
}
```

You can mix architectures across pools (e.g. an x86 `system` group and an ARM
`application` group) — keep one architecture **per** node group so `ami_type` and
`instance_types` stay consistent.

**Before moving a workload to ARM:** every container image scheduled onto that pool
must have an `arm64` build (a multi-arch manifest, or an arm64-specific tag). This
includes your own images **and** anything that runs as a DaemonSet on those nodes.

> [!WARNING]
> `ami_type` and `instance_types` are immutable on an `aws_eks_node_group` —
> changing either on an existing pool **replaces the whole node group** (nodes are
> drained and recreated). For zero-downtime migrations, add a new node group with
> the target AMI/arch, shift workloads over (cordon/drain the old one), then remove
> the old group in a follow-up apply.

### Workload IAM (`irsa_roles`, `pod_identity_roles`)

Two independent mechanisms grant AWS permissions to Kubernetes workloads; both may
be populated on the same cluster.

- `irsa_roles` — IAM Roles for Service Accounts. Each entry creates an IAM role
  whose trust policy uses `StringLike` on the OIDC `:sub` claim, so
  `namespace_pattern` supports glob syntax (`*`, `?`). Annotate the matching
  ServiceAccount with `eks.amazonaws.com/role-arn = <role_arn>` (the ARN is in the
  `irsa` output). Adding a new namespace that matches the wildcard needs no
  `terraform apply`.
- `pod_identity_roles` — EKS Pod Identity. Each entry creates an IAM role plus a Pod
  Identity Association. Bindings require an **exact** `(namespace, service_account)`
  match — the AWS API does not support wildcards. A non-empty map also installs the
  Pod Identity Agent addon. For wildcard namespaces, use `irsa_roles` instead.

### Feature: Transit Gateway (`transit_gateway_id`)

Default: **off** (`transit_gateway_id = null`) — no Transit Gateway resources are created and existing deployments are unaffected.

Set `transit_gateway_id` to the ID of an existing Transit Gateway (typically shared into the account via AWS RAM) to attach this VPC to it, giving EKS nodes and RDS reachability to other VPCs and on-prem networks without VPC peering. When set:

- The VPC is attached to the TGW (default route-table association + propagation, each toggleable via `transit_gateway_default_route_table_association` / `..._propagation`), with the attachment ENIs placed in the private subnets (override via `transit_gateway_subnet_ids`).
- A route to the TGW is added to every private route table (database subnets share these) for each entry in `transit_gateway_cidr_blocks`.
- Ingress is opened on the EKS **node** security group (all traffic by default, restrictable via `transit_gateway_node_ingress`) for every TGW CIDR. The **internal load balancers** reachable from those nodes are likewise routed. The **database** is NOT exposed over the TGW by default — see `expose_database_to_transit_gateway` below.

| Input | Default | Description |
|---|---|---|
| `transit_gateway_id` | `null` | ID of an existing Transit Gateway to attach to. `null` disables the feature. Validated against the `tgw-` ID format. |
| `transit_gateway_cidr_blocks` | `[]` | CIDRs reachable via the TGW (other VPCs, on-prem). One route + SG ingress rule per CIDR. Validated as IPv4 CIDRs (IPv6 is rejected — routes are IPv4-only). |
| `transit_gateway_subnet_ids` | `null` | Subnets for the attachment ENIs. `null` uses the private subnets (one per AZ recommended for HA). Must be `null` or a non-empty list. |
| `transit_gateway_default_route_table_association` | `true` | Associate the attachment with the TGW default route table. Set `false` for segregated route tables in hub-and-spoke topologies. |
| `transit_gateway_default_route_table_propagation` | `true` | Propagate routes to the TGW default route table. Set `false` to manage propagation separately. |
| `transit_gateway_node_ingress` | `[]` | Port ranges allowed from each TGW CIDR to the EKS nodes. Empty = all traffic (protocol `-1`); set explicit `{from_port, to_port, protocol}` ranges to restrict cross-VPC node access. |
| `expose_database_to_transit_gateway` | `false` | **Opt-in** (changed in 0.3.0). When `true`, opens the RDS/Aurora security groups on `5432` to every `transit_gateway_cidr_blocks` entry so external networks reach the database directly over the TGW. Default `false`: database traffic stays in-VPC and admin access goes through Teleport. **Existing TGW + RDS users must set this `true` to keep the pre-0.3.0 direct-database path.** |

Routes and security-group rules use `for_each` keyed by CIDR, so adding or removing a CIDR only touches the affected entries. Outputs: `transit_gateway_id`, `transit_gateway_attachment_id`.

```hcl
transit_gateway_id          = "tgw-0123456789abcdef0"
transit_gateway_cidr_blocks = ["10.1.0.0/16", "10.2.0.0/16"]

# Optional: restrict node ingress instead of allowing all traffic from TGW CIDRs.
transit_gateway_node_ingress = [
  { from_port = 30000, to_port = 32767, protocol = "tcp" }, # NodePorts
  { from_port = 10250, to_port = 10250, protocol = "tcp" }, # kubelet
]
```

---

### Feature: WAF (`waf_web_acls`)

Default: **off** (`waf_web_acls = {}`) — no WAF resources are created.

`waf_web_acls` is a map of WAFv2 Web ACLs keyed by an arbitrary name.
One entry = one Web ACL. Key it by the thing the ACL protects — usually an
**environment** — so a single cluster hosting several envs gets one ACL per env,
each with independent rules, metrics, logging, and rollout state (e.g. count mode
in dev, block in prod). Each ACL's ARN is returned under the same key in the
`waf_web_acl_arns` output.

The Web ACL name (and its metrics, log group, and tags) defaults to
`<project>-<environment>-<key>`. Set the optional per-entry `name` to override it
when the ACL is **not** env-specific — e.g. one ACL shared across environments,
named for the app it protects. Leave it unset and nothing changes. Note: the ACL
name is immutable in AWS, so changing `name` on an existing entry forces a
replacement; if the ACL is already associated with an ALB, detach it in gitops
first (create-new → repoint the annotation → delete-old) or `DeleteWebACL` fails
with `WAFAssociatedItemException`.

Each ACL is `REGIONAL` by default (for ALBs). Set `scope = "CLOUDFRONT"` for an
**edge** ACL fronting a CloudFront distribution — see
[Scope: regional vs edge](#scope-regional-vs-edge) below.

Each ACL can carry four rule kinds (rule **names** and **priorities** must each be
unique across all kinds within one ACL):

| Rule kind | Purpose |
|---|---|
| `rate_based_rules` | Per-client-IP throttling over a rolling window, optionally scoped to a URI `path_prefix`. |
| `managed_rule_groups` | AWS/marketplace managed rule groups — the application-firewall layer (SQLi, known-bad inputs, IP reputation, admin protection). `override_to_count` + per-rule `rule_action_overrides` give a safe rollout. |
| `ip_rules` | IP allow/deny lists. Each entry creates an `aws_wafv2_ip_set` and a matching rule. |
| `geo_rules` | Allow/deny by client country (ISO 3166-1 alpha-2). Set `negate = true` to match every country **except** those listed (e.g. block all non-US traffic with `action = "block"`). |

Per-ACL `logging` writes request logs to a module-created CloudWatch log group
(`aws-waf-logs-<prefix>-<key>`) or an existing S3/Firehose/CloudWatch destination
(`destination_arn`). By default the `authorization` and `cookie` headers are
redacted so session tokens on public routes are never logged, and `only_blocked`
keeps just the blocked requests (dropping allowed and counted) to cut volume.

**Attachment is not done here for the intent ALBs.** They are provisioned by the
aws-load-balancer-controller from a Kubernetes Ingress, so a Terraform
`aws_wafv2_web_acl_association` would fight the controller. Take the ARN from
`waf_web_acl_arns[<key>]` and attach it in **gitops** with the Ingress annotation:

```yaml
alb.ingress.kubernetes.io/wafv2-acl-arn: <arn>   # regional WAFv2 only
```

Use `associate_resource_arns` only for load balancers provisioned outside the
controller (the module then creates the `aws_wafv2_web_acl_association` for you).

#### Narrowing a managed rule group (`scope_down`)

A managed rule group inspects every request by default. When a group has a
false positive on traffic you trust, `scope_down` exempts that traffic from
**that group alone**:

```hcl
managed_rule_groups = [
  { name = "AWSManagedRulesAnonymousIpList", priority = 70,
    scope_down = {
      exempt_when_ips = ["198.51.100.0/28", "203.0.113.0/28"]
      exempt_when_headers = {
        "Host"       = "app.example.com"
        "User-Agent" = "my-test-harness/1"
      }
    } },
]
```

`exempt_when_headers` maps header name to exact value. Every condition set —
the IP list and each header — must match for a request to be exempt, so **each
one you add narrows the exemption**. The example above reads as "inspect
everything except requests from these IPs, addressed to this host, from this
client". Comparison is case-insensitive on both name and value.

At least one condition is required. Two or more render a negated
`and_statement`; a lone condition nests directly under the `not_statement`,
because WAF requires at least two statements in an `and_statement`.

> **Headers alone are not a trust boundary.** They are supplied by the client,
> so `exempt_when_headers` on its own lets anyone who sends those values skip
> the group. They are the right tool for *narrowing* an exemption — to a
> hostname, a route, a particular caller — but pair them with
> `exempt_when_ips` whenever the exemption itself has to be trustworthy.

`exempt_when_ips` creates the `aws_wafv2_ip_set` for you, keyed
`<acl>/<group>` so the same group name in two ACLs cannot collide.

**Reach for this instead of an allow rule.** An allow rule is terminating: the
traffic it matches skips CRS, SQLi, KnownBadInputs, AdminProtection and every
rate-based rule as well, which is almost never what you want. A scope-down
narrows one group and leaves the rest of the ACL enforcing.

The common case is CI. GitHub-hosted runners egress from cloud provider ranges,
so `AWSManagedRulesAnonymousIpList` blocks them via `HostingProviderIPList`.
Exempting the runners' static egress IPs, qualified by the `Host` they may
reach and the `User-Agent` the harness sends, unblocks CI without weakening the
group for anyone else. The `Host` keeps the exemption from following the ACL
onto other ingresses if it is ever attached more widely; the `User-Agent` keeps
it to the one workload, so other jobs sharing those runners do not inherit it.

#### Scope: regional vs edge

| | `scope = "REGIONAL"` (default) | `scope = "CLOUDFRONT"` |
|---|---|---|
| Protects | ALB, API Gateway, AppSync | CloudFront distributions |
| Must be created in | the deployment's own region | **us-east-1 only** |
| Attach by | Ingress `alb.ingress.kubernetes.io/wafv2-acl-arn`, or `associate_resource_arns` | the distribution's `web_acl_id` |

Two constraints the module enforces for you:

- `associate_resource_arns` is rejected on a `CLOUDFRONT`-scope entry — WAF's
  `AssociateWebACL` does not accept CloudFront resources, so the attachment has to
  happen on the distribution.
- An `ip_rules` IP set inherits its ACL's scope, because a set and the ACL
  referencing it must match.

The us-east-1 requirement is **not** validated (the variable can't see the
provider region) — a `CLOUDFRONT` entry in a non-us-east-1 deployment fails at
apply with `WAFInvalidParameterException`.

This module configures its own `provider "aws"` from `var.region` and declares no
`configuration_aliases`, so there is **no** way to route just the edge ACL to
us-east-1 from a deployment in another region. A `CLOUDFRONT` entry is therefore
only usable when the deployment's own `region` is us-east-1 (as
`optura/{dev,prod}/aws` are). For a deployment in any other region, declare the
edge ACL in a separate us-east-1 root module instead of here.

Changing `scope` on an existing entry forces the Web ACL to be **replaced**, which
detaches it from whatever it currently protects. Create a new key instead of
re-scoping a live one.

#### Example 1 — rate limiting + all managed rule groups

```hcl
waf_web_acls = {
  prod = {
    rate_based_rules = [{
      name     = "global-rate-limit"
      priority = 0
      limit    = 2000
    }]

    managed_rule_groups = [
      { name = "AWSManagedRulesCommonRuleSet", priority = 10 },
      { name = "AWSManagedRulesKnownBadInputsRuleSet", priority = 20 },
      { name = "AWSManagedRulesSQLiRuleSet", priority = 30 },
      { name = "AWSManagedRulesLinuxRuleSet", priority = 40 },
      { name = "AWSManagedRulesUnixRuleSet", priority = 50 },
      { name = "AWSManagedRulesAmazonIpReputationList", priority = 60 },
      { name = "AWSManagedRulesAnonymousIpList", priority = 70 },
      { name = "AWSManagedRulesAdminProtectionRuleSet", priority = 80 },
    ]

    logging = { enabled = true, only_blocked = true }
  }
}
```

#### Example 2 — same, but block all traffic from outside the US

Identical to Example 1 with one added `geo_rules` entry that blocks every country
except the US. `negate = true` inverts the country match, and a low priority makes
it evaluate before the rate and managed rules.

```hcl
waf_web_acls = {
  prod = {
    geo_rules = [{
      name          = "block-non-us"
      priority      = 1
      action        = "block"
      country_codes = ["US"]
      negate        = true # match everything that is NOT US
    }]

    rate_based_rules = [{
      name     = "global-rate-limit"
      priority = 0
      limit    = 2000
    }]

    managed_rule_groups = [
      { name = "AWSManagedRulesCommonRuleSet", priority = 10 },
      { name = "AWSManagedRulesKnownBadInputsRuleSet", priority = 20 },
      { name = "AWSManagedRulesSQLiRuleSet", priority = 30 },
      { name = "AWSManagedRulesLinuxRuleSet", priority = 40 },
      { name = "AWSManagedRulesUnixRuleSet", priority = 50 },
      { name = "AWSManagedRulesAmazonIpReputationList", priority = 60 },
      { name = "AWSManagedRulesAnonymousIpList", priority = 70 },
      { name = "AWSManagedRulesAdminProtectionRuleSet", priority = 80 },
    ]

    logging = { enabled = true, only_blocked = true }
  }
}
```

> **Capacity:** a Web ACL has a default ceiling of **1500 WCU**. Rate-based rules
> are cheap; managed rule groups consume WCUs — watch `waf_web_acl_capacities[<key>]`
> as you add groups. The groups above carry no charge beyond standard WAF request
> costs; the intelligent-threat groups (`AWSManagedRulesBotControlRuleSet`,
> `AWSManagedRulesATPRuleSet`, `AWSManagedRulesACFPRuleSet`) bill extra and are
> intentionally not included here.

---

### Network (v0.3.0 layout)

> **0.3.0 is a breaking change to the network layout.** The subnet tiers were
> renamed and resized and pods moved to a non-routed CIDR. There is no in-place
> upgrade from 0.2.x — see [`CHANGELOG.md`](CHANGELOG.md) and
> [`UPGRADING-0.3.md`](UPGRADING-0.3.md). Existing clusters should pin `< 0.3.0`.

The module owns a small **routable** VPC split into purpose-built tiers, and runs
pods on a separate **non-routed** secondary CIDR. Defaults work for most
deployments; override only on CIDR conflicts.

#### Routable vs. non-routed address space

| Tier | Variable | Default | Routable? | What lives here |
|---|---|---|---|---|
| VPC primary | `vpc_cidr` | `10.0.0.0/24` | — | The routable address space (node + LB + database + endpoints) |
| Node subnets | `node_subnet_cidrs` | three `/27` | **Yes** | EKS worker-node ENIs |
| Internal LB subnets | `lb_subnet_cidrs` | three `/28` | **Yes** | Internal ALBs / NLBs |
| Database subnets | `database_subnet_cidrs` | three `/28` | Yes (in-VPC; off-VPC only via `expose_database_to_transit_gateway`) | RDS / Aurora ENIs |
| Public subnets | `public_subnet_cidrs` | three `/28` (only when `igw_enabled = true`) | Yes | Internet-facing LBs, NAT gateways |
| Pod subnets | `pod_subnet_cidrs` | three `/23` (from `pod_secondary_cidr`) | **No** — non-routed secondary CIDR | Pod ENIs via VPC CNI custom networking |
| Pod secondary CIDR | `pod_secondary_cidr` | `100.64.0.0/21` | **No** (RFC 6598) | The block the pod subnets are carved from |

Because pods draw from the non-routed `100.64` space, the routable `/24` only has
to hold node ENIs, load balancers, database ENIs, and VPC endpoints — peered /
on-prem networks never have to account for pod IPs. The default layout (node
`/27` + lb/public/database `/28` per AZ) fills the `/24` with one `/28` to spare;
this matches the minimal app/node routable carve agreed for corp-connected
landing zones.

#### Core networking inputs

| Input | Default | Description |
|---|---|---|
| `vpc_cidr` | `10.0.0.0/24` | Primary (routable) VPC CIDR. A `/24` holds the default layout (node `/27` + lb/public/database `/28`) with a spare `/28`. |
| `node_subnet_cidrs` | `["10.0.0.0/27", "10.0.0.32/27", "10.0.0.64/27"]` | Node subnets (one per AZ). `/27` ≈ 27 usable, ample with pod isolation on; widen to `/26`+ for many nodes/AZ or when pod isolation is off. |
| `lb_subnet_cidrs` | `["10.0.0.96/28", "10.0.0.112/28", "10.0.0.128/28"]` | Internal LB subnets (one per AZ). Must match `node_subnet_cidrs` length. |
| `database_subnet_cidrs` | `["10.0.0.192/28", "10.0.0.208/28", "10.0.0.224/28"]` | Database subnets (one per AZ). Must match `node_subnet_cidrs` length. |
| `public_subnet_cidrs` | `["10.0.0.144/28", "10.0.0.160/28", "10.0.0.176/28"]` | Public subnets (one per AZ). Only created when `igw_enabled = true`. |
| `single_nat_gateway` | `false` | Set `true` for dev to run one NAT instead of one per AZ (~$100/mo saved). Production uses HA (one NAT per AZ). |
| `enable_vpc_endpoints` | `true` | Provision VPC endpoints for S3, ECR (api + dkr), EC2, and STS so node pull/identity traffic skips NAT and cuts egress cost. |

> **`/28` is the AWS subnet minimum.** AWS does not allow a subnet smaller than a
> `/28` (16 addresses, 11 usable after AWS reserves 5). The `/28` LB / database /
> public tiers are already at that floor — do not shrink them.

> **Subnet CIDR changes are destroy/recreate.** Changing any `*_subnet_cidrs`
> value (or `vpc_cidr`) on an existing cluster replaces the affected subnets —
> Terraform cannot resize a subnet in place. Treat the layout as fixed for the
> life of a cluster; to change it, follow the blue/green path in
> [`UPGRADING-0.3.md`](UPGRADING-0.3.md).

#### Pod isolation (VPC CNI custom networking)

Default: **`pod_isolation_enabled = true`** — pods run on the non-routed
`pod_secondary_cidr` (`100.64.0.0/21`) via per-AZ ENIConfigs. Set it `false` to
fall back to pods sharing node-subnet IPs (the pre-0.3 behavior); the secondary
CIDR, pod subnets, and ENIConfigs then disappear.

| Input | Default | Description |
|---|---|---|
| `pod_isolation_enabled` | `true` | Run pods on a non-routed secondary CIDR via VPC CNI custom networking. |
| `pod_secondary_cidr` | `100.64.0.0/21` | RFC 6598 secondary CIDR associated with the VPC for pod IPs (module-owned case). Must not overlap `vpc_cidr`. |
| `pod_subnet_cidrs` | `["100.64.0.0/23", "100.64.2.0/23", "100.64.4.0/23"]` | Pod subnets (one per AZ, 512 IPs each) carved from `pod_secondary_cidr`. Used when the module owns the pod subnets. |
| `pod_subnet_ids` | `[]` | Bring-your-own pod subnet IDs (one per AZ). When set, the module points ENIConfigs at these and creates no secondary CIDR or pod subnets. |
| `cni_prefix_delegation_enabled` | `true` | Enable VPC CNI prefix delegation (`ENABLE_PREFIX_DELEGATION`) to raise pod density per node. Independent of pod isolation. Defaults on; requires Nitro instance types. |

> **Capacity note:** custom networking takes the node's primary ENI out of the
> pod IP pool, so a node holds fewer pods than the EKS-optimized AMI's default
> `max-pods` assumes — left unaddressed, surplus pods stay `ContainerCreating`
> with no IP. This is why `cni_prefix_delegation_enabled` defaults to `true`
> (Nitro instances; the default `t3a` family qualifies), which raises per-node
> capacity to absorb the loss. On non-Nitro instance types set it to `false`
> and pin `max-pods` via a launch template instead. See
> [UPGRADING-0.3.md](./UPGRADING-0.3.md#operating-with-pod-isolation-pods-per-node-capacity).

#### Egress and the internet gateway

| Input | Default | Description |
|---|---|---|
| `egress_mode` | `"nat"` | How node/private subnets reach the internet. `"nat"` routes `0.0.0.0/0` through module-owned NAT gateways. `"transit_gateway"` points the default route at `transit_gateway_id` (no NAT — egress hairpins through the customer network). `"none"` installs no default route (air-gapped; reach AWS APIs via VPC endpoints). |
| `igw_enabled` | `true` | Create the internet gateway and public subnet tier. Set `false` for a fully private module-owned VPC; requires `egress_mode != "nat"` (NAT needs a public subnet + IGW). |
| `enable_nat_gateway` | `true` | Provision NAT gateways. Only honored when `egress_mode = "nat"`. |

See [`examples/pod-isolation/`](examples/pod-isolation/) for a fully private
(`igw_enabled = false`, `egress_mode = "transit_gateway"`) corp-connected cluster.

#### Bring-your-own / shared VPC (`create_vpc`)

Default: **`create_vpc = true`** — the module owns the VPC and every network
resource above. Set `create_vpc = false` to consume an externally-owned (e.g.
AWS RAM-shared) VPC: the module then creates **no** network resources and only
consumes the supplied subnet IDs. The owner account manages the VPC, subnets,
routing, IGW/NAT, TGW attachment, the `100.64` secondary CIDR, subnet tags, and
the S3 gateway endpoint.

| Input | Default | Description |
|---|---|---|
| `create_vpc` | `true` | Create the VPC and all network resources (`true`), or consume an externally-owned VPC by ID (`false`). When `false`, the `*_subnet_cidrs` and egress/NAT/IGW/TGW-creation settings are unused. |
| `vpc_id` | `null` | ID of the existing VPC to consume when `create_vpc = false`. |
| `node_subnet_ids` | `[]` | Existing node subnet IDs (one per AZ) to consume when `create_vpc = false`. |
| `lb_subnet_ids` | `[]` | Existing internal LB subnet IDs (one per AZ) to consume when `create_vpc = false`. |
| `database_subnet_ids` | `[]` | Existing database subnet IDs (one per AZ) to consume when `create_vpc = false` and `rds_enabled = true`. |
| `pod_subnet_ids` | `[]` | Existing pod subnet IDs (one per AZ) for VPC CNI custom networking. |

See [`examples/shared-vpc/`](examples/shared-vpc/) for the full BYO setup,
including the owner-account checklist (subnet tags, `100.64` association, S3
gateway endpoint, routing).

#### Dedicated node security group (`dedicated_node_sg_enabled`)

EKS already attaches its **managed cluster security group** to every managed
node — it covers node-to-node, node-to-control-plane, and node egress. The
module also creates its own `aws_security_group.eks_nodes`. On the nodes that SG
is redundant, but when `pod_isolation_enabled = true` the per-AZ ENIConfig places
it on **pod** secondary ENIs, so there it is load-bearing.

`dedicated_node_sg_enabled` (default `true`) keeps that SG. Set it to `false` to
drop the SG and point pod ENIs + TGW node ingress at the EKS-managed cluster SG
instead. At the default there is **no diff** — existing clusters are unaffected.

**Migrating an existing cluster from `true` to `false`.** For a cluster with
`pod_isolation_enabled = false` (pods share node IPs), the flip is a clean
destroy of the unused SG — plain `terraform apply`. For a cluster with
`pod_isolation_enabled = true`, the ENIConfig change only governs **new** pod
ENIs; pods already running keep the old SG, and AWS refuses to delete a SG still
attached to a live ENI (`DependencyViolation`). Sequence it:

1. Apply the ENIConfig change only, keeping the SG:
   `terraform apply -target='kubectl_manifest.eniconfig'`
2. Recycle the nodes so pods re-attach to the cluster SG
   (`aws eks update-nodegroup-version --cluster-name <c> --nodegroup-name <ng> --force`,
   or a cordon/drain/replace per node).
3. Confirm nothing still holds the old SG, then apply again to delete it:
   `aws ec2 describe-network-interfaces --filters Name=group-id,Values=<eks_nodes-sg-id> --query 'NetworkInterfaces[].NetworkInterfaceId'`
   (empty list ⇒ safe) → `terraform apply`.

If you skip the split and hit `DependencyViolation`, it is not broken — do
step 2, then re-run `terraform apply`.

**TGW-connected clusters** (`transit_gateway_id` set) have two extra effects on
the `false` path, because `nodes_from_tgw` moves from the (unattached) node SG to
the cluster SG that every node actually carries:

- The `nodes_from_tgw` rules become **live for the first time** — TGW source
  CIDRs reach the nodes where before they hit a SG nothing carried. Audit
  `transit_gateway_cidr_blocks` before applying so you're only opening what you
  intend.
- `security_group_id` is `ForceNew` on `aws_security_group_rule`, so those rules
  are **replaced** (destroy + recreate on the new SG), not updated in place —
  expect a brief window during `apply` where the TGW ingress is absent.
- With `pod_isolation_enabled = true`, the ENIConfig also lands on the cluster
  SG, so TGW CIDRs can then reach **pod** secondary ENIs directly, not just node
  ENIs. Confirm that's intended for isolated-pod workloads.

---

## Operating the deployed platform

These commands run against a cluster the module produced — they are the same
regardless of how the module was sourced.

### Database access

Provisioned databases have no public endpoint. From a consuming root, read the
endpoint outputs and connect via a pod (the singular `database_endpoint` output
resolves to the `core` server):

```bash
# Legacy singular output — resolves to the "core" entry
kubectl run -it --rm psql --image=postgres:17 --restart=Never -- \
  psql -h "$(terraform output -raw database_endpoint)" -U psqladmin -d optura

# Multi-DB map output — pick a specific named DB
terraform output database_endpoints
# { "core" = "...", "temporal" = "..." }
```

Or via Teleport when `access_mode = "teleport"` and `teleport_db_enabled = true`.
Each entry in `databases` registers as a separate Teleport database:

```bash
tsh db ls
# Name                       Description  Labels
# optura-dev-rds                          db=core,...
# optura-dev-rds-temporal                 db=temporal,...

tsh db connect optura-dev-rds          --db-user=psqladmin --db-name=optura
tsh db connect optura-dev-rds-temporal --db-user=psqladmin --db-name=temporal
```

> **RBAC note:** the default Teleport roles grant access to all registered
> databases — a user who can connect to `core` can also connect to `temporal`.
> Per-DB RBAC via the `static_labels.db` selector is a planned follow-up.

### Push images to ECR

```bash
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin "$(terraform output -raw registry_url)"

docker tag myapp:latest "$(terraform output -raw registry_url):latest"
docker push "$(terraform output -raw registry_url):latest"
```

---

## Reference

The tables below are generated by `terraform-docs` from the module source. Do not
edit between the markers — regenerate with the repository config.

<!-- BEGIN_TF_DOCS -->


## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.0 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | >= 3.0 |
| <a name="requirement_http"></a> [http](#requirement\_http) | >= 3.0 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | ~> 1.14 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | >= 2.30 |
| <a name="requirement_local"></a> [local](#requirement\_local) | >= 2.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | >= 3.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 6.0 |
| <a name="provider_helm"></a> [helm](#provider\_helm) | >= 3.0 |
| <a name="provider_http"></a> [http](#provider\_http) | >= 3.0 |
| <a name="provider_kubectl"></a> [kubectl](#provider\_kubectl) | ~> 1.14 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | >= 2.30 |
| <a name="provider_local"></a> [local](#provider\_local) | >= 2.0 |
| <a name="provider_random"></a> [random](#provider\_random) | >= 3.0 |
| <a name="provider_terraform"></a> [terraform](#provider\_terraform) | n/a |
| <a name="provider_tls"></a> [tls](#provider\_tls) | n/a |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [aws_acm_certificate.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/acm_certificate) | resource |
| [aws_acm_certificate_validation.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/acm_certificate_validation) | resource |
| [aws_cloudwatch_log_group.eks](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_log_group.waf](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_log_resource_policy.waf](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_resource_policy) | resource |
| [aws_db_instance.postgresql](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_instance) | resource |
| [aws_db_subnet_group.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_subnet_group) | resource |
| [aws_ec2_transit_gateway_vpc_attachment.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ec2_transit_gateway_vpc_attachment) | resource |
| [aws_ecr_lifecycle_policy.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_lifecycle_policy) | resource |
| [aws_ecr_repository.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_repository) | resource |
| [aws_eip.nat](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eip) | resource |
| [aws_eks_access_entry.admin](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_access_entry) | resource |
| [aws_eks_access_entry.karpenter_nodes](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_access_entry) | resource |
| [aws_eks_access_policy_association.admin](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_access_policy_association) | resource |
| [aws_eks_addon.coredns](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_addon) | resource |
| [aws_eks_addon.ebs_csi_driver](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_addon) | resource |
| [aws_eks_addon.kube_proxy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_addon) | resource |
| [aws_eks_addon.metrics_server](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_addon) | resource |
| [aws_eks_addon.pod_identity_agent](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_addon) | resource |
| [aws_eks_addon.vpc_cni](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_addon) | resource |
| [aws_eks_cluster.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_cluster) | resource |
| [aws_eks_node_group.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_node_group) | resource |
| [aws_eks_pod_identity_association.karpenter_controller](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_eks_pod_identity_association.pod_identity](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_iam_instance_profile.karpenter_nodes](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_instance_profile) | resource |
| [aws_iam_openid_connect_provider.eks](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_openid_connect_provider) | resource |
| [aws_iam_policy.aws_lb_controller](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.cluster_autoscaler](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.irsa](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.karpenter_controller](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.logging](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.pod_identity](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.storage](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.teleport_db_agent_rds](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.aws_lb_controller](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.cluster_autoscaler](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.ebs_csi_driver](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.eks_cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.eks_nodes](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.irsa](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.karpenter_controller](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.karpenter_nodes](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.logging](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.pod_identity](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.rds_monitoring](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.storage](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.teleport_db_agent](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.aws_lb_controller](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.cluster_autoscaler](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.ebs_csi_driver](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.eks_cluster_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.eks_cni_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.eks_container_registry_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.eks_ssm_managed_instance_core](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.eks_vpc_resource_controller](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.eks_worker_node_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.irsa](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.karpenter_controller](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.karpenter_nodes](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.logging](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.pod_identity](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.rds_monitoring](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.storage](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.teleport_db_agent_rds](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_internet_gateway.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/internet_gateway) | resource |
| [aws_kms_alias.ecr](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_alias.eks](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_alias.rds](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_alias.s3_logging](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_alias.s3_storage](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.ecr](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_kms_key.eks](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_kms_key.rds](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_kms_key.s3_logging](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_kms_key.s3_storage](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_nat_gateway.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/nat_gateway) | resource |
| [aws_rds_cluster.aurora](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/rds_cluster) | resource |
| [aws_rds_cluster_instance.aurora](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/rds_cluster_instance) | resource |
| [aws_route.private_to_tgw](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route) | resource |
| [aws_route53_record.acm_validation](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |
| [aws_route_table.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table) | resource |
| [aws_route_table.public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table) | resource |
| [aws_route_table_association.database](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table_association) | resource |
| [aws_route_table_association.lb](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table_association) | resource |
| [aws_route_table_association.node](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table_association) | resource |
| [aws_route_table_association.pod](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table_association) | resource |
| [aws_route_table_association.public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table_association) | resource |
| [aws_s3_bucket.logging](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket.storage](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_cors_configuration.storage](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_cors_configuration) | resource |
| [aws_s3_bucket_lifecycle_configuration.logging](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_lifecycle_configuration.storage](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_public_access_block.logging](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_public_access_block.storage](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.logging](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.storage](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.logging](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_s3_bucket_versioning.storage](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_security_group.eks_cluster_additional](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_security_group.eks_nodes](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_security_group.rds](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_security_group.vpc_endpoints](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_security_group_rule.cluster_to_nodes](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group_rule) | resource |
| [aws_security_group_rule.kubelet_from_pod_sg](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group_rule) | resource |
| [aws_security_group_rule.nodes_egress](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group_rule) | resource |
| [aws_security_group_rule.nodes_from_tgw](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group_rule) | resource |
| [aws_security_group_rule.nodes_internal](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group_rule) | resource |
| [aws_security_group_rule.nodes_to_cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group_rule) | resource |
| [aws_security_group_rule.private_network_access](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group_rule) | resource |
| [aws_security_group_rule.rds_egress](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group_rule) | resource |
| [aws_security_group_rule.rds_from_eks_nodes](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group_rule) | resource |
| [aws_security_group_rule.rds_from_pods](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group_rule) | resource |
| [aws_security_group_rule.rds_from_tgw](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group_rule) | resource |
| [aws_security_group_rule.rds_from_vpc](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group_rule) | resource |
| [aws_subnet.database](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet) | resource |
| [aws_subnet.lb](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet) | resource |
| [aws_subnet.node](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet) | resource |
| [aws_subnet.pod](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet) | resource |
| [aws_subnet.public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet) | resource |
| [aws_vpc.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc) | resource |
| [aws_vpc_endpoint.ec2](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_endpoint) | resource |
| [aws_vpc_endpoint.ecr_api](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_endpoint) | resource |
| [aws_vpc_endpoint.ecr_dkr](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_endpoint) | resource |
| [aws_vpc_endpoint.s3](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_endpoint) | resource |
| [aws_vpc_endpoint.sts](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_endpoint) | resource |
| [aws_vpc_ipv4_cidr_block_association.pods](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_ipv4_cidr_block_association) | resource |
| [aws_wafv2_ip_set.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/wafv2_ip_set) | resource |
| [aws_wafv2_ip_set.scope_down](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/wafv2_ip_set) | resource |
| [aws_wafv2_web_acl.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/wafv2_web_acl) | resource |
| [aws_wafv2_web_acl_association.direct](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/wafv2_web_acl_association) | resource |
| [aws_wafv2_web_acl_logging_configuration.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/wafv2_web_acl_logging_configuration) | resource |
| [helm_release.aws_load_balancer_controller](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.cluster_autoscaler](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.teleport_kube_agent](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [kubectl_manifest.eniconfig](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubernetes_cluster_role.teleport_admin](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/cluster_role) | resource |
| [kubernetes_cluster_role.teleport_viewer](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/cluster_role) | resource |
| [kubernetes_cluster_role_binding.teleport_admin](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/cluster_role_binding) | resource |
| [kubernetes_cluster_role_binding.teleport_viewer](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/cluster_role_binding) | resource |
| [kubernetes_cluster_role_binding.tfc_agent](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/cluster_role_binding) | resource |
| [kubernetes_config_map.rds_iam_setup](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/config_map) | resource |
| [kubernetes_config_map_v1_data.aws_auth](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/config_map_v1_data) | resource |
| [kubernetes_deployment.tfc_agent](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/deployment) | resource |
| [kubernetes_job_v1.rds_iam_bootstrap](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/job_v1) | resource |
| [kubernetes_namespace.tfc_agent](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace) | resource |
| [kubernetes_secret.rds_bootstrap_creds](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret) | resource |
| [kubernetes_secret.tfc_agent_token](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret) | resource |
| [kubernetes_service_account.tfc_agent](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_account) | resource |
| [random_password.rds](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [terraform_data.karpenter_access_mode_guard](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [terraform_data.network_mode_guard](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [terraform_data.rds_iam_setup_hash](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [terraform_data.teleport_validation](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [terraform_data.tfc_agent_validation](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [aws_acm_certificate.existing](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/acm_certificate) | data source |
| [aws_availability_zones.available](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/availability_zones) | data source |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_ecr_repository.existing](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ecr_repository) | data source |
| [aws_eks_addon_version.coredns](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/eks_addon_version) | data source |
| [aws_eks_addon_version.ebs_csi_driver](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/eks_addon_version) | data source |
| [aws_eks_addon_version.kube_proxy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/eks_addon_version) | data source |
| [aws_eks_addon_version.metrics_server](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/eks_addon_version) | data source |
| [aws_eks_addon_version.pod_identity_agent](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/eks_addon_version) | data source |
| [aws_eks_addon_version.vpc_cni](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/eks_addon_version) | data source |
| [aws_eks_cluster_auth.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/eks_cluster_auth) | data source |
| [aws_iam_policy_document.aws_lb_controller_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.cluster_autoscaler](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.cluster_autoscaler_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.ebs_csi_driver_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.logging](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.logging_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.storage](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.storage_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.teleport_db_agent_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.teleport_db_agent_rds](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.waf_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_route53_zone.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/route53_zone) | data source |
| [aws_subnet.node](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/subnet) | data source |
| [aws_subnet.pod](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/subnet) | data source |
| [aws_vpc.shared](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/vpc) | data source |
| [http_http.aws_lb_controller_policy](https://registry.terraform.io/providers/hashicorp/http/latest/docs/data-sources/http) | data source |
| [local_file.sa_ca_cert](https://registry.terraform.io/providers/hashicorp/local/latest/docs/data-sources/file) | data source |
| [local_sensitive_file.sa_token](https://registry.terraform.io/providers/hashicorp/local/latest/docs/data-sources/sensitive_file) | data source |
| [tls_certificate.eks](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/data-sources/certificate) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_access_mode"></a> [access\_mode](#input\_access\_mode) | K8s API access mode (teleport or vpn) | `string` | `"teleport"` | no |
| <a name="input_acm_certificate_arn"></a> [acm\_certificate\_arn](#input\_acm\_certificate\_arn) | ARN of existing ACM certificate (only used if acm\_create = false) | `string` | `null` | no |
| <a name="input_acm_create"></a> [acm\_create](#input\_acm\_create) | Create new ACM certificate (false to use existing or skip) | `bool` | `false` | no |
| <a name="input_acm_domain_name"></a> [acm\_domain\_name](#input\_acm\_domain\_name) | Domain name for the certificate. Use '*.example.com' for wildcard certificates or 'example.com' for non-wildcard certificates. | `string` | `null` | no |
| <a name="input_acm_route53_zone_id"></a> [acm\_route53\_zone\_id](#input\_acm\_route53\_zone\_id) | Route53 hosted zone ID for DNS validation (required for automatic DNS validation) | `string` | `null` | no |
| <a name="input_acm_subject_alternative_names"></a> [acm\_subject\_alternative\_names](#input\_acm\_subject\_alternative\_names) | Additional domain names for the certificate (e.g., ['*.example.com', 'www.example.com']) | `list(string)` | `[]` | no |
| <a name="input_acm_validation_method"></a> [acm\_validation\_method](#input\_acm\_validation\_method) | Certificate validation method (DNS or EMAIL) | `string` | `"DNS"` | no |
| <a name="input_api_server_authorized_cidrs"></a> [api\_server\_authorized\_cidrs](#input\_api\_server\_authorized\_cidrs) | Authorized CIDR blocks for API server access (only applies when private\_cluster\_enabled = false, empty = open) | `list(string)` | `[]` | no |
| <a name="input_aurora_engine_version"></a> [aurora\_engine\_version](#input\_aurora\_engine\_version) | Aurora PostgreSQL engine version, aligned to the PostgreSQL 17 major (matching var.rds\_engine\_version). Aurora and RDS never share an exact minor, so this tracks the major; confirm the exact minor available in your Region with `aws rds describe-db-engine-versions --engine aurora-postgresql`. | `string` | `"17.9"` | no |
| <a name="input_aurora_instance_class"></a> [aurora\_instance\_class](#input\_aurora\_instance\_class) | Instance class for Aurora provisioned (engine = "aurora") cluster instances. Ignored for aurora-serverless (forced to db.serverless). | `string` | `"db.t4g.medium"` | no |
| <a name="input_aurora_serverless_max_capacity"></a> [aurora\_serverless\_max\_capacity](#input\_aurora\_serverless\_max\_capacity) | Aurora Serverless v2 maximum capacity in ACUs. | `number` | `4` | no |
| <a name="input_aurora_serverless_min_capacity"></a> [aurora\_serverless\_min\_capacity](#input\_aurora\_serverless\_min\_capacity) | Aurora Serverless v2 minimum capacity in ACUs (0.5 increments). 0 allows scale-to-zero pause on supported versions. | `number` | `0.5` | no |
| <a name="input_aws_lb_controller_version"></a> [aws\_lb\_controller\_version](#input\_aws\_lb\_controller\_version) | AWS Load Balancer Controller Helm chart version | `string` | `"1.16.0"` | no |
| <a name="input_cluster_admin_arns"></a> [cluster\_admin\_arns](#input\_cluster\_admin\_arns) | List of IAM user/role ARNs to grant cluster admin access (system:masters). Empty list = no additional admins. Supports AWS SSO roles. | `list(string)` | `[]` | no |
| <a name="input_cluster_authentication_mode"></a> [cluster\_authentication\_mode](#input\_cluster\_authentication\_mode) | How IAM principals are granted access to the cluster.<br/><br/>- CONFIG\_MAP      aws-auth ConfigMap only (default; what every existing<br/>                  cluster uses).<br/>- API             EKS access entries only. aws-auth is ignored by the<br/>                  cluster — do not pick this for a cluster whose nodes<br/>                  currently map through aws-auth.<br/>- API\_AND\_CONFIG\_MAP  Both. The migration path: entries take effect while<br/>                  aws-auth keeps working, so a cluster can move over<br/>                  without a window where nodes cannot join.<br/><br/>AWS does not allow narrowing this (API\_AND\_CONFIG\_MAP -> CONFIG\_MAP, or<br/>API -> anything). Widening is in-place and safe. | `string` | `"CONFIG_MAP"` | no |
| <a name="input_cluster_autoscaler_version"></a> [cluster\_autoscaler\_version](#input\_cluster\_autoscaler\_version) | Cluster Autoscaler Helm chart version | `string` | `"9.58.0"` | no |
| <a name="input_cluster_public_subnets_enabled"></a> [cluster\_public\_subnets\_enabled](#input\_cluster\_public\_subnets\_enabled) | Also place EKS control-plane ENIs in the public subnets (legacy layout). Default false = node subnets only. Only consulted when create\_vpc = true and the public tier exists. | `bool` | `false` | no |
| <a name="input_cni_prefix_delegation_enabled"></a> [cni\_prefix\_delegation\_enabled](#input\_cni\_prefix\_delegation\_enabled) | Enable VPC CNI prefix delegation (ENABLE\_PREFIX\_DELEGATION) to raise pod density per node. Defaults true; requires Nitro instance types. Set false only for non-Nitro nodes. Interacts with pod\_isolation\_enabled: when isolation is on (the default) pods draw from the /23 pod subnets where /28 prefix allocation is comfortable, but when pod\_isolation\_enabled = false pods return to the node subnets — and prefix delegation carves /28 blocks that a default /27 node subnet cannot hold (WARM\_PREFIX\_TARGET = 1 pre-warms a prefix per ENI and exhausts the subnet, stalling the CNI). For that combination either set this false or widen node subnets to /25 or larger (the module enforces this — see aws/byo-network.tf). | `bool` | `true` | no |
| <a name="input_create_vpc"></a> [create\_vpc](#input\_create\_vpc) | Create the VPC and all network resources (true), or consume an externally-owned/shared VPC by ID and create no network resources (false). When false, supply vpc\_id and the *\_subnet\_ids vars; the *\_subnet\_cidrs and egress/NAT/IGW/TGW settings are unused. | `bool` | `true` | no |
| <a name="input_database_subnet_cidrs"></a> [database\_subnet\_cidrs](#input\_database\_subnet\_cidrs) | CIDR blocks for database subnets (one per AZ). Only RDS/Aurora instance ENIs live here (~1 IP per instance per AZ); a /28 (11 usable after AWS's 5 reserved) comfortably covers a handful of databases. RDS Proxy is heavier: it reserves >=2 IPs per AZ per proxy endpoint and consumes more as its connection pool scales under load/failover, so two proxy endpoints already claim ~4 of a /28's 11 usable IPs. Use /26 or larger if you run RDS Proxy against multiple databases or many instances per AZ. | `list(string)` | <pre>[<br/>  "10.0.0.192/28",<br/>  "10.0.0.208/28",<br/>  "10.0.0.224/28"<br/>]</pre> | no |
| <a name="input_database_subnet_ids"></a> [database\_subnet\_ids](#input\_database\_subnet\_ids) | Existing database subnet IDs (one per AZ) to consume when create\_vpc = false and rds\_enabled = true. Ignored when create\_vpc = true. | `list(string)` | `[]` | no |
| <a name="input_databases"></a> [databases](#input\_databases) | Map of named RDS PostgreSQL instances to provision. Each key becomes part of<br/>the cloud-side identifier. The "core" key is reserved for the legacy primary<br/>database and its on-cloud identifier is preserved (no -core suffix); every<br/>other key produces a suffixed instance (${base}-${each.key}).<br/><br/>Engine selection (per database):<br/>  - engine = "rds"               → standalone RDS PostgreSQL instance (default)<br/>  - engine = "aurora"            → Aurora PostgreSQL provisioned cluster<br/>  - engine = "aurora-serverless" → Aurora PostgreSQL Serverless v2 cluster<br/><br/>The "core" key defaults to "rds" so existing deployments are untouched.<br/>NOTE: switching an existing key between engine families (e.g. rds →<br/>aurora) is a DESTROY + RECREATE of the database — Terraform cannot morph<br/>an aws\_db\_instance into an aws\_rds\_cluster, and the data move is a<br/>separate snapshot-restore / DMS operation. Only switch engines on a<br/>database with no data you need to keep. See aws/README.md.<br/><br/>Per-entry overrides (all optional — fall back to top-level defaults when<br/>omitted):<br/>  - engine                    (string)  — "rds" \| "aurora" \| "aurora-serverless"<br/>  - engine\_version            (string)  — PostgreSQL engine version<br/>                                          (rds → var.rds\_engine\_version,<br/>                                           aurora* → var.aurora\_engine\_version)<br/>  - instance\_class            (string)  — instance class. RDS → var.rds\_instance\_class;<br/>                                          aurora → var.aurora\_instance\_class;<br/>                                          aurora-serverless forces "db.serverless".<br/>  - instance\_count            (number)  — Aurora cluster instances (writer + readers);<br/>                                          default 1. Ignored for engine = "rds".<br/>  - serverless\_min\_capacity   (number)  — Aurora Serverless v2 min ACUs<br/>                                          (default var.aurora\_serverless\_min\_capacity)<br/>  - serverless\_max\_capacity   (number)  — Aurora Serverless v2 max ACUs<br/>                                          (default var.aurora\_serverless\_max\_capacity)<br/>  - allocated\_storage         (number)  — Allocated storage in GB (RDS only; Aurora storage is managed)<br/>  - max\_allocated\_storage     (number)  — Storage autoscaling cap in GB (RDS only)<br/>  - multi\_az                  (bool)    — Multi-AZ deployment (RDS only; Aurora HA = instance\_count > 1)<br/>  - backup\_retention\_period   (number)  — Backup retention in days<br/>  - deletion\_protection       (bool)    — Enable deletion protection<br/>  - skip\_final\_snapshot       (bool)    — Skip final snapshot on destroy<br/>  - admin\_username            (string)  — Master username<br/>  - db\_name                   (string)  — Initial database name | <pre>map(object({<br/>    engine                  = optional(string, "rds")<br/>    engine_version          = optional(string)<br/>    instance_class          = optional(string)<br/>    instance_count          = optional(number)<br/>    serverless_min_capacity = optional(number)<br/>    serverless_max_capacity = optional(number)<br/>    allocated_storage       = optional(number)<br/>    max_allocated_storage   = optional(number)<br/>    multi_az                = optional(bool)<br/>    backup_retention_period = optional(number)<br/>    deletion_protection     = optional(bool)<br/>    skip_final_snapshot     = optional(bool)<br/>    admin_username          = optional(string)<br/>    db_name                 = optional(string)<br/>  }))</pre> | <pre>{<br/>  "core": {}<br/>}</pre> | no |
| <a name="input_dedicated_node_sg_enabled"></a> [dedicated\_node\_sg\_enabled](#input\_dedicated\_node\_sg\_enabled) | Manage a dedicated node security group (aws\_security\_group.eks\_nodes) and attach it to pod ENIs (custom networking) and TGW node ingress. True (default) is the deployed behavior. When false, the SG and its rules are dropped and pod ENIs plus TGW ingress use the EKS-managed cluster security group that every node already carries. WARNING: flipping this from true to false on a cluster with pod\_isolation\_enabled = true requires a node recycle. The ENIConfig change only governs new pod ENIs, so already-running pods keep the old SG and would block its deletion (a DependencyViolation) until the nodes are recycled. See the module README migration note. | `bool` | `true` | no |
| <a name="input_ecr_encryption_type"></a> [ecr\_encryption\_type](#input\_ecr\_encryption\_type) | Encryption type (AES256 or KMS) | `string` | `"AES256"` | no |
| <a name="input_ecr_image_tag_mutability"></a> [ecr\_image\_tag\_mutability](#input\_ecr\_image\_tag\_mutability) | Image tag mutability (MUTABLE or IMMUTABLE) | `string` | `"IMMUTABLE"` | no |
| <a name="input_ecr_lifecycle_policy"></a> [ecr\_lifecycle\_policy](#input\_ecr\_lifecycle\_policy) | Lifecycle policy configuration | <pre>object({<br/>    keep_prod_images   = number<br/>    keep_latest_images = number<br/>    expire_untagged    = number<br/>  })</pre> | <pre>{<br/>  "expire_untagged": 3,<br/>  "keep_latest_images": 3,<br/>  "keep_prod_images": 5<br/>}</pre> | no |
| <a name="input_ecr_repository_name"></a> [ecr\_repository\_name](#input\_ecr\_repository\_name) | Name of existing ECR repository (only used if registry\_enabled = false) | `string` | `null` | no |
| <a name="input_ecr_scan_on_push"></a> [ecr\_scan\_on\_push](#input\_ecr\_scan\_on\_push) | Enable image scanning on push | `bool` | `true` | no |
| <a name="input_egress_mode"></a> [egress\_mode](#input\_egress\_mode) | How node/private subnets reach the internet. "nat" routes 0.0.0.0/0 through module-owned NAT gateways (the default). "transit\_gateway" routes the default route to var.transit\_gateway\_id (no NAT created — egress hairpins through the customer network). "none" installs no default route (air-gapped; reach AWS APIs via VPC endpoints). | `string` | `"nat"` | no |
| <a name="input_eks_addon_versions"></a> [eks\_addon\_versions](#input\_eks\_addon\_versions) | Optional per-add-on version pins (map of add-on key -> version). Unset keys use the most-recent version for the cluster's Kubernetes version. | `map(string)` | `{}` | no |
| <a name="input_enable_cluster_encryption"></a> [enable\_cluster\_encryption](#input\_enable\_cluster\_encryption) | Enable EKS secrets encryption with KMS | `bool` | `true` | no |
| <a name="input_enable_nat_gateway"></a> [enable\_nat\_gateway](#input\_enable\_nat\_gateway) | Enable NAT Gateway for private subnets (only honored when egress\_mode = "nat") | `bool` | `true` | no |
| <a name="input_enable_vpc_endpoints"></a> [enable\_vpc\_endpoints](#input\_enable\_vpc\_endpoints) | Enable VPC endpoints for S3, ECR, EC2 | `bool` | `true` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | Environment name (dev, stg, uat, prod) | `string` | n/a | yes |
| <a name="input_expose_database_to_transit_gateway"></a> [expose\_database\_to\_transit\_gateway](#input\_expose\_database\_to\_transit\_gateway) | Allow the transit\_gateway\_cidr\_blocks to reach RDS/Aurora directly over the Transit Gateway (opens the database security groups on 5432). Default false: application traffic to the database stays in-VPC, and human/admin database access goes through Teleport rather than the corp network, so the database tier is not advertised to the TGW. Set true only when an external network genuinely needs a direct database path. | `bool` | `false` | no |
| <a name="input_ignore_tag_keys"></a> [ignore\_tag\_keys](#input\_ignore\_tag\_keys) | Tag keys owned outside Terraform, ignored on every resource this module<br/>manages. default\_tags makes Terraform the owner of each resource's whole<br/>tag map, so a key written by something else (AWS stamps aws-apn-id onto<br/>RDS instances for partner attribution) shows up as a deletion in every<br/>plan. Listing it here leaves it alone: never added, never removed.<br/>Empty (the default) ignores nothing. | `list(string)` | `[]` | no |
| <a name="input_igw_enabled"></a> [igw\_enabled](#input\_igw\_enabled) | Create the internet gateway and the public subnet tier (public subnets, their route table, and associations). Only consulted when create\_vpc = true. Set false for a fully private module-owned VPC with no internet gateway; requires egress\_mode != "nat" since NAT needs a public subnet + IGW. | `bool` | `true` | no |
| <a name="input_install_aws_lb_controller"></a> [install\_aws\_lb\_controller](#input\_install\_aws\_lb\_controller) | Install AWS Load Balancer Controller via Helm | `bool` | `true` | no |
| <a name="input_install_cluster_autoscaler"></a> [install\_cluster\_autoscaler](#input\_install\_cluster\_autoscaler) | Install Cluster Autoscaler via Helm | `bool` | `true` | no |
| <a name="input_irsa_roles"></a> [irsa\_roles](#input\_irsa\_roles) | Map of service names to IRSA (IAM Roles for Service Accounts)<br/>configurations. Each entry creates:<br/>- An IAM role with a federated trust policy referencing the<br/>  cluster's OIDC provider, using `StringLike` on the `:sub` claim<br/>  so wildcards in `namespace_pattern` are honored<br/>- An IAM policy with the entry's policy\_statements<br/><br/>The K8s ServiceAccount(s) that match the namespace\_pattern must<br/>be created separately (typically via your manifests / GitOps)<br/>with the annotation `eks.amazonaws.com/role-arn = <role_arn>`<br/>(the role ARN is exposed in the `irsa` output). Once that's in<br/>place, adding a new matching namespace does NOT require a<br/>terraform apply — the wildcard already covers it.<br/><br/>`namespace_pattern` supports IAM `StringLike` glob syntax: `*`<br/>matches any sequence of characters, `?` matches a single<br/>character. Example values: "core" (exact match), "tenant-*",<br/>"*-prod".<br/><br/>Independent of pod\_identity\_roles — both may be populated on the<br/>same cluster. | <pre>map(object({<br/>    namespace_pattern = string<br/>    service_account   = string<br/>    policy_statements = list(object({<br/>      sid       = string<br/>      actions   = list(string)<br/>      resources = list(string)<br/>    }))<br/>  }))</pre> | `{}` | no |
| <a name="input_karpenter_enabled"></a> [karpenter\_enabled](#input\_karpenter\_enabled) | Create the IAM prerequisites for Karpenter: a controller role bound by Pod<br/>Identity to the karpenter/karpenter ServiceAccount, and a node role +<br/>instance profile for the EC2 instances Karpenter launches.<br/><br/>This creates IAM and the node access entry ONLY. The controller, NodePools<br/>and EC2NodeClasses are deployed from the gitops repo, which references the<br/>`karpenter_node_instance_profile` output as EC2NodeClass<br/>`spec.instanceProfile`.<br/><br/>Requires cluster\_authentication\_mode = "API" or "API\_AND\_CONFIG\_MAP":<br/>the Karpenter node role joins via an access entry. | `bool` | `false` | no |
| <a name="input_karpenter_node_role_additional_policies"></a> [karpenter\_node\_role\_additional\_policies](#input\_karpenter\_node\_role\_additional\_policies) | Extra managed-policy ARNs to attach to the Karpenter node role, on top of<br/>the four an EKS worker always needs (WorkerNode, CNI, ECR read, SSM core). | `list(string)` | `[]` | no |
| <a name="input_kubernetes_version"></a> [kubernetes\_version](#input\_kubernetes\_version) | Kubernetes version | `string` | `"1.35"` | no |
| <a name="input_lb_subnet_cidrs"></a> [lb\_subnet\_cidrs](#input\_lb\_subnet\_cidrs) | CIDR blocks for internal load balancer subnets (one per AZ). Internal ALBs/NLBs live in their own small subnets so nodes never compete with load balancers for address space. /28 each holds plenty of internal LB ENIs. Ignored when lb\_subnet\_enabled = false. | `list(string)` | <pre>[<br/>  "10.0.0.96/28",<br/>  "10.0.0.112/28",<br/>  "10.0.0.128/28"<br/>]</pre> | no |
| <a name="input_lb_subnet_enabled"></a> [lb\_subnet\_enabled](#input\_lb\_subnet\_enabled) | Create a dedicated internal load-balancer subnet tier. When false, internal LBs are placed in the node subnets instead — in create mode no lb subnets are created and the node subnets receive the kubernetes.io/role/internal-elb tag; in consumer mode lb\_subnet\_ids resolves to the node subnets and its precondition is relaxed (the caller tags their own node subnets). | `bool` | `true` | no |
| <a name="input_lb_subnet_ids"></a> [lb\_subnet\_ids](#input\_lb\_subnet\_ids) | Existing internal load balancer subnet IDs (one per AZ) to consume when create\_vpc = false. Ignored when create\_vpc = true. | `list(string)` | `[]` | no |
| <a name="input_node_groups"></a> [node\_groups](#input\_node\_groups) | Configuration for EKS managed node groups | <pre>map(object({<br/>    instance_types  = list(string)<br/>    min_size        = number<br/>    max_size        = number<br/>    desired_size    = number<br/>    disk_size       = number<br/>    ami_type        = optional(string)<br/>    release_version = optional(string)<br/>    labels          = map(string)<br/>    taints = list(object({<br/>      key    = string<br/>      value  = string<br/>      effect = string<br/>    }))<br/>  }))</pre> | <pre>{<br/>  "application": {<br/>    "desired_size": 2,<br/>    "disk_size": 100,<br/>    "instance_types": [<br/>      "t3a.medium"<br/>    ],<br/>    "labels": {<br/>      "workload-type": "application"<br/>    },<br/>    "max_size": 6,<br/>    "min_size": 2,<br/>    "taints": []<br/>  },<br/>  "support": {<br/>    "desired_size": 1,<br/>    "disk_size": 50,<br/>    "instance_types": [<br/>      "t3a.medium"<br/>    ],<br/>    "labels": {<br/>      "workload-type": "support"<br/>    },<br/>    "max_size": 4,<br/>    "min_size": 1,<br/>    "taints": []<br/>  },<br/>  "system": {<br/>    "desired_size": 2,<br/>    "disk_size": 50,<br/>    "instance_types": [<br/>      "t3a.medium"<br/>    ],<br/>    "labels": {<br/>      "workload-type": "system"<br/>    },<br/>    "max_size": 4,<br/>    "min_size": 2,<br/>    "taints": [<br/>      {<br/>        "effect": "NO_SCHEDULE",<br/>        "key": "CriticalAddonsOnly",<br/>        "value": "true"<br/>      }<br/>    ]<br/>  }<br/>}</pre> | no |
| <a name="input_node_subnet_cidrs"></a> [node\_subnet\_cidrs](#input\_node\_subnet\_cidrs) | CIDR blocks for node subnets (one per AZ). EKS worker-node ENIs live here (roughly one primary IP per node), alongside the four interface VPC endpoint ENIs (ECR API, ECR DKR, EC2, STS — one each per AZ), the EKS control-plane cross-account ENIs (~2 per AZ), and secondary IPs for pods only when pod isolation is disabled. A /27 has 27 usable IPs (32 minus AWS's 5 reserved); after the ~6 endpoint + control-plane ENIs that leaves ~21 for actual worker nodes — comfortable for the default node groups with pod isolation on. Widen to /26 or larger if you run many nodes per AZ or disable pod isolation (pods then also draw from this tier). | `list(string)` | <pre>[<br/>  "10.0.0.0/27",<br/>  "10.0.0.32/27",<br/>  "10.0.0.64/27"<br/>]</pre> | no |
| <a name="input_node_subnet_ids"></a> [node\_subnet\_ids](#input\_node\_subnet\_ids) | Existing node subnet IDs (one per AZ) to consume when create\_vpc = false. Ignored when create\_vpc = true. | `list(string)` | `[]` | no |
| <a name="input_pod_identity_roles"></a> [pod\_identity\_roles](#input\_pod\_identity\_roles) | Map of service names to Pod Identity configurations. Each entry<br/>creates an EKS Pod Identity Association linking the ServiceAccount<br/>to an IAM role. Provide EITHER:<br/>- policy\_statements → this module creates the IAM role (with the<br/>  pods.eks.amazonaws.com trust) and an IAM policy from the<br/>  statements, or<br/>- role\_arn → bind to a pre-existing, externally-managed IAM role<br/>  (its trust + permissions are managed outside this module; the<br/>  module creates only the association).<br/><br/>Pod Identity bindings require an exact match on (namespace,<br/>service\_account) — wildcards are not supported by the AWS API.<br/>For wildcard namespace matching, use irsa\_roles instead.<br/><br/>Independent of irsa\_roles — both may be populated on the same<br/>cluster. A non-empty map also installs the Pod Identity Agent addon. | <pre>map(object({<br/>    namespace       = string<br/>    service_account = string<br/>    role_arn        = optional(string)<br/>    policy_statements = optional(list(object({<br/>      sid       = string<br/>      actions   = list(string)<br/>      resources = list(string)<br/>    })), [])<br/>  }))</pre> | `{}` | no |
| <a name="input_pod_isolation_enabled"></a> [pod\_isolation\_enabled](#input\_pod\_isolation\_enabled) | Run pods on a non-routed secondary CIDR via VPC CNI custom networking, keeping pod IPs out of the routable address space. When false, pods draw IPs from the node subnets and no secondary CIDR, pod subnets, or ENIConfigs are created. | `bool` | `true` | no |
| <a name="input_pod_secondary_cidr"></a> [pod\_secondary\_cidr](#input\_pod\_secondary\_cidr) | Secondary CIDR (carved from the RFC 6598 100.64.0.0/10 shared-address space) associated with the VPC for pod IPs when this module owns the pod subnets. Must not overlap var.vpc\_cidr. Ignored when pod\_isolation\_enabled = false or when bringing your own pod subnets. | `string` | `"100.64.0.0/21"` | no |
| <a name="input_pod_subnet_cidrs"></a> [pod\_subnet\_cidrs](#input\_pod\_subnet\_cidrs) | CIDR blocks for pod subnets (one per AZ), carved from var.pod\_secondary\_cidr. A /23 per AZ yields 512 pod IPs per AZ. Used only when the module owns the pod subnets (pod\_isolation\_enabled = true and pod\_subnet\_ids is empty). | `list(string)` | <pre>[<br/>  "100.64.0.0/23",<br/>  "100.64.2.0/23",<br/>  "100.64.4.0/23"<br/>]</pre> | no |
| <a name="input_pod_subnet_ids"></a> [pod\_subnet\_ids](#input\_pod\_subnet\_ids) | Bring-your-own pod subnet IDs (one per AZ) for VPC CNI custom networking. When set, the module does not create the secondary CIDR or pod subnets and instead points ENIConfigs at these existing subnets. Leave empty to have the module own the pod subnets. Routing caveat: the module only associates route tables with pod subnets it creates. When these are supplied with create\_vpc = true, the module does NOT associate them with its private route tables — the caller must ensure each supplied pod subnet has a default route (to the module's NAT gateway or the Transit Gateway) or pods lose egress to ECR, STS, and off-VPC destinations. In consumer mode (create\_vpc = false) routing is the owner account's responsibility. | `list(string)` | `[]` | no |
| <a name="input_private_cluster_enabled"></a> [private\_cluster\_enabled](#input\_private\_cluster\_enabled) | Enable fully private cluster API (no public endpoint). The private<br/>endpoint is reachable from inside the VPC (the node security group is<br/>allowed by default); grant additional in-VPC or DX/VPN sources with<br/>private\_network\_access\_cidrs. Terraform must then drive the API from a<br/>source with a path to the private endpoint — an in-VPC bastion / CI<br/>runner, or the in-cluster TFC agent (tfc\_agent\_enabled). This is no<br/>longer coupled to tfc\_agent\_enabled: any in-VPC runner works. | `bool` | `false` | no |
| <a name="input_private_network_access_cidrs"></a> [private\_network\_access\_cidrs](#input\_private\_network\_access\_cidrs) | CIDR blocks permitted to reach the private EKS API endpoint on 443.<br/>Only applies when private\_cluster\_enabled = true; ignored otherwise<br/>(public access is governed by api\_server\_authorized\_cidrs). Empty<br/>(the default) creates no rule, so the private endpoint is reachable<br/>only from the node security group. Populate with the CIDR(s) of an<br/>in-VPC bastion / CI runner or a corp network reaching the endpoint<br/>over DX/VPN so Terraform (and operators) can drive the API without<br/>attaching the node security group to the runner. | `list(string)` | `[]` | no |
| <a name="input_project_name"></a> [project\_name](#input\_project\_name) | Project name used in resource naming | `string` | `"optura"` | no |
| <a name="input_public_subnet_cidrs"></a> [public\_subnet\_cidrs](#input\_public\_subnet\_cidrs) | CIDR blocks for public subnets (one per AZ). Host internet-facing load balancers and NAT gateways only; /28 each is ample. | `list(string)` | <pre>[<br/>  "10.0.0.144/28",<br/>  "10.0.0.160/28",<br/>  "10.0.0.176/28"<br/>]</pre> | no |
| <a name="input_rds_admin_username"></a> [rds\_admin\_username](#input\_rds\_admin\_username) | RDS master username | `string` | `"psqladmin"` | no |
| <a name="input_rds_allocated_storage"></a> [rds\_allocated\_storage](#input\_rds\_allocated\_storage) | Allocated storage in GB | `number` | `20` | no |
| <a name="input_rds_backup_retention_period"></a> [rds\_backup\_retention\_period](#input\_rds\_backup\_retention\_period) | Backup retention period in days | `number` | `7` | no |
| <a name="input_rds_database_name"></a> [rds\_database\_name](#input\_rds\_database\_name) | Initial database name | `string` | `"optura"` | no |
| <a name="input_rds_deletion_protection"></a> [rds\_deletion\_protection](#input\_rds\_deletion\_protection) | Enable deletion protection | `bool` | `false` | no |
| <a name="input_rds_enabled"></a> [rds\_enabled](#input\_rds\_enabled) | Deploy RDS PostgreSQL | `bool` | `true` | no |
| <a name="input_rds_engine_version"></a> [rds\_engine\_version](#input\_rds\_engine\_version) | PostgreSQL engine version | `string` | `"17.10"` | no |
| <a name="input_rds_instance_class"></a> [rds\_instance\_class](#input\_rds\_instance\_class) | RDS instance class | `string` | `"db.t4g.micro"` | no |
| <a name="input_rds_max_allocated_storage"></a> [rds\_max\_allocated\_storage](#input\_rds\_max\_allocated\_storage) | Maximum storage for autoscaling in GB | `number` | `100` | no |
| <a name="input_rds_multi_az"></a> [rds\_multi\_az](#input\_rds\_multi\_az) | Enable Multi-AZ deployment | `bool` | `false` | no |
| <a name="input_rds_skip_final_snapshot"></a> [rds\_skip\_final\_snapshot](#input\_rds\_skip\_final\_snapshot) | Skip final snapshot on deletion (set false for prod) | `bool` | `true` | no |
| <a name="input_region"></a> [region](#input\_region) | AWS region for all resources | `string` | `"us-east-1"` | no |
| <a name="input_registry_enabled"></a> [registry\_enabled](#input\_registry\_enabled) | Create new ECR repository (false to use existing) | `bool` | `false` | no |
| <a name="input_single_nat_gateway"></a> [single\_nat\_gateway](#input\_single\_nat\_gateway) | Use single NAT Gateway (cost savings for dev) | `bool` | `false` | no |
| <a name="input_sso_instance_region"></a> [sso\_instance\_region](#input\_sso\_instance\_region) | Region segment of the IAM path on AWS SSO roles in cluster\_admin\_arns, used to rebuild the ARN EKS access entries require. Empty (the default) is correct for an IAM Identity Center hosted in us-east-1, which AWS omits the region segment for. Set it to the Identity Center's region otherwise; this need not match var.region. | `string` | `""` | no |
| <a name="input_storage_general_bucket_name"></a> [storage\_general\_bucket\_name](#input\_storage\_general\_bucket\_name) | Override bucket name for general storage (default: {project}-{environment}-storage) | `string` | `null` | no |
| <a name="input_storage_general_cors_origins"></a> [storage\_general\_cors\_origins](#input\_storage\_general\_cors\_origins) | Browser origins allowed to call the general storage bucket directly (presigned uploads). Empty disables CORS, which blocks every browser upload. | `list(string)` | `[]` | no |
| <a name="input_storage_general_enabled"></a> [storage\_general\_enabled](#input\_storage\_general\_enabled) | Create general purpose storage | `bool` | `true` | no |
| <a name="input_storage_general_encryption_type"></a> [storage\_general\_encryption\_type](#input\_storage\_general\_encryption\_type) | Encryption type for storage (AES256 or aws:kms) | `string` | `"AES256"` | no |
| <a name="input_storage_general_lifecycle"></a> [storage\_general\_lifecycle](#input\_storage\_general\_lifecycle) | Lifecycle policy for storage | <pre>object({<br/>    transition_to_ia_days              = number<br/>    noncurrent_version_expiration_days = number<br/>  })</pre> | <pre>{<br/>  "noncurrent_version_expiration_days": 30,<br/>  "transition_to_ia_days": 90<br/>}</pre> | no |
| <a name="input_storage_general_lifecycle_enabled"></a> [storage\_general\_lifecycle\_enabled](#input\_storage\_general\_lifecycle\_enabled) | Enable lifecycle policies on storage | `bool` | `true` | no |
| <a name="input_storage_general_namespace"></a> [storage\_general\_namespace](#input\_storage\_general\_namespace) | Kubernetes namespace for storage service account | `string` | `"default"` | no |
| <a name="input_storage_general_service_account"></a> [storage\_general\_service\_account](#input\_storage\_general\_service\_account) | Kubernetes service account name for storage access | `string` | `"app-storage"` | no |
| <a name="input_storage_general_versioning"></a> [storage\_general\_versioning](#input\_storage\_general\_versioning) | Enable versioning on storage | `bool` | `true` | no |
| <a name="input_storage_logging_bucket_name"></a> [storage\_logging\_bucket\_name](#input\_storage\_logging\_bucket\_name) | Override bucket name for logging storage (default: {project}-{environment}-logging) | `string` | `null` | no |
| <a name="input_storage_logging_enabled"></a> [storage\_logging\_enabled](#input\_storage\_logging\_enabled) | Create storage for centralized log storage | `bool` | `false` | no |
| <a name="input_storage_logging_lifecycle"></a> [storage\_logging\_lifecycle](#input\_storage\_logging\_lifecycle) | Lifecycle policy for logging storage | <pre>object({<br/>    transition_to_ia_days      = number<br/>    transition_to_glacier_days = number<br/>    expiration_days            = number<br/>  })</pre> | <pre>{<br/>  "expiration_days": 365,<br/>  "transition_to_glacier_days": 90,<br/>  "transition_to_ia_days": 30<br/>}</pre> | no |
| <a name="input_storage_logging_namespace"></a> [storage\_logging\_namespace](#input\_storage\_logging\_namespace) | Kubernetes namespace for logging service account | `string` | `"monitoring"` | no |
| <a name="input_storage_logging_service_account"></a> [storage\_logging\_service\_account](#input\_storage\_logging\_service\_account) | Kubernetes service account name for logging access | `string` | `"loki"` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Common tags applied to all resources | `map(string)` | `{}` | no |
| <a name="input_teleport_agent_chart_repository"></a> [teleport\_agent\_chart\_repository](#input\_teleport\_agent\_chart\_repository) | Helm repository for the teleport-kube-agent chart (e.g. https://charts.releases.teleport.dev or oci://your-registry/charts). Required when access\_mode = teleport — supply your own. | `string` | `""` | no |
| <a name="input_teleport_agent_image"></a> [teleport\_agent\_image](#input\_teleport\_agent\_image) | Container image reference for the Teleport agent (e.g. your-registry/teleport-distroless). Leave empty to use the chart's default image; set to pull from your own registry (required for egress-restricted clusters). | `string` | `""` | no |
| <a name="input_teleport_ca_pin"></a> [teleport\_ca\_pin](#input\_teleport\_ca\_pin) | Teleport CA pin (optional, recommended for prod) | `string` | `null` | no |
| <a name="input_teleport_db_enabled"></a> [teleport\_db\_enabled](#input\_teleport\_db\_enabled) | Enable Teleport database service for RDS | `bool` | `true` | no |
| <a name="input_teleport_gateway_ip"></a> [teleport\_gateway\_ip](#input\_teleport\_gateway\_ip) | Static IP of the egress gateway proxy. When set, hostAliases route the Teleport proxy hostname through this IP so all agent traffic exits via a single static IP. Defaults to null (disabled) — supply your deployment's egress IP. | `string` | `null` | no |
| <a name="input_teleport_join_token"></a> [teleport\_join\_token](#input\_teleport\_join\_token) | Teleport agent join token (used for all services: kube, app, db, discovery) | `string` | `null` | no |
| <a name="input_teleport_proxy_address"></a> [teleport\_proxy\_address](#input\_teleport\_proxy\_address) | Teleport proxy address as host:port (required when access\_mode = teleport). Defaults to empty — supply your own Teleport proxy. | `string` | `""` | no |
| <a name="input_teleport_version"></a> [teleport\_version](#input\_teleport\_version) | Teleport version | `string` | `"18.5.1"` | no |
| <a name="input_tfc_agent_enabled"></a> [tfc\_agent\_enabled](#input\_tfc\_agent\_enabled) | Deploy Terraform Cloud Agent for private cluster access | `bool` | `false` | no |
| <a name="input_tfc_agent_token"></a> [tfc\_agent\_token](#input\_tfc\_agent\_token) | Terraform Cloud Agent token (sensitive, set via TF\_VAR\_tfc\_agent\_token) | `string` | `null` | no |
| <a name="input_tfc_agent_version"></a> [tfc\_agent\_version](#input\_tfc\_agent\_version) | TFC Agent container image tag | `string` | `"1.28.5"` | no |
| <a name="input_transit_gateway_cidr_blocks"></a> [transit\_gateway\_cidr\_blocks](#input\_transit\_gateway\_cidr\_blocks) | CIDR blocks reachable via the Transit Gateway (other VPCs, on-prem networks). Routes and security-group ingress rules are created per CIDR. | `list(string)` | `[]` | no |
| <a name="input_transit_gateway_default_route_table_association"></a> [transit\_gateway\_default\_route\_table\_association](#input\_transit\_gateway\_default\_route\_table\_association) | Associate the VPC attachment with the TGW's default route table. Set false to manage associations separately (e.g. segregated route tables in a hub-and-spoke topology). | `bool` | `true` | no |
| <a name="input_transit_gateway_default_route_table_propagation"></a> [transit\_gateway\_default\_route\_table\_propagation](#input\_transit\_gateway\_default\_route\_table\_propagation) | Propagate routes to the TGW's default route table. Set false to manage propagation separately. | `bool` | `true` | no |
| <a name="input_transit_gateway_id"></a> [transit\_gateway\_id](#input\_transit\_gateway\_id) | ID of an existing Transit Gateway to attach the VPC to (null = no TGW attachment) | `string` | `null` | no |
| <a name="input_transit_gateway_node_ingress"></a> [transit\_gateway\_node\_ingress](#input\_transit\_gateway\_node\_ingress) | Port ranges to allow from each transit\_gateway\_cidr\_blocks entry to the EKS nodes. Empty list (default) allows all traffic (protocol "-1"); set explicit ranges to restrict cross-VPC node access (e.g. NodePorts, kubelet). | <pre>list(object({<br/>    from_port = number<br/>    to_port   = number<br/>    protocol  = optional(string, "tcp")<br/>  }))</pre> | `[]` | no |
| <a name="input_transit_gateway_subnet_ids"></a> [transit\_gateway\_subnet\_ids](#input\_transit\_gateway\_subnet\_ids) | Subnet IDs for the TGW attachment ENIs (null = use the private subnets). One per AZ is recommended for HA. | `list(string)` | `null` | no |
| <a name="input_vpc_cidr"></a> [vpc\_cidr](#input\_vpc\_cidr) | Primary (routable) CIDR block for the VPC. Pods do not draw from this range when pod isolation is enabled — they live in var.pod\_secondary\_cidr — so the routable tier only needs room for node ENIs, load balancers, database ENIs, and VPC endpoints. A /24 holds the default layout (node /27 + lb/public/database /28 per AZ) with a spare /28; widen only if you disable pod isolation (pods then re-enter the node subnets) or run many nodes/AZ. | `string` | `"10.0.0.0/24"` | no |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | ID of an existing (typically RAM-shared) VPC to consume when create\_vpc = false. Ignored when create\_vpc = true. | `string` | `null` | no |
| <a name="input_vpn_gateway_ips"></a> [vpn\_gateway\_ips](#input\_vpn\_gateway\_ips) | VPN gateway IPs (legacy, for vpn mode) | `list(string)` | `[]` | no |
| <a name="input_waf_web_acls"></a> [waf\_web\_acls](#input\_waf\_web\_acls) | AWS WAFv2 Web ACLs, keyed by an arbitrary name (typically an env).<br/>Empty by default (opt-in). One entry = one Web ACL; its ARN is returned under<br/>the same key in waf\_web\_acl\_arns. Attach it to a controller-managed ALB in<br/>gitops via the alb.ingress.kubernetes.io/wafv2-acl-arn annotation; use<br/>associate\_resource\_arns only for ALBs provisioned outside the controller.<br/>Set scope = "CLOUDFRONT" for an edge ACL attached to a CloudFront<br/>distribution's web\_acl\_id — those require the module to run in us-east-1.<br/>Rule names and priorities must each be unique across all rule kinds in an ACL.<br/>Set `name` to override the derived Web ACL name (default `<project>-<environment>-<key>`)<br/>when the ACL is not env-specific (e.g. one ACL shared across environments).<br/>See the README WAF feature section for full field docs and examples. | <pre>map(object({<br/>    name           = optional(string)<br/>    default_action = optional(string, "allow")<br/>    scope          = optional(string, "REGIONAL")<br/><br/>    rate_based_rules = optional(list(object({<br/>      name                      = string<br/>      priority                  = number<br/>      limit                     = number<br/>      evaluation_window_seconds = optional(number, 300)<br/>      action                    = optional(string, "block")<br/>      path_prefix               = optional(string)<br/>      aggregate_key_type        = optional(string, "IP")<br/>      forwarded_ip_header       = optional(string, "X-Forwarded-For")<br/>      forwarded_ip_fallback     = optional(string, "MATCH")<br/>    })), [])<br/><br/>    managed_rule_groups = optional(list(object({<br/>      name              = string<br/>      priority          = number<br/>      vendor_name       = optional(string, "AWS")<br/>      version           = optional(string)<br/>      override_to_count = optional(bool, false)<br/>      rule_action_overrides = optional(list(object({<br/>        name          = string<br/>        action_to_use = string<br/>      })), [])<br/><br/>      # Narrow WHICH requests this group inspects. The group is evaluated for<br/>      # everything EXCEPT requests matching every condition set here — so this<br/>      # exempts known-good traffic from one group without letting it skip the<br/>      # rest of the ACL, which is what a standalone allow rule would do.<br/>      #<br/>      # exempt_when_headers maps header name => exact value. Every condition<br/>      # set — the IP list and each header — must match for a request to be<br/>      # exempt, so more conditions means a narrower exemption. At least one is<br/>      # required. Comparison is case-insensitive on both name and value.<br/>      #<br/>      # Headers are supplied by the client, so they are NOT a trust boundary on<br/>      # their own — anyone can send them. They are for narrowing an exemption<br/>      # to a specific host, route or caller; pair them with exempt_when_ips<br/>      # whenever the exemption itself needs to be trustworthy.<br/>      scope_down = optional(object({<br/>        exempt_when_ips     = optional(list(string))<br/>        exempt_when_headers = optional(map(string))<br/>      }))<br/>    })), [])<br/><br/>    ip_rules = optional(list(object({<br/>      name       = string<br/>      priority   = number<br/>      addresses  = list(string)<br/>      action     = optional(string, "block")<br/>      ip_version = optional(string, "IPV4")<br/>    })), [])<br/><br/>    geo_rules = optional(list(object({<br/>      name          = string<br/>      priority      = number<br/>      country_codes = list(string)<br/>      action        = optional(string, "block")<br/>      negate        = optional(bool, false)<br/>    })), [])<br/><br/>    associate_resource_arns = optional(list(string), [])<br/><br/>    logging = optional(object({<br/>      enabled               = optional(bool, false)<br/>      destination_arn       = optional(string)<br/>      retention_days        = optional(number, 365)<br/>      kms_key_arn           = optional(string)<br/>      redacted_header_names = optional(list(string), ["authorization", "cookie"])<br/>      only_blocked          = optional(bool, false)<br/>    }), {})<br/>  }))</pre> | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_access_mode"></a> [access\_mode](#output\_access\_mode) | Current K8s API access mode |
| <a name="output_acm_certificate_arn"></a> [acm\_certificate\_arn](#output\_acm\_certificate\_arn) | ARN of the ACM certificate (created or existing, null if not configured) |
| <a name="output_acm_certificate_domain"></a> [acm\_certificate\_domain](#output\_acm\_certificate\_domain) | Domain name of the ACM certificate (as specified in acm\_domain\_name) |
| <a name="output_acm_certificate_status"></a> [acm\_certificate\_status](#output\_acm\_certificate\_status) | Status of the created ACM certificate (if created) |
| <a name="output_acm_created"></a> [acm\_created](#output\_acm\_created) | Whether a new ACM certificate was created |
| <a name="output_api_endpoint_access_type"></a> [api\_endpoint\_access\_type](#output\_api\_endpoint\_access\_type) | Type of access to the K8s API endpoint |
| <a name="output_cluster_access_mode"></a> [cluster\_access\_mode](#output\_cluster\_access\_mode) | Current cluster API access configuration |
| <a name="output_cluster_admin_count"></a> [cluster\_admin\_count](#output\_cluster\_admin\_count) | Number of additional cluster admins configured |
| <a name="output_cluster_admin_principals"></a> [cluster\_admin\_principals](#output\_cluster\_admin\_principals) | List of IAM principals granted cluster admin access |
| <a name="output_cluster_authentication_mode"></a> [cluster\_authentication\_mode](#output\_cluster\_authentication\_mode) | The cluster's effective EKS authentication mode. |
| <a name="output_cluster_certificate_authority_data"></a> [cluster\_certificate\_authority\_data](#output\_cluster\_certificate\_authority\_data) | Base64 encoded certificate data for cluster |
| <a name="output_cluster_endpoint"></a> [cluster\_endpoint](#output\_cluster\_endpoint) | Endpoint for Kubernetes cluster API server |
| <a name="output_cluster_id"></a> [cluster\_id](#output\_cluster\_id) | Name of the Kubernetes cluster (EKS uses name as ID) |
| <a name="output_cluster_name"></a> [cluster\_name](#output\_cluster\_name) | Name of the Kubernetes cluster |
| <a name="output_cluster_oidc_issuer_url"></a> [cluster\_oidc\_issuer\_url](#output\_cluster\_oidc\_issuer\_url) | OIDC issuer URL for the cluster |
| <a name="output_cluster_security_group_id"></a> [cluster\_security\_group\_id](#output\_cluster\_security\_group\_id) | Security group ID attached to the cluster |
| <a name="output_cluster_subnet_ids"></a> [cluster\_subnet\_ids](#output\_cluster\_subnet\_ids) | IDs of node subnets (where EKS worker nodes run). Legacy alias for node\_subnet\_ids. |
| <a name="output_database_address"></a> [database\_address](#output\_database\_address) | Address of the "core" database server (without port, legacy alias) |
| <a name="output_database_admin_password"></a> [database\_admin\_password](#output\_database\_admin\_password) | Administrator password for the "core" database (legacy alias) |
| <a name="output_database_admin_passwords"></a> [database\_admin\_passwords](#output\_database\_admin\_passwords) | Map of named DB key → administrator password |
| <a name="output_database_admin_username"></a> [database\_admin\_username](#output\_database\_admin\_username) | Administrator username for the "core" database (legacy alias) |
| <a name="output_database_admin_usernames"></a> [database\_admin\_usernames](#output\_database\_admin\_usernames) | Map of named DB key → administrator username |
| <a name="output_database_endpoint"></a> [database\_endpoint](#output\_database\_endpoint) | Endpoint (host:port) of the "core" database server (legacy alias) |
| <a name="output_database_endpoints"></a> [database\_endpoints](#output\_database\_endpoints) | Map of named DB key → endpoint (host:port). Aurora keys resolve to the cluster writer endpoint. |
| <a name="output_database_name"></a> [database\_name](#output\_database\_name) | Initial database name on the "core" server (legacy alias) |
| <a name="output_database_names"></a> [database\_names](#output\_database\_names) | Map of named DB key → initial database name |
| <a name="output_database_port"></a> [database\_port](#output\_database\_port) | Port of the "core" database server (legacy alias) |
| <a name="output_database_reader_endpoints"></a> [database\_reader\_endpoints](#output\_database\_reader\_endpoints) | Map of Aurora DB key → reader endpoint (host:port), matching database\_endpoints. Empty for engine = "rds" keys, which have no separate reader endpoint. |
| <a name="output_database_server_name"></a> [database\_server\_name](#output\_database\_server\_name) | Identifier of the "core" database server (legacy alias) |
| <a name="output_database_subnet_ids"></a> [database\_subnet\_ids](#output\_database\_subnet\_ids) | IDs of database subnets |
| <a name="output_eniconfig_manifests"></a> [eniconfig\_manifests](#output\_eniconfig\_manifests) | Map of AZ name → rendered ENIConfig YAML applied to drive VPC CNI custom networking (one per AZ). Empty map when pod isolation is disabled. |
| <a name="output_estimated_monthly_cost"></a> [estimated\_monthly\_cost](#output\_estimated\_monthly\_cost) | Estimated monthly cost breakdown |
| <a name="output_general_storage_id"></a> [general\_storage\_id](#output\_general\_storage\_id) | ID/ARN of the general storage |
| <a name="output_general_storage_name"></a> [general\_storage\_name](#output\_general\_storage\_name) | Name of the general storage |
| <a name="output_general_storage_region"></a> [general\_storage\_region](#output\_general\_storage\_region) | Region of the general storage |
| <a name="output_general_storage_role_id"></a> [general\_storage\_role\_id](#output\_general\_storage\_role\_id) | IAM role ARN for storage workload (IRSA) |
| <a name="output_ingress_subnet_ids"></a> [ingress\_subnet\_ids](#output\_ingress\_subnet\_ids) | IDs of public subnets for internet-facing load balancers. Empty in consumer mode (create\_vpc = false): a shared/RAM-shared VPC is private-by-design here — ingress arrives via the corporate network/Transit Gateway and internal LBs, and any public edge is the owner account's concern. There is intentionally no public\_subnet\_ids consumer input. |
| <a name="output_irsa"></a> [irsa](#output\_irsa) | IRSA configuration per service — role ARNs and the trust-policy<br/>pattern (one entry per irsa\_roles key). Annotate K8s<br/>ServiceAccount(s) with `eks.amazonaws.com/role-arn = <role_arn>`<br/>to use; the trust policy uses StringLike on `:sub` so wildcards<br/>in namespace\_pattern work without terraform apply. |
| <a name="output_karpenter_controller_role_arn"></a> [karpenter\_controller\_role\_arn](#output\_karpenter\_controller\_role\_arn) | Karpenter controller role ARN (bound to karpenter/karpenter by Pod Identity). |
| <a name="output_karpenter_node_instance_profile"></a> [karpenter\_node\_instance\_profile](#output\_karpenter\_node\_instance\_profile) | Karpenter node instance profile — EC2NodeClass `spec.instanceProfile`. |
| <a name="output_karpenter_node_role_arn"></a> [karpenter\_node\_role\_arn](#output\_karpenter\_node\_role\_arn) | Karpenter node role ARN. |
| <a name="output_karpenter_node_role_name"></a> [karpenter\_node\_role\_name](#output\_karpenter\_node\_role\_name) | Karpenter node role name. |
| <a name="output_kubectl_config_command"></a> [kubectl\_config\_command](#output\_kubectl\_config\_command) | Command to configure kubectl |
| <a name="output_lb_subnet_ids"></a> [lb\_subnet\_ids](#output\_lb\_subnet\_ids) | IDs of internal load balancer subnets |
| <a name="output_logging_storage_id"></a> [logging\_storage\_id](#output\_logging\_storage\_id) | ID/ARN of the logging storage |
| <a name="output_logging_storage_name"></a> [logging\_storage\_name](#output\_logging\_storage\_name) | Name of the logging storage |
| <a name="output_logging_storage_region"></a> [logging\_storage\_region](#output\_logging\_storage\_region) | Region of the logging storage |
| <a name="output_logging_storage_role_id"></a> [logging\_storage\_role\_id](#output\_logging\_storage\_role\_id) | IAM role ARN for logging workload (IRSA) |
| <a name="output_network_cidr"></a> [network\_cidr](#output\_network\_cidr) | CIDR block of the virtual network |
| <a name="output_network_id"></a> [network\_id](#output\_network\_id) | ID of the virtual network |
| <a name="output_network_name"></a> [network\_name](#output\_network\_name) | Name of the virtual network (the module's Name tag in create mode; the consumed VPC's Name tag in consumer mode) |
| <a name="output_node_group_role_arn"></a> [node\_group\_role\_arn](#output\_node\_group\_role\_arn) | ARN of the EKS node group IAM role |
| <a name="output_node_subnet_ids"></a> [node\_subnet\_ids](#output\_node\_subnet\_ids) | IDs of node subnets (where EKS worker nodes run) |
| <a name="output_oidc_provider_arn"></a> [oidc\_provider\_arn](#output\_oidc\_provider\_arn) | ARN of the OIDC provider for IRSA |
| <a name="output_pod_identity"></a> [pod\_identity](#output\_pod\_identity) | Pod Identity configuration per service — role ARNs and associations (one entry per pod\_identity\_roles key). policy\_arn is null for entries that bind an externally-managed role via role\_arn. |
| <a name="output_pod_secondary_cidr_association_id"></a> [pod\_secondary\_cidr\_association\_id](#output\_pod\_secondary\_cidr\_association\_id) | ID of the VPC IPv4 CIDR association for the pod secondary CIDR. Non-null only when this module owns the pod subnets (create\_vpc = true, pod isolation on, no BYO pod subnets); null when isolation is off or the association is owned externally (shared/BYO VPC). |
| <a name="output_pod_subnet_ids"></a> [pod\_subnet\_ids](#output\_pod\_subnet\_ids) | IDs of the subnets pods draw IPs from via VPC CNI custom networking (empty when pod isolation is disabled) |
| <a name="output_registry_base_url"></a> [registry\_base\_url](#output\_registry\_base\_url) | Base registry URL for the AWS account |
| <a name="output_registry_created"></a> [registry\_created](#output\_registry\_created) | Whether a new container registry was created |
| <a name="output_registry_id"></a> [registry\_id](#output\_registry\_id) | ARN of the container registry (created or existing, null if not configured) |
| <a name="output_registry_name"></a> [registry\_name](#output\_registry\_name) | Name of the container registry (created or existing, null if not configured) |
| <a name="output_registry_url"></a> [registry\_url](#output\_registry\_url) | URL of the container registry (created or existing, null if not configured) |
| <a name="output_teleport_db_agent_role_arn"></a> [teleport\_db\_agent\_role\_arn](#output\_teleport\_db\_agent\_role\_arn) | IAM role ARN for Teleport database agent |
| <a name="output_tfc_agent_status"></a> [tfc\_agent\_status](#output\_tfc\_agent\_status) | Terraform Cloud Agent deployment status |
| <a name="output_transit_gateway_attachment_id"></a> [transit\_gateway\_attachment\_id](#output\_transit\_gateway\_attachment\_id) | Transit Gateway VPC attachment ID (null unless this module owns the attachment) |
| <a name="output_transit_gateway_id"></a> [transit\_gateway\_id](#output\_transit\_gateway\_id) | Transit Gateway ID the VPC is attached to (null if not attached) |
| <a name="output_waf_web_acl_arns"></a> [waf\_web\_acl\_arns](#output\_waf\_web\_acl\_arns) | Map of waf\_web\_acls key => Web ACL ARN. Feed each ARN to gitops as the alb.ingress.kubernetes.io/wafv2-acl-arn annotation on that env's intent Ingress. Empty map when no ACLs are defined. |
| <a name="output_waf_web_acl_capacities"></a> [waf\_web\_acl\_capacities](#output\_waf\_web\_acl\_capacities) | Map of waf\_web\_acls key => WCU (Web ACL Capacity Units) consumed by that ACL's rules. Watch this against the 1500 WCU default ceiling as managed rule groups are added. Empty map when no ACLs are defined. |
| <a name="output_waf_web_acl_ids"></a> [waf\_web\_acl\_ids](#output\_waf\_web\_acl\_ids) | Map of waf\_web\_acls key => Web ACL ID. Empty map when no ACLs are defined. |
| <a name="output_waf_web_acl_names"></a> [waf\_web\_acl\_names](#output\_waf\_web\_acl\_names) | Map of waf\_web\_acls key => Web ACL name. Empty map when no ACLs are defined. |
<!-- END_TF_DOCS -->