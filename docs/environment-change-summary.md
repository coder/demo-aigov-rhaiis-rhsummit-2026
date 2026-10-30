# Environment change summary & open gaps

**Scope:** what changed to bring the RH Summit 2026 demo environment to its
current state, and what still diverges from the original/intended state.

| | |
|---|---|
| **Repo / branch** | `coder/demo-aigov-rhaiis-rhsummit-2026` · `chore/coder-2.37.6-upgrade` |
| **Cluster** | OpenShift 4.21 IPI on AWS · account **342934376218** · **us-east-1** |
| **Key endpoints** | Coder `coder.apps.cluster.rhsummit.coderdemo.io` · Keycloak `keycloak.apps.cluster.rhsummit.coderdemo.io` · GitLab `gitlab.rhsummit.coderdemo.io` (+ `registry.gitlab.…`) |
| **As of** | 2026-10-30 (HEAD `213edd8`) |

> This is a point-in-time working summary. Deeper rationale lives in
> [`decisions.md`](decisions.md); secret handling in [`secrets.md`](secrets.md);
> identity in [`identity-architecture.md`](identity-architecture.md).

---

## 1. Key changes by area

Commits are on `chore/coder-2.37.6-upgrade` (newest first within each area).

### 1.1 Coder 2.37.6 upgrade & workspace templates
- Workspace templates refactored to **Coder Registry modules**: claude-code
  v5.4.0, codex v5.3.2 / 0.159.2, code-server v1.3.1. READMEs updated for
  module-based AI-CLI install + AI Gateway. (`6859fa4`)
- **GitLab-only external_auth**: dropped the GitHub `external_auth` from all
  templates. (`6889948`)
- **Claude Code "custom API key" prompt** suppressed via a non-blocking
  `coder_script` that pre-approves the key hash into `~/.claude.json`
  (`run_on_start`, detached). (`81f4949`, `8a5ceef`)
- **code-server pre-baked** into the `ubi9-node-workspace` image (v4.144.0 at
  `/usr/lib/code-server`); all templates install offline (`install_prefix` +
  `offline=true`) — no runtime download. (`6e0322d`)
- **GitHub Copilot / Copilot Chat disabled** in code-server (Dockerfile strips
  `defaultChatAgent` from `product.json`; templates set
  `chat.disableAIFeatures=true` + `extensions.allowed` deny). (`1a3593e`,
  `0c56f17`)
- AI Gateway routing validated: `/api/v2/ai-gateway/<provider>`
  (bedrock=Claude, openai-compat=Codex), auth via session token.

### 1.2 AWS account security posture
- `terraform/security-services.tf` now manages **GuardDuty** (+ EBS malware
  protection) and **Inspector** (EC2, hybrid scan mode) in Terraform; imported
  the existing detectors so TF owns them. (`3cdd29b`, null-profile fix `7261e7d`)
- GitLab EC2 hardened: SSM instance profile, **IMDSv2 required**, public SSH
  removed; GitLab upgraded **19.5.1 → 19.5.3**.

### 1.3 GitLab moved to a private subnet behind an OpenShift edge Route
- Instance moved to **private subnet** `subnet-0bdae692dd682c15d`
  (`10.0.20.10`, **no public IP**); SG allows only TCP:80 from the VPC CIDR;
  Route 53 records became CNAMEs to the router LB. Port 80 at the edge dropped —
  TLS terminates at the OpenShift router. KAS disabled. (`e45c9c9`)
- GitOps `manifests/gitlab-ingress/`: selector-less Service + EndpointSlice →
  `10.0.20.10:80`, cert-manager SAN `Certificate` (gitlab + registry, LE DNS-01),
  and **edge Routes** that serve it via the OCP 4.21 `RouteExternalCertificate`
  feature. Argo app `gitlab-ingress`. (`bed9575`)
- Live cutover executed: safety EBS snapshot, clean volume detach, TF
  in-place instance replacement → new instance **`i-07e4ab85a65043950`**, data
  volume reattached (preserved), DNS flipped. Verified end-to-end: API v19.5.3,
  registry, git clone/push over HTTPS, SSM online, Security Hub **EC2.9** clear.

### 1.4 GitLab cloud-init deadlock hardening
- Root cause: `gitlab-ctl reconfigure` inside `cloud-final.service` does a
  synchronous `systemctl start gitlab-runsvdir`, deadlocking the boot
  transaction (first cutover hung; recovered with reboot + manual reconfigure).
- Fix: `userdata.sh.tpl` now **defers reconfigure** (+ root password, SSO
  lockdown, runner install) into a one-shot `gitlab-firstboot.service` ordered
  `After=multi-user.target`, kicked off `--no-block`. Self-disables after
  success. (`34129a5`)

### 1.5 Keycloak realm credentials → AWS Secrets Manager + ESO
- `terraform/keycloak-secrets.tf`: generates 7 values (3 persona passwords + 4
  OIDC client secrets) into one JSON secret **`rhsummit/keycloak/demo-realm`**
  (us-east-1, AWS-managed KMS) + an **IRSA role** for the External Secrets
  Operator. (`da454dc`)
- **External Secrets Operator** (Red Hat build, v1.2.1): `ClusterSecretStore`
  (AWS SM via IRSA) + 4 `ExternalSecret`s materialising the realm bundle and the
  coder / openshift / grafana client secrets. Required extras: token-create RBAC
  for `eso-aws-sm`, an egress `NetworkPolicy` (operator ships deny-all), and
  **no `role` field** on the store (avoids STS role-chaining). (`7449e8b`,
  `1330531`)
- Keycloak realm is now a **secret-free `ConfigMap` template** +
  a Sync-hook **render Job** that injects creds in-cluster; plaintext
  `realm-demo.yaml` removed. Coder OIDC secret switched to a `secretKeyRef`.
  The duplicated keycloak SealedSecrets were removed (ESO owns them). (`7449e8b`)
- GitLab fetches its OIDC client secret from AWS SM **at boot via its instance
  profile** (userdata); the plaintext Terraform var was removed. (`da454dc`)
- **Live rotation performed**: realm client secrets + persona passwords rotated
  via `kcadm`; consumers flipped (Coder restart, Grafana restart, OpenShift
  OAuth reload, GitLab `gitlab.rb` + reconfigure via SSM). Validated: all 4
  client secrets accepted by the realm; all 3 personas log in end-to-end.

### 1.6 Repo-wide secret remediation
- Scrubbed persona passwords from `README.md` + docs (now point to AWS SM);
  rewrote [`secrets.md`](secrets.md) with the AWS SM + ESO workflow; annotated
  the firewall demo's `fake-api-key-abc123` as an intentional fixture.
- Added a **gitleaks** CI gate (`.github/workflows/secret-scan.yml` +
  `.gitleaks.toml` allowlist). `git grep` confirms no plaintext realm secrets
  remain in tracked files. All of `manifests/secrets/` is SealedSecrets.

### 1.7 reset-demo automation
- `scripts/reset-demo.sh` now mints the GitLab admin PAT via **SSM Run Command**
  (new `GL_AWS_PROFILE`, `CLUSTER_NAME` vars) instead of SSH. (`f8cbd29`)

### 1.8 Architecture diagrams & docs
- **AWS infrastructure** diagram via the `diagrams` library (engine behind the
  AWS Diagram MCP Server) using official AWS icons —
  `docs/architecture-diagram.py` → `docs/images/architecture-aws.png`. (`9310eb0`)
- **OpenShift platform + Argo CD app-of-apps** rendered first as a node graph
  (retired as unreadable) then as a **component board** —
  `docs/architecture-board.py` → `docs/images/architecture-board.{svg,png}` —
  platform/operators bands + 18 Argo `Application`s as cards grouped by
  sync-wave with L→R sequence badges. (`a4e24a9`, `a8df01c`, `213edd8`)
- Both referenced from the root README "Architecture at a glance" section.

---

## 2. Current live state (verified this session)

- **GitLab** `i-07e4ab85a65043950`: private subnet, no public IP, IMDSv2,
  SSM online; all 9 services up, **KAS disabled**; reachable only through the
  OCP edge Routes; API returns **19.5.3**; registry reachable; git push works.
- **Secrets**: AWS SM `rhsummit/keycloak/demo-realm` present; ESO store
  `Ready=True`; 4 `ExternalSecret`s `SecretSynced`; `external-secrets` Argo app
  **Synced/Healthy**.
- **SSO**: realm rotated to new credentials; Coder, OpenShift OAuth, Grafana,
  GitLab repointed; authentication ClusterOperator Available/not Degraded;
  alice/bob/demoadm authenticate end-to-end.
- **Argo**: `keycloak`, `coder`, `platform-secrets`, `external-secrets`,
  `gitlab-ingress` Synced/Healthy.

---

## 3. Remaining gaps / follow-ups (vs. original/intended state)

| # | Gap | Impact | Suggested action |
|---|---|---|---|
| G1 | **GitLab-module Terraform not applied live.** The new `userdata.sh.tpl` (deferred reconfigure + SM boot-fetch) and the instance-profile `secretsmanager:GetSecretValue` policy are committed but **not applied**, because `terraform apply` would replace the running VM. The live VM has the rotated secret in `gitlab.rb` (set via SSM) but **not** the SM-read IAM policy or the firstboot unit. | Code ↔ live drift; a future `terraform apply` **will replace** the GitLab instance (data volume reattaches). | Schedule a maintenance window to `terraform apply` the `module.gitlab` changes (expect instance replacement), or keep deferred and apply at next rebuild. The deadlock fix + boot-fetch only take effect after that apply. |
| G2 | **Git history still contains the old (now-rotated) demo-realm credentials** — the former shared persona password and the four `*-demo-2026` OIDC client secrets. They were invalidated by the rotation but remain in prior commits. | Low (values rotated/invalid) | Optional `git filter-repo` purge + force-push (coordinate; rewrites history on a shared branch). |
| G3 | **Cloud-init deadlock fix validated only by reasoning + `bash -n`.** Not yet exercised on a real rebuild. | Medium (first real test is the next VM rebuild) | Validate on the next GitLab rebuild (ties to G1); keep the reboot-then-reconfigure recovery noted as fallback. |
| G4 | **KeycloakRealmImport does not update an existing realm.** The render Job re-seeds a *fresh* realm; live credential changes required `kcadm`. | Medium (reset semantics) | For `make reset`: delete the realm (or the KeycloakUser/client CRs) before re-running the render Job, or script a `kcadm` rotation. Document in the reset runbook. |
| G5 | **`gitlab_root_password` default is a weak placeholder** (`ChangeMeBeforeApply2026!`) in `terraform/variables.tf`. Not a Keycloak concern and root login is SSO-only, but it is a committed weak default. | Low | Require it via tfvars (remove default) or move to AWS SM like the realm creds. |
| G6 | **Safety EBS snapshot `snap-085852c78eb40460f`** (GitLab data vol) retained from the cutover. | Cost only | Delete once confident: `aws ec2 delete-snapshot --snapshot-id snap-085852c78eb40460f`. |
| G7 | **`gitlab-ingress` depends on the OCP 4.21 `RouteExternalCertificate` feature** (feature gate enabled; `ROUTER_ENABLE_EXTERNAL_CERTIFICATE=true`). | Portability | Note the dependency; confirm it's GA/enabled on any target cluster before deploying this app. |
| G8 | **ESO bootstrap applied imperatively this session.** The operator `Subscription`, `ExternalSecretsConfig`, SA, token RBAC, egress NetworkPolicy and store are all **committed** (`gitops/operator/` + `manifests/external-secrets/`) and match live, but on *this* cluster they were created by hand. | Low (captured in git) | On a fresh bootstrap the subscription applies in the operator step; no action unless rebuilding this cluster. |
| G9 | **End-to-end demo loop not re-exercised** after the cutover/rotation: the bridge restarted with a fresh PAT and is listening, but a full GitLab issue → workspace → Coder Agents chat → MR run was not performed; GitLab SSO was validated at the realm (client secret accepted + `gitlab.rb` reconfigured) but not via a browser login. | Medium (demo readiness) | Run one `coder-agent`-labelled issue through the bridge and one GitLab "Sign in with Keycloak" to confirm the headline flow before the event. |
| G10 | **Diagram regeneration needs dev deps** (`graphviz` + `pip install diagrams cairosvg`) outside the cluster. | Low | Documented in each generator's header; not part of the deploy path. |

**By design (not gaps):** the **Archify** skill was *not* installed (remote
`npx -y --global` skill execution declined in this privileged environment), and
the **AWS Diagram MCP Server** is not wired as a chat tool — we used the
underlying `diagrams` library directly to the same effect.

---

## 4. Finish / regenerate cheat-sheet

```bash
# Apply the deferred GitLab-module Terraform (REPLACES the running VM; data vol reattaches)
cd terraform && terraform apply -target=module.gitlab \
  -var gitlab_ingress_lb_hostname="$(oc -n openshift-ingress get svc router-default \
     -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"

# Read the current demo-realm credentials from AWS Secrets Manager
aws secretsmanager get-secret-value --region us-east-1 \
  --secret-id rhsummit/keycloak/demo-realm --query SecretString --output text | jq .

# Regenerate the architecture diagrams
python3 -m venv /tmp/diagvenv && . /tmp/diagvenv/bin/activate
pip install diagrams cairosvg        # needs system graphviz (dot)
python3 docs/architecture-diagram.py
python3 docs/architecture-board.py

# Delete the cutover safety snapshot once confident
aws ec2 delete-snapshot --region us-east-1 --snapshot-id snap-085852c78eb40460f
```
