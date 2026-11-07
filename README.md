# Suyoi

**Native macOS menu bar utility for monitoring coding agents, local dev servers, AI subscription quotas, and developer build/cache storage.**

Built with Swift 6, AppKit, and SwiftUI for macOS 14+ with zero external package dependencies.

Created by **Y. Türkkan** ([`@yturkkan`](https://github.com/yturkkan) · [X](https://x.com/yturkkan) · [LinkedIn](https://www.linkedin.com/in/yturkkan))

---

## Overview

Modern software development on macOS often involves running multiple coding agents (`Codex`, `Claude Code`, `OpenCode`, `Gemini CLI`, `Aider`), background language servers, multi-worker localhost dev servers, and tens of gigabytes of build artifacts and caches across workspaces.

**Suyoi** lives in the macOS menu bar and provides a single, low-overhead control plane to:

- **Inspect & steer coding agents** — Detect native and runtime-wrapped (`node`, `bun`, `deno`, `python`) agent processes via `libproc` and bounded `KERN_PROCARGS2` inspection, view local task metadata, focus the host terminal/IDE window, and send follow-up instructions to verified foreground agents in Terminal or iTerm2.
- **Group & manage localhost dev servers** — Map listening TCP ports to their owning process trees, git branches, and frameworks (`Next.js`, `Vite`, `SwiftPM`, `Cargo`, `Python`, `Go`) with one-click browser launch, URL copy, and safe process-group termination.
- **Track 5-hour & 7-day AI quotas** — Combine offline local rolling token counters (`300m` and `10080m` windows) with optional in-memory OAuth quota window checks (`Codex`, `Claude`, `Gemini`, `OpenCode`, `Cursor`), including reset countdowns and customizable provider ordering.
- **Reclaim build & cache storage safely** — Scan workspace build directories (`node_modules`, `.build`, `.next`, `target`, `dist`, `.turbo`, `__pycache__`) and 50+ developer/AI cache locations, verify live process/open-file/lockfile safety at execution time, and move eligible items to **macOS Trash** (`FileManager.trashItem`) — never `rm -rf`.

---

## Installation

### Prebuilt App Bundle

A prebuilt ad-hoc signed macOS bundle is included in this repository and on the [Releases](https://github.com/yturkkan/suyoi/releases) page:

- **Direct bundle:** [`build/Suyoi.app`](build/Suyoi.app)
- **Zip archive:** [`build/Suyoi.app.zip`](build/Suyoi.app.zip)

```bash
open build/Suyoi.app
```

To update an installed copy of Suyoi, open the `…` menu in the bottom-right corner of the popover (or **Settings → About Suyoi**) and click **Check for Updates…** → **Update & Relaunch**. Suyoi downloads the latest `Suyoi.app.zip` from GitHub Releases, verifies its bundle identifier and code signature, replaces the app bundle, and relaunches automatically.

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

Suyoi is designed around strict fail-closed invariants:

1. **No Prompt or Environment Harvesting (`KERN_PROCARGS2`)**
   Wrapper inspection reads only bounded `argv` script/module tokens to identify runtime-hosted agents (`node .../claude`, `bun .../opencode`, `python -m aider`). Environment variables (`envp`), API keys, and conversation bodies are never parsed, logged, or stored.
2. **Process Identity Re-Verification (`ProcessIdentity`)**
   Before sending `SIGTERM` (or an explicit user-requested `SIGKILL`), `ActionExecutor` re-verifies `pid`, `uid`, `startTimeMicroseconds`, and `executable` against the live kernel process table to prevent signaling a reused PID.
3. **Interactive Shell & Agent Boundaries (`ProcessTree`)**
   Server grouping respects interactive shells, coding agents, GUI processes, and project boundaries when walking the process tree or merging related listeners on a shared port.
4. **Live Pre-Trash Safety Re-Evaluation**
   Suyoi collects fresh evidence for each item, including during a bulk operation. A bounded metadata check blocks directories with protected descendants or an incomplete traversal. The final macOS Trash call is path-based, so a change can still occur between the last check and the move.
5. **High-Impact Cache Protection (`Manual Trash`)**
   Large model stores and environments (`HuggingFace` model weights, `uv`, `CoreSimulator`, `.venv`, and uncataloged `~/.cache/*` directories) are separated from disposable build caches and excluded from bulk **Trash All Ready** operations.
6. **Verified Steering Targets**
   Suyoi checks the selected agent's live identity, controlling TTY, and foreground ownership before sending to Terminal or iTerm2. The foreground group must contain only the selected agent. Native Codex and OpenCode continuation is unavailable in the default app because displayed session metadata cannot establish live process ownership.

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
│   └── SuyoiCoreTests/   # Unit and fixture tests (202 tests across 24 suites)
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
