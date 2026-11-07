# Suyoi Architecture & Safety Invariants

Suyoi is split into two targets defined in [`Package.swift`](../Package.swift):

- **`SuyoiCore`** — Dependency-free system inspection, process tree analysis, project metadata resolution, hybrid quota tracking, cleanup safety evaluation, and action execution.
- **`SuyoiApp`** — Native macOS `NSStatusItem` / `NSPopover` interface built with AppKit and SwiftUI, plus the read-only JSON CLI entrypoint.

---

## 1. Process, Agent & Server Inspection (`SuyoiCore`)

### Native Process Table (`NativeProcessInspector`)
Suyoi queries the Darwin kernel directly using `libproc` (`proc_listpids`, `proc_pidinfo`, `proc_pidpath`, `proc_pid_rusage`) scoped to the current UNIX user (`getuid()`). For each process, it captures:
- `pid`, `parentPID`, `uid`, process name, executable path, and current working directory (`cwd`)
- Microsecond start timestamp (`startTimeMicroseconds`), resident memory (`residentBytes`), and physical footprint (`footprintBytes`)
- Controlling TTY (`tty`) and stopped process state (`isStopped`)
- Monotonic CPU time samples used to compute per-process CPU utilization deltas

### Privacy-Preserving Wrapper Detection (`ProcessArgumentsReader` & `AgentRecognizer`)
Many modern coding agents execute inside language runtimes (`node`, `bun`, `deno`, `python`). When an executable is a recognized runtime wrapper, `ProcessArgumentsReader` invokes `sysctl` with `KERN_PROCARGS2` under strict bounds:
- Only the first `argv` command/script tokens are inspected to match known agent entrypoints (`claude`, `codex`, `opencode`, `gemini`, `aider`).
- Environment variables (`envp`), credentials, and prompt arguments are never parsed or retained.

### Activity & Live Task Context (`AgentActivityEvaluator` & `AgentTaskInspector`)
Agent activity state (`active`, `waiting`, `idle`, `stopped`) is derived from verifiable local signals:
- CPU delta between snapshots
- Active child tool processes (`git`, `rg`, `swift`, `cargo`, `npm`, etc.)
- Controlling TTY state and local session metadata timestamps
- Bounded local session metadata (`OpenCode` SQLite `session_v2` / `todo` tables and `Codex` session JSONL `session_meta` / structured task events) without indexing conversation transcripts.

### Server Tree Grouping (`ProcessTree`)
Listening TCP sockets collected via `lsof -nP -iTCP -sTCP:LISTEN` are grouped by walking parent-child relationships in `ProcessTree`:
- Multi-worker servers and reloader hierarchies are consolidated into a single `ServerGroup` with deduplicated memory and CPU totals.
- Upward traversal halts at **interactive shells** (`zsh`, `bash`, `fish`, `sh`, `tcsh`, `ksh`, `login`), **coding agents**, **GUI bundles**, and **project boundaries**, ensuring that stopping a server group never terminates the user's interactive terminal session or parent agent.
- Each `ServerGroup` records immutable `memberIdentities` (`[ProcessIdentity]`) at capture time.

---

## 2. Project Context Resolution (`ProjectResolver`)

For directories associated with active agents or listening servers, `ProjectResolver` walks upward (bounded to 8 levels within the user's home directory) to identify the enclosing repository root:
- Parses `.git/HEAD`, worktree `.git` pointers, `commondir`, and `packed-refs` using non-blocking, `O_NOFOLLOW` file descriptors capped at 4 KiB–256 KiB.
- Extracts framework hints and major versions from `package.json`, `Package.swift`, `Cargo.toml`, `pyproject.toml`, and `go.mod` without executing manifest code.

---

## 3. Hybrid Quota & Token Tracking (`QuotaInspector` & `LiveQuotaPoller`)

### Layer 1: Offline Local Telemetry (`LocalQuotaInspector`)
Reads bounded local telemetry files to compute rolling **5-hour (`300m`)** and **7-day (`10080m`)** token consumption (`input`, `output`, `cacheRead`, `cacheCreation`) and provider rate-limit windows:
- **Codex:** `~/.codex/sessions/YYYY/MM/DD/*.jsonl` (`token_count` and `rate_limits` events)
- **Claude Code:** `~/.claude/projects/*/*.jsonl` and `~/.claude/stats-cache.json` (deduplicated by message ID)
- **Gemini CLI, OpenCode & Cursor:** Bounded local SQLite/JSON usage counters where present; missing data is reported as `unavailable`, never fabricated as zero.

### Layer 2: Opt-In Live Quota Polling (`LiveQuotaPoller`)
When enabled by the user, `LiveQuotaPoller` reads existing local CLI credentials in memory for the duration of a single HTTPS request (with redirect credential-stripping and ephemeral `URLSessionConfiguration`) to fetch live utilization percentages and reset timestamps. Credentials are never written to disk, logs, or JSON output.

---

## 4. Storage Cleanup & Execution Safety (`CleanupScanner`, `SafetyEvaluator` & `ActionExecutor`)

### Discovery & Identity Verification
- `CleanupScanner` discovers reproducible build directories (`node_modules`, `.build`, `.next`, `target`, `dist`, `.turbo`, `__pycache__`, `.pytest_cache`, `DerivedData`) across configured workspace roots.
- `AgentCacheCatalog` discovers 50+ developer and AI cache locations (`HuggingFace`, `uv`, `pip`, `Homebrew`, `SwiftPM`, `Cargo`, `Gradle`, `CocoaPods`, `Xcode DerivedData`, `CoreSimulator`, and `~/.cache/*`).
- Directory `FileIdentity` (`st_dev`, `st_ino`) is captured **before and after** size measurement; any directory whose inode changes mid-scan is marked `partial` and excluded from cleanup.

### Fail-Closed Safety Evaluation (`SafetyEvaluator` & `NodeModulesSafety`)
A candidate is marked reviewable for Trash only when all safety checks pass:
- **No active process usage:** No current-user process or dev server has its `cwd` inside the candidate or its enclosing project root, and `lsof` reports no open file descriptors within the directory.
- **Clean git worktree:** For project build artifacts, `WorktreeInspector` verifies that the enclosing git worktree is not locked or mid-merge.
- **Verified regenerability:** Project dependency directories (`node_modules`) require both a manifest (`package.json`) and a lockfile (`package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, or `bun.lockb`) on disk.
- **High-impact isolation:** Model weight stores (`HuggingFace`), virtual environments (`.venv`/`venv`), `uv`, `CoreSimulator`, and unknown `~/.cache/*` directories are classified as `Manual Trash` and excluded from bulk **Trash All Ready** actions.

### Execution-Time Re-Verification (`ActionExecutor` & `AgentSteerer`)
- **Pre-Trash Live Reassessment (`reassessCandidatesForTrash`):** Immediately prior to calling `FileManager.default.trashItem`, Suyoi re-evaluates live processes, open files, worktrees, lockfiles, non-symlink ancestry, and `FileIdentity(device, inode)`. Permanent deletion (`removeItem` / `rm -rf`) is never used.
- **Process Signaling (`stopProcess` / `stopServerGroup`):** Re-verifies `ProcessIdentity` (`pid`, `uid`, `startTimeMicroseconds`, `executable`) and `ServerGroup.memberIdentities` immediately before sending `SIGTERM` (or explicit `SIGKILL`).
- **Agent Steering (`AgentSteerer`):** Re-verifies `ProcessIdentity` and target TTY/session ownership before delivering user-submitted prompts via parameterized AppleScript (`osascript` argv) or native CLI continuation (`opencode run --session`, `codex exec resume`).
