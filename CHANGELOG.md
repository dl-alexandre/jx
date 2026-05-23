# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.0.1] - 2026-05-12

### Changed

- Publish the Hex package as `jido_orchestrator` while preserving the `jx` CLI,
  OTP app, and module namespace.
- Add Rust launcher build and bundle packaging to the GitHub release workflow.

## [0.1.0] - 2026-05-11

### Added

- Initial release of jx, an agent-facing TUI and orchestrator for durable SSH/tmux-backed work sessions.
- 180+ CLI commands covering sessions, fanout, orchestration, CI watches, Google Meet integration, approvals, delegations, and runtime management.
- Durable workspace primitives: hosts, projects, tasks, session inventory, profiles, watches, notifications, and heartbeats.
- Session management: SSH/tmux discovery, session observation, remote session probing, and session reconciliation.
- Orchestration: Jido-powered agent runtime, operation policy, execution tracking, planner with continuation playbooks, and heartbeat monitoring.
- Delegation system: create, assign, start, complete, review, and gather evidence for delegated work packets.
- CI integration: watch PRs, digest CI runs, and gate promotions with preflight checks.
- Google Meet integration: session creation, join planning, real-time audio bridge, transcription, and artifact export.
- Call handoffs: structured operator-to-agent handoffs with decisions and follow-ups.
- Safe actions registry with execution audit trail.
- Portfolio summaries and project briefs.
- Hex package with full ExUnit coverage (531 tests).
- Burrito-powered standalone binaries for macOS (ARM64/Intel) and Linux (x86_64).
- Homebrew formula support.
- 17 documentation pages covering concepts, orchestration, safety policy, session profiles, and usage modes.

[0.0.1]: https://github.com/dl-alexandre/jido_orchestrator/releases/tag/v0.0.1
[0.1.0]: https://github.com/dl-alexandre/jido_orchestrator/releases/tag/v0.1.0
