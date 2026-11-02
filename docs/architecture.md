# Reference architecture — Coder + Red Hat: governed agentic AI on OpenShift

> Booth-grade reference architecture for the Red Hat Summit + AnsibleFest 2026 demo, plus a sovereign / air-gapped narrative arc for production deployments.

## Context

| Slot | Booth demo | Sovereign / production narrative |
|---|---|---|
| Cluster | OpenShift 4.21 IPI on AWS (3-node converged + 1× A10G g5.2xlarge GPU node) | OpenShift on AWS GovCloud, Azure Gov, on-prem, or behind a sovereign software factory pattern (e.g., Big Bang / UDS Core) |
| Classification | Unclassified | Up to IL5 with Coder's Air-Gapped Deployments Bundle |
| Scale (concurrent workspaces) | 5–25 (warm-pool of 3) | 10K reference architecture is live; 50K reference architecture is in flight |
| Cloud-side LLM provider | AWS Bedrock via the `cluster-coder-bedrock` IRSA role + central OpenAI key (no per-user BYOK) | Bedrock, Azure OpenAI, Anthropic direct, or any OpenAI-compatible — typically routed to a sovereign provider in regulated deployments |
| Sovereign LLM provider | RHAIIS on a single A10G (`g5.2xlarge`) serving `Qwen/Qwen2.5-7B-Instruct` (`--tool-call-parser hermes`, 16K, TP-1) via `vllm-executor`; heavier Llama-3.3-70B INT4 TP-2 on L40S is committed but scaled to 0 for cost (decisions §27/§31/§32) | RHAIIS on GPU nodes, optionally fronted by `llm-d` for distributed serving; FIPS-validated images, RHEL UBI base |
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
│   · RHAIIS / vLLM serving Qwen2.5-7B-Instruct on A10G                  │
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
| AI Bridge (a.k.a. AI Gateway) | **AI Gateway** | GA in Coder v2.30. Env vars renamed to `CODER_AI_GATEWAY_*` in 2.37.x (previously `CODER_AIBRIDGE_*`); endpoints `/api/v2/aibridge/{anthropic,openai}`. Anthropic traffic routes to Bedrock via IRSA; OpenAI traffic uses the central `coder-secrets.openai-api-key` with `ALLOW_BYOK=false` (audit-trail integrity). |
| Agent Firewalls | **Agent Firewalls** | GA in Coder v2.30. NOT currently shipped in either booth template (decision §23). |
| AI Governance Add-On | **AI Governance Add-On** | GA in Coder v2.30 (Feb 2026) — bundles AI Gateway + Agent Firewalls + audit |
| Coder Agents (chatd) | **Coder Agents** | **Beta** as of Coder v2.33.1 (no experiment flag required); cluster now runs **v2.37.6**. Provider + model bootstrap is owned by the `coder-agents-config` Argo Job; the registered Anthropic models are an explicit 7-ID Bedrock allowlist (decision §25). |
| Coder Tasks | **Coder Tasks** | GA |
| Prebuilt Workspaces | **Prebuilt Workspaces** | GA |
| Workspace template | — | OpenShift / RHEL UBI base, FIPS-validated |
| RHAIIS / vLLM | **Red Hat AI Inference Server** | GA |
| Grafana Loki / Splunk / ELK | — | unified Bridge + Boundaries log format streams here |
| Prometheus + Alertmanager | — | metrics + alerts; alert thresholds in `gitops/apps/observability/application.yaml` |

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
- **Egress controls / DLP:** Agent Firewalls rules file with a domain allowlist; default-deny everywhere else. See `coder-templates/demo-ai-gov-firewall-ocp/boundary.config.yaml.tftpl`.

## Observability & audit

- **Workspace audit + Bridge + Boundaries unified log format** → Grafana Loki (or Splunk / ELK via the same shape).
- **Prometheus metrics:** `CODER_PROMETHEUS_ENABLE=true`, with DB metrics and agent stats enabled.
- **Alert groups:** Licenses, coderd CPU/Memory, Replicas, Workspace Build Failures, provisionerd Replicas. Thresholds in `gitops/apps/observability/application.yaml`.
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

The cost-effective default actually running is **`Qwen/Qwen2.5-7B-Instruct`** on a single **A10G (`g5.2xlarge`)** via the `vllm-executor` Deployment — `hermes` tool-call parser, tensor-parallel-1, 16K context (`ai-providers/rhaiis.tf` registers it at `http://vllm-executor.ocp-ai.svc.cluster.local:8000/v1`). The heavier **Llama 3.3 70B Instruct INT4** (`RedHatAI/Llama-3.3-70B-Instruct-quantized.w4a16`, `llama3_json`, tensor-parallel-2, 32K on 2× L40S / `g6e.12xlarge` — see `manifests/rhaiis/vllm-planner-tp.yaml`) is committed but **scaled to 0** for cost. Decisions §31 + §32 + §33 capture how we got here:
- §27 was the initial "Qwen 2.5 32B AWQ on L40S" decision (now scaled to 0 — `manifests/rhaiis/vllm-deployment.yaml` + `manifests/machinesets/gpu-l40s.yaml`, both `coder.com/lifecycle: deprecated`).
- §30 documented the temporary revert to Qwen after the Llama V1-engine silent hang.
- §31 found the V0 + `--enforce-eager` + 8K-context recipe that works on single L40S.
- §32 extended that to tensor-parallel-2 for 32K context on g6e.12xlarge — the big-model scale-up (currently scaled to 0; the live cluster runs the A10G / Qwen-7B executor).
- §33 documented the V1 + cudagraphs retest on rhoai-2.22-cuda (still broken; staying on V0).

**Always validate with `scripts/tool-call-smoke-test.sh` before going live** — wrong parser is a silent failure mode where text returns instead of structured `tool_calls`.

## Demo-day open items

The following items were tracked in the Red Hat Summit 2026 demo plan. As of 2026-05-11 the booth is live. Status updates land in this repo as they're closed.

- ✅ End-to-end validation of Coder Agents against RHAIIS (sovereign) — currently Qwen2.5-7B on the A10G; Llama-70B TP-2 was validated previously on an L40S node (now scaled to 0)
- ✅ RHAIIS on the A10G `g5.2xlarge` (Qwen2.5-7B, cost-effective default); L40S / `g6e.12xlarge` is the optional heavy scale-up (scaled to 0)
- ✅ Sprint trigger replaced by `bridge` service: GitLab Issues webhook → Coder workspace + chat. Triggers off `coder-hitl` / `coder-agent[:slug]` labels.
- ⚠ Backup video of the full demo for booth-network failure (still pending — operator action)
- ✅ IdP — Keycloak (RHBK) for demo personas, dual-IdP alongside GitHub OAuth for admins
