# Coder Agent session — activity summary & repeatability gaps

**Quick summary of the agent-driven work that brought the RH Summit 2026 demo to
its current state, a live-verification snapshot, and the sharp edges that still
stand between "works on this cluster" and "repeatable, easy to deploy."**

The detailed, commit-by-commit change log is in
[`environment-change-summary.md`](environment-change-summary.md). This doc is the
quick read + the repeatability gap analysis.

| | |
|---|---|
| Repo / branch | `coder/demo-aigov-rhaiis-rhsummit-2026` · `chore/coder-2.37.6-upgrade` |
| Cluster / cloud | OpenShift **4.21.37** IPI · AWS **342934376218** · **us-east-1** |
| Live-verified | 2026-11-02 (from the Coder workspace, `system:admin` + AWS admin) |

---

## 1. What was done (quick, chronological)

1. **Coder 2.37.6 upgrade + templates** — AI-CLI templates moved to Coder
   Registry modules; GitLab-only `external_auth` in templates; Claude key-prompt
   pre-approval; **code-server pre-baked** into the workspace image (offline);
   Copilot disabled. (`6859fa4`…`0c56f17`)
2. **AWS account security** — GuardDuty + Inspector managed in Terraform; GitLab
   VM hardened (SSM, IMDSv2, no public SSH); GitLab **19.5.1 → 19.5.3**.
   (`3cdd29b`, `7261e7d`)
3. **GitLab → private subnet behind an OpenShift edge Route** — no public IP,
   TLS at the router (cert-manager SAN cert), KAS off, port 80 dropped; in-place
   instance replacement with data-volume reattach. (`e45c9c9`, `bed9575`)
4. **Cloud-init deadlock fix** — deferred `gitlab-ctl reconfigure` into a
   one-shot `gitlab-firstboot.service` (out of the boot transaction). (`34129a5`)
5. **Keycloak realm creds → AWS Secrets Manager + ESO** — Terraform generates the
   7 values into `rhsummit/keycloak/demo-realm` + an IRSA role; ESO syncs them in;
   realm became a secret-free template + render Job; consumers repointed; **live
   rotation** performed and all 3 personas verified logging in. (`da454dc`,
   `7449e8b`, `1330531`)
6. **Repo-wide secret remediation** — scrubbed docs, rewrote `secrets.md`,
   gitleaks CI gate; no plaintext realm secrets remain in tracked files.
7. **reset-demo** mints the GitLab PAT via SSM (no SSH). (`f8cbd29`)
8. **Architecture diagrams** — AWS infra diagram + OpenShift/Argo **component
   board**, referenced from the README. (`9310eb0`…`213edd8`)
9. **Docs** — change-summary + this doc; plus the accuracy pass in §3 below.

---

## 2. Live-verification snapshot (2026-11-02)

| Check | Result |
|---|---|
| OpenShift | 4.21.37, 4 nodes Ready |
| Coder | `ghcr.io/coder/coder:v2.37.6`; AI Gateway env = `CODER_AI_GATEWAY_*` (BYOK off, Bedrock=claude-sonnet-4); external_auth slot0 gitlab + slot1 github |
| Keycloak realm | `demo` (live) |
| ESO | store Ready; 4 ExternalSecrets `SecretSynced` |
| GitLab EC2 | `i-07e4ab85a65043950` · **no public IP** · `10.0.20.10` · private subnet · IMDSv2 · m7a.2xlarge |
| GitLab routes | `gitlab.…` + `registry.gitlab.…` edge, `externalCertificate=gitlab-tls` |
| AWS SM | `rhsummit/keycloak/demo-realm` present |
| GuardDuty / Inspector | detector active · Inspector EC2 **ENABLED** |
| Argo CD | 19 Applications (incl. `root`), all project `default`; 16 Synced/Healthy, 3 OutOfSync-but-Healthy |

---

## 3. Documentation accuracy pass (corrected this session)

- `identity-architecture.md`: realm `rhsummit` → **`demo`** (diagram, components,
  summary table, issuer URLs); **GitLab networking rewritten** (was "public
  subnet / public IP / SG 80·443 from anywhere / LE via gitlab-ctl / t3.large" →
  now private subnet, no public IP, edge Route + router TLS, SG 80 from VPC only,
  m7a.2xlarge, OIDC secret from AWS SM); GitLab base URL corrected.
- `decisions.md`: §11 noted the **2.37.6** upgrade; §19 noted that the Keycloak
  realm creds now use **ESO + AWS Secrets Manager** (the option it had deferred),
  coexisting with Sealed Secrets for everything else.
- `architecture.md`: Coder Agents row notes the cluster now runs **v2.37.6**.
- Still accurate (spot-checked, left as-is): README stack table, `secrets.md`,
  `demo-flow-persona-setup.md` (the GitHub external_auth slot-1 **is** still live
  on the Coder server, so that language is correct).

---

## 4. Sharp edges & gaps to make this repeatable / easy to deploy

Ordered by how much they block a clean, hands-off rebuild. (Cross-refs to the
`G#` items in [`environment-change-summary.md`](environment-change-summary.md).)

| # | Sharp edge / gap | Evidence | To make it repeatable |
|---|---|---|---|
| R1 | **Multi-step manual bring-up.** 15 scripts in `scripts/`, only ~4 wrapped in the Makefile (`reset`, `promote-demoadmins`, `register-webhook`, `status`). Full first deploy still hand-runs quota bootstrap, R53 delegation, TF backend, `configure-manifests`, `fix-bedrock-irsa`, `loki-s3-irsa-setup`, `gitlab-create-coder-oauth-app`, `render-coder-agents-configmap`, `setup-demo-labels`. | `ls scripts/` vs `make help` | One ordered, **idempotent** top-level `make deploy` (or a numbered runbook) that chains these with clear checkpoints. |
| R2 | **Live state diverges from committed IaC for GitLab.** The `cluster-gitlab` IAM role has **no inline policies live** (verified `[]`), so the Secrets-Manager-read grant + boot-fetch + cloud-init deadlock fix in the committed `module.gitlab` are **not applied** — a `terraform apply` will **replace** the VM to converge. The running VM only got its rotated secret via an SSM `sed`. (G1, G3) | `aws iam list-role-policies cluster-gitlab` → `[]` | Apply `module.gitlab` in a maintenance window (expect replacement; data vol reattaches) and validate the firstboot unit + SM boot-fetch on that rebuild. |
| R3 | **Realm rotation/reset isn't GitOps-repeatable.** `KeycloakRealmImport` does **not** update an existing realm; the render Job only seeds a *fresh* one, so the live rotation had to be done imperatively via `kcadm`. (G4) | this session's rotation steps | Add a reset path that deletes the realm (or user/client CRs) before re-import, or a scripted `kcadm` rotate; wire into `make reset`. |
| R4 | **Argo CD RBAC gap for SSO users.** Keycloak/`demoadm` can authenticate to Argo (via "Log in via OpenShift") but gets **no access** to the `default` project / app-of-apps — only `kube:admin` is auto-mapped to Argo admin. No `argocd-rbac` mapping is committed. | user report + no `argocd-rbac-cm` customization in `gitops/` | Commit an ArgoCD CR `spec.rbac` with `scopes: '[groups]'` + `g, admins, role:admin` so admin access is reproducible (not just kubeadmin). |
| R5 | **ESO bootstrap was applied imperatively** this session (operator Subscription, `ExternalSecretsConfig`, `eso-aws-sm` SA, token RBAC, egress NetworkPolicy). All are now committed (`gitops/operator/` + `manifests/external-secrets/`) **but the clean-bootstrap ordering is unproven** — CRDs must exist before the store/ExternalSecrets, and the deny-all egress baseline must be patched. (G8) | this session's install steps | Validate on a fresh cluster that the operator step + Argo waves bring ESO up with no manual nudging. |
| R6 | **`RouteExternalCertificate` enablement not in IaC.** coder, observability, and gitlab routes all use `spec.tls.externalCertificate`; the cluster feature-gate/router enablement isn't captured in `manifests/`/`gitops/`/`terraform/`. | repo grep (no featureGate/ROUTER_ENABLE); live routes work | Confirm it's default-on in OCP 4.21; if not, add the `FeatureGate`/router config to bootstrap IaC. (G7) |
| R7 | **3 Argo apps sit OutOfSync (Healthy).** `cluster-config` (GroupSync CR), `coder-observability` (Grafana/Alertmanager StatefulSets), `sealed-secrets` (Deployment) — operator/runtime-mutated fields. | `oc get applications` | Add targeted `ignoreDifferences` so steady state is "all Synced" (removes false drift and makes `make status` meaningful). |
| R8 | **AI Gateway endpoint path doc inconsistency.** Env is confirmed `CODER_AI_GATEWAY_*`, but prose variously cites `/api/v2/aibridge/{anthropic,openai}` vs `/api/v2/ai-gateway/<provider>`. | `architecture.md` vs earlier notes | Verify the actual 2.37.6 path once and standardize across README/architecture.md. |
| R9 | **End-to-end demo loop not re-validated** post-cutover/rotation. Bridge is listening (fresh PAT) but a full GitLab issue→workspace→agent→MR run and a GitLab browser SSO login weren't exercised. (G9) | this session scope | Run one `coder-agent`-labelled issue + one GitLab "Sign in with Keycloak" before the event. |
| R10 | **Residual hygiene:** git history still holds the old (now-invalid) secrets (G2); `gitlab_root_password` has a weak committed default (G5); cutover safety snapshot `snap-085852c78eb40460f` still around (G6); Sealed-Secrets sealing-key DR depends on an out-of-band backup. | — | Optional history purge; require root pw via tfvars/SM; delete snapshot; confirm sealing-key backup. |

---

## 5. Recommended path to "one-command repeatable"

1. **Fold the manual scripts into an ordered, idempotent `make deploy`** (R1) with
   explicit pre-flight checks (AWS creds, DNS delegation, TF backend).
2. **Apply `module.gitlab` Terraform** in a window and validate the rebuild path
   (R2, R6) — this is the one place code and live still diverge.
3. **Commit the Argo RBAC mapping** (R4) and **`ignoreDifferences`** for the drifting
   apps (R7) so the GitOps steady state is clean and SSO admins work out of the box.
4. **Scripted realm reset/rotate** (R3) so `make reset` fully re-seeds identity.
5. **Do one clean rebuild in a scratch account** end-to-end (R5, R9) as the
   acceptance test for "repeatable."

Items 2–4 are small, well-scoped changes; item 1 and item 5 are the real work to
turn this from "a cluster we hand-built" into "a demo anyone can `make deploy`."
