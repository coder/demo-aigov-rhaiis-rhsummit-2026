# Sealed Secrets rollout — runbook

> **Audience:** an agent or operator working on the OpenShift-auth'd workstation. The repo at `coder/demo-aigov-rhaiis-rhsummit-2026` already contains every static change needed for this rollout. Your job is the cluster-side seal/commit dance.
>
> **Delete this file when the rollout is complete** (it's a one-shot artifact, not durable docs — durable docs live in [`secrets.md`](secrets.md) and [`decisions.md`](decisions.md)).

## TL;DR

1. `git pull` on the OCP-auth'd workstation.
2. Install `kubeseal` CLI.
3. Wait for the `sealed-secrets` Argo app to be `Healthy` (it'll sync automatically once the root app picks it up).
4. Back up the sealing key to a secure store.
5. Seal `coder-secrets` (GitHub OAuth credentials — operator will paste in chat).
6. Wait for Coder to come up; mint a provisioner key; seal `coder-provisioner-key`.
7. Verify everything is `Synced` + `Healthy`.

## What's already in `main` (you'll see these after `git pull`)

| File | What changed |
|---|---|
| `gitops/apps/coder/application.yaml` | Rewired Coder Helm values: GitHub OAuth for `demo-rhsummit-users`, password auth disabled, AI Bridge env vars (Bedrock-only via IRSA), `CODER_PROVISIONER_DAEMONS=0`, security headers. References `coder-secrets/{github-client-id,github-client-secret}` (will be a SealedSecret). |
| `gitops/apps/coder-provisioner/application.yaml` | New Argo app — 5-replica external provisioner Deployment. References `coder-provisioner-key/key`. |
| `gitops/apps/sealed-secrets/application.yaml` | New Argo app — Bitnami Sealed Secrets controller, sync wave -1, namespace `sealed-secrets`. |
| `gitops/apps/platform-secrets/application.yaml` | New Argo app — points at `manifests/secrets/`, sync wave 0. Picks up every `SealedSecret` you commit. |
| `manifests/secrets/{README.md,.gitkeep}` | Empty target dir so Argo can resolve the path before any cipher exists. |
| `gitops/README.md` | Updated app table, removed the "operator must `oc create secret` out-of-band" rows, added "back up the sealing key" prereq. |
| `docs/decisions.md` | New entries §19 (Sealed Secrets vs SOPS/ESO/Vault) and §20 (GitHub OAuth into Coder). |
| `docs/secrets.md` | Workflow guide (kubeseal install, per-secret invocations, troubleshooting). |

## Pre-flight

You need:
- `oc` logged into the cluster as a user with cluster-admin or equivalent (creating Secrets in `coder` and reading from `sealed-secrets`).
- `git` logged into the GitHub remote with push access to `coder/demo-aigov-rhaiis-rhsummit-2026`.
- `kubeseal` CLI (install below).
- The Coder CLI (`coder`) for step 6 — install when you get there if it's not on your PATH.

```bash
# Verify oc auth
oc whoami
oc get nodes

# Pull latest main
cd /path/to/demo-aigov-rhaiis-rhsummit-2026
git pull origin main

# Install kubeseal (Linux x86_64 — adjust for arch / OS)
KUBESEAL_VERSION=$(curl -s https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/latest | jq -r '.tag_name' | sed 's/^v//')
curl -fsSL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz" \
  | tar -xz -C /tmp kubeseal
sudo install -m 0755 /tmp/kubeseal /usr/local/bin/kubeseal
kubeseal --version
```

## Step 1 — Wait for the `sealed-secrets` controller to sync

Argo CD's root app (`gitops/bootstrap/root-app.yaml`) discovers every `application.yaml` under `gitops/apps/`. Within ~30s of `git pull` + the previous push hitting `main`, Argo should already be syncing the new `sealed-secrets` and `platform-secrets` apps.

```bash
# Watch Argo apps
oc get applications -n openshift-gitops -w

# Or just check the two new ones:
oc get application sealed-secrets -n openshift-gitops
oc get application platform-secrets -n openshift-gitops
```

Expected end state: `sealed-secrets` is `Synced` + `Healthy`, controller pod is `Running` in the `sealed-secrets` namespace.

```bash
oc get pods -n sealed-secrets
# NAME                              READY   STATUS    RESTARTS   AGE
# sealed-secrets-xxxxxxxxxx-xxxxx   1/1     Running   0          2m
```

`platform-secrets` will be `Synced` but with zero resources for now — that's fine; we add the SealedSecrets in steps 3 and 6.

If `sealed-secrets` is stuck:
```bash
oc describe application sealed-secrets -n openshift-gitops
oc logs -n sealed-secrets -l app.kubernetes.io/name=sealed-secrets --tail=100
```

## Step 2 — Back up the sealing key (CRITICAL, one-time)

The controller generated an asymmetric key on first start. The private half is the only thing that can decrypt every cipher we'll commit. **Lose this key + lose the cluster = re-seal everything from scratch.**

```bash
oc get secret -n sealed-secrets \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > /tmp/sealed-secrets-key-backup.yaml

# Verify it's not empty
grep -c "tls.key" /tmp/sealed-secrets-key-backup.yaml   # should print at least 1

# Move into your team's secrets-of-secrets store (1Password / Vault / etc.).
# DO NOT commit this file. DO NOT leave it on disk after backup.
# Operator: do this step interactively (e.g. via `op document create`).

# After verified safe in the vault:
shred -u /tmp/sealed-secrets-key-backup.yaml
```

## Step 3 — Seal `coder-secrets`

The operator pastes the GitHub OAuth client ID + secret in chat (do not echo them into shell history; use the `read -s` form below or paste directly into the heredoc).

```bash
# Read the values into env vars without leaving them in shell history.
# Operator will paste each value when prompted.
read -s -p "GitHub OAuth client ID: " GH_CLIENT_ID; echo
read -s -p "GitHub OAuth client secret: " GH_CLIENT_SECRET; echo

# Generate the plaintext Secret manifest -> /tmp -> kubeseal -> manifests/secrets/
oc create secret generic coder-secrets \
  --namespace=coder \
  --from-literal=github-client-id="$GH_CLIENT_ID" \
  --from-literal=github-client-secret="$GH_CLIENT_SECRET" \
  --dry-run=client -o yaml > /tmp/coder-secrets.yaml

kubeseal --controller-namespace=sealed-secrets --format yaml \
  < /tmp/coder-secrets.yaml \
  > manifests/secrets/coder-secrets.yaml

# Wipe plaintext immediately
shred -u /tmp/coder-secrets.yaml
unset GH_CLIENT_ID GH_CLIENT_SECRET

# Sanity check the cipher
head -20 manifests/secrets/coder-secrets.yaml
# Expected: kind: SealedSecret, encryptedData with 2 keys (github-client-id, github-client-secret),
# template.metadata.namespace: coder, template.metadata.name: coder-secrets

git add manifests/secrets/coder-secrets.yaml
git commit -m "secrets: seal coder-secrets for demo-rhsummit-users GitHub org"
git push origin main
```

Within ~30s, Argo CD's `platform-secrets` app picks up the new SealedSecret and the controller decrypts it:

```bash
oc get sealedsecret coder-secrets -n coder
oc get secret coder-secrets -n coder -o jsonpath='{.data}' | jq 'keys'
# Expected output: ["github-client-id","github-client-secret"]
```

The Coder Deployment will roll on its own once the SealedSecret is decrypted (it depends on this Secret's existence to start). If the Coder pods are stuck in `CreateContainerConfigError`, give Argo another minute, then:

```bash
oc rollout restart deployment/coder -n coder
oc rollout status  deployment/coder -n coder
```

## Step 4 — Wait for Coder to be reachable

```bash
# Find the Coder Route
oc get route coder -n coder -o jsonpath='{.spec.host}'
# e.g. coder.apps.cluster.rhsummit.coderdemo.io

# Wait until the UI returns 200
CODER_URL="https://$(oc get route coder -n coder -o jsonpath='{.spec.host}')"
until curl -sf -o /dev/null "$CODER_URL/healthz"; do echo "...waiting for Coder"; sleep 5; done
echo "Coder is up at $CODER_URL"
```

The first user to log in via GitHub OAuth becomes the deployment owner. Do that via browser before step 5 — the operator who's running this rollout is the natural choice.

## Step 5 — Seal `coder-provisioner-key`

Install the Coder CLI if it's not on your PATH:

```bash
curl -fsSL https://coder.com/install.sh | sh
```

Mint a provisioner key and seal it:

```bash
CODER_URL="https://$(oc get route coder -n coder -o jsonpath='{.spec.host}')"

# Browser-based login (opens a browser; or use --token after creating a token in the UI)
coder login "$CODER_URL"

# Mint the key (organization scope so it can build any template)
KEY=$(coder provisioner keys create rhsummit-demo --tag scope=organization 2>&1 | awk '/^Provisioner key:/ {print $3}')
[ -n "$KEY" ] || { echo "Failed to capture provisioner key — re-run interactively" >&2; exit 1; }

# Seal it
oc create secret generic coder-provisioner-key \
  --namespace=coder \
  --from-literal=key="$KEY" \
  --dry-run=client -o yaml > /tmp/coder-provisioner-key.yaml

kubeseal --controller-namespace=sealed-secrets --format yaml \
  < /tmp/coder-provisioner-key.yaml \
  > manifests/secrets/coder-provisioner-key.yaml

shred -u /tmp/coder-provisioner-key.yaml
unset KEY

git add manifests/secrets/coder-provisioner-key.yaml
git commit -m "secrets: seal coder-provisioner-key"
git push origin main
```

The `coder-provisioner` Deployment is in CrashLoopBackOff until now (it depends on this Secret). Once Argo applies the cipher and the controller decrypts:

```bash
oc rollout status deployment/coder-provisioner -n coder
oc get pods -n coder -l app.kubernetes.io/name=coder-provisioner
# Expected: 5/5 Running
```

## Step 6 — Verify everything

```bash
# Argo apps
oc get applications -n openshift-gitops
# Expected: every app Synced + Healthy. New ones to confirm:
#   sealed-secrets       Synced   Healthy
#   platform-secrets     Synced   Healthy
#   coder                Synced   Healthy
#   coder-provisioner    Synced   Healthy

# In-cluster Secrets backing the SealedSecrets
oc get secret coder-secrets         -n coder
oc get secret coder-provisioner-key -n coder

# Coder is alive and accepting GitHub OAuth
curl -sf "$CODER_URL/healthz" && echo "OK"

# Coder pods up
oc get pods -n coder -l app.kubernetes.io/name=coder
# Expected: 3/3 Running (one per AZ via topology spread)

# Provisioner pods up
oc get pods -n coder -l app.kubernetes.io/name=coder-provisioner
# Expected: 5/5 Running

# End-to-end smoke: log into Coder UI as a `demo-rhsummit-users` member,
# build the openshift-ai-gov template — if it builds, the provisioner is
# auth'd and IRSA→Bedrock→AI Bridge is wired.
```

## Cleanup

```bash
git rm docs/sealed-secrets-rollout.md
git commit -m "docs: remove sealed-secrets rollout runbook (rollout complete)"
git push origin main
```

## Things that can go wrong (and what to do)

- **`platform-secrets` Synced but `coder-secrets` Secret never appears.** Controller can't decrypt the cipher. Most common cause: the cipher was sealed against a different cluster's key. Re-run step 3 with `kubeseal --re-encrypt` against the current cluster, or restore the original sealing key from backup (`oc apply -f sealed-secrets-key-backup.yaml` followed by a controller restart).

- **Coder pods CrashLoopBackOff with "secret coder-secrets not found".** Race between Coder rollout and SealedSecret decryption. `oc rollout restart deployment/coder -n coder`.

- **Coder OAuth login fails: "you are not a member of the demo-rhsummit-users organization".** Either: (a) the user genuinely isn't in the org — invite them on GitHub; (b) the OAuth app's "Request user authorization (OAuth) during installation" wasn't checked, so the membership check fails. Verify on GitHub.

- **`coder provisioner keys create` fails with "permission denied".** The CLI session doesn't have admin rights. The first user to log in becomes the owner; if a different user logged in first, either log in as that user or have them assign you the Owner role.

- **Sealing key was generated by a previous controller install and is gone.** All previously sealed manifests are bricked. Either restore the key backup or re-seal every secret from scratch (steps 3 and 5). The repo's manifests/secrets/ would need to be regenerated.

## Why this runbook is one-shot

It documents a transition from "no SealedSecret infra, secrets created out-of-band by the operator at bootstrap" to "every secret is a `SealedSecret` in Git." Once the rollout is complete and the two ciphers are committed, the durable workflow lives in [`docs/secrets.md`](secrets.md) — that's the file new operators read. This runbook is just the bootstrap event itself; deleting it (per "Cleanup" above) keeps the repo honest about its current state.
