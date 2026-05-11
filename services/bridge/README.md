# bridge

GitLab Issues -> Coder workspace bridge.

Accepts GitLab Issues Hook POSTs, filters by `template:<name>` label, and creates
a Coder workspace for the issue author. Designed for the
GitLab + Keycloak + Coder identity stack where the GitLab username == the Coder
username (1:1 via Keycloak).

## Behaviour

- `POST /webhook` — GitLab Issues Hook receiver. Verifies `X-Gitlab-Token` against
  `BRIDGE_WEBHOOK_SECRET` (constant-time). Filters to `object_kind=="issue"` and
  `action in {open,update,reopen}` with at least one `template:<name>` label.
  Idempotent: existing workspace -> 200 no-op.
- `GET /healthz` — liveness; always 200.
- `GET /readyz` — 200 if Coder is reachable, else 503.

## Config (env)

| Var | Required | Default | Notes |
|-----|----------|---------|-------|
| `BRIDGE_LISTEN_ADDR` | no | `:8080` | |
| `CODER_URL` | yes | | e.g. `http://coder.coder.svc.cluster.local` |
| `CODER_TOKEN` | yes | | Admin Coder session token (`Coder-Session-Token`) |
| `BRIDGE_WEBHOOK_SECRET` | yes | | Shared secret from GitLab webhook config |
| `LOG_LEVEL` | no | `info` | `debug` \| `info` \| `warn` \| `error` |

## Local run

```sh
export CODER_URL=https://coder.example.com
export CODER_TOKEN=...           # admin session token
export BRIDGE_WEBHOOK_SECRET=devsecret
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

The bridge has two interesting code paths from the outside: noop (label absent)
and happy (label present, user + template exist).

### Noop path — no `template:` label, expect 200 noop

```sh
curl -sS -X POST http://localhost:8080/webhook \
  -H 'Content-Type: application/json' \
  -H "X-Gitlab-Token: $BRIDGE_WEBHOOK_SECRET" \
  -d '{
    "object_kind": "issue",
    "user": {"username": "alice"},
    "project": {"path_with_namespace": "demo/repo"},
    "object_attributes": {"iid": 7, "action": "open", "title": "test"},
    "labels": [{"title": "bug"}]
  }'
# -> {"action":"noop","ok":true,"reason":"no template label"}
```

### Happy path — `template:python-data` label, expect 201 created

Requires a Coder user `alice` and a template named `python-data` to exist.

```sh
curl -sS -X POST http://localhost:8080/webhook \
  -H 'Content-Type: application/json' \
  -H "X-Gitlab-Token: $BRIDGE_WEBHOOK_SECRET" \
  -d '{
    "object_kind": "issue",
    "user": {"username": "alice"},
    "project": {"path_with_namespace": "demo/repo"},
    "object_attributes": {"iid": 7, "action": "open", "title": "spin up env"},
    "labels": [{"title": "template:python-data"}]
  }'
# -> {"action":"created","ok":true,"workspace_name":"alice-gl7","workspace_url":"https://.../@alice/alice-gl7"}
```

A second identical request returns `{"action":"noop","reason":"workspace exists"}`.

## Build

```sh
docker build -t bridge:dev .
```

Distroless static-debian12 nonroot runtime; binary is at `/bridge`.
