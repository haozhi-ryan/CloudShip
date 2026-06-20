# CloudShip — Terraform Infrastructure Overview

This document explains how the project's Terraform files work together as a system. Each file also has its own detailed doc in `docs/` — this page is the map that shows how they connect.

## Files in this project

| File | What it provisions | Detailed doc |
|---|---|---|
| `main.tf` | Provider + Terraform version config only — no resources | — |
| `vpc.tf` | The network itself: VPC, public/private subnets, route tables, internet gateway | `docs/vpc.md` |
| `security-groups.tf` | Firewall rules controlling what can talk to what | `docs/security-groups.md` |
| `iam.tf` | Lets GitHub Actions push images to ECR via OIDC (no stored AWS keys) | `docs/iam.md` |
| `ecr.tf` | The container registry that stores built Docker images | `docs/ecr.md` |
| `ecs.tf` | Runs the container on Fargate, fronted by a load balancer | `docs/ecs.md` |
| `vpc-endpoints.tf` | Lets private-subnet tasks reach ECR/S3/CloudWatch without internet access | `docs/vpc-endpoints.md` |

## How they fit together: two separate flows

It helps to think of this infrastructure as **two independent pipelines that only meet at one point** — the ECR repository.

### Flow 1 — Getting code into a runnable image (CI)

```
Developer pushes code to GitHub (main branch)
        │
        ▼
GitHub Actions workflow runs
        │
        ▼
Authenticates to AWS using the OIDC role from iam.tf
(no stored AWS keys — GitHub proves its identity, AWS hands back temporary credentials)
        │
        ▼
Builds the Docker image, pushes it to the ECR repo from ecr.tf
```

`iam.tf` only matters during this flow — it's the trust relationship that lets GitHub push to ECR.

### Flow 2 — Running that image and serving it publicly (CD / runtime)

```
ecs.tf's ECS Service starts a Fargate task
        │
        ▼
The task needs to pull the image — but it lives in a PRIVATE subnet (vpc.tf)
with no internet route, so it can't reach ECR directly
        │
        ▼
vpc-endpoints.tf provides a private path to ECR (api + dkr) and S3
(S3 because ECR stores image layers there behind the scenes)
        │
        ▼
Task pulls the image, starts the container, registers with the
target group defined in ecs.tf
        │
        ▼
The Application Load Balancer (also in ecs.tf, sitting in PUBLIC subnets
from vpc.tf) receives traffic on the live URL and forwards it to the task
        │
        ▼
security-groups.tf enforces that ONLY the ALB can reach the task
(nothing else in the VPC, and nothing from the internet, can reach it directly)
```

`ecs_task_execution` role (defined inside `ecs.tf`) is the other IAM piece at play here — separate from `iam.tf`'s GitHub role — it's what lets the *running task* (not GitHub) pull from ECR and write logs, at the moment it starts.

### The one shared point: `ecr.tf`

Flow 1 ends by depositing an image into the ECR repo. Flow 2 begins by picking that same image back up. Every other file either prepares the path *into* ECR (iam.tf, for GitHub) or the path *out of* it (vpc-endpoints.tf, vpc.tf, ecs.tf, for the running task).

## Why two separate IAM roles exist (a common point of confusion)

There are two distinct identities that interact with ECR, and it's easy to conflate them:

| Role | Defined in | Who assumes it | Direction | When |
|---|---|---|---|---|
| `github_actions` | `iam.tf` | GitHub's CI workflow | **Pushes** to ECR | Every `git push` to `main` |
| `ecs_task_execution` | `ecs.tf` | The ECS service | **Pulls** from ECR, writes logs | Every time a task starts |

Different trust principals (`Federated` GitHub OIDC vs. `Service: ecs-tasks.amazonaws.com`), different point in the lifecycle, different permissions scope. Neither role can do the other's job.

## Why two separate security groups exist

Same pattern as the IAM split — least privilege, applied to network access instead of API permissions:

| Security group | Defined in | Protects | Allows inbound from |
|---|---|---|---|
| `alb` | `security-groups.tf` | The load balancer | The public internet, port 80 |
| `ecs_tasks` | `security-groups.tf` | The running container | Only the `alb` security group, port 3000 |
| `vpc_endpoints` | `vpc-endpoints.tf` | The ECR/S3/Logs endpoints | Only the `ecs_tasks` security group, port 443 |

Each layer only trusts the layer immediately in front of it — the internet can reach the ALB, the ALB can reach the tasks, the tasks can reach the endpoints, and nothing skips a layer.

## Why there's no NAT Gateway anywhere in this stack

A NAT Gateway is the conventional way to give private-subnet resources internet access. This project deliberately avoids one — instead, `vpc-endpoints.tf` provides narrow, AWS-only private connectivity for exactly the three services the task needs (ECR, S3, CloudWatch Logs). The tradeoff: the running container has **zero path to the public internet**, not just a restricted one. See `docs/vpc-endpoints.md` for the full reasoning, including when a NAT Gateway would actually be the right call (e.g. calling a third-party API, which this app doesn't currently do).

## Known scope limitation (intentional, deferred)

The ECR repository (`ecr.tf`) currently lives in the **same Terraform state** as the ECS/VPC/networking resources. Since this project is destroyed and reapplied between sessions to manage cost, a future refactor will split this into two separate state files — a `persistent/` stack (ECR, IAM) that's never destroyed, and a `compute/` stack (VPC, ECS, ALB) that's torn down freely — so a routine `terraform destroy` can't accidentally delete the image registry along with the compute layer.

## Quick reference: applying and tearing down

```bash
terraform plan      # always review before applying
terraform apply      # creates/updates everything across all 7 files in one pass
terraform output app_url   # the live URL, once apply finishes

terraform destroy    # tears down everything, including the ECR repo and its images
                       # (until the persistent/compute split above is done)
```