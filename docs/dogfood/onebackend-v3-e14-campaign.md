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
- `scripts/campaign_lane_status.sh`
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
