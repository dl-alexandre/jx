#!/usr/bin/env bash
#
# Hardened observation wrapper for OneBackend-v3 E14.
#
# This is intentionally the single routine command used by the scheduler.  Grok
# repeatedly hung during bootstrap before reaching the campaign commands, so the
# default path redirects to the deterministic observer.  Set USE_GROK=1 for a
# bounded Grok-supervised pass when debugging Grok itself.

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PROMPT_FILE="$ROOT/docs/campaign_grok_operator.md"
LOG_FILE="$ROOT/logs/campaign_grok_observe.log"
OBSERVE_SCRIPT="$ROOT/scripts/campaign_observe.sh"
mkdir -p "$(dirname "$LOG_FILE")"

[[ -f "$PROMPT_FILE" ]] || {
  echo "missing prompt file: $PROMPT_FILE" >&2
  exit 1
}

echo "[$(date)] Starting safe observation pass..." >> "$LOG_FILE"

if [[ "${USE_GROK:-0}" != "1" ]]; then
  echo "[$(date)] Redirecting to deterministic campaign_observe.sh" >> "$LOG_FILE"
  exec "$OBSERVE_SCRIPT" "$@"
fi

timeout 90s grok \
  --cwd "$ROOT" \
  --no-alt-screen \
  --disable-web-search \
  --max-turns 8 \
  --output-format plain \
  --always-approve \
  --prompt-file "$PROMPT_FILE" \
  2>&1 | tee -a "$LOG_FILE"

EXIT_CODE=${PIPESTATUS[0]}
echo "[$(date)] Finished with exit code $EXIT_CODE" >> "$LOG_FILE"

exit $EXIT_CODE
