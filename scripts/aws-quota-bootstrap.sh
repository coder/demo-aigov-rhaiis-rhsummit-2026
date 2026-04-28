#!/usr/bin/env bash
#
# aws-quota-bootstrap.sh
#
# Plan AWS Service Quotas for an OpenShift IPI cluster of a given shape:
# read the account's CURRENT IN-USE counts, compare against (in-use + demo
# need + margin) vs the quota limit, optionally file increase requests,
# and track pending requests through to APPROVED / DENIED / CASE_CLOSED.
#
# Complements terraform/prereqs/main.tf — designed for the tight loop of
# "what do I have left, what does the demo add, how much margin is wise"
# that Terraform's plan-time precondition checks don't surface clearly.
#
# Usage:
#   ./aws-quota-bootstrap.sh [flags] <command>
#
# Commands:
#   check      Compute usage / need / margin vs quota; print table.
#              Exit 0 if every line is OK; non-zero if any is SHORT.
#   request    Run check, then file an increase request for each SHORT
#              row, sized to (in_use + need + margin). Records request
#              IDs to the tracker file.
#   status     Show status (PENDING / CASE_OPENED / APPROVED / DENIED /
#              CASE_CLOSED) of every request in the tracker file.
#   wait       Like status, but loops until every tracked request reaches
#              a terminal state or --timeout-minutes elapses.
#
# Flags (most may be set via env or .env):
#   --aws-profile NAME              AWS CLI profile (env AWS_PROFILE)
#   --aws-region REGION             env AWS_REGION (default us-east-1)
#   --control-plane-count N         default 3
#   --control-plane-instance-type T default m6i.xlarge
#   --worker-count N                default 3
#   --worker-instance-type T        default m6i.2xlarge
#   --vcpu-buffer N                 vCPU margin (default 12)
#   --eip-margin N                  EIP margin (default 2 — ELBs created
#                                   during IPI install can briefly hold
#                                   extra EIPs)
#   --with-gpu                      add a GPU node to the demo's needs
#                                   (default off; flag turns on)
#   --gpu-instance-type T           GPU instance type (default g5.2xlarge)
#   --gpu-count N                   GPU node count (default 1, only used
#                                   when --with-gpu is set)
#   --tracker-file PATH             default ~/.aws-quota-bootstrap.json
#   --timeout-minutes N             for `wait` command (default 60)
#   --poll-seconds N                for `wait` command (default 60)
#   -h, --help                      show this help and exit
#
# Architecture inputs map 1:1 to terraform/variables.tf so this script and
# the cluster TF compute identical needs from the same numbers.
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
EIP_MARGIN="${EIP_MARGIN:-2}"
WITH_GPU="${WITH_GPU:-false}"
GPU_INSTANCE_TYPE="${GPU_INSTANCE_TYPE:-g5.2xlarge}"
GPU_COUNT="${GPU_COUNT:-1}"
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
    --eip-margin)                   EIP_MARGIN="$2"; shift 2 ;;
    --with-gpu)                     WITH_GPU="true"; shift ;;
    --gpu-instance-type)            GPU_INSTANCE_TYPE="$2"; shift 2 ;;
    --gpu-count)                    GPU_COUNT="$2"; shift 2 ;;
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
# vCPU per instance type
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
    g4dn.xlarge)  echo 4 ;;
    g4dn.2xlarge) echo 8 ;;
    g4dn.4xlarge) echo 16 ;;
    g5.xlarge)    echo 4 ;;
    g5.2xlarge)   echo 8 ;;
    g5.4xlarge)   echo 16 ;;
    g5.8xlarge)   echo 32 ;;
    *) echo 8 ;;  # safe default if a type isn't in this table yet
  esac
}

CP_VCPUS_PER_NODE="$(vcpus_for "$CONTROL_PLANE_INSTANCE_TYPE")"
WORKER_VCPUS_PER_NODE="$(vcpus_for "$WORKER_INSTANCE_TYPE")"
GPU_VCPUS_PER_NODE="$(vcpus_for "$GPU_INSTANCE_TYPE")"
BOOTSTRAP_VCPUS="$CP_VCPUS_PER_NODE"

REQUIRED_STD_VCPUS=$(( CONTROL_PLANE_COUNT * CP_VCPUS_PER_NODE \
                     + WORKER_COUNT       * WORKER_VCPUS_PER_NODE \
                     + BOOTSTRAP_VCPUS ))

if [ "$WITH_GPU" = "true" ]; then
  REQUIRED_GPU_VCPUS=$(( GPU_COUNT * GPU_VCPUS_PER_NODE ))
else
  REQUIRED_GPU_VCPUS=0
fi

###############################################################################
# Quota table — service|quota_code|name|need|margin|usage_func
###############################################################################

QUOTAS=(
  "ec2|L-1216C47A|EC2 vCPUs (Standard On-Demand)|$REQUIRED_STD_VCPUS|$VCPU_BUFFER|standard_vcpu"
  "ec2|L-DB2E81BA|EC2 vCPUs (G and VT - GPU)|$REQUIRED_GPU_VCPUS|0|gpu_vcpu"
  "ec2|L-0263D0A3|EC2 Elastic IPs|5|$EIP_MARGIN|eips"
  "vpc|L-F678F1CE|VPCs per Region|1|0|vpcs"
  "vpc|L-A4707A72|Internet gateways per Region|1|0|igws"
  "vpc|L-FE5A380F|NAT gateways per AZ|1|0|nat_per_az"
  "route53|L-ACB674F3|Route 53 hosted zones|1|0|hosted_zones"
)

###############################################################################
# Helpers — AWS calls
###############################################################################

aws_sq() {
  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" service-quotas "$@"
}
aws_sq_global() {
  aws --profile "$AWS_PROFILE" --region us-east-1 service-quotas "$@"
}
aws_ec2() {
  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" ec2 "$@"
}

is_global_service() { [ "$1" = "route53" ]; }

get_current_quota() {
  local svc="$1" quota="$2"
  if is_global_service "$svc"; then
    aws_sq_global get-service-quota --service-code "$svc" --quota-code "$quota" \
      --query 'Quota.Value' --output text 2>/dev/null \
      || aws_sq_global get-aws-default-service-quota --service-code "$svc" --quota-code "$quota" \
        --query 'Quota.Value' --output text 2>/dev/null
  else
    aws_sq get-service-quota --service-code "$svc" --quota-code "$quota" \
      --query 'Quota.Value' --output text 2>/dev/null \
      || aws_sq get-aws-default-service-quota --service-code "$svc" --quota-code "$quota" \
        --query 'Quota.Value' --output text 2>/dev/null
  fi
}

latest_request_for_quota() {
  local svc="$1" quota="$2"
  if is_global_service "$svc"; then
    aws_sq_global list-requested-service-quota-change-history-by-quota \
      --service-code "$svc" --quota-code "$quota" \
      --query 'RequestedQuotas | sort_by(@, &Created) | [-1].{Id:Id, Status:Status, DesiredValue:DesiredValue, Created:Created}' \
      --output json 2>/dev/null || echo '{}'
  else
    aws_sq list-requested-service-quota-change-history-by-quota \
      --service-code "$svc" --quota-code "$quota" \
      --query 'RequestedQuotas | sort_by(@, &Created) | [-1].{Id:Id, Status:Status, DesiredValue:DesiredValue, Created:Created}' \
      --output json 2>/dev/null || echo '{}'
  fi
}

request_increase() {
  local svc="$1" quota="$2" desired="$3"
  if is_global_service "$svc"; then
    aws_sq_global request-service-quota-increase \
      --service-code "$svc" --quota-code "$quota" --desired-value "$desired" \
      --query 'RequestedQuota.Id' --output text 2>/dev/null
  else
    aws_sq request-service-quota-increase \
      --service-code "$svc" --quota-code "$quota" --desired-value "$desired" \
      --query 'RequestedQuota.Id' --output text 2>/dev/null
  fi
}

###############################################################################
# Usage detection — one function per quota
#
# Return current in-use count as a single integer on stdout.
# Errors are silenced; on failure return 0 (best-effort, fail-open so the
# script doesn't hard-crash when the principal can't read a particular
# resource — the table will just under-count usage there).
###############################################################################

# Sum vCPU of running, on-demand (NOT spot), Standard-family instances.
# Standard families per L-1216C47A: A, C, D, H, I, M, R, T, Z prefix.
get_usage_standard_vcpu() {
  local total=0 itype vcpus
  while IFS= read -r itype; do
    [ -z "$itype" ] && continue
    case "$itype" in
      [acdhimrtzACDHIMRTZ]*) ;;
      *) continue ;;
    esac
    vcpus="$(vcpus_for "$itype")"
    total=$(( total + vcpus ))
  done < <(aws_ec2 describe-instances \
    --filters "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[?InstanceLifecycle != `spot`].InstanceType' \
    --output text 2>/dev/null | tr '\t' '\n')
  echo "$total"
}

# Sum vCPU of running, on-demand, G/VT family instances (the GPU quota).
get_usage_gpu_vcpu() {
  local total=0 itype vcpus
  while IFS= read -r itype; do
    [ -z "$itype" ] && continue
    case "$itype" in
      g[0-9]*|vt[0-9]*|G[0-9]*|VT[0-9]*) ;;
      *) continue ;;
    esac
    vcpus="$(vcpus_for "$itype")"
    total=$(( total + vcpus ))
  done < <(aws_ec2 describe-instances \
    --filters "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[?InstanceLifecycle != `spot`].InstanceType' \
    --output text 2>/dev/null | tr '\t' '\n')
  echo "$total"
}

get_usage_eips() {
  aws_ec2 describe-addresses --query 'length(Addresses)' --output text 2>/dev/null || echo 0
}

get_usage_vpcs() {
  aws_ec2 describe-vpcs --query 'length(Vpcs)' --output text 2>/dev/null || echo 0
}

get_usage_igws() {
  aws_ec2 describe-internet-gateways --query 'length(InternetGateways)' --output text 2>/dev/null || echo 0
}

# Conservative: total NAT GWs (≥ max per AZ). Quota dimension is per-AZ;
# if you have 1 NAT GW per AZ across 3 AZs, the per-AZ usage is 1.
# Reporting total here over-states usage in the worst case but is
# correct for the most common single-cluster sandbox.
get_usage_nat_per_az() {
  local subs az_counts max
  subs=$(aws_ec2 describe-nat-gateways \
    --filter "Name=state,Values=available,pending" \
    --query 'NatGateways[].SubnetId' --output text 2>/dev/null | tr '\t' '\n' | sort -u | grep -v '^$' || true)
  if [ -z "$subs" ]; then echo 0; return; fi

  # Map each NAT-gateway subnet to its AZ, then count NAT GWs per AZ.
  local nat_subnets nat_azs
  nat_subnets=$(aws_ec2 describe-nat-gateways \
    --filter "Name=state,Values=available,pending" \
    --query 'NatGateways[].SubnetId' --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true)
  nat_azs=$(aws_ec2 describe-subnets --subnet-ids $subs \
    --query 'Subnets[].[SubnetId,AvailabilityZone]' --output text 2>/dev/null || true)

  if [ -z "$nat_azs" ]; then echo 0; return; fi

  max=$(echo "$nat_subnets" | while IFS= read -r sid; do
    [ -z "$sid" ] && continue
    echo "$nat_azs" | awk -v s="$sid" '$1==s {print $2}'
  done | sort | uniq -c | awk '{print $1}' | sort -rn | head -1)
  echo "${max:-0}"
}

get_usage_hosted_zones() {
  aws --profile "$AWS_PROFILE" route53 list-hosted-zones \
    --query 'length(HostedZones)' --output text 2>/dev/null || echo 0
}

###############################################################################
# Tracker file
###############################################################################

ensure_tracker() { [ -f "$TRACKER_FILE" ] || echo '{}' > "$TRACKER_FILE"; }
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
  printf '\n=== AWS Service Quota plan ===\n'
  printf '  Account profile : %s\n' "$AWS_PROFILE"
  printf '  Region          : %s\n' "$AWS_REGION"
  printf '  CP nodes        : %d × %s (%d vCPU each)\n' \
    "$CONTROL_PLANE_COUNT" "$CONTROL_PLANE_INSTANCE_TYPE" "$CP_VCPUS_PER_NODE"
  printf '  Worker nodes    : %d × %s (%d vCPU each)\n' \
    "$WORKER_COUNT" "$WORKER_INSTANCE_TYPE" "$WORKER_VCPUS_PER_NODE"
  printf '  Bootstrap       : %d vCPU (transient, install-time only)\n' \
    "$BOOTSTRAP_VCPUS"
  printf '  vCPU buffer     : %d (added as Margin on the std-vCPU row)\n' "$VCPU_BUFFER"
  printf '  Required (std)  : %d vCPU\n' "$REQUIRED_STD_VCPUS"
  if [ "$WITH_GPU" = "true" ]; then
    printf '  GPU node(s)     : %d × %s (%d vCPU each, total %d)\n' \
      "$GPU_COUNT" "$GPU_INSTANCE_TYPE" "$GPU_VCPUS_PER_NODE" "$REQUIRED_GPU_VCPUS"
  else
    printf '  GPU             : disabled (re-run with --with-gpu to add a GPU node)\n'
  fi
  printf '\n  %-38s  %5s  %6s  %5s  %6s  %6s  %6s  %s\n' \
    "Quota" "Limit" "In use" "Need" "Margin" "Total" "Avail" "Status"
  printf '  %-38s  %5s  %6s  %5s  %6s  %6s  %6s  %s\n' \
    "--------------------------------------" "-----" "------" "-----" "------" "------" "------" "------"
}

###############################################################################
# Commands
###############################################################################

cmd_check() {
  print_header
  local shortfall=0
  for entry in "${QUOTAS[@]}"; do
    IFS='|' read -r svc quota name need margin usage_fn <<<"$entry"

    local limit
    limit="$(get_current_quota "$svc" "$quota" 2>/dev/null || echo 0)"
    limit="${limit%.*}"

    local in_use
    in_use="$(get_usage_${usage_fn} 2>/dev/null || echo 0)"
    in_use="${in_use%.*}"

    local total=$(( in_use + need + margin ))
    local avail=$(( limit - total ))
    local mark="OK"
    if (( avail < 0 )); then mark="SHORT"; shortfall=$(( shortfall + 1 )); fi

    printf '  %-38s  %5d  %6d  %5d  %6d  %6d  %6d  %s\n' \
      "$name" "$limit" "$in_use" "$need" "$margin" "$total" "$avail" "$mark"
  done
  echo
  if (( shortfall > 0 )); then
    echo "  ${shortfall} quota(s) below required (Avail < 0)."
    echo "  Run with 'request' to file increases sized to (in_use + need + margin)."
    return 1
  fi
  echo "  All quotas satisfied with margin."
}

cmd_request() {
  print_header
  ensure_tracker
  local filed=0 already=0
  for entry in "${QUOTAS[@]}"; do
    IFS='|' read -r svc quota name need margin usage_fn <<<"$entry"

    local limit in_use total avail
    limit="$(get_current_quota "$svc" "$quota" 2>/dev/null || echo 0)";  limit="${limit%.*}"
    in_use="$(get_usage_${usage_fn} 2>/dev/null || echo 0)";              in_use="${in_use%.*}"
    total=$(( in_use + need + margin ))
    avail=$(( limit - total ))

    if (( avail >= 0 )); then
      printf '  %-38s  %5d  %6d  %5d  %6d  %6d  %6d  OK\n' \
        "$name" "$limit" "$in_use" "$need" "$margin" "$total" "$avail"
      continue
    fi

    # Already an open request at >= the value we'd ask for?
    local latest existing_id existing_desired existing_status
    latest="$(latest_request_for_quota "$svc" "$quota")"
    existing_id="$(jq -r '.Id // empty' <<<"$latest")"
    existing_status="$(jq -r '.Status // empty' <<<"$latest")"
    existing_desired="$(jq -r '.DesiredValue // 0 | tonumber | floor' <<<"$latest")"

    if [ -n "$existing_id" ] \
       && echo "$existing_status" | grep -qE '^(PENDING|CASE_OPENED)$' \
       && (( existing_desired >= total )); then
      printf '  %-38s  %5d  %6d  %5d  %6d  %6d  %6d  PENDING (req %s)\n' \
        "$name" "$limit" "$in_use" "$need" "$margin" "$total" "$avail" "$existing_id"
      tracker_record "$svc/$quota" "$existing_id" "$existing_desired"
      already=$(( already + 1 ))
      continue
    fi

    local req_id
    req_id="$(request_increase "$svc" "$quota" "$total" || true)"
    if [ -n "$req_id" ] && [ "$req_id" != "None" ]; then
      tracker_record "$svc/$quota" "$req_id" "$total"
      printf '  %-38s  %5d  %6d  %5d  %6d  %6d  %6d  FILED (req %s, desired=%d)\n' \
        "$name" "$limit" "$in_use" "$need" "$margin" "$total" "$avail" "$req_id" "$total"
      filed=$(( filed + 1 ))
    else
      printf '  %-38s  %5d  %6d  %5d  %6d  %6d  %6d  ERROR (request failed)\n' \
        "$name" "$limit" "$in_use" "$need" "$margin" "$total" "$avail"
    fi
  done
  echo
  echo "  Filed ${filed} new; ${already} already in flight. Tracker: $TRACKER_FILE"
}

cmd_status() {
  ensure_tracker
  local count
  count="$(jq 'length' "$TRACKER_FILE")"
  if [ "$count" = "0" ]; then
    echo "No tracked requests in $TRACKER_FILE."
    return 0
  fi
  printf '\n=== Tracked requests (%s) ===\n\n' "$count"
  printf '  %-38s  %-26s  %-12s  %s\n' "Quota" "Request ID" "Status" "Desired"
  printf '  %-38s  %-26s  %-12s  %s\n' "--------------------------------------" "--------------------------" "------------" "-------"

  local all_done=1
  while IFS= read -r entry; do
    local key svc quota req_id desired latest status latest_desired name
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

    name="$svc/$quota"
    for q in "${QUOTAS[@]}"; do
      IFS='|' read -r s c n _ <<<"$q"
      if [ "$s" = "$svc" ] && [ "$c" = "$quota" ]; then name="$n"; fi
    done

    printf '  %-38s  %-26s  %-12s  %s\n' "$name" "$req_id" "$status" "$latest_desired"
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
    if cmd_status; then return 0; fi
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
