# Reflection

`jx reflect` is a **retrospective** report over the durable orchestration
record. Where `jx portfolio summary` is a *live* snapshot of what is running
right now, reflection looks *backward* over persisted tasks and session
observations and answers "how did past runs actually go?"

It exists because launching work is only half of orchestration: a run isn't
auditable unless its outcome and observations make it back into the record.
Reflection surfaces exactly where that loop held and where it broke.

## Command

```sh
jx reflect [--run-gap-minutes 30] [--stale-running-minutes 60] [--json]
```

- `--run-gap-minutes` — launch-time gap that starts a new run cluster (default 30).
- `--stale-running-minutes` — age past which a `running` task with no update is
  treated as stale/stuck (default 60).
- `--json` — emit the full structured report instead of tables.

## What it reports

**Runs.** Tasks are clustered into runs by launch-time proximity. Each run shows
its time window, task count, the agent and status breakdown, and how many
session observations fall within its window. A run with zero observations is
flagged `BLIND` — work was launched but nothing was ever observed about it.

**Lifecycle health.** Status totals, a terminal-state count
(`completed`/`stopped`/`failed`), and the list of `running` tasks that have gone
stale (no update within `--stale-running-minutes`). Stale-running tasks are the
signature of "launched into the dark": dispatched, but their terminal state
never came back.

**Observation coverage.** Total observations and a per-agent breakdown (count,
distinct hosts, time window). This is how you confirm an agent was actually
observed while it ran, versus merely launched.

**Attribution gaps.** Observations whose `agent_name` is blank even though their
tmux `session_name` encodes the agent as a trailing `_<agent>` segment
(e.g. `jx_<project>_task_<hash>_claude`). These are a *recoverable* capture
defect — the agent is knowable from the session name and should be backfilled.
Bare shell sessions (non-`jx` names) legitimately carry no agent and are not
counted.

## Reading the output

- **Blind runs** + **stale-running tasks** together mean the observation /
  heartbeat path was not feeding the record during those runs. The fix is on
  the launch path (route status transitions and heartbeats through
  `JX.Workspace`), not in reflection itself.
- **Attribution gaps** point at the capture path: when a session name encodes
  the agent, `agent_name` should be populated from it.

## API

Reflection is reached through the policy boundary:

```elixir
{:ok, report} = JX.Workspace.reflect(run_gap_seconds: 1800, stale_running_seconds: 3600)
```

The query layer is `JX.Reflection`, which returns plain maps so callers (CLI,
daemon, Jido actions) can render tables or JSON.
