# Project: demo-aigov-rhaiis-rhsummit-2026

Booth demo for Coder + Red Hat at Red Hat Summit 2026. Deploys a governed agentic AI coding environment on OpenShift 4.21 using Terraform, GitOps (Argo CD app-of-apps), and Coder workspace templates.

## Architecture

- **Terraform** (`terraform/`) provisions AWS VPC, IAM, and runs `openshift-install create cluster` (IPI). A separate root (`terraform/prereqs/`) handles account-level prereqs (quotas, hosted zone, installer IAM).
- **GitOps** (`gitops/`) — Argo CD app-of-apps. `gitops/bootstrap/root-app.yaml` fans out to `gitops/apps/*/application.yaml`. Operator subscriptions live in `gitops/operator/`.
- **Manifests** (`manifests/`) — raw Kubernetes YAML referenced by Argo CD Applications. One subdirectory per app (postgres, cert-manager, coder, rhaiis, gpu-stack, observability).
- **Coder templates** (`coder-templates/`) — Terraform-defined workspace templates pushed to the live cluster by GH Actions.
- **Scripts** (`scripts/`) — bash utilities for quota bootstrapping, R53 delegation, smoke tests, and demo labels.

## Conventions

### Terraform (HCL)
- Terraform ≥1.7. No OpenTofu-only features.
- Heavy inline comments explaining *why*, not just *what*.
- Separate files: `versions.tf`, `providers.tf`, `variables.tf`, `outputs.tf`, `main.tf`, `locals.tf`, `network.tf`, `backend.tf`.
- Variables have full `description` strings. Use `validation {}` blocks for constraints.
- Use `null_resource` + `local-exec` for imperative steps (openshift-install, oc apply).
- No modules from external registries — everything is inline in this repo.
- State backend: S3 + DynamoDB (configured in `backend.tf`).

### Kubernetes / OpenShift YAML
- All resources use `app.kubernetes.io/name`, `app.kubernetes.io/component`, `app.kubernetes.io/part-of` labels.
- Namespaces are explicit in manifests (not inherited from Argo CD destination).
- Argo CD Applications use `syncPolicy.automated` with `prune: true` and `selfHeal: true`.
- Sync waves control ordering: operators first (wave -1), postgres (wave 0), coder (wave 1), rhaiis (wave 2).
- `ServerSideApply=true` and `CreateNamespace=true` in syncOptions.

### Operator policy
- Red Hat-certified operators only. Two documented exceptions: NVIDIA GPU operator (certified-operators source) and CloudNativePG (certified-operators source, EDB-engineered). Both have inline rationale in their subscription YAML.
- Never use upstream community operators when Red Hat ships an equivalent (e.g., use `openshift-gitops-operator` not `argocd-operator`; use `openshift-cert-manager-operator` not `cert-manager`).

### Manifest configuration
- Manifests use cluster-specific values (domain names, zone IDs) that are patched by `scripts/configure-manifests.sh` after `terraform apply`.
- The Argo CD root app is applied by the script (not terraform) to avoid race conditions.
- Workflow: `terraform apply` → `./scripts/configure-manifests.sh` → `git commit && push`.

### Scripts (bash)
- `set -euo pipefail` at the top.
- Use `#!/usr/bin/env bash` shebang.
- Inline help via `--help` flag or usage function.
- Scripts are executable (`chmod +x`).

### Commits
- Conventional commits: `feat(scope):`, `fix(scope):`, `docs(scope):`, `chore(scope):`.
- Scopes: `terraform`, `gitops`, `manifests`, `template`, `scripts`, `ci`, `docs`.

### GitHub Actions
- Workflows in `.github/workflows/`.
- `build-images.yml` — builds workspace base images → GHCR.
- `push-templates.yml` — pushes Coder templates to the live cluster on changes to `coder-templates/`.
- `sprint-ticket.yml` — booth demo flow: issue → workspace creation.

## Key decisions

- **No RDS** — CloudNativePG provides in-cluster Postgres so the demo is on-prem-portable.
- **No CPU fallback for RHAIIS** — GPU node is always present when cluster is up.
- **Compact 3-node converged cluster** — control-plane nodes are schedulable (`compute.replicas: 0`).
- **Lifecycle is destroy/apply, never ec2 stop** — OCP doesn't tolerate stop/start.
- **Demo simplicity over hardening** — no STIG/FIPS, no restricted-v2 SCC overrides, no air-gap config.

## Sensitive files (never commit)

- `.env` (use `.env.example` as template)
- `terraform.tfvars` (use `terraform.tfvars.example`)
- `.cluster/` directory (kubeconfig, kubeadmin password)
- `*.pem`, `*.key`, `secrets-data.yaml`

## Adding a new Argo CD app

1. Create `manifests/<app-name>/` with raw K8s YAML.
2. Create `gitops/apps/<app-name>/application.yaml` pointing at the manifests path.
3. Set appropriate `argocd.argoproj.io/sync-wave` annotation.
4. The root app auto-discovers it on next sync.

## Adding a new operator

1. Create `gitops/operator/<name>-subscription.yaml` with the OLM `Subscription` + `OperatorGroup` if needed.
2. Add a CRD wait loop in `terraform/main.tf`'s `gitops_bootstrap` provisioner.
3. Document the operator source and rationale inline in the subscription YAML.
