# GitHub Actions vs Jenkins

A practical comparison of the two most common CI/CD tools — how each works, where each wins, and how to choose.

**See also:** [../README.md](../README.md) · [../../terraform/](../../terraform/) · [../../ansible/](../../ansible/)

---

## TL;DR

- **GitHub Actions** — CI/CD **built into GitHub**. YAML workflows in your repo, managed runners, a huge marketplace of reusable actions. Best when your code lives on GitHub and you want zero infrastructure to maintain.
- **Jenkins** — a **self-hosted, open-source automation server**. Infinitely flexible via ~1,800 plugins, runs anywhere, you own it end to end. Best for complex/legacy/on-prem pipelines and full control.

**Rule of thumb:** for most **new, cloud-native, GitHub-hosted** projects → **GitHub Actions**. For **large enterprises, on-prem/regulated environments, or highly customized pipelines** → **Jenkins** (or a hybrid).

---

## What each one is

| | GitHub Actions | Jenkins |
|--|----------------|---------|
| Type | SaaS CI/CD native to GitHub | Self-hosted automation server (Java) |
| Config | YAML in `.github/workflows/` | `Jenkinsfile` (Groovy) or UI jobs |
| Hosting | GitHub-managed runners (or self-hosted) | You host the controller + agents |
| Setup | Nothing to install — works with the repo | Install, patch, secure, scale yourself |
| Reuse | Marketplace **actions** | ~1,800 **plugins** + shared libraries |
| Cost model | Per-minute billing (free tier); self-hosted runners free | Free software; you pay for infra + ops time |

---

## How each models a pipeline

**GitHub Actions** — event-driven workflows triggered by repo events (`push`, `pull_request`, `schedule`, `workflow_dispatch`):

```yaml
# .github/workflows/ci.yml
name: CI
on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20 }
      - run: npm ci
      - run: npm test
```

**Jenkins** — a declarative (or scripted) pipeline in a `Jenkinsfile` checked into the repo:

```groovy
// Jenkinsfile
pipeline {
  agent { label 'linux' }
  stages {
    stage('Install') { steps { sh 'npm ci' } }
    stage('Test')    { steps { sh 'npm test' } }
  }
  post {
    always { junit 'reports/*.xml' }
  }
}
```

Both support stages, parallelism, matrix builds, conditionals, artifacts, and secrets — the difference is *where they run* and *how much you operate*.

---

## Head-to-head

| Dimension | GitHub Actions | Jenkins |
|-----------|----------------|---------|
| **Setup & maintenance** | Zero — fully managed | You install, upgrade, secure, back up |
| **Flexibility** | High, within GitHub's model | Highest — plugins do almost anything |
| **Ecosystem** | Marketplace actions (curated, versioned) | ~1,800 plugins (powerful but variable quality) |
| **Scalability** | Auto-scaled managed runners | Scale agents yourself (static, Docker, K8s) |
| **Cost** | Pay per build minute; free for public/small | Free tool, but real cost is infra + engineer time |
| **Security** | GitHub-managed; OIDC to cloud; scoped `GITHUB_TOKEN` | You own hardening, plugin CVEs, credential store |
| **Portability** | Tied to GitHub | Runs anywhere, any SCM (Git, SVN, on-prem) |
| **Learning curve** | Low — YAML, quick start | Steeper — Groovy, plugins, admin |
| **Best for** | GitHub repos, cloud-native, OSS, small→mid teams | Enterprise, on-prem, regulated, complex/legacy |

---

## Strengths & weaknesses

**GitHub Actions**
- Pros: no infrastructure, tight GitHub integration (PR checks, statuses, environments), huge reusable-action marketplace, fast onboarding, OIDC to AWS/GCP/Azure (no long-lived cloud keys), matrix builds out of the box.
- Cons: locked to GitHub, per-minute cost can add up for heavy CI, less control over the runner environment (unless self-hosted), complex/enterprise workflows can be awkward, debugging is log-only.

**Jenkins**
- Pros: runs anywhere and with any SCM, virtually unlimited flexibility via plugins/shared libraries, no vendor lock-in, mature for complex multi-stage/enterprise pipelines, self-hosted control for compliance/air-gapped networks.
- Cons: **you own the ops** (upgrades, backups, HA, scaling), plugin sprawl and security patching, steeper Groovy learning curve, UI feels dated, static agents can waste resources.

---

## When to choose which

**Choose GitHub Actions when:**
- Your code is on **GitHub** and you want CI/CD with minimal setup.
- You're **cloud-native** / greenfield and value managed infrastructure.
- Small-to-medium team; you'd rather not run a CI server.
- You want native PR gating, environments, and OIDC to cloud providers.

**Choose Jenkins when:**
- You need **on-prem / air-gapped / regulated** builds or non-GitHub SCM.
- Pipelines are **complex, highly customized, or legacy**, needing specific plugins.
- You want **full control** over runners, tooling, and no per-minute billing.
- A large org already has Jenkins expertise and shared libraries.

**Hybrid** is common: Jenkins for heavy/on-prem orchestration (e.g., Terraform apply gates, DB migrations), GitHub Actions for fast PR checks and lint/test — triggered from the same repo.

---

## Which is preferable?

There's no universal winner — it depends on context:

- **For most new projects today, GitHub Actions is preferable**: it removes an entire class of operational toil (no server to run, patch, scale, or secure), integrates natively with the code, and gets teams shipping fastest. If you're already on GitHub, it's the pragmatic default.
- **Jenkins is preferable when you need control, portability, or depth** GitHub Actions can't give: on-prem/regulated environments, non-GitHub source control, or intricate pipelines that lean on specific plugins and shared libraries.

A useful way to frame it in an interview: *"GitHub Actions trades flexibility and control for zero maintenance and native integration — great for cloud-native, GitHub-hosted teams. Jenkins trades operational overhead for maximum flexibility and portability — better for enterprise, on-prem, or highly customized pipelines. I'd default to GitHub Actions for new GitHub-based work and reach for Jenkins when control, compliance, or complex legacy pipelines demand it."*

---

## Interview quick hits

- **Core difference:** GitHub Actions = managed, GitHub-native, YAML; Jenkins = self-hosted, plugin-driven, `Jenkinsfile` (Groovy).
- **Maintenance:** Actions has none (managed runners); Jenkins is yours to operate (upgrades, plugins, HA, backups).
- **Lock-in vs portability:** Actions ties you to GitHub; Jenkins runs anywhere with any SCM.
- **Secrets to cloud:** Actions supports **OIDC** (no static cloud keys) — a strong security point.
- **Cost:** Actions bills per build minute; Jenkins is "free" but costs infra + engineer time.
- **Default recommendation:** GitHub Actions for new/cloud-native GitHub projects; Jenkins for enterprise/on-prem/complex; hybrid is legitimate.
