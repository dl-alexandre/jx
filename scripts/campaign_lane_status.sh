#!/usr/bin/env bash
#
# Read-only status for the active OneBackend-v3 E14 campaign lanes.
# Reports per-host tmux sessions, campaign log sizes/exit markers, and git
# worktree change counts for the current non-advanced lanes.
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
)

usage() {
  cat <<EOF
Usage: $(basename "$0")

Prints a read-only status summary for current runnable campaign lanes.
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

  python3 - "$state" "$host" <<'PY'
import json
import sys

path, host = sys.argv[1:3]
state = json.load(open(path))
paths = [
    slot.get("worktree_path", "")
    for slot in state.get("slots", [])
    if slot.get("host_id") == host and slot.get("status") != "advanced"
]
print(":".join(p for p in paths if p))
PY
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  local state_tmp
  state_tmp=$(mktemp "${TMPDIR:-/tmp}/campaign-lane-state.XXXXXX")
  copy_state "$state_tmp"

  local entry
  for entry in "${RUNNABLE_LINES[@]}"; do
    local host="${entry%%:*}"
    local tmux_bin="${entry#*:}"
    local worktrees
    worktrees=$(host_worktrees "$state_tmp" "$host")

    printf '### %s\n' "$host"
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" "bash -s" <<REMOTE || true
set -u
tmux_bin='$tmux_bin'
worktrees='$worktrees'

echo 'sessions:'
if [ -x "\$tmux_bin" ] || command -v "\$tmux_bin" >/dev/null 2>&1; then
  "\$tmux_bin" list-sessions 2>/dev/null | grep '^e14-' || true
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
for d in "\${dirs[@]}"; do
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
