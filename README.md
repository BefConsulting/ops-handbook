# Ops Handbook

A personal reference for operations and platform engineering: notes, study guides, and runnable artifacts across databases, infrastructure-as-code, configuration management, and CI/CD.

Each section follows the same pattern: a `docs/` folder for concepts and best practices, plus folders holding runnable artifacts (scripts, modules, playbooks, pipelines).

## Sections

| Section | Focus | Contents |
|---------|-------|----------|
| [databases/](databases/) | PostgreSQL administration & reliability | `docs/` guides, `lab/` EXPLAIN lab, `scripts/` monitoring SQL |
| [terraform/](terraform/) | Infrastructure as Code | `docs/`, reusable `modules/` |
| [ansible/](ansible/) | Configuration management | `docs/`, `playbooks/` |
| [jenkins/](jenkins/) | CI/CD pipelines | `docs/`, `pipelines/` |

## Layout

```
ops-handbook/
├── README.md
├── databases/
│   ├── README.md
│   ├── docs/         # internals, performance, WAL, HA/DR, Patroni
│   ├── lab/          # EXPLAIN practice DB + scenarios
│   └── scripts/      # ready-to-run monitoring SQL
├── terraform/
│   ├── docs/
│   └── modules/
├── ansible/
│   ├── docs/
│   └── playbooks/
└── jenkins/
    ├── docs/
    └── pipelines/
```

## Status

| Section | State |
|---------|-------|
| databases | Populated — guides, lab, and monitoring scripts |
| terraform | Scaffolded — ready for content |
| ansible | Scaffolded — ready for content |
| jenkins | Scaffolded — ready for content |

Start with [databases/README.md](databases/README.md).

## Interview prep

[prep.md](prep.md) — a role-focused study guide mapping required skills (PostgreSQL internals, HA/failover, performance, PITR, observability, distributed systems, Linux, IaC, security) to talking points, likely questions, and links into this handbook.
