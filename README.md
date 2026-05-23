# jx — The Durable Backbone for Agentic Coding

[![License](https://img.shields.io/badge/license-Apache_2.0-blue.svg)](LICENSE)
[![Elixir](https://img.shields.io/badge/elixir-%3E%3D1.19-8e4b9c.svg)](https://elixir-lang.org)
[![Hex.pm](https://img.shields.io/hexpm/v/jido_orchestrator?color=8e4b9c)](https://hex.pm/packages/jido_orchestrator)

**jx** is the missing operating system layer for agents that live in terminals.

It does **not** replace Claude, Cursor, Codex, Aider, tmux, SSH, or CI.  
It gives them something they currently lack: **durable, queryable, auditable state** across sessions, hosts, worktrees, and time.

Think of it as **tmux + git + approvals + CI context**, but built for agents instead of humans.

---

## The Problem

Agents today are stateless and amnesiac:

- They lose context the moment a tmux pane is closed or a worktree is switched.
- They have no shared memory of what was observed, approved, or blocked across machines.
- They cannot safely coordinate when multiple agents (or multiple instances of the same agent) are working on the same codebase.
- Reviewers and operators have almost no visibility into what the agent actually did.

**jx** fixes this by turning the terminal into a first-class, persistent environment for agent work.

---

## What jx Gives You

- Persistent hosts, projects, tasks, worktrees, and sessions
- Compact, structured observations from tmux/SSH panes
- Approval gates and safe-action policies before destructive or public actions
- Cross-host coordination (including the new `jx campaign` system for large PR-driven efforts)
- Full audit trail of decisions, handoffs, CI watches, and heartbeats
- A powerful TUI (`jx tui`) for operators to stay on top of everything

The durable record **is** the product.

---

## Quick Start

### Install

```bash
# Recommended (once we ship the installer)
# curl -fsSL https://get.jx.run | sh

# Current method
mix escript.install hex jido_orchestrator
jx --help
```

GitHub releases (with launcher bundles) are available at:
https://github.com/dl-alexandre/jido_orchestrator/releases

### 60-Second First Run

```bash
jx init
jx host add local --local --workspace /tmp/jx
jx host doctor local --agent codex

jx project add my-app --host local --repo /path/to/my-app
jx assign my-app "Investigate the failing import flow" --agent codex

jx tui
```

From there you can run agents with full observation, approval gates, and cross-session memory.

---

## Key Features

- **Campaigns** (`jx campaign`) — Coordinate large numbers of agent-driven PRs across multiple hosts with dry-run/apply semantics and canonical state syncing.
- **Safety by default** — Destructive, public, or ambiguous actions require explicit approval or policy approval.
- **Multi-host by design** — Works across local machines, VMs, and remote servers with consistent state.
- **Agent-friendly** — Designed so agents can report observations, request approvals, and hand off work programmatically.

---

## Documentation

Full documentation lives on HexDocs:

→ https://hexdocs.pm/jido_orchestrator

Particularly useful:
- [Concepts](docs/hexdocs/concepts.md)
- [Orchestration](docs/hexdocs/orchestration.md)
- [Safety Policy](docs/hexdocs/safety_policy.md)
- [CLI Reference](docs/hexdocs/cli.md)

---

## Positioning

`jx` is the **durable execution and coordination layer** for agentic coding workflows.

It sits *under* the LLMs and *above* the raw terminal, giving agents the same kind of operational backbone that human engineering teams get from good CI, good git hygiene, and good runbooks.

---

## Development

See `ONBOARDING.md` for contributor setup.

Run the full pre-publish gate:

```bash
mix deps.get
mix hex.audit
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix docs
mix hex.build
mix precommit
```

---

## Status

`jx` is under active development. The core is stable enough for serious dogfooding, and we're currently hardening it for a proper 0.1.0 release and Hex publication.

If you're building agent systems that live in terminals and you keep running into "the agent forgot what it was doing", `jx` is probably for you.

---

**GitHub Topics**: `ai-agents`, `agentic-coding`, `orchestration`, `tmux`, `durable-execution`, `claude`, `cursor`

(Repo maintainers: please add these in GitHub repository settings)
