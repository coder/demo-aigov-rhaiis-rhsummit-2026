#!/usr/bin/env bash
#
# aws-quota-bootstrap.sh
#
# Compute the AWS Service Quotas needed for an OpenShift IPI cluster of a
# given shape, compare against the account's current limits in the target
# region, optionally file increase requests, and track pending requests
# through to APPROVED / DENIED / CASE_CLOSED.
#
# Complements terraform/prereqs/main.tf (which does compute+request inline)
# by giving you a tight loop for the request → wait → re-check phase that
# Terraform isn't well suited to.
#
# Usage:
#   ./aws-quota-bootstrap.sh [flags] <command>
#
# Commands:
#   check      Compute needed vs current; print table; exit 0 if all OK,
#              non-zero if any shortfall. (default)
#   request    Run check, then file an increase request for each shortfall.
#              Records request IDs to the tracker file.
#   status     Show status (PENDING / CASE_OPENED / APPROVED / DENIED /
#              CASE_CLOSED) of every request in the tracker file plus any
#              other pending requests AWS shows for these quotas.
#   wait       Like status, but loops until every tracked request reaches
#              a terminal state (APPROVED / DENIED / CASE_CLOSED) or
#              --timeout-minutes elapses.
#
# Flags (all may be set via env or .env — see .env.example):
#   --aws-profile NAME              AWS CLI profile (defaults to env AWS_PROFILE)
#   --aws-region REGION             defaults to env AWS_REGION or us-east-1
#   --control-plane-count N         default 3
#   --control-plane-instance-type T default m6i.xlarge
#   --worker-count N                default 3
#   --worker-instance-type T        default m6i.2xlarge
#   --vcpu-buffer N                 spare vCPU on top of computed need (default 12)
#   --tracker-file PATH             default ~/.aws-quota-bootstrap.json
#   --timeout-minutes N             for `wait` command, default 60
#   --poll-seconds N                for `wait` command, default 60
#   -h, --help                      show this help and exit
#
# Architecture inputs map 1:1 to terraform/variables.tf so this script and
# the cluster TF are computing identical needs from the same numbers.
#
# Requires: aws CLI v2, jq.

set -euo pipefail

###############################################################################
# Defaults — overridable by env vars (e.g., from `source .env`) or flags
###############################################################################

AWS_PROFILE="${AWS_PROFILE:-default}"
AWS_REGION="${AWS_REGION:-us-east-1}"
CONTROL_PLANE_COUNT="${TF_VAR_control_plane_count:-3}"
CONTROL_PLANE_INSTANCE_TYPE="${TF_VAR_control_plane_instance_type:-m6i.xlarge}"
WORKER_COUNT="${TF_VAR_worker_count:-3}"
WORKER_INSTANCE_TYPE="${TF_VAR_worker_instance_type:-m6i.2xlarge}"
VCPU_BUFFER="${VCPU_BUFFER:-12}"
TRACKER_FILE="${TRACKER_FILE:-$HOME/.aws-quota-bootstrap.json}"
TIMEOUT_MINUTES="${TIMEOUT_MINUTES:-60}"
POLL_SECONDS="${POLL_SECONDS:-60}"

CMD="check"

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --aws-profile)                  AWS_PROFILE="$2"; shift 2 ;;
    --aws-region)                   AWS_REGION="$2"; shift 2 ;;
    --control-plane-count)          CONTROL_PLANE_COUNT="$2"; shift 2 ;;
    --control-plane-instance-type)  CONTROL_PLANE_INSTANCE_TYPE="$2"; shift 2 ;;
    --worker-count)                 WORKER_COUNT="$2"; shift 2 ;;
    --worker-instance-type)         WORKER_INSTANCE_TYPE="$2"; shift 2 ;;
    --vcpu-buffer)                  VCPU_BUFFER="$2"; shift 2 ;;
    --tracker-file)                 TRACKER_FILE="$2"; shift 2 ;;
    --timeout-minutes)              TIMEOUT_MINUTES="$2"; shift 2 ;;
    --poll-seconds)                 POLL_SECONDS="$2"; shift 2 ;;
    -h|--help)                      usage 0 ;;
    check|request|status|wait)      CMD="$1"; shift ;;
    *) echo "Unknown arg: $1" >&2; usage 1 ;;
  esac
done

for bin in aws jq; do
  command -v "$bin" >/dev/null \
    || { echo "ERROR: '$bin' not on PATH." >&2; exit 1; }
done

###############################################################################
# vCPU per instance type (mirrors terraform/prereqs/main.tf locals.vcpu_per_type)
###############################################################################

vcpus_for() {
  case "$1" in
    m6i.large)   echo 2  ;;
    m6i.xlarge)  echo 4  ;;
    m6i.2xlarge) echo 8  ;;
    m6i.4xlarge) echo 16 ;;
    m6i.8xlarge) echo 32 ;;
    m5.large)    echo 2  ;;
    m5.xlarge)   echo 4  ;;
    m5.2xlarge)  echo 8  ;;
    m5.4xlarge)  echo 16 ;;
    c6i.xlarge)  echo 4  ;;
    c6i.2xlarge) echo 8  ;;
    r6i.xlarge)  echo 4  ;;
    r6i.2xlarge) echo 8  ;;
    *)
      echo "WARN: unknown instance type '$1' — defaulting to 8 vCPU. Add it to vcpus_for() if it's actually different." >&2
      echo 8
      ;;
  esac
}

CP_VCPUS_PER_NODE="$(vcpus_for "$CONTROL_PLANE_INSTANCE_TYPE")"
WORKER_VCPUS_PER_NODE="$(vcpus_for "$WORKER_INSTANCE_TYPE")"
BOOTSTRAP_VCPUS="$CP_VCPUS_PER_NODE"

REQUIRED_VCPUS=$(( CONTROL_PLANE_COUNT * CP_VCPUS_PER_NODE \
                 + WORKER_COUNT       * WORKER_VCPUS_PER_NODE \
                 + BOOTSTRAP_VCPUS \
                 + VCPU_BUFFER ))

###############################################################################
# Quotas table — service_code, quota_code, friendly name, required value
#
# Quota codes come from `aws service-quotas list-service-quotas`.
# OCP IPI on AWS (3 CP + 3 worker, multi-AZ BYO-VPC) needs all of these.
###############################################################################

QUOTAS=(
  "ec2|L-1216C47A|EC2 vCPUs (Standard On-Demand)|$REQUIRED_VCPUS"
  "ec2|L-0263D0A3|EC2 Elastic IPs|5"
  "vpc|L-F678F1CE|VPCs per Region|1"
  "vpc|L-A4707A72|Internet gateways per Region|1"
  "vpc|L-FE5A380F|NAT gateways per AZ|1"
  "route53|L-ACB674F3|Route 53 hosted zones|1"
)

###############################################################################
# Helpers — AWS calls
###############################################################################

aws_sq() {
  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" service-quotas "$@"
}
aws_sq_global() {
  # Some services (route53) are global — region must be us-east-1 for the SQ API.
  aws --profile "$AWS_PROFILE" --region us-east-1 service-quotas "$@"
}

is_global_service() { [[ "$1" == "route53" ]]; }

get_current_quota() {
  local svc="$1" quota="$2"
  local cmd=(aws_sq)
  is_global_service "$svc" && cmd=(aws_sq_global)
  "${cmd[@]}" get-service-quota \
    --service-code "$svc" --quota-code "$quota" \
    --query 'Quota.Value' --output text 2>/dev/null \
    || { "${cmd[@]}" get-aws-default-service-quota \
           --service-code "$svc" --quota-code "$quota" \
           --query 'Quota.Value' --output text 2>/dev/null; }
}

# Most recent open/closed request for a quota — empty if none.
latest_request_for_quota() {
  local svc="$1" quota="$2"
  local cmd=(aws_sq)
  is_global_service "$svc" && cmd=(aws_sq_global)
  "${cmd[@]}" list-requested-service-quota-change-history-by-quota \
    --service-code "$svc" --quota-code "$quota" \
    --query 'RequestedQuotas | sort_by(@, &Created) | [-1].{Id:Id, Status:Status, DesiredValue:DesiredValue, Created:Created}' \
    --output json 2>/dev/null || echo '{}'
}

# Submit an increase. Returns the request Id on success, empty on failure.
request_increase() {
  local svc="$1" quota="$2" desired="$3"
  local cmd=(aws_sq)
  is_global_service "$svc" && cmd=(aws_sq_global)
  "${cmd[@]}" request-service-quota-increase \
    --service-code "$svc" --quota-code "$quota" \
    --desired-value "$desired" \
    --query 'RequestedQuota.Id' --output text 2>/dev/null
}

###############################################################################
# Tracker file — JSON keyed by "<svc>/<quota>"
###############################################################################

ensure_tracker() { [[ -f "$TRACKER_FILE" ]] || echo '{}' > "$TRACKER_FILE"; }
tracker_record() {
  local key="$1" id="$2" desired="$3"
  ensure_tracker
  jq --arg k "$key" --arg id "$id" --arg d "$desired" \
     --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     '.[$k] = {request_id:$id, desired:($d|tonumber), submitted_at:$ts}' \
     "$TRACKER_FILE" > "$TRACKER_FILE.tmp" && mv "$TRACKER_FILE.tmp" "$TRACKER_FILE"
}

###############################################################################
# Pretty-print
###############################################################################

print_header() {
  printf '\n=== AWS Service Quota check ===\n'
  printf '  Account profile : %s\n' "$AWS_PROFILE"
  printf '  Region          : %s\n' "$AWS_REGION"
  printf '  CP nodes        : %d × %s (%d vCPU each)\n' \
    "$CONTROL_PLANE_COUNT" "$CONTROL_PLANE_INSTANCE_TYPE" "$CP_VCPUS_PER_NODE"
  printf '  Worker nodes    : %d × %s (%d vCPU each)\n' \
    "$WORKER_COUNT" "$WORKER_INSTANCE_TYPE" "$WORKER_VCPUS_PER_NODE"
  printf '  Bootstrap       : %d vCPU (transient, install-time only)\n' \
    "$BOOTSTRAP_VCPUS"
  printf '  Buffer          : %d vCPU\n' "$VCPU_BUFFER"
  printf '  Required vCPUs  : %d\n\n' "$REQUIRED_VCPUS"
  printf '  %-40s  %10s  %10s  %s\n' "Quota" "Current" "Needed" "Status"
  printf '  %-40s  %10s  %10s  %s\n' "----------------------------------------" "----------" "----------" "------"
}

###############################################################################
# Commands
###############################################################################

cmd_check() {
  print_header
  local shortfall=0
  for entry in "${QUOTAS[@]}"; do
    IFS='|' read -r svc quota name needed <<<"$entry"
    local current
    current="$(get_current_quota "$svc" "$quota" 2>/dev/null || echo 0)"
    current="${current%.*}"  # strip ".0" tails
    local mark="OK"
    if (( current < needed )); then mark="SHORT"; shortfall=$(( shortfall + 1 )); fi
    printf '  %-40s  %10s  %10s  %s\n' "$name" "$current" "$needed" "$mark"
  done
  echo
  if (( shortfall > 0 )); then
    echo "  ${shortfall} quota(s) below required. Run with 'request' to file increases."
    return 1
  fi
  echo "  All quotas satisfied."
}

cmd_request() {
  print_header
  ensure_tracker
  local filed=0 already=0
  for entry in "${QUOTAS[@]}"; do
    IFS='|' read -r svc quota name needed <<<"$entry"
    local current existing_id existing_desired existing_status
    current="$(get_current_quota "$svc" "$quota" 2>/dev/null || echo 0)"
    current="${current%.*}"
    if (( current >= needed )); then
      printf '  %-40s  %10s  %10s  %s\n' "$name" "$current" "$needed" "OK"
      continue
    fi

    # Check if there's already an open AWS-side request before re-filing
    local latest
    latest="$(latest_request_for_quota "$svc" "$quota")"
    existing_id="$(jq -r '.Id // empty' <<<"$latest")"
    existing_status="$(jq -r '.Status // empty' <<<"$latest")"
    existing_desired="$(jq -r '.DesiredValue // 0 | tonumber | floor' <<<"$latest")"

    if [[ -n "$existing_id" ]] \
       && [[ "$existing_status" =~ ^(PENDING|CASE_OPENED)$ ]] \
       && (( existing_desired >= needed )); then
      printf '  %-40s  %10s  %10s  PENDING (req %s, %s)\n' \
        "$name" "$current" "$needed" "$existing_id" "$existing_status"
      tracker_record "$svc/$quota" "$existing_id" "$existing_desired"
      already=$(( already + 1 ))
      continue
    fi

    local req_id
    req_id="$(request_increase "$svc" "$quota" "$needed" || true)"
    if [[ -n "$req_id" && "$req_id" != "None" ]]; then
      tracker_record "$svc/$quota" "$req_id" "$needed"
      printf '  %-40s  %10s  %10s  FILED  (req %s)\n' \
        "$name" "$current" "$needed" "$req_id"
      filed=$(( filed + 1 ))
    else
      printf '  %-40s  %10s  %10s  ERROR (request failed — see AWS console)\n' \
        "$name" "$current" "$needed"
    fi
  done
  echo
  echo "  Filed ${filed} new request(s); ${already} already in flight. Tracker: $TRACKER_FILE"
}

cmd_status() {
  ensure_tracker
  local count
  count="$(jq 'length' "$TRACKER_FILE")"
  if [[ "$count" == "0" ]]; then
    echo "No tracked requests in $TRACKER_FILE."
    return 0
  fi
  printf '\n=== Tracked requests (%s) ===\n\n' "$count"
  printf '  %-40s  %-26s  %-12s  %s\n' "Quota" "Request ID" "Status" "Desired"
  printf '  %-40s  %-26s  %-12s  %s\n' "----------------------------------------" "--------------------------" "------------" "-------"

  local all_done=1
  while IFS= read -r entry; do
    local key svc quota req_id desired latest status latest_desired
    key="$(jq -r '.key' <<<"$entry")"
    req_id="$(jq -r '.value.request_id' <<<"$entry")"
    desired="$(jq -r '.value.desired' <<<"$entry")"
    svc="${key%/*}"
    quota="${key#*/}"

    latest="$(latest_request_for_quota "$svc" "$quota")"
    status="$(jq -r '.Status // "UNKNOWN"' <<<"$latest")"
    latest_desired="$(jq -r '.DesiredValue // 0 | tonumber | floor' <<<"$latest")"

    case "$status" in
      APPROVED|DENIED|CASE_CLOSED) : ;;
      *) all_done=0 ;;
    esac

    # Look up friendly name
    local name="$svc/$quota"
    for q in "${QUOTAS[@]}"; do
      IFS='|' read -r s c n _ <<<"$q"
      if [[ "$s" == "$svc" && "$c" == "$quota" ]]; then name="$n"; fi
    done

    printf '  %-40s  %-26s  %-12s  %s\n' "$name" "$req_id" "$status" "$latest_desired"
  done < <(jq -c 'to_entries[]' "$TRACKER_FILE")

  echo
  if (( all_done )); then
    echo "  All tracked requests have reached a terminal state."
    return 0
  fi
  echo "  Some requests still in flight. Run 'wait' to poll until done."
  return 2
}

cmd_wait() {
  local deadline=$(( $(date +%s) + TIMEOUT_MINUTES * 60 ))
  while true; do
    if cmd_status; then
      return 0
    fi
    if (( $(date +%s) >= deadline )); then
      echo "  Timeout (${TIMEOUT_MINUTES} min) reached with requests still pending." >&2
      return 3
    fi
    echo "  Sleeping ${POLL_SECONDS}s before next poll..."
    sleep "$POLL_SECONDS"
  done
}

###############################################################################
# Dispatch
###############################################################################

case "$CMD" in
  check)   cmd_check ;;
  request) cmd_request ;;
  status)  cmd_status ;;
  wait)    cmd_wait ;;
  *) echo "Unknown command: $CMD" >&2; exit 1 ;;
esac
