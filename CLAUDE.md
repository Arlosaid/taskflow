# TaskFlow

Portfolio project for practicing production-grade delivery: a Python application with
background workers, deployed to AWS through infrastructure as code and a CI/CD pipeline.
Built in phases — see `docs/roadmap.md` for what is done and what comes next.

The guiding rule for the whole project: **if it isn't in the pipeline, it doesn't exist.**
No `docker push` from a laptop, no secrets typed into the console, no `terraform apply` from
a workstation once CI exists (bootstrap and the OIDC role are the two documented exceptions).

## Layout

| Path | Contains |
|---|---|
| `app/` | main application (not started) |
| `worker/` | background processes (not started) |
| `infra/bootstrap/` | account-level, applied by hand: state bucket + GitHub OIDC provider |
| `infra/modules/` | reusable Terraform modules |
| `infra/envs/dev/` | the dev environment, consumes modules |
| `k8s/` | placeholder; the project targets ECS Fargate, not Kubernetes |
| `docs/roadmap.md` | the plan, with progress checkboxes |
| `docs/bitacora.md` | learning log — why each decision was made (in Spanish) |

## State of play

Working: the Terraform state backend (S3, versioned, encrypted, native lockfile) and the
account-level GitHub OIDC provider. The `github-oidc` module is applied: roles
`taskflow-dev-github-plan` (read-only, assumable from pull requests) and
`taskflow-dev-github-deploy` (assumable from main and the dev/prod environments) exist in AWS.
The federation is verified end to end: a workflow assumed the deploy role and got temporary
credentials with no stored secrets.

Not built yet: any CI workflow, any workload infrastructure (VPC/ECR/ECS/RDS), the
application itself, tests, Dockerfile, migrations.

## Conventions

- Terraform and code comments in English; `docs/bitacora.md` in Spanish.
- Comments explain **why**, not what. The existing files in `infra/bootstrap/main.tf` are the
  reference for tone — match them.
- Modules never declare a `provider` or `backend` block; they receive both from the caller.
- Checkov suppressions are inline and always carry a reason:
  `#checkov:skip=CKV_AWS_145:SSE-S3 is intentional for this low-cost state bucket.`
- Terraform provider pinned at `~> 6.0`, `required_version >= 1.11`, in every directory.
- Conventional commits (`feat:`, `fix:`, `chore:`), one commit per roadmap sub-step.
- This project deliberately does **not** use ADRs; decisions are recorded in `docs/bitacora.md`.

## Commands

```bash
export TF_VAR_aws_profile=taskflow-dev   # required locally; unset in CI, where OIDC supplies creds

cd infra/envs/dev && terraform init && terraform plan
pre-commit run --all-files
terraform fmt -check -recursive
```

## Gotchas worth knowing before touching anything

- `infra/bootstrap/` uses a **local** backend on purpose. It is the chicken-and-egg root: it
  creates the bucket every other environment stores state in. Applied by hand, rarely.
- `var.aws_profile` must default to the `null` literal, **never** the string `"null"` or `""`.
  Only the literal makes the AWS provider fall back to the standard credential chain in CI.
- The backend uses `use_lockfile = true` (S3-native locking, no DynamoDB table). Consequence:
  even a read-only `terraform plan` needs `s3:PutObject`/`s3:DeleteObject` on
  `<env>/terraform.tfstate.tflock`.
- `aws_iam_openid_connect_provider` is unique per AWS account. It lives in bootstrap so that
  no per-environment state ever tries to own it. **IAM role names are account-global too** —
  every role name must carry the environment (`taskflow-dev-...`) or a second environment in
  the same account will collide.
- **This repo uses GitHub's immutable subject claims.** The OIDC `sub` claim is
  `repo:OWNER@OWNER-ID/REPO@REPO-ID:<context>`, not the classic `repo:OWNER/REPO:<context>`.
  GitHub applies this format by default to repositories created after 2026-07-15. Trust policy
  conditions built from the plain `owner/repo` string will silently never match. Always take the
  literal subject from a decoded token rather than assembling it from the repo name.
- The `plan` and `deploy` roles must never share a policy document. `plan` gets `GetObject` on
  the state plus `PutObject`/`DeleteObject` on the `.tflock` only; `deploy` gets write access to
  the state itself. Sharing the document silently gives a pull request the ability to corrupt
  state, which defeats the reason the two roles exist.

## Working with the user

Spanish. They write the code themselves and want to understand each piece — give
step-by-step instructions with the reasoning, not finished files to paste. Keep token use
low: go straight to named paths instead of exploring the repo.
