#!/usr/bin/env bash
#
# bootstrap-r53-delegation.sh
#
# Stand up a Route 53 subdomain delegation across two AWS accounts.
#
#   parent account  ──[ NS record ]──▶  child account
#   coderdemo.io                         rhsummit.coderdemo.io
#
# Pure DNS delegation — no IAM cross-account roles needed. Public resolvers
# walk parent → NS pointer → child zone's awsdns nameservers.
#
# Usage:
#   ./bootstrap-r53-delegation.sh \
#     --child-zone rhsummit.coderdemo.io \
#     --child-profile sandbox \
#     [--parent-zone coderdemo.io] \
#     [--parent-profile parent]    # if omitted: prints the JSON change-batch
#                                  # for whoever owns the parent zone to run
#
# Behavior:
#   1. Look up or create the child hosted zone in --child-profile's account.
#   2. Capture the 4 NS values AWS auto-assigned to the child zone.
#   3. Render an UPSERT change-batch JSON for the parent zone.
#   4. If --parent-profile is set, apply the change directly. Otherwise,
#      print the file path so you can hand it to whoever owns the parent.
#   5. dig the new delegation against a public resolver to verify.
#
# Idempotent — re-running with the same flags is safe.
#
# Requires: aws CLI v2, jq, dig.

set -euo pipefail

###############################################################################
# Defaults + argument parsing
#
# Precedence: CLI flag > pre-existing env var (e.g., from `source .env`) >
# script default.
###############################################################################

CHILD_ZONE="${CHILD_ZONE:-rhsummit.coderdemo.io}"
CHILD_PROFILE="${CHILD_PROFILE:-}"
PARENT_ZONE="${PARENT_ZONE:-}"           # derived from CHILD_ZONE if not explicit
PARENT_PROFILE="${PARENT_PROFILE:-}"     # if empty, we only emit the JSON
NS_TTL="${NS_TTL:-300}"
RESOLVER="${RESOLVER:-8.8.8.8}"

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --child-zone)     CHILD_ZONE="$2"; shift 2 ;;
    --child-profile)  CHILD_PROFILE="$2"; shift 2 ;;
    --parent-zone)    PARENT_ZONE="$2"; shift 2 ;;
    --parent-profile) PARENT_PROFILE="$2"; shift 2 ;;
    --ns-ttl)         NS_TTL="$2"; shift 2 ;;
    --resolver)       RESOLVER="$2"; shift 2 ;;
    -h|--help)        usage 0 ;;
    *) echo "Unknown flag: $1" >&2; usage 1 ;;
  esac
done

if [[ -z "$CHILD_PROFILE" ]]; then
  echo "ERROR: --child-profile is required (the AWS profile for the child/sandbox account)." >&2
  exit 1
fi

# Default parent zone = child zone's parent label
if [[ -z "$PARENT_ZONE" ]]; then
  PARENT_ZONE="${CHILD_ZONE#*.}"
fi

# Trailing-dot variants for R53 / dig comparisons
CHILD_ZONE_DOT="${CHILD_ZONE%.}."
PARENT_ZONE_DOT="${PARENT_ZONE%.}."

OUT_DIR="${OUT_DIR:-/tmp/r53-delegation}"
mkdir -p "$OUT_DIR"
CHANGE_BATCH_FILE="$OUT_DIR/${CHILD_ZONE}-delegation.json"

echo "==========================================================="
echo "  Child zone:    $CHILD_ZONE  (account profile: $CHILD_PROFILE)"
echo "  Parent zone:   $PARENT_ZONE $([[ -n "$PARENT_PROFILE" ]] && echo "(account profile: $PARENT_PROFILE)" || echo "(no profile — JSON-only mode)")"
echo "  NS TTL:        ${NS_TTL}s"
echo "==========================================================="
echo

###############################################################################
# Pre-flight
###############################################################################

for bin in aws jq dig; do
  command -v "$bin" >/dev/null || { echo "ERROR: '$bin' not on PATH." >&2; exit 1; }
done

aws --profile "$CHILD_PROFILE" sts get-caller-identity \
  --query 'Account' --output text >/dev/null \
  || { echo "ERROR: 'aws --profile $CHILD_PROFILE sts get-caller-identity' failed." >&2; exit 1; }

if [[ -n "$PARENT_PROFILE" ]]; then
  aws --profile "$PARENT_PROFILE" sts get-caller-identity \
    --query 'Account' --output text >/dev/null \
    || { echo "ERROR: 'aws --profile $PARENT_PROFILE sts get-caller-identity' failed." >&2; exit 1; }
fi

###############################################################################
# Step 1 — find or create the child hosted zone
###############################################################################

echo "==> Looking up child zone $CHILD_ZONE in account $CHILD_PROFILE..."

CHILD_ZONE_ID="$(aws --profile "$CHILD_PROFILE" route53 list-hosted-zones-by-name \
  --dns-name "$CHILD_ZONE_DOT" --max-items 1 \
  --query "HostedZones[?Name=='$CHILD_ZONE_DOT' && !Config.PrivateZone].Id | [0]" \
  --output text 2>/dev/null || echo "None")"

if [[ "$CHILD_ZONE_ID" == "None" || -z "$CHILD_ZONE_ID" ]]; then
  echo "    not found — creating..."
  CHILD_ZONE_ID="$(aws --profile "$CHILD_PROFILE" route53 create-hosted-zone \
    --name "$CHILD_ZONE" \
    --caller-reference "bootstrap-$(date +%s)-$RANDOM" \
    --hosted-zone-config "Comment=Cluster zone for RH Summit demo,PrivateZone=false" \
    --query 'HostedZone.Id' --output text)"
  echo "    created: $CHILD_ZONE_ID"
else
  echo "    found existing: $CHILD_ZONE_ID"
fi

###############################################################################
# Step 2 — capture the 4 NS values AWS assigned to the child zone
###############################################################################

echo "==> Capturing NS values for child zone..."

# Portable read-loop instead of `mapfile` — macOS ships bash 3.2 by default,
# and `/usr/bin/env bash` picks that up unless you've installed a newer one.
NS_VALUES=()
while IFS= read -r line; do
  [ -n "$line" ] && NS_VALUES+=("$line")
done < <(aws --profile "$CHILD_PROFILE" route53 get-hosted-zone \
  --id "$CHILD_ZONE_ID" \
  --query 'DelegationSet.NameServers[]' --output text | tr '\t' '\n')

if (( ${#NS_VALUES[@]} != 4 )); then
  echo "ERROR: expected 4 NS values, got ${#NS_VALUES[@]}" >&2
  printf '  %s\n' "${NS_VALUES[@]}" >&2
  exit 1
fi

printf '    %s\n' "${NS_VALUES[@]}"

###############################################################################
# Step 3 — render the parent UPSERT change-batch JSON
###############################################################################

echo "==> Rendering change-batch JSON: $CHANGE_BATCH_FILE"

NS_RR_JSON="$(printf '"%s."\n' "${NS_VALUES[@]}" \
  | jq -Rs --arg name "$CHILD_ZONE_DOT" --argjson ttl "$NS_TTL" \
      'split("\n")|map(select(length>0)|fromjson)|map({Value:.})|
       {Comment:"Subdomain delegation for \($name)",
        Changes:[{Action:"UPSERT",ResourceRecordSet:{Name:$name,Type:"NS",TTL:$ttl,ResourceRecords:.}}]}')"

echo "$NS_RR_JSON" > "$CHANGE_BATCH_FILE"
jq -e . "$CHANGE_BATCH_FILE" >/dev/null || { echo "ERROR: rendered JSON is invalid" >&2; exit 1; }

###############################################################################
# Step 4 — apply to parent (or hand off)
###############################################################################

if [[ -z "$PARENT_PROFILE" ]]; then
  cat <<EOF

==> Parent profile not provided — JSON-only mode.

Hand this off to whoever owns the parent zone $PARENT_ZONE :

  aws --profile <parent> route53 change-resource-record-sets \\
    --hosted-zone-id <zone-id-of-$PARENT_ZONE> \\
    --change-batch file://$CHANGE_BATCH_FILE

Once they apply it, re-run this script with --parent-profile <name> to
verify the delegation, or skip ahead to the dig check below manually:

  dig +short NS $CHILD_ZONE @$RESOLVER

EOF
  exit 0
fi

echo "==> Applying change to parent zone $PARENT_ZONE in account $PARENT_PROFILE..."

PARENT_ZONE_ID="$(aws --profile "$PARENT_PROFILE" route53 list-hosted-zones-by-name \
  --dns-name "$PARENT_ZONE_DOT" --max-items 1 \
  --query "HostedZones[?Name=='$PARENT_ZONE_DOT' && !Config.PrivateZone].Id | [0]" \
  --output text)"

if [[ "$PARENT_ZONE_ID" == "None" || -z "$PARENT_ZONE_ID" ]]; then
  echo "ERROR: parent zone $PARENT_ZONE not found in account $PARENT_PROFILE." >&2
  exit 1
fi

CHANGE_ID="$(aws --profile "$PARENT_PROFILE" route53 change-resource-record-sets \
  --hosted-zone-id "$PARENT_ZONE_ID" \
  --change-batch "file://$CHANGE_BATCH_FILE" \
  --query 'ChangeInfo.Id' --output text)"

echo "    submitted: $CHANGE_ID — waiting for INSYNC..."
aws --profile "$PARENT_PROFILE" route53 wait resource-record-sets-changed --id "$CHANGE_ID"
echo "    INSYNC"

###############################################################################
# Step 5 — verify with dig against a public resolver
###############################################################################

echo "==> Verifying delegation with dig (resolver: $RESOLVER)..."
echo

# A few seconds for global edge resolvers to pick it up
for i in $(seq 1 12); do
  RESOLVED="$(dig +short NS "$CHILD_ZONE" @"$RESOLVER" | sort)"
  if [[ -n "$RESOLVED" ]]; then
    break
  fi
  printf '    waiting for public resolver (%d/12)...\n' "$i"
  sleep 5
done

EXPECTED="$(printf '%s.\n' "${NS_VALUES[@]}" | sort)"

if [[ "$RESOLVED" == "$EXPECTED" ]]; then
  echo "    ✅ delegation OK — $CHILD_ZONE NS resolves to:"
  printf '       %s\n' "${NS_VALUES[@]}"
else
  echo "    ⚠ resolver returned different/empty NS — DNS may still be propagating." >&2
  echo "    expected:" >&2
  printf '       %s.\n' "${NS_VALUES[@]}" | sort >&2
  echo "    got:" >&2
  echo "$RESOLVED" | sed 's/^/       /' >&2
  echo "    Re-run dig in a minute:  dig +short NS $CHILD_ZONE @$RESOLVER"
  exit 2
fi

cat <<EOF

==========================================================
Delegation complete.

Set the cluster Terraform's base_domain to:
   base_domain = "$CHILD_ZONE"

OCP IPI install will write A records into the $CHILD_ZONE zone in
account $CHILD_PROFILE; cert-manager will do DNS-01 against the same
zone. No cross-account IAM is required.
==========================================================
EOF
