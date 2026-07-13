# Terraform CI/CD — plan on PR, apply on merge

The standard **GitOps** workflow for infrastructure: a pull request runs `terraform plan` so reviewers see exactly what will change, and merging to the main branch runs `terraform apply` to make it real. This doc shows the pattern in **GitHub Actions** and **Jenkins**, applies it to an **RDS/Aurora database upgrade**, and explains where **Terraform Cloud/Enterprise (TFE)** fits.

**See also:** [../README.md](../README.md) · [../../jenkins/docs/github-actions-vs-jenkins.md](../../jenkins/docs/github-actions-vs-jenkins.md) · [../../databases/docs/aws-rds-aurora.md](../../databases/docs/aws-rds-aurora.md)

---

## The workflow (why plan-on-PR / apply-on-merge)

```
 Developer                 CI                         Cloud
 ─────────                 ──                         ─────
 edit *.tf ──► open PR ──► terraform plan ──► post plan as PR comment
                                              (reviewers approve the diff)
              merge PR ──► terraform apply ──► changes applied to infra
```

- **PR = plan (read-only):** shows the diff (`+ create`, `~ update`, `- destroy`) with **no changes made**. This is the review gate — you approve the *plan*, not just the code.
- **Merge = apply:** the reviewed change is executed against real infrastructure. Main branch = source of truth for what's deployed.
- **Why:** peer review of actual infra changes, an audit trail, no manual `apply` from laptops, and no drift between code and reality.

Key building blocks either tool needs:
- **Remote state** with locking (e.g., S3 + DynamoDB) so concurrent runs don't corrupt state.
- **Cloud credentials** — prefer **OIDC** (short-lived, no stored keys) over long-lived access keys.
- **A manual approval** before `apply` for production (environment protection / input step).

---

## GitHub Actions

Two workflows (or one with two jobs): **plan** on `pull_request`, **apply** on `push` to `main`.

```yaml
# .github/workflows/terraform.yml
name: Terraform
on:
  pull_request:
  push:
    branches: [main]

permissions:
  id-token: write      # for OIDC to AWS
  contents: read
  pull-requests: write # to comment the plan on the PR

jobs:
  plan:
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::123456789012:role/terraform-ci
          aws-region: us-east-1
      - uses: hashicorp/setup-terraform@v3
      - run: terraform init
      - run: terraform plan -no-color -out=tfplan
        id: plan
      - uses: actions/github-script@v7        # post the plan back to the PR
        with:
          script: |
            const out = `#### Terraform Plan\n\`\`\`\n${{ steps.plan.outputs.stdout }}\n\`\`\``;
            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner, repo: context.repo.repo, body: out });

  apply:
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    runs-on: ubuntu-latest
    environment: production        # <-- requires a manual approval before apply
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::123456789012:role/terraform-ci
          aws-region: us-east-1
      - uses: hashicorp/setup-terraform@v3
      - run: terraform init
      - run: terraform apply -auto-approve
```

- `pull_request` event → **plan** job → comments the diff on the PR.
- `push` to `main` (i.e., the merge) → **apply** job. The `environment: production` gives you a **required reviewer** gate before it runs.
- OIDC (`id-token: write` + `configure-aws-credentials`) means **no AWS keys stored** in GitHub.

---

## Jenkins

A single `Jenkinsfile` (multibranch pipeline) that branches on whether it's a PR build or a main build.

```groovy
// Jenkinsfile
pipeline {
  agent { label 'linux' }
  environment { AWS_REGION = 'us-east-1' }

  stages {
    stage('Init') {
      steps { sh 'terraform init -input=false' }
    }

    stage('Plan') {                       // runs on PR branches
      when { changeRequest() }            // true for PR builds
      steps {
        sh 'terraform plan -no-color -out=tfplan'
        sh 'terraform show -no-color tfplan > plan.txt'
        archiveArtifacts 'plan.txt'       // reviewers read the plan artifact
        // optional: post plan.txt back to the PR via GitHub API / plugin
      }
    }

    stage('Apply') {                      // runs only on main (after merge)
      when { branch 'main' }
      steps {
        input message: 'Apply this Terraform change to production?'  // manual gate
        sh 'terraform apply -auto-approve'
      }
    }
  }
  post { always { cleanWs() } }
}
```

- `when { changeRequest() }` → the **Plan** stage runs for PRs.
- `when { branch 'main' }` → the **Apply** stage runs after the merge; `input` pauses for a human approval before applying.
- Credentials come from the **Jenkins credentials store** (or IAM role on the agent / OIDC via a plugin) rather than being hardcoded.

Same GitOps outcome as GitHub Actions — the difference is you **operate the Jenkins controller/agents** yourself, whereas Actions runs on managed runners.

---

## Applying it to an RDS / Aurora database upgrade

A database engine upgrade becomes a **code change + PR** instead of a console click. You bump `engine_version` in Terraform; the PR plan shows the upgrade; merging applies it.

```hcl
# rds-aurora.tf
resource "aws_rds_cluster" "app" {
  cluster_identifier              = "app-prod"
  engine                          = "aurora-postgresql"
  engine_version                  = "16.4"          # <-- bump this to upgrade
  allow_major_version_upgrade     = true            # required for major (15.x -> 16.x)
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.pg16.name
  apply_immediately               = false           # true = now (downtime); false = maintenance window
  # ...
}

resource "aws_rds_cluster_parameter_group" "pg16" {
  name   = "app-prod-pg16"
  family = "aurora-postgresql16"                     # new family for the new major version
  # ... your custom params ...
}
```

**What the PR plan shows** (the review gate for a risky change):

```
  ~ resource "aws_rds_cluster" "app" {
      ~ engine_version                  = "15.4" -> "16.4"
      ~ db_cluster_parameter_group_name = "app-prod-pg15" -> "app-prod-pg16"
    }
```

Reviewers see the version jump and the parameter-group swap **before** anything happens, then approve the merge.

**Tie-in to the Aurora Global Database gotchas** (see [aws-rds-aurora.md](../../databases/docs/aws-rds-aurora.md)):
- **Pre-create the new-family parameter groups in every region** (including headless secondaries) in the *same* PR — Terraform manages them as code, which keeps regions **symmetric** and avoids the "secondary fell back to defaults" trap.
- For a **global cluster**, drive the version on the `aws_rds_global_cluster` and let members follow; **turn off `rds.global_db_rpo`** before a major upgrade (a cluster-parameter-group change, also in Terraform).
- **Minor upgrades of a headless secondary** need a temporary instance — that's an operational step Terraform can express (add instance → upgrade → remove), but many teams do the minor-upgrade dance via a runbook rather than a single apply.
- Use `apply_immediately = false` to let the upgrade land in the **maintenance window** rather than instantly.

**Why do DB upgrades this way:** every version bump is peer-reviewed, diffed, audited in git, repeatable across environments (dev → staging → prod via the same PR flow), and reversible in code — far safer than clicking "Modify" in the console.

> Caution: Terraform will happily plan a destructive change. For databases, **always read the plan carefully** — some attribute changes force **replacement** (`-/+ destroy and then create`), which on a DB means data loss. Guard with `lifecycle { prevent_destroy = true }` on stateful resources.

---

## Where Terraform Cloud / Enterprise (TFE) fits

**TFE** (and its SaaS sibling **HCP Terraform**, formerly Terraform Cloud) is a **managed platform that runs the plan/apply for you** and adds governance. It slots into the same PR→plan / merge→apply flow but **moves the execution off your CI runner** into TFE's **remote runs**.

Two common integration styles:

1. **VCS-driven workflow (TFE watches the repo directly):**
   - You connect the repo to a TFE **workspace**.
   - Open a PR → TFE automatically runs a **remote `plan`** and posts the result as a **PR check**.
   - Merge to main → TFE queues an **`apply`** that waits for **manual approval** in the TFE UI (for prod).
   - Here TFE *replaces* the plan/apply logic in GitHub Actions/Jenkins — your CI may still run tests/lint, but Terraform runs in TFE.

2. **CI-driven (your pipeline calls TFE):** GitHub Actions/Jenkins triggers a run via the TFE API / `cloud` block, and TFE executes it remotely.

```hcl
# backend: run remotely in TFE/HCP Terraform instead of on the CI runner
terraform {
  cloud {
    organization = "my-org"
    workspaces { name = "app-prod" }
  }
}
```

**What TFE adds beyond plain CI + S3 state:**
- **Managed remote runs** — consistent, isolated plan/apply execution (no runner setup).
- **State management** — encrypted remote state, locking, versioning, and history built in (no S3+DynamoDB to run).
- **Policy as code** — **Sentinel** or **OPA** guardrails that can *block* a run (e.g., "no public S3," "prod DB must have `apply_immediately = false`," "deletion protection required"). This is the big enterprise differentiator.
- **Run approvals & RBAC** — mandatory approval gates, team permissions, full audit log.
- **Secrets/variables** — workspace-scoped variables and secure credential injection.
- **Cost estimation** and a **private module registry**.

**How to think about it:**

| Layer | Plain CI (Actions/Jenkins) | With TFE / HCP Terraform |
|-------|----------------------------|--------------------------|
| Where `plan`/`apply` run | On your CI runner | **Remotely in TFE** |
| State | You run S3 + DynamoDB | **Managed by TFE** |
| Policy guardrails | DIY (scripts, OPA in pipeline) | **Sentinel/OPA built in, can block runs** |
| Approvals/RBAC/audit | CI environment gates | **First-class in TFE** |
| Best for | Small/mid teams, full control | Larger orgs needing governance & compliance |

**In one line:** GitHub Actions/Jenkins are the **trigger and orchestration** (PR opened, merged); TFE is the **execution + governance engine** that actually runs the plan/apply with policy, state, and approvals. You can use CI **alone** (with S3 state), or CI **+ TFE** where CI triggers and TFE runs the Terraform with guardrails.

---

## Interview quick hits

- **Plan on PR, apply on merge** = GitOps for infra: review the *diff*, not just the code; main branch is the source of truth.
- **Same pattern, different host:** GitHub Actions (managed runners, `pull_request` vs `push` triggers, `environment` approval) vs Jenkins (`Jenkinsfile`, `changeRequest()` vs `branch 'main'`, `input` gate) — you operate Jenkins yourself.
- **Credentials:** prefer **OIDC** (short-lived) over stored cloud keys.
- **DB upgrades as code:** bump `engine_version` (+ `allow_major_version_upgrade`, new-family parameter group), review the plan, merge to apply — auditable and repeatable; watch for **replacement** diffs and use `apply_immediately = false`.
- **TFE/HCP Terraform** runs plan/apply **remotely** with **managed state, Sentinel/OPA policy, approvals, and RBAC** — CI triggers it; TFE executes and governs it.
