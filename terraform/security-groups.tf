# --- Security group for the Application Load Balancer (ALB) ---
# This is the "front door" — it's the only thing allowed to receive
# traffic directly from the internet.
resource "aws_security_group" "alb" {
  name        = "cloudship-alb-sg"
  description = "Allow inbound HTTP from the internet"
  vpc_id      = module.vpc.vpc_id   # references the VPC created by the vpc module

  # Allow anyone on the internet to reach the ALB on port 80 (HTTP)
  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]   # 0.0.0.0/0 = "any IP address"
  }

  # Allow the ALB to send traffic out to anywhere (needed to reach the ECS tasks)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"            # -1 = all protocols
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- Security group for the ECS Fargate tasks (your running containers) ---
# This locks the containers down so ONLY the ALB can talk to them —
# nothing reaches them directly from the internet.
resource "aws_security_group" "ecs_tasks" {
  name        = "cloudship-ecs-tasks-sg"
  description = "Allow inbound only from the ALB"
  vpc_id      = module.vpc.vpc_id   # references the VPC created by the vpc module

  # Only allow traffic on port 3000 (Next.js) if it's coming from the ALB's security group
  ingress {
    description     = "From ALB only"
    from_port        = 3000
    to_port          = 3000
    protocol         = "tcp"
    security_groups  = [aws_security_group.alb.id]   # source = the ALB SG, not an IP range
  }

  # Allow the tasks to send traffic out anywhere (needed to pull images from ECR, call APIs, etc.)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}