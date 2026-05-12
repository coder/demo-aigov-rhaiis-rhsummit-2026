# bridge

GitLab Issues -> Coder workspace bridge.

Accepts GitLab Issues Hook POSTs, filters by `coder-workspace` / `coder-agent`
labels, and creates a Coder workspace (and optionally an autonomous chat) for
the issue's assignee. Designed for the GitLab + Keycloak + Coder identity
stack where the GitLab username == the Coder username (1:1 via Keycloak).

## Behaviour

- `POST /webhook` — GitLab Issues Hook receiver. Verifies `X-Gitlab-Token` against
  `BRIDGE_WEBHOOK_SECRET` (constant-time). Filters to `object_kind=="issue"` and
  `action in {open,update,reopen}` with at least one of the labels below AND a
  non-empty assignee list. Idempotent: existing workspace -> reuse, existing
  agent chat -> reuse.
- `GET /healthz` — liveness; always 200.
- `GET /readyz` — 200 if Coder is reachable, else 503.

## Label vocabulary

The bridge looks at the issue's labels (top-level `labels[]`, per GitLab's
Issue Hook schema). When both `coder-workspace*` and `coder-agent*` are present,
**agent wins** (it's the superset: agent always spawns a workspace too).

| Label                                | Action                                                                                              |
|--------------------------------------|-----------------------------------------------------------------------------------------------------|
| `coder-workspace`                    | Create a workspace using the **default** template (`artemis-sim-dev-ocp`). Assignee opens it.       |
| `coder-workspace:<template-slug>`    | Create a workspace using the named Coder template (e.g. `coder-workspace:ai-dev-ocp`).              |
| `coder-agent`                        | Create a workspace + an autonomous chat using the **default** chatd model.                          |
| `coder-agent:<model-slug>`           | Create a workspace + chat pinned to the matching model (case-insensitive substring; latest version wins). |

Slug charset: `[a-z0-9._-]+` (case-insensitive, lowercased on parse). Slugs
with spaces or other punctuation are ignored — the bridge falls through to
no-match for that label.

## Workspace naming

`<repo>-issue-<iid>` derived from the GitLab project's `path_with_namespace`
(last path segment only) and the issue IID. Lowercased, non-`[a-z0-9-]` chars
replaced with `-`. Coder enforces a 32-char limit; when the assembled name
exceeds 32 chars the repo prefix is truncated and the `-issue-<iid>` suffix
is preserved.

Examples:

| `path_with_namespace`         | `iid` | Workspace name                       |
|-------------------------------|-------|--------------------------------------|
| `alice/artemis-sim`           | 7     | `artemis-sim-issue-7`                |
| `Demo/ProjectName`            | 12    | `projectname-issue-12`               |
| `group/sub-group/repo.dots`   | 3     | `repo-dots-issue-3`                  |
| long repo + large iid         | n     | repo prefix truncated, suffix intact |

## Workspace parameters (rich parameter values)

On `CreateWorkspace`, the bridge sets the template parameter `git_repo` to
`Project.WebURL` from the webhook payload (e.g.
`https://gitlab.rhsummit.coderdemo.io/alice/artemis-sim`). Templates that
declare a `git_repo` parameter (like `artemis-sim-dev-ocp`) therefore track
the originating issue's project automatically — the template's own
`git_repo` default is only used for UI-driven workspace creation. Templates
that don't declare a `git_repo` parameter simply ignore the extra value.

## Config (env)

| Var | Required | Default | Notes |
|-----|----------|---------|-------|
| `BRIDGE_LISTEN_ADDR` | no | `:8080` | |
| `CODER_URL` | yes | | e.g. `http://coder.coder.svc.cluster.local` |
| `CODER_PUBLIC_URL` | no | `$CODER_URL` | External URL used to build user-facing workspace + chat links |
| `CODER_TOKEN` | yes | | Admin Coder session token (`Coder-Session-Token`) |
| `BRIDGE_WEBHOOK_SECRET` | yes | | Shared secret from GitLab webhook config (`X-Gitlab-Token`) |
| `GITLAB_API_URL` | yes | | e.g. `https://gitlab.rhsummit.coderdemo.io/api/v4` |
| `GITLAB_BRIDGE_PAT` | yes | | Long-lived admin PAT used to post issue comments |
| `DEFAULT_TEMPLATE` | no | `artemis-sim-dev-ocp` | Template name used when no `coder-workspace:<slug>` override is supplied |
| `LOG_LEVEL` | no | `info` | `debug` \| `info` \| `warn` \| `error` |

## Local run

```sh
export CODER_URL=https://coder.example.com
export CODER_TOKEN=...           # admin session token
export BRIDGE_WEBHOOK_SECRET=devsecret
export GITLAB_API_URL=https://gitlab.example.com/api/v4
export GITLAB_BRIDGE_PAT=...
go run ./cmd/bridge
```

## Tests

```sh
go test ./...
```

Covers workspace-name derivation, label regex, token verification, and the
actionable-event filter. Integration against a real Coder lives in the
deployment smoke test; see below.

## Manual smoke test

The bridge has two interesting code paths from the outside: noop (no
coder-* label or no assignee) and happy (label present + assignee set).

### Noop path — no coder-* label, expect 200 noop

```sh
curl -sS -X POST http://localhost:8080/webhook \
  -H 'Content-Type: application/json' \
  -H "X-Gitlab-Token: $BRIDGE_WEBHOOK_SECRET" \
  -d '{
    "object_kind": "issue",
    "user": {"username": "alice"},
    "project": {"id": 1, "path_with_namespace": "demo/repo", "web_url": "https://gitlab.example.com/demo/repo"},
    "object_attributes": {"iid": 7, "action": "open", "title": "test"},
    "assignees": [{"username": "alice"}],
    "labels": [{"title": "bug"}]
  }'
# -> {"action":"noop","ok":true,"reason":"no coder-{workspace,agent} label"}
```

### Happy path — `coder-workspace` label, expect 201 created

Requires a Coder user `alice` and the default template to exist.

```sh
curl -sS -X POST http://localhost:8080/webhook \
  -H 'Content-Type: application/json' \
  -H "X-Gitlab-Token: $BRIDGE_WEBHOOK_SECRET" \
  -d '{
    "object_kind": "issue",
    "user": {"username": "alice"},
    "project": {"id": 1, "path_with_namespace": "demo/artemis-sim", "web_url": "https://gitlab.example.com/demo/artemis-sim"},
    "object_attributes": {"iid": 7, "action": "open", "title": "spin up env"},
    "assignees": [{"username": "alice"}],
    "labels": [{"title": "coder-workspace"}]
  }'
# -> {"action":"ready","ok":true,"workspace_name":"artemis-sim-issue-7","workspace_url":"https://.../@alice/artemis-sim-issue-7"}
```

A second identical request reuses the existing workspace.

## Build

```sh
docker build -t bridge:dev .
```

Distroless static-debian12 nonroot runtime; binary is at `/bridge`.
