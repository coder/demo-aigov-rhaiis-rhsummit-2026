# GitOps — Argo CD app-of-apps

[Red Hat OpenShift GitOps](https://docs.openshift.com/gitops/) (Argo CD) manages every cluster-side component of this demo. Terraform installs the operator and applies the **root Application** in `bootstrap/`, which discovers every `application.yaml` under `apps/` and fans out to:

| App | Sync wave | What it deploys |
|---|---|---|
| `sealed-secrets` | -1 | Bitnami Sealed Secrets controller. Decrypts `SealedSecret` CRs in `manifests/secrets/` into in-cluster `Secret`s. See [`docs/secrets.md`](../docs/secrets.md). |
| `cluster-config` | -2 | Cluster-scoped CRs: `Scheduler/cluster` (`mastersSchedulable: true`), `OAuth/cluster` (GitHub IdP for OpenShift login, scoped to `demo-rhsummit-users` org), `GroupSync` (redhat-cop CR mapping `admin` team → cluster-admin Group), and the corresponding `ClusterRoleBinding`. |
| `group-sync-operator` | 0 | OLM Subscription + OperatorGroup (OwnNamespace) for `redhat-cop/group-sync-operator`. Pairs with `cluster-config`'s GroupSync CR to keep the OpenShift Group in sync with the GitHub team. |
| `platform-secrets` | 0 | Every `SealedSecret` CR under `manifests/secrets/`: `coder-secrets`, `coder-provisioner-key`, `coder-admin-token`, `secret-postgres`, `grafana-github-oauth`, `ghcr-pull`, `github-oauth-client-secret`, `github-group-sync-token`. |
| `postgres` | 0 | CNPG `Cluster` CR (3 instances, multi-AZ via streaming replication) — auto-generates the `coder-app` Secret consumed by the Coder Helm chart |
| `gpu-stack` | 0 | NodeFeatureDiscovery instance + NVIDIA GPU operator `ClusterPolicy`. Drivers + device-plugin + GPU Feature Discovery roll out onto the GPU nodes (g5.2xlarge A10G + g6e.2xlarge L40S — both labeled with `nvidia.com/gpu.product=...` once drivers come up). |
| `cert-manager` | 0 | ClusterIssuers (Let's Encrypt prod + staging) using DNS-01 over Route 53 with ambient IRSA credentials |
| `coder` | 1 | Coder Helm chart **2.33.1** — control plane + AI Bridge (env vars `CODER_AIBRIDGE_*`, endpoints `/api/v2/aibridge/{anthropic,openai}`). Reads `coder-app/uri` for Postgres, `coder-secrets` for GitHub OAuth + central `openai-api-key`. Internal provisioners disabled — see `coder-provisioner`. |
| `rhaiis` | 2 | vLLM Deployment + Service from `manifests/rhaiis/`. Pinned to `nvidia.com/gpu.product=NVIDIA-L40S` so it lands on the L40S node from `manifests/machinesets/gpu-l40s.yaml`. Currently serves `Qwen/Qwen2.5-Coder-32B-Instruct-AWQ` with `--tool-call-parser hermes`. |
| `coder-routing` | 2 | OpenShift Route(s) for Coder with cert-manager-issued wildcard TLS + ingress wildcard policy patch |
| `coder-provisioner` | 2 | External Coder provisioner daemon (5 replicas) — runs all template builds. Reads `coder-provisioner-key/key` to auth against the Coder API. |
| `coder-workspaces` | 2 | `coder-workspaces` namespace + cross-namespace Role/RoleBinding granting the `coder-server` SA permission to create/delete workspace Pods + PVCs in this namespace + `ghcr-pull` image-pull secret reference. |
| `observability` | 3 | Grafana + Prometheus + Loki + Coder dashboards (Helm chart from `helm.coder.com/observability`). Bundled dashboards include AI Bridge model-invocation metrics + Agent Boundaries activity. Route at `grafana.apps.cluster.<base_domain>` with GitHub OAuth (`role_attribute_path` maps `admin` team → Grafana Admin). |
| `coder-agents-config` | 5 | Bootstrap Job that calls `/api/experimental/chats/...` to register the Coder Agents (chatd) providers and the **explicit-allowlist** Bedrock model set + RHAIIS-hosted Qwen. Runs on every sync (`hook: Sync`, `BeforeHookCreation` delete policy). Uses the `coder-server` SA (Bedrock IRSA) and the `coder-admin-token` SealedSecret. See [`manifests/coder-agents-config/`](../manifests/coder-agents-config/). |

### What's NOT in GitOps

**MachineSets (compute pools)** are intentionally **not** Argo-managed. The original A10G `g5.2xlarge` MachineSet was provisioned at install-time by `openshift-install` from `terraform/install-config.yaml.tftpl`'s compute pool config. The newer L40S `g6e.2xlarge` MachineSet is checked in at `manifests/machinesets/gpu-l40s.yaml` for record-keeping but applied directly via `oc apply -f` (not through Argo). Backout is `oc scale --replicas=0` then `oc delete machineset/...`.

**Agent Firewall config** is currently NOT shipped in either of the two `-ocp` templates (`ai-dev-ocp` relies on AI Bridge for governance; `agents-dev-ocp` relies on chatd's server-side execution model). If/when an Agent Firewall narrative is added back, its config would be template-scoped per [Coder docs](https://coder.com/docs/ai-coder/agent-firewall) and pushed by `.github/workflows/push-templates.yml`.

## Operator policy

This demo prefers **Red-Hat-certified, RH-supported operators** wherever Red Hat ships one. Subscriptions live in `operator/` and are applied by the cluster Terraform's bootstrap step:

| File | Source | Why |
|---|---|---|
| `openshift-gitops-subscription.yaml` | `redhat-operators` | Red Hat OpenShift GitOps (NOT upstream Argo CD operator) |
| `cert-manager-subscription.yaml` | `redhat-operators` | cert-manager Operator for Red Hat OpenShift (NOT upstream jetstack/cert-manager) |
| `nfd-subscription.yaml` | `redhat-operators` | Node Feature Discovery — Red Hat-engineered. Required by the NVIDIA GPU operator to detect GPU PCI devices on each node. |
| `cnpg-subscription.yaml` | `community-operators` | **Documented exception.** Red Hat does not ship a first-party in-cluster Postgres operator. CloudNativePG is the de facto Kubernetes-native Postgres operator (CNCF Sandbox) and is OpenShift-compatible. |
| `nvidia-gpu-operator-subscription.yaml` | `certified-operators` | **Documented exception.** NVIDIA-engineered, Red Hat-certified for OpenShift. Red Hat does not engineer their own GPU operator and explicitly directs OCP customers to NVIDIA's certified build for GPU support — see RH docs on [GPU architecture](https://docs.openshift.com/container-platform/4.21/architecture/nvidia-gpu-architecture-overview.html). |
| `gitops/apps/sealed-secrets/application.yaml` | Bitnami chart on GHCR mirror | Bitnami Sealed Secrets controller. We use the Bitnami Helm chart (no operator) and override the image to the GHCR mirror to dodge Docker Hub rate limits; SCC compliance is handled via `podSecurityContext.enabled: false` per decision §19. |
| `gitops/apps/group-sync-operator/application.yaml` | `community-operators` | **Documented exception.** redhat-cop/group-sync-operator. Reconciles the GitHub `demo-rhsummit-users:admin` team into a Kubernetes Group bound to `cluster-admin`; OwnNamespace mode (per the operator's docs) so the OperatorGroup targets only the operator's own namespace. |

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

The `coder-app` Secret used by the Coder Helm chart for its Postgres URL is auto-generated by the CloudNativePG operator. The eight sealed secrets in `manifests/secrets/` (`coder-secrets`, `coder-provisioner-key`, `coder-admin-token`, `secret-postgres`, `grafana-github-oauth`, `ghcr-pull`, `github-oauth-client-secret`, `github-group-sync-token`) cover the GitHub OAuth identities, the Coder API tokens, the Grafana datasource credentials, and the GHCR pull secret — see [`docs/secrets.md`](../docs/secrets.md) for the rotation/seal workflow.

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
