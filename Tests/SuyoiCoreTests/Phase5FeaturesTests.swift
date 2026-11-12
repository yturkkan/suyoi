import Darwin
import Foundation
import Testing
@testable import SuyoiCore

private final class SequenceCommandRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [CommandResult]
    private var recorded: [CommandRequest] = []

    init(_ results: [CommandResult]) {
        self.queued = results
    }

    var requests: [CommandRequest] {
        lock.withLock { recorded }
    }

    func run(_ request: CommandRequest) throws -> CommandResult {
        lock.withLock {
            recorded.append(request)
            if !queued.isEmpty {
                return queued.removeFirst()
            }
            return CommandResult(exitCode: 0, stdout: Data(), stderr: Data(), timedOut: false, truncated: false)
        }
    }
}

private func phase5ForegroundBSDInfo(pid: UInt32 = 400, uid: UInt32 = 501) -> proc_bsdinfo {
    var info = proc_bsdinfo()
    info.pbi_pid = pid
    info.pbi_uid = uid
    info.pbi_ruid = uid
    info.pbi_start_tvusec = 100
    info.pbi_status = UInt32(SSLEEP)
    info.pbi_flags = UInt32(PROC_FLAG_CONTROLT)
    info.e_tdev = 17
    info.pbi_pgid = pid
    info.e_tpgid = pid
    return info
}

private func makeProcArgsData(executablePath: String, argv: [String]) -> Data {
    var data = Data()
    var argc = Int32(argv.count).littleEndian
    withUnsafeBytes(of: &argc) { data.append(contentsOf: $0) }
    data.append(contentsOf: executablePath.utf8)
    data.append(0)
    for arg in argv {
        data.append(contentsOf: arg.utf8)
        data.append(0)
    }
    return data
}

@Suite("Phase 5 steering, hooks, collisions, diffs, burn rate & health")
struct Phase5FeaturesTests {
    private func makeLiveProcess(
        pid: Int = 400,
        parentPID: Int = 1,
        uid: Int = 501,
        cpu: Double = 0,
        tty: String? = "ttys001",
        cwd: String? = "/workspace/demo",
        executable: String = "/bin/claude"
    ) -> ObservedProcess {
        ObservedProcess(
            pid: pid,
            parentPID: parentPID,
            uid: uid,
            cpuPercent: cpu,
            residentBytes: 64 * 1_024 * 1_024,
            executable: executable,
            startTimeMicroseconds: 100,
            cwd: cwd,
            tty: tty,
            isStopped: false
        )
    }

    private func makeTerminalVerifier() -> TerminalForegroundVerifier {
        TerminalForegroundVerifier(
            bsdInfo: { $0 == 400 ? phase5ForegroundBSDInfo() : nil },
            groupMembers: { $0 == 400 ? [400] : nil },
            ttyDevice: { $0 == "/dev/ttys001" ? 17 : nil },
            currentUID: { 501 }
        )
    }

    @Test func steersWezTermAndKittyPanesAndFailsClosedOnAmbiguity() {
        let live = makeLiveProcess()
        let wezAgent = AgentObservation(
            id: 400,
            agentName: "Claude Code",
            process: live,
            project: nil,
            terminalApp: "WezTerm",
            statusSource: .processOnly,
            childServerPorts: []
        )
        #expect(AgentSteerer.preferredMode(for: wezAgent) == .weztermPane)

        let wezPanesJSON = #"[{"pane_id":7,"tty_name":"/dev/ttys001"},{"pane_id":8,"tty_name":"/dev/ttys009"}]"#
        let wezRunner = SequenceCommandRunner([
            CommandResult(exitCode: 0, stdout: Data(wezPanesJSON.utf8), stderr: Data(), timedOut: false, truncated: false),
            CommandResult(exitCode: 0, stdout: Data(), stderr: Data(), timedOut: false, truncated: false),
            CommandResult(exitCode: 0, stdout: Data(), stderr: Data(), timedOut: false, truncated: false)
        ])
        let wezSteerer = AgentSteerer(
            processLookup: { _, _ in live },
            runner: wezRunner,
            executableResolver: { "/tools/\($0)" },
            terminalForegroundVerifier: makeTerminalVerifier()
        )
        let wezOutcome = wezSteerer.steer(agent: wezAgent, prompt: "run tests now", uid: 501)
        #expect(wezOutcome.succeeded)
        #expect(wezOutcome.mode == .weztermPane)
        #expect(wezRunner.requests.count == 3)
        #expect(wezRunner.requests[0].arguments == ["cli", "list", "--format", "json"])
        #expect(wezRunner.requests[1].arguments == ["cli", "send-text", "--pane-id", "7", "--no-paste", "--", "run tests now"])
        #expect(wezRunner.requests[2].arguments == ["cli", "send-text", "--pane-id", "7", "--no-paste", "--", "\r"])

        let ambiguousWezJSON = #"[{"pane_id":7,"tty_name":"/dev/ttys001"},{"pane_id":9,"tty_name":"ttys001"}]"#
        let ambiguousWezRunner = SequenceCommandRunner([
            CommandResult(exitCode: 0, stdout: Data(ambiguousWezJSON.utf8), stderr: Data(), timedOut: false, truncated: false)
        ])
        let ambiguousWezSteerer = AgentSteerer(
            processLookup: { _, _ in live },
            runner: ambiguousWezRunner,
            executableResolver: { "/tools/\($0)" },
            terminalForegroundVerifier: makeTerminalVerifier()
        )
        #expect(!ambiguousWezSteerer.steer(agent: wezAgent, prompt: "run tests", uid: 501).succeeded)
        #expect(ambiguousWezRunner.requests.count == 1)

        let kittyAgent = AgentObservation(
            id: 400,
            agentName: "Claude Code",
            process: live,
            project: nil,
            terminalApp: "kitty",
            statusSource: .processOnly,
            childServerPorts: []
        )
        #expect(AgentSteerer.preferredMode(for: kittyAgent) == .kittyWindow)

        let kittyJSON = #"[{"tabs":[{"windows":[{"id":12,"is_self":false,"foreground_processes":[{"pid":400}]}]}]}]"#
        let kittyRunner = SequenceCommandRunner([
            CommandResult(exitCode: 0, stdout: Data(kittyJSON.utf8), stderr: Data(), timedOut: false, truncated: false),
            CommandResult(exitCode: 0, stdout: Data(), stderr: Data(), timedOut: false, truncated: false),
            CommandResult(exitCode: 0, stdout: Data(), stderr: Data(), timedOut: false, truncated: false)
        ])
        let kittySteerer = AgentSteerer(
            processLookup: { _, _ in live },
            runner: kittyRunner,
            executableResolver: { "/tools/\($0)" },
            terminalForegroundVerifier: makeTerminalVerifier()
        )
        let kittyOutcome = kittySteerer.steer(agent: kittyAgent, prompt: #"check path\to\file"#, uid: 501)
        #expect(kittyOutcome.succeeded)
        #expect(kittyOutcome.mode == .kittyWindow)
        #expect(kittyRunner.requests.count == 3)
        #expect(kittyRunner.requests[0].arguments == ["@", "ls"])
        #expect(kittyRunner.requests[1].arguments == ["@", "send-text", "--match", "id:12", "--", #"check path\\to\\file"#])
        #expect(kittyRunner.requests[2].arguments == ["@", "send-text", "--match", "id:12", "\\r"])
    }

    @Test func tracksAndCancelsNativeContinuationJobs() throws {
        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent("suyoi-jobs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let launcher = NativeAgentJobLauncher(homeDirectory: tempHome)
        let meta = NativeContinuationMetadata(
            agentID: 42,
            agentName: "Codex",
            sessionID: "session-abc",
            projectPath: tempHome.path
        )
        let sleepJobID = try launcher.launch(
            executable: "/bin/sleep",
            arguments: ["5"],
            workingDirectory: tempHome,
            metadata: meta
        )
        #expect(launcher.activeJobs().contains(where: { (job: NativeContinuationJob) in
            job.id == sleepJobID && job.state == NativeContinuationJob.State.running
        }))
        #expect(launcher.cancelJob(id: sleepJobID))

        var cancelled = false
        for _ in 0..<25 {
            if launcher.recentJobs().contains(where: { (job: NativeContinuationJob) in
                job.id == sleepJobID && job.state == NativeContinuationJob.State.cancelled
            }) {
                cancelled = true
                break
            }
            usleep(25_000)
        }
        #expect(cancelled)

        let okJobID = try launcher.launch(
            executable: "/usr/bin/true",
            arguments: [],
            workingDirectory: tempHome,
            metadata: meta
        )
        var completed = false
        for _ in 0..<25 {
            if launcher.recentJobs().contains(where: { (job: NativeContinuationJob) in
                job.id == okJobID && job.state == NativeContinuationJob.State.completed
            }) {
                completed = true
                break
            }
            usleep(25_000)
        }
        #expect(completed)
    }

    @Test func expandsAndPersistsSteeringSlashSnippets() throws {
        let suiteName = "suyoi.snippets.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(SteeringSnippetCatalog.normalizeTrigger("lint") == "/lint")
        #expect(SteeringSnippetCatalog.normalizeTrigger("/check_1") == "/check_1")
        #expect(SteeringSnippetCatalog.normalizeTrigger("/bad space") == nil)

        let custom = try #require(SteeringSnippetCatalog.sanitizeCustomSnippet(
            trigger: "lint",
            title: "Run SwiftLint",
            prompt: "Run linter and fix warnings."
        ))
        SteeringSnippetCatalog.saveCustomSnippets([custom], to: defaults)
        let loaded = SteeringSnippetCatalog.loadCustomSnippets(from: defaults)
        #expect(loaded == [custom])

        let merged = SteeringSnippetCatalog.mergedSnippets(custom: loaded)
        let expandedWithExtra = SteeringSnippetCatalog.expand("/lint Sources/SuyoiCore", snippets: merged)
        #expect(expandedWithExtra == "Run linter and fix warnings. Sources/SuyoiCore")
        #expect(SteeringSnippetCatalog.expand("plain prompt", snippets: merged) == "plain prompt")
    }

    @Test func installsUpdatesAndUninstallsClaudeHooksSafely() throws {
        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent("suyoi-hooks-\(UUID().uuidString)", isDirectory: true)
        let claudeDir = tempHome.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let settingsURL = claudeDir.appendingPathComponent("settings.json")
        let initialJSON = """
        {
          "model": "claude-opus-4-6",
          "hooks": {
            "SessionStart": [
              {
                "hooks": [
                  { "type": "command", "command": "/usr/local/bin/other-tool --notify" }
                ]
              }
            ]
          }
        }
        """
        try Data(initialJSON.utf8).write(to: settingsURL)

        let installer = ClaudeHookInstaller(homeDirectory: tempHome)
        let bridgePath = "/Applications/Suyoi Next.app/Contents/MacOS/Suyoi"
        #expect(installer.inspectStatus(bridgeExecutablePath: bridgePath) == .notInstalled)

        let installedStatus = try installer.install(bridgeExecutablePath: bridgePath, includePreToolUse: true)
        #expect(installedStatus == .installed(
            command: "'/Applications/Suyoi Next.app/Contents/MacOS/Suyoi' --hook-bridge",
            includesPreToolUse: true
        ))
        #expect(FileManager.default.fileExists(atPath: installer.backupFileURL.path))

        let mergedData = try Data(contentsOf: settingsURL)
        let mergedObj = try #require(JSONSerialization.jsonObject(with: mergedData) as? [String: Any])
        #expect(mergedObj["model"] as? String == "claude-opus-4-6")

        let uninstalled = try installer.uninstall()
        #expect(uninstalled == .notInstalled)
        let afterData = try Data(contentsOf: settingsURL)
        let afterText = String(decoding: afterData, as: UTF8.self)
        #expect(afterText.contains("other-tool --notify"))
        #expect(!afterText.contains("--hook-bridge"))

        try FileManager.default.removeItem(at: settingsURL)
        let targetFile = tempHome.appendingPathComponent("outside.json")
        try Data("{}".utf8).write(to: targetFile)
        try FileManager.default.createSymbolicLink(at: settingsURL, withDestinationURL: targetFile)
        if case .blocked = installer.inspectStatus(bridgeExecutablePath: bridgePath) {
            // Expected fail-closed symlink block
        } else {
            Issue.record("Expected symlinked settings.json to be blocked")
        }
    }

    @Test func enforcesScopedReadOnlyAutoApprovalBoundaries() throws {
        #expect(AgentApprovalController.isSafeReadOnlyTool(toolName: "Read", command: nil))
        #expect(AgentApprovalController.isSafeReadOnlyTool(toolName: "Grep", command: nil))
        #expect(AgentApprovalController.isSafeReadOnlyTool(toolName: "Bash", command: "git status --short"))
        #expect(AgentApprovalController.isSafeReadOnlyTool(toolName: "Bash", command: "git diff HEAD"))
        #expect(!AgentApprovalController.isSafeReadOnlyTool(toolName: "Write", command: nil))
        #expect(!AgentApprovalController.isSafeReadOnlyTool(toolName: "Bash", command: "git status; rm -rf /tmp/x"))
        #expect(!AgentApprovalController.isSafeReadOnlyTool(toolName: "Bash", command: "git checkout -f"))
        #expect(!AgentApprovalController.isSafeReadOnlyTool(toolName: "Bash", command: "npm test"))
        #expect(!AgentApprovalController.isSafeReadOnlyTool(toolName: "Bash", command: "git status\nrm -rf /tmp/x"))
        #expect(!AgentApprovalController.isSafeReadOnlyTool(toolName: "Bash", command: "git status\trm"))
        #expect(!AgentApprovalController.isSafeReadOnlyTool(toolName: "Bash", command: "git status\u{00A0}--short"))
        #expect(!AgentApprovalController.isSafeReadOnlyTool(toolName: "Bash", command: "git log '--output=/tmp/x'"))
        #expect(!AgentApprovalController.isSafeReadOnlyTool(toolName: "Bash", command: "git diff --no-index /etc/passwd /dev/null"))

        let tempProject = FileManager.default.temporaryDirectory.appendingPathComponent("suyoi-ro-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempProject, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempProject) }
        let canonicalProject = tempProject.resolvingSymlinksInPath().standardizedFileURL.path

        let controller = AgentApprovalController()
        controller.setScopedPolicy(ScopedApprovalPolicy(
            autoApproveReadOnlyTools: true,
            applyToAllVerifiedProjects: false,
            allowedProjectPaths: [canonicalProject]
        ))

        let scope = ApprovalScope(
            process: ProcessIdentity(pid: 400, uid: 501, startTimeMicroseconds: 100, executablePath: "/bin/claude"),
            sessionID: "session-ro-1",
            projectPath: canonicalProject,
            generation: UUID()
        )

        final class ReplyBox: @unchecked Sendable {
            var replyJSON: String?
        }
        let readReply = ReplyBox()
        let readPayload = Data("""
        {"hook_event_name":"PermissionRequest","session_id":"session-ro-1","agent_name":"Claude Code","pid":400,"cwd":"\(canonicalProject)","tool_name":"Read","tool_input":{"file_path":"README.md"}}
        """.utf8)
        let queuedRead = controller.ingestHookEvent(readPayload, scope: scope, isScopeCurrent: { true }) { data in
            readReply.replyJSON = String(decoding: data, as: UTF8.self)
        }
        #expect(queuedRead == nil)
        #expect(readReply.replyJSON?.contains(#""approve""#) == true)
        #expect(controller.recentAutoApprovedRecords().count == 1)

        // Mutating Write tool in the same verified project MUST NOT auto-approve
        let writePayload = Data("""
        {"hook_event_name":"PermissionRequest","session_id":"session-ro-1","agent_name":"Claude Code","pid":400,"cwd":"\(canonicalProject)","tool_name":"Write","tool_input":{"file_path":"README.md"}}
        """.utf8)
        let queuedWrite = controller.ingestHookEvent(writePayload, scope: scope, isScopeCurrent: { true })
        #expect(queuedWrite != nil)
        #expect(controller.pendingRequests().count == 1)
    }

    @Test func detectsWorktreeCollisionsAndInspectsReadOnlyGitDiffs() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("suyoi-git-\(UUID().uuidString)", isDirectory: true)
        let repoDir = tempRoot.appendingPathComponent("demo-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let runner = CommandRunner()
        _ = try runner.run(CommandRequest(executable: "/usr/bin/git", arguments: ["-C", repoDir.path, "init", "-b", "main"], timeout: 5, maximumOutputBytes: 16_384))
        _ = try runner.run(CommandRequest(executable: "/usr/bin/git", arguments: ["-C", repoDir.path, "config", "user.email", "test@example.com"], timeout: 5, maximumOutputBytes: 16_384))
        _ = try runner.run(CommandRequest(executable: "/usr/bin/git", arguments: ["-C", repoDir.path, "config", "user.name", "Suyoi Test"], timeout: 5, maximumOutputBytes: 16_384))

        let trackedFile = repoDir.appendingPathComponent("app.swift")
        try Data("line1\nline2\nline3\n".utf8).write(to: trackedFile)
        _ = try runner.run(CommandRequest(executable: "/usr/bin/git", arguments: ["-C", repoDir.path, "add", "app.swift"], timeout: 5, maximumOutputBytes: 16_384))
        _ = try runner.run(CommandRequest(executable: "/usr/bin/git", arguments: ["-C", repoDir.path, "commit", "-m", "init"], timeout: 5, maximumOutputBytes: 16_384))

        // Modify tracked file (+2, -1) and add an untracked file
        try Data("line1\nline2-updated\nline3\nline4\n".utf8).write(to: trackedFile)
        try Data("notes\n".utf8).write(to: repoDir.appendingPathComponent("untracked.md"))

        let proj = ProjectContext(
            rootPath: repoDir.path,
            name: "demo-repo",
            framework: nil,
            gitBranch: "main",
            gitCommit: nil,
            isWorktree: false
        )
        let agentA = AgentObservation(
            id: 501,
            agentName: "Claude Code",
            process: makeLiveProcess(pid: 501, cwd: repoDir.path),
            project: proj,
            terminalApp: "Terminal",
            statusSource: .processOnly,
            childServerPorts: [],
            activityState: .active
        )
        let agentB = AgentObservation(
            id: 502,
            agentName: "Codex",
            process: makeLiveProcess(pid: 502, cwd: repoDir.path, executable: "/bin/codex"),
            project: proj,
            terminalApp: "WezTerm",
            statusSource: .processOnly,
            childServerPorts: [],
            activityState: .waiting
        )

        let collisions = AgentCollisionDetector.detectCollisions(in: [agentA, agentB])
        #expect(collisions.count == 1)
        #expect(collisions[0].agentIDs == [501, 502])

        let diff = try #require(WorktreeDiffInspector().inspect(projectPath: repoDir.path))
        #expect(diff.changedFiles == 1)
        #expect(diff.untrackedFiles == 1)
        #expect(diff.addedLines == 2)
        #expect(diff.deletedLines == 1)
        #expect(!FileManager.default.fileExists(atPath: repoDir.appendingPathComponent(".git/index.lock").path))

        let worktreeOutcome = AgentCollisionDetector.createIsolatedWorktree(from: repoDir.path, branchSlug: "codex-502")
        #expect(worktreeOutcome.succeeded)
        if let wtPath = worktreeOutcome.worktreePath {
            #expect(FileManager.default.fileExists(atPath: wtPath))
        }
    }

    @Test func estimatesQuotaBurnRateAndRecommendsBestProvider() {
        var tracker = QuotaBurnRateTracker()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = t0.addingTimeInterval(3 * 3600)

        tracker.record(
            windowsByProvider: [
                .claude: [QuotaWindow(kind: .fiveHour, usedPercent: 40, resetsAt: reset)],
                .codex: [QuotaWindow(kind: .fiveHour, usedPercent: 15, resetsAt: reset)]
            ],
            at: t0
        )
        let t1 = t0.addingTimeInterval(600) // +10 minutes, +10% used => 60%/hr
        let claudeWin = QuotaWindow(kind: .fiveHour, usedPercent: 50, resetsAt: reset)
        let codexWin = QuotaWindow(kind: .fiveHour, usedPercent: 16, resetsAt: reset)
        tracker.record(
            windowsByProvider: [
                .claude: [claudeWin],
                .codex: [codexWin]
            ],
            at: t1
        )

        let estimate = tracker.estimate(for: .claude, window: claudeWin, now: t1)
        #expect(estimate != nil)
        #expect(estimate?.willDepleteBeforeReset == true)
        #expect((estimate?.percentPerHour ?? 0) > 55)

        let rec = tracker.recommendProvider(
            windowsByProvider: [.claude: [claudeWin], .codex: [codexWin]],
            visibleProviders: [.claude, .codex],
            now: t1
        )
        #expect(rec?.provider == .codex)
    }

    @Test func detectsOrphanMCPHelpersWithoutLeakingArgsAndFlagsStuckAgents() {
        let mcpData = makeProcArgsData(
            executablePath: "/opt/homebrew/bin/node",
            argv: ["node", "/Users/dev/.npm/_npx/mcp-server-filesystem/index.js", "--secret-token=TOPSECRET"]
        )
        #expect(ProcessArgumentsReader.parseMCPHelperKind(
            from: mcpData,
            executablePath: "/opt/homebrew/bin/node"
        ) == "MCP Server (Node)")

        let normalNodeData = makeProcArgsData(
            executablePath: "/opt/homebrew/bin/node",
            argv: ["node", "server.js"]
        )
        #expect(ProcessArgumentsReader.parseMCPHelperKind(
            from: normalNodeData,
            executablePath: "/opt/homebrew/bin/node"
        ) == nil)

        let orphanProc = makeLiveProcess(pid: 910, parentPID: 1, uid: 501, executable: "/opt/homebrew/bin/node")
        let snapshot = InventorySnapshot(
            processes: [orphanProc],
            listeners: [],
            warnings: [],
            capturedAt: Date(),
            agentObservations: [],
            serverGroups: [],
            projectsByPath: [:]
        )
        let orphans = ProcessHealthAdvisor.detectOrphanToolProcesses(in: snapshot, uid: 501) { pid, _ in
            pid == 910 ? "MCP Server (Node)" : nil
        }
        #expect(orphans.count == 1)
        #expect(orphans[0].kindLabel == "MCP Server (Node)")

        var stuckTracker = StuckAgentTracker()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let spinningProc = makeLiveProcess(pid: 777, cpu: 94.0)
        let spinningObs = AgentObservation(
            id: 777,
            agentName: "Claude Code",
            process: spinningProc,
            project: nil,
            terminalApp: "Terminal",
            statusSource: .processOnly,
            childServerPorts: [],
            activityState: .active,
            lastActivityAt: base,
            currentTask: "Running Bash"
        )
        #expect(stuckTracker.evaluate(agents: [spinningObs], turnPreviews: [:]).isEmpty)
        #expect(stuckTracker.evaluate(agents: [spinningObs], turnPreviews: [:]).isEmpty)
        let third = stuckTracker.evaluate(agents: [spinningObs], turnPreviews: [:])
        #expect(third[777] != nil)

        // Advancing lastActivityAt clears the stuck warning immediately
        let progressedObs = AgentObservation(
            id: 777,
            agentName: "Claude Code",
            process: spinningProc,
            project: nil,
            terminalApp: "Terminal",
            statusSource: .processOnly,
            childServerPorts: [],
            activityState: .active,
            lastActivityAt: base.addingTimeInterval(15),
            currentTask: "Editing Models.swift"
        )
        let cleared = stuckTracker.evaluate(agents: [progressedObs], turnPreviews: [:])
        #expect(cleared.isEmpty)
    }
}
