#!/usr/bin/env bash
#
# Run one Grok-guided PR guardian pass for the OneBackend-v3 E14 campaign.
# This is intentionally separate from campaign_grok_observe.sh: it may repair
# PR branches and merge only fully green, non-draft campaign PRs.

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PROMPT_FILE="$ROOT/docs/campaign_grok_pr_guardian.md"
GROK_BIN="${GROK_BIN:-grok}"

[[ -f "$PROMPT_FILE" ]] || {
  echo "missing prompt file: $PROMPT_FILE" >&2
  exit 1
}

exec "$GROK_BIN" \
  --cwd "$ROOT" \
  --no-alt-screen \
  --disable-web-search \
  --max-turns 160 \
  --output-format plain \
  --always-approve \
  --prompt-file "$PROMPT_FILE"
