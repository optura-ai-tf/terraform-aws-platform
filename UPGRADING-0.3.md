# Upgrading to 0.3.0

## There is NO in-place upgrade from 0.2.x to the 0.3.0 layout

0.3.0 renames and resizes the subnet tiers. The single `private_subnet_cidrs`
tier becomes an explicit `node_subnet_cidrs` / `lb_subnet_cidrs` split, the
routable VPC shrinks to a `/24`, the database tier becomes `/28`, and pods move
to a non-routed `100.64` secondary CIDR. Those are not edits Terraform can apply
in place — renaming a subnet variable and changing its CIDR is a **destroy and
recreate** of the underlying `aws_subnet`. Doing that under a live cluster would
tear down the subnets your nodes, load balancers, and database live in. **NO
in-place migration is supported, and you must not attempt one on a running
cluster.**

Pin existing clusters to the 0.2.x line until you are ready to migrate:

```hcl
version = "~> 0.2.2"
```

## Adopting 0.3.0 = a blue/green rebuild

Treat 0.3.0 as a new cluster, not an upgrade of the old one:

1. **Stand up a new environment on 0.3.0.** Use a new `vpc_cidr` (or a new
   account/region) so the new VPC does not collide with the old one. Apply the
   module at `0.3.0` to build the new VPC, subnets, EKS cluster, and node groups
   with the node/LB split and `100.64` pod isolation.
2. **Migrate workloads.** Redeploy your applications onto the new cluster
   (GitOps re-point, `kubectl apply`, Helm install). Move data: snapshot-restore
   the database, or replicate via DMS, into the new environment's RDS/Aurora.
3. **Cut over traffic.** Shift DNS / ingress / Teleport access to the new
   cluster once it is verified healthy.
4. **Decommission the old environment.** Once the new cluster carries production
   traffic and the old one is drained, `terraform destroy` the 0.2.x stack.

A blue/green rebuild is the only path that gets you the full 0.3.0 layout (the
node/LB tier split and the routable-vs-non-routed separation).

## The only in-place alternative (advanced): isolation-only, keep the 0.2.x layout

If a full rebuild is not feasible and you only want pods off the routable address
space, you can add pod isolation **to your existing 0.2.x VPC without renaming or
resizing its subnets**. This is an advanced, hand-managed path:

1. Stay on a module version that keeps your current subnet layout — do **not**
   adopt the 0.3.0 default subnet variables. Add a `100.64.0.0/x` secondary CIDR
   association and per-AZ pod subnets to the **existing** VPC, leaving the
   existing node/private and database subnets exactly as they are.
2. Bring those pod subnets in as `pod_subnet_ids` with `pod_isolation_enabled =
   true` so the module points ENIConfigs at them rather than creating new ones.
3. Roll the node groups so the VPC CNI picks up custom networking and new pods
   land on the `100.64` subnets. (Existing pods keep their old IPs until they are
   rescheduled.)

> **This alternative does NOT give you the node/LB subnet split.** Your load
> balancers and nodes continue to share the original 0.2.x subnet tier. You get
> pod-IP isolation only — not the rest of the 0.3.0 network layout. Use the
> blue/green rebuild above if you want the full 0.3.0 shape.

## Behavior change for existing Transit Gateway + RDS users

In 0.3.0, RDS is no longer reachable directly over the Transit Gateway by
default. The database security-group ingress for `transit_gateway_cidr_blocks`
is now gated behind `expose_database_to_transit_gateway` (default `false`). If
you rely on a direct database path from another network over the TGW, set:

```hcl
expose_database_to_transit_gateway = true
```

Otherwise application traffic to the database stays in-VPC and human/admin access
goes through Teleport.

## Operating with pod isolation: pods-per-node capacity

With `pod_isolation_enabled = true` (the 0.3.0 default), the VPC CNI runs in
custom-networking mode: the node's **primary** ENI no longer serves pods — pods
only get IPs from the secondary ENIs attached in the `100.64` subnets. This
**reduces** the IPs available per node versus a stock cluster, but the
EKS-optimized AMI's default `max-pods` is computed assuming the primary ENI is
usable. Left unchanged, the scheduler can place more pods on a node than there
are pod IPs, and the excess pods sit in `ContainerCreating` with no address.

The module handles this for you by default:

- **Prefix delegation is on by default** (`cni_prefix_delegation_enabled =
  true`). The CNI hands out `/28` prefixes instead of single IPs, which raises
  per-node pod capacity well past the default and absorbs the primary-ENI loss.
  Requires Nitro-based instance types (the default `t3a` family qualifies). If
  any custom `node_groups` use non-Nitro instance types, set
  `cni_prefix_delegation_enabled = false` and pin `max-pods` instead (below).
- **Or pin `max-pods` explicitly.** If you set
  `cni_prefix_delegation_enabled = false`, compute the correct value with the
  AWS `max-pods-calculator` for custom networking and set it via a launch
  template on your node groups, so the scheduler never over-commits a node's
  pod IPs.

This applies to new 0.3.0 clusters as well as migrated ones, and to both
module-owned and BYO/shared-VPC deployments.

## Verify ENIConfigs applied before trusting isolation

The per-AZ `ENIConfig` CRDs that pin pods to the `100.64` subnets are applied
through the community `gavinbunney/kubectl` provider. If they fail to apply
(auth timing on a first `apply`, or a provider/Kubernetes API incompatibility),
nodes still launch and pods silently fall back to node-subnet IPs — there is no
Terraform error. After the first apply, confirm isolation is actually active:

```sh
kubectl get eniconfig                      # one per AZ, matching your node AZs
kubectl get pods -A -o wide | grep -v 100\\.64   # workload pods should be empty
```

If a workload pod shows a node-subnet IP, the ENIConfig for that AZ did not
apply — re-run `terraform apply` (or re-apply the ENIConfig) and recycle the
affected nodes.
