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

The bridge requires **BOTH** of these on an issue before it spawns
anything; either alone is a no-op. Whichever event (label-add OR
assignee-add) is applied second triggers the spawn — order doesn't
matter.

1. PM (or anyone) opens a GitLab issue in `alice/sample-app`.
2. **Assign** the issue to a Keycloak persona (alice, bob, carol, dave).
   The assignee — not the author — owns the resulting workspace and
   chat. (Rationale: authors are typically PMs, not the people who
   do the work.)
3. **Apply one label**:
   - `coder-hitl` → "human in the loop". Bridge spawns a workspace
     for the assignee; assignee opens it and works manually.
   - `coder-agent` → "agent". Bridge spawns a workspace AND creates
     a Coder Agents chat owned by the assignee, pre-seeded with
     *"Go work on this GitLab issue: <url>. When done, push a branch
     and open a Merge Request."* Llama 70B then drives the chat
     autonomously inside the workspace.
   - Both labels? `coder-agent` wins.
4. Bridge posts a comment back on the issue with the workspace URL
   (always) and chat URL (coder-agent only).
5. Workspace name format: `{assignee}-gl{issue-iid}` (deterministic,
   so re-triggers on the same issue no-op via the workspace-exists
   check).
6. Inside the workspace, assignee clicks "Authenticate with GitLab"
   once to wire git push (Coder external_auth).

**Template selection**: the bridge uses the `DEFAULT_TEMPLATE` env
on its Deployment (currently `ai-dev-ocp`). Per-project override via
GitLab CI variable or `.coder` file is a future enhancement.

## When something breaks

| Bridge response | What happened | Fix |
|---|---|---|
| `200 {"action":"noop","reason":"no coder-{hitl,agent} label"}` | Issue is missing the trigger label | Add `coder-hitl` or `coder-agent` |
| `200 {"action":"noop","reason":"no assignee — assign the issue to trigger spawn"}` | Label present but no assignee | Assign the issue to a Keycloak persona |
| `200 {"action":"noop","reason":"workspace exists"}` | Re-trigger of same issue | Working as designed; idempotent |
| `422 {"error":"coder user not found"}` | Assignee hasn't signed in to Coder yet | Persona needs to log in once via Keycloak |
| `422 {"error":"default template not found"}` | DEFAULT_TEMPLATE env points at a non-existent template | Check `oc -n coder logs deploy/bridge` for the name being looked up; either push the template via `coder templates push` or update the env |
| `401 {"error":"unauthorized"}` | Webhook secret mismatch | Re-run `./scripts/gitlab-register-bridge-webhook.sh` |
| `chat_error` in response, workspace_url still present | Coder chat creation failed (likely vLLM unreachable or chat API change) | Workspace is usable; check `bridge` logs for the chat_error detail |
| Workspace boots but `git push` fails | GitLab external_auth not connected | Click "Authenticate with GitLab (Demo)" inside the workspace |
