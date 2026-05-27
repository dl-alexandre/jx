# Installation

jx is distributed on Hex as `jido_orchestrator`. The package installs the `jx`
executable.

## Hex

Install the escript:

```bash
mix escript.install hex jido_orchestrator
```

Then run:

```bash
jx status
```

## Local Development

Install dependencies and run tests:

```bash
mix deps.get
mix test
```

Run the wrapper through Mix:

```bash
bin/jx status
```

## Build The Local Launcher

Build and smoke-test the local `./jx` launcher:

```bash
mix jx.build
```

This creates a `jx` executable at the project root and verifies:

```bash
./jx --version
./jx help
JX_USE_MIX=1 bin/jx help
```

To build the Hex-style escript directly, run:

```bash
mix escript.build
```

## Database

By default, jx stores state in:

```text
~/.jx/jx.db
```

Override it for a single command:

```bash
jx --db /tmp/jx.db sessions queues
```

Or through the environment:

```bash
JX_DB=/tmp/jx.db jx sessions queues
```

## Required Runtime Tools

The local and SSH adapters expect standard command-line tools:

- `git`
- `tmux`
- `ssh` for remote hosts
- any configured agent binary, such as `codex`, `claude`, or `opencode`
- `acpx` when using `--transport acpx`

Use host doctor before assigning real work:

```bash
jx host doctor local --agent codex
jx host doctor local --agent codex --transport acpx
```
