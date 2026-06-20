# VPC Endpoints (`vpc-endpoints.tf`)

## What this file does

This file solves a specific problem: ECS Fargate tasks run in **private subnets** with no route to the public internet (see `docs/vpc.md`), but they still need to reach a few AWS services — ECR (to pull the container image), S3 (where ECR actually stores image data), and CloudWatch Logs (to ship container logs). VPC Endpoints provide a private connection directly to these services over AWS's internal network, without ever touching the public internet and without needing a NAT Gateway.

### Security group for the endpoints

```hcl
resource "aws_security_group" "vpc_endpoints" {
  name        = "cloudship-vpc-endpoints-sg"
  description = "Allow HTTPS from ECS tasks to VPC endpoints"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port        = 443
    to_port          = 443
    protocol         = "tcp"
    security_groups  = [aws_security_group.ecs_tasks.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
```

Controls who can reach the endpoints themselves. Only traffic from the `ecs_tasks` security group (defined in `security-groups.tf`) is allowed in, on port 443 (HTTPS) — consistent with the least-privilege pattern used throughout this project: nothing reaches these endpoints except the specific tasks that need them.

### Interface endpoints: ECR API, ECR Docker registry, CloudWatch Logs

```hcl
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.ap-southeast-2.ecr.api"
  vpc_endpoint_type    = "Interface"
  subnet_ids           = module.vpc.private_subnets
  security_group_ids   = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled  = true
}
```

(Same shape repeats for `ecr_dkr` and `logs`, just with different `service_name` values.)

`vpc_endpoint_type = "Interface"` means AWS creates an actual network interface (ENI) inside the private subnets, giving the VPC a private IP address that resolves to that AWS service. Three Interface endpoints are needed here:

| Endpoint | Why it's needed |
|---|---|
| `ecr.api` | Handles ECR's authentication/control-plane calls — e.g. `GetAuthorizationToken`, the step that failed with a timeout before this file was added. |
| `ecr.dkr` | Handles the actual Docker-registry protocol calls — the part that streams the image layers down. |
| `logs` | Lets the container ship its stdout/stderr to CloudWatch Logs (configured in `ecs.tf`'s `logConfiguration`) — without this, log delivery would hit the same no-internet-route problem. |

`private_dns_enabled = true` is what makes this transparent to the application — it means the standard AWS service hostnames (e.g. `api.ecr.ap-southeast-2.amazonaws.com`) automatically resolve to these private endpoints instead of a public IP, so nothing in the task definition or application code needs to be reconfigured to use a special address.

### Gateway endpoint: S3

```hcl
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.ap-southeast-2.s3"
  vpc_endpoint_type  = "Gateway"
  route_table_ids    = module.vpc.private_route_table_ids
}
```

S3 uses a different endpoint type — `"Gateway"` rather than `"Interface"`. Instead of creating a network interface, it adds an entry directly into the private subnets' route tables (`module.vpc.private_route_table_ids`), routing S3-bound traffic privately. Gateway endpoints have no hourly charge, unlike Interface endpoints. This is needed because ECR doesn't store image layers itself — it stores them in S3 behind the scenes, so pulling an image involves an S3 read even though that's invisible from the ECR API itself.

---

## In plain English

Picture the private subnet from `vpc.tf`'s analogy — the **back-office floor with no door to the street**. The problem: the staff working there still need to receive a few specific deliveries (the app's image, log storage, vulnerability data) from outside suppliers, but the building has no street exit at all.

The fix isn't to cut a new street door (that would be a NAT Gateway, giving access to *anything* outside). Instead, this file installs a few **dedicated, direct delivery chutes** — one per supplier — that go straight from the back office to that one supplier's warehouse, completely bypassing the street.

- **The Interface endpoints (ECR API, ECR Docker, CloudWatch Logs)** are like installing **three separate pneumatic tubes**, each one running directly and only to one specific supplier's loading dock — one tube to "the ECR front desk" (checking you're allowed to pick up a package), one to "the ECR warehouse" (where the actual package is), and one to "the building's shared logbook service" (CloudWatch). Nothing else can use these tubes, and these tubes can't reach anywhere except their one destination.

- **`private_dns_enabled = true`** is what makes this invisible to the people using it — staff just call the supplier by their normal name, and the building automatically routes the call through the private tube instead of them needing to remember a different number for "the secret internal version" of that supplier.

- **The S3 Gateway endpoint** works a bit differently — instead of installing a tube, it's like adding a line to the building's internal mail-routing rules: *"anything addressed to the S3 warehouse, route it through the basement instead of the street."* Cheaper to set up than a tube (no hourly cost), but it only works for this one specific supplier (S3), and only because S3 happens to support being reached this way.

- **The endpoint security group** is the rule posted at each tube's entrance on the back-office side: *"only staff with an ECS Tasks badge are allowed to use these tubes — nobody else in the building gets access, even if they're also on the back-office floor."*

The end result: the back office still has zero connection to the public street, but it can still receive exactly the three things it actually needs, through dedicated, locked-down channels that go nowhere else.