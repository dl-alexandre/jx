# Publishing

jx is published through three channels:

| Channel | Audience | Command |
|---|---|---|
| **Hex** | Elixir/OTP developers | `mix escript.install hex jido_orchestrator` |
| **GitHub Releases** | Operators that want packaged release assets | Download from the release page |
| **Burrito** | Standalone binary experiments | `BURRITO_BUILD=1 MIX_ENV=prod mix release` |

The Hex package is published as `jido_orchestrator`. It installs the `jx`
executable and keeps the OTP app name as `:jx`.

## Build Docs Locally

Install dependencies:

```bash
mix deps.get
```

Generate docs:

```bash
mix docs
```

Open:

```text
doc/index.html
```

## Package Check

Before publishing:

```bash
mix hex.audit
mix hex.build
```

Then inspect the package contents carefully.

`mix hex.audit` must run before tasks that load or start the application. It
checks for retired Hex dependencies and should be treated as a publishing gate.

## Local Development Build

For local dogfooding, use the escript:

```bash
mix escript.build
./bin/jx version
```

## OTP Release

For environments with Erlang/OTP but without Elixir:

```bash
MIX_ENV=prod mix release
```

The release is placed at:

```text
_build/prod/rel/jx/
```

This is a standard Mix release that requires an Erlang/OTP runtime.

## Burrito Release

The release definition also has Burrito targets for Darwin and Linux. Burrito is
disabled by default so normal local and CI release builds stay fast and
predictable. Enable it explicitly:

```bash
BURRITO_BUILD=1 MIX_ENV=prod mix release
```

Configured targets:

- `macos` for Darwin arm64
- `macos_intel` for Darwin x86_64
- `linux` for Linux x86_64
- `linux_aarch64` for Linux arm64

Burrito output is currently blocked because Burrito 1.5 hard-requires Zig
**0.15.2** (`Burrito.check_zig_version/0`) and the active development toolchain
has 0.16.0. The repo's `.tool-versions` now pins `zig 0.15.2` so `mise install`
or `asdf install` will provide the correct version.

Once a developer builds with the pinned Zig, any further macOS SDK / linker
issues during `Burrito.wrap/1` can be diagnosed and fixed. The release
definition still declares the targets (`macos`, `macos_intel`, `linux`,
`linux_aarch64`).

Tracked as a bug; until resolved, the reliable distribution path is
`mix escript.build` (requires Erlang/OTP 28 at runtime).

## Continuous Integration

Pushes and pull requests to `master` run `.github/workflows/ci.yml`.

The CI gate runs:

1. `mix deps.get`
2. `mix hex.audit`
3. `mix format --check-formatted`
4. `mix compile --warnings-as-errors`
5. `mix test`
6. `mix docs`
7. `mix hex.build`
8. `mix precommit`

The precommit alias is intentionally non-mutating; it checks formatting instead
of rewriting files.

## Release Workflow

### 1. Tag a Release

```bash
git tag -a v0.0.1 -m "Release v0.0.1"
git push origin v0.0.1
```

### 2. Release CI Builds Assets

Pushing a `v*` tag triggers `.github/workflows/release.yml`:

1. Audits retired Hex dependencies (`mix hex.audit`)
2. Checks Elixir and Rust formatting
3. Compiles with warnings as errors
4. Builds the Rust launcher
5. Runs the full test suite (`mix test`)
6. Builds the Hex package (`mix hex.build`)
7. Builds ExDoc docs (`mix docs`)
8. Builds the OTP release (`MIX_ENV=prod mix release`)
9. Creates a GitHub Release with `jido_orchestrator-*` release assets

The launcher bundle asset is named for the Hex package and contains the `jx`
executable, `version.txt`, and the `jx-release.tar.gz` sidecar used by the
launcher.

The release workflow currently publishes an OTP release tarball plus a Linux
x86_64 launcher bundle. It does not enable Burrito by default.

### 3. Publish Hex (Manual)

After the CI passes and the GitHub Release is created:

```bash
mix hex.publish
mix hex.publish docs
```

## Release Blockers

Do not publish to Hex or cut a release until these are resolved:

- [x] Confirm license and add a `LICENSE` file.
- [x] Confirm source repository URL for Hex links.
- [x] Confirm maintainers and organization ownership.
- [x] Confirm whether public docs should expose all internal modules or hide schemas. *(Decision: keep current `groups_for_modules` structure. Public API boundary is `JX` and `JX.Workspace`; internal modules are grouped by function and documented for advanced users.)*
- [x] Run the full test suite for the release candidate.
- [x] Run `mix hex.audit` and treat retired dependencies as release blockers.
- [x] Run `mix docs` and treat warnings as release blockers.
- [x] Run `mix hex.build` and inspect package contents.
- [x] Build `MIX_ENV=prod mix release` and verify the OTP release works.

## Known Limitations

- **Upstream warnings in `:prod`**: Some dependencies emit compiler warnings in `MIX_ENV=prod`. These do not affect functionality. The `mix precommit` alias and CI test job run in `:test`, so they are unaffected. Release builds intentionally do not use `--warnings-as-errors`.

## Publish Commands

Only after explicit approval:

```bash
mix hex.publish
```

Docs can also be published with:

```bash
mix hex.publish docs
```

Publishing is a public release action and should stay held until the lead agent confirms the release boundary.
