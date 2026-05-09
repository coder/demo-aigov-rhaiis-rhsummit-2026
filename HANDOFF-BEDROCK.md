# Handoff — 2026-05-08 (kiro session) → next session (Coder templates)

## What I did

### Bedrock IRSA — fully wired and verified

1. **Added SA annotation to Helm values** (`gitops/apps/coder/application.yaml`)
   - `serviceAccount.annotations.eks.amazonaws.com/role-arn: arn:aws:iam::342934376218:role/demo/cluster-coder-bedrock`
   - This makes the annotation persistent across Argo CD syncs (previously it was only applied by the Terraform bootstrap and got overwritten by selfHeal).

2. **Fixed the IAM role trust policy** (`scripts/fix-bedrock-irsa.sh`)
   - The role existed but had a stale trust policy (old `sts:AssumeRole` pattern from before the STS/IRSA refactor).
   - Updated to the correct OIDC web identity trust with both `:sub` and `:aud` conditions.
   - Bedrock invoke permissions: `InvokeModel`, `InvokeModelWithResponseStream`, `Converse`, `ConverseStream`, `ListFoundationModels`, `GetFoundationModel`, `ListInferenceProfiles`, `GetInferenceProfile` — all resources (`*`).

3. **Hardened Terraform** (`terraform/irsa.tf`)
   - Added `:aud = "sts.amazonaws.com"` condition to both cert-manager and coder-bedrock trust policies.

4. **Rolled the Coder pods** — the pod-identity-webhook now injects into every coder-server pod:
   - `AWS_ROLE_ARN=arn:aws:iam::342934376218:role/demo/cluster-coder-bedrock`
   - `AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token`
   - A projected `aws-iam-token` volume (audience: `sts.amazonaws.com`, 24h expiry)

5. **Fixed AWS SSO profile** — `sso_role_name` was `AdministratorAccess`, corrected to `AWSAdministratorAccess`. Config now in `~/.aws/config` (SSO-based, no static keys in credentials file).

### Verified end-to-end

From inside the cluster (pod with `serviceAccountName: coder-server`):
```
$ aws sts get-caller-identity
{
    "Arn": "arn:aws:sts::342934376218:assumed-role/cluster-coder-bedrock/botocore-session-..."
}

$ aws bedrock list-foundation-models --query "modelSummaries[?contains(modelId,'claude')].modelId"
anthropic.claude-sonnet-4-20250514-v1:0
anthropic.claude-opus-4-20250514-v1:0
anthropic.claude-3-5-haiku-20241022-v1:0
... (all Claude models available)
```

AI Bridge picks Bedrock up via the standard AWS SDK credential chain — no static keys, no env var config beyond what's already in the Helm values (`CODER_AIBRIDGE_ENABLED=true`, `AWS_REGION=us-east-1`).

### Coder Agents (chatd) provider + model bootstrap

A new GitOps app at `gitops/apps/coder-agents-config/` registers the
Bedrock + RHAIIS providers and model lineup with chatd via
`/api/experimental/chats/...`. Reference template was the k3s-infra
`coder-agents-provider-model-config.sh` script.

What's wired:

| Piece | Location |
|---|---|
| Canonical script | `scripts/coder-agents-provider-model-config.sh` (runnable from a laptop with `aws` + `jq` + `curl`) |
| ConfigMap renderer | `scripts/render-coder-agents-configmap.sh` — regenerates the configmap when the script changes |
| Tooling image | `coder-templates/images/agents-config-tools/Dockerfile` (UBI9-minimal + aws + jq + curl + bash); built by `.github/workflows/build-images.yml` |
| K8s Job | `manifests/coder-agents-config/job.yaml` — runs as `coder-server` SA (Bedrock IRSA), reads `coder-admin-token` SealedSecret, sync-hook so it re-runs every Argo sync |
| Argo CD app | `gitops/apps/coder-agents-config/application.yaml` (sync wave 5) |

What it creates in chatd:

- **Bedrock provider** (provider type `bedrock`, no api_key — uses IRSA;
  flip `BEDROCK_PROVIDER_MODE=aibridge` in the Job env if your Coder
  build's chatd doesn't accept `bedrock` and you want to route through
  AI Bridge's `/api/v2/aibridge/anthropic` endpoint instead).
- **RHAIIS provider** (provider type `openai`, base_url
  `http://vllm.ocp-ai.svc.cluster.local:8000/v1`, api_key `EMPTY`).
- **Every Anthropic Opus + Sonnet inference profile** discovered at
  Job-runtime via `aws bedrock list-inference-profiles --type-equals
  SYSTEM_DEFINED`. Newest Opus is set as the chatd default. Each model
  registers twice — once with extended thinking on, once without.
- **`ibm-granite/granite-3.1-8b-instruct`** on the RHAIIS provider.

Pre-reqs the next session needs to do once:

1. Build + push the new tooling image: trigger
   `.github/workflows/build-images.yml` (any push under
   `coder-templates/images/**` does it; `workflow_dispatch` works too).
2. Mint a long-lived Owner-role Coder API token, seal it as
   `coder-admin-token`, commit at `manifests/secrets/coder-admin-token.yaml`
   (full workflow in `docs/secrets.md`).
3. Push — Argo will pick up the new app and the bootstrap Job will run
   on its first sync.

## What's NOT done (explicitly out of scope)

- **OpenAI models on Bedrock** — GPT-5.5/5.4 are in limited preview (gated, announced May 6). Not worth pursuing for the booth.
- **Bedrock invocation logging** — Decision #17 says deliberately NOT enabled for this demo.

## Current cluster state

| App | State |
|---|---|
| `coder` | 3/3 Running, IRSA injected, healthz 200 |
| `coder-provisioner` | 6/6 Running |
| `coder-routing` | Synced/Healthy |
| `coder-observability` | OutOfSync/Progressing (cosmetic — same as before) |
| Everything else | Synced/Healthy |

## Available Bedrock models for AI Gateway

| Model ID | Use |
|---|---|
| `anthropic.claude-sonnet-4-20250514-v1:0` | Primary — strongest tool-use |
| `anthropic.claude-3-5-haiku-20241022-v1:0` | Fast/cheap fallback |
| `anthropic.claude-opus-4-20250514-v1:0` | Heavy reasoning (if needed) |

## Context for Coder template setup

The workspace template at `coder-templates/openshift-ai-gov/` needs to be configured so that:

1. **AI Gateway routing** — Coder's AI Bridge is the gateway. It's already enabled server-side (`CODER_AIBRIDGE_ENABLED=true`). The template just needs to configure which models are available to agents/tasks. This is done via the Coder admin UI or API (`coder models` CLI if available in this RC).

2. **Agent Firewall** — The template's `config.yaml` (mounted at `~/.config/coder_boundary/config.yaml`) defines process-level egress allowlists. The workspace pod itself doesn't call Bedrock directly — AI Bridge in the control plane does. The firewall config should allow the agent to talk to the Coder server (for AI Bridge) but block direct LLM API calls.

3. **RHAIIS (sovereign model)** — Available at `http://vllm.ocp-ai.svc.cluster.local:8000/v1` inside the cluster. AI Bridge can route to this as a secondary provider. The model is `ibm-granite/granite-3.1-8b-instruct` with the `granite` tool-call parser.

4. **No AWS credentials in the workspace** — The workspace pod does NOT need Bedrock access. AI Bridge in the Coder server handles all LLM calls. The IRSA annotation is only on the `coder-server` SA, not on workspace SAs.

## Commits from this session

```
53667d5 feat(gitops): add Bedrock IRSA annotation to coder-server ServiceAccount
eb63ccd fix(terraform): add :aud condition to IRSA trust policies + fix script
```

## AWS credential notes

- SSO session is active (refreshed ~19:40 UTC May 8)
- Profile: `ocp-deploy-acct` in `~/.aws/config` (SSO-based)
- Must unset `AWS_ENDPOINT_URL` before any real AWS call (workspace injects a mock endpoint)
- Pattern: `env -u AWS_ENDPOINT_URL aws <command> --profile ocp-deploy-acct --region us-east-1`
- SSO sessions last ~8h; refresh via: `env -u AWS_ENDPOINT_URL aws sso login --profile ocp-deploy-acct`

## Kubeconfig

```bash
export KUBECONFIG=/tmp/kubeconfig
```
