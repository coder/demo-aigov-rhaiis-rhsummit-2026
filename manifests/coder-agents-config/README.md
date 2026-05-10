# manifests/coder-agents-config/

Kubernetes manifests for the **`coder-agents-config`** Argo CD
Application — a one-shot Job that bootstraps the Coder Agents (chatd)
providers and model-configs every time it syncs.

What lands in chatd after this Job runs:

| Provider | Connection | Audit |
|---|---|---|
| `bedrock` (or `anthropic` via AI Bridge — env-toggleable) | IRSA on the `coder-server` SA → AWS Bedrock | chatd usage rows + Bedrock CloudTrail |
| `openai-compat` (RHAIIS) | Direct in-cluster: `http://vllm.ocp-ai.svc.cluster.local:8000/v1` | chatd usage rows |

(The provider type is `openai-compat`, NOT `openai` — chatd treats them
as distinct types. `openai-compat` is the right type for any vLLM /
LM Studio / Ollama-style upstream.)

| Models | Source |
|---|---|
| 7 explicitly-allowlisted `us.anthropic.*` cross-region inference profile IDs | Hardcoded `ALL_IDS` in `scripts/coder-agents-provider-model-config.sh` (verified subscribed; see `bedrock-model-sub.md`) |
| `Qwen/Qwen2.5-Coder-32B-Instruct-AWQ` | Hardcoded `RHAIIS_MODEL_ID`; matches what RHAIIS is serving |

The Bedrock allowlist (in script order, default first):

```
us.anthropic.claude-sonnet-4-20250514-v1:0   ← demo primary, default
us.anthropic.claude-sonnet-4-6
us.anthropic.claude-sonnet-4-5-20250929-v1:0
us.anthropic.claude-opus-4-7
us.anthropic.claude-opus-4-6-v1
us.anthropic.claude-opus-4-5-20251101-v1:0
us.anthropic.claude-opus-4-1-20250805-v1:0
```

`is_default: true` is set on `claude-sonnet-4-20250514-v1:0` (cheapest of
the verified-subscribed set, plenty for booth Q&A). Override at deploy
time by exporting `DEFAULT_MODEL_ID=<other-profile-id>` before running
the script.

Each Bedrock model is registered ONCE — the previous "(Extended Thinking)"
dual-entry pattern was dropped (would have produced too many dropdown
options). Users who want extended thinking toggle
`provider_options.bedrock.effort` via the admin UI.

Why an explicit allowlist instead of dynamic discovery: see
[`docs/decisions.md`](../../docs/decisions.md) §25 — `aws bedrock list-inference-profiles`
returns ~16 Anthropic profiles, but only a subset is invocable. Models
that are listed but not Marketplace-subscribed produce a 403 the first
time chatd invokes them, which surfaces in the UI as a generic
"Authentication failed."

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
