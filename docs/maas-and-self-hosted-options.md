# Model-as-a-Service (MaaS) & self-hosted LLM serving — what your air-gap and sensitive customers can actually use

> Reading material for SE / architect conversations with customers running **Coder + Coder Agents + AI Bridge** in regulated, sovereign, or air-gapped environments.
>
> Last updated 2026-05-10 with the booth-prep research findings. **None of this is settled** — the LLM serving stack is moving faster than any product roadmap can keep up with. Use this as a snapshot and check the linked sources before you commit a customer to a specific path.

## What this doc tries to answer

Three customer questions that keep coming up:

1. **"How do I serve multiple LLMs centrally and let many internal apps consume them?"** — the MaaS pattern.
2. **"What's Red Hat's blessed answer for that? And what falls back to OSS / community?"**
3. **"Which of those will actually work in my air-gapped or restricted environment, and which will Coder integrate with?"**

The short version: Red Hat is investing heavily in this layer (llm-d, RHOAI 3.0, Llama Stack, agentgateway + GAIE) but the strategic answer isn't fully GA in mid-2026. The community-OSS answer (LiteLLM) is the tactical bridge most customers land on. **Coder integrates with whatever speaks OpenAI-compatible**, which gives you a wide menu.

---

## What "MaaS" actually means here

**Model-as-a-Service** is the pattern where a small platform team serves LLM inference centrally — one OpenAI-compatible endpoint, multiple models behind it, governance and observability at the gateway — and dozens or hundreds of internal apps consume it without each owning its own GPUs, model weights, or vLLM tuning.

Distinct from two things it gets confused with:

- **Inference serving** alone (vLLM, TGI, Triton, llama.cpp) — that's the workhorse layer. MaaS is the gateway + router + governance ABOVE it.
- **Application-side AI gateways** (Coder AI Bridge / AI Gateway, LangChain proxies, etc.) — that's the consumer-side abstraction. MaaS sits between the consumer-side gateway and the inference servers.

For a Coder customer, the architecture is typically:

```
Coder Workspace / Coder Agents (chatd) ─→ Coder AI Bridge ─→ MaaS gateway ─→ vLLM / RHAIIS pods
                  (workspace egress)         (audit, key)      (model dispatch,    (raw inference)
                                                                quota, observability)
```

Coder owns the left two; MaaS is the middle; RHAIIS / vLLM / etc. own the right.

---

## Red Hat's strategic MaaS stack (2026)

Red Hat's investment shows up in five components, all open source, varying maturity:

### 1. Red Hat OpenShift AI 3.0 (RHOAI 3.0)

The umbrella product. Bundles model serving, training, monitoring, and the rest of the AI lifecycle on OpenShift. RHOAI 3.0 is the first release where llm-d is integrated and Caikit-TGIS is deprecated in favor of vLLM.

- **Air-gap fit**: OpenShift Disconnected install + RHOAI Disconnected pattern is documented. Operator catalog mirroring (`oc-mirror`), image mirroring to the customer's internal registry, and disconnected `oc adm catalog mirror` workflows all apply.
- **Sensitive customer fit**: RHOAI inherits OpenShift's STIG/FIPS/CC posture stories. The challenge isn't OpenShift; it's the model artifacts (see "Model artifact mirroring" below).
- **Coder integration**: indirect — RHOAI exposes inference endpoints; Coder consumes them via standard OpenAI-compat. No special integration.
- **Sources**:
  - [RHOAI documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/)
  - [Tokens, caches & how llm-d improves observability in RHOAI 3.0](https://www.redhat.com/en/blog/tokens-caches-how-llm-d-improves-llm-observability-red-hat-openshift-ai-3.0)

### 2. llm-d (https://llm-d.ai)

Red-Hat-led open-source project for production-grade LLM inference at scale. The right way to think about llm-d: it's NOT primarily an inter-model router. It's an **intra-model serving optimizer** — given multiple replicas of the same model, llm-d's "Endpoint Picker" routes requests using KV-cache awareness, prefix-cache hints, queue depth, and disaggregated prefill/decode.

If you have ten replicas of Llama 3.3 70B and want them to serve traffic efficiently, llm-d is what you reach for. If you have one Llama 70B and one Qwen 7B and want a router to dispatch by `model:` field, llm-d alone is the wrong tool.

- **Maturity**: v0.6.0 in April 2026. Production-ready for the intra-model case.
- **Air-gap fit**: Helm-installable on disconnected OpenShift clusters; image mirroring is straightforward. Conflicts with Service Mesh/Istio installs if you're already running OSSM — read the install notes carefully.
- **Coder integration**: indirect via the inference endpoints llm-d exposes.
- **Sources**:
  - [llm-d project site](https://llm-d.ai)
  - [llm-d/llm-d on GitHub](https://github.com/llm-d/llm-d)
  - [Production-Grade LLM Inference at Scale with KServe, llm-d, and vLLM](https://llm-d.ai/blog/production-grade-llm-inference-at-scale-kserve-llm-d-vllm)
  - [Accelerate multi-turn LLM workloads on OpenShift AI with llm-d intelligent routing](https://developers.redhat.com/articles/2026/01/13/accelerate-multi-turn-workloads-llm-d)

### 3. agentgateway + Gateway API Inference Extension (GAIE)

GAIE (https://github.com/kubernetes-sigs/gateway-api-inference-extension) extends the Kubernetes Gateway API with `InferencePool` and `InferenceModel` CRs — a standard way to express "I want these N model backends served behind one logical endpoint." `agentgateway` is one Gateway API Inference implementation; `OpenShift Service Mesh 3.1` ships another (Tech Preview as of mid-2026).

The Red Hat "Run Model-as-a-Service for multiple LLMs on OpenShift" Developer article (March 2026) chains agentgateway + GAIE + llm-d to give you the canonical Red-Hat-blessed MaaS pattern. Body-field `model:` extraction is a CEL expression on `AgentgatewayPolicy`. Inter-model dispatch.

- **Maturity**: Tech Preview in OSSM 3.1; production paths exist but require multiple Helm charts and a moderate amount of CRD wrangling.
- **Air-gap fit**: same as RHOAI/OpenShift — image mirroring and operator catalog mirroring apply. Better story than LiteLLM if your customer already standardizes on OpenShift Service Mesh.
- **Coder integration**: indirect via the OpenAI-compat endpoint the gateway exposes. chatd points at the gateway URL.
- **This is where I'd send a sovereign / sensitive customer who wants the strategic Red Hat path** and has the OpenShift maturity to deploy it.
- **Sources**:
  - [Run Model-as-a-Service for multiple LLMs on OpenShift](https://developers.redhat.com/articles/2026/03/24/run-model-service-multiple-llms-openshift) — the canonical article
  - [agentgateway docs](https://agentgateway.dev)
  - [Gateway API Inference Extension](https://github.com/kubernetes-sigs/gateway-api-inference-extension)
  - [Introducing OpenShift Service Mesh 3.1](https://www.redhat.com/en/blog/introducing-openshift-service-mesh-31)

### 4. Llama Stack (Meta upstream, packaged in RHOAI Tech Preview)

A higher-level abstraction over inference: agents, RAG, evaluation, safety guardrails, and OpenAI-compatible inference all behind one API. Strategic value: a **single API contract** that customers can build to once and have it run across multiple inference providers (vLLM, Bedrock, Together, Anyscale, etc.).

The catch is that Llama Stack's API contract is NOT stock OpenAI — it adds toolkit and agent abstractions that are different from standard `/v1/chat/completions`. Apps written for stock OpenAI either need an adapter or need to be rewritten against the Llama Stack SDK.

- **Maturity**: Tech Preview in RHOAI 3.x as of mid-2026. Pre-GA.
- **Air-gap fit**: should be fine once GA — same RHOAI Disconnected mechanics.
- **Coder integration**: not direct today. Would need either (a) Llama Stack to expose stock-OpenAI compatibility under a different prefix (it does for some endpoints; full parity is incomplete), or (b) an adapter layer between chatd and Llama Stack.
- **The strategic post-Summit Red Hat path to evaluate** for customers who want one unified API across cloud + sovereign providers. Not for tonight.
- **Sources**:
  - [Working with Llama Stack — RHOAI 3.3 docs](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.3/html-single/working_with_llama_stack/index)
  - [Llama Stack upstream](https://github.com/meta-llama/llama-stack)

### 5. vLLM (the engine)

What RHAIIS packages. The dominant OSS LLM serving runtime in 2026. Single model per server, OpenAI-compatible API surface, supports tool calling via per-model parsers (`hermes`, `granite`, `llama3_json`, `mistral`, etc.), supports many quantization formats (AWQ, GPTQ, FP8, INT4 W4A16).

- **Air-gap fit**: excellent. The image is in `quay.io/modh/vllm` (Red Hat-published mirror) or `vllm/vllm-openai` upstream. Models load from local volume / mirrored HF cache.
- **Sensitive customer fit**: per-customer choice of which model weights are acceptable. See "Model license tradeoffs" below.
- **Coder integration**: direct. chatd's `openai-compat` provider points at vLLM's `/v1`.

### 6. vLLM Semantic Router (Athena release)

A Red-Hat-led project that routes based on **prompt semantics** (a small BERT classifier) rather than the `model:` field. Different problem from "fan out to multiple vLLMs"; useful for cost optimization (route trivial prompts to cheap models, hard prompts to expensive ones).

- **Coder integration**: similar to LiteLLM — sits in front of vLLM, exposes OpenAI-compat. chatd doesn't care which side of the routing decision the request lands on.
- **Sources**:
  - [Getting started with vLLM Semantic Router (Athena release)](https://developers.redhat.com/articles/2026/03/25/getting-started-vllm-semantic-router-athena-release)

---

## Tactical / community OSS options

What customers reach for when the strategic Red Hat stack isn't ready or appropriate.

### LiteLLM

The de facto answer for "OpenAI-compatible router that fans out by `model:` field." MIT-licensed core, AGPL for the proxy/server. ConfigMap-only deploy. ~10-min setup.

- **Maturity**: well-established. Documented bugs (mostly on Ollama / Responses-API translation paths), but vLLM upstream pass-through is clean.
- **Air-gap fit**: image at `ghcr.io/berriai/litellm-non_root:main-stable` (use the non-root variant for restricted-v2 SCC). For air-gap mirror to internal registry; ConfigMap-only deploy means no Prisma, no Postgres dependency.
- **OpenShift gotcha**: with the standard image and Helm chart you'll hit [BerriAI/litellm#19408](https://github.com/BerriAI/litellm/issues/19408) (Prisma write-path under restricted-v2). Fix: `STORE_MODEL_IN_DB=false` and a static config ConfigMap. Documented in our `docs/decisions.md` §28.
- **Coder integration**: chatd points at LiteLLM's `/v1`; many model_configs map to LiteLLM `model_name` aliases.

### KServe + ModelMesh

KServe `InferenceService` exposes one OpenAI endpoint per ISVC — no native fan-out across multiple ISVCs. ModelMesh is for serving many SMALL classical models on shared pods, not for vLLM-class LLMs. Not the right tool for the MaaS-multiple-LLMs case in 2026, but worth knowing about for customers who already have KServe in their RHOAI deployment.

### Caikit-TGIS

Being deprecated in RHOAI 3.x in favor of vLLM. Don't pick this for new deployments.

### Envoy AI Gateway

Upstream Envoy project. Not currently shipped or supported by Red Hat as a separate product, though the underlying Envoy is in OSSM. Build-your-own territory.

### NVIDIA Triton Inference Server

Workhorse for non-LLM inference (computer vision, classical ML). Has OpenAI-compat support for LLMs but the ecosystem has settled on vLLM for LLMs specifically. Don't pick Triton for an LLM-first MaaS stack.

### KubeAI / Aibrix

Newer community projects. Worth watching but not Red-Hat-blessed and not battle-tested at customer scale in 2026.

---

## Air-gap deployment checklist

Specific to Coder Agents + AI Bridge + an OSS LLM stack on OpenShift Disconnected:

1. **Mirror operator catalogs** to the customer's internal registry — `oc-mirror` is the supported tool. Catalogs: `redhat-operators`, `certified-operators`, `community-operators` (depending on which operators you need).

2. **Mirror images**:
   - OpenShift cluster images (standard disconnected install)
   - RHOAI operator images
   - vLLM (`quay.io/modh/vllm:rhoai-2.20-cuda` or successor) — Red Hat ships this on Quay; mirror to internal
   - Coder server image (`ghcr.io/coder/coder:vX.Y.Z`)
   - LiteLLM if used (`ghcr.io/berriai/litellm-non_root:main-stable`)
   - Any sidecar images (cert-manager, sealed-secrets, NVIDIA GPU operator, etc.)

3. **Model artifact mirroring** — this is the underrated hard part:
   - HuggingFace's CDN is unreachable in air-gap. Customers must pull model weights, scan them, and host them in an internal artifact store.
   - vLLM supports loading from local paths (`HF_HOME=/mnt/models`) instead of HF download. Bake weights into a PVC / shared volume.
   - For RHEL-blessed quants, the `RedHatAI/` namespace on HF (e.g. `RedHatAI/Llama-3.3-70B-Instruct-quantized.w4a16`) is what to mirror. Fewer artifacts to verify than upstream.
   - Some customers maintain a "model registry" — Harbor with provenance metadata, Sonatype Nexus, Artifactory. Pattern is the same: mirror once, sign, scan, then load from local.

4. **Certificate trust** — internal CAs need to be in the OpenShift `additionalTrustBundle` (in install-config) AND in any custom container images that talk to internal registries (Coder workspace base images included).

5. **Model license vetting** — your security team will want to review the license of every model you run, especially:
   - **Granite (IBM)**: Apache-2.0. Easiest path for license-strict customers. Capability tradeoffs: Granite 3.x's tool-calling and agentic reasoning is mid-tier; not the right fit for sustained Coder Agents loops on its own.
   - **Llama 3.x (Meta)**: Llama 3.x Community License — has the >700M MAU clause and acceptable-use policy. NOT OSI-OSS. Acceptable for ~all enterprises; deal-breaker for some regulated sectors.
   - **Qwen (Alibaba)**: Apache-2.0 for most variants. Origin sensitivity for some PubSec / DoD audiences.
   - **Mistral / Mixtral**: Apache-2.0 (Mistral 7B), Mistral Research License (newer models). Per-model check.
   - **DeepSeek**: MIT for v3.x weights. Origin sensitivity (Chinese provider).

6. **Coder workspace base images** — for air-gap, `coder-templates/images/ubi9-base-workspace` etc. need to be built from internally-mirrored base images (UBI9 from `registry.redhat.io` mirror) and pushed to the customer's internal registry.

---

## What works with Coder Agents + AI Bridge specifically

Coder's two governance layers handle this cleanly because both speak OpenAI-compat / Anthropic API.

**AI Bridge (`/api/v2/aibridge/{anthropic,openai}` endpoints):**
- Swap upstream URL via `CODER_AIBRIDGE_*` env vars to point at any OpenAI-compatible internal endpoint
- For Anthropic, the bridge uses AWS SDK to talk to Bedrock — in air-gap with no AWS, you'd need a Bedrock-API-compatible self-hosted alternative (rare; most customers point AI Bridge's anthropic provider at a vLLM-served Anthropic-format model OR migrate users to OpenAI-compat-only)
- Central API key model: `CODER_AIBRIDGE_OPENAI_KEY` + `CODER_AIBRIDGE_ALLOW_BYOK=false` enforces audit trail integrity — works fine with internal endpoints

**Coder Agents (chatd):**
- Provider type `openai-compat` consumes any vLLM / LiteLLM / RHAIIS / llm-d-fronted endpoint
- Provider type `bedrock` consumes AWS Bedrock via the IRSA-attached SA — replace with `openai-compat` pointing at internal endpoints in air-gap
- Provider type `anthropic` (also OpenAI-compat-ish for our purposes) — same swap pattern
- One known constraint: chatd's schema enforces ONE provider per type, so multi-backend dispatch needs a router. See `docs/decisions.md` §28.

**Coder external auth, observability, cert trust:**
- All standard OpenShift patterns. Coder's Helm chart accepts `additionalTrustBundle` and custom images.

---

## Customer-shape decision tree

| Customer profile | Strategic recommendation | Tactical answer |
|---|---|---|
| **DoD IL5/IL6** | OpenShift Disconnected + RHOAI Disconnected + RHAIIS-served Granite (Apache-2.0) | LiteLLM in front of vLLM if multi-model MaaS needed. Llama 3.x license is a non-starter. |
| **FedRAMP High** | RHOAI on AWS GovCloud or Azure Gov + RHAIIS + Bedrock GovCloud (when models available) | Same. AI Bridge points at GovCloud Bedrock + vLLM-served Granite. |
| **Healthcare HIPAA** | RHOAI on customer cloud + RHAIIS + ANY model the legal team approves | LiteLLM tactical; agentgateway+GAIE+llm-d strategic. PHI never leaves the cluster. |
| **Financial services / SOX** | Same as Healthcare. AI Bridge audit trail is the booth talking point. | Same. |
| **EU sovereign cloud** | RHOAI on customer-hosted OpenShift + RHAIIS + Mistral or Llama (license-permitting) | LiteLLM tactical. Mistral-family models keep the data + the model in-region. |
| **Defense industrial base / sensitive but not classified** | Same as PubSec but with more model flexibility | Same. |
| **Regulated enterprise (insurance, telecom)** | RHOAI + RHAIIS + BYO model. LiteLLM is fine until they outgrow it. | LiteLLM. |

---

## Reading list — primary sources to send a customer

Red Hat:
- [RHOAI documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/) — start here for the umbrella product.
- [Run Model-as-a-Service for multiple LLMs on OpenShift](https://developers.redhat.com/articles/2026/03/24/run-model-service-multiple-llms-openshift) — the canonical Red Hat MaaS reference.
- [Tokens, caches & how llm-d improves observability in RHOAI 3.0](https://www.redhat.com/en/blog/tokens-caches-how-llm-d-improves-llm-observability-red-hat-openshift-ai-3.0)
- [Accelerate multi-turn LLM workloads with llm-d intelligent routing](https://developers.redhat.com/articles/2026/01/13/accelerate-multi-turn-workloads-llm-d)
- [Introducing OpenShift Service Mesh 3.1](https://www.redhat.com/en/blog/introducing-openshift-service-mesh-31) — covers GAIE Tech Preview.
- [vLLM Semantic Router — Athena release](https://developers.redhat.com/articles/2026/03/25/getting-started-vllm-semantic-router-athena-release)
- [Working with Llama Stack — RHOAI docs](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.3/html-single/working_with_llama_stack/index)

Upstream OSS:
- [llm-d project](https://llm-d.ai) and [llm-d/llm-d on GitHub](https://github.com/llm-d/llm-d)
- [Gateway API Inference Extension](https://github.com/kubernetes-sigs/gateway-api-inference-extension)
- [agentgateway docs](https://agentgateway.dev)
- [vLLM tool calling docs](https://docs.vllm.ai/en/latest/features/tool_calling/)
- [LiteLLM docs](https://docs.litellm.ai)
- [Llama Stack on GitHub](https://github.com/meta-llama/llama-stack)

Coder:
- [Coder Agents docs](https://coder.com/docs/ai-coder/agents)
- [Coder Agents — Models and Providers](https://coder.com/docs/ai-coder/agents/models)
- [Coder AI Bridge / AI Gateway docs](https://coder.com/docs/ai-coder/ai-bridge)
- [Self-Hosted, AI Model Agnostic Coder Agents](https://coder.com/blog/self-hosted-ai-model-agnostic-coder-agents)

Model licensing references:
- [Llama 3.3 Community License](https://github.com/meta-llama/llama3/blob/main/LICENSE) — read the >700M MAU clause and acceptable-use sections.
- [Mistral Research License](https://mistral.ai/news/mistral-research-license)
- [IBM Granite license overview (Apache-2.0)](https://www.ibm.com/granite/docs/models/license)
- [Qwen license per model on HuggingFace](https://huggingface.co/Qwen) — varies; mostly Apache-2.0.

---

## Five questions to ask a customer to land them in the right slot

1. **What's your model-license risk tolerance?** — Granite-Apache-2.0-only? Llama-Community-License OK? Origin-sensitive (no Qwen/DeepSeek)?
2. **Do you need fully air-gapped or "controlled egress"?** — air-gap means model-artifact mirroring infrastructure; controlled egress lets you pull from `RedHatAI/` HuggingFace via an internal proxy.
3. **What's already running?** — RHOAI? KServe? Service Mesh? llm-d? That determines whether agentgateway+GAIE+llm-d is "just configuration" or "a new operator install."
4. **One model or many?** — single LLM behind RHAIIS is straightforward. Multi-model MaaS needs a router; pick LiteLLM tactical or agentgateway+GAIE+llm-d strategic.
5. **What does the audit story need to look like?** — Coder AI Bridge's central-key-only model + structured logging is the story. Bedrock CloudTrail, vLLM Prometheus metrics, llm-d observability dashboards layer on top.
