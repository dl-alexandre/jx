#!/usr/bin/env bash
#
# Show open GitHub PRs whose head branch matches the current non-advanced
# campaign lanes in the canonical file-backed campaign state.
#

CAMPAIGN="${CAMPAIGN:-onebackend-v3-e14}"
REPO="${REPO:-MILCGroup/OneBackend-v3}"
CANONICAL_HOST="${CANONICAL_HOST:-uitestserver}"
CANONICAL_ROOT="${CANONICAL_ROOT:-/home/developer/OneBackend-v3}"
CANONICAL_PATH=""

set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --campaign <name>      Campaign name (default: onebackend-v3-e14)
  --repo <owner/repo>    GitHub repository (default: MILCGroup/OneBackend-v3)
  --canonical-host <h>   Canonical SSH host (default: uitestserver)
  --canonical-root <p>   Canonical repo root (default: /home/developer/OneBackend-v3)
  -h, --help             This help
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --campaign) CAMPAIGN="${2:-}"; shift 2 ;;
      --repo) REPO="${2:-}"; shift 2 ;;
      --canonical-host) CANONICAL_HOST="${2:-}"; shift 2 ;;
      --canonical-root) CANONICAL_ROOT="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
}

main() {
  parse_args "$@"
  CANONICAL_PATH="${CANONICAL_ROOT}/.jx/campaigns/${CAMPAIGN}.json"

  local state prs
  state=$(mktemp "${TMPDIR:-/tmp}/campaign-pr-state.XXXXXX")
  prs=$(mktemp "${TMPDIR:-/tmp}/campaign-pr-gh.XXXXXX")

  scp -q -o BatchMode=yes -o ConnectTimeout=10 "$CANONICAL_HOST:$CANONICAL_PATH" "$state" ||
    die "failed to copy canonical from $CANONICAL_HOST:$CANONICAL_PATH"

  env NO_COLOR=1 CLICOLOR=0 CLICOLOR_FORCE=0 gh pr list --repo "$REPO" --state open --limit 200 \
    --json number,url,headRefName,title,isDraft,baseRefName >"$prs"

  python3 - "$state" "$prs" <<'PY'
import json
import sys

state_path, prs_path = sys.argv[1:3]
state = json.load(open(state_path, "r", encoding="utf-8"))
prs = json.load(open(prs_path, "r", encoding="utf-8"))

current = [
    slot for slot in state.get("slots", [])
    if slot.get("status") != "advanced"
]
branches = {slot.get("branch"): slot for slot in current if slot.get("branch")}
matches = [
    pr for pr in prs
    if pr.get("headRefName") in branches
]

print(f"campaign: {state.get('name')}")
print(f"current_lanes: {len(current)}")
print(f"open_current_lane_prs: {len(matches)}")

for pr in sorted(matches, key=lambda item: item.get("headRefName") or ""):
    slot = branches[pr.get("headRefName")]
    draft = "draft" if pr.get("isDraft") else "ready"
    print(
        "pr "
        f"slot={slot.get('slot_index')} "
        f"host={slot.get('host_id')} "
        f"issue={slot.get('issue_number')} "
        f"branch={pr.get('headRefName')} "
        f"number={pr.get('number')} "
        f"state={draft} "
        f"url={pr.get('url')} "
        f"title={pr.get('title')}"
    )
PY

  rm -f "$state" "$prs"
}

main "$@"
