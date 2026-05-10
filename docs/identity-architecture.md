# Demo Identity & SCM Architecture — RH Summit 2026

## Context

The demo repo at **github.com/coder/demo-aigov-rhaiis-rhsummit-2026** originally used:
- **GitHub** as SCM
- **GitHub OAuth** gated on `coder/demo-rhsummit-users` team for Coder, OpenShift Console, and Grafana logins
- A GitHub Actions secret `CODER_SESSION_TOKEN` for the workspace-provisioning path

This is being **augmented** (not replaced) with an on-cluster Keycloak realm so the demo:
1. Doesn't depend on a presenter-specific GitHub identity for the demo-user persona path (the booth machine is operated by multiple SEs/sales reps; we don't want anyone's personal `austen@coder.com` GitHub session left signed in)
2. Resets declaratively between booth presenters
3. Tells a stronger story for the RH Summit audience (self-hosted GitLab + Keycloak mirrors how RH-shop enterprises actually run)

**Dual-IdP architecture (updated 2026-05-10):** GitHub OAuth STAYS as an IdP for both OpenShift and Coder — that's the **admin** access path (Coder team, SE/admin presenters using their `coder/demo-rhsummit-users:admin` team membership). Keycloak is ADDED as a **second** IdP scoped to the **demo-user personas** (alice, bob, carol, dave). Both OpenShift's OAuth CR and Coder's auth config support multiple IdPs natively; this is not a swap, it's a stacking.

The blocker that forced this pivot: adding a shared demo GitHub user (working name `coderfed`) into the `coder` GitHub org couldn't be cleared by demo day. Even if it could, GitHub-org-gated identity doesn't reset between presenters without admin intervention. Keycloak gives us reset-friendly demo-user identities while admins keep using GitHub.

## Target Architecture

```
                       ┌─────────────────────┐
                       │  Keycloak (RHBK)    │
                       │  realm: rhsummit    │  ← single source of identity
                       │  users: alice,bob,… │
                       │  group: developers  │
                       └──────────┬──────────┘
                                  │ OIDC
            ┌─────────────────────┼─────────────────────┐
            │                     │                     │
       ┌────▼────┐          ┌─────▼─────┐         ┌─────▼────┐
       │ GitLab  │          │   Coder   │         │ Grafana  │
       │ self-   │          │           │         │          │
       │ hosted  │          └─────┬─────┘         └──────────┘
       └────┬────┘                │                     ┌─────▼──────┐
            │ webhook             │ API                 │  OpenShift │
            │ (issue.assigned)    │                     │  Console   │
            └───►┌──────────────┐ │                     └────────────┘
                 │ bridge svc   │─┘
                 │ (small pod)  │
                 └──────────────┘
```

All four web UIs (GitLab, Coder, Grafana, OpenShift Console) federate to Keycloak. The hero moment of the demo is GitLab issue assignment → bridge service → Coder API → workspace spins up ready by the time the dev sits down.

## Components

### 1. Keycloak (Red Hat Build of Keycloak)

- Deploy via the Keycloak Operator on OpenShift.
- Realm name: `rhsummit` (or similar — pick once and use consistently).
- Declared via `KeycloakRealmImport` CR so the realm config lives in git as YAML.
- Users: 3–5 demo personas (`alice`, `bob`, `carol`, …), all with a known shared password (booth context, not a security boundary).
- Groups: `developers` (default for all demo users), `admins` (subset, for Grafana admin role).
- Pre-declared OIDC clients:
  - `coder` — confidential, redirect URI = Coder's callback
  - `gitlab` — confidential, redirect URI = GitLab's `/users/auth/openid_connect/callback`
  - `openshift` — used by the OAuth CR's `OpenIDIdentityProvider` type
  - `grafana` — confidential, redirect URI = Grafana's `/login/generic_oauth`
- Group claim mapping included in the token so downstream services can map groups → roles.

### 2. GitLab (self-hosted on EC2 — NOT in the cluster)

**Updated 2026-05-10:** GitLab runs on a dedicated `t3.large` EC2 instance (2 vCPU, 8 GiB, ~$2/day) using the **Omnibus installer** on Amazon Linux 2023 (or RHEL 9 for the RH-shop narrative). Rationale:
- 5-minute Omnibus install vs 30-45 minutes for Helm/Operator on OCP
- Zero cluster resource contention (Coder + vLLM + observability already use significant RAM/CPU)
- Reset is fast and fully isolated from cluster lifecycle
- "Dedicated GitLab VM federated by Keycloak to OpenShift apps" is a more realistic enterprise pattern than "GitLab in K8s"
- Failure isolation: GitLab crash can't take down cluster Postgres / Coder

Networking:
- Hostname: `gitlab.rhsummit.coderdemo.io` (A record to the EC2 public IP; same Route 53 zone as the cluster)
- TLS: Let's Encrypt via `gitlab-ctl` (Omnibus handles renewal natively)
- Public subnet so booth laptops + cluster pods both reach it via the public DNS name
- Security group: 80/443 ingress from anywhere, 22 from operator IP only; outbound unrestricted

Configuration:
- Terraform module `terraform/gitlab/` provisions: EC2 instance + security group + Route 53 A record + EBS data volume + cloud-init that installs gitlab-ce, configures Omnibus with the right `external_url` and OIDC settings, requests the Let's Encrypt cert.
- OIDC against Keycloak using the `gitlab` client. Keycloak's issuer URL (`https://keycloak.apps.<cluster-fqdn>/realms/rhsummit`) is reachable from the EC2 instance because it's served via the public OCP Route.
- Pre-seeded content (declared via the GitLab Terraform provider — runs after the VM is up and the API is reachable):
  - Group `demo` containing the project(s) prospects interact with
  - Project `demo/sample-app` with starter code + a few open issues with realistic story descriptions
  - Webhook on each project pointing at the bridge service's public Route in the cluster (`https://issue-bridge.apps.<cluster-fqdn>/webhook`)
- Disable signup (`gitlab_signup_enabled = false`). Only Keycloak-federated users can log in.

Backup: EBS snapshot daily. Reset = `glab issue/project` API calls (or Terraform destroy + re-apply for the project subtree only — keep the VM running).

### 3. Coder

- OIDC against Keycloak using the `coder` client.
- Template: parameterized to accept a GitLab issue ID and project path. Workspace startup script clones the GitLab repo, checks out a branch named for the issue, opens the relevant files.
- The template should pull container images from a registry the cluster can reach (likely the same GitLab's container registry, which keeps everything in one stateful service).
- Group sync: Keycloak `developers` → Coder organization member role.

### 4. Issue → Workspace bridge

The hero demo moment. Smallest sensible implementation:

- A tiny HTTP service (Go or Python, single container) deployed on the cluster.
- Listens for GitLab webhook events filtered to `Issue Hook` with `object_attributes.action == "update"` and a non-empty `assignees`.
- On a relevant event, calls Coder API: `POST /api/v2/users/{user_id}/workspaces` with:
  - `template_id` of the demo template
  - `rich_parameter_values` including issue ID, issue title, project path, branch name
- User-id mapping: GitLab user → Coder user resolved by matching email (both come from Keycloak, so emails align).
- Idempotency: check for an existing workspace named after the issue before creating a new one.
- Auth: bridge holds a Coder admin token in a Kubernetes Secret. GitLab → bridge auth via a webhook secret header.

### 5. OpenShift Console

- Add an `OpenIDConnect` identity provider to the `OAuth` cluster CR pointing at Keycloak.
- Group sync via the OIDC `groups` claim → OpenShift groups. Map `admins` → `cluster-admins` if you want demo users to see operator dashboards.

### 6. Grafana

- OIDC against Keycloak using the `grafana` client.
- Role mapping: `admins` group → Grafana Admin, everyone else → Viewer.
- Config goes in the Grafana CR (assuming Grafana Operator) or `grafana.ini` if Helm.

## Realm/Client Naming Conventions

Pick once, use everywhere. Suggested:

| Thing | Value |
|---|---|
| Keycloak realm | `rhsummit` |
| Keycloak issuer URL | `https://keycloak.apps.<cluster-fqdn>/realms/rhsummit` |
| GitLab base URL | `https://gitlab.apps.<cluster-fqdn>` |
| Coder base URL | `https://coder.apps.<cluster-fqdn>` (unchanged from current demo) |
| Grafana base URL | `https://graf-coder.apps.<cluster-fqdn>` (unchanged) |
| OIDC group claim | `groups` |
| Demo project path | `demo/sample-app` |

## Build Order

These layers each unblock the next; do them in order unless you're parallelizing intentionally.

1. **Keycloak up with realm import.** Operator install + `KeycloakRealmImport` CR with users, groups, and all four OIDC clients pre-declared. Verify by logging into Keycloak's account console as `alice`.
2. **Wire Coder OIDC to Keycloak.** Easiest second consumer — just OIDC client config in Coder. Confirms the realm works end-to-end. After this, every reference to GitHub OAuth in the demo content is dead weight.
3. **GitLab on the cluster, OIDC to Keycloak.** The big install. Helm or Operator. Pre-seed the project and issues via Terraform provider in the same repo.
4. **Issue → workspace bridge.** Build, deploy, register webhook. Test the full path: assign an issue in GitLab → workspace appears in Coder within seconds.
5. **OpenShift Console + Grafana OIDC.** Both are mechanical once Keycloak is proven.
6. **`make reset` flow.** See below.
7. **Booth station (separate workspace).** Out of scope for this repo — handled in the bootc image for the `rhsummit-demo` host.

## Reset Story

Goal: `make reset` returns the demo environment to a known clean state between booth presenters, fast (target: under 60 seconds).

Two approaches, pick one:

- **Surgical:** `oc delete keycloakuser/* -n keycloak --all` + GitLab API calls to delete and recreate the demo project + `oc delete workspaces` (Coder CRDs if templates are Kubernetes-backed, otherwise `coder delete` for each workspace). Fast but more script to maintain.
- **Full wipe:** delete the GitLab namespace and the Keycloak realm, reapply manifests. Slow (GitLab takes minutes to come back) but bulletproof. Probably not what you want mid-event.

Recommended: build the surgical path. Bake it into a `Makefile` target. Keep the full wipe as `make reset-hard` for end-of-day.

The demo users' state (workspaces, branches, issues) all live in resources you control declaratively, so reset is deterministic.

## What Changes in the Demo Repo

Concrete edits to `coder/demo-aigov-rhaiis-rhsummit-2026`:

1. **Auth config — ADD, don't replace.** Current setup uses GitHub OAuth apps with `demo-rhsummit-users` org filter. Keycloak OIDC is *added alongside*. Affects:
   - OpenShift OAuth CR: `identityProviders` list gains a new `openid` entry pointing at Keycloak. The existing `github` entry stays. The OAuth CR supports multiple IdPs; users see both buttons on the OCP login page.
   - Coder helm values: keep `CODER_OAUTH2_GITHUB_*` env vars (existing admin path). Add `CODER_OIDC_*` env vars for the Keycloak client. Coder supports both auth types simultaneously.
   - Grafana CR / helm values: similar dual config (`auth.github` + `auth.generic_oauth` for Keycloak).
   - GitLab: Keycloak is the *only* IdP for GitLab — GitLab is itself a new component, no GitHub-OAuth-into-GitLab path exists today, no need to add one.
2. **New manifests:**
   - Keycloak Operator subscription + `Keycloak` + `KeycloakRealmImport` CRs
   - GitLab Operator or Helm release + Terraform module declaring the demo project/group/webhooks
   - Bridge service: small Go/Python container, Deployment + Service + Ingress, plus a Secret for the Coder admin token
3. **GitHub Actions sprint-ticket flow:** the bridge replaces it AS THE DEMO TRIGGER (GitLab issue → workspace). The GH Actions workflow itself stays as the **admin** sprint trigger (Coder team can still use GH issues + the workflow to provision workspaces with their GitHub identity). Both paths coexist; the booth talk-track uses the GitLab path.
4. **Documentation:** README's "Authentication & Credential Requirements" section needs a partial rewrite — the GitHub OAuth setup steps stay, plus add the Keycloak/GitLab credentials section. The new required inputs are still AWS creds, pull secret, SSH key, GH OAuth client; what's added is Keycloak admin password (sealed) and GitLab root password (sealed).
5. **`gh` CLI references** in setup scripts → keep (still used for the admin path). Add `glab` if the bootstrap script needs to push to the GitLab demo project.

## Anti-Patterns / Explicit Non-Goals

- **Do not put secrets in any container image** (this includes the booth bootc image and any custom Coder template images). Keycloak client secrets, the bridge's Coder admin token, AWS keys, pull secret — all of these live in Kubernetes Secrets, ExternalSecrets, or sealed-secrets. Never in image layers.
- **Do not gate any *demo-user* identity on the `coder` GitHub org.** That blocker is exactly what the Keycloak addition exists to escape. Admin-tier access (Coder owners, OCP cluster-admins) still flows through the existing GitHub OAuth + `demo-rhsummit-users:admin` team mapping — that's the dual-IdP design.
- **Do not remove GitHub OAuth.** Stays as the admin-tier IdP for Coder + OpenShift. The dual-IdP model is the design, not an interim state. Mixing identity providers IS confusing if you don't separate them by role, so the separation is: GitHub OAuth → `admin`-tier humans (presenters, Coder team); Keycloak → demo-persona accounts (alice/bob/carol/dave).
- **Do not bake demo-user state into the Keycloak image.** Users live in the realm import YAML in git, applied as a CR — that way reset is just re-applying the manifest.
- **Do not assume GitLab CI executes on the cluster.** If the demo flow needs a CI run, set up GitLab Runner explicitly and budget cluster resources for it. Otherwise the issue→workspace bridge is the only "automation" path the demo exercises.

## Out of Scope for This Doc

- **The booth station itself** (`rhsummit-demo` host, bootc image, demo Linux user, browser pre-signed-in to Keycloak as a demo user). That work happens in a separate workspace against the Containerfile + Makefile on USB.
- **AWS account setup, IAM, openshift-install bootstrap.** Assume the OpenShift cluster exists and you have cluster-admin.

## Open Questions

- Which Keycloak: upstream Keycloak Operator, or specifically Red Hat Build of Keycloak Operator (RHBK)? RHBK is the on-narrative choice for an RH event; functionally equivalent for our needs.
- GitLab CE or EE? Resource budget is similar. EE has nicer issue/board features for the demo visuals but requires a trial license. CE is fine.
- Bridge language: Go (single static binary, fits in a tiny container) vs Python (faster to iterate, slightly larger image). Recommend Go unless you already have Python bridge code lying around.
- Demo user count: 3 personas enough for the booth flow, or do you want 5+ to show role-based variation?
