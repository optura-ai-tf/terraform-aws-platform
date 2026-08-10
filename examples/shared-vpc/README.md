# Example: bring-your-own / RAM-shared VPC (`create_vpc = false`)

For deployments where another account owns the network — for example a customer
landing zone that shares a VPC into your account via AWS RAM. This module then
consumes the supplied subnet IDs and creates **no network resources of its own**:
it builds only the EKS cluster, node groups, security groups, addons, RDS, and
the pod ENIConfigs. The owner account is responsible for the VPC, subnets,
routing, egress, the Transit Gateway / Direct Connect path, the `100.64` pod
secondary CIDR, subnet tags, and the S3 gateway endpoint.

```bash
cd examples/shared-vpc
terraform init
export TF_VAR_teleport_join_token="..."   # never commit this
terraform apply
```

> Every `vpc-…` / `subnet-…` ID in `main.tf` is a placeholder. Replace them with
> the real IDs the owner account shared to you before applying.

## OWNER-ACCOUNT CHECKLIST

The account that owns the shared VPC must have the following in place **before**
this module can apply. The module reads these resources; it does not create or
manage them.

- [ ] **Create the VPC and subnets.** One node subnet, one internal-LB subnet,
  and one database subnet **per AZ** (three AZs), plus one pod subnet per AZ.
  Share them into the consuming account via AWS RAM.
- [ ] **Associate the `100.64` pod secondary CIDR and pod subnets.** Attach a
  non-routed `100.64.0.0/x` (RFC 6598) secondary CIDR to the VPC and carve the
  per-AZ pod subnets from it. Pods draw their IPs from these — the module only
  points ENIConfigs at the supplied `pod_subnet_ids`.
- [ ] **Route only the node + LB tiers to the TGW / Direct Connect.** Advertise
  the routable node and internal-LB subnets to the corp network. Do **not** route
  the pod (`100.64`) or database subnets off-VPC — they stay hidden.
- [ ] **Apply the required subnet tags** so EKS and the AWS Load Balancer
  Controller can discover them:
  - On **every** subnet the cluster uses:
    `kubernetes.io/cluster/<cluster-name> = shared`
    (the cluster name is `eks-<project_name>-<environment>`, e.g.
    `eks-optura-prod`).
  - On the **internal LB** subnets, additionally:
    `kubernetes.io/role/internal-elb = 1`.
- [ ] **Create the VPC endpoints the cluster needs** — the module provisions
  none in consumer mode. At minimum the **S3 gateway** endpoint (image layer
  pulls) plus the **ECR API**, **ECR DKR**, **EC2**, and **STS** interface
  endpoints (image pulls, the VPC CNI / EC2 registration, and IRSA via STS),
  unless the owner's egress path already reaches those AWS APIs another way.
  These are exactly the endpoints the module creates for itself in `create_vpc`
  mode (see `aws/vpc-endpoints.tf`).
- [ ] **Manage NAT / egress.** The owner controls the default route (NAT, TGW
  hairpin, or no egress). The module installs no NAT, IGW, or default route when
  `create_vpc = false`.

## What this module still owns

Even in consumer mode the module manages the EKS cluster and everything on top of
the network: node groups, the node and RDS security groups (CIDR-scoped to the
consumed VPC's CIDR, read back automatically), all EKS addons including the VPC
CNI and the per-AZ ENIConfigs that point at your `pod_subnet_ids`, RDS/Aurora,
S3 workload buckets, and Teleport access.
