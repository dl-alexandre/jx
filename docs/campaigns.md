# Campaigns

`jx campaign` manages PR-gated worktree campaigns as file-backed slot state.
It is intentionally thin: GitHub PRs are detected with `gh`, git worktrees
remain the workspace source of truth, and campaign state only tracks slots,
issue cursors, PR links, and events.

The campaign scope is the full issue/PR sequence configured in `issues`. The
13 slots in the E14 campaign are only the current parallel lanes; they are not
the campaign boundary. As lanes advance, historical `advanced` slot records stay
in the JSON and replacement lane records are appended.

## Commands

```sh
jx campaign init onebackend-v3-e14 --issues 1025..1153 --parallelism 13 --agent-mix grok,claude,codex --direction desc
jx campaign seed onebackend-v3-e14 --from-existing-worktrees --branch-prefix onebackend-v3-
jx campaign tick onebackend-v3-e14 --dry-run --repo owner/repo
jx campaign tick onebackend-v3-e14 --apply --repo owner/repo
jx campaign status onebackend-v3-e14
jx campaign events onebackend-v3-e14
```

State is stored at `.jx/campaigns/<name>.json` and is ignored by git.

## Slot Model

Each slot is an independent lane with an issue, branch, worktree path, host id,
agent kind, status, and optional PR fields. The current MVP uses these statuses:

- `planned`: tick has identified the next issue for the lane in dry-run mode.
- `worktree_created`: apply mode created or reused the replacement worktree.
- `agent_working`: seed mode found an existing worktree for the lane.
- `pr_detected`: `gh pr list --head <branch>` found an open PR.
- `advanced`: the previous issue in the lane was completed and the lane moved on.
- `blocked`: deterministic detection or worktree creation failed.

`tick` is safe to run every minute. Repeated PR detections update the same slot
state, existing worktree paths are reused, and dry-run mode never writes state.

`parallelism` controls how many live lanes should exist while unassigned issues
remain. Total `.slots` can exceed `parallelism` after the first advancement
because completed lane records remain as audit history.

## Canonical State & Sync (Pass 1)

Because the campaign state is a single JSON file (`.jx/campaigns/onebackend-v3-e14.json`),
all five OneBackend-v3 checkouts must stay in sync. The chosen canonical copy lives on
`uitestserver`:

```
/home/developer/OneBackend-v3/.jx/campaigns/onebackend-v3-e14.json
```

### Sync script

A small helper keeps the five copies identical:

```sh
scripts/campaign_sync.sh status          # show drift
scripts/campaign_sync.sh push --dry-run  # preview
scripts/campaign_sync.sh push            # copy canonical to the other four hosts
scripts/campaign_sync.sh pull optiplex-xe2-local --dry-run  # preview after a real --apply
scripts/campaign_sync.sh pull optiplex-xe2-local            # promote that host's JSON to canonical
scripts/campaign_pr_status.sh            # show open PRs for current non-advanced lanes
scripts/campaign_lane_status.sh          # show agent session/log/worktree activity
```

If the campaign was initially seeded with only the current lanes, expand the
canonical issue cursor before the first real apply:

```sh
scripts/campaign_set_issues.sh --issues 1025..1153 --dry-run
scripts/campaign_set_issues.sh --issues 1025..1153
scripts/campaign_sync.sh push --dry-run
scripts/campaign_sync.sh push
```

For `onebackend-v3-e14`, the authoritative issue cursor was derived from
GitHub issues labeled `epic:E14` and `area:animals`: 129 issues, `1153..1025`
in descending execution order.

### Observation loop

The scheduler/Grok operator should use the thin observation wrapper, not reimplement
campaign logic in a prompt:

```sh
scripts/campaign_observe.sh                  # sync check + dry-run ticks on all runnable hosts
scripts/campaign_observe.sh --only testserver # one host, useful during smoke tests
```

`campaign_observe.sh` never runs `tick --apply`. It checks sync drift, prints explicit
GitHub PR visibility for the current non-advanced lanes, previews the canonical push,
runs host-scoped `jx campaign tick --dry-run --host-id <host>` on the runnable hosts,
then prints canonical status and events.

Use `campaign_lane_status.sh` alongside the observer while agents are still working.
It does not mutate state; it only reports tmux sessions, log freshness/exit markers,
and local git change counts for the active lanes.

The definitive host → path map is embedded in the script (and duplicated in the table below
for documentation). Run the sync tool from a control machine that can SSH to all five
hosts; it treats the `uitestserver` JSON as the remote canonical source. Run it before and
after observation or apply steps so that every `jx campaign tick --host-id <host>` sees a
fresh, consistent view.

### Current sync map

| SSH host            | JSON path                                                            | Notes                     |
|---------------------|----------------------------------------------------------------------|---------------------------|
| uitestserver        | `/home/developer/OneBackend-v3/.jx/campaigns/onebackend-v3-e14.json` | Canonical source          |
| testserver          | `/Users/developer/OneBackend-v3/.jx/campaigns/onebackend-v3-e14.json` | Runnable                  |
| milcmini            | `/Users/milc/Documents/GitHub/OneBackend-v3/.jx/campaigns/onebackend-v3-e14.json` | Runnable      |
| optiplex-xe2-local  | `/home/milc/Work/OneBackend-v3/.jx/campaigns/onebackend-v3-e14.json` | Runnable                  |
| ideapad             | `/home/ideapad/Work/OneBackend-v3/.jx/campaigns/onebackend-v3-e14.json` | Synced for visibility  |

### Safe lifecycle (once real --apply begins)

1. On the control machine: `campaign_sync.sh status`
2. On the target host: `jx campaign tick onebackend-v3-e14 --apply --host-id <host> ...`
3. On the control machine: `campaign_sync.sh pull <host> --dry-run`
4. On the control machine: `campaign_sync.sh pull <host>` (validates the target JSON, backs up canonical, then brings the result back as new truth)
5. On the control machine: `campaign_sync.sh push --dry-run`
6. On the control machine: `campaign_sync.sh push` (propagates the new truth)

This makes every state mutation explicit and reviewable — exactly what is required before
productionizing the 1-minute scheduler loop. Sync validation checks campaign identity,
version, configured parallelism, and current lane count; it must not require total
slot count to stay at 13 because the JSON is also the audit log for all advanced lanes.
