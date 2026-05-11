# Demo persona onboarding — what alice (or any demo user) runs

The bridge service (`services/bridge/`) creates a Coder workspace when a
GitLab issue gets labeled `template:<coder-template-name>`. To take that
flow end-to-end, the persona's identity has to exist on every surface
the bridge touches. This is the checklist.

Everything below is **one-time per persona, per project**. Booth resets
preserve identity (Keycloak realm survives Coder/GitLab restarts unless
the operator explicitly wipes it).

## What alice does

### 1. Sign in to Coder once

Visit `https://coder.apps.cluster.rhsummit.coderdemo.io` → click
**"Sign in with Keycloak (demo users)"** → enter alice's Keycloak
credentials (`alice` / `Demo2026!`). On first login, Coder auto-creates
a User row for alice and applies the OIDC role mappings (developers
group → site `auditor` + org `developers-auditor-plus` custom role).

If the bridge fires before this step, it returns
`422 {"error":"coder user not found: alice"}` — by design.

### 2. Sign in to GitLab once

Visit `https://gitlab.rhsummit.coderdemo.io/users/sign_in` → click
**"Sign in with Keycloak"** (the username/password form is disabled).
Same credentials as Coder. GitLab auto-creates a User row.

### 3. Create a GitLab project

In the GitLab UI:

1. **+** menu (top nav) → **New project** → **Create blank project**.
2. **Project name**: anything (e.g. `sample-app`).
3. **Project URL**: `alice` / `sample-app` (personal namespace, or a
   group namespace if alice has one).
4. **Visibility**: Private is fine; the bridge uses a token-authenticated
   webhook, not a public callback.
5. Click **Create project**.

The URL after creation is the value that goes into the next step's
`GITLAB_DEMO_PROJECTS` variable: `alice/sample-app`.

### 4. (Inside the workspace) wire git push to GitLab

When alice's workspace boots, the agent panel shows
**"Authenticate with GitLab (Demo)"**. Click it once → Keycloak
authentication → GitLab issues an OAuth token with the right scopes
(`api write_repository read_registry write_registry`) → Coder stores
the token against alice's identity. `git push` to any URL matching
`^https://gitlab\.rhsummit\.coderdemo\.io/.*` will now use that token
automatically.

**GitHub external_auth is also available as an optional second
provider** (the slot-1 button: "Authenticate with GitHub") — for
cloning the demo repo or any other github.com source from inside the
workspace. Neither is required for the workspace to boot.

## What the operator runs (once per project)

```
GITLAB_DEMO_PROJECTS="alice/sample-app" \
  ./scripts/gitlab-register-bridge-webhook.sh
```

This:
1. Reads the live bridge shared secret from
   `bridge-webhook-secret/token` in the `coder` namespace.
2. Mints a 7-day admin PAT on the GitLab EC2 host via
   `gitlab-rails runner` over SSH.
3. POSTs to `/api/v4/projects/<encoded-path>/hooks` to register
   an Issues-events webhook pointed at
   `https://bridge.apps.cluster.rhsummit.coderdemo.io/webhook`,
   with the shared secret in the `token` parameter.
4. Idempotent: re-running rotates the secret on the existing hook
   rather than creating duplicates.

Multiple projects? Comma-separated: `GITLAB_DEMO_PROJECTS="alice/foo,bob/bar"`.

## Then: the demo loop

1. Alice opens a GitLab issue in `alice/sample-app`.
2. She applies one label:
   - `template:demo-ai-gov-firewall-ocp` → workspace with egress
     restricted to Coder's AI Bridge (governed AI access)
   - `template:demo-ai-gov-no-firewall-ocp` → workspace with open
     egress to public LLM APIs (the "ungoverned" story)
   - Or any other `template:<name>` where `<name>` is a valid Coder
     template — `agents-dev-ocp`, `ai-dev-ocp`, `openshift-ai-gov`.
3. GitLab fires the webhook → bridge looks up alice's Coder user,
   looks up the template by name, POSTs to
   `/api/v2/users/alice/workspaces` with a deterministic workspace
   name `alice-gl<issue-iid>` (e.g. `alice-gl42`).
4. Coder spins the workspace. Alice clicks through to it from the
   Coder UI; bridge response also carries the workspace URL.
5. Alice authenticates to GitLab inside the workspace (step 4 above)
   once per workspace lifetime.
6. Same issue re-triggered → same workspace name → bridge no-ops.

## When something breaks

| Bridge response | What happened | Fix |
|---|---|---|
| `200 {"action":"noop","reason":"no template label"}` | Issue doesn't carry a `template:` label | Add one |
| `422 {"error":"coder user not found"}` | Persona hasn't signed in to Coder yet | Step 1 above |
| `422 {"error":"template not found"}` | Label references a template that doesn't exist in Coder | Check `template:<name>` against the templates list in Coder admin |
| `401 {"error":"unauthorized"}` | Webhook secret mismatch | Re-run the webhook registration script — it'll rotate the token in place |
| Workspace boots but `git push` fails | GitLab external_auth not connected | Step 4 above |
