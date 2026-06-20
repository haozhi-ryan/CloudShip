# Networking Foundation (`vpc.tf`)

## What this file does

This file provisions CloudShip's **Virtual Private Cloud (VPC)** — the isolated network that all other infrastructure (ECS tasks, the load balancer, VPC endpoints) lives inside. It uses the community-maintained `terraform-aws-modules/vpc/aws` module rather than raw resources, since VPC setup involves many interrelated pieces (subnets, route tables, an internet gateway, associations) that this module handles as a single, well-tested unit.

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.6.1"

  name = "cloudship-app-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["ap-southeast-2a", "ap-southeast-2b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}
```

| Argument | Purpose |
|---|---|
| `cidr = "10.0.0.0/16"` | The total address range for the VPC — roughly 65,000 IP addresses available to carve up among subnets. `/16` is generous headroom for a project this size. |
| `azs` | Spreads resources across **two Availability Zones** (`ap-southeast-2a` and `ap-southeast-2b`) — physically separate data centers within the same AWS region. If one AZ has an outage, resources in the other keep running. |
| `private_subnets` | Two subnets (`10.0.1.0/24`, `10.0.2.0/24`), one per AZ, with **no direct route to the internet**. This is where the ECS Fargate tasks run (see `ecs.tf`) — nothing here is reachable from outside the VPC unless explicitly routed. |
| `public_subnets` | Two subnets (`10.0.101.0/24`, `10.0.102.0/24`), one per AZ, **with** a route to the internet via an Internet Gateway (created automatically by the module). This is where the Application Load Balancer sits, since it needs to be internet-reachable. |

### What the module creates behind the scenes

Calling this one module block actually provisions around 17 underlying AWS resources, including: the VPC itself, all 4 subnets, an Internet Gateway, public and private route tables, route table associations (linking each subnet to its route table), and default VPC resources (default security group, default route table, default network ACL). All of this is visible in `terraform plan` output prefixed with `module.vpc.` — e.g. `module.vpc.aws_subnet.private[0]`.

### Why no NAT Gateway

Notably, this configuration does **not** include `enable_nat_gateway = true`. That means resources in the private subnets have no route to the public internet at all — by design. Instead, the private subnets reach essential AWS services (ECR, S3, CloudWatch Logs) via **VPC Endpoints**, defined separately in `vpc-endpoints.tf`. This keeps the private subnets fully isolated from the open internet, rather than giving them broad outbound access through a NAT Gateway. See `docs/vpc-endpoints.md` for the full reasoning.

### Outputs referenced elsewhere

Other files reference this VPC via the module's outputs, not direct resource names:

```hcl
module.vpc.vpc_id              # used by security groups, target group, VPC endpoints
module.vpc.public_subnets       # used by the ALB
module.vpc.private_subnets      # used by the ECS service
module.vpc.private_route_table_ids   # used by the S3 Gateway endpoint
```

---

## In plain English

Think of the VPC as **building a private office complex on an empty plot of land you own.**

- **The CIDR block (`10.0.0.0/16`)** is the boundary fence around the entire plot — it defines how much land you have to work with before you even start putting up buildings.

- **The two Availability Zones** are like building on **two separate city blocks instead of one**. If a water main bursts on one block, the other block keeps running completely normally — your office isn't a single point of failure.

- **The public subnets** are the **lobby and reception area** — the part of the complex with a street-facing door, where visitors from outside are allowed to walk in. This is where the load balancer (the receptionist, from `ecs.tf`'s analogy) sits.

- **The private subnets** are the **back-office floors** — no street access, no door to the outside world at all. Employees (your containers) work here, but a visitor off the street has no way to wander in directly. The only way anyone reaches them is by going through reception first.

- **No NAT Gateway** means the back-office floors don't even have a side exit to the street for *employees* to leave through, either — they're sealed off entirely. Normally, a business might install a staff-only back exit (a NAT Gateway) so employees can step out to run errands (reach the internet). Instead, this design installs a few specific **internal phone lines** directly to the suppliers they actually need (ECR, S3, CloudWatch — covered in `vpc-endpoints.md`), without ever opening a door to the public street at all.

- **The module itself** is like hiring a **specialist contractor** who knows how to build an entire office complex — foundation, wiring, floor plans, fire exits — from a single set of instructions, instead of you personally pouring every brick and running every cable yourself (which is what writing each piece as a raw, individual Terraform resource would mean).