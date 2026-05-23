# jx Roadmap

This document captures the current direction and major initiatives for `jido_orchestrator` / `jx`.

---

## Vision

`jx` is the durable operating system layer for agentic coding.

It provides the same kind of operational backbone to AI agents that good engineering teams get from CI, git workflows, runbooks, and approval processes — but designed for agents instead of humans.

Positioning: **"tmux + git + CI + approvals for agents"**

---

## High-Impact / Quick Wins (Current Focus)

| Item | Status | Notes |
|------|--------|-------|
| Stronger README with hero example & clear positioning | In progress | New version written May 2026 |
| One-command installer (`curl \| sh`) | In progress | Placeholder script created |
| Official Docker image (`ghcr.io/...`) | In progress | Basic Dockerfile created |
| GitHub topics & discoverability | Pending | Need to add in repo settings + README badges |
| Improved CHANGELOG and release hygiene | Done | 0.1.0 section prepared, CI aligned to OTP 28 |

---

## Core Product

- **Agent Protocol** — Lightweight stdio/JSON interface so external agents can report observations, request approvals, and hand off work. (Design doc started)
- **Campaign System Polish**
  - Pretty `jx campaign status` with progress bars
  - Campaign templates (`refactor`, `bug-bash`, `feature`)
  - Auto-generated PR descriptions from observations
- **Safety & Observability**
  - Action signatures / intent declarations
  - Granular policy rules
  - `jx audit export --format json/csv`
- **TUI Improvements**
  - Vim-style navigation
  - Filters (by agent, project, status)
  - Better color support + themes

---

## Ecosystem & Adoption

- First-class guides and prompt packs for:
  - Claude / Claude Code
  - Cursor
  - Aider
  - Continue.dev
  - OpenDevin
- Stronger multi-host / remote workflows
- `jx ssh <host> <session>` with context injection
- (Future) Optional web dashboard (Phoenix LiveView)

---

## Technical / Long-term

- Finish standalone binary (Burrito + Zig macOS linker issues)
- Telemetry + OpenTelemetry export
- Plugin system for custom transports
- Comprehensive contract tests for the public Workspace API
- Jido-native actions / behaviors so `jx` can be controlled from within Jido agents

---

## Suggested 4–6 Week Focus (as of May 2026)

1. **Release 0.1.0** — Solid CI, clean docs, good README, installer + Docker ready
2. **Agent Protocol v0** — Minimal command surface + prompt snippets for major agents
3. **Campaign UX** — Make the new campaign system delightful to use
4. **Discoverability** — Topics, badges, better hero content
5. **Standalone binary** — Unblock Burrito so we can ship real zero-dependency binaries

---

This roadmap is living. Major items will be broken into GitHub issues or project boards as they are scheduled.

Last updated: 2026-05-23
