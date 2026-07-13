# Jenkins

CI/CD notes and pipeline definitions.

## Layout

| Path | Purpose |
|------|---------|
| `docs/` | Concepts, pipeline syntax, agents, best practices |
| `pipelines/` | `Jenkinsfile` examples and shared library snippets |

## Docs

- [github-actions-vs-jenkins.md](docs/github-actions-vs-jenkins.md) — CI/CD tool comparison and how to choose

## Suggested topics for `docs/`

- Declarative vs scripted pipelines; `Jenkinsfile` anatomy
- Agents/nodes, stages, parallelism, `when` conditions
- Credentials and secrets management
- Shared libraries, reusable steps
- Integrations: Terraform plan/apply gates ([../terraform/](../terraform/)), Ansible deploys ([../ansible/](../ansible/)), DB migrations ([../databases/](../databases/))
- Webhooks, multibranch pipelines, artifact handling

---

**See also:** [../README.md](../README.md)
