# Dogfooding jx

`jx` is a durable terminal control plane for agent orchestration — it gives
Codex / Claude / opencode / tmux / SSH / CI work *one operational record*: what
sessions exist, what changed, what's blocked, what needs approval, and which
actions are safe next. It's a CLI + OTP app backed by a local SQLite database.

---

## The handoff format

You were handed a `jx` **escript** — a single executable file containing all the
compiled BEAM bytecode and native NIFs (tzdata, exqlite). It is **not** a
zero-dependency binary.

**Runtime requirement:** Erlang/OTP 28.4.2. The escript bundles the Elixir
application code, but the Erlang runtime (`escript` / `erl` / erts) must be
present on the executing machine.

The repo's `.tool-versions` pins the exact versions:
- `erlang 28.4.2`
- `elixir 1.19.5-otp-28`

With `mise` or `asdf`, installing the toolchain is a single command after
cloning the repo.

> **Note on the "standalone binary" dream:** A truly self-contained executable
> (no Erlang runtime at all on the target machine) was prototyped via
> [Burrito](https://github.com/burrito-elixir/burrito). That path is currently
> blocked because the Burrito 1.5 wrapper requires Zig **0.15.2** and the
> development machine has 0.16.0. The repo's `.tool-versions` now pins the
> correct Zig version; once a developer has it active, Burrito builds can
> proceed (and any subsequent macOS SDK linker issues can be addressed).
> Tracked as a bug to fix (see GitHub issues). Until resolved, the escript +
> one-command toolchain via mise/asdf is the reliable dogfood handoff.

---

## 1. Install the toolchain (mise or asdf)

**Recommended: [mise](https://mise.jdx.dev)** (fast, simple, works on macOS/Linux):

```bash
# Install mise (one-time)
curl https://mise.run | sh
# or: brew install mise

# Clone the repo (needed for .tool-versions + context)
git clone https://github.com/dl-alexandre/jido_orchestrator.git
cd jido_orchestrator

# One command installs exactly the pinned versions
mise install

# Verify
erl -version        # should report something like "Erlang (SMP,ASYNC_THREADS) (BEAM) emulator version 15.x"
elixir --version    # Elixir 1.19.5 (compiled with Erlang/OTP 28)
```

**Alternative: [asdf](https://asdf-vm.com):**

```bash
asdf plugin add erlang
asdf plugin add elixir
asdf install
```

Both tools read `.tool-versions` from the repo root and install the exact
Erlang/OTP and Elixir the project is tested against.

---

## 2. Install the jx escript

You received a file named `jx` (≈8–9 MB). Make it executable and put it on
your PATH:

```bash
chmod +x jx
mv jx /usr/local/bin/        # or ~/bin, or any directory on $PATH
jx --help
```

On macOS, Gatekeeper may block it on first run ("cannot verify developer").
Allow it once:

```bash
xattr -d com.apple.quarantine $(which jx)
```

State lives in `~/.jx/jx.db` (override with the `JX_DB` env var). It's a local
SQLite file — safe to delete if you want a clean slate.

---

## 3. First run

```bash
jx init                                          # create local state + run migrations
jx host add local --local --workspace /tmp/jx    # register this machine as a host
jx host doctor local --agent codex               # check the host can run agents
```

Register a repo and launch bounded agent work:

```bash
jx project add my-app --host local --repo /path/to/some/git/repo
jx assign my-app "Investigate the failing import flow" --agent codex
```

Inspect live work:

```bash
jx tui                                # interactive dashboard
jx sessions queues --json
jx project brief my-app --json
jx orchestrator health --json
```

Try the orchestrator in dry-run before letting it execute anything:

```bash
jx orchestrator start --dry-run --replace
jx orchestrate step --json
```

---

## 4. What to actually exercise

The point of dogfooding is to hit the surfaces that matter, not just `--help`:

- **Lifecycle** — `init` → `host add` → `project add` → `assign`. Does a task
  get its own isolated workspace/session?
- **Observation** — `jx tui`, `jx sessions queues`, `jx project brief`. Does the
  durable record match reality after a session moves, blocks, or finishes?
- **Approvals / safety** — trigger something that needs approval (destructive or
  ambiguous action) and confirm it's *held*, not executed. Inspection and
  dry-run should never be gated; destructive/public actions always should be.
- **Agents** — point it at a real repo and `assign` actual work to `codex` (or
  `claude` / `opencode` if you have them). Watch it through `jx tui`.
- **Recovery** — kill a session mid-flight, restart, see if `jx` reconciles.

You don't need an agent runner installed to test `init` / `host` / `project` /
inspection — only the `assign` + orchestration flows need one.

---

## 5. Known rough edges (so you don't file these as surprises)

- **Flaky test** — the suite has 1 known non-deterministic test failure (~1 in
  1241, around the approval/timing path). Not user-facing; mentioned for honesty.
- **Version string** — `mix.exs` says `0.0.1` while some package artifacts say
  `0.1.x`. Cosmetic inconsistency, being sorted out.
- **Burrito blocked** — the experimental self-contained binary path (true
  zero-dependency, no OTP runtime required) is currently blocked because
  Burrito 1.5 requires Zig 0.15.2 and the dev machine has 0.16.0.
  `.tool-versions` now pins the correct Zig; once active, builds can proceed
  and any SDK/linker follow-ups can be addressed. Tracked as a bug.
- This is **pre-1.0 dogfood-grade software**. Expect sharp corners; that's the
  point of you being here.

---

## 6. How to report back

For anything that breaks, surprises you, or feels wrong, capture:

- the exact `jx` command you ran
- what you expected vs. what happened
- relevant output — most commands take `--json`, which is the most useful form
- `jx version` and your OS

> **TODO (handoff owner): fill in where reports go** — GitHub issues on
> `dl-alexandre/jido_orchestrator`, a Slack channel, or direct to you.

---

## Appendix — Producing a handoff escript (or local dogfood binary)

From a clean checkout with the correct toolchain (`.tool-versions` satisfied):

```bash
mix deps.get
mix jx.build          # shorthand for MIX_ENV=prod mix escript.build
```

The resulting `jx` file at the project root (~7–8 MB) is the handoff / dogfood
artifact. It runs on any machine with Erlang/OTP 28 on the PATH.

After building, `bin/jx` (and `./jx`) automatically prefers the local escript:

```bash
bin/jx sessions queues
bin/jx tui
```

Only use `JX_USE_MIX=1 bin/jx ...` when you need to run against the live
source tree during active development of jx itself.

The escript is the **primary way** to get a real, consistent `jx` CLI for
dogfooding on your own work.

Canonical reference docs live in `docs/hexdocs/` and at
https://hexdocs.pm/jido_orchestrator.
