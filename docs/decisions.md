# Decisions log — Coder + RH Summit 2026 demo

> Architectural and operational decisions made during the demo build, with the alternatives we considered and why we picked what we picked.
> If you're tempted to revisit one of these — read the "why" first; we may have already burned that path.
> Last updated 2026-05-10.

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

**Converged scheduler config (post-install):** `Scheduler/cluster` is patched with `spec.mastersSchedulable: true`, owned by `gitops/apps/cluster-config/`. Without that, masters keep the `node-role.kubernetes.io/master:NoSchedule` taint and only pods that explicitly tolerate it can land — defeating the converged shape. The masters are also given the `node-role.kubernetes.io/worker` label so they show up in `oc get nodes` as `control-plane,master,worker` (cosmetic + matches what node-selectors targeting `worker` expect). Setting `mastersSchedulable: true` is non-disruptive (no MCO-driven reboot); reverting it WOULD evict untolerated pods from masters, so don't flip back without intent. Apps no longer carry a master toleration — the Scheduler patch is the single source of truth.

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

**Picked:** Parent zone `coderdemo.io` lives in a CS-owned AWS account. Child zone `rhsummit.coderdemo.io` lives in the demo ocp-deploy account. Account A delegates the child to Account B's awsdns nameservers via a single NS record. Pure DNS — no IAM cross-account roles.

**Considered:** Move the parent zone into the ocp-deploy account (would have required IT to migrate domain ownership), or run the entire demo in the CS account (mixes demo cluster lifecycle with shared account state).

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

## 11. Coder v2.33.1 (stable; Agents now beta, no longer behind an experiment flag)

**Picked:** `coder_chart_version = "2.33.1"`, image `v2.33.1`. Stable release.

**Considered:** Pin to an RC; track main HEAD.

**Why:** Original choice was `2.33.0-rc.3` because that was the only build with Coder Agents (Early Access experiment). v2.33.1 (released after the 2.33.0 line stabilized) **removed the `agents` experiment flag and promoted Agents to beta** (PR coder/coder#24432) — the demo no longer needs `CODER_EXPERIMENTS=agents`. Stable cut > RC for booth reliability.

**Trigger to revisit:** Bump on Coder minor releases (every ~2 weeks per Coder's mainline cadence). Validate AI Bridge + agents flows after each bump.

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

**Why:** Standard pattern. Shared TF state means any teammate with ocp-deploy SSO can plan/apply from their own laptop. DynamoDB lock prevents concurrent applies stepping on each other. Bucket has versioning + AES256 + public-access fully blocked.

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

## 19. Bitnami Sealed Secrets for in-Git secret management (not SOPS, not ESO+ASM, not Vault, not inline)

**Picked:** Bitnami Sealed Secrets controller deployed via Argo CD (`gitops/apps/sealed-secrets/application.yaml`, sync wave -1). Encrypted `SealedSecret` CRs live in `manifests/secrets/` and are decrypted in-cluster by the controller. Workflow doc at [`docs/secrets.md`](secrets.md).

**Considered:**
- **SOPS + age/GPG + Argo CD plugin (KSOPS / argocd-vault-plugin)** — encryption keys live as files; needs an Argo plugin to decrypt at sync time, which means a custom Argo image or initContainer.
- **External Secrets Operator + AWS Secrets Manager** — would have been the AWS-native answer (IRSA already works for the IAM grant). Cleanest for rotation, supports drift correction, no sealing-key DR risk.
- **HashiCorp Vault** — overkill for a demo with two managed secrets.
- **Inline values committed to Git** — non-starter for OAuth client secrets.
- **`oc create secret` out-of-band, not in Git** — works but breaks the "every cluster-side state is a `git push`" Argo narrative we're selling at the booth.

**Why:**
- **On-prem-portability dominates.** Same theme as #3 (CNPG over RDS) and #4 (GHCR over ECR). The audience is OCP platform engineers running OpenShift on AWS, Azure, vSphere, bare-metal, air-gap. ESO+ASM is the most operationally clean choice on AWS, but it ties the secret-management narrative to AWS — exactly what we avoided for Postgres and the registry. Sealed Secrets runs identically on any cluster; "the controller is in your cluster" is a story that scales to all of them.
- **Workflow parity with the existing K3s lab** (`zambruhni.com`). Operators already know `kubectl create secret … | kubeseal …`. No new mental model.
- **Argo manages the cipher.** SealedSecret CRs are normal Argo-tracked resources; rotation is a `git commit` + push, like every other change in this repo.
- **The deferred-secret-mgmt risks are bounded:**
  - Sealing-key DR — backed up to 1Password / Vault on day 1; without it, every secret has to be re-sealed (acceptable for a demo lifecycle).
  - Namespace-scoped by default — fine, every secret here is per-namespace.
  - No native rotation API — manual re-seal, fine for the few secrets we have.

**Tradeoffs:** Lose the AWS-native rotation story we'd have gotten with ESO+ASM. Sealing key is a single point of failure if both the cluster and the backup vault are lost simultaneously — bus factor, not a daily concern.

**Trigger to revisit:** If the customer story shifts to AWS-only production architectures (full ASM + KMS encryption-at-rest + automated rotation narrative), swap to ESO+ASM. For booth: never.

**Note (OpenShift compat):** The upstream Bitnami chart hardcodes `podSecurityContext.fsGroup: 65534` and `containerSecurityContext.runAsUser: 1001`. Those IDs fall outside the per-namespace `openshift.io/sa.scc.uid-range` and are rejected by `restricted-v2` admission, leaving the Deployment in `ReplicaFailure`. The Helm values in `gitops/apps/sealed-secrets/application.yaml` disable the pod-level block entirely (`podSecurityContext.enabled: false`) and null `containerSecurityContext.runAsUser`, so the SCC mutating admission injects valid IDs from the namespace range while the chart's other container hardening (drop ALL caps, readOnlyRootFilesystem, RuntimeDefault seccomp) is preserved.

**Note (registry):** The same Helm values override the chart's default `docker.io/bitnami/sealed-secrets-controller` image to `ghcr.io/bitnami-labs/sealed-secrets-controller`. Docker Hub's anonymous pull rate limit trips reliably during a fresh-cluster sync (multiple nodes pulling the same image simultaneously → 429). The upstream `bitnami-labs/sealed-secrets` project publishes the same controller binary to GHCR; using it stays consistent with decision #4's GHCR-first registry policy.

---

## 20. GitHub OAuth into Coder, scoped to the `demo-rhsummit-users` org (not Coder built-in user/pass, not OIDC/Keycloak)

**Picked:** Coder server runs with `CODER_DISABLE_PASSWORD_AUTH=true` and `CODER_OAUTH2_GITHUB_ALLOWED_ORGS=demo-rhsummit-users`. The OAuth client ID/secret live in the `coder-secrets` SealedSecret. Same OAuth app is reused as `CODER_EXTERNAL_AUTH_0_*` so workspaces inherit GitHub creds for git operations.

**Considered:**
- **Coder built-in user/pass** — what the original plan deferred to (`booth-acceptable to use Coder's built-in user/pass`). Reversed: passwords in a multi-person demo are friction, the GitHub org gate is sharper.
- **OIDC into Keycloak / RH SSO** — closer to a federal-customer story but adds a Keycloak install + realm config the demo doesn't need; we have one access boundary (`demo-rhsummit-users` membership) and that's it.
- **Reuse `coder/coder` GitHub org** — too broad; we want a clean cohort.

**Why:** The org is the access boundary. Anyone we want in the demo gets invited to `demo-rhsummit-users`; everyone else hits "you're not a member of this org" at login. No password storage, no per-user creation flow during a booth crunch. The same OAuth app doubling as the workspace's git provider means cloning a private repo Just Works after login.

**Tradeoffs:** Requires a GitHub org for the demo audience. Not a problem; we already have one. Password fallback is gone — if GitHub is down, no one logs in.

**Trigger to revisit:** A federal customer says "no GitHub" — swap to RH SSO via OIDC.

---

## 21. GitHub OAuth into OpenShift, with `demo-rhsummit-users:admin` team → `cluster-admin` via redhat-cop/group-sync-operator (not OIDC, not manual `oc adm groups sync`, not a hand-maintained Group)

**Picked:** A second GitHub OAuth app (separate from Coder's — GitHub apps are bound to a single callback URL) is wired into the singleton `OAuth/cluster` CR as a `GitHub` identityProvider, gated by `organizations: [demo-rhsummit-users]`. Cluster-admin elevation comes from membership in the `admin` team within that org: the `redhat-cop/group-sync-operator` (installed from the `community-operators` OLM catalog) polls GitHub every 5 minutes and reconciles the `admin` GitHub team into the OpenShift `Group/admin`. A `ClusterRoleBinding` binds that Group to `cluster-admin`. All of it (OAuth IdP patch, GroupSync CR, ClusterRoleBinding, sealed PAT secret) lives under `gitops/apps/cluster-config/` + `gitops/apps/group-sync-operator/`.

**Considered:**
- **Hand-maintained `Group/admins` resource** — list the GitHub usernames in YAML. Simple, no operator, but every admin team change is a PR. Acceptable for a stable demo team but a lousy story if we want to demo "remove an admin via GitHub UI and watch RBAC follow."
- **`oc adm groups sync` CronJob** — same end state as the operator, fewer moving parts (no OLM CSV, no operator pod). Less polished, no UI in the OpenShift console, no watch-driven reconciliation. Rejected: the operator's scheduled-sync-with-status-conditions story matches the GitOps narrative better.
- **OIDC via Keycloak/RH SSO with GitHub IdP behind it** — Keycloak surfaces team membership as group claims, removing the need for a separate sync loop. Right answer for federal customers but an extra dependency to install/configure for a demo whose narrative is "GitHub is the single source of truth." Same trigger as decision #20: revisit if the customer story shifts.
- **Map GitHub identity to OpenShift cluster-admin via the IdP's `teams:` field** (instead of `organizations:`) — the GitHub IdP DOES auto-create OpenShift Groups for listed teams. But specifying `teams:` instead of `organizations:` restricts login to admin team members only — non-admin org members can't get in at all. We need both: any org member can log in (read-only), admin team gets `cluster-admin`. Two scopes, two mechanisms.

**Why:**
- **Single source of truth = GitHub.** Org membership controls "can log in," team membership controls "is cluster-admin." Both are managed by whoever administers the GitHub org via the standard GitHub UI/CLI; no second admin surface, no PRs.
- **5-minute reconcile loop is fast enough for a demo** ("add me to the admin team, watch me get cluster-admin within 5 minutes") and well under GitHub's 5000 req/hour authed rate limit.
- **Operator > CronJob > YAML.** OLM-managed install means uninstalling = deleting the Subscription. Status surfaces in `oc get groupsync`. Audit-friendly: each sync is logged with sync-time annotations on the resulting Group.
- **Separate OAuth app from Coder** is forced by GitHub (one callback URL per app). The OAuth app's client secret is a SealedSecret in `openshift-config`; the read:org PAT for the operator is a SealedSecret in `group-sync-operator`. Both rotate the same way every other secret in this repo does (decision #19's workflow).

**Tradeoffs:**
- **Coder Owner role is NOT auto-synced from the admin team.** Coder's GitHub OAuth doesn't expose a team→role mapping mechanism (the `CODER_OAUTH2_GITHUB_*` env vars only restrict login, not assign roles). Adding a Coder admin requires a manual `coder users edit-roles <user> --roles owner` once they've logged in for the first time. Documented in `docs/secrets.md` (or wherever the Coder admin runbook lives). Acceptable cost given how rarely admins get added.
- **Group name is just `admin`** — the operator's GitHub provider names the synced Group after the team slug, not `<org>-<team>`. If we ever sync admin teams from multiple orgs they'd collide; for one org that's fine and the short name is more readable.
- **Operator install requires `OwnNamespace` mode**, not `AllNamespaces` (the CSV's installModes don't allow it). The OperatorGroup pins `targetNamespaces: [group-sync-operator]`. The operator still manages cluster-scoped Group resources globally — install mode controls only what the controller WATCHES.

**Trigger to revisit:** Adding a second OpenShift cluster — the operator + GroupSync CR + sealed PAT lift into the new cluster's bootstrap unchanged, so this scales fine. If we add a second GitHub org with its own admin team, swap the GitHub provider to use a transform that prefixes the group name with the org so the names don't collide.

---

## 22. coder-observability translated from k3s ref to OpenShift (in-place fixes, not OpenShift Logging operator)

**Picked:** Run the upstream `coder-observability` Helm chart (`helm.coder.com/observability`, v0.7.1) on OCP with values overrides for every OCP-specific incompatibility. Same story zambruhni-refs/k3s-infra deploys, adapted in `gitops/apps/observability/application.yaml`. Grafana served at `https://graf-coder.apps.cluster.rhsummit.coderdemo.io` via OCP Route + cert-manager Certificate, GitHub OAuth gated to `demo-rhsummit-users`, admin team mapped to Grafana Admin role.

**Considered:**
- **OpenShift Logging operator (Vector + LokiStack)** — the canonical RH way. Operator-managed install, signed SCCs, integrated with the cluster-monitoring stack. Right answer for production. Rejected for the demo because the chart we're reusing from k3s carries the Coder-specific dashboards, AI Bridge panels, agent-boundaries panels, and alert rules — re-implementing those on top of LokiStack would be a separate project.
- **Skip log shipping** — keep just Grafana + Prometheus, drop Loki + grafana-agent. Smaller surface but the AI Gateway / AI Bridge dashboards lean on log queries to surface tool-call traces, so this would degrade the demo narrative.

**Why:** Chart re-use is the dominant story — same dashboards, same alerts, same workflow as the existing K3s lab. Demo audience sees one stack across both clusters, with the only operational delta being "OCP needs these SCC overrides" — itself a useful talking point about restricted-v2.

**Translation work (every override has a comment in `application.yaml`):**

- **SCC compliance** — chart subcharts hardcode UIDs that violate the namespace's `openshift.io/sa.scc.uid-range` (1000800000/10000 for `coder-observability`). Overrides:
  - `grafana.securityContext` — chart default UID 472 → pin to 1000800000 (chart's init-chown-data init container references runAsUser inline in its `chown` command, so null-then-inject would break the rendered StatefulSet).
  - `grafana.initChownData.enabled: false` — OCP's CSI driver chgrps the PV at mount time using SCC-injected fsGroup, so manual chown is redundant. Avoids the init container entirely.
  - `prometheus.server.securityContext` — chart default 65534 → null (schema permits null here).
  - `prometheus.alertmanager.{podSecurityContext,securityContext}` — chart default 65534 → 1000800000 (schema strict-types as integer; null fails).
  - `prometheus.kube-state-metrics.securityContext` — chart default 65534 → 1000800000 (same reason).
  - `loki.loki.podSecurityContext` — chart default 10001 → null.
  - `loki.gateway.podSecurityContext` — chart default 101 → null.
  - `loki.minio.securityContext` — chart default 1000 → 1000800000 (same schema-strict-integer pattern as alertmanager).

- **DNS resolver** — `loki.gateway` is nginx and embeds `<dnsService>.<dnsNamespace>.svc.cluster.local` from chart globals. Defaults are `kube-dns.kube-system` (k3s/vanilla k8s naming); OCP's CoreDNS Service is `dns-default.openshift-dns`. Override `loki.global.{dnsService,dnsNamespace}` so nginx resolves at boot.

- **Image registries** — Docker Hub anonymous rate-limit catches three subcharts on a fresh-cluster sync:
  - `loki.memcached.image.repository: mirror.gcr.io/library/memcached` (was `docker.io/library/memcached`).
  - `loki.memcachedExporter.enabled: false` — `prom/memcached-exporter` has no published mirror; we lose memcached-self metrics, cache function still works.
  - `sqlExporter.enabled: false` — `burningalchemist/sql_exporter` is DH-only. Disabling drops Coder-specific Postgres SQL business metrics; control-plane Prometheus metrics still come from Coder pods directly via `prometheus.io/scrape`.

- **Postgres exporter** — `global.postgres.exporter.enabled: false`. Chart wants a `secret-postgres` Secret with `PGUSER`/`PGPASSWORD`/etc. CNPG's auto-generated `coder-app` Secret uses different keys (`uri`, `host`, `port`, `dbname`, `user`, `password`, `jdbc-uri`). Wiring a translation Secret/Job is follow-up work; for the booth Prom + Loki + Grafana dashboards work without postgres metrics.

- **MinIO memory request** — `loki.minio.resources.requests.memory: 1Gi` (was 16Gi chart default). 16Gi is sized for a production object-store replica; one demo bucket with no real data load doesn't need it, and the request would block scheduling on the converged 3-node cluster.

- **OCP node-exporter collision** — `prometheus.prometheus-node-exporter.enabled: false` because OCP ships its own as part of the cluster-monitoring stack on port 9100.

- **grafana-agent SCC binding** — the agent DaemonSet ships node + container logs to Loki via hostPath mounts (`/var/log`, `/var/lib/docker/containers`). `restricted-v2` blocks hostPath. `manifests/observability/grafana-agent-scc.yaml` binds the agent's SA to the `hostmount-anyuid` SCC — narrower than `privileged`, the OCP-standard for log/metric shippers. Production should switch to OpenShift Logging (operator-managed SCCs).

- **Grafana OAuth** — sealed `manifests/secrets/grafana-github-oauth.yaml` (keys `GF_AUTH_GITHUB_CLIENT_ID` / `_CLIENT_SECRET`) fed via `grafana.envFromSecret`. `grafana.ini.auth.github.role_attribute_path` maps `@demo-rhsummit-users/admin` membership to Grafana Admin role; everyone else lands as Viewer. `skip_org_role_sync: true` so the path is evaluated on every login. Same admin team that drives OpenShift cluster-admin (decision #21) — one team change covers both.

- **OCP Route** — `manifests/observability/route.yaml` targets Service `grafana` (not the chart's older `<release>-grafana` convention) on port name `service`. Cert-manager Certificate at `manifests/observability/certificate.yaml` issues `graf-coder.apps...` from the Let's Encrypt cluster issuer.

**Tradeoffs:**
- We lose `sql-exporter` (Coder SQL business metrics) and the `memcached_exporter` self-metrics — both deferred until we mirror their DH images to a registry we control.
- `postgres-exporter` is disabled; postgres-specific Grafana dashboards will be empty.
- `grafana-agent` uses a broader-than-restricted-v2 SCC. Acceptable for the demo where the agent is the only pod that needs hostPath; production swaps to operator-managed bindings.
- A small set of resources still report `OutOfSync` in Argo (orphan grafana PVC from a chart-template artifact, SSA managedFields cosmetic diffs on three StatefulSets, ClusterRole/CRB tracking-id labels). All Healthy; cosmetic-only.

**Trigger to revisit:** A federal customer requires operator-managed observability — swap to OpenShift Logging (Vector + LokiStack) and consume the same dashboards via dual-source Argo. Also revisit if the Coder team publishes a non-DH `sql-exporter` mirror.

---

## 23. Two `-ocp` workspace templates only (not five)

**Picked:** Ship just `coder-templates/ai-dev-ocp/` and `coder-templates/agents-dev-ocp/`. The earlier `openshift-ai-gov`, `ai-dev`, `agents-dev`, `demo-ai-gov-firewall-ocp`, and `demo-ai-gov-no-firewall-ocp` templates were deleted from the repo and removed from the Coder server.

**Considered:** Keep the firewall-on/off A-B narrative templates for the governance story.

**Why:**
- Booth narrative is "show the open model do what Claude does on the same workspace UX" — that needs ONE solid CLI-driven workspace (`ai-dev-ocp`: code-server + Claude/Codex/Gemini/Kiro CLI + Cursor/Kiro IDE) and ONE chatd-driven workspace (`agents-dev-ocp`: code-server only, agent loop runs server-side).
- Five templates meant five sets of UBI9 SCC fixes, five GH Actions matrix entries, five sets of sealed-secret consumers — too much surface for one event.
- The firewall narrative still works at-cluster level (Bedrock IRSA scoping, AI Bridge `ALLOW_BYOK=false` enforcement, restricted-v2 SCC); we don't need separate templates to demonstrate it.

**Tradeoffs:** No live A-B demonstration of agent-process-firewall toggling. If we want it back, the `demo-ai-gov-*-ocp` templates can be restored from git history (they were deleted, not archived).

**Trigger to revisit:** Customer specifically asks "show me what the egress-blocked variant does differently."

---

## 24. UBI9 9.7 workspace base images on GHCR (renamed from workspace-base / enterprise-node)

**Picked:** Three images at `coder-templates/images/`:
- `ubi9-base-workspace` — UBI 9.7 + EPEL + zsh/tmux/neovim/fzf/ripgrep/fd-find + starship + the SCC-compliant `uid_entrypoint.sh` pattern + `chgrp -R 0 /home/coder && chmod -R g=u`.
- `ubi9-node-workspace` — `FROM ubi9-base-workspace`, adds NodeSource Node 22 + corepack + TypeScript.
- `agents-config-tools` — UBI9-minimal + aws + jq + curl, used by the `coder-agents-config` Argo Job pod.

Tags: `<name>:<UBI9_VERSION>` (currently `9.7`), `<name>:<UBI9_VERSION>-<git-sha>` (immutable pinable), `<name>:latest`. Built by `.github/workflows/build-images.yml` on `coder-templates/images/**` push.

**Considered:** Leave the original `codercom/workspace-base:ubuntu` and `codercom/enterprise-node:ubuntu` images.

**Why:**
- UBI9 is the right narrative for an OpenShift demo — "Red Hat's container base, on Red Hat's Kubernetes, running Red Hat's AI Inference Server."
- Restricted-v2 SCC drops `CAP_SETUID` so `sudo` doesn't elevate; the `uid_entrypoint.sh` pattern (Red Hat's S2I convention) appends a passwd entry for the runtime UID and `chgrp 0 + chmod g=u` makes `/home/coder` writable by any UID in the namespace's allowed range.
- The original Ubuntu images had hard-coded UID 1000 + `apt-get install` + sudo expectations; replacing them piecemeal across templates kept reintroducing Ubuntu-isms.

**Tradeoffs:**
- UBI9 strips some packages (tmux), so we pull tmux from Rocky 9 BaseOS in the base image.
- Two-stage build (`ubi9-node-workspace FROM ubi9-base-workspace`) needs `:9.7-<sha>` pinning at FROM-time so the second image doesn't accidentally use a stale `:latest`. The build workflow does this correctly via the `WORKSPACE_BASE` build-arg.

**Trigger to revisit:** Coder ships an official UBI-based workspace base; switch to it.

---

## 25. Static Bedrock model allowlist (not `aws bedrock list-inference-profiles` at runtime)

**Picked:** `scripts/coder-agents-provider-model-config.sh` ships an explicit 7-ID allowlist of `us.anthropic.*` cross-region inference profiles:
```
us.anthropic.claude-sonnet-4-20250514-v1:0   ← demo primary, default
us.anthropic.claude-sonnet-4-6
us.anthropic.claude-sonnet-4-5-20250929-v1:0
us.anthropic.claude-opus-4-7
us.anthropic.claude-opus-4-6-v1
us.anthropic.claude-opus-4-5-20251101-v1:0
us.anthropic.claude-opus-4-1-20250805-v1:0
```

Verified subscribed + IRSA-invocable on 2026-05-09 by kiro-cli using the marketplace-permitted `ocp-deploy-acct` SSO profile. Subscription procedure documented in `bedrock-model-sub.md`.

**Considered:** Dynamic discovery via `aws bedrock list-inference-profiles --type-equals SYSTEM_DEFINED | jq 'opus|sonnet'`.

**Why:** Discovery returns ~16 Anthropic profiles in `us-east-1`, but only a subset is invocable — account-wide AWS Marketplace subscription must have been completed for each profile by an `aws-marketplace:Subscribe`-permitted principal. Registering an unsubscribed model in chatd surfaced a 403 ("AWS Marketplace subscription cannot be completed at this time") on first call, which the Coder Agents UI rendered as a generic "Authentication failed" — confusing for booth visitors. Pinning the allowlist makes the picker only show working models. Dynamic discovery also picked up `global.*`-prefix profiles (different from `us.*`) and legacy `claude-3-*` profiles, none of which were subscribed.

**Tradeoffs:**
- Adding a new model means editing the script + `bedrock-model-sub.md` + re-running the Job. The procedure is one paragraph in the bedrock doc.
- Haiku 4.5 (`us.anthropic.claude-haiku-4-5-20251001-v1:0`) is intentionally NOT in the allowlist — it requires the Anthropic use-case form in the Bedrock console (one subscription that the marketplace-permitted bedrock-runtime invoke can't complete on its own).

**Trigger to revisit:** AWS exposes Bedrock FM subscription as a first-class CLI/API operation (the "marketplace-catalog start-change-set" path is documented but not yet covering Bedrock FMs as of 2026-05).

---

## 26. RHAIIS vLLM `--max-model-len` sized to the GPU's free KV cache budget

**Picked:**
- A10G (g5.2xlarge, 24 GiB) running 8B fp16 → `--max-model-len 16384`.
- L40S (g6e.2xlarge, 48 GiB) running 32B AWQ → `--max-model-len 32768`.
A `startupProbe` (15-20 min runway) gates liveness so the slow weight download doesn't get killed mid-load and force a re-download.

**Considered:** Keep the original 8K, or push to 32K on A10G.

**Why:**
- 8K was too small for Coder Agents — chatd's system prompt + 19-tool schema + chat history + 4K completion budget produced 8502-token requests, vLLM 400'd, chatd surfaced "OpenAI Compatible rejected the model configuration."
- 32K on A10G crashed at vLLM init: 8B fp16 weights consume 15.25 GiB, cudagraph buffers another ~1-2 GiB, leaving only 3.77 GiB for KV cache — and 32K context needs 5.00 GiB. Explicit error: `ValueError: To serve at least one request with the models's max seq len (32768), (5.00 GiB KV cache is needed, which is larger than the available KV cache memory (3.77 GiB).`
- 16K on A10G fit comfortably (~2.5 GiB KV cache, ~1.2 GiB headroom) — twice the original 8K cap and well above Coder Agents' typical working set.
- Moving to L40S (decision #27) freed the budget to run 32K + a 32B AWQ model.

**Tradeoffs:** Per-GPU calibration. If GPU changes, both `--max-model-len` and the chatd `context_limit` must be re-tuned together (mismatched limits silently truncate prompts). The script is the single source of truth — re-render the configmap after edits.

**Trigger to revisit:** Move to A100 80 GiB / H100 80 GiB → can extend to 128K (Granite/Qwen native) via YaRN. Or add prefix-caching tuning if observed hit rates are high.

---

## 27. Qwen 2.5 Coder 32B Instruct AWQ on L40S (not Granite 3.1 8B on A10G)

**Picked:** RHAIIS serves `Qwen/Qwen2.5-Coder-32B-Instruct-AWQ` on a `g6e.2xlarge` (1× NVIDIA L40S, 48 GiB) provisioned by a second MachineSet (`manifests/machinesets/gpu-l40s.yaml`). vLLM args: `--quantization awq_marlin`, `--tool-call-parser hermes`, `--max-model-len 32768`. The original `g5.2xlarge`/A10G MachineSet stays in place as the backout target.

**Considered:**
1. Stay on Granite 3.1 8B / A10G.
2. Swap model only: Qwen 2.5 7B Instruct or Hermes 3 Llama-3.1 8B on the same A10G with `--tool-call-parser hermes`.
3. Llama 3.3 70B Instruct (FP8/INT4 quants from RedHatAI/neuralmagic) on a bigger GPU (A100 80GB / H100).
4. Llama 4 Scout/Maverick.

**Why:**
- Granite 3.1 8B's BFCL v3 = 68.27, mid-pack. With Coder Agents' 19-tool harness (read_file, write_file, edit_files, execute, create_workspace, spawn_agent, ...) the 8B couldn't keep all schemas in working context AND chain them. Verified: chatted fine, never fired tool_calls for workspace creation / file edits / command exec. Meta and IBM both warn 8B is too small for "chat + many tools."
- Qwen 2.5 Coder 32B is purpose-built for agentic coding (SWE-Bench Pro ~44%, well above Llama 3.3 70B on coding tasks).
- AWQ 4-bit quant (~18 GiB on disk, ~19 GiB on GPU) fits L40S 48 GiB with room for 32K KV cache + cudagraph buffers + batch headroom.
- Hermes parser handles Qwen 2.5 Instruct's `<tool_call>...</tool_call>` emission format correctly. (Qwen 2.5 *Coder* base uses a different `<tools>` tag the hermes parser silently fails on — that's why we run the **Instruct** variant, which the 32B quant we picked is.)
- Cost delta: g5.2xlarge ~$1.21/hr → g6e.2xlarge ~$2.24/hr. Acceptable for booth; can scale the L40S MachineSet to 0 between events.

**Tradeoffs:**
- Cost roughly doubles for the GPU pool.
- AWQ quant introduces small accuracy loss (~1-2% on benchmarks). Functionally invisible for the booth use case.
- Qwen origins (Alibaba) may be a sensitivity for some PubSec audiences. **Backup model**: `meta-llama/Llama-3.3-70B-Instruct` is documented in this section as the swap target if Qwen origins come into question. License is the Llama 3.3 Community License (not OSI-OSS — has a >700M MAU clause and acceptable-use policy; fine for ~all enterprises). FP8 / INT4 quants from `RedHatAI/` and `neuralmagic/` namespaces fit either on a single L40S (INT4) or A100 80GB (FP8). vLLM parser: `--tool-call-parser llama3_json`. Caveat: vLLM docs call out Llama 3.x as not supporting parallel tool calls — agent harness still works, just one tool per turn.
- Llama 4 was released but got a mixed reception; Llama 3.3 70B and Qwen 2.5/3 are the practical incumbents for serious tool-using deployments.

**Trigger to revisit:** Qwen origins flagged → swap to Llama 3.3 70B (procedure: change `RHAIIS_MODEL_ID` + `RHAIIS_DISPLAY_NAME` in the script, change `--model` + `--tool-call-parser` in vLLM deployment, possibly bump GPU to A100 80GB if running FP8). DeepSeek V3.x or Qwen 3 Coder pulls ahead on benchmarks → re-evaluate.

---

## 28. Single Llama 3.3 70B INT4 in chatd, planner+executor split deferred until a router lands

**Picked:** Register a single openai-compat provider in chatd ("RHAIIS (Sovereign Llama 3.3 70B)") pointing at `vllm-planner.ocp-ai.svc.cluster.local:8000/v1`, serving `RedHatAI/Llama-3.3-70B-Instruct-quantized.w4a16`. The `vllm-executor` Deployment (Qwen 2.5 7B Instruct on A10G) stays running but is intentionally NOT registered in chatd — the planner+executor architectural goal is deferred.

**The blocker we discovered:** chatd's Postgres schema enforces a UNIQUE constraint on `chat_providers.provider` (the type column — `openai-compat`, `bedrock`, `anthropic`, etc.). Inserting a second `openai-compat` provider returns:

```
HTTP 409 Conflict
{"message":"Chat provider already exists.",
 "detail":"pq: duplicate key value violates unique constraint \"chat_providers_provider_key\""}
```

Conceptually correct: "RHAIIS is the provider, the models it hosts are below it." Implementation-wise, vLLM 0.x serves one model per pod (separate `/v1/chat/completions` endpoints for `vllm-planner` vs `vllm-executor`), and chatd's single openai-compat provider has ONE `base_url`. To present "two backends behind one logical RHAIIS provider" we need a router between chatd and the two vLLM Services that dispatches by the `model:` field in the request body.

**Considered (with research, 2026-05-10):**

1. **LiteLLM** (`ghcr.io/berriai/litellm-non_root:main-stable`) — the de facto answer. ConfigMap-only deploy (`STORE_MODEL_IN_DB=false` to bypass the documented Prisma write-path bug under restricted-v2 SCC, see [BerriAI/litellm#19408](https://github.com/BerriAI/litellm/issues/19408)). Routes by `model:` field; passes vLLM `tool_calls` through cleanly (the documented LiteLLM tool-call bugs are on the Ollama and OpenAI Responses-API translation paths, not on vLLM upstreams). ~10 min to deploy. **Tactical answer if/when we want the planner+executor split now.**

2. **llm-d** (`https://llm-d.ai`, v0.6.0 April 2026) — Red Hat's strategic LLM-serving project, integrated into OpenShift AI 3.0. **Solves a different problem**: intra-model routing across replicas of the SAME model with KV-cache awareness, prefix-cache hints, and queue-depth balancing. Not designed for inter-model dispatch by `model:` field across different models on heterogeneous GPUs. Wrong tool.

3. **agentgateway + Gateway API Inference Extension (GAIE) + llm-d** — Red Hat's documented "MaaS for multiple LLMs on OpenShift" pattern (Red Hat Developer, March 2026). Three Helm charts plus three CRDs (`AgentgatewayPolicy`, `InferencePool`, `HTTPRoute`). The `model:` body extraction is via a CEL expression on `AgentgatewayPolicy`. **The Red-Hat-blessed path** but multi-hour install — overkill for the booth.

4. **Llama Stack** (RHOAI 3.x Tech Preview) — exposes an OpenAI-compatible API and routes inference across vLLM backends. Strategic Red Hat path. **Uses its own API contract** that diverges from stock OpenAI in places (toolkit/agent abstractions). chatd would need an adapter or feature work to consume it. Worth re-evaluating post-Summit when it goes GA.

5. **Coder AI Gateway** (Coder, in flight) — Coder's own answer for routing chatd's openai-compat traffic across multiple backends. Per Coder roadmap chatter, this is where the platform is heading; once it ships, chatd should be able to register N backends via the AI Gateway abstraction without the schema constraint we hit.

6. **OpenShift Service Mesh / Envoy** (Tech Preview GAIE, OSSM 3.1) — Tech Preview status; same underlying GAIE/llm-d stack as #3. Deferred.

7. **3scale API Management with APIcast Lua policy** — possible content-routing on JSON body fields, but no documented Red Hat pattern for LLM model dispatch. Bespoke.

8. **vLLM native multi-model** — confirmed not present in vLLM 0.8.x or 0.9.x. One model per server.

**Why single Llama 3.3 70B for tonight (not LiteLLM right now):**
- The 70B model alone fixes the symptoms that drove the original "two models" discussion: hand-holding on Coder Agents sub-agent flow logic and template selection. 70B-class reasoning is the gap, not architectural separation per se.
- LiteLLM is a 10-minute deploy but adds a new component to the booth lineup. Booth shape stays simpler with one chatd provider, one model, one path of execution to explain.
- The vllm-executor Qwen 7B Deployment is ALREADY warm on the A10G — when we're ready to add a router, it's a config-only flip (LiteLLM ConfigMap, repoint chatd's RHAIIS provider's base_url) without touching vLLM infra.

**Tradeoffs:**
- Llama 3.3 70B Community License is NOT OSI-OSS — has the >700M MAU clause and acceptable-use policy. Acceptable for ~all enterprises; documented backup in §27 is Qwen3 32B Instruct AWQ in the same slot.
- L40S 48 GiB is tight for Llama 70B INT4 + 16K context (`--max-model-len 16384`; 32K would need ~10 GiB additional KV cache and crash init per the same pattern that bit us with Granite at 32K on A10G in §26). Bigger GPU (A100 80 GiB) opens 32K+ context.
- A10G is paying for an idle-from-chatd's-perspective vllm-executor pod. ~$1.21/hr. Acceptable for the tactical demo + future router-drop-in story.

**Trigger to revisit:**
- Coder AI Gateway lands → register both backends via AI Gateway, retire the workaround.
- Llama Stack goes GA in RHOAI → evaluate whether chatd can consume it directly (or via an adapter Coder ships).
- We decide the planner+executor split is actually load-bearing for the demo (not just architecturally interesting) → land LiteLLM ConfigMap (~10 min change documented in this section + the bootstrap script).

---

## 29. GPU + vLLM dashboards in OCP Console only (not Grafana)

**Picked:** Ship the NVIDIA DCGM GPU dashboard and the vLLM serving dashboard as ConfigMaps in `openshift-config-managed` (label `console.openshift.io/dashboard=true`) — surfacing under the OpenShift Console's "Observe → Dashboards" view. **Do not** ship them to the `coder-observability` Grafana.

**Considered:** Ship to both. Initially we did — turned out neither dashboard could populate panels in Grafana because the `coder-observability` Prometheus only scrapes its in-namespace ServiceMonitors (Coder, kube-state-metrics, etc.) and doesn't see the cluster-wide DCGM exporter (`nvidia-gpu-operator/nvidia-dcgm-exporter`) or vLLM metrics (`ocp-ai/vllm-{planner,executor}`).

**Why OCP Console only:**
- OCP Console's dashboard rendering defaults to **Thanos Querier**, which federates BOTH the cluster Prometheus (which scrapes `nvidia-gpu-operator` because that namespace has `openshift.io/cluster-monitoring=true`) AND User Workload Monitoring Prometheus (which scrapes the vLLM ServiceMonitors in `ocp-ai`). Every metric we care about is visible from the OCP Console out of the box.
- Making Grafana see the same metrics would require adding Thanos Querier as a Grafana datasource with a bearer token from a SA bound to `cluster-monitoring-view`, plus TLS wiring against the cluster-internal CA. That's ~30 min of plumbing for "the same dashboard, in a second place." Booth-tonight tradeoff: skip it, document the path.
- Coder-specific dashboards (AI Bridge usage, Agent Boundaries activity, Coder server metrics) keep their home in Grafana — Coder's Prometheus IS positioned to scrape them. Two dashboard surfaces, each scoped to what they're best at.

**Tradeoffs:**
- Operators have to know to look in two places (OCP Console for cluster + GPU + vLLM, Grafana for Coder-specific). Mitigation: link from each to the other in the booth runbook.
- Customers asking "we want all dashboards in one Grafana" need the Thanos federation work done. Documented as future work below.

**Trigger to revisit:**
- Customer requirement for single-pane-of-glass Grafana → land the Thanos datasource + RBAC + TLS plumbing.
- Coder ships its own AI Gateway observability that obviates the need for this dashboard set.
- llm-d goes GA in RHOAI 3.x and includes its own observability dashboards we can adopt directly.

---

## 30. Reverted RHAIIS planner from Llama 3.3 70B INT4 → Qwen 2.5 32B Instruct AWQ

**Picked:** vllm-planner serves `Qwen/Qwen2.5-32B-Instruct-AWQ` with `--tool-call-parser hermes` on the L40S g6e.2xlarge node. The `vllm-executor` Deployment serving Qwen 2.5 7B Instruct on the A10G stays in place but unregistered in chatd (still no router; see §28).

**Considered + tried:** `RedHatAI/Llama-3.3-70B-Instruct-quantized.w4a16` (Llama 3.3 70B INT4, the canonical Red-Hat-blessed quant). Rationale per §27 — strongest planning/reasoning at the 70B-class for sub-agent flow logic and template selection.

**Why the revert:**
- Tried with default cudagraph capture: container hit the 25-min `startupProbe.failureThreshold` mid-compile, cycled 4 times in 50 min without binding `/v1/models` (kubelet SIGKILL at exit 137).
- Bumped startupProbe to 40 min runway + added `--enforce-eager` to skip cudagraph compile entirely.
- Container then **hung silently** after weight load: 38 GiB allocated on the L40S, both python processes (`vllm_tgis_adapter` parent + engine_core child) in `State: S (sleeping)`, total CPU time ~25 seconds across both, ZERO new log output for 37+ minutes, no restart, no crash. Almost certainly a multiprocessing IPC deadlock specific to vLLM 0.8.4 + this INT4 quant + `quay.io/modh/vllm:rhoai-2.20-cuda` image.
- We have no path to debug or work around the deadlock in the booth window. The Qwen 2.5 32B Instruct AWQ stack on the same L40S, same vLLM image, same `--enable-auto-tool-choice` was previously verified end-to-end (per §27): structured tool_calls under `tool_choice: auto`, multi-step agentic chats, no hangs. Known-good > almost-working.

**Tradeoffs:**
- 32B-class reasoning vs 70B-class. User-visible difference: 32B needs more nudging on long sub-agent chains and template selection (the original symptom that pushed us to consider 70B). For booth conversations this is a "see this open model do work like Claude does" demo, not a production agentic harness — 32B is a credible booth-grade exhibit.
- AWQ 4-bit quant has a small accuracy gap vs fp16. Functionally invisible at booth scale.
- We lose the Red-Hat-published-quant booth talking point (RedHatAI/...). Qwen-AWQ is community quant. Acceptable.

**Trigger to revisit:**
- vLLM ≥0.9 ships in a future RHAIIS image (the rhoai-2.20-cuda we use is pinned to vLLM 0.8.4) — re-test Llama 3.3 70B INT4 against it. The deadlock may be resolved upstream.
- Customer specifically demands a Llama-on-OpenShift demo and we have time to debug the engine_core deadlock with NVIDIA / RHAIIS support.
- We add LiteLLM / llm-d as a router (see §28); that introduces a new code path that may also expose or work around the issue.

---

## 31. Llama 3.3 70B INT4 working config found — V0 engine + 0.95 mem + 8K context

**Picked:** vllm-llama-experiment Deployment runs `RedHatAI/Llama-3.3-70B-Instruct-quantized.w4a16` end-to-end on the experimental L40S MachineSet with these flags:

```
--model RedHatAI/Llama-3.3-70B-Instruct-quantized.w4a16
--tool-call-parser llama3_json
--enable-auto-tool-choice
--enforce-eager
--gpu-memory-utilization 0.95
--max-model-len 8192
--tensor-parallel-size 1
env: VLLM_USE_V1=0
```

Verified end-to-end: `/v1/models` 200, structured `tool_calls` under `tool_choice: auto`, single-tool and multi-tool prompts. Sequential reasoning (one tool_call at a time, waits for result before next) is correct for ordering-sensitive workflows like clone-then-read. Qwen 32B AWQ in comparison emits parallel tool_calls which is faster but can race on data dependencies.

**The four sticking points + their fixes (booth-grade troubleshooting log):**

1. **V1 engine deadlock** — `core_client.py:421` parent process spins in a 10-second-poll loop waiting for engine_core child readiness handshake; child loads weights to GPU but never sends the handshake reply. Silent: no log output, no restart, no crash. **Fix:** `VLLM_USE_V1=0` forces V0 engine which uses a completely different process model. V0 is the legacy engine but ships in the same image and works correctly here.

2. **--disable-frontend-multiprocessing red herring** — sounds related but only affects the HTTP API frontend, NOT the engine_core process. Did not help and was dropped.

3. **KV cache budget exhaustion** — at default `--gpu-memory-utilization 0.9` (43.2 GiB on a 48 GiB L40S) with 35 GiB weights + 7-8 GiB framework overhead, vLLM has ZERO budget left for KV cache. V0 surfaces this as `ValueError: No available memory for the cache blocks`; V1 deadlocks instead of erroring. **Fix:** `--gpu-memory-utilization 0.95` recovers 2.4 GiB.

4. **8K context (not 16K)** — even with 0.95 utilization, 70B KV cache for 16K context needs ~12-15 GiB which won't fit alongside the weights. **Fix:** `--max-model-len 8192` — needs ~6-7 GiB at 8K, fits with 3-4 GiB headroom. Coding-agent traffic typically stays well under 8K input + 4K output = 12K total per turn — so 8K is restrictive but functional. Bumping max-model-len to a 70B-on-L40S-fit ceiling (probably 10K-12K) is iteration #5 if we want more.

**Status — NOT promoted to the production planner.**

The Qwen 2.5 32B Instruct AWQ on the production `vllm-planner` Service stays as the booth-ready model — works under `tool_choice: auto`, 32K context (4x Llama's 8K), already verified yesterday end-to-end with chatd. Llama 70B INT4 on the experimental Service is available at `vllm-llama-experiment.ocp-ai.svc.cluster.local:8000` for direct testing but is NOT registered in chatd (the openai-compat provider's single base_url still points at vllm-planner).

**Tradeoff matrix for the booth-day decision:**

| Property | Qwen 32B Instruct AWQ (production planner) | Llama 70B INT4 (experiment) |
|---|---|---|
| **Reasoning quality** | Mid-tier; needs nudging on sub-agent flows | Strongest of the OSS 70B class; better at planning + template selection |
| **Tool-call behavior** | Parallel (faster, occasional race on data deps) | Sequential (correct ordering, slower) |
| **Context window** | 32K | 8K (limited by GPU memory) |
| **GPU footprint** | 18 GiB on L40S (38% used) | 42 GiB on L40S (88% used) |
| **License** | Apache-2.0 | Llama 3.3 Community License (>700M MAU clause) |
| **vLLM stack** | V1 engine + cudagraph (default) | V0 engine + `--enforce-eager` (only path that works) |

**Trigger to revisit:**
- Customer wants Llama-branded demo → flip chatd's openai-compat provider base_url to point at `vllm-llama-experiment` Service + PATCH the model_config to the Llama model id. ~30 seconds. Both backends stay running so the flip is reversible.
- Need >8K context with Llama 70B → upgrade GPU to A100 80GB or H100 80GB on the experimental MachineSet (replace `g6e.2xlarge` with `p5.48xlarge` slice or similar). FP8 quant becomes viable at 70 GiB on 80 GiB GPU and supports 32K+ context easily.
- vLLM ≥0.9 ships in a future RHAIIS image → re-test V1 engine; the deadlock may be fixed upstream, giving back better serving performance + larger context.

## 32. Coder external_auth for self-hosted GitLab — the four-landmine working recipe

**Context:** During the identity pivot (decisions §20 was superseded by the dual-IdP shift to Keycloak + the GitLab SCM swap), `CODER_EXTERNAL_AUTH_0_*` was switched from GitHub to a self-hosted GitLab at `gitlab.rhsummit.coderdemo.io`. Took four rounds of debugging before workspace `git push` worked.

**Picked:** the env-var set proven in `lab/k3s-infra/helm-values/coder.yaml`, ported with this repo's hostnames:

```
CODER_EXTERNAL_AUTH_0_TYPE          = gitlab
CODER_EXTERNAL_AUTH_0_ID            = gitlab
CODER_EXTERNAL_AUTH_0_DISPLAY_NAME  = GitLab (Demo)
CODER_EXTERNAL_AUTH_0_AUTH_URL      = https://gitlab.rhsummit.coderdemo.io/oauth/authorize
CODER_EXTERNAL_AUTH_0_TOKEN_URL     = https://gitlab.rhsummit.coderdemo.io/oauth/token
CODER_EXTERNAL_AUTH_0_VALIDATE_URL  = https://gitlab.rhsummit.coderdemo.io/oauth/token/info
CODER_EXTERNAL_AUTH_0_REVOKE_URL    = https://gitlab.rhsummit.coderdemo.io/oauth/revoke
CODER_EXTERNAL_AUTH_0_REGEX         = ^https://gitlab\.rhsummit\.coderdemo\.io/.*
CODER_EXTERNAL_AUTH_0_SCOPES        = api write_repository read_registry write_registry
```

Plus the OAuth app on the GitLab side registered with **exactly** that scope set (`scopes=["api", "write_repository", "read_registry", "write_registry"]`).

**The four landmines and their fixes (the troubleshooting log):**

1. **VALIDATE_URL=`/api/v4/user` is wrong** — that endpoint requires the token to carry `read_user`. Symptom: Coder UI shows *"Failed to validate oauth access token. Verify the external authentication validation URL is accurately configured."*  **Fix:** use `/oauth/token/info` — the OAuth2 token-info endpoint validates the token itself, no scope context required, future-proof against changing the requested scope list.

2. **SCOPES env var is space-separated, not comma-separated** — Coder forwards the value verbatim into the OAuth `scope=` query parameter. RFC 6749 mandates space-separated. Comma-separated gives *"The requested scope is invalid, unknown, or malformed."* (Confirmed in GitLab's `production_json.log` — the rejected `/oauth/authorize` call had `"scope":"read_user,read_repository,write_repository"`.) **Fix:** space-separate in the YAML env value.

3. **Requested scopes must be a SUBSET of the OAuth app's registered scopes** — adding `read_registry write_registry` to the SCOPES env triggers the *same* "invalid scope" error if those aren't in the OAuth application's `scopes` array on GitLab. GitLab's `applications` API has no PUT/PATCH; widening the scope list requires deleting and recreating the application, which rotates `application_id` AND `secret`. **Fix:** before bumping SCOPES, recreate the OAuth app via `POST /api/v4/applications` with the full target scope set, then re-seal the new credentials into the existing `gitlab-coder-external-auth` SealedSecret.

4. **`envFrom: secretKeyRef` doesn't auto-refresh on Secret change** — after rotating the OAuth app credentials, the Coder pods continue to hold the OLD `application_id`/`secret` in env until restart. Symptom: *"Client authentication failed due to unknown client, no client authentication included, or unsupported authentication method."* **Fix:** `oc -n coder rollout restart deploy/coder` after any underlying-Secret rotation.

**Trigger to revisit:**
- The `api` scope is the over-scope; trimming to a minimum-privilege set (`read_user write_repository read_registry write_registry`) is worth doing post-event. The trim removes the user's full API surface from the token Coder holds.
- GitLab CE has no native OIDC-group → instance-admin mapping; demoadm gets promoted manually by `scripts/gitlab-promote-demoadmins.sh` after first login. The proper SAML-style `admin_groups` mapping is a GitLab Premium feature.

**Operational gotcha that bit:** the scoped-down OAuth app's `secret` is only available at `applications.create` response time. The `GET /api/v4/applications` response does **not** include the secret. After recreating an app, capture the secret immediately into the SealedSecret or you'll be running another recreate to recover it.

## 33. vLLM V1 engine still broken on rhoai-2.22-cuda (next: rhoai-2.23+)

**Context:** §31 documented that V1 engine deadlocks on Llama 70B INT4 + rhoai-2.20-cuda's vLLM 0.8.4. We promoted V0 to production and put Llama in `vllm-planner-tp` (decision §32 codebase change). The standing question was: does the V1 engine work on a newer image with cudagraphs back on?

**Tested:** A parallel deployment `vllm-planner-tp-v1` (manifests/rhaiis/vllm-planner-tp-v1.yaml) running on the OTHER 2 GPUs of the same g6e.12xlarge that hosts PROD, with:
- Image `quay.io/modh/vllm:rhoai-2.22-cuda` (two RHAIIS minors newer than PROD)
- V1 engine default (no `VLLM_USE_V1=0`)
- cudagraphs ON (no `--enforce-eager`)
- Same TP-2, same 32K context, same `--max-num-seqs 8`

**Result:** **Still NOT viable.** Different upstream bug this time — `ValueError: 'aimv2' is already used by a Transformers config, pick another name.` at `vllm/transformers_utils/configs/ovis.py:76`. The rhoai-2.22 image bundles a vLLM + transformers combination that double-registers the `aimv2` config name when V1's cudagraph-import path executes. PROD (V0 + `--enforce-eager`) doesn't hit the bad import order so it survives on the same image; V1 doesn't.

**Picked:** Scale `vllm-planner-tp-v1` to 0 (manifest deprecation comment + replicas=0). Stay on V0 + eager + the four-flag recipe (§31). Re-test on `rhoai-2.23-cuda` (or any subsequent image with vLLM ≥0.9.x that ships in the RHAIIS channel).

**Cost retired by the verdict:** the 2 GPUs that V1 was hogging on the g6e.12xlarge are released back to the node's free pool. No marginal infrastructure cost ever incurred — the test reused the existing 4-GPU node.

**Trigger to revisit:**
- New RHAIIS image lands on quay.io/modh/vllm with a tag ≥ rhoai-2.23.
- Upstream vLLM ≥ 0.9.x ships with the `aimv2` double-register fix (track upstream PR/issue).

**Why we kept the manifest in git:** so the next operator who wants to re-test V1 just bumps `replicas: 1` + the image tag, and the rest of the recipe (TP-2, gpu_memory_utilization, max-num-seqs) is preserved.

## 34. Revert Coder Agents custom system prompt + plan-mode appendix to default-only

**Context:** Over the day we accumulated ~8 KiB of override rules in `manifests/coder-agents-config/system-prompt.md` and ~1.4 KiB in `plan-mode-instructions.md` trying to guide Llama 70B INT4 through edge cases observed in live chats:
- Knowledge questions tool-looped → "answer from training" override.
- spawn_agent fired without wait → "next call MUST be wait_agent" rule.
- `wait_agent timeout_seconds: "300"` string vs int → "numeric args are bare literals" rule + safe-baseline example.
- Sub-agent looped on `create_workspace` → "sub-agents can't mutate workspaces; 'Tool not active in this turn' is a permanent palette error" rule.

Each iteration plugged the observed gap. But on the fourth iteration (`da7955b8-...`, Stanley Cup app prompt) the SAME sub-agent palette loop happened again — 50 messages, 25 alternating `create_workspace` / `list_templates` calls all returning the same permanent error. The "Tool not active is permanent" rule landed in the live prompt (verified 8075 bytes with the rule present at chat-creation time); Llama ignored it.

**Picked:** Empty the custom appendix on both system prompt and plan-mode instructions. Run on Coder's built-in `DefaultSystemPrompt` + `PlanningOverlayPrompt` with no overrides. Files at `manifests/coder-agents-config/{system-prompt,plan-mode-instructions}.md` retained as single HTML-comment placeholders pointing at this decision, so the bootstrap Job sees them, the renderer composes a valid ConfigMap, and a future operator who needs targeted overrides can edit the file + re-render without scaffolding.

**Why this is the right call:**
1. **Llama-INT4 follows positive instructions, ignores negative ones.** The default's "use AS MANY TOOLS" framing wins over our "don't spawn for X" overrides. More rules made the model more confused, not less.
2. **Sonnet and Opus handle every observed failure mode correctly without any appendix.** The booth's `coder-agent` default model is Sonnet 4.6 (decision §32 + the 2026-05-11 default-flip in chatd model-configs). Sovereign-AI demos opt into Llama via `coder-agent:llama`, with the understanding that its agentic-loop behavior is weaker than Bedrock.
3. **Tracking Coder's evolving default for free.** When chatd's `DefaultSystemPrompt` improves upstream we inherit it without merging changes into our appendix.

**Cost of the reversal:** the targeted UUID-vs-string hints for `create_workspace`'s `template_id`, the no-retry-loop rule, the classification decision tree — all gone. If a specific failure mode resurfaces on Sonnet/Opus (low probability), we add a small targeted rule back. The pattern is: prove the failure on the better models BEFORE adding overrides — don't tune for INT4 weaknesses.

**Trigger to revisit:**
- A failure pattern shows up on Sonnet or Opus that the default prompt mishandles. Then add ONE narrow rule, not eight.
- vLLM ships a Llama variant with structurally better tool-call adherence (e.g., a Llama 3.3 instruct-tuned-for-tools quant). Re-test with full appendix at that point.

## 35. Workspace image symlinks `/home/user` → `/home/coder` so Llama's hallucinated workdirs resolve

**Context:** Watching Llama 3.3 70B INT4 drive a chatd sub-agent against an `agents-dev-ocp` workspace, every `execute` and `write_file` tool call set `workdir` (or path prefix) to `/home/user/workspace/<project>` and failed:
- `write_file` → `mkdir /home/user: permission denied` (uid 1000830000 can't create `/home/user`)
- `execute` → `fork/exec /usr/bin/sh: no such file or directory` (misleading — the shell exists; the failure is chdir to a nonexistent workdir, kernel returns ENOENT from `execve`, the Coder agent surfaces it as a shell-missing error)

The workspace's HOME is `/home/coder` (verified via `oc exec` + the agent's own env). Llama picked `/home/user/...` from training-data priors — that path is common in sandbox configs (Anthropic computer-use, Modal, etc.). The chatd `execute` tool description (chattool/execute.go:80-82) just says "Working directory for the command" with no default hint — so when a model supplies one, it has to guess.

**The knowledge gap behind the bug** (the structural difference, not a prompt fix):

Bigger frontier models (Sonnet, Opus) succeed at this not because they "know" the right HOME, but because they:
1. **Probe before assuming.** Opus 4.7's literal first action in a parallel test chat was `node --version && npm --version && pwd && ls`. It discovered `/home/coder` empirically.
2. **Omit optional arguments by default.** Subsequent `execute` calls didn't carry `workdir` — and the chatd `WorkDir *string \`json:"workdir,omitempty"\`` definition causes the agent to fall back to its own cwd, which IS `/home/coder`.

Llama-INT4 doesn't do either reliably. It skips the probe (no `pwd` first turn) and supplies `workdir` explicitly with a hallucinated value. Prompt-engineering this away is fragile (decision §34 documents three iterations of failed attempts to do exactly that).

**Picked:** Structural fix in the workspace base image — `RUN ln -s /home/coder /home/user` in `coder-templates/images/ubi9-base-workspace/Dockerfile`. Wrong guesses transparently resolve to the right path. Sonnet/Opus unaffected (they don't pass `workdir`). Future weaker models or new quants that make the same mistake also work. Build-time, root context, no SCC issues at workspace runtime.

Cost: one Dockerfile line + a `build-images.yml` GHA run (~5 min to rebuild + push ubi9-base + ubi9-node + re-pull on workspace start).

**Why we didn't fix this upstream (yet):**
- Patching chatd's `execute` tool to fall back to `$HOME` when `workdir` is missing OR points at a nonexistent path would help every consumer. File as an upstream issue post-event.
- Updating the tool's `description` field to read `"Working directory for the command. Defaults to /home/coder; omit unless overriding"` would help models that read tool docs carefully (more frontier-class than Llama-INT4). Also upstream.
- Symlink is the booth-grade workaround that doesn't require forking chatd.

**Trigger to revisit:**
- Upstream chatd lands a workdir-default fix — we can remove the symlink as cleanup.
- Llama (or any future on-prem model) starts hallucinating a different path (`/workspace/...`, `/sandbox/...`, etc.). Add the symlink for each as observed; the cost is bounded.

**Related decision:** §34 (default-only system prompt — don't fight this at the prompt layer).

---

## 36. FP8 Llama 3.3 70B attempt aborted — AWS capacity blocker + INT4 is good enough for the booth

**Context:** §35 documented the workspace-image symlink workaround for Llama-INT4's hallucinated workdir paths (`/home/user/...`, `/workspace/...`, `/project/...`). On 2026-05-11 we ran out of training-prior paths Llama-INT4 could land on while debugging at the venue (4 symlinks landed; the 5th request picked `/project/`), and pulled out the structural fix: **the quantization is the root cause** — INT4 erodes the cautious-agent patterns (`pwd && ls` probe, omit-by-default for optional args) that Sonnet/Opus exhibit reliably. A higher-precision quant would retain those patterns.

**Plan:** Stand up `RedHatAI/Llama-3.3-70B-Instruct-FP8-dynamic` on a parallel `g6e.12xlarge` MachineSet (4× L40S, TP-4, 32K context) so the proven-working INT4 path stayed as a fallback. New manifests committed at `ba45f41` (`manifests/machinesets/gpu-l40s-tp-fp8.yaml` + `manifests/rhaiis/vllm-planner-tp-fp8.yaml`).

**Blocker:** AWS returned `InsufficientInstanceCapacity` for every `g6e.12xlarge` request in `us-east-1a` — over 1,000 retries in 60 minutes, all the same error. AWS explicitly suggested `us-east-1b/1c/1d` in the error body. The cluster *does* have private subnets in those AZs (master-1 in 1b, master-2 in 1c), but they're configured as master-only — verifying that those subnets' route tables would pass NAT-egress for a worker (so image pulls succeed) couldn't be done with `oc` alone, and gambling on it 12 hours before the booth had asymmetric downside.

**Picked:** Abort FP8. Revert `ba45f41`, scale the failed MachineSet to 0, delete it. Ship the booth on INT4 with the symlink-removed workspace image (also reverted per `3e93e91`) and the narrative framing of "first-gen Llama-3 INT4 doesn't probe its environment, here's how a 5x bigger frontier model handles it" — that's actually a *stronger* demo story than "look, all models work great."

**Why not:**
- **Swap to us-east-1b** — viable but unverified subnet/route-table compatibility, and there'd be no time to roll back if it failed. Bad risk profile for a one-shot demo.
- **FP16 on the same hardware** — 140 GiB weights at TP-4 leaves only ~13 GiB/GPU for KV cache; 32K context with concurrency would OOM. Not actionable without bigger GPUs.
- **Stay on INT4 but keep adding symlinks** — `/project/` was the 5th path; there is no enumerable set. Already covered in §35.

**Trigger to revisit:**
- AWS releases additional `g6e` capacity in `us-east-1a` (visible via `aws ec2 describe-instance-type-offerings`) — re-apply the FP8 manifests post-event.
- Cluster gets re-installed with worker subnets in multiple AZs — FP8 becomes a single-MachineSet change.
- Upstream chatd lands the `workdir` fallback fix mentioned in §35 — INT4 stops needing the structural workaround at all, and quant choice becomes about quality alone.

**Related decision:** §35 (the symlink workaround that didn't scale).

**2026-05-12 follow-up — FP8 attempt #2 succeeded in us-east-1b:** Same AMI, same Coder/RHAIIS chart, just `availabilityZone: us-east-1b` + the master-1 subnet (`subnet-047a2f01877be7843`). Capacity available. Machine Provisioned → Node Ready (~10 min) → image pull (~3 min) → 70 GiB FP8 download + TP-4 weight load (~13 min) → engine init (~1 min); total ~30 min to /v1/models = 200. Smoke `chat/completions` returned "pong". chatd cut over (provider base_url + model-config model both updated to FP8 in the same window); `vllm-planner-tp` (INT4) stays running on its us-east-1a MachineSet as a hot fallback. Next post-event: scale the INT4 MachineSet to 0 if FP8 holds at the booth; revisit the `coder-firewall-scc` + `iptables-nat-modules` DaemonSet (originally added thinking nsjail was the firewall path — turned out boundary supports landjail which doesn't need either; see §39).

---

## 37. Three-persona identity model — one Keycloak group per role tier

**Context:** The pre-existing realm had 5 personas — `alice`, `bob`, `carol`, `dave` all in `/developers`, plus `demoadm` in both `/developers` and `/admins`. carol and dave had zero role differentiation from alice; they existed only to make the persona dropdown feel populated. Worse, every developer-tier user got the Coder `auditor` site role (via `CODER_OIDC_USER_ROLE_MAPPING`), which gave alice cross-deployment audit visibility she had no business having — and gave bob (the supposed "project manager" persona) nothing distinct from alice.

The booth narrative for the 3-persona reframe is:
- **alice** is a developer — she creates workspaces, talks to AI, pushes code.
- **bob** is a project manager — he watches what gets done and reads the audit trail.
- **demoadm** runs the place — every platform, full control.

Each persona should map cleanly to ONE permissions tier that's enforced by group membership in Keycloak, not by application-specific configuration drift. The original "everyone gets auditor + a custom role to add create perms" mapping was a workaround for not having multiple groups; with multiple groups the design simplifies.

**Picked (group → role matrix):**

| Keycloak group | Members | Coder site | Coder org-role | OCP | Argo | Grafana | GitLab |
|---|---|---|---|---|---|---|---|
| `/admins` | demoadm | `owner` | (inherited via owner) | cluster-admin (new CRB `keycloak-admins-cluster-admin`) | inherited via OCP | Admin | instance admin (via `gitlab-promote-demoadmins.sh`) |
| `/developers` | alice | (none — Member) | `developers-chat` (workspace.* + chat.*, NO audit_log/connection_log) | none | none | denied at OAuth callback (`allowed_groups: admins`) | regular user |
| `/auditors` | bob | `auditor` (read-only deployment-wide) | (none) | none | none | denied at OAuth callback | regular user |

**Concrete changes (commit `<this PR>`):**
1. `manifests/keycloak/realm-demo.yaml` — drop carol/dave; add `/auditors` group; move bob into it; demoadm now in `/admins` only (was `/developers + /admins`).
2. `gitops/apps/coder/application.yaml` — `CODER_OIDC_USER_ROLE_MAPPING` is now `{"admins":["owner"],"auditors":["auditor"]}` (developers intentionally not mapped at site level; their permissions come from the org-scoped custom role).
3. `scripts/coder-agents-provider-model-config.sh` — custom org role renamed `developers-auditor-plus` → `developers-chat`. `audit_log:read` and `connection_log:read` permissions removed (those belong to bob's site-level auditor role now). OIDC role-sync mapping `{developers: [developers-chat]}` unchanged in shape (only the role name changed).
4. `manifests/cluster-config/keycloak-demo-users-rbac.yaml` — replaced. The old `developers → cluster-reader + cluster-monitoring-view` bindings are gone (alice has no business in OCP); a new `admins → cluster-admin` binding gives demoadm a Keycloak path to cluster-admin (previously only the GitHub `admin` team had that).
5. `gitops/apps/observability/application.yaml` — Grafana's `auth.generic_oauth` block gains `allowed_groups: admins`, locking the Keycloak login to demoadm only.
6. `scripts/reset-demo.sh` — `DEMO_PERSONAS` default reduced from `alice,bob,carol,dave,demoadm` to `alice,bob,demoadm`.
7. `docs/identity-architecture.md` + `README.md` — updated persona list + group→role matrix.

**Why not:**
- **Add a `/project-managers` group instead of `/auditors`** — semantically nicer name, but Coder's site role is literally called `auditor`. Naming the Keycloak group `auditors` keeps the mental model consistent across the OIDC → role hop.
- **Keep developers mapped to `auditor` at site level** — that's what gave alice cross-deployment audit visibility she didn't need. The 3-persona narrative breaks down if alice can see bob's audit view by default.
- **Map developers → custom role at site level via `CODER_OIDC_USER_ROLE_MAPPING`** — Coder's site-level mapping accepts only BUILT-IN role names. The custom role has to be assigned at the org level via the `idpsync/roles` endpoint, which the agents-config Job already does idempotently.

**Trigger to revisit:**
- We add a fourth persona tier (e.g. "security auditor" with cross-org visibility) — add a fourth Keycloak group rather than overloading an existing one.
- Coder adds first-class custom site roles (no longer org-scoped) — collapse the developers-chat custom role into `CODER_OIDC_USER_ROLE_MAPPING` directly.

**Related decisions:** §32 (GitLab external_auth recipe — separate but identity-adjacent).

---

## 38. New template `artemis-sim-dev-ocp` — the non-AI half of the booth story

**Context:** The existing OCP templates (`ai-dev-ocp`, `agents-dev-ocp`, the two `demo-ai-gov-*-ocp` variants) all lead with AI tooling — Claude Code / Codex / Gemini CLIs, AI Bridge env vars, Coder Agents chat integration. That covers the "AI governance" half of the booth pitch well, but it makes for an unbalanced demo: every Coder workspace looks like an AI workstation. The Red Hat audience also has a large contingent of traditional enterprise developers — embedded, simulation, control-systems folks — who want to see Coder as a generic dev-platform story, not just an AI-tools story.

`artemis-sim-dev-ocp` is the contrast piece. It's a "regular SWE on OCP" template: C++ backend + Node/TS frontend, no AI tooling, clones a real-feeling Artemis-2 simulator repo. The booth narrative flips between this template and the AI templates to show "Coder is the platform; the toolchain is your choice."

**Picked (template shape):**
- **Persona**: one persona — a *simulator engineer* who builds the sim. The simulator itself serves 4 downstream user types (Flight SW, GNC, Payload, Mission Control) but those are CONSUMERS of the simulator binary, not workspace users. The engineer writing the C++ runtime + Node visualization is one role, hence one preset/parameter shape.
- **Stack**: C++ (gcc + clang + cmake + gdb + clangd) for the digital-sim backend, Node.js 22 LTS + TypeScript for the visualization frontend. Both layers pre-installed in the `ubi9-node-workspace` base image so workspace cold starts don't hit `sudo dnf install` (which restricted-v2 SCC blocks via CAP_SETUID drop).
- **Repo URL is dynamic** (decision recorded here per user ask):
  - Template defines `git_repo` as a Coder parameter with default `https://gitlab.rhsummit.coderdemo.io/alice/artemis-sim` and `mutable = false`.
  - The default is what UI-driven workspace creation gets (the natural form for booth visitors who click "Create Workspace" from the Coder dashboard).
  - The bridge service ALSO populates `git_repo` via `RichParameterValues` on every webhook-triggered workspace creation, pulling the value from the GitLab webhook payload's `Project.WebURL` field. So when a PM labels a GitLab issue in some-other-project with `coder-workspace:artemis-sim-dev-ocp`, the workspace clones that other project, not the default.
  - This keeps the template generic (works for any GitLab project that has the right shape) without baking a per-project hardcode into the template.
- **Modules**: `code-server` (browser VSCode), `git-clone` (handles the dynamic clone via `GITLAB_TOKEN` from external_auth), `dotfiles` (user-level zsh/tmux/neovim config). NO Kiro, NO Cursor — those are AI-tool surfaces that don't belong here.
- **No AI plumbing**: no `claude_settings` / `claude_config` locals, no `ai_bridge_*` URLs, no `coder_env` resources for `CLAUDE_API_KEY` / `OPENAI_API_KEY`, no Anthropic/OpenAI env vars on the agent.

**Why not:**
- **One template per simulator-consumer persona (Flight SW / GNC / Payload / Mission Control)** — initially considered. Rejected after clarification: those personas use the simulator's RUNTIME, not the dev workspace. They're not Coder users. One template per consumer would be 4× maintenance for no narrative payoff.
- **Hardcoded repo URL in the template's `startup_script`** — simpler at first but doesn't carry the bridge → workspace plumbing story. The dynamic param via `RichParameterValues` lets us demo "GitLab webhook describes the work, Coder reads the description, the workspace clones the right repo automatically" as one connected flow.
- **Install C++ tooling at workspace startup via `dnf` in the agent script** — fails under restricted-v2 (CAP_SETUID dropped, sudo can't elevate). Build-time install in `ubi9-node-workspace` is the canonical pattern (see decisions §35 for the related symlink workaround — same root cause of "we can't install at runtime").

**Trigger to revisit:**
- A specific persona (e.g. Flight SW) gets a workspace-shape requirement the simulator engineer one doesn't cover — at that point, fork to `artemis-flightsw-dev-ocp` rather than overload artemis-sim-dev-ocp.
- The bridge starts supporting `.coder/template.yaml`-style per-project template overrides (handler.go has a TODO for this) — then the artemis-sim-dev-ocp default could be removed and replaced with project-driven selection.

**Related decisions:** §35 (workspace SCC pattern / why we install at build time), §37 (the 3-persona identity model — alice is the developer who uses this template).

---

## 39. Coder Agent Firewall (boundary) on OCP — `--jail-type landjail`, not nsjail

**Context:** The firewall workspace template installs HashiCorp Boundary's `boundary` CLI to enforce per-process network allowlisting. Boundary supports two backends:
- `nsjail` (the default): creates a new Linux network namespace per command, sets up iptables MASQUERADE rules to NAT outbound packets through the parent pod's eth0
- `landjail`: uses the Linux Landlock LSM (kernel ≥5.13) to restrict the process's network syscalls in-place — no new namespace, no iptables, no NAT

We initially tried to make nsjail work and hit a cascade of issues:
1. **`Operation not permitted` on `setuid`** — restricted-v2 SCC drops CAP_SETUID, but boundary's sudo-based install path needs it. Built a new `coder-firewall-scc` (modeled on restricted-v2) that allows `NET_BIND_SERVICE`, `NET_ADMIN`, `SYS_ADMIN` and DOESN'T drop `SETUID`/`SETGID`. Bound a dedicated `coder-firewall-runner` ServiceAccount to it.
2. **`iptables: executable file not found`** — UBI9 doesn't ship iptables by default. Added `iptables-nft` to the `ubi9-base-workspace` Dockerfile.
3. **`Extension MASQUERADE revision 0 not supported, missing kernel module?`** — OCP 4.21 uses OVN-Kubernetes for its CNI, which does service NAT in OVS userspace; the kernel modules `nft_chain_nat`/`nft_masq`/`nf_nat`/`iptable_nat` aren't auto-loaded on workers. Container can't `modprobe` (CAP_SYS_MODULE blocked by every reasonable SCC). Shipped a privileged DaemonSet (`iptables-nat-modules`) that nsenter's into PID 1 and loads the modules at boot, sleeping infinity so node-reboot pod restarts reload them.
4. **`No route to host` even after the modules loaded** — the pod's `/proc/sys/net/ipv4/ip_forward` is `0` (again, OVN doesn't need it). Without kernel forwarding, nsjail's MASQUERADE rule has nowhere to forward packets to. Can't `sysctl -w` from inside the container (CAP_NET_ADMIN gates `net.*` sysctls in the host netns; pod's writes only affect the pod's netns, not the host's, but they're also gated).

**Picked: `landjail`.** Boundary v0.9.0 exposes `--jail-type landjail` / `BOUNDARY_JAIL_TYPE=landjail`. Verified end-to-end on the live workspace pod:

| Domain | Status |
|---|---|
| `api.github.com` (allowed) | HTTP 200 in 57ms |
| `api.anthropic.com` (allowed) | HTTP 404 (route 404, server reached) |
| `coder.apps.cluster...` (allowed) | HTTP 200 |
| `webhook.site` (denied) | HTTP 403 from boundary proxy |
| `example.com` (denied) | HTTP 403 from boundary proxy |
| `claude -p "say hello"` | "hello" |

landjail runs as the workspace's own SCC-injected UID under restricted-v2 — no privileged setup needed. Boundary's allowlist enforcement (HTTP-proxy + LSM filtering) is identical between the two backends; only the *isolation mechanism* differs.

**Concrete changes (commit `0cfb615`):**
- `coder-templates/demo-ai-gov-firewall-ocp/main.tf`: wrappers at `~/.local/bin/boundary-wrappers/{claude,codex}` now pass `--config "$HOME/.config/coder_boundary/config.yaml" --jail-type landjail`. Shell profiles export `BOUNDARY_CONFIG` + `BOUNDARY_JAIL_TYPE=landjail` so direct `boundary --` invocations also use the new backend.
- Boundary v0.9.0 has NO auto-discovery for `~/.config/coder_boundary/config.yaml` — `--config` or `BOUNDARY_CONFIG` is mandatory. Earlier template comment claiming otherwise was wrong.

**Why not:**
- **MachineConfig + systemd kmod-load** to fix nsjail's missing modules persistently — works, but requires a worker-node roll (10 min/node) which the user explicitly vetoed.
- **`privileged` SCC for workspace pods** — bypasses the kernel-module + ip_forward issues by giving the pod everything, but unacceptable security narrative for a demo about AI governance.
- **`hostNetwork: true`** — workspace shares the node's netns, nsjail can use the host's networking. Defeats the per-workspace isolation story.

**Trigger to revisit:**
- Boundary upstream lands a nsjail backend that auto-enables `ip_forward` in the pod's netns (would need CAP_NET_ADMIN, which we have via coder-firewall-scc) — could move back to nsjail for stronger isolation than landjail offers.
- We migrate off OVN-Kubernetes — different CNIs have different netfilter behavior.

**Cleanup candidates (post-event):** `manifests/cluster-config/coder-firewall-scc.yaml` and `manifests/cluster-config/iptables-nat-modules-ds.yaml` were added during the nsjail debugging path. landjail doesn't need either. Leaving both in place for the booth (they're harmless); revisit removal post-event.

**Related decisions:** §35 (the `Operation not permitted` debugging that surfaced the same restricted-v2/CAP pattern).

---

## Decisions explicitly deferred to post-event

These came up; we said "not for booth, document and move on":

- **IRSA migration** — replace static IAM keys with role-assumption (decision #10)
- **STIG/FIPS hardening** — `restricted-v2` SCC overrides, `fips: true` in install-config
- **Vault for secrets** — Sealed Secrets is the booth answer (decision #19); Vault is the production answer for orgs that already run it
- **AAP for sprint trigger** — replaced with GitHub Actions
- **Tekton for sprint trigger** — same
- **AWS Load Balancer Controller** — overkill; OCP IngressController serves Routes
- **External-DNS** — manual cert-manager + Route 53 is fine for one cluster
- **LokiStack with S3 backing** — local PVC is fine for 7-day retention
- **Tempo / Service Mesh / multi-cluster** — out of scope
- **Bedrock invocation logging** — see decision #17
- **OIDC / Keycloak SSO into Coder** — superseded by GitHub OAuth (decision #20)

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
