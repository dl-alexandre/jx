# OneBackend-v3 E14 Campaign – Deployment Notes

This document preserves the concrete operational details for the
`onebackend-v3-e14` campaign that was used to drive the initial development
of the `jx campaign` system.

These notes are **not** part of the generic `jx` documentation. They are kept
here for the team that ran the campaign and for future reference when
replaying a similar large-scale effort.

## Original Commands (as run)

```sh
jx campaign init onebackend-v3-e14 --issues 1025..1153 --parallelism 13 --agent-mix grok,claude,codex --direction desc
jx campaign seed onebackend-v3-e14 --from-existing-worktrees --branch-prefix onebackend-v3-
jx campaign tick onebackend-v3-e14 --dry-run --repo MILCGroup/OneBackend-v3
jx campaign tick onebackend-v3-e14 --apply --repo MILCGroup/OneBackend-v3
jx campaign status onebackend-v3-e14
jx campaign events onebackend-v3-e14
```

## Canonical State Location (Pass 1)

```
/home/developer/OneBackend-v3/.jx/campaigns/onebackend-v3-e14.json   (uitestserver – canonical)
```

## Host Map

| SSH host            | JSON path                                                            | Role                     |
|---------------------|----------------------------------------------------------------------|--------------------------|
| uitestserver        | `/home/developer/OneBackend-v3/.jx/campaigns/onebackend-v3-e14.json` | Canonical source         |
| testserver          | `/Users/developer/OneBackend-v3/.jx/campaigns/onebackend-v3-e14.json`| Runnable                 |
| milcmini            | `/Users/milc/Documents/GitHub/OneBackend-v3/.jx/campaigns/...`       | Runnable                 |
| optiplex-xe2-local  | `/home/milc/Work/OneBackend-v3/.jx/campaigns/...`                    | Runnable                 |
| ideapad             | `/home/ideapad/Work/OneBackend-v3/.jx/campaigns/...`                 | Visibility / sync target |

## Sync & Observation Scripts Used

- `scripts/campaign_sync.sh`
- `scripts/campaign_observe.sh`
- `scripts/campaign_pr_status.sh`
- `scripts/campaign_lane_status.sh` (extended with --advanced/--all/--only/--json-file/--canonical-* for merge phase)
- `scripts/campaign_merge_assist.sh` (new for post-advance rebase/runbook generation)
- `scripts/campaign_set_issues.sh`
- `scripts/campaign_tick.exs`

See the commit history and the files in `docs/dogfood/` for the Grok operator
prompts (`campaign_grok_operator.md`, `campaign_grok_pr_guardian.md`) that
were written specifically for supervising this campaign.

## Scope Note

The issue range `1025..1153` (129 issues) was derived from GitHub issues
labeled `epic:E14` and `area:animals`, executed in descending order.

The 13 slots were the concurrent execution lanes, not the total scope.
Historical `advanced` records accumulated in the JSON over time.

## Drive-to-Zero Merge Tracker System (Production-Grade for E14)

For the long-running post-advance phase (until the live GitHub count of open
E14 advanced PRs reaches **exactly 0**), the operational system centers on:

- `/tmp/e14-merge-tracker.md` + `/tmp/e14-merge-tracker.json` (source of truth)
- `/tmp/e14_drive_tools/refresh_e14_tracker.py` (the persistent refresher)
- `/tmp/e14-still-open.json` + sidecars (for filtering)
- The enhanced `scripts/campaign_merge_assist.sh --still-open-json ...` (produces filtered "clean" runbooks directly)
- Per-host `e14-batch-*-<TS>.md` (timestamped, now filtered)
- The canonical `/tmp/e14-campaign-current.json` (synced copy of the uitestserver one)

**Current live status (fresh gh + refresh as of 2026-05-23T19:40Z)**: **72** still-open E14 advanced PRs
(out of 129 advanced slots with PRs; total repo open PRs 74). Down from earlier snapshots (~82 initial advanced). Goal remains exactly 0.

### Key Production Improvements (addressing long-haul friction)
- History accumulates in the JSON (no loss of prior counts on refresh).
- Human confirmations (`confirmed_at`, `last_batch` per item) are carried over automatically on refresh.
- Hosts sorted fewest-remaining first for batch priority.
- Dynamic counts and lists (no hard-coded numbers or host orders in generated artifacts).
- `refresh` validates canonical path + produces consistent stderr messages.
- Runbooks can be generated **filtered** so only still-open PRs appear (no manual skipping of merged lanes).
- Tracker + runbooks stay strictly read-only; human executes the gh/git commands.
- The human-facing `e14-merge-tracker.md` (and `next-batch-ready.md`) are **always derived** from the .json on refresh. The Playbook and confirmation guidance explicitly direct all edits to the .json only; hand edits to .md are lost (and now warned against in the generated output).
- Still-open sidecars and next-batch-ready.md are now protected by atomic writes + rotating backups (same as main tracker.json) — prevents corruption/loss during long-haul refreshes.
- Generated artifacts now include a concise live "Current Next-Batch Priority (fewest-first)" block (current host + PR count/list) that points to the single authoritative Drive-to-Zero Playbook section for the detailed sequence. This reduces "which host first?" guesswork and instruction duplication on every handoff for the repeated 72→0 loop.
- Full "human batch confirmation edit in .json + re-refresh carry-over + history append + stable count" loop is exercised and verified on every improvement cycle (not just happy-path).

### Refresh + Batch Workflow (repeated cycles)
```sh
# 1. Always
./scripts/campaign_sync.sh status

# 2. Refresh central tracker (live gh correlation + carry-over)
python3 /tmp/e14_drive_tools/refresh_e14_tracker.py \
    --canonical /tmp/e14-campaign-current.json \
    --output-dir /tmp

# 3. Generate clean filtered runbooks (no manual edit step)
TS=$(date +%Y%m%d-%H%M%S)
STILL=/tmp/e14-still-open.json
CANON=/tmp/e14-campaign-current.json
# Dynamic host list from the just-refreshed tracker (fewest-first order, authoritative)
for h in $(python3 -c '
import json,sys
d=json.load(open("/tmp/e14-merge-tracker.json"))
print(" ".join(d.get("still_open_prs_by_host",{}).keys()))
' 2>/dev/null || echo 'ideapad uitestserver optiplex-xe2-local milcmini testserver'); do
  ./scripts/campaign_merge_assist.sh \
    --host $h --json-file $CANON --still-open-json $STILL \
    > /tmp/e14-batch-$h-$TS.md 2>/tmp/gen-$h.log
done

# 4. Hand the still-open lists (from tracker.md or next-batch-ready.md) + the new batch-*.md to human
# 5. Human executes (using gh cross-checks), reports merges
# 6. Re-run 1+2 (confirmations preserved), repeat until 0
```

Offline / resilient usage: point --canonical (and --still-open-json) at local copies of the JSONs; the refresh still needs `gh` for the live open list (the source of truth for "still open").

The Drive-to-Zero Playbook lives in the generated `e14-merge-tracker.md` (refreshed on every run) and is also captured in the operator prompt.

See also: `docs/dogfood/campaign_grok_operator.md` (Merge Assistance section) and the campaign scripts.

**Artifacts after a refresh**:
- `e14-merge-tracker.json` (full items + history + confirmations; durable source)
- `e14-merge-tracker.md` (human view + playbook; *derived*)
- `e14-still-open.json` (rich item dicts with all fields for --still-open-json filter and `jq '.[].pr_number'`); companion `e14-still-open-branches.txt` (lightweight one-branch-per-line list)
- `e14-next-batch-ready.md` (*derived*)
The assist filter gracefully accepts either the rich dict list or a bare-int list from the json.

This system is designed to be self-sustaining with minimal friction for the duration of the drive-to-zero.
