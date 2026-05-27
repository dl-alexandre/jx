# Campaigns

`jx campaign` manages PR-gated worktree campaigns as file-backed slot state.
It is intentionally thin: GitHub PRs are detected with `gh`, git worktrees
remain the workspace source of truth, and campaign state only tracks slots,
issue cursors, PR links, and events.

The campaign scope is the full issue/PR sequence configured in `issues`. The
configured number of parallel slots (e.g. 13) are only the *current* live lanes;
they are not the campaign boundary. As lanes advance, historical `advanced`
slot records stay in the JSON and replacement lane records are appended.

## Commands

```sh
jx campaign init <name> --issues <range-or-list> --parallelism <n> [--agent-mix ...]
jx campaign seed <name> --from-existing-worktrees --branch-prefix <prefix>
jx campaign tick <name> [--dry-run|--apply] [--repo owner/repo] [--host-id <id>]
jx campaign status <name>
jx campaign events <name>
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

## Canonical State & Multi-host Sync

When a campaign spans multiple machines, the single JSON file
(`.jx/campaigns/<name>.json`) must be kept in sync across all participating
hosts. One machine is designated as the *canonical* source. A small set of
helper scripts (typically living alongside the campaign) are used to:

- Detect drift between copies
- Push updates from the canonical copy to the others
- Pull a mutated copy from a runnable host back to canonical after an apply step

The sync helpers are intentionally kept outside the core `jx` binary so that
each deployment can implement its own transport (rsync over SSH, git, etc.)
while still using the same `jx campaign` primitives.

See the scripts that accompany a real deployment for concrete examples of
drift detection, host-scoped `jx campaign tick --host-id <id>`, and the
safe "pull → validate → promote → push" lifecycle.

## Observation & Operator Loops

A typical automated or human-supervised loop does the following (in order):

1. Ensure all hosts see a consistent view of the campaign JSON.
2. Run `jx campaign tick --dry-run --host-id <host>` on every runnable host.
3. Report PR status for currently active lanes.
4. Report local session / log / git activity for agents that are working.
5. Only after review: run the same tick commands with `--apply` (still scoped
   to a single `--host-id`).

The core `jx` tool never decides when to run `--apply` or which host to target;
that decision belongs to the operator (human or scripted) that has visibility
across all machines.

## Real-world Deployment Example

For a concrete, production use of the campaign system (including the exact
sync scripts, host map, observation loop, and Grok operator prompts used for
one large campaign), see:

- `docs/dogfood/campaign_grok_operator.md`
- `docs/dogfood/campaign_grok_pr_guardian.md`
- The operational scripts under `scripts/campaign_*.sh` in that deployment

These files contain deployment-specific paths, host names, repository details,
and runbooks. They are intentionally kept outside the generic documentation
so that the public `jx` docs remain reusable across organizations.

## Post-Advance / Merge Phase

When all unassigned issues have been processed, every lane eventually reaches `status: "advanced"`.
At this point the campaign shifts from "create new work + open PRs" to "rebase, resolve conflicts, and merge the existing PRs".

### New Tools for the Merge Phase

- `scripts/campaign_lane_status.sh --advanced` (and `--all`)
  - Now reports on completed lanes.
  - Explicitly surfaces the "MISSING DIRECTORY" case (when a worktree was removed after the lane advanced).

- `scripts/campaign_merge_assist.sh --host <name>`
  - Primary tool for this phase.
  - Consumes the canonical JSON + per-host conflict data.
  - Emits a complete, copy-pasteable runbook with:
    - Correct `git rebase origin/develop` commands (with special parent-repo handling for hosts whose worktrees have been removed).
    - Post-rebase `gh pr review` / `gh pr merge --auto` suggestions.
    - Hygiene steps (sync, prune stale registrations, etc.).

Always start any merge-assistance session with `./scripts/campaign_sync.sh status`.

### Special Cases

**Hosts with aggressive worktree cleanup**: The physical worktree directories for many advanced lanes may no longer exist on disk, even though `git worktree list` in the parent still shows registrations. The merge-assist script detects this and emits commands that operate from the parent checkout.

### Operator Responsibilities

The Grok operator **never** performs rebases, commits, pushes, or merges itself.
Its job is to produce accurate, safe, host-specific command blocks that a human (or a short-lived fix-up agent session) can execute.

When a campaign enters this phase, update the standing Grok prompt (`docs/dogfood/campaign_grok_operator.md`) with a "Merge Assistance for Advanced Lanes" section.

For a concrete long-running "drive-to-zero" instance (E14 on OneBackend-v3, 129 advanced slots), the operational tracker system lives in `/tmp/e14-merge-tracker.*` + `refresh_e14_tracker.py` + enhanced `--still-open-json` support on `campaign_merge_assist.sh`. See `docs/dogfood/onebackend-v3-e14-campaign.md` for the full playbook, current live count (72 as of latest), and the self-sustaining process used until the open PR count hits exactly 0. The same patterns (read-only runbooks, confirmation carry-over, fewest-first batching) can be reused for future campaigns.
