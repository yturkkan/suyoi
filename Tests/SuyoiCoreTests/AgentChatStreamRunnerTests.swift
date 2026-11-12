import CryptoKit
import Darwin
import Foundation
import Testing
@testable import SuyoiCore

private final class StreamEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AgentChatStreamEvent] = []
    private let finishedSemaphore = DispatchSemaphore(value: 0)
    private var didSignalFinished = false

    var events: [AgentChatStreamEvent] {
        lock.withLock { stored }
    }

    func append(_ event: AgentChatStreamEvent) {
        var shouldSignal = false
        lock.withLock {
            stored.append(event)
            if case .finished = event, !didSignalFinished {
                didSignalFinished = true
                shouldSignal = true
            }
        }
        if shouldSignal {
            finishedSemaphore.signal()
        }
    }

    func waitForFinish(timeoutSeconds: TimeInterval = 5.0) -> Bool {
        finishedSemaphore.wait(timeout: .now() + timeoutSeconds) == .success
    }
}

private final class RecordingSteerJobLauncher: NativeAgentJobLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var lastExecutable: String?
    private(set) var lastArguments: [String] = []
    private(set) var lastWorkingDirectory: String?

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
            lastExecutable = executable
            lastArguments = arguments
            lastWorkingDirectory = workingDirectory?.path
        }
        return UUID()
    }
}

@Suite("Unified Agent Chat Stream Runner & Gemini Session Discovery")
struct AgentChatStreamRunnerTests {
    private func makeTempDir() throws -> URL {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("suyoi-chat-stream-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        return raw.resolvingSymlinksInPath().standardizedFileURL
    }

    private func writeExecutableScript(_ script: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(script.utf8).write(to: url, options: .atomic)
        chmod(url.path, S_IRWXU)
    }

    @Test("buildArguments constructs safe new-chat and resume CLI invocations for Codex, Gemini, OpenCode, and Claude")
    func buildArgumentsForAllChatProviders() throws {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

        // 1. Codex new chat & resume
        let codexNew = try AgentChatStreamRunner.buildArguments(
            for: AgentChatStreamRequest(provider: .codex, projectPath: "/Users/tester/repo", prompt: "Özet çıkar"),
            homeDirectory: home
        ).get()
        #expect(codexNew.prefix(3) == ["exec", "--json", "--skip-git-repo-check"])
        #expect(codexNew.suffix(2) == ["--", "Özet çıkar"])

        let codexResume = try AgentChatStreamRunner.buildArguments(
            for: AgentChatStreamRequest(provider: .codex, sessionID: "019c1111-2222-7333-8444-555555555555", projectPath: "/Users/tester/repo", prompt: "Devam et"),
            homeDirectory: home
        ).get()
        #expect(codexResume.contains("resume"))
        #expect(codexResume.suffix(4) == ["resume", "019c1111-2222-7333-8444-555555555555", "--", "Devam et"])

        // 2. Gemini CLI new chat & resume (--prompt=... avoids leading-dash flag confusion)
        let geminiNew = try AgentChatStreamRunner.buildArguments(
            for: AgentChatStreamRequest(provider: .gemini, projectPath: "/Users/tester/repo", prompt: "--help flag test"),
            homeDirectory: home
        ).get()
        #expect(geminiNew == ["--output-format", "stream-json", "--prompt=--help flag test"])

        let geminiResume = try AgentChatStreamRunner.buildArguments(
            for: AgentChatStreamRequest(provider: .gemini, sessionID: "gem-session-99", projectPath: "/Users/tester/repo", prompt: "Analiz et"),
            homeDirectory: home
        ).get()
        #expect(geminiResume == ["--resume", "gem-session-99", "--output-format", "stream-json", "--prompt=Analiz et"])

        // 3. OpenCode new chat & resume (no non-existent --standalone flag)
        let openCodeResume = try AgentChatStreamRunner.buildArguments(
            for: AgentChatStreamRequest(provider: .openCode, sessionID: "ses_abc123", projectPath: "/Users/tester/repo", prompt: "Testleri çalıştır"),
            homeDirectory: home
        ).get()
        #expect(openCodeResume == ["run", "--format", "json", "--session", "ses_abc123", "--", "Testleri çalıştır"])
        #expect(!openCodeResume.contains("--standalone"))

        // 4. Claude Code new chat & resume
        let claudeResume = try AgentChatStreamRunner.buildArguments(
            for: AgentChatStreamRequest(provider: .claude, sessionID: "11111111-2222-4333-8444-555555555555", projectPath: "/Users/tester/repo", prompt: "Fix lint"),
            homeDirectory: home
        ).get()
        #expect(claudeResume == ["-p", "--verbose", "--output-format", "stream-json", "--resume", "11111111-2222-4333-8444-555555555555", "--", "Fix lint"])
    }

    @Test("AgentChatStreamRunner streams Codex NDJSON events end-to-end with Turkish UTF-8 characters")
    func streamsCodexEndToEnd() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let repoDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)

        let fakeCodex = root.appendingPathComponent("bin/codex")
        let script = """
        #!/bin/sh
        printf '%s\\n' '{"type":"thread.started","thread_id":"019c9999-aaaa-7bbb-8ccc-ddddeeeeffff"}'
        printf '%s\\n' '{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"swift test","status":"in_progress"}}'
        printf '%s\\n' '{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"swift test","exit_code":0,"status":"completed"}}'
        printf '%s\\n' '{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"Tüm testler geçti — şğıİöüç karakter desteği doğrulandı."}}'
        """
        try writeExecutableScript(script, to: fakeCodex)

        let runner = AgentChatStreamRunner(
            homeDirectory: root,
            executableResolver: { provider in provider == .codex ? fakeCodex.path : nil }
        )
        let box = StreamEventBox()
        let result = runner.start(
            request: AgentChatStreamRequest(provider: .codex, projectPath: repoDir.path, prompt: "Testleri kontrol et")
        ) { event in
            box.append(event)
        }
        _ = try result.get()
        #expect(box.waitForFinish())

        let events = box.events
        #expect(events.contains(.sessionStarted("019c9999-aaaa-7bbb-8ccc-ddddeeeeffff")))
        #expect(events.contains { event in
            if case .toolCallUpdated(let turn) = event {
                return turn.toolName == "shell" && turn.toolStatus == "completed" && turn.text.contains("swift test")
            }
            return false
        })
        #expect(events.contains(.assistantMessageUpdated(
            id: "codex-item_2",
            text: "Tüm testler geçti — şğıİöüç karakter desteği doğrulandı."
        )))
        #expect(events.last == .finished(exitCode: 0))
    }

    @Test("AgentStreamLineParser concatenates Gemini delta chunks without stripping inter-word spaces and ignores user echo")
    func parsesGeminiStreamingDeltasAndTools() {
        var parser = AgentStreamLineParser(provider: .gemini)

        let e1 = parser.parseLine(#"{"type":"init","session_id":"gem-live-777","model":"gemini-2.5-pro"}"#)
        #expect(e1 == [.sessionStarted("gem-live-777")])

        // User prompt echo must be ignored
        let e2 = parser.parseLine(#"{"type":"message","role":"user","content":"Bu klasörü özetle"}"#)
        #expect(e2.isEmpty)

        // Streaming assistant deltas preserve spaces between tokens
        let e3 = parser.parseLine(#"{"type":"message","role":"assistant","content":"Merhaba ","delta":true}"#)
        let e4 = parser.parseLine(#"{"type":"message","role":"assistant","content":"dünya! ","delta":true}"#)
        let e5 = parser.parseLine(#"{"type":"message","role":"assistant","content":"Proje hazır.","delta":true}"#)
        #expect(e3 == [.assistantMessageUpdated(id: "gemini-msg-1", text: "Merhaba")])
        #expect(e4 == [.assistantMessageUpdated(id: "gemini-msg-1", text: "Merhaba dünya!")])
        #expect(e5 == [.assistantMessageUpdated(id: "gemini-msg-1", text: "Merhaba dünya! Proje hazır.")])

        // Tool call followed by tool result retains tool name and summary
        let e6 = parser.parseLine(#"{"type":"tool_use","tool_id":"call_1","tool_name":"run_shell_command","parameters":{"command":"git status --short"}}"#)
        #expect(e6.count == 1)
        if case .toolCallUpdated(let runningTool) = e6.first {
            #expect(runningTool.toolName == "run_shell_command")
            #expect(runningTool.toolStatus == "running")
            #expect(runningTool.text.contains("git status --short"))
        } else {
            Issue.record("Expected running toolCallUpdated event")
        }

        let e7 = parser.parseLine(#"{"type":"tool_result","tool_id":"call_1","status":"success"}"#)
        if case .toolCallUpdated(let finishedTool) = e7.first {
            #expect(finishedTool.toolName == "run_shell_command")
            #expect(finishedTool.toolStatus == "completed")
            #expect(finishedTool.text.contains("git status --short"))
        } else {
            Issue.record("Expected completed toolCallUpdated event")
        }
    }

    @Test("AgentStreamLineParser parses OpenCode JSON events including sessionID, tools, and cumulative/delta text parts")
    func parsesOpenCodeStreamEvents() {
        var parser = AgentStreamLineParser(provider: .openCode)

        let e1 = parser.parseLine(#"{"type":"step_start","sessionID":"ses_opencode_42"}"#)
        #expect(e1 == [.sessionStarted("ses_opencode_42")])

        let e2 = parser.parseLine(#"{"type":"tool_use","sessionID":"ses_opencode_42","part":{"id":"prt_t1","type":"tool","tool":"bash","state":{"status":"completed","input":{"command":"bun test"}}}}"#)
        if case .toolCallUpdated(let toolTurn) = e2.first {
            #expect(toolTurn.toolName == "bash")
            #expect(toolTurn.toolStatus == "completed")
            #expect(toolTurn.text.contains("bun test"))
        } else {
            Issue.record("Expected OpenCode toolCallUpdated")
        }

        let e3 = parser.parseLine(#"{"type":"text","sessionID":"ses_opencode_42","part":{"id":"prt_m1","type":"text","text":"İlk satır"}}"#)
        let e4 = parser.parseLine(#"{"type":"text","sessionID":"ses_opencode_42","part":{"id":"prt_m1","type":"text","text":"İlk satır ve devamı"}}"#)
        #expect(e3 == [.assistantMessageUpdated(id: "oc-prt_m1", text: "İlk satır")])
        #expect(e4 == [.assistantMessageUpdated(id: "oc-prt_m1", text: "İlk satır ve devamı")])
    }

    @Test("AgentChatStreamRunner surfaces non-zero exit stderr and supports mid-stream cancellation")
    func handlesErrorsAndCancellation() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let repoDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)

        // 1. Failing CLI surfaces cleaned stderr message
        let failingBin = root.appendingPathComponent("bin/gemini")
        try writeExecutableScript(
            """
            #!/bin/sh
            printf '%s\\n' 'Authentication expired: please run gemini auth' >&2
            exit 2
            """,
            to: failingBin
        )

        let failRunner = AgentChatStreamRunner(
            homeDirectory: root,
            executableResolver: { provider in provider == .gemini ? failingBin.path : nil }
        )
        let failBox = StreamEventBox()
        _ = try failRunner.start(
            request: AgentChatStreamRequest(provider: .gemini, projectPath: repoDir.path, prompt: "Hello")
        ) { failBox.append($0) }.get()
        #expect(failBox.waitForFinish())
        #expect(failBox.events.contains(.error("Authentication expired: please run gemini auth")))
        #expect(failBox.events.last == .finished(exitCode: 2))

        // 2. Cancelling a running stream terminates cleanly without emitting a spurious error
        let sleeperBin = root.appendingPathComponent("bin/opencode")
        try writeExecutableScript(
            """
            #!/bin/sh
            printf '%s\\n' '{"type":"step_start","sessionID":"ses_cancel_1"}'
            sleep 30
            """,
            to: sleeperBin
        )

        let cancelRunner = AgentChatStreamRunner(
            homeDirectory: root,
            executableResolver: { provider in provider == .openCode ? sleeperBin.path : nil }
        )
        let cancelBox = StreamEventBox()
        let runID = try cancelRunner.start(
            request: AgentChatStreamRequest(provider: .openCode, projectPath: repoDir.path, prompt: "Long task")
        ) { cancelBox.append($0) }.get()

        usleep(120_000)
        #expect(cancelRunner.cancel(runID: runID))
        #expect(cancelBox.waitForFinish())
        let hasError = cancelBox.events.contains {
            if case .error = $0 { return true }
            return false
        }
        #expect(!hasError)
    }

    @Test("WorkspaceSessionIndexer resolves Gemini CLI project paths via projects.json and SHA256 hashes, skips checkpoints, and enables .geminiResume")
    func discoversResumableGeminiSessionsAndSteersViaCLI() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }

        let slugRepo = home.appendingPathComponent("Developer/slug-mapped-app", isDirectory: true)
        let hashRepo = home.appendingPathComponent("Developer/hash-mapped-app", isDirectory: true)
        try FileManager.default.createDirectory(at: slugRepo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hashRepo, withIntermediateDirectories: true)

        // 1. ~/.gemini/projects.json mapping slugRepo -> "slug-mapped-app"
        let projectsJSON = """
        {
          "projects": {
            "\(slugRepo.path)": "slug-mapped-app"
          }
        }
        """
        let projectsFile = home.appendingPathComponent(".gemini/projects.json")
        try FileManager.default.createDirectory(at: projectsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(projectsJSON.utf8).write(to: projectsFile, options: .atomic)

        let slugChatFile = home
            .appendingPathComponent(".gemini/tmp/slug-mapped-app/chats", isDirectory: true)
            .appendingPathComponent("session-2026-04-12-abc1.json")
        let slugChatPayload = """
        {
          "sessionId": "gem-slug-001",
          "messages": [
            {"type": "user", "content": [{"text": "Slug projeyi incele"}]},
            {"type": "gemini", "content": [{"text": "İnceleme tamamlandı."}]}
          ]
        }
        """
        try FileManager.default.createDirectory(at: slugChatFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(slugChatPayload.utf8).write(to: slugChatFile, options: .atomic)

        // Checkpoint file in same folder must be skipped
        let checkpointFile = home
            .appendingPathComponent(".gemini/tmp/slug-mapped-app/chats", isDirectory: true)
            .appendingPathComponent("checkpoint-before-edit.json")
        try Data(#"{"sessionId":"gem-checkpoint-ignored","messages":[{"type":"user","content":"skip me"}]}"#.utf8)
            .write(to: checkpointFile, options: .atomic)

        // 2. Legacy SHA-256 directory hash bucket under ~/.gemini/tmp/<sha256>/chats/
        let shaHex = SHA256.hash(data: Data(hashRepo.path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let hashChatFile = home
            .appendingPathComponent(".gemini/tmp/\(shaHex)/chats", isDirectory: true)
            .appendingPathComponent("session-hash-002.json")
        let hashChatPayload = """
        {
          "sessionId": "gem-hash-002",
          "messages": [
            {"type": "user", "parts": [{"text": "SHA256 dizin eşleşmesini doğrula"}]},
            {"type": "model", "parts": [{"text": "Başarıyla eşleşti."}]}
          ]
        }
        """
        try FileManager.default.createDirectory(at: hashChatFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(hashChatPayload.utf8).write(to: hashChatFile, options: .atomic)

        let indexer = WorkspaceSessionIndexer(homeDirectory: home)
        let sessions = indexer.indexSessions(liveAgents: [], allProcesses: [])

        #expect(!sessions.contains(where: { $0.sessionID == "gem-checkpoint-ignored" }))

        let slugSession = try #require(sessions.first(where: { $0.sessionID == "gem-slug-001" }))
        #expect(slugSession.projectPath == slugRepo.path)
        #expect(slugSession.canResumeNatively)
        #expect(slugSession.nativeSteerMode == .geminiResume)
        let slugTurns = indexer.loadConversationTurns(for: slugSession)
        #expect(slugTurns.count == 2)
        #expect(slugTurns[0].text == "Slug projeyi incele")
        #expect(slugTurns[1].text == "İnceleme tamamlandı.")

        let hashSession = try #require(sessions.first(where: { $0.sessionID == "gem-hash-002" }))
        #expect(hashSession.projectPath == hashRepo.path)
        #expect(hashSession.canResumeNatively)
        #expect(hashSession.nativeSteerMode == .geminiResume)
        let hashTurns = indexer.loadConversationTurns(for: hashSession)
        #expect(hashTurns.count == 2)
        #expect(hashTurns[0].text == "SHA256 dizin eşleşmesini doğrula")

        // Verify AgentSteerer.steerIndexedSession invokes gemini --resume <id> --prompt=<prompt>
        let fakeGeminiBin = home.appendingPathComponent("bin/gemini")
        try writeExecutableScript("#!/bin/sh\nexit 0\n", to: fakeGeminiBin)
        let launcher = RecordingSteerJobLauncher()
        let steerer = AgentSteerer(
            executableResolver: { name in name == "gemini" ? fakeGeminiBin.path : nil },
            homeDirectory: home,
            nativeJobLauncher: launcher
        )
        let outcome = steerer.steerIndexedSession(
            session: slugSession,
            prompt: "Devam edelim",
            preferLiveTerminal: false,
            uid: Int(getuid())
        )
        #expect(outcome.succeeded)
        #expect(outcome.mode == .geminiResume)
        #expect(launcher.lastArguments == ["--resume", "gem-slug-001", "--prompt=Devam edelim"])
        #expect(launcher.lastWorkingDirectory == slugRepo.path)
    }
}
