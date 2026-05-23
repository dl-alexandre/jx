#!/usr/bin/env bash
#
# campaign_sync.sh
#
# Tiny, auditable helper for keeping the onebackend-v3-e14 campaign JSON
# in sync across the five OneBackend-v3 checkouts (Pass 1 file-backed model).
#
# Canonical source of truth:
#   uitestserver:/home/developer/OneBackend-v3/.jx/campaigns/onebackend-v3-e14.json
#
# Usage:
#   ./scripts/campaign_sync.sh status
#   ./scripts/campaign_sync.sh push --dry-run
#   ./scripts/campaign_sync.sh push
#   ./scripts/campaign_sync.sh pull optiplex-xe2-local --dry-run
#   ./scripts/campaign_sync.sh pull ideapad
#   ./scripts/campaign_sync.sh verify /path/to/some.json
#
# The script is intentionally simple and self-contained so the movement of
# campaign state is explicit, reviewable, and safe before/after observation
# or apply steps.
#

# --- Defaults must be defined before 'set -u' for Bash 3.2 compatibility ---
CAMPAIGN="${CAMPAIGN:-onebackend-v3-e14}"
CANONICAL_PATH=""

# Definitive sync map (from live fleet inspection 2026-05).
# Format: "ssh-host:remote-path"  (one per line)
# Keep this list in sync with docs/campaigns.md
TARGET_LINES=()

# Canonical host is the source; it does not appear in the target list for push.
CANONICAL_HOST="uitestserver"

DRY_RUN=false
ONLY_HOST=""
COMMAND=""

set -euo pipefail

# --- Portable helpers (Bash 3.2 compatible) ---

configure_paths() {
  CANONICAL_PATH="/home/developer/OneBackend-v3/.jx/campaigns/${CAMPAIGN}.json"
  TARGET_LINES=(
    "testserver:/Users/developer/OneBackend-v3/.jx/campaigns/${CAMPAIGN}.json"
    "milcmini:/Users/milc/Documents/GitHub/OneBackend-v3/.jx/campaigns/${CAMPAIGN}.json"
    "optiplex-xe2-local:/home/milc/Work/OneBackend-v3/.jx/campaigns/${CAMPAIGN}.json"
    "ideapad:/home/ideapad/Work/OneBackend-v3/.jx/campaigns/${CAMPAIGN}.json"
  )
}

target_path_for() {
  local want="$1"
  for entry in "${TARGET_LINES[@]}"; do
    local h="${entry%%:*}"
    local p="${entry#*:}"
    if [[ "$h" == "$want" ]]; then
      echo "$p"
      return 0
    fi
  done
  echo ""
}

target_hosts() {
  for entry in "${TARGET_LINES[@]}"; do
    echo "${entry%%:*}"
  done
}

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  status                 Show drift between canonical and all targets
  push                   Copy canonical to all (or --only) targets
  pull <ssh-host>        Copy from a target back to canonical (use after --apply)
  verify [file]          Basic sanity check on a JSON file (correct name/parallelism)

Options:
  --dry-run              Show what would happen without making changes
  --only <ssh-host>      Limit push to a single host
  --campaign <name>      Override campaign name (default: onebackend-v3-e14)
  -h, --help             This help

Typical flow (run on the canonical machine):
  $(basename "$0") status
  $(basename "$0") push --dry-run
  $(basename "$0") push

After a real tick --apply on one host:
  $(basename "$0") pull <that-host>
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

# Cross-platform SHA-256 of a local file
file_sha256() {
  local f="$1"
  if have_cmd sha256sum; then
    sha256sum "$f" | awk '{print $1}'
  elif have_cmd shasum; then
    shasum -a 256 "$f" | awk '{print $1}'
  else
    die "need sha256sum or shasum"
  fi
}

# Cross-platform SHA-256 of a remote file via SSH
remote_sha256() {
  local host="$1"
  local path="$2"
  ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$host" "
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum '$path' 2>/dev/null | awk '{print \$1}'
    elif command -v shasum >/dev/null 2>&1; then
      shasum -a 256 '$path' 2>/dev/null | awk '{print \$1}'
    else
      echo 'NO_HASHER'
    fi
  " 2>/dev/null || echo 'SSH_FAILED'
}

canonical_is_local() {
  [[ -f "$CANONICAL_PATH" ]]
}

canonical_source_label() {
  if canonical_is_local; then
    echo "$CANONICAL_PATH"
  else
    echo "$CANONICAL_HOST:$CANONICAL_PATH"
  fi
}

copy_canonical_to_temp() {
  local tmp="$1"
  if canonical_is_local; then
    cp -a "$CANONICAL_PATH" "$tmp"
  else
    scp -q -o BatchMode=yes -o ConnectTimeout=10 "$CANONICAL_HOST:$CANONICAL_PATH" "$tmp" ||
      die "failed to copy canonical from $CANONICAL_HOST:$CANONICAL_PATH"
  fi
}

validate_json() {
  local f="$1"
  [[ -f "$f" ]] || die "file not found: $f"

  local name slots current_slots version parallelism issues
  if have_cmd jq; then
    name=$(jq -r '.name // empty' "$f" 2>/dev/null || echo '')
    slots=$(jq -r '.slots | length' "$f" 2>/dev/null || echo '0')
    current_slots=$(jq -r '[.slots[]? | select(.status != "advanced")] | length' "$f" 2>/dev/null || echo '0')
    version=$(jq -r '.version // 0' "$f" 2>/dev/null || echo '0')
    parallelism=$(jq -r '.parallelism // 0' "$f" 2>/dev/null || echo '0')
    issues=$(jq -r '.issues | length' "$f" 2>/dev/null || echo '0')
  elif have_cmd python3; then
    local parsed
    parsed=$(python3 -c "
import json,sys
try:
  d=json.load(open(sys.argv[1]))
  slots=d.get('slots',[])
  print(d.get('name',''))
  print(len(slots))
  print(len([s for s in slots if s.get('status') != 'advanced']))
  print(d.get('version',0))
  print(d.get('parallelism',0))
  print(len(d.get('issues',[])))
except Exception:
  print('')
  print('0')
  print('0')
  print('0')
  print('0')
  print('0')
" "$f" 2>/dev/null || echo -e '\n0\n0\n0\n0\n0')
    name=$(printf '%s\n' "$parsed" | sed -n '1p')
    slots=$(printf '%s\n' "$parsed" | sed -n '2p')
    current_slots=$(printf '%s\n' "$parsed" | sed -n '3p')
    version=$(printf '%s\n' "$parsed" | sed -n '4p')
    parallelism=$(printf '%s\n' "$parsed" | sed -n '5p')
    issues=$(printf '%s\n' "$parsed" | sed -n '6p')
  else
    log "warning: jq or python3 not found — skipping deep validation"
    return 0
  fi

  if [[ "$name" != "$CAMPAIGN" ]]; then
    die "JSON name mismatch: got '$name', expected '$CAMPAIGN'"
  fi
  if [[ "$parallelism" != "13" ]]; then
    die "expected parallelism 13, found $parallelism"
  fi
  if [[ "$issues" -lt "$parallelism" ]]; then
    die "issue list too short: issues=$issues, parallelism=$parallelism"
  fi
  if [[ "$current_slots" -gt "$parallelism" ]]; then
    die "too many current lanes: current_slots=$current_slots, parallelism=$parallelism"
  fi
  if [[ "$slots" -lt "$current_slots" ]]; then
    die "invalid slot counts: total_slots=$slots, current_slots=$current_slots"
  fi
  if [[ "$version" != "1" ]]; then
    log "warning: version is $version (expected 1)"
  fi
  log "validation passed: total_slots=$slots, current_slots=$current_slots, parallelism=$parallelism, issues=$issues, name=$name, version=$version"
}

do_status() {
  local tmp src_sha
  tmp=$(mktemp "${TMPDIR:-/tmp}/campaign-sync-canonical.XXXXXX")
  copy_canonical_to_temp "$tmp"
  validate_json "$tmp" >/dev/null
  src_sha=$(file_sha256 "$tmp")
  rm -f "$tmp"

  log "canonical: $(canonical_source_label)"
  log "sha256: $src_sha"
  echo

  while IFS= read -r host; do
    local path
    path=$(target_path_for "$host")
    [[ -n "$path" ]] || continue

    local remote_sha
    remote_sha=$(remote_sha256 "$host" "$path")

    if [[ "$remote_sha" == "SSH_FAILED" ]]; then
      printf "  %-22s  SSH_FAILED  %s\n" "$host" "$path"
    elif [[ "$remote_sha" == "NO_HASHER" ]]; then
      printf "  %-22s  NO_HASHER   %s\n" "$host" "$path"
    elif [[ "$remote_sha" == "$src_sha" ]]; then
      printf "  %-22s  OK          %s\n" "$host" "$path"
    else
      printf "  %-22s  DRIFT       %s\n" "$host" "$path"
    fi
  done < <(target_hosts)
}

do_push() {
  local src
  src=$(mktemp "${TMPDIR:-/tmp}/campaign-sync-canonical.XXXXXX")
  copy_canonical_to_temp "$src"
  validate_json "$src"

  local src_sha
  src_sha=$(file_sha256 "$src")

  local targets=()
  if [[ -n "$ONLY_HOST" ]]; then
    local p
    p=$(target_path_for "$ONLY_HOST")
    [[ -n "$p" ]] || die "unknown host in map: $ONLY_HOST"
    targets+=("$ONLY_HOST")
  else
    while IFS= read -r h; do targets+=("$h"); done < <(target_hosts)
  fi

  for host in "${targets[@]}"; do
    local dest
    dest=$(target_path_for "$host")
    log "push → $host:$dest"

    if $DRY_RUN; then
      log "  (dry-run) would copy $(canonical_source_label) → $host:$dest"
      continue
    fi

    # Ensure remote directory exists, then copy the small JSON file.
    ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$host" "mkdir -p '$(dirname "$dest")'" ||
      die "failed to mkdir on $host"
    scp -q -o BatchMode=yes -o ConnectTimeout=10 "$src" "$host:$dest" ||
      die "scp to $host failed"

    local new_sha
    new_sha=$(remote_sha256 "$host" "$dest")
    if [[ "$new_sha" != "$src_sha" ]]; then
      die "post-push hash mismatch on $host"
    fi
    log "  OK (hash matches)"
  done

  rm -f "$src"
}

do_pull() {
  local host="$1"
  [[ -n "$host" ]] || die "pull requires a host argument"
  local src_path
  src_path=$(target_path_for "$host")
  [[ -n "$src_path" ]] || die "host not in sync map: $host"

  local dest="$CANONICAL_PATH"

  log "pull ← $host:$src_path  →  $(canonical_source_label) (canonical)"

  if $DRY_RUN; then
    log "  (dry-run) would validate $host:$src_path and overwrite canonical"
    return 0
  fi

  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/campaign-sync-incoming.XXXXXX")
  scp -q -o BatchMode=yes -o ConnectTimeout=10 "$host:$src_path" "$tmp" ||
    die "scp from $host failed"

  validate_json "$tmp"

  # Backup current canonical only after the incoming file is known-good.
  local backup="${dest}.bak.$(date +%s)"
  if canonical_is_local; then
    cp -a "$dest" "$backup"
    log "  backed up current canonical → $backup"
    mv "$tmp" "$dest"
  else
    ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$CANONICAL_HOST" \
      "cp -a '$dest' '$backup'" || die "failed to back up canonical on $CANONICAL_HOST"
    log "  backed up current canonical → $CANONICAL_HOST:$backup"
    scp -q -o BatchMode=yes -o ConnectTimeout=10 "$tmp" "$CANONICAL_HOST:$dest" ||
      die "failed to update canonical on $CANONICAL_HOST"
    rm -f "$tmp"
  fi

  local verify_tmp
  verify_tmp=$(mktemp "${TMPDIR:-/tmp}/campaign-sync-verify.XXXXXX")
  copy_canonical_to_temp "$verify_tmp"
  validate_json "$verify_tmp"
  log "pull complete. new canonical sha: $(file_sha256 "$verify_tmp")"
  rm -f "$verify_tmp"
}

do_verify() {
  local f="${1:-}"
  if [[ -n "$f" ]]; then
    log "verifying $f"
    validate_json "$f"
  else
    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/campaign-sync-canonical.XXXXXX")
    copy_canonical_to_temp "$tmp"
    log "verifying $(canonical_source_label)"
    validate_json "$tmp"
    rm -f "$tmp"
  fi
}

main() {
  # Allow --help as the very first token
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  if [[ $# -eq 0 ]]; then
    usage
    exit 0
  fi

  local positionals=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=true; shift ;;
      --only)    ONLY_HOST="${2:-}"; shift 2 ;;
      --campaign) CAMPAIGN="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *)
        if [[ -z "$COMMAND" ]]; then
          COMMAND="$1"
        else
          positionals+=("$1")
        fi
        shift
        ;;
    esac
  done

  configure_paths

  case "$COMMAND" in
    status) do_status ;;
    push)   do_push ;;
    pull)
      local target_host="${positionals[0]:-}"
      do_pull "$target_host"
      ;;
    verify) do_verify "${positionals[0]:-}" ;;
    *) die "unknown command: $COMMAND (try --help)" ;;
  esac
}

main "$@"
