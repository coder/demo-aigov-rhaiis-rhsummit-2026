# GitOps — Argo CD app-of-apps

[Red Hat OpenShift GitOps](https://docs.openshift.com/gitops/) (Argo CD) manages every cluster-side component of this demo. Terraform installs the operator and applies the **root Application** in `bootstrap/`, which discovers every `application.yaml` under `apps/` and fans out to:

| App | Sync wave | What it deploys |
|---|---|---|
| `cert-manager` | 0 | ClusterIssuers (Let's Encrypt prod + staging) using DNS-01 over Route 53 |
| `coder` | 1 | Coder Helm chart (latest RC) — control plane + provisioner + AI Governance Add-On |
| `rhaiis` | 2 | RHAIIS / vLLM Deployment + Service from `manifests/rhaiis/` |
| `coder-routing` | 2 | OpenShift Route(s) for Coder with cert-manager-issued wildcard TLS + ingress wildcard policy patch |
| `agent-firewalls` | 3 | Coder Agent Firewalls rules ConfigMap from `manifests/agent-firewalls/` |

## Operator policy

This demo uses **only Red-Hat-certified, RH-supported operators** wherever Red Hat ships one. We do not deploy upstream community variants when an RH-supported equivalent exists. Operator subscriptions live in `operator/`:

- `openshift-gitops-subscription.yaml` — Red Hat OpenShift GitOps (Argo CD)
- `cert-manager-subscription.yaml` — cert-manager Operator for Red Hat OpenShift (NOT upstream jetstack/cert-manager)

Coder is a Red Hat partner and uses the partner pull-secret (the same `pull-secret.json` from console.redhat.com, tied to the partner subscription) for any RH-distributed image.

## Adding a new app

1. Drop a new file at `gitops/apps/<name>/application.yaml`
2. Commit + push to `main`
3. Argo CD root app picks it up on the next refresh

## Pre-requisites Argo CD won't manage for you

Three secrets must exist before sync — none are in Git for obvious reasons. Two are created by you; one is created automatically by the cluster Terraform's bootstrap step.

```bash
# 1. Coder DB URL (RDS Aurora endpoint + password from terraform output)
#    YOU create this once after `terraform apply`:
oc create namespace coder 2>/dev/null || true
oc create secret generic coder-db-url \
  -n coder \
  --from-literal=url='postgres://coder:<RDS_PASSWORD>@<RDS_ENDPOINT>:5432/coder?sslmode=require'

# 2. Red Hat partner pull secret for RHAIIS image
#    YOU create this once with your partner pull-secret JSON
#    (https://console.redhat.com/openshift/install/pull-secret):
oc create namespace ocp-ai 2>/dev/null || true
oc create secret docker-registry redhat-pull-secret \
  --docker-server=registry.redhat.io \
  --docker-username='<RH_USERNAME>' \
  --docker-password='<RH_TOKEN>' \
  --namespace=ocp-ai

# 3. Route 53 credentials for cert-manager DNS-01 challenges
#    AUTOMATICALLY created by `terraform apply` (cluster TF bootstrap step).
#    No action needed unless you're running outside of the cluster TF flow.
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
