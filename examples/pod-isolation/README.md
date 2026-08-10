# Example: corp-connected pod isolation (module owns the VPC)

A fully-private EKS environment where **this module owns the VPC**. There is no
internet gateway and no public subnet tier — egress hairpins through the
customer's network over a Transit Gateway, and pods run on a non-routed `100.64`
secondary CIDR. This is the shape most enterprise landing zones mandate.

```bash
cd examples/pod-isolation
terraform init
export TF_VAR_teleport_join_token="..."   # never commit this
terraform apply
```

> `transit_gateway_id` in `main.tf` is a placeholder (`tgw-0123…`). Point it at a
> real Transit Gateway shared into your account before applying.

## Routable vs. hidden address space

The whole point of the layout is that the corp network only ever sees a small,
routable slice of the VPC — roughly a `/24` worth of node + load-balancer IPs.
Everything else stays inside the VPC and is never advertised over the TGW.

| Tier | CIDR(s) | Routable to corp / on-prem? | What lives here |
|---|---|---|---|
| Node subnets | `10.0.0.0/27` ×3 | **Yes** — advertised to the TGW | EKS worker-node ENIs |
| Internal LB subnets | `10.0.0.96/28` ×3 | **Yes** — advertised to the TGW | Internal ALBs / NLBs |
| Database subnets | `10.0.0.192/28` ×3 | **No** (hidden; opt-in via `expose_database_to_transit_gateway`) | RDS / Aurora ENIs |
| Pod subnets | `100.64.0.0/23` ×3 (from `100.64.0.0/21`) | **No** (non-routed secondary CIDR) | Pod ENIs via VPC CNI custom networking |

Pods and the database never consume routable address space, so the corp network
does not have to plan around pod churn or reserve a database range. The node,
internal-LB, and database tiers all fit inside a single routable `/24`.

## Sizing floor

The routable footprint is driven by the **node tier**: three `/27` node subnets
(plus the `/28` LB and `/28` database subnets) fit inside a single `/24` with a
`/28` to spare. With pod isolation on (the default), a node subnet only holds the
node primary ENI plus the interface VPC-endpoint ENIs, so `/27` (≈27 usable) is
ample. The practical bounds:

- **`/27` per node subnet** (×3 AZs) is the default — comfortable for the default
  node groups. Widen to `/26` only for many nodes per AZ, or if you disable pod
  isolation (pods then consume node-subnet IPs).
- a **`/24` VPC** holds the whole routable layout (node `/27` + lb/database
  `/28`); `/28` is the AWS subnet floor, so don't shrink the LB/database tiers
  below it.

The non-routed pod space (`100.64.0.0/21` → three `/23` pod subnets, 512 IPs per
AZ) scales independently and does not eat into the routable floor.

## Why no internet gateway

`igw_enabled = false` produces a VPC with no internet gateway and no public
subnets. Because NAT gateways require a public subnet + IGW, `egress_mode` must
be `"transit_gateway"` (or `"none"`) here — the default route for the node/private
subnets points at the Transit Gateway, so all egress exits through the customer's
centralized firewall/proxy. AWS API traffic still works via the VPC endpoints the
module provisions.
