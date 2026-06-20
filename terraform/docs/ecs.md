# ECS Fargate Deployment (`ecs.tf`)

## What this file does

This file defines everything needed to actually **run** CloudShip's container in AWS and make it reachable via a public URL: the ECS cluster, load balancer, task definition, and the service that ties them together.

### 1. ECS Cluster

```hcl
resource "aws_ecs_cluster" "main" {
  name = "cloudship-cluster"
}
```

A logical grouping that ECS services and tasks run inside. On its own it costs nothing and runs nothing — it's just a namespace.

### 2. Application Load Balancer (ALB)

```hcl
resource "aws_lb" "main" {
  name               = "cloudship-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = module.vpc.public_subnets
}
```

This is the public entry point — it gets a stable DNS name (the live URL) and sits in the **public** subnets so it's internet-reachable. `internal = false` means it has a public-facing address; `security_groups` ties it to the ALB security group defined in `security-groups.tf`, which only allows inbound traffic on port 80.

### 3. Target Group

```hcl
resource "aws_lb_target_group" "app" {
  name        = "cloudship-tg"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip"

  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }
}
```

The target group is the list of "things the ALB sends traffic to." `target_type = "ip"` is required specifically because this is Fargate — there's no EC2 instance to point at, each task gets its own IP address, so the target group tracks IPs directly rather than instance IDs.

The `health_check` block defines how the ALB decides whether a running container is actually healthy: it hits `/` every 30 seconds, expects an HTTP 200, and needs 2 consecutive passes before marking a target healthy (or 3 consecutive failures before marking it unhealthy and pulling it out of rotation).

### 4. Listener

```hcl
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
```

Connects the ALB to the target group: "traffic arriving on port 80 gets forwarded to this target group."

### 5. ECS Task Execution Role

```hcl
resource "aws_iam_role" "ecs_task_execution" {
  name = "cloudship-ecs-task-execution-role"
  assume_role_policy = jsonencode({
    ...
    Principal = { Service = "ecs-tasks.amazonaws.com" }
    ...
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
```

This is a separate IAM role from the GitHub Actions one in `iam.tf` — easy to confuse since both relate to ECR, but they operate at different points in time and for different actors:

| | Who assumes it | What it does | When |
|---|---|---|---|
| `github_actions` (in `iam.tf`) | GitHub's CI workflow | **Pushes** images to ECR | At build time, on every `git push` |
| `ecs_task_execution` (here) | The ECS service itself | **Pulls** images from ECR, writes logs to CloudWatch | At task start time, every time a container launches |

### 6. CloudWatch Log Group

```hcl
resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/cloudship-app"
  retention_in_days = 7
}
```

Where the container's console output (stdout/stderr) gets sent, so logs can be checked from the AWS Console or CLI rather than needing to SSH into anything. `retention_in_days = 7` auto-deletes old logs to keep storage costs negligible.

### 7. Task Definition

```hcl
resource "aws_ecs_task_definition" "app" {
  family                   = "cloudship-app"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([{
    name      = "cloudship-app"
    image     = "${aws_ecr_repository.app.repository_url}:latest"
    essential = true
    portMappings = [{ containerPort = 3000, protocol = "tcp" }]
    logConfiguration = { ... }
  }])
}
```

This describes *what* to run, not how many or where — the blueprint for a single container instance. `network_mode = "awsvpc"` is mandatory for Fargate; it gives each task its own elastic network interface and private IP, rather than sharing the host's networking (which is how ECS-on-EC2 typically works instead). `cpu = "256"` / `memory = "512"` is the smallest, cheapest Fargate size (0.25 vCPU / 512 MB) — sufficient for a simple Next.js app. The `image` field always pulls whatever was most recently tagged `:latest` in ECR — meaning this picks up new code automatically every time the CI pipeline pushes a new image and the service is redeployed.

### 8. ECS Service

```hcl
resource "aws_ecs_service" "app" {
  name            = "cloudship-app-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name    = "cloudship-app"
    container_port    = 3000
  }

  depends_on = [aws_lb_listener.http]
}
```

While the task definition is the *blueprint*, the service is what actually keeps it running: it launches `desired_count` copies of the task, restarts them if they crash or fail health checks, and registers/deregisters them with the target group automatically as they start and stop.

Two design choices worth highlighting:
- **`subnets = module.vpc.private_subnets`, `assign_public_ip = false`** — the running container has no public IP and no direct route to the internet. It's only reachable *through* the ALB, which is the only public-facing piece. This is the actual security benefit of the public/private subnet split.
- **`depends_on = [aws_lb_listener.http]`** — an explicit dependency, because Terraform's automatic dependency graph wouldn't otherwise know the listener must exist before the service tries to register with the target group (the link between them isn't a direct attribute reference).

### 9. Output: the live URL

```hcl
output "app_url" {
  value = "http://${aws_lb.main.dns_name}"
}
```

Prints the ALB's public DNS name as a usable URL after `terraform apply` — this is the link that gets opened in a browser to see the running app.

---

## In plain English

Think of this whole file as setting up a **restaurant with a reception desk out front and a kitchen out back that no customer ever sees.**

- **The ECS Cluster** is just the *building* — an empty shell that says "this address is where the restaurant operates," before any staff or equipment are in it.

- **The Application Load Balancer (ALB)** is the **receptionist at the front door**. It's the only one allowed to greet people walking in off the street (the public internet). It has a known street address (the DNS name / live URL) that customers use to find the place.

- **The Target Group** is the receptionist's **list of which kitchen staff are currently available to take an order**. As cooks clock in or go on break, this list updates automatically — the receptionist always knows who's actually ready right now.

- **The Listener** is the rule the receptionist follows: *"when someone walks in the front door, send them to whoever's on the available-staff list."*

- **The Task Execution Role** is like a **staff ID badge** that lets a cook badge into the supply room (ECR) to grab ingredients (the image) and write their shift notes into the building's logbook (CloudWatch) — but only at the moment they clock in, not before.

- **The CloudWatch Log Group** is that **shift logbook** — anyone checking on the kitchen later can read what happened, without needing to have been standing there.

- **The Task Definition** is the **recipe card** — exactly what ingredients (image), how big a workstation (CPU/memory), and what station number (port) a cook needs, written down so anyone could follow it.

- **The ECS Service** is the **kitchen manager**. They make sure exactly the right number of cooks (`desired_count`) are working the recipe at all times — if one walks off the job or gets sick (crashes or fails a health check), the manager immediately replaces them, without anyone out front even noticing.

- **Cooks work in the back kitchen, not the dining room** (private subnets, no public IP) — customers never walk back there directly. Every order goes through the receptionist first. That's the whole point of the front-desk/back-kitchen split: nobody from the street can wander into the kitchen and start poking around.

- **The final `app_url` output** is just the restaurant's listed address — the thing you'd actually type into Google Maps (or a browser) to go visit it.