# Terraform

Infrastructure-as-Code notes and reusable modules.

## Layout

| Path | Purpose |
|------|---------|
| `docs/` | Concepts, workflow, state management, best practices |
| `modules/` | Reusable, versioned Terraform modules |

## Docs

- [cicd-plan-apply.md](docs/cicd-plan-apply.md) — plan-on-PR / apply-on-merge in GitHub Actions & Jenkins, RDS/Aurora upgrades as code, and where TFE fits

## Suggested topics for `docs/`

- Core workflow (`init` / `plan` / `apply` / `destroy`) and how `plan` is read
- State management: remote backends (S3 + DynamoDB lock), workspaces, `terraform state` surgery
- Module design: inputs/outputs, composition, versioning
- Provisioning patterns, `for_each` vs `count`, `depends_on`
- Secrets handling, drift detection, `import`
- CI/CD integration (plan on PR, apply on merge) — see [../jenkins/](../jenkins/)

---

**See also:** [../README.md](../README.md)
