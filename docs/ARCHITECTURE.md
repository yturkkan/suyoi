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
- This process inspection skips environment variables (`envp`) and prompt arguments. Session preview content is handled separately.

### Activity & Live Task Context (`AgentActivityEvaluator` & `AgentTaskInspector`)
Process activity is derived from CPU delta between snapshots, live child tool processes, and the kernel's stopped state. TTY attachment describes the process's terminal connection. A quiet process observation leaves the agent's turn state unknown. Bounded session metadata is shown separately when live ownership can be verified.

### Server Tree Grouping (`ProcessTree`)
Listening TCP sockets collected via `lsof -nP -iTCP -sTCP:LISTEN` are grouped by walking parent-child relationships in `ProcessTree`:
- Multi-worker servers and reloader hierarchies are consolidated into a single `ServerGroup` with deduplicated memory and CPU totals.
- Upward traversal halts at **interactive shells** (`zsh`, `bash`, `fish`, `sh`, `tcsh`, `ksh`, `login`), **coding agents**, **GUI bundles**, and **project boundaries**. A shared-port merge between separate groups requires an ancestor path that respects those boundaries, even when both groups belong to the same project.
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

### Layer 2: Live Quota Polling (`LiveQuotaPoller`)
Live checks are on by default. Suyoi uses the saved preference when one exists. Turning live checks off cancels polling and invalidates in-flight results. Supported provider requests use existing local credentials in memory with an ephemeral HTTPS session and reject redirects. Live utilization is account-wide and appears separately from locally observed token usage.

---

## 4. Storage Cleanup & Execution Safety (`CleanupScanner`, `SafetyEvaluator` & `ActionExecutor`)

### Discovery & Identity Verification
- `CleanupScanner` discovers reproducible build directories (`node_modules`, `.build`, `.next`, `target`, `dist`, `.turbo`, `__pycache__`, `.pytest_cache`, `DerivedData`) across configured workspace roots.
- `AgentCacheCatalog` discovers 50+ developer and AI cache locations (`HuggingFace`, `uv`, `pip`, `Homebrew`, `SwiftPM`, `Cargo`, `Gradle`, `CocoaPods`, `Xcode DerivedData`, `CoreSimulator`, and `~/.cache/*`).
- Directory `FileIdentity` (`st_dev`, `st_ino`) is captured **before and after** size measurement. A directory whose inode changes mid-scan is marked `partial` and excluded from cleanup.
- Cached measurements retain the original logical size and optional allocated size separately.

### Fail-Closed Safety Evaluation (`SafetyEvaluator` & `NodeModulesSafety`)
A candidate is marked reviewable for Trash only when all safety checks pass:
- **No active process usage:** No current-user process or dev server has its `cwd` inside the candidate or its enclosing project root, and `lsof` reports no open file descriptors within the directory.
- **Clean git worktree:** For project build artifacts, `WorktreeInspector` verifies that the enclosing git worktree is not locked or mid-merge.
- **Verified regenerability:** Project dependency directories (`node_modules`) require both a manifest (`package.json`) and a lockfile (`package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, or `bun.lockb`) on disk.
- **High-impact isolation:** Model weight stores (`HuggingFace`), virtual environments (`.venv`/`venv`), `uv`, `CoreSimulator`, and unknown `~/.cache/*` directories are classified as `Manual Trash` and excluded from bulk **Trash All Ready** actions.

### Execution-Time Re-Verification (`ActionExecutor`)

- **Pre-Trash live reassessment.** The executor requests a fresh `assessCandidateForTrash` result for each item in order. The assessment checks live process and listener evidence, open files, worktrees where applicable, and regenerability. The executor then verifies the path, device and inode, applicable lockfile, and descendant safety before calling `FileManager.default.trashItem`. A batch preview alone cannot authorize the move.
- **Protected descendants.** A bounded metadata-only walk checks the names of descendant files and directories against the protected-path policy. It never follows child symlinks. Each walk has a two-second deadline and entry and depth limits. Trash can perform a walk during live assessment and again after the executor's other checks. Large trees, unreadable entries, and changes detected during the walk can prevent verification and block Trash. A final race remains because macOS Trash accepts a path.
- **Merged worktrees.** Discovery and execution use an Apple-signed Git binary in a sandbox that blocks child processes, network access, and repository writes. A configured clean filter on a tracked path blocks eligibility. Before Trash, Suyoi rechecks branch and commit, merge ancestry, worktree status, and live usage. A bounded walk verifies that physical entries match tracked paths and the linked worktree's root `.git` file. Ignored, untracked, or otherwise unverifiable content blocks the move.
- **Session log retention.** Each move requires a fresh and complete current-user process observation, absence of possible active provider owners, and an exact-file open-descriptor check. The file's metadata and identity are checked again before Trash.
- **Put Back.** The Trash outcome binds the moved inode to the original and Trash parent chains. Restore opens parent directories without following symlinks and uses a descriptor-relative rename that refuses overwrites. A successful Trash operation may lack verifiable recovery evidence. The source leaf can still change between its final identity check and the rename.
- **Process signaling.** `stopProcess` and `stopServerGroup` re-verify `ProcessIdentity` (`pid`, `uid`, `startTimeMicroseconds`, `executable`) before sending `SIGTERM` or an explicitly requested `SIGKILL`.

## 5. Agent Steering, Deep Session Jump & Hook Approvals (`AgentSteerer`, `SessionJumpRouter` & `AgentApprovalController`)

- **Terminal, `tmux` and IDE deep-jump (`SessionJumpRouter`).** Rechecks process identity and the controlling TTY before navigation. Host activation verifies current ancestry and host identity. Commands use fixed argument arrays.
- **Bounded turn and tool previews (`SessionTurnPreviewInspector`).** Live transcript text requires a unique writable session file in the selected Codex or Claude Code process and matching session and workspace metadata. The preview reads at most 64 KiB from the verified file in memory and redacts common credential patterns, including the full Bearer token alphabet, before shortening text. A separate API accepts an explicit historical session ID. Suyoi keeps no raw transcript copy or preview history.
- **Claude Code tool approvals (`AgentApprovalController`, `HookBridgeClient`).** The bridge writes a reduced request to a user-private spool and translates decisions to the output schema for `PermissionRequest` or `PreToolUse`. It discards unused events before writing and keeps raw tool output out of the spool. The controller grants auto-approval only to a verified process, project, session and lifetime marker. The bridge rotates the marker on `SessionStart`, removes it on `SessionEnd`, and checks it again before returning an approval. A request without this evidence is eligible for a one-time response only.
- **Terminal and iTerm2 steering (`AgentSteerer`).** After rechecking process identity and the controlling TTY, Suyoi requires the selected agent to be the sole member and leader of the terminal's live foreground process group. The fixed AppleScript receives the TTY and prompt as separate arguments and checks for a unique matching tab or session. Apple Event delivery remains separate from the kernel check.
- **Native CLI continuation (`NativeAgentJobLauncher`).** The composer requires an explicit session selection. The action checks the selected provider, project, session metadata source, and the row's live process identity before launching `codex exec resume` or `opencode run --session` with fixed arguments and null standard streams. The selected session can be historical. A successful action confirms local process creation.
- **Display surfaces, themes & CESP sound packs (`IslandSurfaceCalculator`, `ExperienceThemeCatalog`, `IslandWindowController`).** Computes geometry for the Menu Bar Popover, top-center Notch Dynamic Island, and movable Floating Companion (`NSPanel`), and loads local OpenPeon (`openpeon.json`) sound packs using `O_NOFOLLOW` descriptor walks that reject symlinks and path traversal.

## 6. App Update Verification (`AppUpdater`)

The updater stages the GitHub Releases archive and verifies the checksum when provided, the bundle identifier, the normalized release version, and the bundle's code signature. The replacement helper exits before moving either bundle if the old process is still running after its wait. The ad-hoc signature verifies bundle integrity. Publisher trust depends on the release source.
