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
JSON_FILE=""

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
OFFLINE_MODE=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [--advanced | --all | --active] [--only <host>] [--campaign <name>]
       [--canonical-host <h>] [--canonical-root <p>] [--json-file <path>]

  --active     (default) Report only non-advanced (still active) lanes
  --advanced   Report only advanced lanes (the post-completion / merge phase lanes)
  --all        Report both active and advanced lanes

  --only <host>   Limit output to a single SSH host (testserver, milcmini, ...)
  --campaign <n>  Override campaign name (default: onebackend-v3-e14)

  --canonical-host <h>  Override canonical SSH host for state (default: uitestserver)
  --canonical-root <p>  Override canonical filesystem root (default: /home/developer/OneBackend-v3)
  --json-file <path>    Use this local JSON file directly instead of scp/fetch (supports
                        offline analysis, testing, and recovery from SCP failures)

Prints a read-only status summary useful for both active observation and
post-advance merge assistance.
EOF
}

state_path() {
  printf '%s/.jx/campaigns/%s.json\n' "$CANONICAL_ROOT" "$CAMPAIGN"
}

copy_state() {
  local tmp="$1"
  local canon_path
  canon_path="$(state_path)"

  if [[ -n "$JSON_FILE" ]]; then
    echo "Using provided --json-file: $JSON_FILE" >&2
    cp -a "$JSON_FILE" "$tmp" || {
      echo "ERROR: failed to copy --json-file $JSON_FILE" >&2
      return 1
    }
    return 0
  fi

  if [[ -f "$canon_path" ]]; then
    echo "Using local canonical JSON: $canon_path" >&2
    cp -a "$canon_path" "$tmp" || {
      echo "ERROR: failed to cp local $canon_path" >&2
      return 1
    }
    return 0
  fi

  echo "Fetching canonical JSON from $CANONICAL_HOST ..." >&2
  scp -q -o BatchMode=yes -o ConnectTimeout=10 \
    "$CANONICAL_HOST:$canon_path" "$tmp" || {
      echo "ERROR: failed to scp canonical from $CANONICAL_HOST:$canon_path" >&2
      echo "       Tip: use --json-file /path/to/local/$CAMPAIGN.json (e.g. from prior sync) to continue" >&2
      return 1
    }
  return 0
}

host_worktrees() {
  local state="$1"
  local host="$2"
  local mode="${3:-active}"

  python3 - "$state" "$host" "$mode" <<'PY'
import json
import sys

path, host, mode = sys.argv[1:4]

try:
    with open(path, "r", encoding="utf-8") as f:
        state = json.load(f)
except Exception as e:
    print(f"ERROR: failed to read or parse campaign JSON at {path}: {e}", file=sys.stderr)
    sys.exit(1)

if not isinstance(state, dict) or "slots" not in state or not isinstance(state.get("slots"), list):
    print(f"ERROR: {path} is not a valid campaign state JSON (missing 'slots' list)", file=sys.stderr)
    sys.exit(1)

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
      --only)
        if [[ $# -lt 2 || -z "${2:-}" ]]; then echo "ERROR: --only requires <host>" >&2; exit 1; fi
        ONLY_HOST="$2"; shift 2 ;;
      --campaign)
        if [[ $# -lt 2 || -z "${2:-}" ]]; then echo "ERROR: --campaign requires <name>" >&2; exit 1; fi
        CAMPAIGN="$2"; shift 2 ;;
      --canonical-host)
        if [[ $# -lt 2 || -z "${2:-}" ]]; then echo "ERROR: --canonical-host requires <h>" >&2; exit 1; fi
        CANONICAL_HOST="$2"; shift 2 ;;
      --canonical-root)
        if [[ $# -lt 2 || -z "${2:-}" ]]; then echo "ERROR: --canonical-root requires <p>" >&2; exit 1; fi
        CANONICAL_ROOT="$2"; shift 2 ;;
      --json-file)
        if [[ $# -lt 2 || -z "${2:-}" ]]; then echo "ERROR: --json-file requires a path" >&2; exit 1; fi
        JSON_FILE="$2"; shift 2 ;;
      -h|--help)  usage; exit 0 ;;
      *)          echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
  done

  if [[ -n "$JSON_FILE" ]]; then
    OFFLINE_MODE=true
  fi

  local state_tmp
  state_tmp=$(mktemp "${TMPDIR:-/tmp}/campaign-lane-state.XXXXXX")
  trap 'rm -f "$state_tmp"' EXIT
  if ! copy_state "$state_tmp"; then
    exit 1
  fi

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
    if $OFFLINE_MODE; then
      echo 'sessions: (skipped in offline mode via --json-file; SSH required for live tmux status)'
      echo 'logs: (skipped in offline mode via --json-file; SSH required for live log freshness)'
      echo 'worktrees:'
      IFS=':' read -r -a dirs <<< "$worktrees"
      if [ ${#dirs[@]} -eq 0 ]; then
        echo "  (no worktrees for this host+filter)"
      fi
      for d in "${dirs[@]}"; do
        printf '  %s  [REGISTERED (existence not verified in offline mode)]\n' "$d"
      done
    else
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
    fi
  done

  # tmp cleanup handled by EXIT trap set after mktemp
}

main "$@"
