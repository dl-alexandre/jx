# Branding Boundary

The public identity is:

- CLI: `jx`
- product: `jx`
- Hex package: `jido_orchestrator`
- tagline: durable agent orchestration from the terminal

The implementation uses:

- OTP app: `:jx`
- modules: `JX.*`
- primary CLI: `jx`

## Why This Boundary

`jx` is short, scriptable, and visually distinct from generic agent commands.
It also describes the actual user surface better than an IDE name: terminal
operations for sessions, watches, queues, handoffs, and policy-gated actions.

## Current State

Current state:

- Hex package distribution uses `jido_orchestrator`; documentation and CLI
  examples use `jx` as the public name.
- `bin/jx` is the local wrapper.
- `mix jx.build` emits the local `./jx` launcher.
- `mix escript.build` remains the Hex-style escript build.
- `JX.*` is the stable module namespace.
- runtime defaults use `~/.jx`.
