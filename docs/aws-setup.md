# AWS setup walkthrough

> Step-by-step from "fresh laptop" to "`terraform apply` is ready to run." Pairs with [`docs/aws-creds.md`](aws-creds.md), which explains *why* each cred exists.
> Last updated 2026-04-27 (commit `7d6d2bf`-era).

You're configuring **two** AWS profiles on this machine:

| Profile | What it owns | What you'll do with it |
|---|---|---|
| **`sandbox`** (Account B) | The demo cluster (compute, networking, IAM users, child Route 53 zone) | `terraform apply` for the cluster + every script in `scripts/` |
| **`parent`** (Account A) | The parent Route 53 zone `coderdemo.io` | Add **one** NS record to delegate `rhsummit.coderdemo.io` to the sandbox account. After this is done, the parent profile isn't needed again. |

If you don't have direct access to Account A, you can skip the parent profile — `scripts/bootstrap-r53-delegation.sh` will emit a JSON change-batch you hand to whoever does (e.g., Greg).

---

## 0. Pre-flight — install the tooling (one-time)

Most of this is probably already on your Mac.

```bash
# Confirm what's installed
aws --version          # need v2 (e.g., aws-cli/2.x)
jq --version           # any recent version
gh --version           # already authenticated (gh auth status)
terraform version      # 1.7+ or tofu 1.7+
openshift-install version   # 4.21+ — get from mirror.openshift.com
oc version --client    # 4.21+ recommended; 4.20 works against a 4.21 cluster
```

Anything missing:

```bash
# AWS CLI v2 — the v1 in default macOS won't cut it
brew install awscli

# Other helpers
brew install jq gh

# OpenShift binaries — Apple Silicon
curl -L https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable-4.21/openshift-install-mac-arm64.tar.gz | tar -xz
curl -L https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable-4.21/openshift-client-mac-arm64.tar.gz   | tar -xz
sudo mv openshift-install oc kubectl /usr/local/bin/

# Terraform (or OpenTofu)
brew install terraform   # or: brew install opentofu
```

---

## 1. Configure Account B (sandbox) — the cluster lives here

### 1a. Pick your auth path

There are three common ways orgs hand out AWS access. Pick the one your sandbox uses:

| Auth model | Looks like | Setup command |
|---|---|---|
| **AWS IAM Identity Center (SSO)** | Browser login flow, short-lived creds rotated automatically | `aws configure sso --profile sandbox` |
| **Static IAM user access keys** | You have an `AKIA...` access key + secret | `aws configure --profile sandbox` |
| **Assume role from a base account** | You have a base profile and assume into the sandbox via STS | Edit `~/.aws/config` directly with `role_arn` + `source_profile` |

If your org uses Identity Center, **prefer that path** — short-lived creds, no key rotation, no static secrets on disk.

### 1b. SSO path (recommended if available)

```bash
aws configure sso --profile sandbox
# Prompts:
#   SSO session name (Recommended): coder-sso
#   SSO start URL:                  https://<your-org>.awsapps.com/start
#   SSO region:                     us-east-1     (or wherever Identity Center lives)
#   Default region:                 us-east-1     (where the cluster will run)
#   Default output:                 json
```

After it opens the browser and you approve, the profile is registered. To refresh creds when they expire (default 8 hours):

```bash
aws sso login --profile sandbox
```

### 1c. Static-key path

```bash
aws configure --profile sandbox
# Prompts:
#   AWS Access Key ID:     AKIA...
#   AWS Secret Access Key: ...
#   Default region:        us-east-1
#   Default output:        json
```

This writes `~/.aws/credentials` and `~/.aws/config`. Static keys never rotate themselves — set a calendar reminder.

### 1d. Cross-account assume-role path

Edit `~/.aws/config` directly:

```ini
[profile sandbox]
role_arn       = arn:aws:iam::<SANDBOX_ACCOUNT_ID>:role/<ROLE_NAME>
source_profile = base
region         = us-east-1
output         = json

[profile base]
sso_session     = coder-sso
sso_account_id  = <BASE_ACCOUNT_ID>
sso_role_name   = AdministratorAccess
region          = us-east-1
```

Or set `aws_access_key_id`/`aws_secret_access_key` on the `base` profile if you don't have SSO.

### 1e. Verify

```bash
aws --profile sandbox sts get-caller-identity
# Expect a clean JSON with Account = <SANDBOX_ACCOUNT_ID>, plus your principal.
```

If you see `Unable to locate credentials` → step 1b/1c didn't write the profile.
If you see `An error occurred (ExpiredToken)` → run `aws sso login --profile sandbox`.
If you see a different account ID → you're talking to the wrong account; double-check the role/account in your SSO config.

---

## 2. Required IAM permissions on Account B

OpenShift IPI needs a long list of permissions across EC2, IAM, Route 53, ELB, S3, and Service Quotas. You have two options:

### 2a. Easy path — `AdministratorAccess`

If the sandbox is genuinely a sandbox (no other workloads, you're the sole user), grant your principal the AWS-managed `AdministratorAccess` policy. That's what `terraform/prereqs/main.tf` would have created for the optional `ocp-installer-<cluster_name>` IAM user (`var.create_installer_iam = true`).

For SSO-managed accounts, this is a permission set assignment in Identity Center — your IAM admin attaches the `AdministratorAccess` permission set to your group on the sandbox account.

### 2b. Scoped path — IPI installer policy

Red Hat publishes a scoped IAM policy for the installer at:
<https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/installing_on_aws/installation-config-aws#installation-aws-permissions-iam-roles_installing-aws-account>

The list is long (~60 statements across `ec2:*Vpc*`, `ec2:*Subnet*`, `iam:CreateRole`, `route53:*`, `s3:*`, `elasticloadbalancing:*`, plus quota read perms). It's the right answer for a shared / production AWS account — overkill for a real sandbox.

### 2c. Quota requests need an extra permission either way

For `scripts/aws-quota-bootstrap.sh request` and `terraform/prereqs/main.tf`'s optional `request_quota_increases = true`, you also need:

```json
{
  "Effect": "Allow",
  "Action": [
    "servicequotas:GetServiceQuota",
    "servicequotas:GetAWSDefaultServiceQuota",
    "servicequotas:RequestServiceQuotaIncrease",
    "servicequotas:ListRequestedServiceQuotaChangeHistory",
    "servicequotas:ListRequestedServiceQuotaChangeHistoryByQuota",
    "support:*"
  ],
  "Resource": "*"
}
```

`support:*` is required because quota increases that aren't auto-approved open a support case under the hood — without it you'll see `User is not authorized to perform: support:CreateCase`. `AdministratorAccess` covers this; the scoped path needs to be augmented.

### 2d. Quick smoke test for permissions

```bash
# These are the calls TF and the scripts make most often. If any fail with
# AccessDenied, your principal is missing perms.
aws --profile sandbox ec2 describe-vpcs                                     --region us-east-1 --max-items 1
aws --profile sandbox iam list-users                                        --max-items 1
aws --profile sandbox route53 list-hosted-zones                             --max-items 1
aws --profile sandbox service-quotas get-service-quota                      --service-code ec2 --quota-code L-1216C47A
aws --profile sandbox bedrock list-foundation-models                        --region us-east-1 --max-items 1
```

The Bedrock call confirms you have model-access read. If `bedrock` itself isn't enabled on the account, that's a separate one-time activation in the AWS console for the region — see [the Bedrock setup section](aws-creds.md#aws-bedrock-model-access--one-time-manual-human) of `docs/aws-creds.md`.

---

## 3. Configure Account A (parent zone) — only needed for the R53 NS delegation

Skip this section if Greg / whoever owns `coderdemo.io` will apply the change-batch for you. In that case you'll run `scripts/bootstrap-r53-delegation.sh` *without* `--parent-profile` — it'll emit a JSON file you hand off, and you're done.

### 3a. Configure the profile

Same auth options as Account B (`aws configure sso --profile parent`, or `aws configure --profile parent`). Use whatever auth your CS account hands out.

```bash
aws --profile parent sts get-caller-identity
# Expect Account = <PARENT_ACCOUNT_ID>
```

### 3b. Required permissions on Account A

Tiny scope — only Route 53 changes on the parent zone:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DelegateChildZone",
      "Effect": "Allow",
      "Action": [
        "route53:ChangeResourceRecordSets",
        "route53:ListResourceRecordSets",
        "route53:GetChange"
      ],
      "Resource": "arn:aws:route53:::hostedzone/<PARENT_ZONE_ID>"
    },
    {
      "Sid": "FindZoneByName",
      "Effect": "Allow",
      "Action": "route53:ListHostedZonesByName",
      "Resource": "*"
    }
  ]
}
```

Replace `<PARENT_ZONE_ID>` with the hosted-zone ID of `coderdemo.io` (find it via `aws --profile parent route53 list-hosted-zones-by-name --dns-name coderdemo.io. --query 'HostedZones[0].Id' --output text`).

`AdministratorAccess` works too if Account A is freely editable for you — but for the parent zone you almost certainly want the minimum scope above.

### 3c. Smoke test

```bash
aws --profile parent route53 list-hosted-zones-by-name \
  --dns-name coderdemo.io. \
  --query 'HostedZones[?Name==`coderdemo.io.`].{Id:Id, Records:ResourceRecordSetCount}' \
  --output table
```

You should see the zone listed with a non-zero record count.

---

## 4. Wire the profiles into `.env`

Once `aws sts get-caller-identity` works for both profiles, drop the names into the project's `.env`:

```bash
cd ~/code/coder/demo-aigov-rhaiis-rhsummit-2026
cp .env.example .env

# Edit .env:
#   AWS_PROFILE_SANDBOX="sandbox"     ← whatever you named it in step 1
#   AWS_PROFILE_PARENT="parent"       ← or "" if you skipped Account A
```

Then `source .env` in your shell before running TF or any of the scripts. Every script in `scripts/` honors these env vars; Terraform picks up `AWS_PROFILE` (which `.env` sets to `AWS_PROFILE_SANDBOX`).

---

## 5. End-to-end verify

`scripts/verify-aws-access.sh` runs the same smoke tests above, prints a checklist, and exits non-zero if anything's missing:

```bash
source .env
scripts/verify-aws-access.sh
```

Expected output is all-green for the sandbox profile and either all-green or `(skipped)` for the parent profile depending on whether you set `AWS_PROFILE_PARENT`.

---

## 6. What's next

Once both profiles verify cleanly:

1. **R53 cross-account delegation** — `scripts/bootstrap-r53-delegation.sh` (one-time, ~2 min)
2. **Service quotas** — `scripts/aws-quota-bootstrap.sh check` then `... request` if anything is short. **Run this at least a week before the booth** if your sandbox is new — GPU vCPU (`L-DB2E81BA`) approval is case-based, not auto.
3. **Bedrock model access** — open the URL printed by `terraform output -raw bedrock_model_access_url` after the cluster is up; one-click approval per Anthropic model.
4. **Account-level prereqs** — `cd terraform/prereqs && terraform apply`. With `manage_hosted_zone = false` (default in `.env`), this only creates the optional installer IAM user.
5. **Cluster install** — `cd terraform && terraform apply`. ~60 minutes; see the [startup-time table](../README.md#startup-time-cold-start-to-first-usable-workspace) in the main README.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Unable to locate credentials` from any `aws` command | Profile not set, or shell didn't pick up `.env` | Re-run `source .env`; verify `echo $AWS_PROFILE` is the right name |
| `ExpiredToken` after a few hours | SSO creds expired | `aws sso login --profile sandbox` (and `parent` if you have one) |
| `AccessDenied` on `iam:CreateUser` from `terraform apply` | Sandbox principal missing IAM perms | Need at least IAM user/policy/key creation — see §2a/§2b |
| `AccessDenied` on `support:CreateCase` from `aws-quota-bootstrap.sh request` | Quota increase fell through to a support case but principal lacks `support:*` | Add `support:*` to your scoped policy or use `AdministratorAccess` |
| `bedrock list-foundation-models` returns empty / 404 | Bedrock not enabled for this region on the account | One-time enable in the AWS console; see [`docs/aws-creds.md`](aws-creds.md) |
| `aws configure sso` step prompts for a different region than expected | Identity Center home region ≠ workload region | The SSO region is where Identity Center lives (often `us-east-1`); the *default region* it asks for next is where you'll deploy (also `us-east-1` for this demo) |
| `terraform apply` fails with `cluster: cluster name length should not exceed ... characters` | `cluster_name + base_domain` is too long | Shorten one of them; OCP IPI has a strict combined limit |
| Terraform sees stale state after a session rotation | Old SSO token still cached | `aws sso logout` then `aws sso login --profile sandbox` |

If you get stuck on a step, [`docs/aws-creds.md`](aws-creds.md) explains *why* each cred exists; this doc is the *how*.
