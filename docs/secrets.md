# Managing secrets — Bitnami Sealed Secrets

This demo uses [Bitnami Sealed Secrets](https://sealed-secrets.netlify.app/) to keep encrypted Kubernetes secrets in Git. Decision rationale: [`docs/decisions.md` §19](decisions.md#19-bitnami-sealed-secrets-for-in-git-secret-management-not-sops-not-esoasm-not-vault-not-inline).

## How it works

1. You generate a normal `Secret` manifest (never commit this).
2. `kubeseal` encrypts it against the in-cluster controller's public key into a `SealedSecret` CR.
3. You commit the `SealedSecret` to `manifests/secrets/`.
4. Argo CD's `platform-secrets` app applies the CR; the controller decrypts it into a regular `Secret` in the target namespace.

The cipher only decrypts in this cluster. Lose the cluster + the sealing-key backup and every secret has to be re-sealed.

## Install `kubeseal`

```bash
# macOS
brew install kubeseal

# Linux
KUBESEAL_VERSION=$(curl -s https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/latest | jq -r '.tag_name' | sed 's/^v//')
curl -fsSL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz" \
  | tar -xz -C /tmp kubeseal
sudo install -m 0755 /tmp/kubeseal /usr/local/bin/kubeseal
kubeseal --version
```

The CLI version doesn't have to match the controller exactly, but staying within one minor version is safest.

## One-time bootstrap: back up the sealing key

The Bitnami controller generates an asymmetric key pair on first start. The private half is what decrypts every `SealedSecret` in the cluster. **Back it up before you seal anything important.**

```bash
oc get secret -n sealed-secrets \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-key-backup.yaml

# Move this file into 1Password / Vault / wherever your secrets-of-secrets live.
# Do NOT commit it to Git.
shred -u sealed-secrets-key-backup.yaml   # after you've stored it elsewhere
```

If you ever rebuild the cluster:

```bash
# Apply the backed-up key BEFORE installing the controller
oc create namespace sealed-secrets
oc apply -f sealed-secrets-key-backup.yaml
# Then let Argo CD sync the controller — it'll find the key and reuse it.
```

## Per-secret workflows

All `kubeseal` invocations target `--controller-namespace=sealed-secrets` (matches `gitops/apps/sealed-secrets/application.yaml`'s destination).

### `coder-secrets` — GitHub OAuth for the `demo-rhsummit-users` org

Consumed by the Coder server (`CODER_OAUTH2_GITHUB_*` and `CODER_EXTERNAL_AUTH_0_*`).

```bash
# Create the OAuth app at https://github.com/organizations/demo-rhsummit-users/settings/applications/new
#   Homepage URL:      https://coder.apps.cluster.rhsummit.coderdemo.io
#   Callback URL:      https://coder.apps.cluster.rhsummit.coderdemo.io/api/v2/users/oauth2/github/callback

oc create secret generic coder-secrets \
  --namespace=coder \
  --from-literal=github-client-id='Ov23li...' \
  --from-literal=github-client-secret='...' \
  --dry-run=client -o yaml > /tmp/coder-secrets.yaml

kubeseal --controller-namespace=sealed-secrets --format yaml \
  < /tmp/coder-secrets.yaml \
  > manifests/secrets/coder-secrets.yaml

rm /tmp/coder-secrets.yaml

git add manifests/secrets/coder-secrets.yaml
git commit -m "secrets: seal coder-secrets (GitHub OAuth, demo-rhsummit-users)"
git push
```

Argo will sync within ~30s; the controller will decrypt into `Secret/coder-secrets -n coder`. The `coder` Deployment will need to roll to pick up the new env values:

```bash
oc rollout restart deployment/coder -n coder
```

### `coder-provisioner-key` — daemon auth key

Consumed by the external `coder-provisioner` Deployment. Chicken-and-egg: Coder must be running before you can mint a key.

```bash
# 1. Wait for Coder to be reachable. First-time login: the deployment owner
#    is the first GitHub user to log in via OAuth.
# 2. From a workstation with the Coder CLI installed:
coder login https://coder.apps.cluster.rhsummit.coderdemo.io
KEY=$(coder provisioner keys create rhsummit-demo --tag scope=organization)

# 3. Seal the key
oc create secret generic coder-provisioner-key \
  --namespace=coder \
  --from-literal=key="$KEY" \
  --dry-run=client -o yaml > /tmp/coder-provisioner-key.yaml

kubeseal --controller-namespace=sealed-secrets --format yaml \
  < /tmp/coder-provisioner-key.yaml \
  > manifests/secrets/coder-provisioner-key.yaml

rm /tmp/coder-provisioner-key.yaml
unset KEY

git add manifests/secrets/coder-provisioner-key.yaml
git commit -m "secrets: seal coder-provisioner-key"
git push
```

The `coder-provisioner` Deployment is in CrashLoopBackOff until this Secret exists; it self-heals once Argo applies the SealedSecret and the controller decrypts it.

### Granting Coder `Owner` to admin team members

The OpenShift side (decision #21) auto-syncs the `demo-rhsummit-users:admin` GitHub team into an OpenShift Group bound to `cluster-admin`. **Coder does NOT have an equivalent team→role hook** — its `CODER_OAUTH2_GITHUB_*` env vars only restrict login, not assign roles. New admins land as regular Members.

Manual one-liner per admin, after their first login:

```bash
coder users edit-roles <username> --roles owner
```

Run from a workstation already authenticated as a Coder Owner. Until you elevate them, the user can log in but won't see admin views or be able to grant licenses, manage organizations, etc.

Reasoning lives in decision #21 under "Tradeoffs."

## Updating an existing secret

Same flow — re-run the `kubeseal` invocation with the new value. Argo applies the new cipher, the controller updates the in-cluster `Secret`, and you `oc rollout restart` whatever Deployment mounts it as env vars (env-mounted secrets don't pick up changes without a pod restart; volume-mounted secrets DO).

## Viewing decrypted secrets (debug)

```bash
oc get secret coder-secrets -n coder \
  -o jsonpath='{.data.github-client-id}' | base64 -d

oc get secret coder-secrets -n coder \
  -o jsonpath='{.data}' | jq 'keys'
```

## Troubleshooting

### "no matches for kind \"SealedSecret\""

The controller hasn't rolled out yet. Check the `sealed-secrets` Argo app is `Healthy` and `Synced`:

```bash
oc get applications -n openshift-gitops sealed-secrets
oc get pods -n sealed-secrets
oc logs -n sealed-secrets -l app.kubernetes.io/name=sealed-secrets
```

### "unable to fetch certificate" / `kubeseal` can't reach the controller

`kubeseal` needs an active kubeconfig context that can reach the cluster. From outside the cluster, it talks to the controller through the API server. If you're offline, fetch the public cert once and use it for offline sealing:

```bash
kubeseal --controller-namespace=sealed-secrets --fetch-cert > /tmp/seal-cert.pem
# Now you can seal without API access:
kubeseal --cert /tmp/seal-cert.pem --format yaml < /tmp/foo.yaml > sealed.yaml
```

### "no key could decrypt secret"

The cipher was sealed against a different key — i.e. a previous controller / cluster. Either restore the original key from backup or re-seal every affected `SealedSecret` with the current key.

```bash
# Re-seal everything in manifests/secrets/ against the current cluster
for f in manifests/secrets/*.yaml; do
  [[ "$f" == *README* ]] && continue
  kubeseal --controller-namespace=sealed-secrets --re-encrypt -o yaml < "$f" > "$f.new"
  mv "$f.new" "$f"
done
```

### "wrong scope" when applying

The `template.metadata.namespace` in the SealedSecret must match the namespace where you generated the source `Secret`. Sealed Secrets is namespace-scoped by default — re-seal with the right namespace if you moved it.

## Security notes

1. **Never commit plaintext.** The `kubeseal` flow always writes plaintext to `/tmp` first; `rm` it immediately after sealing.
2. **Back up the sealing key.** Without it, a cluster rebuild means re-creating every secret from scratch.
3. **Rotate the OAuth client secret** every 90 days or after any incident — re-seal `coder-secrets`, restart Coder.
4. **Audit `oc get secret` access** the same way you'd audit any other privileged read.
