# Security Groups (`security-groups.tf`)

## What this file does

This file defines two **security groups** — virtual firewalls that control what network traffic is allowed in and out of specific AWS resources. Together they implement a layered access pattern: the internet can only reach the load balancer, and only the load balancer can reach the running container.

### ALB security group

```hcl
resource "aws_security_group" "alb" {
  name        = "cloudship-alb-sg"
  description = "Allow inbound HTTP from the internet"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
```

This is attached to the Application Load Balancer (defined in `ecs.tf`). The `ingress` rule allows inbound traffic from `0.0.0.0/0` — meaning any IP address — but only on port 80 (HTTP). This is intentional: the ALB is the one piece of infrastructure that's *supposed* to be publicly reachable, since it's what the live URL points to. The `egress` rule allows the ALB to send traffic anywhere, which it needs in order to forward requests onward to the ECS tasks.

### ECS tasks security group

```hcl
resource "aws_security_group" "ecs_tasks" {
  name        = "cloudship-ecs-tasks-sg"
  description = "Allow inbound only from the ALB"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "From ALB only"
    from_port        = 3000
    to_port          = 3000
    protocol         = "tcp"
    security_groups  = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
```

This is attached to the ECS Fargate tasks (also wired up in `ecs.tf`). The key difference from the ALB's security group: instead of `cidr_blocks = ["0.0.0.0/0"]`, the `ingress` rule uses `security_groups = [aws_security_group.alb.id]`. This is a **security-group-to-security-group reference** rather than an IP range — it means "only allow traffic that's coming from something carrying the ALB security group," regardless of what IP address that traffic happens to have. This is what makes the container completely unreachable from the open internet, even though it does have inbound rules at all — the only thing on the "allow" list is the ALB itself, nothing else qualifies.

The `egress` rule is intentionally broad (anywhere, any protocol) because the task needs outbound access for several legitimate reasons: pulling the image from ECR (via the endpoints in `vpc-endpoints.tf`), writing logs to CloudWatch, and potentially calling external APIs in future phases.

### Why two separate security groups, not one

This is the same least-privilege pattern used throughout the project (see also the two separate IAM roles in `iam.tf` vs. `ecs.tf`). A single shared security group would mean either over-permissioning the task (letting the public internet reach it directly) or under-permissioning the ALB (blocking it from receiving public traffic at all). Splitting them lets each resource have exactly the access it needs and nothing more.

---

## In plain English

Picture the receptionist and the back-office kitchen staff from `ecs.tf`'s analogy, and think of these two security groups as **the rules posted at each one's door.**

- **The ALB's security group** is the sign on the **front door of the building**: *"anyone off the street is welcome to walk in, but only through this one door, and only during business hours"* (port 80 only, not every possible entrance). This is correct and expected — a receptionist whose door nobody could walk through wouldn't be much use.

- **The ECS tasks' security group** is the sign on the **kitchen's internal door**: *"this door only opens for people wearing a receptionist badge."* It doesn't matter who's standing outside or what street they walked in from — if you're not wearing that specific badge (the ALB's security group), the door simply doesn't open for you. A customer can't bypass the front desk and walk straight into the kitchen, even if they somehow found their way to the back hallway.

- **The "allow traffic out to anywhere" rules** on both doors are like saying staff are free to step out to make a delivery or a phone call whenever they need to — the restriction in this whole file is entirely about who's allowed to come **in**, not about controlling where people inside are allowed to go.

The overall effect: there's exactly one path from the street to the kitchen, and it's enforced at the door, not by hoping nobody wanders off course.