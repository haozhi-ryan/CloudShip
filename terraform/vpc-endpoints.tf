# --- VPC Endpoints for ECR + S3 ---
# These let resources in PRIVATE subnets reach ECR and S3 over AWS's internal
# network, without needing a route to the public internet (no NAT Gateway).
# ECR itself needs two endpoints (api + dkr) because of how its API is split,
# and S3 is needed too because ECR stores the actual image layers in S3 behind the scenes.

# Security group for the endpoints themselves — controls what can reach them
resource "aws_security_group" "vpc_endpoints" {
  name        = "cloudship-vpc-endpoints-sg"
  description = "Allow HTTPS from ECS tasks to VPC endpoints"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "HTTPS from ECS tasks"
    from_port        = 443
    to_port          = 443
    protocol         = "tcp"
    security_groups  = [aws_security_group.ecs_tasks.id]   # only the ECS tasks can reach these endpoints
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Endpoint for ECR's authentication/control-plane API
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.ap-southeast-2.ecr.api"
  vpc_endpoint_type    = "Interface"          # "Interface" = creates an ENI in your subnet to talk to the service
  subnet_ids           = module.vpc.private_subnets
  security_group_ids   = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled  = true                  # lets the task resolve the normal ECR DNS name to this private endpoint
}

# Endpoint for ECR's actual image-pulling (Docker registry) API
resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.ap-southeast-2.ecr.dkr"
  vpc_endpoint_type    = "Interface"
  subnet_ids           = module.vpc.private_subnets
  security_group_ids   = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled  = true
}

# Endpoint for S3 — ECR stores image layers here, so tasks need this too
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.ap-southeast-2.s3"
  vpc_endpoint_type  = "Gateway"                          # "Gateway" type = free, just a route table entry, not an ENI
  route_table_ids    = module.vpc.private_route_table_ids   # attaches to the private subnets' route tables
}

# Endpoint for CloudWatch Logs — your task needs this too, to ship logs
# (this is also a private-network call, same problem as ECR if missing)
resource "aws_vpc_endpoint" "logs" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.ap-southeast-2.logs"
  vpc_endpoint_type    = "Interface"
  subnet_ids           = module.vpc.private_subnets
  security_group_ids   = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled  = true
}