# manifests/coder-agents-config/

Kubernetes manifests for the **`coder-agents-config`** Argo CD
Application — a one-shot Job that bootstraps the Coder Agents (chatd)
providers and model-configs every time it syncs.

What lands in chatd after this Job runs:

| Provider | Connection | Audit |
|---|---|---|
| `bedrock` (or `anthropic` via AI Bridge — env-toggleable) | IRSA on the `coder-server` SA → AWS Bedrock | chatd usage rows + Bedrock CloudTrail |
| `openai` (RHAIIS) | Direct in-cluster: `http://vllm.ocp-ai.svc.cluster.local:8000/v1` | chatd usage rows |

| Models | Source |
|---|---|
| Every Anthropic Opus + Sonnet inference profile in the configured AWS region | `aws bedrock list-inference-profiles` at Job runtime |
| `ibm-granite/granite-3.1-8b-instruct` | Hardcoded; matches what RHAIIS is serving |

The newest Opus profile is set as `is_default: true`. Each Bedrock
model gets two entries — one with `provider_options.effort: "max"`
(extended thinking) and one without — so users can flip in the UI
without an admin round-trip.

## Files

| File | Purpose |
|---|---|
| `configmap.yaml` | **Generated** from `scripts/coder-agents-provider-model-config.sh` by `scripts/render-coder-agents-configmap.sh`. Contains the script the Job runs. |
| `job.yaml` | The Job itself. Sync hook (`argocd.argoproj.io/hook: Sync`), wave 5, runs as the `coder-server` SA so it inherits the Bedrock IRSA role. |

## Updating the script

The script lives canonically at `scripts/coder-agents-provider-model-config.sh`
so you can also run it from a laptop (`CODER_URL=… CODER_TOKEN=… ./scripts/…`).

After editing the script:

```bash
./scripts/render-coder-agents-configmap.sh
git add scripts/coder-agents-provider-model-config.sh \
        manifests/coder-agents-config/configmap.yaml
git commit -m "chore(coder-agents-config): update provider/model bootstrap"
git push
```

Argo CD picks up both files; the next sync recreates the Job with the
new ConfigMap.

## Pre-requisites

1. **Tooling image** — `ghcr.io/coder/demo-aigov-rhaiis-rhsummit-2026/agents-config-tools:latest`
   built by `.github/workflows/build-images.yml` (UBI9-minimal + aws CLI
   + jq + curl + bash).
2. **`coder-admin-token` SealedSecret** — owner-role Coder API token,
   sealed and committed at `manifests/secrets/coder-admin-token.yaml`.
   See [`docs/secrets.md`](../../docs/secrets.md) for the seal workflow.
3. **`coder-server` ServiceAccount IRSA annotation** — already present
   via `gitops/apps/coder/application.yaml`
   (`eks.amazonaws.com/role-arn: …/cluster-coder-bedrock`). The Job
   re-uses this SA so no extra IAM wiring is needed.

## Verification

```bash
oc -n coder logs job/coder-agents-config -f
oc -n coder get job coder-agents-config -o yaml | grep -A2 conditions
```

In the UI: **https://coder.apps.<cluster-domain>/admin/ai-governance**
should show the Bedrock + RHAIIS providers and every Opus/Sonnet/Granite
model entry.
