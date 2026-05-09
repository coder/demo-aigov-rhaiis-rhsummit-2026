# GitOps — Argo CD app-of-apps

[Red Hat OpenShift GitOps](https://docs.openshift.com/gitops/) (Argo CD) manages every cluster-side component of this demo. Terraform installs the operator and applies the **root Application** in `bootstrap/`, which discovers every `application.yaml` under `apps/` and fans out to:

| App | Sync wave | What it deploys |
|---|---|---|
| `sealed-secrets` | -1 | Bitnami Sealed Secrets controller. Decrypts `SealedSecret` CRs in `manifests/secrets/` into in-cluster `Secret`s. See [`docs/secrets.md`](../docs/secrets.md). |
| `platform-secrets` | 0 | Every `SealedSecret` CR committed under `manifests/secrets/` (currently `coder-secrets`, `coder-provisioner-key`). |
| `postgres` | 0 | CNPG `Cluster` CR (3 instances, multi-AZ via streaming replication) — auto-generates the `coder-app` Secret consumed by the Coder Helm chart |
| `gpu-stack` | 0 | NodeFeatureDiscovery instance + NVIDIA GPU operator `ClusterPolicy`. Drivers + device-plugin + GPU Feature Discovery roll out onto the g5.2xlarge GPU node provisioned by the installer's `gpu` compute pool. |
| `cert-manager` | 0 | ClusterIssuers (Let's Encrypt prod + staging) using DNS-01 over Route 53 with ambient IRSA credentials |
| `coder` | 1 | Coder Helm chart (latest RC) — control plane + AI Governance Add-On. Reads `coder-app/uri` for the Postgres URL, `coder-secrets` for GitHub OAuth (org `demo-rhsummit-users`). Internal provisioners disabled — see `coder-provisioner`. |
| `rhaiis` | 2 | RHAIIS / vLLM (CUDA build) Deployment + Service from `manifests/rhaiis/`. Image pulled with `redhat-pull-secret`; pod schedules on the GPU node via `nvidia.com/gpu.present=true` selector + `nvidia.com/gpu: 1` resource request. |
| `coder-routing` | 2 | OpenShift Route(s) for Coder with cert-manager-issued wildcard TLS + ingress wildcard policy patch |
| `coder-provisioner` | 2 | External Coder provisioner daemon (5 replicas) — runs all template builds. Reads `coder-provisioner-key/key` to auth against the Coder API. |
| `coder-observability` | 3 | Grafana + Prometheus + Loki + Coder dashboards (Helm chart from `helm.coder.com/observability`). Bundled dashboards include AI Bridge model-invocation metrics + Agent Boundaries (Agent Firewall) activity — the "every model call is governed and logged" booth visual. Route at `grafana.apps.cluster.<base_domain>`. |
| `coder-agents-config` | 5 | Bootstrap Job that calls `/api/experimental/chats/...` to register the Coder Agents (chatd) providers and the Bedrock Opus/Sonnet + RHAIIS Granite model lineup. Runs on every sync (`hook: Sync`, `BeforeHookCreation` delete policy). Uses the `coder-server` SA (Bedrock IRSA) and a Coder admin token from `coder-admin-token` SealedSecret. See [`manifests/coder-agents-config/`](../manifests/coder-agents-config/). |

### What's NOT in GitOps

**Agent Firewall config** is intentionally **not** managed here. Per [Coder docs](https://coder.com/docs/ai-coder/agent-firewall), the firewall config is **template-scoped** — `coder-templates/openshift-ai-gov/config.yaml` is bundled with the template, mounted into the workspace at `~/.config/coder_boundary/config.yaml` by a `coder_script` at workspace start, and pushed to live Coder by `.github/workflows/push-templates.yml`. Different templates can have different allowlists.

## Operator policy

This demo prefers **Red-Hat-certified, RH-supported operators** wherever Red Hat ships one. Subscriptions live in `operator/` and are applied by the cluster Terraform's bootstrap step:

| File | Source | Why |
|---|---|---|
| `openshift-gitops-subscription.yaml` | `redhat-operators` | Red Hat OpenShift GitOps (NOT upstream Argo CD operator) |
| `cert-manager-subscription.yaml` | `redhat-operators` | cert-manager Operator for Red Hat OpenShift (NOT upstream jetstack/cert-manager) |
| `nfd-subscription.yaml` | `redhat-operators` | Node Feature Discovery — Red Hat-engineered. Required by the NVIDIA GPU operator to detect GPU PCI devices on each node. |
| `cnpg-subscription.yaml` | `community-operators` | **Documented exception.** Red Hat does not ship a first-party in-cluster Postgres operator. CloudNativePG is the de facto Kubernetes-native Postgres operator (CNCF Sandbox) and is OpenShift-compatible. |
| `nvidia-gpu-operator-subscription.yaml` | `certified-operators` | **Documented exception.** NVIDIA-engineered, Red Hat-certified for OpenShift. Red Hat does not engineer their own GPU operator and explicitly directs OCP customers to NVIDIA's certified build for GPU support — see RH docs on [GPU architecture](https://docs.openshift.com/container-platform/4.21/architecture/nvidia-gpu-architecture-overview.html). |

Coder is a Red Hat partner and uses the partner pull-secret (the same `pull-secret.json` from console.redhat.com, tied to the partner subscription) for any RH-distributed image.

## Adding a new app

1. Drop a new file at `gitops/apps/<name>/application.yaml`
2. Commit + push to `main`
3. Argo CD root app picks it up on the next refresh

## Pre-requisites Argo CD won't manage for you

The cluster Terraform's bootstrap step creates a few in-cluster resources that Argo CD-managed apps reference but cannot create themselves:

| Resource | Where | Source |
|---|---|---|
| `cert-manager` SA annotation `eks.amazonaws.com/role-arn` | `cert-manager` namespace | `aws_iam_role.cert_manager` from `terraform/irsa.tf` |
| `coder` SA with `eks.amazonaws.com/role-arn` annotation | `coder` namespace | `aws_iam_role.coder_bedrock` from `terraform/irsa.tf` |
| `redhat-pull-secret` docker-registry Secret | `ocp-ai` namespace | `var.pull_secret_path` |
| OIDC provider + platform IAM roles | AWS IAM | `ccoctl aws create-all` (run by Terraform) |
| Sealed Secrets sealing key backup | operator's secure storage (1Password / Vault) | one-time, after `sealed-secrets` controller comes up — see [`docs/secrets.md`](../docs/secrets.md). Lose this key + lose the cluster = every secret has to be re-sealed from scratch. |

The `coder-app` Secret used by the Coder Helm chart for its Postgres URL is auto-generated by the CloudNativePG operator. `coder-secrets` (GitHub OAuth) and `coder-provisioner-key` are managed via SealedSecrets in `manifests/secrets/` — see [`docs/secrets.md`](../docs/secrets.md) for the rotation/seal workflow.

```bash
# Verify IRSA annotations
oc get sa cert-manager -n cert-manager -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'
oc get sa coder -n coder -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'

# Verify STS credentials on a platform component
oc get secrets -n openshift-image-registry installer-cloud-credentials \
  -o jsonpath='{.data.credentials}' | base64 -d
# Should show role_arn + web_identity_token_file (not access keys)
```

## Watching sync

```bash
oc get applications -n openshift-gitops -w
```

## Why GitOps and not pure Terraform?

This audience (Red Hat Summit 2026) expects to see Argo CD. The cluster apps live in Git, change is a `git push`, drift correction is automatic, and the visual sync graph is a great booth talking point. Terraform owns AWS + the OCP install + STS IRSA bootstrap only.
