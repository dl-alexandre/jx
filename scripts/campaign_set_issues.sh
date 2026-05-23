#!/usr/bin/env bash
#
# Update the configured issue sequence for a file-backed campaign JSON.
# This is for Pass 1 operations where the initial seeded lanes are only the
# active parallelism, not the whole campaign scope.
#

CAMPAIGN="${CAMPAIGN:-onebackend-v3-e14}"
CANONICAL_HOST="${CANONICAL_HOST:-uitestserver}"
CANONICAL_ROOT="${CANONICAL_ROOT:-/home/developer/OneBackend-v3}"
CANONICAL_PATH=""
ISSUES=""
DIRECTION="desc"
DRY_RUN=false

set -euo pipefail

configure_paths() {
  CANONICAL_PATH="${CANONICAL_ROOT}/.jx/campaigns/${CAMPAIGN}.json"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") --issues <range[,range...]> [options]

Options:
  --issues <spec>        Issue list, for example 1055..1153 or 1153..1055,1150
  --direction <dir>      desc or asc (default: desc)
  --campaign <name>      Campaign name (default: onebackend-v3-e14)
  --canonical-host <h>   Canonical SSH host (default: uitestserver)
  --canonical-root <p>   Canonical repo root (default: /home/developer/OneBackend-v3)
  --dry-run              Validate and show the change without writing
  -h, --help             This help

The script refuses to drop any issue that is already present in a slot.
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --issues) ISSUES="${2:-}"; shift 2 ;;
      --direction) DIRECTION="${2:-}"; shift 2 ;;
      --campaign) CAMPAIGN="${2:-}"; shift 2 ;;
      --canonical-host) CANONICAL_HOST="${2:-}"; shift 2 ;;
      --canonical-root) CANONICAL_ROOT="${2:-}"; shift 2 ;;
      --dry-run) DRY_RUN=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
}

main() {
  parse_args "$@"
  configure_paths

  [[ -n "$ISSUES" ]] || die "--issues is required"
  [[ "$DIRECTION" == "desc" || "$DIRECTION" == "asc" ]] || die "--direction must be desc or asc"

  local tmp updated
  tmp=$(mktemp "${TMPDIR:-/tmp}/campaign-issues-current.XXXXXX")
  updated=$(mktemp "${TMPDIR:-/tmp}/campaign-issues-updated.XXXXXX")

  scp -q -o BatchMode=yes -o ConnectTimeout=10 "$CANONICAL_HOST:$CANONICAL_PATH" "$tmp" ||
    die "failed to copy canonical from $CANONICAL_HOST:$CANONICAL_PATH"

  python3 - "$tmp" "$updated" "$CAMPAIGN" "$ISSUES" "$DIRECTION" <<'PY'
import json
import sys
from datetime import datetime, timezone

src, dest, campaign, spec, direction = sys.argv[1:6]

def parse_issue_part(part):
    part = part.strip()
    if not part:
        return []
    if ".." in part:
        first, last = part.split("..", 1)
        start = int(first.strip())
        finish = int(last.strip())
        step = 1 if start <= finish else -1
        return list(range(start, finish + step, step))
    return [int(part)]

issues = []
for part in spec.split(","):
    issues.extend(parse_issue_part(part))

issues = sorted(set(issues), reverse=(direction == "desc"))

with open(src, "r", encoding="utf-8") as f:
    state = json.load(f)

if state.get("name") != campaign:
    raise SystemExit(f"campaign mismatch: got {state.get('name')!r}, expected {campaign!r}")

slot_issues = sorted({
    slot.get("issue_number")
    for slot in state.get("slots", [])
    if isinstance(slot.get("issue_number"), int)
})
missing = [issue for issue in slot_issues if issue not in issues]
if missing:
    raise SystemExit(f"new issue list would drop assigned slot issues: {missing}")

old_issues = state.get("issues", [])
state["issues"] = issues
state["direction"] = direction
state["updated_at"] = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
state.setdefault("events", []).append({
    "type": "issues_updated",
    "at": state["updated_at"],
    "data": {
        "old_count": len(old_issues),
        "new_count": len(issues),
        "direction": direction,
        "first_issue": issues[0] if issues else None,
        "last_issue": issues[-1] if issues else None,
    },
})

print(f"old_count={len(old_issues)}")
print(f"new_count={len(issues)}")
print(f"first_issue={issues[0] if issues else ''}")
print(f"last_issue={issues[-1] if issues else ''}")
print(f"assigned_slot_issues={','.join(str(i) for i in slot_issues)}")

with open(dest, "w", encoding="utf-8") as f:
    json.dump(state, f, indent=2)
    f.write("\n")
PY

  if $DRY_RUN; then
    log "dry-run: would update $CANONICAL_HOST:$CANONICAL_PATH"
    rm -f "$tmp" "$updated"
    return 0
  fi

  local backup="${CANONICAL_PATH}.bak.$(date +%s)"
  ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$CANONICAL_HOST" \
    "cp -a '$CANONICAL_PATH' '$backup'" ||
    die "failed to back up canonical on $CANONICAL_HOST"
  log "backed up canonical → $CANONICAL_HOST:$backup"

  scp -q -o BatchMode=yes -o ConnectTimeout=10 "$updated" "$CANONICAL_HOST:$CANONICAL_PATH" ||
    die "failed to update canonical"
  log "updated canonical issues → $CANONICAL_HOST:$CANONICAL_PATH"

  rm -f "$tmp" "$updated"
}

main "$@"
