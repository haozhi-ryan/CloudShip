# GitHub Actions OIDC Authentication (`iam.tf`)

This file lets GitHub Actions push Docker images to ECR without storing any AWS credentials as GitHub secrets. Instead, AWS trusts short-lived tokens issued directly by GitHub for each workflow run.

## Why OIDC instead of access keys

The traditional approach stores a static `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` pair as GitHub secrets. These don't expire on their own, and if a workflow ever leaks them (bad logging, a compromised action, a misconfigured step), the keys are valid until someone manually rotates them.

OIDC removes that risk entirely. GitHub issues a token that's valid only for the duration of a single workflow run, AWS verifies it came from GitHub and matches a specific repo, and hands back temporary credentials. Nothing long-lived is stored anywhere.

## Resources in this file

### 1. `aws_iam_openid_connect_provider.github_actions_oidc`

```hcl
resource "aws_iam_openid_connect_provider" "github_actions_oidc" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
}
```

This registers GitHub's OIDC identity provider as a **trusted issuer** inside the AWS account. AWS doesn't know about GitHub's tokens by default — this resource is what tells it "tokens from this URL are allowed to be evaluated for trust."

| Argument | Meaning |
|---|---|
| `url` | GitHub's OIDC token endpoint. Every GitHub Actions workflow run can request a token from here. |
| `client_id_list` | The allowed audience(s) for the token. `sts.amazonaws.com` means "this token is meant for AWS STS," scoping it so a GitHub token can't be replayed against some unrelated service. |

**Note:** an OIDC provider for a given URL can only exist once per AWS account. If you reuse this pattern in another project's Terraform (e.g. Munchies) in the same AWS account, don't create a second one — reference this existing provider instead.

### 2. `aws_iam_role.github_actions`

```hcl
resource "aws_iam_role" "github_actions" {
  name = "github-actions-ecr-push"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRoleWithWebIdentity"
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github_actions_oidc.arn
        }
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = "repo:haozhi-ryan/CloudShip:*"
          }
        }
      }
    ]
  })
}
```

This is the IAM role GitHub Actions assumes during a workflow run. The `assume_role_policy` (the **trust policy**) defines exactly who is allowed to assume it:

- **`Principal.Federated`** — points at the OIDC provider above, meaning "only identities verified through that provider can even attempt this."
- **`Condition.StringEquals` on `aud`** — double-checks the token's audience really is AWS STS.
- **`Condition.StringLike` on `sub`** — restricts *which* GitHub identity is trusted. `repo:haozhi-ryan/CloudShip:*` means any workflow run from the `haozhi-ryan/CloudShip` repo, on any branch, tag, or pull request, can assume this role.

> **Tightening this further:** the `:*` wildcard trusts every branch and PR in the repo, not just `main`. Since this role is meant for the CI/CD pipeline (which should only run on `main`), a stricter `sub` value would be:
> ```
> "repo:haozhi-ryan/CloudShip:ref:refs/heads/main"
> ```
> This is a least-privilege improvement worth making once the pipeline is stable.

### 3. `aws_iam_role_policy_attachment.ecr_push`

```hcl
resource "aws_iam_role_policy_attachment" "ecr_push" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}
```

This is the **permissions policy** — separate from the trust policy above. Where the trust policy controls *who can assume the role*, this controls *what the role can do once assumed*.

`AmazonEC2ContainerRegistryPowerUser` is an AWS-managed policy that grants push/pull access to ECR repositories, without granting broader account permissions (e.g. it can't touch EC2, IAM, or other services). This keeps the role scoped to exactly what the CI/CD pipeline needs.

### 4. `output.github_actions_role_arn`

```hcl
output "github_actions_role_arn" {
  value = aws_iam_role.github_actions.arn
}
```

Exposes the role's ARN after `terraform apply`, so it can be copied into the `role-to-assume` field of the GitHub Actions workflow file (`.github/workflows/deploy.yml`).

## How it fits together at runtime

1. A commit is pushed to `main` in `haozhi-ryan/CloudShip`.
2. The workflow requests a short-lived OIDC token from GitHub (requires `permissions: id-token: write` in the workflow YAML).
3. The workflow presents that token to AWS STS via `aws-actions/configure-aws-credentials`, asking to assume `github_actions_role_arn`.
4. AWS checks the trust policy: is the token from the registered OIDC provider, with the right audience, from the right repo? If yes, AWS issues temporary credentials scoped to this role.
5. Those temporary credentials are used to log in to ECR and push the Docker image — and they expire automatically once the job finishes.

No AWS keys are ever stored in GitHub, and nothing here needs manual rotation.

<br><br>

# 🏗️ Analogy: The Grand Clubhouse Security System

**The Cast:** You (the clubhouse owner), your GitHub robot (the delivery bot), a bouncer (AWS IAM), and a badge-printing machine (GitHub's OIDC system).

---

## 1. `aws_iam_openid_connect_provider` = The Bouncer's Rulebook

**What you are doing:** You walk up to the clubhouse bouncer and hand him an official document from the city. The document says: "The city guarantees that any badge stamped with the city's official seal comes from the real government printing office."

**What AWS does:** You are creating a trusted entry in AWS that says: "I trust login badges that come from `https://token.actions.githubusercontent.com` (GitHub)."

- **`url`** = The address of the government printing office (GitHub).
- **`client_id_list`** = The specific stamp on the badge. You tell the bouncer: "Only accept badges that say 'This is for AWS' on them." For GitHub, this is always `sts.amazonaws.com`.

**Result:** The bouncer now has a rulebook. He knows where a valid badge must come from and what stamp it must have.

---

## 2. `aws_iam_role.github_actions` = The Temporary "Delivery Driver" Uniform

**What you are doing:** You go to the coat closet and hang up a special red delivery driver uniform (the IAM Role).

**What AWS does:** It creates an empty uniform with a tag on it. The tag has two parts:

- **The Trust Policy (Who can wear this uniform):** The tag explicitly says: "Only a delivery robot that shows a badge with the name `repo:haozhi-ryan/CloudShip:*` is allowed to put this uniform on."
- **No permissions yet:** Right now, the uniform itself has no pockets or tools. It doesn't say what the driver is allowed to do once dressed.

**Result:** You have a uniform hanging on the hook, but nobody can do anything with it yet because it has no tools.

---

## 3. `aws_iam_role_policy_attachment` = Filling the Uniform's Toolbelt

**What you are doing:** You walk over to the red uniform and attach a heavy-duty toolbelt to it. The toolbelt has a label that says: "This belt allows the wearer to open the ECR warehouse and push boxes inside."

**What AWS does:** It takes the AWS-managed policy called `AmazonEC2ContainerRegistryPowerUser` (the toolbelt) and clips it onto your `github-actions-ecr-push` role (the uniform).

**Result:** The uniform is now fully functional. If a robot wears this uniform, it gets the toolbelt and can push Docker images to ECR.

---

## 4. `output "github_actions_role_arn"` = The Uniform's Official Barcode

**What you are doing:** You stick a barcode sticker on the back of the red uniform that reads: `arn:aws:iam::123456789012:role/github-actions-ecr-push`.

**What AWS does:** It generates a unique Amazon Resource Name (ARN) for the role and prints it out as an output after you run Terraform.

**Why you need it:** You take this barcode and copy it into your GitHub Actions workflow file (`.github/workflows/deploy.yml`). This is how you tell the robot: "Hey robot, when you get to the clubhouse, go to the coat closet and specifically ask for the uniform with THIS exact barcode on it."

---

## 🔄 The Full Story (How It All Works Together)

**Step 1:** Your GitHub Actions workflow file (which has your role ARN in it) starts running.

**Step 2:** The robot (GitHub runner) goes to the government printing office (GitHub's OIDC system) and says: "I am from the CloudShip repository. Please give me a badge." GitHub checks and hands the robot a badge (JWT token). The badge has a stamp on it: `sts.amazonaws.com`, and the robot's name written on it: `repo:haozhi-ryan/CloudShip:*`.

**Step 3:** The robot walks up to your clubhouse bouncer (AWS) and holds up the badge.

**Step 4:** The bouncer pulls out his Rulebook (`aws_iam_openid_connect_provider`). He checks:
- "Did this badge come from the official government printer?" (Checks the `url`) ✅ Yes.
- "Does it have the correct 'For AWS' stamp?" (Checks `client_id_list`) ✅ Yes.

**Step 5:** The robot says: "I would like to wear the uniform with the barcode `arn:aws:iam::123456789012:role/github-actions-ecr-push`."

**Step 6:** The bouncer pulls that Uniform (`aws_iam_role`) off the hook and reads the Trust Policy tag on it. He checks:
- "Does the name on this badge (`repo:haozhi-ryan/CloudShip:*`) match the name allowed on the uniform's tag?" ✅ Yes.

**Step 7:** The bouncer says: "You are cleared! Here, put on this uniform." The robot puts on the uniform, which has the Toolbelt (`aws_iam_role_policy_attachment`) attached to it.

**Step 8:** The robot now has temporary keys. It walks into the ECR warehouse, uses the tools on its belt to push the Docker image, and finishes the job.

**Step 9:** After 1 hour, the uniform and the keys automatically expire and go back on the hook, useless to anyone else.

---

## 📝 The One-Sentence Summary

| Terraform Code | Analogy | Purpose |
|---|---|---|
| `aws_iam_openid_connect_provider` | Bouncer's rulebook | Tells AWS which external ID system to trust and what stamp to look for. |
| `aws_iam_role.github_actions` | The empty uniform | Creates a temporary identity that can be worn, with a tag saying who is allowed to wear it. |
| `aws_iam_role_policy_attachment` | The toolbelt on the uniform | Adds the actual permissions (ECR push) to the identity. |
| `output.github_actions_role_arn` | The uniform's barcode | Prints the official name of the uniform so your GitHub robot can ask for it by name. |