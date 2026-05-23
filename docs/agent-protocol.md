# Agent Protocol (Draft)

This document describes a lightweight protocol that external agents (Claude, Cursor, Aider, Continue.dev, OpenDevin, etc.) can use to interact with `jx`.

The goal is to let agents:
- Report observations from their terminal sessions
- Request approvals for actions
- Hand off tasks
- Query current state (what's blocked, what needs review, etc.)

## Guiding Principles

- Simple to implement from any agent runtime (stdio, JSON-RPC, or HTTP)
- Human operators can always inspect and override
- Everything is append-only and auditable
- Works over SSH/tmux as the primary transport

## Proposed Command Surface (initial)

```bash
# Report an observation from the current session
jx agent report --session <id> --kind observation --text "..."

# Request approval for a planned action
jx agent request-approval \
  --action "git push --force" \
  --reason "Need to overwrite remote history after rebase" \
  --risk high

# Hand off a task to another agent or human
jx agent handoff --to operator --summary "..." --context-ref <task-id>

# Query current work state for this project
jx agent status --project my-app --json

# Acknowledge that a human has reviewed something
jx agent ack --ref <approval-id>
```

## Data Shapes (JSON)

All commands above should also support `--json` input/output for machine-to-machine use.

Example observation payload:

```json
{
  "type": "observation",
  "session_id": "sess_abc123",
  "timestamp": "2026-05-23T12:34:56Z",
  "kind": "terminal",
  "content": "Tests are now passing after the rebase.",
  "metadata": {
    "exit_code": 0,
    "duration_ms": 12400
  }
}
```

## Transport Options (in order of priority)

1. **Stdio / Subprocess** — Easiest for agents that can spawn `jx`
2. **Local Unix socket** (future)
3. **HTTP/WebSocket** (optional, behind `jx serve` or a small sidecar)
4. **SSH + `jx` over the existing transport**

## Next Steps (for implementation)

- Define the minimal command set in `lib/jx_cli/cli/agent.ex`
- Add structured types under `JX.AgentProtocol.*`
- Provide example prompt snippets that agents can include in their system prompts

This protocol is intentionally small at first. We can grow it once real agents start using it.
