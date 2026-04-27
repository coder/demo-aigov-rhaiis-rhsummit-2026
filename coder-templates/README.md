# coder-templates/

Coder workspace templates pushed to the live Coder instance by the
`.github/workflows/push-templates.yml` workflow on every change to this
directory.

## Conventions

- One subdirectory per template: `<template-name>/`
- Each template has:
  - `main.tf` — Coder Terraform (`coder/coder` provider)
  - `README.md` — what the template does, who it's for, env vars / params
  - `images/` (optional) — Dockerfiles for the workspace base images, built and pushed to ECR by `.github/workflows/build-images.yml`

## Pushing a template manually

```bash
cd coder-templates/openshift-ai-gov
coder login https://coder.<your-cluster-fqdn>
coder templates push openshift-ai-gov \
  --directory . \
  --variable namespace=coder-workspaces \
  --yes
```

## Pushing via GitHub Actions

Required GH secrets (set once with `gh secret set`):
- `CODER_URL` — the Coder instance URL (from `terraform output -raw coder_url`)
- `CODER_SESSION_TOKEN` — Coder session token (created via `coder tokens create` after login)

Required GH variable:
- `AWS_ROLE_ARN` — ARN of the GHA OIDC role (from `terraform output -raw github_actions_role_arn`)

The workflow runs on push to `main` when `coder-templates/**` changes.
