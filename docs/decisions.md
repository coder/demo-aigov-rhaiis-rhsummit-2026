# Decisions log — Coder + RH Summit 2026 demo

> Architectural and operational decisions made during the demo build, with the alternatives we considered and why we picked what we picked.
> If you're tempted to revisit one of these — read the "why" first; we may have already burned that path.
> Last updated 2026-04-27.

## How to use this doc

Each section is one decision: **what we picked**, **what we considered**, **why this**, and **tradeoffs**. Optional **trigger to revisit** notes call out conditions under which the decision is worth re-litigating.

If you change a decision, update this file in the same PR.

---

## 1. OCP IPI on AWS (not ROSA)

**Picked:** Self-managed OpenShift 4.21 via Installer-Provisioned Infrastructure (`openshift-install create cluster --dir=...`) on a BYO-VPC.

**Considered:** ROSA (Red Hat OpenShift Service on AWS).

**Why:** ROSA was explicitly rejected. Routing via the ROSA-managed ELB layer is too constrained for our wildcard + custom-cert pattern (`*.coder.apps.<fqdn>` with cert-manager-issued externalCertificate Routes), and ROSA's IPI control surface is limited compared to self-managed.

**Tradeoffs:** We own more — installer maintenance, MachineSet config, cluster ops. Acceptable for a demo cluster that lives a few weeks.

**Trigger to revisit:** None — this was thoroughly debated and locked.

---

## 2. Compact 3-node converged + 1 GPU node (not 3 CP + 2 worker, not SNO, not the original 6-node)

**Picked:** 3 × m6i.4xlarge as control-plane AND workers (`compute.replicas: 0` in `install-config.yaml`) + 1 × g5.2xlarge GPU compute pool, always-on whenever the cluster is up.

**Considered:**
- 3 CP m6i.xlarge + 3 worker m6i.2xlarge (the original default)
- 3 CP + 2 worker + 1 GPU
- 3 × m6i.2xlarge converged + 1 GPU (Path 1)
- SNO (single-node OCP, m6i.8xlarge)

**Why:**
- 6-node was over-provisioned for the workload (~20 vCPU peak demand vs 19 usable on workers); cost ~$45/day for capacity we don't use.
- 3 CP + 2 worker has WORSE HA than 3 converged: lose one worker mid-demo and you lose 50% of compute. The 3-converged math gives you 11/16.5 vCPU left after one node failure, etcd quorum holds.
- m6i.2xlarge converged is at the floor (16.5 usable vCPU vs 21 vCPU peak demand). OCP overhead eats too much. We saw "perf issues on xlarge" historically at Coder.
- m6i.4xlarge converged: 39 usable vCPU comfortable headroom; +$28/day vs 2xlarge for "no workload tuning needed."
- SNO loses every HA narrative (multi-AZ Postgres, multi-AZ control plane) AND the GPU narrative — too many compromises.

**Tradeoffs:** $87/day always-up vs ~$60 with toggle, ~$45 with old shape. We pay ~$28/day for comfort + simplicity (no kustomize-CPU-vs-GPU overlay).

**Trigger to revisit:** If post-install we see capacity pressure on the converged nodes (active workspace count > 3), bump to m6i.8xlarge or add a worker MachineSet. If GPU node is consistently underutilized (RHAIIS p99 latency stays low), consider g4dn.xlarge for cost.

---

## 3. CloudNativePG, in-cluster (not RDS)

**Picked:** CNPG operator (community-operators, channel `stable-v1.24`), `Cluster` CR with 3 instances spread across AZs via pod-anti-affinity on `topology.kubernetes.io/zone`.

**Considered:** AWS RDS Aurora Postgres multi-AZ (the original demo had this).

**Why on-prem-portability is the dominant factor:** the audience at RH Summit is OpenShift platform engineers running OCP everywhere — AWS, Azure, vSphere, bare-metal, air-gap. If the demo bakes in RDS, the customer reads it as "this is an AWS-flavored thing, not an OpenShift thing." CNPG's Cluster CR runs unchanged on any OCP. Bonus: CNPG auto-generates the `coder-app` Secret that Coder consumes — no manual DB-URL plumbing.

**Tradeoffs:** community-operators source (not Red-Hat-engineered). Documented as an operator-policy exception in the operator-policy table because RH doesn't ship a first-party in-cluster Postgres operator and CNPG is the de facto Kubernetes-native choice.

**Trigger to revisit:** If the customer story shifts to AWS-native production architectures (e.g., a full RDS multi-AZ + KMS encryption at rest narrative), swap back. For booth: never.

---

## 4. GHCR (not ECR)

**Picked:** Workspace base images live at `ghcr.io/coder/demo-aigov-rhaiis-rhsummit-2026/...`. GH Actions push uses the workflow's built-in `GITHUB_TOKEN`.

**Considered:** AWS ECR + GH Actions OIDC role (the original setup).

**Why:** Same on-prem-portability reason as CNPG. GHCR works the same from any cluster anywhere; ECR ties workspaces to AWS. Bonus: GHA OIDC role + ECR was three more AWS resources we don't need.

**Tradeoffs:** Public registry. Booth-acceptable; production may want a private registry (Quay, Harbor).

**Trigger to revisit:** Never for booth. For production: customer's own Quay deployment.

---

## 5. cert-manager + Let's Encrypt + R53 DNS-01 (not ACM)

**Picked:** cert-manager Operator for Red Hat OpenShift, ACME wildcard cert via DNS-01 challenge against Route 53. The TLS Secret materialized in-cluster is referenced by OCP Routes via `tls.externalCertificate`.

**Considered:** AWS Certificate Manager (ACM).

**Why:** ACM-issued cert private keys cannot be pulled into OCP Routes — they live in ACM, never leave. OCP Routes need the cert + key in a K8s Secret to do edge termination. cert-manager + DNS-01 + R53 is the standard pattern.

**Tradeoffs:** A tiny IAM user with R53 perms must live in-cluster (`cert-manager` static IAM key in K8s Secret). Documented in `docs/aws-creds.md`.

**Trigger to revisit:** If we ever move to OCP-on-IRSA, replace the static IAM user with role assumption.

---

## 6. RHAIIS standalone Deployment (not RHOAI ServingRuntime)

**Picked:** A vanilla Kubernetes Deployment in the `ocp-ai` namespace pulling `registry.redhat.io/rhoai/vllm-cuda-rhel9:latest`. NodeSelector targets `nvidia.com/gpu.present=true`; resource request includes `nvidia.com/gpu: 1`.

**Considered:** Deploy the full Red Hat OpenShift AI (RHOAI) operator stack and run RHAIIS as a `ServingRuntime` inside it.

**Why:** Operator surface area. RHOAI is huge (DataScienceCluster CR, multiple namespaces, ~20 operators). Booth is 3 days; debugging RHOAI-specific weirdness at 2pm Tuesday is the wrong fight. Standalone Deployment uses the same RHAIIS image and gives us 90% of the talking points without the operator footprint.

**Tradeoffs:** No fancy ServingRuntime features (auto-scaling, model-mesh, etc.). Acceptable — we're serving one model at low concurrency. README explicitly notes RHAIIS-can-also-run-in-RHOAI for the booth story.

**Trigger to revisit:** Post-event. If we want a "production-shape" demo cluster that mirrors a real customer deployment, the RHOAI path is correct.

---

## 7. RHAIIS GPU image only (no CPU fallback path)

**Picked:** `vllm-cuda-rhel9` with a `nvidia.com/gpu: 1` resource request. The pod can ONLY schedule on the GPU node.

**Considered:** Toggle pattern — `vllm-cpu-rhel9` on converged nodes by default, swap to GPU on booth days; or kustomize overlay for CPU/GPU.

**Why:** Per-user input: "when this cluster is up it needs the GPU(s) running." That removes the toggle complexity entirely. Simpler manifest, simpler operator stack (NFD + GPU operator are now always-on, not conditional), and the converged nodes don't have to size for RHAIIS-on-CPU's 16 GiB memory footprint.

**Tradeoffs:** GPU node always costs $1.21/hr while cluster is up. Acceptable given the ~$87/day total and the destroy/rebuild lifecycle saving cost off-hours.

**Trigger to revisit:** If the cost dashboard shows > $100/day uncomfortable, consider a g4dn.xlarge ($0.526/hr — half the price, T4 instead of A10G; 16 GiB VRAM is tight but works for Granite-3.1-8B fp16).

---

## 8. NFD + NVIDIA GPU Operator (RH-engineered + NVIDIA-engineered/RH-certified)

**Picked:** Node Feature Discovery (`nfd`, `redhat-operators` source) for hardware-feature labeling + NVIDIA GPU Operator (`gpu-operator-certified`, `certified-operators` source) for drivers / device-plugin / DCGM.

**Considered:** Roll our own DaemonSet for GPU drivers (rejected); RHAIIS-bundled-in-RHOAI (see decision #6).

**Why:** Red Hat's own [OCP GPU architecture docs](https://docs.openshift.com/container-platform/4.21/architecture/nvidia-gpu-architecture-overview.html) explicitly direct customers to NVIDIA's certified-operators build. NFD is the dependency. This is the supported, documented pattern.

**Tradeoffs:** Two operator subscriptions instead of zero. NVIDIA GPU Operator is a documented operator-policy exception (alongside CNPG). Worth it.

---

## 9. Cross-account R53 delegation (not single-account everything)

**Picked:** Parent zone `coderdemo.io` lives in a CS-owned AWS account. Child zone `rhsummit.coderdemo.io` lives in the demo sandbox account. Account A delegates the child to Account B's awsdns nameservers via a single NS record. Pure DNS — no IAM cross-account roles.

**Considered:** Move the parent zone into the sandbox account (would have required IT to migrate domain ownership), or run the entire demo in the CS account (mixes demo cluster lifecycle with shared account state).

**Why:** Cleanest separation. Sandbox is throwaway, parent zone is shared infra. Delegation is one NS record on the parent's side; no IAM trust to maintain.

**Tradeoffs:** First-time pain to set up (we built `scripts/bootstrap-r53-delegation.sh` to make it idempotent). Once delegated, no further cross-account work.

---

## 10. Mint-mode Cloud Credential Operator + 2 scoped IAM users (not IRSA, not passthrough)

**Picked:** `openshift-install` runs in default mint mode — creates long-lived IAM users with scoped policies for each cluster operator that needs AWS, drops keys into K8s Secrets. Plus 2 IAM users we layered: `<cluster_name>-cert-manager` (R53 ACME) and `<cluster_name>-coder-bedrock` (Bedrock invocations).

**Considered:**
- Passthrough mode (cluster uses your install-time creds) — rejected, your SSO expires and the cluster breaks.
- IRSA / `credentialsMode: Manual` — production-correct, but requires `ccoctl` pre-install setup, ~20 extra min, more moving parts.

**Why:** Mint mode is zero pre-install work. Static keys are fine for a 3-week demo cluster. Two scoped IAM users with narrow policies (`bedrock:Invoke*`, R53 on the base zone only) is a small surface.

**Tradeoffs:** Static keys live in K8s Secrets and TF state. Documented as a deferred production-hardening item in `docs/aws-creds.md`.

**Trigger to revisit:** Post-event, if customers ask "how would you do this in prod?" — IRSA migration is the answer.

---

## 11. Coder v2.33.0-rc.3 (latest tagged RC, not main HEAD)

**Picked:** `coder_chart_version = "2.33.0-rc.3"`, image `v2.33.0-rc.3`. Pinned because RC tags are the stable cut points; main HEAD on a Tuesday isn't necessarily a tagged RC.

**Considered:** Pin to a stable release; track main HEAD.

**Why:** RC has Coder Agents Early Access functionality the booth demo needs (no stable release does as of 2026-04). main HEAD is a moving target — a 3am-yesterday merge could break the booth. RC tag = cut point we can verify against.

**Trigger to revisit:** When a newer rc.N tag ships, bump. When stable v2.33.0 GAs, bump to that.

---

## 12. SBOM verifier sample app (not payments-api)

**Picked:** Sample repo `coder/demo-sbom-verifier` — a tiny Go HTTP service with a deliberately-stubbed SLSA-3 attestation signature verifier. Booth flow: agent reads `TASK.md`, fixes the stub with real ed25519 verification, tests pass.

**Considered:** Generic `coder/demo-payments-api` (the original plan) — POST /checkout endpoint missing input validation.

**Why:** PubSec relevance. EO 14028 §4(e)(iii) is universal across DoD / IC / civilian; the SBOM/SLSA narrative pairs naturally with Red Hat's Trusted Software Supply Chain story on the show floor; "AI agent strengthens supply-chain security" is the cleanest pairing with the AI Governance pillar.

**Tradeoffs:** Slightly less universally relatable than payments validation (everyone has done input validation). The PubSec audience finds it more compelling.

---

## 13. Sample-repo seed pattern: main IS the seed (not seed/ dir + reset script)

**Picked:** `main` always holds the broken state. Branch protection blocks force-pushes + merges. Each Coder workspace clones fresh. `make reset` exists for in-workspace re-runs but isn't strictly necessary because workspaces are ephemeral.

**Considered:** Explicit `seed/` directory with canonical broken files + a `seed-reset.sh` script.

**Why:** Simpler. The ephemeral-workspace model already gives freshness. One less moving part.

**Tradeoffs:** If someone accidentally merges a fix to `main` (e.g., bypasses branch protection), the seed gets corrupted. Acceptable risk for a 3-week demo with a small team.

---

## 14. Anonymous Grafana viewer (not GitHub OAuth)

**Picked:** Grafana's anonymous-viewer setting enabled for the booth. Visitors can browse dashboards without logging in. Admin password is set for editing.

**Considered:** GitHub OAuth (the k3s-infra reference uses this with org allowlist).

**Why:** Booth visitors wouldn't have a GH account in our org; OAuth would require us to grant per-visitor access. Anonymous viewer = "click the link, see the dashboards."

**Tradeoffs:** Anyone on the internet who finds the URL can see the dashboards. The dashboards have no PII (just metrics + audit logs of demo activity). Not a concern.

**Trigger to revisit:** For production, switch to OIDC with a Coder org IdP.

---

## 15. S3 + DynamoDB remote TF state (not local state, not Terraform Cloud)

**Picked:** Terraform state in S3 bucket `tfstate-coder-demo-aigov-rhsummit-2026-<account-id>`, locking via DynamoDB table `...-tflock`. Both `terraform/` and `terraform/prereqs/` use the shared backend with different keys.

**Considered:**
- Local state (start-of-project default) — doesn't scale to a 3-person team
- Terraform Cloud — extra account, extra friction for a short-lived demo

**Why:** Standard pattern. Shared TF state means any teammate with sandbox SSO can plan/apply from their own laptop. DynamoDB lock prevents concurrent applies stepping on each other. Bucket has versioning + AES256 + public-access fully blocked.

**Tradeoffs:** $0 cost (DynamoDB pay-per-request, S3 GB-cents). `terraform destroy` on the prereqs/ won't auto-clean the bucket — that needs a separate cleanup script post-event.

---

## 16. Declarative destroy/rebuild lifecycle (not ec2 stop/start)

**Picked:** Cluster lives via `terraform apply`; goes away via `terraform destroy`. Mon morning up / Fri evening down for prep weeks (saves ~$425/wk vs always-up).

**Considered:** EC2 stop/start during off-hours; cluster autoscale to zero.

**Why:** OCP doesn't tolerate `ec2 stop/start` cleanly — etcd quorum, kubelet TLS rot, IPI-managed ELBs all break. Destroy/rebuild is the only safe pattern. Bedrock model access + R53 delegation + GHCR images all survive destroy, so rebuild only takes ~75 min.

**Tradeoffs:** ~75 min cold start. For a "I want to test something for 5 minutes" cycle, painful. For a "build this for 3 weeks" cycle, fine.

---

## 17. Bedrock invocation logging deliberately NOT enabled

**Picked:** No Bedrock-side audit trail. The demo's audit story is application-layer (Coder AI Gateway audit log + Loki).

**Considered:** Enable Bedrock model invocation logging (publishes every InvokeModel call to CloudWatch Logs).

**Why:** User-direct call: keep the demo RH + Coder agnostic, infrastructure-agnostic. Enabling AWS-specific governance hooks weakens the "this is the same story on Azure / on-prem" narrative.

**Trigger to revisit:** If a federal customer specifically asks "what about cloud-side audit?" — the answer is "yes, every cloud has equivalent invocation logging; for our demo we showed the application layer because it's portable." This is in `docs/aws-creds.md`'s production-hardening checklist as a deferred item.

---

## 18. No shared Coder workspace for team collaboration (separate laptops + shared TF state)

**Picked:** Each teammate runs their own laptop. Shared TF state on S3 makes everyone's `terraform apply/destroy` operate against the same cluster.

**Considered:** A shared Coder workspace (dev.coder.com) where the team logs into one ephemeral env.

**Why:** 3 people on a small repo. Shared workspace means only one can edit at a time without git conflicts. Coder workspaces are the booth-day artifact; they're not the development substrate.

---

## Decisions explicitly deferred to post-event

These came up; we said "not for booth, document and move on":

- **IRSA migration** — replace static IAM keys with role-assumption (decision #10)
- **STIG/FIPS hardening** — `restricted-v2` SCC overrides, `fips: true` in install-config
- **Vault for secrets** — too heavy for the demo's 3 secrets
- **AAP for sprint trigger** — replaced with GitHub Actions
- **Tekton for sprint trigger** — same
- **AWS Load Balancer Controller** — overkill; OCP IngressController serves Routes
- **External-DNS** — manual cert-manager + Route 53 is fine for one cluster
- **LokiStack with S3 backing** — local PVC is fine for 7-day retention
- **Tempo / Service Mesh / multi-cluster** — out of scope
- **Bedrock invocation logging** — see decision #17
- **OIDC / Keycloak SSO into Coder** — booth-acceptable to use Coder's built-in user/pass

---

## What changed since the original plan

The original plan (from Austen's pre-PTO context) had these decisions slightly different. They were updated mid-build:

| Original | Final | Why |
|---|---|---|
| `coder/demo-payments-api` sample | `coder/demo-sbom-verifier` | PubSec relevance (decision #12) |
| 3 CP m6i.xlarge + 3 worker m6i.2xlarge | 3 × m6i.4xlarge converged + 1 × g5.2xlarge GPU | Sizing math + GPU narrative (decisions #2, #7) |
| GPU as a toggle (`replicas: 0`/`1` MachineSet) | GPU always 1 replica | "Cluster up = GPU up" (decision #7) |
| `rh.coderdemo.io` | `rhsummit.coderdemo.io` | More specific to the event |
| OCP 4.20 | OCP 4.21 | Latest stable when verified (decision #11 reasoning extends here too) |
| Bedrock model-access UI step | First-invoke auto-enable | AWS retired the page in late 2025 |
