# jido_orchestrator

`jido_orchestrator` is the Hex package for `jx`, a durable terminal control
plane for agent orchestration.

`jx` does not replace Codex, Claude, opencode, tmux, SSH, or CI. It gives them
an operational record: what sessions exist, what changed, what is blocked, what
needs approval, and which actions are safe to take next.

## Install From Hex

```bash
mix escript.install hex jido_orchestrator
jx --help
```

GitHub release bundles are published at:

```text
https://github.com/dl-alexandre/jido_orchestrator/releases
```

## First Run

Create local state and register the local machine as an orchestration host:

```bash
jx init
jx host add local --local --workspace /tmp/jx
jx host doctor local --agent codex
```

Register a repository and launch bounded agent work:

```bash
jx project add my-app --host local --repo /path/to/my-app
jx assign my-app "Investigate the failing import flow" --agent codex
```

Inspect live work and orchestrator health:

```bash
jx tui
jx sessions queues --json
jx project brief my-app --json
jx orchestrator health --json
```

Run orchestration in dry-run mode before allowing it to execute actions:

```bash
jx orchestrator start --dry-run --replace
jx orchestrate step --json
```

## What It Is For

Use `jx` when useful agent state is spread across terminal scrollback, remote
tmux panes, local branches, CI pages, and chat context.

It persists:

- hosts, projects, tasks, worktrees, and runtime environments
- tmux, SSH, and process-backed session inventory
- compact terminal observations, profiles, queues, and watches
- handoffs, wake triggers, CI watches, notifications, and timelines
- approvals, safe actions, leases, assignments, and orchestrator heartbeats

The durable record is the product. A session can move, block, finish, or need
input, and `jx` can still compare the latest observation against saved
objectives before surfacing or executing work.

## Safety Model

`jx` separates observation from execution. Inspection, queueing, profile updates,
and dry-run planning are low-risk surfaces. Destructive, public, ambiguous, or
externally visible actions are held behind approval and policy gates.

Core invariants:

- SSH is transport, not identity.
- One task maps to one isolated workspace or session.
- Append-only evidence is preferred over mutable state.
- Adapters remain replaceable.
- Safety is enforced by code and policy, not prompt convention.

## Documentation

HexDocs are the canonical long-form reference:

```text
https://hexdocs.pm/jido_orchestrator
```

Source pages live under `docs/hexdocs/` and are grouped by `mix.exs`.

Useful entry points:

- [Overview](docs/hexdocs/overview.md)
- [Installation](docs/hexdocs/installation.md)
- [Concepts](docs/hexdocs/concepts.md)
- [CLI reference](docs/hexdocs/cli.md)
- [Orchestration](docs/hexdocs/orchestration.md)
- [Safety policy](docs/hexdocs/safety_policy.md)
- [Publishing](docs/hexdocs/publishing.md)

Generate docs locally:

```bash
mix deps.get
mix docs
```

## Naming Contract

- Hex package: `jido_orchestrator`
- GitHub repository: `dl-alexandre/jido_orchestrator`
- Installed executable: `jx`
- OTP app: `:jx`
- Elixir modules: `JX.*`

## Development Checks

Run the release-facing checks:

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

For local dogfooding, build the escript with `mix jx.build` (see below).

Build the local dogfood escript (recommended for contributors):

```bash
mix jx.build          # or: MIX_ENV=prod mix escript.build
bin/jx --help         # auto-uses ./jx if present (no env var needed)
```

After building, `bin/jx` (and `./jx`) will prefer the fast, consistent escript binary.
Use `JX_USE_MIX=1 bin/jx ...` only if you need to run against the live source during development.

Build the Rust launcher:

```bash
cargo fmt --manifest-path crates/jx-launcher/Cargo.toml -- --check
cargo build --manifest-path crates/jx-launcher/Cargo.toml --release --locked
```
