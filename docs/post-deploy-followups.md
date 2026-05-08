# Post-deployment follow-ups

> Open questions and gaps to address **after** the initial cluster comes up. These are not blockers for first boot — but each one is a decision we punted, a default we accepted, or a thing we'll want answered before the cluster lives in front of anyone other than us.
> Last updated 2026-05-08.

## How to use this doc

Each entry is one open question: **what we have today**, **what's missing or unanswered**, and **what we'd need to do to close it**. When something is resolved, move it to `docs/decisions.md` (with the rationale) and delete it from here.

---

## 1. Argo CD repo authentication

**Today:** No repo credentials configured. Argo CD clones `https://github.com/coder/demo-aigov-rhaiis-rhsummit-2026.git` unauthenticated. Works because the repo is public.

**Open questions:**
- Will the repo stay public through the event? If it goes private, every sync breaks immediately.
- Same applies to `https://helm.coder.com/v2` (Coder Helm chart) — public, unauthenticated.
- The `openshift-gitops` instance is operator-default — no `ArgoCD` CR in this repo customizing RBAC, SSO, or repo creds.

**To close:**
- If the repo goes private: create a Secret of type `Opaque` with label `argocd.argoproj.io/secret-type: repository` containing either a GitHub App key, a fine-grained PAT, or an SSH deploy key.
- Decide: GitHub App (preferred for org repos, auto-rotating) vs fine-grained PAT (simpler, 90-day expiry) vs SSH deploy key (read-only, no expiry management).
- Add the Secret to the terraform bootstrap provisioner (alongside the other cluster secrets).

---

## 2. Default ingress / console / Argo CD UI certs (self-signed)

**Today:** Only Coder and Grafana routes have real Let's Encrypt certs (via cert-manager DNS-01):
- `coder.apps.<fqdn>` + `*.coder.apps.<fqdn>` — `manifests/coder/certificate.yaml`
- `grafana.apps.<fqdn>` — `manifests/observability/certificate.yaml`

Everything else uses the default IngressController's self-signed wildcard:
- OpenShift web console (`console-openshift-console.apps.<fqdn>`)
- Argo CD UI (`openshift-gitops-server-openshift-gitops.apps.<fqdn>`)
- OAuth server (`oauth-openshift.apps.<fqdn>`)
- API server (`api.<fqdn>:6443`) — internal cluster CA, separate from ingress

**Open questions:**
- Do we care about browser cert warnings on console/argocd for the booth demo? (Audience only sees Coder UI, but we use console for debugging.)
- Is it worth the complexity of patching the default IngressController cert vs just clicking through warnings?

**To close (recommended: single wildcard on default IngressController):**
1. Create a cert-manager `Certificate` for `*.apps.<cluster_name>.<base_domain>` using the existing `letsencrypt-prod` ClusterIssuer.
2. Patch the default IngressController: `oc patch ingresscontroller/default -n openshift-ingress-operator --type=merge -p '{"spec":{"defaultCertificate":{"name":"apps-wildcard-cert"}}}'`
3. Add both as manifests under `manifests/cert-manager/` and let Argo CD manage them.
4. The API server cert is separate — requires patching the `APIServer` resource. Lower priority (only `oc` CLI users see it).
