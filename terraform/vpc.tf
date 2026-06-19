module "vpc" {
  source = "terraform-aws-modules/vpc/aws"
  version = "6.6.1"

  name = "cloudship-app-vpc"
  cidr = "10.0.0.0/16"

  # which availability zones to spread across (2 AZs = high availability)
  azs             = ["ap-southeast-2a", "ap-southeast-2b"]

  # one private subnet per AZ = 2 private subnets total
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]

  # one public subnet per AZ = 2 public subnets total
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  tags = {
    Terraform = "true"
    Environment = "dev"
  }
}

