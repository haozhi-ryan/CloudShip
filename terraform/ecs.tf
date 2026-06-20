resource "aws_ecs_cluster" "main" {
  name = "cloudship-cluster"
}

# --- Application Load Balancer (ALB) ---
# This is the entry point for all traffic — it gets a public DNS name,
# which becomes your live URL.
resource "aws_lb" "main" {
  name               = "cloudship-alb"
  internal           = false                          # false = publicly accessible
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]    # uses the SG we created earlier
  subnets            = module.vpc.public_subnets        # ALB must sit in PUBLIC subnets

  tags = {
    Environment = "dev"
  }
}

# --- Target Group ---
# This is the "list of things the ALB sends traffic to" — in this case,
# your ECS Fargate tasks. ECS automatically registers/deregisters tasks
# here as they start, stop, or fail health checks.
resource "aws_lb_target_group" "app" {
  name        = "cloudship-tg"
  port        = 3000                # the port your Next.js container listens on
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip"                # required for Fargate (tasks get their own IP, not an instance ID)

  health_check {
    path                = "/"        # URL the ALB hits to check if your app is alive
    healthy_threshold   = 2          # consecutive successful checks before marking "healthy"
    unhealthy_threshold = 3          # consecutive failed checks before marking "unhealthy"
    timeout             = 5          # seconds to wait for a response
    interval            = 30         # seconds between checks
    matcher             = "200"      # expects an HTTP 200 response
  }
}

# --- Listener ---
# Tells the ALB: "when traffic arrives on port 80, send it to this target group"
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# --- IAM role for ECS to pull images and write logs ---
# This is DIFFERENT from the GitHub Actions role — that one lets GitHub push
# images TO ecr. This one lets ECS itself pull images FROM ecr and write logs,
# at the time a task actually starts running.
resource "aws_iam_role" "ecs_task_execution" {
  name = "cloudship-ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"   # only the ECS service itself can assume this
      }
    }]
  })
}

# AWS-managed policy with exactly what's needed: pull from ECR, write to CloudWatch Logs
resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# --- CloudWatch Log Group ---
# Where your container's logs (console output) get sent, so you can debug
# from the AWS Console instead of needing to SSH anywhere.
resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/cloudship-app"
  retention_in_days = 7   # auto-deletes old logs after 7 days, keeps costs near-zero
}

# --- Task Definition ---
# Describes the container: which image, how much CPU/memory, what port,
# where logs go. This is the Fargate equivalent of a Kubernetes pod spec.
resource "aws_ecs_task_definition" "app" {
  family                   = "cloudship-app"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"          # required for Fargate — gives each task its own ENI/IP
  cpu                      = "256"               # 0.25 vCPU — smallest/cheapest Fargate size
  memory                   = "512"               # 512 MB — smallest/cheapest Fargate size
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([
    {
      name      = "cloudship-app"
      image     = "${aws_ecr_repository.app.repository_url}:latest"   # pulls the latest pushed image
      essential = true                                                  # if this container dies, the task dies (only one container here, so it must be essential)

      portMappings = [
        {
          containerPort = 3000
          protocol      = "tcp"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = "ap-southeast-2"
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])
}

# --- ECS Service ---
# Keeps the desired number of tasks running, registers them with the
# target group, restarts them if they crash or fail health checks.
resource "aws_ecs_service" "app" {
  name            = "cloudship-app-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1                          # how many copies of the container to run
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = module.vpc.private_subnets   # tasks run in PRIVATE subnets, not public
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false                          # not needed — traffic comes via the ALB, not directly
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name    = "cloudship-app"               # must match the name in container_definitions
    container_port    = 3000
  }

  depends_on = [aws_lb_listener.http]   # ALB listener must exist before the service tries to register
}

# --- Output: the live URL ---
output "app_url" {
  value = "http://${aws_lb.main.dns_name}"
}