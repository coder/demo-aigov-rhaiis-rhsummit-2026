# Reference architecture — Coder + Red Hat: governed agentic AI on OpenShift

> Booth-grade reference architecture for the Red Hat Summit + AnsibleFest 2026 demo, plus a sovereign / air-gapped narrative arc for production deployments.

## Context

| Slot | Booth demo | Sovereign / production narrative |
|---|---|---|
| Cluster | OpenShift 4.21 IPI on AWS (3-node converged + 1× L40S g6e.2xlarge GPU node) | OpenShift on AWS GovCloud, Azure Gov, on-prem, or behind a sovereign software factory pattern (e.g., Big Bang / UDS Core) |
| Classification | Unclassified | Up to IL5 with Coder's Air-Gapped Deployments Bundle |
| Scale (concurrent workspaces) | 5–25 (warm-pool of 3) | 10K reference architecture is live; 50K reference architecture is in flight |
| Cloud-side LLM provider | AWS Bedrock via the `cluster-coder-bedrock` IRSA role + central OpenAI key (no per-user BYOK) | Bedrock, Azure OpenAI, Anthropic direct, or any OpenAI-compatible — typically routed to a sovereign provider in regulated deployments |
| Sovereign LLM provider | RHAIIS on a single L40S GPU node serving `Qwen/Qwen2.5-Coder-32B-Instruct-AWQ` (`--tool-call-parser hermes`); Llama 3.3 70B Instruct documented as the swap target if Qwen origins come into question (decision §27) | RHAIIS on GPU nodes, optionally fronted by `llm-d` for distributed serving; FIPS-validated images, RHEL UBI base |
| Pillars | Modernize-led, Multiply-centerpiece (Coder Agents beta), Migrate-substrate | Same shape; Migrate substrate becomes the dominant story in air-gap |

## High-level architecture (booth shape; same shape lands in sovereign environments)

```
┌────────────────────────────────────────────────────────────────────────┐
│  Developer / Demo Driver                                               │
│  IDE: Cursor / VS Code / Claude Code (Coder Tasks)                     │
└──────────────────┬──────────────────────────────────────┬──────────────┘
                   │ (model traffic)                      │ (workspace shell / SSH / IDE proxy)
                   ▼                                      ▼
┌──────────────────────────────┐            ┌──────────────────────────────┐
│   Coder Control Plane        │            │   OpenShift Route /          │
│   (3 coderd replicas, OCP    │            │   Coder DERP (relay-only,    │
│   Routes, hardened SCC)      │            │   direct connections off)    │
│                              │◀───────────┤                              │
│  ┌────────────────────────┐  │            └──────────────┬───────────────┘
│  │ AI Gateway             │  │                          │
│  │  · Centralized auth    │  │                          │
│  │  · BYOK / central key  │  │                          │
│  │  · Per-user attribution│  │                          │
│  │  · Routes to:          │  │                          │
│  │    - Anthropic (cloud) │  │                          │
│  │    - RHAIIS (sovereign)│  │                          │
│  └────────────────────────┘  │                          │
│  ┌────────────────────────┐  │                          │
│  │ Agent Firewalls        │  │                          │
│  │  · Process-level       │  │                          │
│  │  · Domain allowlist    │  │                          │
│  │  · Landjail (no priv)  │  │                          │
│  │  · Audit → Loki/Splunk │  │                          │
│  └────────────────────────┘  │                          │
│  ┌────────────────────────┐  │                          │
│  │ Coder Agents (EA)      │  │                          │
│  │  · Loop runs HERE      │  │                          │
│  │  · No keys in workspace│  │                          │
│  │  · User identity tied  │  │                          │
│  │    to every action     │  │                          │
│  │  · Sub-agent delegation│  │                          │
│  └────────────────────────┘  │                          │
└────────────┬─────────────────┘                          │
             │ (provisioner work via signed JWT)          │
             ▼                                            ▼
┌──────────────────────────────┐            ┌──────────────────────────────┐
│ Coder External Provisioners  │            │  Coder Workspaces (OCP pods)  │
│ N replicas, dedicated nodes  │───────────▶│   - Repo cloned (Git)        │
│ Build templates, never touch │            │   - IDE process              │
│ workspace data plane         │            │   - Coder Task agent (GA)    │
└──────────────────────────────┘            │   - Prebuilt warm pool       │
                                            └────┬─────────────────────────┘
                                                 │ (model calls leave VIA control plane,
                                                 │  not the workspace pod — Coder Agents)
                                                 ▼
┌────────────────────────────────────────────────────────────────────────┐
│  Backends                                                              │
│   · Postgres (CNPG in-cluster, multi-AZ)                               │
│   · AWS Bedrock via IRSA (no static keys; 7 subscribed Anthropic       │
│     inference profiles — see bedrock-model-sub.md)                     │
│   · OpenAI direct via central key in coder-secrets.openai-api-key      │
│   · RHAIIS / vLLM serving Qwen2.5-Coder-32B-AWQ on L40S                │
│     (OpenAI-compatible; --tool-call-parser hermes)                     │
│   · Git host (GitHub OAuth scoped to demo-rhsummit-users org)          │
│   · Grafana Loki (Bridge + Boundaries unified audit logs)              │
│   · Prometheus + Alertmanager                                          │
└────────────────────────────────────────────────────────────────────────┘
```

## Component inventory

| Component | Customer-facing name | Status |
|---|---|---|
| Coder server (3 replicas, hardened SCC) | Coder Premium | GA |
| External provisioners (12 replicas, dedicated nodes) | — | GA |
| AI Bridge (a.k.a. AI Gateway) | **AI Gateway** | GA in Coder v2.30. In code/env vars referred to as `AIBRIDGE` (`CODER_AIBRIDGE_*`); endpoints `/api/v2/aibridge/{anthropic,openai}`. Anthropic traffic routes to Bedrock via IRSA; OpenAI traffic uses the central `coder-secrets.openai-api-key` with `ALLOW_BYOK=false` (audit-trail integrity). |
| Agent Firewalls | **Agent Firewalls** | GA in Coder v2.30. NOT currently shipped in either booth template (decision §23). |
| AI Governance Add-On | **AI Governance Add-On** | GA in Coder v2.30 (Feb 2026) — bundles AI Gateway + Agent Firewalls + audit |
| Coder Agents (chatd) | **Coder Agents** | **Beta** as of Coder v2.33.1 (no experiment flag required). Provider + model bootstrap is owned by the `coder-agents-config` Argo Job; the registered Anthropic models are an explicit 7-ID Bedrock allowlist (decision §25). |
| Coder Tasks | **Coder Tasks** | GA |
| Prebuilt Workspaces | **Prebuilt Workspaces** | GA |
| Workspace template | — | OpenShift / RHEL UBI base, FIPS-validated |
| RHAIIS / vLLM | **Red Hat AI Inference Server** | GA |
| Grafana Loki / Splunk / ELK | — | unified Bridge + Boundaries log format streams here |
| Prometheus + Alertmanager | — | metrics + alerts; alert thresholds in `helm/coder/values-observability.yaml` |

## Identity & access

- **IdP (recommended):** Keycloak — matches the Big Bang / UDS Core ecosystem and aligns with the sovereign narrative. Okta is the alternate for enterprise / civilian Fed.
- **Auth:** OIDC for SSO with `offline_access` scope and `access_type=offline` for refresh tokens.
- **External Auth:** Git host integration via OIDC / OAuth (single Git host for the booth; multi-host pattern in production).
- **RBAC:** Org-level + workspace-level + AI-policy-level (Agent Firewalls). Coder Agents User role granted only to demo accounts during EA.
- **Service Account:** dedicated `coder` SA with workspace permissions, scoped to `coder-workspaces` namespace.

## Networking & egress

- **DERP relay only** (`CODER_DISABLE_DIRECT_CONNECTIONS=true`) — eliminates direct WireGuard between developer and workspace; all traffic routes via the Coder server.
- **OpenShift Routes** for ingress. Helm ingress is disabled.
- **Path apps disabled** (`CODER_DISABLE_PATH_APPS=true`) — subdomain apps only.
- **Wildcard access URL:** `*.coder.<demo-domain>` for workspace subdomain apps.
- **Strict TLS** (`CODER_STRICT_TRANSPORT_SECURITY=true`).
- **Telemetry off** (`CODER_DISABLE_NETWORK_TELEMETRY=true`, `CODER_DISABLE_USAGE_STATS=true`) — required posture for any regulated customer.
- **Egress controls / DLP:** Agent Firewalls rules file with a domain allowlist; default-deny everywhere else. See `manifests/agent-firewalls/rules.example.yaml`.

## Observability & audit

- **Workspace audit + Bridge + Boundaries unified log format** → Grafana Loki (or Splunk / ELK via the same shape).
- **Prometheus metrics:** `CODER_PROMETHEUS_ENABLE=true`, with DB metrics and agent stats enabled.
- **Alert groups:** Licenses, coderd CPU/Memory, Replicas, Workspace Build Failures, provisionerd Replicas. Thresholds in `helm/coder/values-observability.yaml`.
- **Postgres exporter** for DB observability.
- **Session tracking** for AI usage — pulls into the platform admin dashboard.

## Compliance & ATO touchpoints

- **Container security context:** `runAsNonRoot: true`, `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, `seccompProfile.type: RuntimeDefault`, `capabilities.drop: [ALL]`. Required for STIG'd OCP clusters and OpenShift's `restricted-v2` SCC.
- **FIPS posture:** RHEL UBI base images are FIPS-validated.
- **Air-gap path:** AI Governance Add-On Air-Gapped Deployments Bundle.
- **ATO inheritance options:** Big Bang / Platform One / UDS Core / DCCSCR for DoD; FedRAMP Moderate authorization boundary inheritance from AWS GovCloud or Azure Gov for civilian Fed.

## Inference layer — RHAIIS specifics

RHAIIS exposes the OpenAI-compatible API:

- `POST /v1/chat/completions` — Chat Completions, with `tools` / `tool_choice` for tool use
- `POST /v1/completions` — legacy text completion
- `POST /v1/embeddings`
- `GET /v1/models`

**Tool-call support is model-dependent.** vLLM ships per-model tool parsers; the launch flag must match the model:

| Parser | Models |
|---|---|
| `granite` | IBM Granite-3.x-Instruct |
| `hermes` | Qwen2.5 / Qwen2.5-Coder, OpenHermes |
| `llama3_json` | Llama-3.1+ Instruct |
| `mistral` | Mistral / Mixtral Instruct |
| `deepseek` | DeepSeek-V3 / DeepSeek-Coder-V2.5+ |

For the booth demo we use **Llama 3.3 70B Instruct INT4** (`RedHatAI/Llama-3.3-70B-Instruct-quantized.w4a16`) with the `llama3_json` parser, tensor-parallel-2 across 2× L40S on a g6e.12xlarge node, 32K context. See `manifests/rhaiis/vllm-planner-tp.yaml` for the launch flags. Decisions §31 + §32 + §33 capture how we got here:
- §27 was the initial "Qwen 2.5 32B AWQ on L40S" decision (now scaled to 0 — `manifests/rhaiis/vllm-deployment.yaml` + `manifests/machinesets/gpu-l40s.yaml`, both `coder.com/lifecycle: deprecated`).
- §30 documented the temporary revert to Qwen after the Llama V1-engine silent hang.
- §31 found the V0 + `--enforce-eager` + 8K-context recipe that works on single L40S.
- §32 extended that to tensor-parallel-2 for 32K context on g6e.12xlarge — current production.
- §33 documented the V1 + cudagraphs retest on rhoai-2.22-cuda (still broken; staying on V0).

**Always validate with `scripts/tool-call-smoke-test.sh` before going live** — wrong parser is a silent failure mode where text returns instead of structured `tool_calls`.

## Demo-day open items

The following items were tracked in the Red Hat Summit 2026 demo plan. As of 2026-05-11 the booth is live. Status updates land in this repo as they're closed.

- ✅ End-to-end validation of Coder Agents against RHAIIS (Llama 70B INT4 TP-2 in chatd)
- ✅ RHAIIS on g6e.12xlarge (4× L40S, 2 in use by production TP)
- ✅ Sprint trigger replaced by `bridge` service: GitLab Issues webhook → Coder workspace + chat. Triggers off `coder-hitl` / `coder-agent[:slug]` labels.
- ⚠ Backup video of the full demo for booth-network failure (still pending — operator action)
- ✅ IdP — Keycloak (RHBK) for demo personas, dual-IdP alongside GitHub OAuth for admins
