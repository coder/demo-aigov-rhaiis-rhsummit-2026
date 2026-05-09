# Bedrock model subscription — handoff to kiro-cli

**Owner:** kiro-cli (you'll have AWS context I don't)
**Goal:** subscribe the AWS account `342934376218` to every Anthropic Bedrock model the demo registers, so the IRSA role `cluster-coder-bedrock` can invoke without 403s.

## Symptom

A Coder Agents chat in the workspace, after one successful response, started returning:

```
Authentication failed
Authentication with AWS Bedrock failed. Check the API key, permissions,
and billing settings.
POST "https://bedrock-runtime.us-east-1.amazonaws.com/v1/messages":
403 Forbidden
{"message":"Model access is denied due to IAM user or service role is
not authorized to perform the required AWS Marketplace actions
(aws-marketplace:ViewSubscriptions, aws-marketplace:Subscribe) to
enable access to this model. Refer to the Amazon Bedrock documentation
for further details. Your AWS Marketplace subscription for this model
cannot be completed at this time. ..."}
```

### Claude Code CLI surfaces it differently

Inside an `ai-dev-ocp` workspace, the same 403 shows up as a "model
doesn't exist / no access" message in the Claude Code TUI, NOT as a
Bedrock error. Both the template-pinned default (`claude-sonnet-4-...`)
AND any model picked via `/model` fail the same way:

```
[coder@coder-...]$ claude
 ▐▛███▜▌   Claude Code v2.1.137
▝▜█████▛▘  Opus 4.7 (1M context) · API Usage Billing
  ▘▘ ▝▝    /home/coder

❯ who is nasa
● There's an issue with the selected model (claude-sonnet-4-6). It may
  not exist or you may not have access to it. Run /model to pick a
  different model.

❯ /model
  ⎿  Set model to Opus 4.7 (1M context) (default)

❯ who is nasa
● There's an issue with the selected model (claude-opus-4-7[1m]). It
  may not exist or you may not have access to it. Run /model to pick a
  different model.
```

This is the same upstream Marketplace 403 — AI Bridge proxies the
Bedrock response and Claude Code translates the error into its
generic "model not available" UX. Once the account-wide subscription
lands, the pinned `claude-sonnet-4-20250514` (set in
`coder-templates/ai-dev-ocp/main.tf` via `claude_settings.model`) will
work without the user touching `/model`.

Note: `claude-sonnet-4-6` and `claude-opus-4-7[1m]` are Anthropic-direct
preview tags Claude Code v2.1.x knows about but Bedrock doesn't host —
those won't resolve even after subscription. The fix is the pinned
Bedrock model id, not switching via `/model`.

## Why it happens

Per AWS's own message in the (now-retired) Bedrock Model Access page:

> Serverless foundation models are now automatically enabled across all
> AWS commercial regions when first invoked in your account, so you can
> start using them instantly. You no longer need to manually activate
> model access through this page. Note that for Anthropic models,
> first-time users may need to submit use case details before they can
> access the model. **For models served from AWS Marketplace, a user with
> AWS Marketplace permissions must invoke the model once to enable it
> account-wide for all users.**

The IRSA role `cluster-coder-bedrock` (annotated on the `coder-server`
ServiceAccount in OCP) has Bedrock invoke perms but does NOT have
`aws-marketplace:ViewSubscriptions` / `aws-marketplace:Subscribe`. So it
fails the first-call subscribe step on Marketplace-listed Anthropic
models.

The fix per AWS docs: **a marketplace-permitted principal invokes each
model once.** Account-wide subscription, then IRSA works.

## What to subscribe

The Coder Agents bootstrap Job
(`manifests/coder-agents-config/configmap.yaml`) discovers and registers
every Anthropic Opus/Sonnet inference profile in the configured region,
plus on-demand foundation models. The exact discovery query is:

```bash
aws bedrock list-inference-profiles --region us-east-1 \
  --type-equals SYSTEM_DEFINED --output json \
  | jq -r '.inferenceProfileSummaries[]
      | select(.models|length > 0)
      | select(.models[0].modelArn | contains("anthropic"))
      | select(.inferenceProfileId | test("opus|sonnet"))
      | .inferenceProfileId'

aws bedrock list-foundation-models --region us-east-1 \
  --by-provider anthropic --output json \
  | jq -r '.modelSummaries[]
      | select(.modelLifecycle.status == "ACTIVE")
      | select(.inferenceTypesSupported | index("ON_DEMAND"))
      | select(.modelId | test("opus|sonnet"))
      | .modelId'
```

Run this from the **`ocp-deploy-acct` SSO profile** (which has admin /
marketplace perms) to get the canonical list.

Per the existing handoff `HANDOFF-BEDROCK.md`, current expected hits:

- `anthropic.claude-sonnet-4-20250514-v1:0`
- `anthropic.claude-opus-4-20250514-v1:0`
- `anthropic.claude-3-5-haiku-20241022-v1:0`
- plus any inference profile IDs that show up (e.g.
  `us.anthropic.claude-sonnet-4-20250514-v1:0`)

## How to subscribe

For each model ID returned by the discovery, do a one-shot invoke from
the marketplace-permitted profile:

```bash
env -u AWS_ENDPOINT_URL aws bedrock-runtime converse \
  --model-id "<model-or-profile-id>" \
  --messages '[{"role":"user","content":[{"text":"hi"}]}]' \
  --inference-config '{"maxTokens":10}' \
  --profile ocp-deploy-acct \
  --region us-east-1
```

A 200 response with a tiny completion confirms the subscription is
done for the account. Subsequent calls from the IRSA role
`cluster-coder-bedrock` should then succeed.

A loop is fine:

```bash
for ID in \
  "anthropic.claude-sonnet-4-20250514-v1:0" \
  "anthropic.claude-opus-4-20250514-v1:0" \
  "anthropic.claude-3-5-haiku-20241022-v1:0"
do
  echo "=== $ID ==="
  env -u AWS_ENDPOINT_URL aws bedrock-runtime converse \
    --model-id "$ID" \
    --messages '[{"role":"user","content":[{"text":"hi"}]}]' \
    --inference-config '{"maxTokens":10}' \
    --profile ocp-deploy-acct --region us-east-1 \
    --query 'output.message.content[0].text' --output text \
    || echo "  FAILED on $ID — investigate manually"
done
```

If any models hit a "use case details required" prompt (Anthropic
first-time access has that intermediate step per AWS's notice), submit
the use case form once in the AWS console for that model.

## How to verify it worked

From inside the cluster, check the IRSA role can invoke. Easiest is
via the existing `coder` server pod which has the IRSA env vars
injected:

```bash
export KUBECONFIG=/tmp/kubeconfig
oc exec -n coder deploy/coder -c coder -- /bin/sh -c '
  curl -fsSL -o /tmp/aws.zip "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" 2>/dev/null \
    || true
  # If aws CLI isn't already in the image, fall back to direct API call
  # via the Python SDK:
  python3 -c "
import boto3, json
c = boto3.client(\"bedrock-runtime\", region_name=\"us-east-1\")
r = c.converse(
  modelId=\"anthropic.claude-sonnet-4-20250514-v1:0\",
  messages=[{\"role\":\"user\",\"content\":[{\"text\":\"hi\"}]}],
  inferenceConfig={\"maxTokens\":10},
)
print(json.dumps(r[\"output\"], default=str))
  "
'
```

If that returns a real completion (no 403), Bedrock is unblocked from
the workspace's perspective.

You can also re-run the failing prompt in the Coder Agents chat at
`https://coder.apps.cluster.rhsummit.coderdemo.io` — same effect.

## Background — what's running

- IRSA role: `arn:aws:iam::342934376218:role/demo/cluster-coder-bedrock`
  (trust policy via OIDC; see `terraform/irsa.tf`)
- AWS profile for admin work: `ocp-deploy-acct` (SSO; refresh with
  `env -u AWS_ENDPOINT_URL aws sso login --profile ocp-deploy-acct` if
  the session is expired)
- `coder-server` pods consume the role via the SA annotation set in
  `gitops/apps/coder/application.yaml`:
  `eks.amazonaws.com/role-arn: arn:aws:iam::342934376218:role/demo/cluster-coder-bedrock`

## Programmatic alternative

We did consider `aws marketplace-catalog start-change-set` to subscribe
directly without invoking each model. As of May 2026 AWS has not
exposed Bedrock FM subscription as a first-class operation in the
Bedrock CLI surface — the documented path is "have a marketplace-permitted
principal invoke once," which is what AWS retired the Model Access page
in favor of. If that changes, swap to the API call.

## Out of scope for this handoff

- The `aws-marketplace:Subscribe` permission could in principle be added
  to the `cluster-coder-bedrock` role so it self-subscribes. That works
  but couples runtime workspace pods to having marketplace perms — bad
  governance posture for a demo about AI governance. Keep the role
  narrow; do the one-time human-driven subscribe instead.

---

## Resolution — 2026-05-09 05:47 UTC

Ran the subscription loop from the `ocp-deploy-acct` SSO profile (AWSAdministratorAccess). Results:

### Subscribed ✅ (verified working from IRSA role inside cluster)

| Inference Profile ID | Notes |
|---|---|
| `us.anthropic.claude-sonnet-4-20250514-v1:0` | **Demo primary** |
| `us.anthropic.claude-sonnet-4-6` | Alias for latest Sonnet 4 |
| `us.anthropic.claude-sonnet-4-5-20250929-v1:0` | |
| `us.anthropic.claude-opus-4-7` | Latest Opus |
| `us.anthropic.claude-opus-4-6-v1` | |
| `us.anthropic.claude-opus-4-5-20251101-v1:0` | |
| `us.anthropic.claude-opus-4-1-20250805-v1:0` | |

### Not available ❌

| Model | Reason |
|---|---|
| `us.anthropic.claude-haiku-4-5-20251001-v1:0` | Marketplace subscription blocked even for admin — needs Anthropic use-case form in AWS console |
| `us.anthropic.claude-3-5-haiku-20241022-v1:0` | Legacy — no longer on-demand invocable |
| `us.anthropic.claude-3-sonnet-20240229-v1:0` | Legacy |
| `us.anthropic.claude-3-opus-20240229-v1:0` | EOL |
| `us.anthropic.claude-opus-4-20250514-v1:0` | Legacy (superseded by opus-4-7) |

### Haiku workaround

If a cheap/fast model is needed for the demo, submit the Anthropic use-case form at:
https://us-east-1.console.aws.amazon.com/bedrock/home?region=us-east-1#/modelaccess

Select "Claude Haiku 4.5" and fill in the one-page form. Approval is typically minutes. Then re-run:
```bash
env -u AWS_ENDPOINT_URL aws bedrock-runtime converse \
  --model-id "us.anthropic.claude-haiku-4-5-20251001-v1:0" \
  --messages '[{"role":"user","content":[{"text":"hi"}]}]' \
  --inference-config '{"maxTokens":10}' \
  --profile ocp-deploy-acct --region us-east-1
```

### Verification

Confirmed from inside the cluster via a pod using `serviceAccountName: coder-server` (IRSA role `cluster-coder-bedrock`):
```
$ aws bedrock-runtime converse --model-id us.anthropic.claude-sonnet-4-20250514-v1:0 ...
→ "Hello! How are you doing today? Is there"  ✅

$ aws bedrock-runtime converse --model-id us.anthropic.claude-opus-4-7 ...
→ "Hi there! How can I help you"  ✅
```

AI Bridge / Coder Agents should now work without 403s for all subscribed models.
