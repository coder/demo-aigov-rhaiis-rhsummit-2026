# GitOps — Argo CD app-of-apps

[Red Hat OpenShift GitOps](https://docs.openshift.com/gitops/) (Argo CD) manages every cluster-side component of this demo. Terraform installs the operator and applies the **root Application** in `bootstrap/`, which discovers every `application.yaml` under `apps/` and fans out to:

| App | Sync wave | What it deploys |
|---|---|---|
| `coder` | 1 | Coder Helm chart (latest RC) — control plane + provisioner + AI Governance Add-On |
| `rhaiis` | 2 | RHAIIS / vLLM Deployment + Service from `manifests/rhaiis/` |
| `agent-firewalls` | 3 | Coder Agent Firewalls rules ConfigMap from `manifests/agent-firewalls/` |

## Adding a new app

1. Drop a new file at `gitops/apps/<name>/application.yaml`
2. Commit + push to `main`
3. Argo CD root app picks it up on the next refresh

## Pre-requisites Argo CD won't manage for you

Two secrets must exist before sync — neither is in Git for obvious reasons:

```bash
# 1. Coder DB URL (RDS Aurora endpoint + password from terraform output)
oc create namespace coder 2>/dev/null || true
oc create secret generic coder-db-url \
  -n coder \
  --from-literal=url='postgres://coder:<RDS_PASSWORD>@<RDS_ENDPOINT>:5432/coder?sslmode=require'

# 2. Red Hat pull secret for RHAIIS image
oc create namespace ocp-ai 2>/dev/null || true
oc create secret docker-registry redhat-pull-secret \
  --docker-server=registry.redhat.io \
  --docker-username='<RH_USERNAME>' \
  --docker-password='<RH_TOKEN>' \
  --namespace=ocp-ai
```

## Watching sync

```bash
oc get applications -n openshift-gitops -w
```

Argo CD console URL — the OpenShift GitOps operator exposes it at:

```
https://openshift-gitops-server-openshift-gitops.apps.<cluster_fqdn>
```

## Why GitOps and not pure Terraform?

This audience (Red Hat Summit 2026) expects to see Argo CD. The cluster apps live in Git, change is a `git push`, drift correction is automatic, and the visual sync graph is a great booth talking point. Terraform owns AWS + the OCP install only.
