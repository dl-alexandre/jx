#!/usr/bin/env bash
#
# campaign_observe.sh
#
# Example observation loop for a jx campaign.
# This version was written for the OneBackend-v3 E14 campaign and is
# intentionally specific. Adapt for your own multi-host setup.
#
# It syncs canonical state, runs host-scoped dry-run ticks, and reports status.
# It never runs --apply.
#

set -euo pipefail

CAMPAIGN="${CAMPAIGN:-onebackend-v3-e14}"
REPO="${REPO:-MILCGroup/OneBackend-v3}"
SYNC_SCRIPT="${SYNC_SCRIPT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/campaign_sync.sh}"
PR_STATUS_SCRIPT="${PR_STATUS_SCRIPT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/campaign_pr_status.sh}"

RUNNABLE_TARGETS=(
  "testserver:testserver:/Users/developer/OneBackend-v3"
  "milcmini:milcmini:/Users/milc/Documents/GitHub/OneBackend-v3"
  "optiplex-xe2-local:optiplex-xe2-local:/home/milc/Work/OneBackend-v3"
  "uitestserver:uitestserver:/home/developer/OneBackend-v3"
)

CANONICAL_HOST="uitestserver"
CANONICAL_ROOT="/home/developer/OneBackend-v3"
CANONICAL_JSON="$CANONICAL_ROOT/.jx/campaigns/$CAMPAIGN.json"
JX_BIN="${JX_BIN:-/tmp/jx-campaign-pass1/bin/jx}"

ONLY_HOST=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [--only <host>] [--campaign <name>]

Runs the safe observation path:
  1. campaign_sync.sh status
  2. campaign_pr_status.sh
  3. campaign_sync.sh push --dry-run
  4. host-scoped jx campaign tick --dry-run on runnable hosts
  5. canonical jx campaign status/events

This script never runs tick --apply.
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

target_root_for() {
  local want="$1"
  local entry
  for entry in "${RUNNABLE_TARGETS[@]}"; do
    local label="${entry%%:*}"
    local rest="${entry#*:}"
    local host="${rest%%:*}"
    local root="${rest#*:}"

    if [[ "$label" == "$want" || "$host" == "$want" ]]; then
      printf '%s:%s\n' "$host" "$root"
      return 0
    fi
  done
  return 1
}

run_remote_tick() {
  local label="$1"
  local host="$2"
  local root="$3"

  log "tick dry-run → $label ($host, root=$root)"
  ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$host" \
    "'$JX_BIN' campaign tick '$CAMPAIGN' --dry-run --repo '$REPO' --repo-root '$root' --root '$root' --host-id '$label'"
}

run_scope_check() {
  log "canonical scope check"
  ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$CANONICAL_HOST" \
    "python3 - '$CANONICAL_JSON' <<'PY'
import json
import sys

with open(sys.argv[1], 'r', encoding='utf-8') as f:
    state = json.load(f)

slots = state.get('slots', [])
current = [slot for slot in slots if slot.get('status') != 'advanced']
issues = state.get('issues', [])
parallelism = state.get('parallelism')

print(f\"scope: issues={len(issues)} total_slots={len(slots)} current_lanes={len(current)} parallelism={parallelism}\")
if len(issues) <= len(current):
    print(\"scope_warning: issue cursor is no larger than current lanes; expand issues before tick --apply if this campaign continues beyond the seed lanes\")
PY"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --only) ONLY_HOST="${2:-}"; shift 2 ;;
      --campaign) CAMPAIGN="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
}

main() {
  parse_args "$@"
  CANONICAL_JSON="$CANONICAL_ROOT/.jx/campaigns/$CAMPAIGN.json"

  [[ -x "$SYNC_SCRIPT" ]] || die "sync script not executable: $SYNC_SCRIPT"
  [[ -x "$PR_STATUS_SCRIPT" ]] || die "PR status script not executable: $PR_STATUS_SCRIPT"

  log "campaign observation start: $CAMPAIGN"
  "$SYNC_SCRIPT" --campaign "$CAMPAIGN" status
  run_scope_check
  log "campaign PR status"
  "$PR_STATUS_SCRIPT" --campaign "$CAMPAIGN" --repo "$REPO"
  "$SYNC_SCRIPT" --campaign "$CAMPAIGN" push --dry-run

  if [[ -n "$ONLY_HOST" ]]; then
    local resolved
    resolved=$(target_root_for "$ONLY_HOST") || die "unknown runnable host: $ONLY_HOST"
    run_remote_tick "$ONLY_HOST" "${resolved%%:*}" "${resolved#*:}"
  else
    local entry
    for entry in "${RUNNABLE_TARGETS[@]}"; do
      local label="${entry%%:*}"
      local rest="${entry#*:}"
      local host="${rest%%:*}"
      local root="${rest#*:}"
      run_remote_tick "$label" "$host" "$root"
    done
  fi

  log "canonical status"
  ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$CANONICAL_HOST" \
    "'$JX_BIN' campaign status '$CAMPAIGN' --root '$CANONICAL_ROOT'"

  log "canonical events"
  ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$CANONICAL_HOST" \
    "'$JX_BIN' campaign events '$CAMPAIGN' --root '$CANONICAL_ROOT'"

  log "campaign observation complete"
}

main "$@"
