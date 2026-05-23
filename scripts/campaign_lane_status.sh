#!/usr/bin/env bash
#
# Read-only status for OneBackend-v3 E14 campaign lanes (active or advanced).
#
# Reports per-host tmux sessions, campaign log freshness/exit markers, and
# git worktree state. Supports active lanes (default), advanced lanes (--advanced),
# or all lanes (--all). This is the primary inspection tool for the merge-assistance phase.
#

CAMPAIGN="${CAMPAIGN:-onebackend-v3-e14}"
CANONICAL_HOST="${CANONICAL_HOST:-uitestserver}"
CANONICAL_ROOT="${CANONICAL_ROOT:-/home/developer/OneBackend-v3}"

set -euo pipefail

RUNNABLE_LINES=(
  "testserver:/opt/homebrew/bin/tmux"
  "milcmini:/opt/homebrew/bin/tmux"
  "optiplex-xe2-local:/usr/bin/tmux"
  "uitestserver:/usr/bin/tmux"
  "ideapad:/usr/bin/tmux"
)

# Filter mode for which slots to inspect: "active" (default), "advanced", or "all"
FILTER_MODE="active"
ONLY_HOST=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [--advanced | --all | --active] [--only <host>] [--campaign <name>]

  --active     (default) Report only non-advanced (still active) lanes
  --advanced   Report only advanced lanes (the post-completion / merge phase lanes)
  --all        Report both active and advanced lanes

  --only <host>   Limit output to a single SSH host (testserver, milcmini, ...)
  --campaign <n>  Override campaign name (default: onebackend-v3-e14)

Prints a read-only status summary useful for both active observation and
post-advance merge assistance.
EOF
}

state_path() {
  printf '%s/.jx/campaigns/%s.json\n' "$CANONICAL_ROOT" "$CAMPAIGN"
}

copy_state() {
  local tmp="$1"
  scp -q -o BatchMode=yes -o ConnectTimeout=10 \
    "$CANONICAL_HOST:$(state_path)" "$tmp"
}

host_worktrees() {
  local state="$1"
  local host="$2"
  local mode="${3:-active}"

  python3 - "$state" "$host" "$mode" <<'PY'
import json
import sys

path, host, mode = sys.argv[1:4]
state = json.load(open(path))

def include(slot):
    s = slot.get("status")
    if mode == "active":
        return s != "advanced"
    elif mode == "advanced":
        return s == "advanced"
    else:  # all
        return True

paths = [
    slot.get("worktree_path", "")
    for slot in state.get("slots", [])
    if slot.get("host_id") == host and include(slot)
]
print(":".join(p for p in paths if p))
PY
}

main() {
  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --advanced) FILTER_MODE="advanced"; shift ;;
      --all)      FILTER_MODE="all";      shift ;;
      --active)   FILTER_MODE="active";   shift ;;
      --only)     ONLY_HOST="${2:-}"; shift 2 ;;
      --campaign) CAMPAIGN="${2:-}"; shift 2 ;;
      -h|--help)  usage; exit 0 ;;
      *)          echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
  done

  local state_tmp
  state_tmp=$(mktemp "${TMPDIR:-/tmp}/campaign-lane-state.XXXXXX")
  copy_state "$state_tmp"

  local entry
  for entry in "${RUNNABLE_LINES[@]}"; do
    local host="${entry%%:*}"
    local tmux_bin="${entry#*:}"

    if [[ -n "$ONLY_HOST" && "$host" != "$ONLY_HOST" ]]; then
      continue
    fi

    local worktrees
    worktrees=$(host_worktrees "$state_tmp" "$host" "$FILTER_MODE")

    printf '### %s (mode=%s)\n' "$host" "$FILTER_MODE"
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" "bash -s" <<REMOTE || true
set -u
tmux_bin='$tmux_bin'
worktrees='$worktrees'
filter_mode='$FILTER_MODE'

echo 'sessions:'
if [ -x "\$tmux_bin" ] || command -v "\$tmux_bin" >/dev/null 2>&1; then
  "\$tmux_bin" list-sessions 2>/dev/null | grep -E '^e14-|^[[:space:]]*e14-' || true
else
  echo "tmux unavailable: \$tmux_bin"
fi

echo 'logs:'
now=\$(date +%s)
for f in /tmp/onebackend-v3-e14-logs/e14-*.log; do
  [ -f "\$f" ] || continue
  size=\$(wc -c < "\$f" | tr -d ' ')
  if stat -c %Y "\$f" >/dev/null 2>&1; then
    mtime=\$(stat -c %Y "\$f")
  else
    mtime=\$(stat -f %m "\$f" 2>/dev/null || echo "\$now")
  fi
  age=\$((now - mtime))
  exit_marker=''
  if grep -q '\\[campaign\\] exited' "\$f" 2>/dev/null; then
    exit_marker=' exited'
  fi
  printf '  %s age=%ss bytes=%s%s\\n' "\$(basename "\$f")" "\$age" "\$size" "\$exit_marker"
done

echo 'worktrees:'
IFS=':' read -r -a dirs <<< "\$worktrees"
if [ \${#dirs[@]} -eq 0 ]; then
  echo "  (no worktrees for this host+filter)"
fi
for d in "\${dirs[@]}"; do
  if [ ! -d "\$d" ]; then
    printf '  %s  [MISSING DIRECTORY - only git registration remains]\\n' "\$d"
    continue
  fi
  git -C "\$d" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue
  branch=\$(git -C "\$d" branch --show-current)
  changes=\$(git -C "\$d" status --short | wc -l | tr -d ' ')
  ahead=\$(git -C "\$d" rev-list --count origin/develop..HEAD 2>/dev/null || echo NA)
  head=\$(git -C "\$d" log -1 --format='%h %cr %s')
  printf '  %s changes=%s ahead_develop=%s head=%s\\n' "\$branch" "\$changes" "\$ahead" "\$head"
done
REMOTE
  done

  rm -f "$state_tmp"
}

main "$@"
