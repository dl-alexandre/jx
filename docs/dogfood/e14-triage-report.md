# E14 PR Triage Report

Generated: 2026-05-23 by jx operator (picking up grok session `019e5313`).
Source: live `gh pr list` for `head:onebackend-v3- state:open` against
`MILCGroup/OneBackend-v3` + local syntax-parse and diff analysis.
**No PRs or branches were modified to produce this report** (read-only clone +
worktree only).

## Headline

55 open `onebackend-v3-*` PRs remain (down from ~82). They are **not** a set of
clean PRs awaiting a merge click. They are variable-quality agent output with
three distinct problems, and the conflicts are structural, not incidental.

## The structural problem: contention on shared registration files

Each PR adds one new "animal parity" screen and registers it the same way, so
they all edit the same few files:

| File | # of PRs touching it |
|------|---------------------|
| `lib/one_web/router.ex` | 33 |
| `lib/one_web/routes/animals.ex` | 30 |
| `lib/one_web/live/components/top_bar_component.ex` | 19 |
| `lib/one_web/route_helpers/operations_routes.ex` | 18 |
| `lib/one_web/live/components/dual_sidebar_layout.ex` | 17 |
| `lib/one/api/animals.ex` | 12 |

Only **4 of 55** PRs touch none of the contention hotspots. Consequence:
integration is **serial** — every merge rewrites `router.ex`, invalidating the
rebase of every other open PR. This cannot be parallelized across hosts the way
the campaign assumed.

## Category A — Broken, do NOT merge as-is (2)

| PR | Branch | Problem |
|----|--------|---------|
| #1281 | onebackend-v3-grok-1043 | **Deletes 4 working API functions** (`record_died_sold`, `import_reproduction_events`, `record_other_event`, `record_dnb_batch`) from `lib/one/api/animals.ex`, replacing them with the comment `# measurement parity endpoints would go here if any,` — leaves a dangling `end`; file does not parse. Also breaks `operations_routes.ex` and `routes/animals.ex`. |
| #1224 | onebackend-v3-grok-1081 | Syntax error in `lib/one/animals/field_map.ex:67` (keyword list not last in map). Rest of the PR (cow_query additions + tests) looks legitimate and is salvageable with a one-line fix. |

Recommendation: **close #1281** (regressive + broken). **Salvage #1224** (fix the
one syntax error, then treat as Category C).

## Category B — Competing rewrites of the same feature (mutually exclusive)

Multiple PRs independently rewrite the same feature surface, deleting each
other's/existing functions. They cannot all be merged; someone must pick a winner.

- **Animals Import/Export** — #1286, #1266, #1242 all rewrite
  `animals_import_export_live.ex` / `import_export.ex` (net hundreds of lines
  deleted each). Pick one, close the other two.
- **Animals Milking** — #1272 rewrites `animals_milking_components.ex` (216 lines
  deleted). Verify against any sibling milking PR before merging.

Recommendation: **product decision required** on which implementation wins per
feature; close the losers.

## Category C — Plausibly salvageable, additive new screens (~49)

Parse cleanly; net-additive (new LiveView + route + nav entry + tests). Each
needs: (1) rebase onto `develop`, (2) conflict resolution that is almost entirely
in the shared registration files above (additive, low semantic risk), (3) CI
fixes (Format/Compile/Docs/Coverage currently failing on most). Quality caveats
seen in samples: unfinished UI labels like `placeholder="???"`, `TODO`/`stub`
markers — cosmetic but indicate the screens are not production-polished.

## Recommended path forward

1. Close #1281; decide Category B winners and close losers (removes ~5 PRs).
2. Fix #1224's one-line syntax error.
3. Integrate Category C **serially** in small batches: rebase → resolve the
   router/routes/nav conflict → `mix format` + compile + targeted tests → push →
   merge → repeat. Expect to re-rebase the queue after each merge.
4. Treat the remaining count as an integration backlog, not a parallel campaign.

The autonomous "rebase-and-merge across all hosts" loop is unsafe here because
(a) at least one PR regresses working code, (b) several are duplicate features
needing a human decision, and (c) the shared-file contention forces serial
integration regardless.
