# Architecture Evolution Plan for jx

This document captures targeted architectural improvements based on deep review of the current system.

---

## Current State (as of May 2026)

- Single OTP application
- Heavy use of Jido for orchestration
- Ecto + SQLite for persistence
- CLI, TUI, Campaigns, Safety all in one codebase
- Early Agent Protocol work started (`JX.CLI.Agent`)

---

## Proposed Target Architecture

### High-Level Layers (Recommended)

```
┌─────────────────────────────────────────────────────────────┐
│                    Agent Adapters Layer                     │
│   (Claude, Cursor, Aider, Continue, Custom)                 │
└───────────────────────────────┬─────────────────────────────┘
                                │
┌───────────────────────────────▼─────────────────────────────┐
│                   Agent Protocol Layer                      │
│   JX.Agent.Protocol (behaviour)                             │
│   Adapters: Stdio, JSON-RPC, HTTP                           │
└───────────────────────────────┬─────────────────────────────┘
                                │
┌───────────────────────────────▼─────────────────────────────┐
│                    Core Domain Services                     │
│   - JX.Orchestration.*                                      │
│   - JX.Safety.*                                             │
│   - JX.Session.*                                            │
│   - JX.Campaign.*                                           │
└───────────────────────────────┬─────────────────────────────┘
                                │
┌───────────────────────────────▼─────────────────────────────┐
│                      Event Bus                              │
│   (Jido Signals / Broadway / GenStage)                      │
│   Events: ObservationReceived, ApprovalRequested, etc.      │
└───────────────────────────────┬─────────────────────────────┘
                                │
┌───────────────────────────────▼─────────────────────────────┐
│              Persistence & Projections                      │
│   - Event Sourcing for key aggregates                       │
│   - Pluggable backends (SQLite, Postgres)                   │
│   - CQRS-lite (Commands → Events → Projections)             │
└───────────────────────────────┬─────────────────────────────┘
                                │
┌───────────────────────────────▼─────────────────────────────┐
│                    Interface Layer                          │
│   - CLI (`jx_cli`)                                          │
│   - TUI (`jx_tui`)                                          │
│   - Future: REST / WebSocket / Web Dashboard                │
└─────────────────────────────────────────────────────────────┘
```

---

## Recommended Umbrella Structure

```
jido_orchestrator/          (Umbrella root)
├── apps/
│   ├── jx_core/            # Sessions, Persistence, Safety, Orchestration
│   ├── jx_campaign/        # Campaign Manager + workflows
│   ├── jx_agent/           # Agent Protocol + Adapters
│   ├── jx_cli/             # Command Line Interface
│   ├── jx_tui/             # Terminal UI
│   └── jx_release/         # Release packaging (escript, launcher, Burrito)
├── apps/
│   └── jx/                 # (optional) Main umbrella aggregator
├── crates/
│   └── jx-launcher/        # Rust launcher (keep as-is)
└── mix.exs                 # Umbrella mix file
```

**Benefits**:
- Clear ownership and testing boundaries
- Can release some packages independently later
- Easier to onboard contributors to specific areas

---

## Priority Order (Architecture Work)

1. **Agent Protocol Layer** (highest leverage right now)
   - Finish `JX.Agent.Protocol` behaviour
   - Implement first adapter (stdio)
   - Wire CLI commands to the protocol

2. **Introduce Event Bus**
   - Define core domain events
   - Use Jido signals as the starting point (low friction)

3. **Umbrella Refactor**
   - Start with extracting `:jx_agent` and `:jx_campaign` as separate apps
   - Do this incrementally (don't big-bang)

4. **Persistence Evolution**
   - Make backend pluggable (start with config switch between SQLite/Postgres)
   - Add Event Sourcing for Campaigns first (highest value)

5. **Observability**
   - Add OpenTelemetry hooks
   - Structured events for metrics

---

## Next Concrete Steps

- [x] Define `JX.Agent.Protocol` behaviour
- [x] Wire `jx agent` commands through the `JX.Workspace` policy boundary
      (no longer returns fabricated data)
- [ ] Refactor `JX.CLI.Agent` to dispatch via adapters implementing the protocol
- [ ] Create first domain events (`ObservationReceived`, `ApprovalRequested`)
- [ ] Document bounded contexts in code

---

## Implementation status (reality check)

The layered/umbrella/event-sourcing sections above are **aspirational design**, not
shipped structure. As of 2026-05-23 the only concrete code changes are:

- `jx agent request-approval` and `jx agent handoff` create durable
  `approval_items` (sources `agent`, kinds `agent_request` / `agent_handoff`)
  via the new `JX.Workspace.create_approval/1`, reusing the existing dedupe +
  routing + operational-event pipeline.
- `jx agent status` reports real counts from `approval_summary`, `list_agents`,
  and `list_delegations`.
- `jx agent report` is **deliberately not implemented**: there is no durable
  freeform-observation primitive yet. Delegation evidence requires
  `command`/`cwd`/`exit_status` (execution evidence), and session observations
  are snapshot-based. The command returns an explicit error rather than
  fabricating an observation id. Building a real observation primitive (schema +
  migration + Workspace function) is the next concrete unit of work for `report`.

The Event Bus, CQRS, pluggable persistence, and umbrella split remain unstarted —
they should not be scaffolded until a specific feature demands them.

---

*This is a living document. Last updated: 2026-05-23*
