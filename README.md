# Suyoi

**Native macOS menu bar utility for monitoring coding agents, local dev servers, AI subscription quotas, and developer build/cache storage.**

Built with Swift 6, AppKit, and SwiftUI for macOS 14+ with zero external package dependencies.

Created by **Y. Türkkan** ([`@yturkkan`](https://github.com/yturkkan) · [X](https://x.com/yturkkan) · [LinkedIn](https://www.linkedin.com/in/yturkkan))

---

## Overview

Modern software development on macOS often involves running multiple coding agents (`Claude Code`, `Codex`, `OpenCode`, `Gemini CLI`, `Antigravity CLI`, `Hermes Agent`, `Qwen Code`, `Kimi CLI`, `OpenClaw`, `Pi Agent`, `Aider`, `Cursor`, `Windsurf`, `GitHub Copilot`, `Goose`, `Amp`, `Droid`, `Kiro`), background language servers, multi-worker localhost dev servers, and tens of gigabytes of build artifacts and caches across workspaces.

**Suyoi** lives in the macOS menu bar (or as a **Notch Dynamic Island** / **Floating Companion**) and provides a single, low-overhead control plane to:

- **Inspect, jump to & steer 18+ coding agents** — Detect native and runtime-wrapped agents, see bounded previews when the live transcript can be identified, and jump to an associated terminal tab, `tmux` pane, or IDE workspace. Send instructions to a verified Terminal or iTerm2 target, or choose an explicit Codex or OpenCode session to continue. The Claude Code hook bridge supports in-panel approval, denial, and eligible session auto-approval.
- **Switch between 3 display surfaces, 4 themes & semantic audio packs** — Operate Suyoi as a standard **Menu Bar Popover**, a top-center **Notch Dynamic Island** pill that expands on attention, or a draggable **Floating Companion ("Buddy")**, paired with **Suyoi Glass**, **macOS Native**, **Pixel Arcade**, or **Game Boy Olive** themes and macOS system sounds or **OpenPeon (`openpeon.json`)** CESP audio packs.
- **Group & manage localhost dev servers** — Map listening TCP ports to their owning process trees, git branches, and frameworks (`Next.js`, `Vite`, `SwiftPM`, `Cargo`, `Python`, `Go`) with RFC 1123 named `http://<project>.localhost:<port>` URLs, stale/idle (`Idle 2h+`) & uptime badges, one-click browser launch, URL copy, and safe process-group termination.
- **Track 5-hour & 7-day AI quotas** — See local rolling token counts alongside account-wide usage and reset times when available. Live quota checks are enabled by default and can be disabled from the Quotas tab.
- **Review storage before moving it to Trash** — Scan workspace build artifacts, developer caches, merged secondary Git worktrees, and aged session logs. Suyoi checks eligibility again for each move to **macOS Trash**. **Put Back** is available when Suyoi can verify the moved item and both directory locations.

---

## Installation

### Prebuilt App Bundle

A prebuilt ad-hoc signed macOS bundle is included in this repository and on the [Releases](https://github.com/yturkkan/suyoi/releases) page:

- **Direct bundle:** [`build/Suyoi.app`](build/Suyoi.app)
- **Zip archive:** [`build/Suyoi.app.zip`](build/Suyoi.app.zip)

```bash
open build/Suyoi.app
```

To update an installed copy, open **Settings → About Suyoi**, check for updates, and choose **Update & Relaunch**. Suyoi downloads the archive from GitHub Releases and verifies the bundle identifier, release version, code signature, and checksum when supplied. The helper waits for the current process to exit before replacing the bundle. The ad-hoc signature checks bundle integrity. Publisher trust comes from the GitHub release source.

### Build from Source

Requirements: **macOS 14.0+** and **Xcode / Swift 6 Command Line Tools**. No third-party packages are required.

```bash
# Run the test suite
./scripts/swift-local.sh test

# Build release binary and package build/Suyoi.app + build/Suyoi.app.zip
./scripts/build-app.sh

# Launch the menu bar app
open build/Suyoi.app
```

---

## Command-Line Interface

The embedded executable also provides a read-only JSON inspection CLI for scripting and diagnostics:

```bash
build/Suyoi.app/Contents/MacOS/Suyoi --help
build/Suyoi.app/Contents/MacOS/Suyoi --snapshot
build/Suyoi.app/Contents/MacOS/Suyoi --quotas
build/Suyoi.app/Contents/MacOS/Suyoi --scan-cleanup
build/Suyoi.app/Contents/MacOS/Suyoi --scan-cleanup "/path/to/workspace"
build/Suyoi.app/Contents/MacOS/Suyoi --agent-storage
```

| Flag | Description |
| :--- | :--- |
| `--snapshot` | Outputs current-user processes, detected coding agents, grouped dev servers, resolved project contexts, and listening TCP ports as JSON. |
| `--quotas` | Outputs local rolling token consumption (`300m` / `10080m`) and rate-limit window metadata as JSON. |
| `--scan-cleanup [path]` | Scans project build artifacts under the target workspace root and allowlisted developer/agent caches, including safety assessments. |
| `--agent-storage` | Lists discovered developer and AI cache directories with byte measurements without running safety evaluation. |

---

## Safety & Privacy Architecture

Suyoi verifies the target and available evidence before performing an action.

1. **Bounded Process and Session Inspection**
   Wrapper recognition reads only the `argv` script and module tokens needed to identify an agent. It skips prompt arguments and process environment variables. Session previews read bounded portions of an identified transcript in memory and redact common credential patterns before display. Suyoi keeps no raw transcript copy or preview history.
2. **Process Identity Re-Verification (`ProcessIdentity`)**
   Before sending `SIGTERM` (or an explicit user-requested `SIGKILL`), `ActionExecutor` re-verifies `pid`, `uid`, `startTimeMicroseconds`, and `executable` against the live kernel process table to prevent signaling a reused PID.
3. **Interactive Shell & Agent Boundaries (`ProcessTree`)**
   Server grouping respects interactive shells, coding agents, GUI processes, and project boundaries when walking the process tree or merging related listeners on a shared port.
4. **Live Pre-Trash Safety Re-Evaluation**
   Suyoi collects fresh evidence for each item, including during a bulk operation. Worktree cleanup blocks ignored or untracked local files and unverifiable Git status. Session log retention requires a fresh, complete process sample and clear open-file evidence. The final macOS Trash call accepts a path, so a change can still occur between the last check and the move.
5. **High-Impact Cache Protection (`Manual Trash`)**
   Large model stores and environments (`HuggingFace` model weights, `uv`, `CoreSimulator`, `.venv`, and uncataloged `~/.cache/*` directories) are separated from disposable build caches and excluded from bulk **Trash All Ready** operations.
6. **Verified Steering Targets**
   Suyoi checks the selected agent's live identity, controlling TTY, and sole foreground ownership before sending to Terminal or iTerm2. Foreground ownership can change before the Apple Event arrives. To continue through the Codex or OpenCode CLI, select the provider session and check its project in the composer. This starts a new local continuation process for the chosen session.
7. **Claude Code Hook Approvals**
   Configure the copied hook command for `SessionStart`, `SessionEnd`, and one approval event, either `PreToolUse` or `PermissionRequest`. Session auto-approval requires a verified Claude Code process, project, and session lifetime. The private bridge stores only fields needed to show and resolve the request.

For deeper implementation details, see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

---

## Repository Layout

```text
Suyoi/
├── Package.swift
├── Sources/
│   ├── SuyoiCore/        # Process inspection, tree grouping, quotas, cleanup safety & steering
│   └── SuyoiApp/         # AppKit status bar controller, SwiftUI popover views & CLI entrypoint
├── Tests/
│   └── SuyoiCoreTests/   # Unit and fixture tests
├── Resources/            # AppIcon.icns & artwork
├── scripts/
│   ├── build-app.sh      # Release bundle & archive builder
│   └── swift-local.sh    # Toolchain wrapper for Swift Testing
├── docs/
│   └── ARCHITECTURE.md   # System design & safety invariants
├── LICENSE               # MIT License
└── THIRD_PARTY_NOTICES.md
```

---

## License & Acknowledgments

Suyoi is an independent clean-room implementation released under the [MIT License](LICENSE). Engineering patterns informed by open-source macOS utilities are documented with full license notices in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

MIT License · © 2026 **Y. Türkkan** ([@yturkkan](https://github.com/yturkkan))
