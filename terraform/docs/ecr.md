# ECR Repository (`ecr.tf`)

## What this file does

This file defines the **Elastic Container Registry (ECR) repository** that stores CloudShip's Docker images — the built, deployable versions of the application.

```hcl
resource "aws_ecr_repository" "app" {
  name         = "cloudship-repository"
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}
```

| Argument | Purpose |
|---|---|
| `name` | The repository's name within ECR. This is the identifier used everywhere else — the GitHub Actions workflow pushes to it, the ECS task definition pulls from it. |
| `force_delete` | Without this, AWS refuses to delete a repository that still contains images — `terraform destroy` would fail partway through. Setting it to `true` allows a clean teardown even with images present, which matters here since the repo accumulates a new image on every CI run. |
| `image_scanning_configuration { scan_on_push = true }` | Tells AWS to automatically scan every image for known vulnerabilities (CVEs) as soon as it's pushed, at no extra cost. Purely informational — it doesn't block a push, just surfaces findings in the console. |

```hcl
output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}
```

This exposes the repository's full URL (account ID + region + repo name) as a Terraform output, so other resources — specifically the ECS task definition in `ecs.tf` — can reference it directly via `aws_ecr_repository.app.repository_url`, instead of it being hardcoded as a string somewhere.

### Why this resource needed `terraform import`, not just `terraform apply`

This repository was originally created manually (via the AWS CLI) in Week 2, before Terraform was introduced to the project in Week 3. Writing the `resource` block alone doesn't make Terraform aware that a matching repository already exists in AWS — Terraform only tracks what's recorded in its **state file**. Running `terraform import aws_ecr_repository.app cloudship-repository` was a one-time command that linked this existing AWS resource to this Terraform resource block, so Terraform manages it going forward without trying to recreate it (which would fail anyway, since a repository with that name already exists).

---

## In plain English

Think of ECR as a **locker room at a gym**.

Every time you finish a workout (write new code and push it), you put your gym bag (a Docker image — basically a zipped-up, ready-to-run copy of your app) into a locker. The locker room is `cloudship-repository` — one designated space that holds all your bags, each one labeled with a tag (like a date or a version number) so you can tell them apart.

- **`force_delete = true`** is like telling the gym, "if I ever cancel my membership, throw out anything still in my locker instead of refusing to close my account because it's not empty." Without this, if you tried to shut everything down while a bag was still in the locker, the gym would say "no, empty it first" — and you'd be stuck.

- **`scan_on_push = true`** is like having gym security automatically check your bag for anything dangerous the moment you drop it off — not stopping you from using the locker, just quietly flagging anything concerning so you can deal with it later.

- **The `output` block** is like posting the locker's address on a noticeboard so anyone else in the building (like the part of the system that actually picks up your bag and runs your app — ECS) knows exactly where to go get it, without you having to tell them in person every time.

- **Why we needed `import`:** you'd already rented this locker yourself, by hand, before you started using a property management app (Terraform) to manage everything else in the building. Writing the Terraform config alone is like adding the locker to the app's spreadsheet — but the app doesn't actually know it's *your* real locker until you do one manual step that says "this locker, in real life, is the same one as this entry in your spreadsheet." That one-time linking step is what `terraform import` did.