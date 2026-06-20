# --- ECR repository for the app's Docker images ---
# This repo already exists (created manually in Week 2) — we're bringing
# it under Terraform management via `terraform import`, not creating a new one.
resource "aws_ecr_repository" "app" {
  name         = "cloudship-repository"   # replace with your real repo name
  force_delete = true                      # lets `terraform destroy` remove it even if it has images

  image_scanning_configuration {
    scan_on_push = true
  }
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}