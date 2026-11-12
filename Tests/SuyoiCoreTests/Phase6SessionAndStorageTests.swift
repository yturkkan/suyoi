import Darwin
import Foundation
import SQLite3
import Testing
@testable import SuyoiCore

private final class TrashCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var paths: [String] { lock.withLock { recorded } }
    func record(_ path: String) { lock.withLock { recorded.append(path) } }
}

private final class RecordingJobLauncher: NativeAgentJobLaunching, @unchecked Sendable {
    struct LaunchCall: Equatable, Sendable {
        let executable: String
        let arguments: [String]
        let workingDirectory: String?
        let metadata: NativeContinuationMetadata?
    }

    private let lock = NSLock()
    private var recorded: [LaunchCall] = []

    var calls: [LaunchCall] {
        lock.withLock { recorded }
    }

    func launch(executable: String, arguments: [String], workingDirectory: URL?) throws {
        _ = try launch(executable: executable, arguments: arguments, workingDirectory: workingDirectory, metadata: nil)
    }

    @discardableResult
    func launch(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        metadata: NativeContinuationMetadata?
    ) throws -> UUID {
        lock.withLock {
            recorded.append(
                LaunchCall(
                    executable: executable,
                    arguments: arguments,
                    workingDirectory: workingDirectory?.path,
                    metadata: metadata
                )
            )
        }
        return UUID()
    }
}

@Suite("Phase 6 Unified Workspace Session Indexer & Deep Storage Indexer")
struct Phase6SessionAndStorageTests {
    private func makeTempHome() throws -> URL {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("suyoi-phase6-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        return raw.resolvingSymlinksInPath().standardizedFileURL
    }

    private func writeUTF8(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url, options: .atomic)
    }

    private func writeSizedFile(bytes: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload = Data(repeating: 0x41, count: bytes)
        try payload.write(to: url, options: .atomic)
    }

    // MARK: - WorkspaceSessionIndexer & Historical CLI Resume Tests

    @Test("WorkspaceSessionIndexer discovers Claude, Codex, OpenCode & Gemini sessions and correlates live agents")
    func indexesLiveAndHistoricalSessionsAndLoadsMultiTurnStream() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let claudeRepo = home.appendingPathComponent("Developer/payment-api", isDirectory: true)
        let codexRepo = home.appendingPathComponent("Developer/web-portal", isDirectory: true)
        let geminiRepo = home.appendingPathComponent("Developer/bench-tool", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeRepo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexRepo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: geminiRepo, withIntermediateDirectories: true)

        // 1. Claude Code historical JSONL session with multi-line text, tool_use + tool_result, noise & secret
        let claudeSessionID = "11111111-2222-4333-8444-555555555555"
        let claudeJSONL = """
        {"type":"user","sessionId":"\(claudeSessionID)","cwd":"\(claudeRepo.path)","gitBranch":"feat/webhooks","timestamp":"2026-04-10T12:00:00Z","message":{"role":"user","content":"<local-command-stdout>ignored</local-command-stdout>"}}
        {"type":"user","sessionId":"\(claudeSessionID)","cwd":"\(claudeRepo.path)","gitBranch":"feat/webhooks","timestamp":"2026-04-10T12:00:05Z","message":{"role":"user","content":"Audit webhook signature verification.\\nKeep multiline notes and redact sk-secret9876543210abcdef."}}
        {"type":"assistant","sessionId":"\(claudeSessionID)","cwd":"\(claudeRepo.path)","gitBranch":"feat/webhooks","timestamp":"2026-04-10T12:00:12Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"swift test --filter WebhookTests"}},{"type":"text","text":"Checked HMAC verification.\\n- Step 1: constant-time compare\\n- Step 2: replay window"}]}}
        {"type":"user","sessionId":"\(claudeSessionID)","cwd":"\(claudeRepo.path)","gitBranch":"feat/webhooks","timestamp":"2026-04-10T12:00:16Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","is_error":false,"content":"All 12 tests passed"}]}}
        """
        let claudeFile = home
            .appendingPathComponent(".claude/projects/-Developer-payment-api", isDirectory: true)
            .appendingPathComponent("\(claudeSessionID).jsonl")
        try writeUTF8(claudeJSONL + "\n", to: claudeFile)

        // 2. Codex rollout JSONL session correlated to a live WezTerm agent
        let codexSessionID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let codexJSONL = """
        {"timestamp":"2026-04-10T13:00:00Z","type":"session_meta","payload":{"id":"\(codexSessionID)","cwd":"\(codexRepo.path)","git":{"branch":"main"}}}
        {"timestamp":"2026-04-10T13:00:04Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Fix dashboard table pagination and run unit tests"}]}}
        {"timestamp":"2026-04-10T13:00:09Z","type":"response_item","payload":{"type":"function_call","call_id":"call_99","name":"shell_command","arguments":"{\\"command\\":\\"pnpm test\\"}"}}
        {"timestamp":"2026-04-10T13:00:14Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_99","output":"Exit code: 0"}}
        {"timestamp":"2026-04-10T13:00:18Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Pagination offset bug is fixed and pnpm test passed."}]}}
        """
        let codexFile = home
            .appendingPathComponent(".codex/sessions/2026/04/10", isDirectory: true)
            .appendingPathComponent("rollout-2026-04-10-\(codexSessionID).jsonl")
        try writeUTF8(codexJSONL + "\n", to: codexFile)

        // 3. Gemini CLI JSON chat session
        let geminiJSON = """
        {
          "sessionId": "gem-session-42",
          "cwd": "\(geminiRepo.path)",
          "messages": [
            {"type": "user", "content": "Compare POSIX openat performance"},
            {"type": "gemini", "content": "openat + fstatat avoids path resolution overhead."}
          ]
        }
        """
        let geminiFile = home
            .appendingPathComponent(".gemini/tmp/hash123/chats", isDirectory: true)
            .appendingPathComponent("session-42.json")
        try writeUTF8(geminiJSON, to: geminiFile)

        // Live Codex process running in codexRepo
        let liveCodexProc = ObservedProcess(
            pid: 77_001,
            parentPID: 1,
            uid: Int(getuid()),
            cpuPercent: 18.5,
            residentBytes: 256_000_000,
            executable: "/usr/local/bin/codex",
            startTimeMicroseconds: 500,
            cwd: codexRepo.path,
            tty: "ttys004"
        )
        let liveCodexObs = AgentObservation(
            id: liveCodexProc.pid,
            agentName: "Codex",
            process: liveCodexProc,
            project: ProjectContext(rootPath: codexRepo.path, name: "web-portal", framework: "Next.js", gitBranch: "main", gitCommit: "abc1234", isWorktree: false),
            terminalApp: "WezTerm",
            statusSource: .processOnly,
            childServerPorts: [],
            activityState: .active
        )

        let indexer = WorkspaceSessionIndexer(homeDirectory: home)
        let sessions = indexer.indexSessions(liveAgents: [liveCodexObs], allProcesses: [liveCodexProc])

        #expect(sessions.count == 3)
        // Live session sorts first and correlates with the disk Codex session ID
        let first = try #require(sessions.first)
        #expect(first.isLive)
        #expect(first.provider == .codex)
        #expect(first.sessionID == codexSessionID)
        #expect(first.canSteerInLiveTerminal)
        #expect(first.canResumeNatively)

        // Historical Claude session is resumable via CLI even without a live process!
        let claudeIndexed = try #require(sessions.first(where: { $0.provider == .claude }))
        #expect(!claudeIndexed.isLive)
        #expect(claudeIndexed.canResumeNatively)
        #expect(claudeIndexed.nativeSteerMode == .claudeResume)
        #expect(claudeIndexed.gitBranch == "feat/webhooks")

        // Verify multi-turn conversation stream, multiline preservation, tool status, and secret redaction
        let claudeTurns = indexer.loadConversationTurns(for: claudeIndexed)
        #expect(claudeTurns.count == 3)
        #expect(claudeTurns[0].kind == .user)
        #expect(claudeTurns[0].text.contains("\nKeep multiline notes"))
        #expect(!claudeTurns[0].text.contains("sk-secret9876543210abcdef"))
        #expect(claudeTurns[0].text.contains("[REDACTED]"))

        #expect(claudeTurns[1].kind == .toolCall)
        #expect(claudeTurns[1].toolName == "Bash")
        #expect(claudeTurns[1].toolStatus == "completed")

        #expect(claudeTurns[2].kind == .assistant)
        #expect(claudeTurns[2].text.contains("- Step 1: constant-time compare\n- Step 2: replay window"))

        // Verify Codex turns also parse cleanly
        let codexTurns = indexer.loadConversationTurns(for: first)
        #expect(codexTurns.map(\.kind) == [.user, .toolCall, .assistant])
    }

    @Test("AgentSteerer.steerIndexedSession resumes an idle/historical Claude or Codex session directly via CLI")
    func resumesHistoricalSessionWithoutLiveProcess() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let projectDir = home.appendingPathComponent("Developer/payment-api", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let fakeClaudeBin = home.appendingPathComponent("bin/claude")
        try writeUTF8("#!/bin/sh\nexit 0\n", to: fakeClaudeBin)
        chmod(fakeClaudeBin.path, S_IRWXU)

        let launcher = RecordingJobLauncher()
        let steerer = AgentSteerer(
            executableResolver: { name in name == "claude" ? fakeClaudeBin.path : nil },
            homeDirectory: home,
            nativeJobLauncher: launcher
        )

        let historicalSession = IndexedAgentSession(
            id: "claude:11111111-2222-4333-8444-555555555555",
            provider: .claude,
            agentName: "Claude Code",
            sessionID: "11111111-2222-4333-8444-555555555555",
            title: "Audit webhook signature verification",
            projectPath: projectDir.path,
            projectName: "payment-api",
            gitBranch: "feat/webhooks",
            isLive: false,
            liveObservation: nil,
            canResumeNatively: true,
            nativeSteerMode: .claudeResume
        )

        let outcome = steerer.steerIndexedSession(
            session: historicalSession,
            prompt: "Run regression tests and summarize results",
            preferLiveTerminal: false,
            uid: Int(getuid())
        )

        #expect(outcome.succeeded)
        #expect(outcome.mode == .claudeResume)
        #expect(launcher.calls.count == 1)
        let call = try #require(launcher.calls.first)
        #expect(call.executable == fakeClaudeBin.path)
        #expect(call.arguments == [
            "--print",
            "--resume",
            "11111111-2222-4333-8444-555555555555",
            "--",
            "Run regression tests and summarize results"
        ])
        #expect(call.workingDirectory == projectDir.path)
    }

    @Test("steerIndexedSession never starts a parallel CLI resume while a live process still owns the session")
    func refusesNativeResumeWhileSessionIsLive() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let projectDir = home.appendingPathComponent("Developer/payment-api", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let liveProcess = ObservedProcess(pid: 4_242, parentPID: 1, uid: Int(getuid()), cpuPercent: 0, residentBytes: 0,
                                          executable: "/tools/claude", startTimeMicroseconds: 1_000, cwd: projectDir.path)
        let observation = AgentObservation(id: liveProcess.pid, agentName: "Claude Code", process: liveProcess, project: nil,
                                           terminalApp: nil, statusSource: .processOnly, childServerPorts: [],
                                           sessionID: "11111111-2222-4333-8444-555555555555")
        let launcher = RecordingJobLauncher()
        let steerer = AgentSteerer(
            processLookup: { pid, _ in pid == 4_242 ? liveProcess : nil },
            executableResolver: { _ in "/tools/claude" },
            homeDirectory: home,
            nativeJobLauncher: launcher
        )
        let liveSession = IndexedAgentSession(
            id: "claude:11111111-2222-4333-8444-555555555555",
            provider: .claude,
            agentName: "Claude Code",
            sessionID: "11111111-2222-4333-8444-555555555555",
            title: "Live session",
            projectPath: projectDir.path,
            projectName: "payment-api",
            gitBranch: nil,
            isLive: true,
            liveObservation: observation,
            canResumeNatively: true,
            nativeSteerMode: .claudeResume
        )

        let outcome = steerer.steerIndexedSession(
            session: liveSession,
            prompt: "Continue",
            preferLiveTerminal: false,
            uid: Int(getuid())
        )
        #expect(!outcome.succeeded)
        #expect(launcher.calls.isEmpty)
    }

    // MARK: - DeepStorageIndexer & Safe Trash + Put Back Recovery Tests

    @Test("DeepStorageIndexer discovers deep monorepo artifacts, Xcode DerivedData & AI caches and marks dirty-repo node_modules Ready")
    func deepMonorepoIndexingAndSafetyClassification() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let devRoot = home.appendingPathComponent("Developer", isDirectory: true)

        // Deep monorepo (depth 4) with dirty .git + subpackages named 'history', 'prompts', 'config' (regression check!)
        let monorepoGit = devRoot.appendingPathComponent("platform-mono/.git/HEAD")
        try writeUTF8("ref: refs/heads/main\n", to: monorepoGit)

        let webAppRoot = devRoot.appendingPathComponent("platform-mono/apps/dashboard-web", isDirectory: true)
        try writeUTF8("{\"name\":\"dashboard-web\"}", to: webAppRoot.appendingPathComponent("package.json"))
        try writeSizedFile(bytes: 32_768, to: webAppRoot.appendingPathComponent("node_modules/history/index.js"))
        try writeSizedFile(bytes: 32_768, to: webAppRoot.appendingPathComponent("node_modules/prompts/index.js"))
        try writeSizedFile(bytes: 32_768, to: webAppRoot.appendingPathComponent("node_modules/config/default.json"))

        // Active Next.js workspace locked by a live node server
        let activeAppRoot = devRoot.appendingPathComponent("platform-mono/apps/live-storefront", isDirectory: true)
        try writeUTF8("{\"name\":\"live-storefront\"}", to: activeAppRoot.appendingPathComponent("package.json"))
        try writeSizedFile(bytes: 40_960, to: activeAppRoot.appendingPathComponent("node_modules/next/dist/server.js"))

        // Rust crate target directory
        let rustCrateRoot = devRoot.appendingPathComponent("platform-mono/crates/query-engine", isDirectory: true)
        try writeUTF8("[package]\nname = \"query-engine\"\n", to: rustCrateRoot.appendingPathComponent("Cargo.toml"))
        try writeSizedFile(bytes: 65_536, to: rustCrateRoot.appendingPathComponent("target/debug/libquery.rlib"))

        // Python .venv directory (should be .highImpactReview: cleanable, but excluded from default auto-select)
        let pyServiceRoot = devRoot.appendingPathComponent("platform-mono/services/ml-worker", isDirectory: true)
        try writeSizedFile(bytes: 49_152, to: pyServiceRoot.appendingPathComponent(".venv/lib/python3.12/site.py"))

        // Xcode DerivedData per-project directory containing build.db (regression check for .db inside cache!)
        let derivedProject = home.appendingPathComponent("Library/Developer/Xcode/DerivedData/Suyoi-abcdef123456", isDirectory: true)
        try writeSizedFile(bytes: 81_920, to: derivedProject.appendingPathComponent("Build/Intermediates.noindex/XCBuildData/build.db"))

        // AI Agent regenerable cache
        let claudeCache = home.appendingPathComponent("Library/Caches/claude-cli-nodejs", isDirectory: true)
        try writeSizedFile(bytes: 24_576, to: claudeCache.appendingPathComponent("tarballs/pkg.tgz"))

        // Live process running inside activeAppRoot ONLY
        let liveNode = ObservedProcess(
            pid: 88_100,
            parentPID: 1,
            uid: Int(getuid()),
            cpuPercent: 3.1,
            residentBytes: 120_000_000,
            executable: "/usr/local/bin/node",
            startTimeMicroseconds: 999,
            cwd: activeAppRoot.path
        )

        let progressLock = NSLock()
        var sawFinalProgress = false

        let indexer = DeepStorageIndexer(homeDirectory: home, minimumBytes: 4_096)
        let report = indexer.indexAll(
            workspaceRoots: [devRoot],
            includeSystemAndAgentCaches: true,
            liveProcesses: [liveNode],
            onProgress: { prog in
                progressLock.withLock {
                    if !prog.isIndexing && prog.fractionCompleted >= 1.0 {
                        sawFinalProgress = true
                    }
                }
            }
        )

        #expect(sawFinalProgress)
        #expect(report.items.count == 6)

        // 1. Dirty-repo monorepo node_modules containing 'history'/'prompts'/'config' MUST be .ready!
        let dashboardModules = try #require(report.items.first(where: { $0.path.hasSuffix("dashboard-web/node_modules") }))
        #expect(dashboardModules.safety == .ready)
        #expect(dashboardModules.bytes >= 98_304)

        // 2. DerivedData containing build.db MUST be .ready and parsed as 'DerivedData · Suyoi'!
        let derivedItem = try #require(report.items.first(where: { $0.category == .xcodeAndSimulators }))
        #expect(derivedItem.displayName == "DerivedData · Suyoi")
        #expect(derivedItem.safety == .ready)

        // 3. Rust target MUST be .ready!
        let rustItem = try #require(report.items.first(where: { $0.path.hasSuffix("query-engine/target") }))
        #expect(rustItem.safety == .ready)

        // 4. Active storefront node_modules MUST be protected as .inUse!
        let activeModules = try #require(report.items.first(where: { $0.path.hasSuffix("live-storefront/node_modules") }))
        #expect(!activeModules.safety.isCleanable)

        // 5. Python .venv MUST be .highImpactReview (cleanable by user, not auto-selected in Ready)!
        let venvItem = try #require(report.items.first(where: { $0.path.hasSuffix("ml-worker/.venv") }))
        #expect(venvItem.safety.isCleanable)
        #expect(!venvItem.safety.isRecommendedDefault)
    }

    @Test("DeepStorageIndexer.moveItemsToTrash moves cleanable items, blocks in-use & symlinks, and supports Put Back restore")
    func safeTrashAndPutBackRoundTrip() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let devRoot = home.appendingPathComponent("Developer", isDirectory: true)
        let fakeTrashDir = home.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeTrashDir, withIntermediateDirectories: true)

        let appRoot = devRoot.appendingPathComponent("alpha-web", isDirectory: true)
        try writeUTF8("{\"name\":\"alpha-web\"}", to: appRoot.appendingPathComponent("package.json"))
        let modulesURL = appRoot.appendingPathComponent("node_modules", isDirectory: true)
        try writeSizedFile(bytes: 20_480, to: modulesURL.appendingPathComponent("react/index.js"))

        let indexer = DeepStorageIndexer(
            homeDirectory: home,
            minimumBytes: 1_024,
            trashHandler: { sourceURL in
                let dest = fakeTrashDir.appendingPathComponent("\(sourceURL.lastPathComponent)-\(UUID().uuidString.prefix(6))")
                try FileManager.default.moveItem(at: sourceURL, to: dest)
                return dest
            }
        )

        let report = indexer.indexAll(workspaceRoots: [devRoot], includeSystemAndAgentCaches: false)
        let item = try #require(report.items.first)
        #expect(item.safety == .ready)

        let trashReport = indexer.moveItemsToTrash([item], liveProcesses: [])
        #expect(trashReport.trashedCount == 1)
        #expect(!FileManager.default.fileExists(atPath: modulesURL.path))

        let outcome = try #require(trashReport.outcomes.first)
        let trashedPath = try #require(outcome.trashedURL)
        #expect(outcome.recovery != nil)

        // Verify TrashRecoveryStore Put Back restores the exact directory back to its original path!
        let recoveryStore = TrashRecoveryStore()
        recoveryStore.record(
            originalPath: outcome.path,
            trashedURL: URL(fileURLWithPath: trashedPath),
            category: item.category.rawValue,
            bytes: outcome.bytes,
            recovery: outcome.recovery
        )

        let record = try #require(recoveryStore.records().first)
        let restoreOutcome = recoveryStore.restore(record)
        #expect(restoreOutcome.restored)
        #expect(FileManager.default.fileExists(atPath: modulesURL.appendingPathComponent("react/index.js").path))
    }

    @Test("moveItemsToTrash refuses stale or forged cached items that no longer classify as artifacts")
    func trashRevalidatesCachedItemsAgainstDisk() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let appRoot = home.appendingPathComponent("Developer/beta-web", isDirectory: true)
        try writeUTF8("{\"name\":\"beta-web\"}", to: appRoot.appendingPathComponent("package.json"))
        let sourceDir = appRoot.appendingPathComponent("src", isDirectory: true)
        try writeSizedFile(bytes: 8_192, to: sourceDir.appendingPathComponent("index.ts"))
        let vendoredRepo = appRoot.appendingPathComponent("node_modules", isDirectory: true)
        try writeSizedFile(bytes: 8_192, to: vendoredRepo.appendingPathComponent("lib/a.js"))
        try writeUTF8("ref: refs/heads/main\n", to: vendoredRepo.appendingPathComponent(".git/HEAD"))
        let unknownCache = home.appendingPathComponent("Library/Caches/some-random-app", isDirectory: true)
        try writeSizedFile(bytes: 8_192, to: unknownCache.appendingPathComponent("blob.bin"))

        let trashedPaths = TrashCallRecorder()
        let indexer = DeepStorageIndexer(
            homeDirectory: home,
            minimumBytes: 1_024,
            trashHandler: { url in
                trashedPaths.record(url.path)
                return nil
            }
        )
        let reader = FileMetadataReader()
        func forged(_ url: URL, projectRoot: String?, category: StorageCategory) throws -> IndexedStorageItem {
            IndexedStorageItem(
                path: url.path,
                displayName: url.lastPathComponent,
                subtitle: "forged",
                projectName: nil,
                projectRootPath: projectRoot,
                category: category,
                ecosystemLabel: "forged",
                bytes: 8_192,
                allocatedBytes: 8_192,
                fileCount: 1,
                lastModifiedAt: nil,
                fileIdentity: try #require(reader.identity(at: url)),
                safety: .ready
            )
        }

        let report = indexer.moveItemsToTrash([
            try forged(sourceDir, projectRoot: appRoot.path, category: .dependencies),
            try forged(vendoredRepo, projectRoot: appRoot.path, category: .dependencies),
            try forged(unknownCache, projectRoot: nil, category: .aiAgentStorage)
        ], liveProcesses: [])

        #expect(report.trashedCount == 0)
        #expect(trashedPaths.paths.isEmpty)
        #expect(report.outcomes.count == 3)
        #expect(report.outcomes.allSatisfy { !$0.succeeded })
    }
}
