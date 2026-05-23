#!/usr/bin/env bash
#
# campaign_merge_assist.sh
#
# Produces ready-to-run rebase + review runbooks for advanced E14 lanes.
# This is the primary tool for the post-advance merge assistance phase.
#
# Usage examples:
#   ./scripts/campaign_merge_assist.sh --host milcmini
#   ./scripts/campaign_merge_assist.sh --host testserver --campaign onebackend-v3-e14
#   ./scripts/campaign_merge_assist.sh --host milcmini --json-file /tmp/e14-test-campaign.json
#
# It is intentionally read-only. It never performs rebases, commits, or merges itself.
#

CAMPAIGN="${CAMPAIGN:-onebackend-v3-e14}"
CANONICAL_HOST="${CANONICAL_HOST:-uitestserver}"
CANONICAL_ROOT="${CANONICAL_ROOT:-/home/developer/OneBackend-v3}"
TARGET_HOST=""
JSON_FILE=""
STILL_OPEN_JSON=""

set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") --host <host> [--campaign <name>]
       [--canonical-host <h>] [--canonical-root <p>] [--json-file <path>]
       [--still-open-json <path>]

  --host <name>     Required. One of: testserver, milcmini, optiplex-xe2-local, uitestserver, ideapad
  --campaign <name> Override campaign name (default: onebackend-v3-e14)

  --canonical-host <h>  Override canonical SSH host for state (default: uitestserver)
  --canonical-root <p>  Override canonical filesystem root (default: /home/developer/OneBackend-v3)
  --json-file <path>    Use this local JSON file directly instead of scp/fetch (supports
                        offline analysis, testing, and recovery from SCP failures)
  --still-open-json <path>
                        Path to e14-still-open.json (enveloped {schema_version, generated_at, items[]} or legacy bare list)
                        from refresh_e14_tracker.py. When supplied, the runbook is filtered to ONLY
                        still-open PRs (producing "clean" runbooks directly; no manual skip of already-merged lanes).
                        The envelope enables staleness awareness via generated_at in the INFO log line.
                        Realistic offline example:
                          ./scripts/campaign_merge_assist.sh --host ideapad \\
                            --json-file /tmp/e14-campaign-current.json \\
                            --still-open-json /tmp/e14-still-open.json \\
                            > /tmp/e14-batch-ideapad-$(date +%Y%m%d-%H%M%S).md 2>/tmp/gen.log

Outputs a markdown runbook with exact, copy-pasteable commands for rebasing and
reviewing the advanced lanes assigned to that host.
When --still-open-json is used, only current live open E14 PRs for the host appear in the batch.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then echo "ERROR: --host requires <host>" >&2; exit 1; fi
      TARGET_HOST="$2"; shift 2 ;;
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
    --still-open-json)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then echo "ERROR: --still-open-json requires a path" >&2; exit 1; fi
      STILL_OPEN_JSON="$2"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *)          echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$TARGET_HOST" ]]; then
  echo "ERROR: --host is required" >&2
  usage
  exit 1
fi

# Use a temp file for the canonical JSON so the script works from any control machine
CANONICAL_JSON=$(mktemp "${TMPDIR:-/tmp}/e14-campaign-state.XXXXXX.json")

if [[ -n "$JSON_FILE" ]]; then
  echo "Using provided --json-file: $JSON_FILE" >&2
  cp -a "$JSON_FILE" "$CANONICAL_JSON" || {
    echo "ERROR: failed to copy --json-file $JSON_FILE" >&2
    rm -f "$CANONICAL_JSON"
    exit 1
  }
else
  local_canon_path="$CANONICAL_ROOT/.jx/campaigns/$CAMPAIGN.json"
  if [[ -f "$local_canon_path" ]]; then
    echo "Using local canonical JSON: $local_canon_path" >&2
    cp -a "$local_canon_path" "$CANONICAL_JSON" || {
      echo "ERROR: failed to cp local $local_canon_path" >&2
      rm -f "$CANONICAL_JSON"
      exit 1
    }
  else
    echo "Fetching canonical JSON from $CANONICAL_HOST ..." >&2
    scp -q -o BatchMode=yes -o ConnectTimeout=15 \
        "$CANONICAL_HOST:$local_canon_path" "$CANONICAL_JSON" || {
      echo "ERROR: failed to fetch canonical JSON from $CANONICAL_HOST:$local_canon_path" >&2
      echo "       Tip: use --json-file /path/to/local/$CAMPAIGN.json (e.g. from prior sync) to continue" >&2
      rm -f "$CANONICAL_JSON"
      exit 1
    }
  fi
fi

# Early guard for --still-open-json (prevents misleading "filtered" output on bad path; mirrors --json-file error handling)
if [[ -n "$STILL_OPEN_JSON" && ! -f "$STILL_OPEN_JSON" ]]; then
  echo "ERROR: --still-open-json file not found: $STILL_OPEN_JSON" >&2
  echo "       Tip: run the refresher first to (re)generate /tmp/e14-still-open.json, or use --json-file only for unfiltered runbooks." >&2
  rm -f "$CANONICAL_JSON"
  exit 1
fi

trap 'rm -f "$CANONICAL_JSON"' EXIT

python3 - "$CANONICAL_JSON" "$TARGET_HOST" "$CAMPAIGN" "$STILL_OPEN_JSON" <<'PYEOF'
import json
import sys
from datetime import datetime, timezone

json_path, host, campaign = sys.argv[1:4]
still_open_path = sys.argv[4] if len(sys.argv) > 4 else ""

try:
    with open(json_path, "r", encoding="utf-8") as f:
        state = json.load(f)
except Exception as e:
    print(f"ERROR: failed to read or parse campaign JSON at {json_path}: {e}", file=sys.stderr)
    sys.exit(1)

if not isinstance(state, dict) or "slots" not in state or not isinstance(state.get("slots"), list):
    print(f"ERROR: {json_path} is not a valid campaign state JSON (missing 'slots' list)", file=sys.stderr)
    sys.exit(1)

slots = state.get("slots", [])
advanced = [s for s in slots if s.get("status") == "advanced" and s.get("host_id") == host]

# Optional still-open filter (for clean filtered runbooks; production-grade for drive-to-zero)
orig_count = len(advanced)
filtered = False
if still_open_path:
    try:
        with open(still_open_path, "r", encoding="utf-8") as f:
            still_data = json.load(f)
        # Support both legacy bare list and new self-describing envelope {schema_version, generated_at, still_open_count, items}
        # This enables staleness checks (e.g. log the generated_at of the still-open snapshot used for the runbook).
        still_list = []
        still_meta = ""
        if isinstance(still_data, dict):
            still_list = still_data.get("items", []) or []
            gen_at = still_data.get("generated_at", "")
            cnt = still_data.get("still_open_count", len(still_list))
            if gen_at:
                still_meta = f" (snapshot {gen_at}, {cnt} PRs)"
        elif isinstance(still_data, list):
            still_list = still_data
        if still_list:
            if isinstance(still_list[0], dict) if still_list else False:
                still_prs = {int(it.get("pr_number")) for it in still_list if it.get("pr_number") is not None}
            else:
                still_prs = {int(x) for x in still_list if x}
        else:
            still_prs = set()
        if still_prs:
            advanced = [s for s in advanced if s.get("pr_number") in still_prs]
            print(f"INFO: --still-open-json filtered to {len(advanced)} still-open PRs (was {orig_count}){still_meta}", file=sys.stderr)
            filtered = True
    except Exception as e:
        print(f"WARNING: could not load/filter --still-open-json {still_open_path}: {e} (emitting all advanced)", file=sys.stderr)

print(f"# E14 Merge Assistance Runbook – {host}")
print(f"Campaign: {campaign}")
dt = datetime.now(timezone.utc)
print(f"Generated: {dt.isoformat().replace('+00:00', 'Z')}")
suffix = f" (still-open filtered from {orig_count})" if filtered else ""
print(f"Advanced lanes on this host: {len(advanced)}{suffix}")
print()
print("## Prerequisites (run first)")
print("```bash")
print(f"cd /Users/developer/Documents/GitHub/workspaces/saysure   # or wherever your copy lives")
print("./scripts/campaign_sync.sh status")
print("```")
print()
print("## Host Notes")

if host == "milcmini":
    print("**IMPORTANT**: Physical worktree directories are missing on milcmini.")
    print("All work must be performed from the parent checkout (`/Users/milc/Documents/GitHub/OneBackend-v3`).")
    print("Stale git registrations will need pruning after verification.")
else:
    print("Worktrees are expected to exist on disk and be locally clean.")

print()

# Always emit the list of PRs that will receive blocks in this runbook (accurate when filtered)
still_open_list = [s.get("pr_number") for s in sorted(advanced, key=lambda x: (x.get("pr_number") or 0), reverse=True)]
print("## Still-open PRs for this host (live at runbook gen; use these + gh pr view before any rebase)")
print(f"**Still open on {host}**: {still_open_list}")
print()
print("(Only these PRs have rebase/review/merge blocks below. Confirm they are still open via `gh pr view <n> --repo MILCGroup/OneBackend-v3` and the tracker before executing.)")
print()

print("## Rebase & Review Batch (copy-paste safe commands)")
print()

for s in sorted(advanced, key=lambda x: x.get("pr_number") or 0, reverse=True):
    issue = s.get("issue_number")
    pr = s.get("pr_number")
    branch = s.get("branch")
    worktree = s.get("worktree_path")
    agent = s.get("agent_kind", "?")
    slot = s.get("slot_index")

    print(f"### PR #{pr} – issue {issue} ({agent}) – slot {slot}")
    print(f"Branch: `{branch}`")
    print()

    if host == "milcmini":
        # Special case – operate from parent
        print("```bash")
        print(f"# On control machine – inspect current registration")
        print(f"ssh -o BatchMode=yes -o ConnectTimeout=15 milcmini 'cd /Users/milc/Documents/GitHub/OneBackend-v3 && git worktree list | grep {branch}'")
        print()
        print(f"# Rebase from parent (recommended for milcmini)")
        print(f"ssh -o BatchMode=yes -o ConnectTimeout=15 milcmini '")
        print(f"  cd /Users/milc/Documents/GitHub/OneBackend-v3 &&")
        print(f"  git fetch origin develop &&")
        print(f"  git worktree add -B {branch} ../{branch} {branch} 2>/dev/null || true &&")
        print(f"  cd ../{branch} &&")
        print(f"  git fetch origin develop &&")
        print(f"  git rebase origin/develop")
        print(f"'")
        print("```")
    else:
        print("```bash")
        print(f"ssh -o BatchMode=yes -o ConnectTimeout=15 {host} '")
        print(f"  cd {worktree} &&")
        print(f"  git fetch origin develop &&")
        print(f"  git rebase origin/develop")
        print(f"'")
        print("```")

    print()
    print("After the rebase succeeds on the host:")
    print("```bash")
    print(f"# Review (from your control machine)")
    print(f"gh pr view {pr} --repo MILCGroup/OneBackend-v3")
    print(f"gh pr review {pr} --repo MILCGroup/OneBackend-v3 --approve   # or --comment")
    print(f"gh pr merge {pr} --repo MILCGroup/OneBackend-v3 --auto --merge")
    print("```")
    print()

print("## Post-batch hygiene (after you have merged several lanes)")
print("```bash")
print(f"# On control machine")
print("./scripts/campaign_sync.sh status")
print()
if host == "milcmini":
    print("# Optional: prune stale registrations on milcmini (only after you have verified the PRs)")
    print("ssh -o BatchMode=yes -o ConnectTimeout=15 milcmini 'cd /Users/milc/Documents/GitHub/OneBackend-v3 && git worktree prune --dry-run'")
    print("ssh -o BatchMode=yes -o ConnectTimeout=15 milcmini 'cd /Users/milc/Documents/GitHub/OneBackend-v3 && git worktree prune'")
print("```")
print()
print("---")
print("Remember: the operator (Grok) only produces these commands. A human must execute them.")
PYEOF
