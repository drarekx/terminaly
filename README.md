# Terminaly

Native macOS app (SwiftUI + SwiftTerm) for running and steering CLI agent sessions, inspired by Unpeel.

- Sidebar: projects (folders) → sessions, pin, rename, archive, folder colors, drop folders to add
- Real terminals (SwiftTerm), kept alive while hidden
- Presets (Shell, Claude, Codex…) editable in Settings; ⌘T launches the first one
- Split panes (⌘D right, ⇧⌘D down, ⌘W close), persisted layout
- Agent status: Claude Code hooks → Working / Ready / Needs input, notifications + dock badge;
  other agents use output activity
- Command palette (⌘K), ⌘[ / ⌘] to cycle sessions
- Sessions live in the `tly` host daemon: quitting the app leaves them running and they
  reattach (with recent output replayed) on next launch

## Architecture

- `Terminaly` — SwiftUI app; renders terminals (SwiftTerm `TerminalView`) and forwards input.
- `tly` — one daemon process for all sessions (`tly daemon`, auto-started) plus CLI.
  PTYs via forkpty, kqueue-driven (no polling), 2 MB replay ring per session,
  Claude hook HTTP server on 127.0.0.1 with per-run token, exits after 60 s with no sessions or clients.
  Unix socket `~/Library/Application Support/Terminaly/tly.sock` (0600, same-UID peers only).
- `TerminalyKit` — shared framing protocol and socket helpers.

## CLI

```sh
ln -s "$PWD/build/Terminaly.app/Contents/MacOS/tly" /usr/local/bin/tly
tly ls · tly new --command claude · tly send <id> "text" --enter · tly logs <id>
tly attach <id> (Ctrl-\ detaches) · tly wait <id> · tly kill|rm <id> · tly shutdown
```

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/drarekx/terminaly/main/install.sh | bash
```

Installs `Terminaly.app` into /Applications (or ~/Applications) and links the `tly` CLI
(`bash -s -- --no-cli` to skip it). Later versions arrive through the built-in updater.

## Release

```sh
scripts/release.sh 0.2.0 "release notes"
```

Builds, zips and EdDSA-signs the app, writes `appcast.xml`, tags, pushes and publishes the GitHub
release (versioned zip + `Terminaly.zip` for the installer + appcast for Sparkle).
Needs `gh` and the Sparkle private key in the login Keychain.

## Build

```sh
./scripts/bundle.sh          # → build/Terminaly.app
open build/Terminaly.app
```

Enable Claude Code status in Settings → Agents → Install Hooks (edits `~/.claude/settings.json`, backup kept).

## Self-test

```sh
swift build && TERMINALY_STATE_DIR=$(mktemp -d) .build/debug/Terminaly --selftest
```
Uses the real daemon: hook path → needsInput, output heuristic → working/idle, and a simulated app
relaunch that checks the session survives and its output is replayed.
