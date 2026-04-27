# GitOps — Argo CD app-of-apps

[Red Hat OpenShift GitOps](https://docs.openshift.com/gitops/) (Argo CD) manages every cluster-side component of this demo. Terraform installs the operator and applies the **root Application** in `bootstrap/`, which discovers every `application.yaml` under `apps/` and fans out to:

| App | Sync wave | What it deploys |
|---|---|---|
| `external-secrets` | -1 | ClusterSecretStore pointing at AWS Secrets Manager |
| `cert-manager` | 0 | ClusterIssuers (Let's Encrypt prod + staging) using DNS-01 over Route 53 |
| `coder` | 1 | Coder Helm chart (latest RC) — control plane + provisioner + AI Governance Add-On. ExternalSecret materializes `coder-db-url` at wave 0 within this app's tree. |
| `rhaiis` | 2 | RHAIIS / vLLM Deployment + Service from `manifests/rhaiis/`. ExternalSecret materializes `redhat-pull-secret` at wave 0 within this app's tree. |
| `coder-routing` | 2 | OpenShift Route(s) for Coder with cert-manager-issued wildcard TLS + ingress wildcard policy patch |
| `agent-firewalls` | 3 | Coder Agent Firewalls rules ConfigMap from `manifests/agent-firewalls/` |

## Operator policy

This demo prefers **Red-Hat-certified, RH-supported operators** wherever Red Hat ships one. Subscriptions live in `operator/`:

| File | Source | Why |
|---|---|---|
| `openshift-gitops-subscription.yaml` | `redhat-operators` | Red Hat OpenShift GitOps (NOT upstream Argo CD operator) |
| `cert-manager-subscription.yaml` | `redhat-operators` | cert-manager Operator for Red Hat OpenShift (NOT upstream jetstack/cert-manager) |
| `external-secrets-subscription.yaml` | `community-operators` | **Documented exception.** Red Hat does not ship a first-party External Secrets Operator. The RH-supported alternative for this use case is HashiCorp Vault on OpenShift, which is overkill for two demo secrets. ESO appears in several Red Hat validated-patterns docs (multicluster-gitops, AAP+AWS-Secrets-Manager) as the integration point for AWS Secrets Manager. |

Coder is a Red Hat partner and uses the partner pull-secret (the same `pull-secret.json` from console.redhat.com, tied to the partner subscription) for any RH-distributed image.

## Adding a new app

1. Drop a new file at `gitops/apps/<name>/application.yaml`
2. Commit + push to `main`
3. Argo CD root app picks it up on the next refresh

## Pre-requisites Argo CD won't manage for you

All cluster secrets are now **automatically created by the cluster Terraform's bootstrap step** — there are no manual `oc create secret` steps anymore.

The flow:

1. Cluster TF writes `coder-db-url` and `redhat-pull-secret` content into AWS Secrets Manager (`demo-aigov/coder-db-url`, `demo-aigov/redhat-pull-secret`)
2. Cluster TF creates two scoped IAM users (cert-manager → Route 53; ESO → Secrets Manager) with access keys
3. Cluster TF bootstrap injects three Kubernetes Secrets:
   - `route53-credentials` in the `cert-manager` namespace (cert-manager IAM keys)
   - `aws-secrets-manager-creds` in the `external-secrets` namespace (ESO IAM keys)
4. Argo CD applies the `ClusterSecretStore` (wave -1)
5. ExternalSecrets in the `coder` and `ocp-ai` namespaces (wave 0) cause ESO to materialize the actual `coder-db-url` and `redhat-pull-secret` Kubernetes Secrets from AWS Secrets Manager

If you ever need to inspect the secrets manually:

```bash
oc get secrets -n coder coder-db-url
oc get secrets -n ocp-ai redhat-pull-secret
oc get secrets -n external-secrets aws-secrets-manager-creds
oc get secrets -n cert-manager route53-credentials
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
