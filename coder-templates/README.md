# coder-templates/

Coder workspace templates pushed to the live Coder instance by the
`.github/workflows/push-templates.yml` workflow on every change to this
directory.

## Conventions

- One subdirectory per template: `<template-name>/`
- Each template has:
  - `main.tf` — Coder Terraform (`coder/coder` provider)
  - `README.md` — what the template does, who it's for, env vars / params
  - `images/` (optional) — Dockerfiles for the workspace base images, built and pushed to GHCR by `.github/workflows/build-images.yml` using the workflow's built-in `GITHUB_TOKEN`

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

Optional GH variable:
- `IMAGE_REGISTRY` — overrides the default `ghcr.io/coder/demo-aigov-rhaiis-rhsummit-2026` registry path (use this if you fork the repo into another GH org)

The workflow runs on push to `main` when `coder-templates/**` changes. No AWS credentials are required — image pushes use the workflow's built-in `GITHUB_TOKEN`.
