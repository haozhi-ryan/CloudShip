module "security_group" {
  source = "terraform-aws-modules/security-group/aws"
  version = "6.0.0"

  name        = "cloudship-app-sg"
  description = "Security group for Cloudship application"
  vpc_id      = module.vpc.vpc_id  

  ingress_rules = {
    https = {
      from_port   = 443
      ip_protocol = "tcp"
      cidr_ipv4   = "10.0.0.0/16"
      description = "HTTPS from internal"
    }
    self-all = {
      ip_protocol                  = "-1"
      referenced_security_group_id = "self"
      description                  = "All traffic from members of this SG"
    }
  }

  egress_rules = {
    all = {
      ip_protocol = "-1"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }

  tags = {
    Environment = "dev"
  }
}
