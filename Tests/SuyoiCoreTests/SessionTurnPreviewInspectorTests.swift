import Foundation
import Darwin
import Testing
@testable import SuyoiCore

@Suite("Bounded session turn previews")
struct SessionTurnPreviewInspectorTests {
    private let codexPath = ".codex/sessions/2026/11/08/rollout-turn-a.jsonl"
    private let claudePath = ".claude/projects/-workspace-app/turn-a.jsonl"
    private let timestamp = "2026-11-08T10:00:00Z"

    private struct Fixture {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("suyoi-preview-\(UUID().uuidString)")

        init() throws { try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true) }
        func clean() { try? FileManager.default.removeItem(at: home) }
        func write(_ records: [[String: Any]], to path: String) throws {
            var data = Data()
            for record in records {
                data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
                data.append(10)
            }
            try write(data, to: path)
        }
        func write(_ data: Data, to path: String) throws {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        func inspect(_ agent: AgentObservation, processes: [ObservedProcess] = []) -> SessionTurnPreview? {
            SessionTurnPreviewInspector(homeDirectory: home).inspectPreview(for: agent, allProcesses: processes)
        }
    }

    private func process(_ name: String = "codex", pid: Int = 400, parent: Int = 1, uid: Int = 501, stopped: Bool = false, cwd: String? = "/workspace/app") -> ObservedProcess {
        ObservedProcess(pid: pid, parentPID: parent, uid: uid, cpuPercent: 1, residentBytes: 0,
                        executable: "/bin/\(name)", startTimeMicroseconds: 100, cwd: cwd, isStopped: stopped)
    }

    private func agent(_ name: String = "Codex", sessionID: String? = "turn-a", root: String? = "/workspace/app", task: String? = nil, stopped: Bool = false) -> AgentObservation {
        let p = process(name == "Codex" ? "codex" : "claude", stopped: stopped, cwd: root)
        let project = root.map { ProjectContext(rootPath: $0, name: "app", framework: nil, gitBranch: nil, gitCommit: nil, isWorktree: false) }
        return AgentObservation(id: p.pid, agentName: name, process: p, project: project, terminalApp: nil,
                                statusSource: .processOnly, childServerPorts: [], sessionID: sessionID, currentTask: task)
    }

    private func meta(_ id: String = "turn-a", root: String = "/workspace/app") -> [String: Any] {
        ["type": "session_meta", "payload": ["id": id, "cwd": root]]
    }

    private func event(_ type: String, _ message: String, stamp: String? = nil) -> [String: Any] {
        ["type": "event_msg", "timestamp": stamp ?? timestamp, "payload": ["type": type, "message": message]]
    }

    private func response(_ payload: [String: Any], stamp: String? = nil) -> [String: Any] {
        ["type": "response_item", "timestamp": stamp ?? timestamp, "payload": payload]
    }

    private func claude(_ role: String, content: Any, id: String = "turn-a", root: String = "/workspace/app") -> [String: Any] {
        ["type": role, "sessionId": id, "cwd": root, "timestamp": timestamp, "message": ["role": role, "content": content]]
    }

    private static let secretSamples: [String] = [
        "sk-" + String(repeating: "a", count: 24),
        "sk-proj-" + String(repeating: "b", count: 24),
        "sk-ant-api03-" + String(repeating: "c", count: 24),
        "ghp_" + String(repeating: "d", count: 24),
        "gho_" + String(repeating: "e", count: 24),
        "ghu_" + String(repeating: "f", count: 24),
        "ghs_" + String(repeating: "g", count: 24),
        "ghr_" + String(repeating: "h", count: 24),
        "AIza" + String(repeating: "i", count: 24),
        "Bearer " + String(repeating: "j", count: 24) + ".abc_def-123",
        "bearer\n" + String(repeating: "k", count: 24),
        "eyJ" + String(repeating: "l", count: 16) + "." + String(repeating: "m", count: 16),
        "eyJ" + String(repeating: "n", count: 16) + "." + String(repeating: "o", count: 16) + ".signature"
    ]

    @Test(arguments: SessionTurnPreviewInspectorTests.secretSamples)
    func commonSecretsAreFullyRedacted(_ secret: String) {
        #expect(SessionTurnPreviewInspector.sanitizeAndRedact("before \(secret) after") == "before [REDACTED] after")
    }

    @Test func whitespaceControlsAndEmptyInput() {
        #expect(SessionTurnPreviewInspector.sanitizeAndRedact("  one\n\r\t two\u{00a0}three\0\u{0007} \u{202e}four  ") == "one two three four")
        #expect(SessionTurnPreviewInspector.sanitizeAndRedact("\0\n\t ") == nil)
        #expect(SessionTurnPreviewInspector.sanitizeAndRedact("") == nil)
        let splitSecret = "sk-" + String(repeating: "a", count: 8) + "\0" + String(repeating: "b", count: 8)
        #expect(SessionTurnPreviewInspector.sanitizeAndRedact(splitSecret) == "[REDACTED]")
    }

    @Test func lengthIncludesEllipsisAndRespectsCharacters() {
        #expect(SessionTurnPreviewInspector.sanitizeAndRedact("abc", maxLength: 0) == nil)
        #expect(SessionTurnPreviewInspector.sanitizeAndRedact("abc", maxLength: -1) == nil)
        #expect(SessionTurnPreviewInspector.sanitizeAndRedact("abc", maxLength: 1) == "…")
        #expect(SessionTurnPreviewInspector.sanitizeAndRedact("abc", maxLength: 3) == "abc")
        #expect(SessionTurnPreviewInspector.sanitizeAndRedact("abcd", maxLength: 3) == "ab…")
        #expect(SessionTurnPreviewInspector.sanitizeAndRedact(String(repeating: "👨‍👩‍👧", count: 170))?.count == 160)
        #expect(SessionTurnPreviewInspector.sanitizeAndRedact(String(repeating: "x", count: 200)) == String(repeating: "x", count: 159) + "…")
        let secret = "sk-" + String(repeating: "a", count: 200)
        #expect(SessionTurnPreviewInspector.sanitizeAndRedact(secret, maxLength: 12) == "[REDACTED]")
    }

    @Test func previewContractsRoundTrip() throws {
        let preview = SessionTurnPreview(sessionID: "turn-a", lastUserPromptPreview: "Review changes", lastAssistantReplyPreview: nil,
                                         recentTools: [SessionToolCallSummary(toolName: "Read", targetSummary: "file.swift", status: "completed")],
                                         updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(try JSONDecoder().decode(SessionTurnPreview.self, from: JSONEncoder().encode(preview)) == preview)
    }

    @Test func codexLatestMessagesAndAllowedRoles() throws {
        let f = try Fixture(); defer { f.clean() }
        try f.write([
            meta(), event("user_message", "Earlier request"), event("agent_message", "Earlier reply"),
            response(["type": "message", "role": "user", "content": [["type": "input_text", "text": "Latest\nrequest"]]]),
            response(["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Latest reply"], ["type": "image", "text": "Hidden image"]]], stamp: "2026-11-08T10:00:02.500Z"),
            response(["type": "message", "role": "developer", "content": [["type": "input_text", "text": "Hidden instructions"]]]),
            event("token_count", "Hidden metadata", stamp: "2026-11-08T11:00:00Z")
        ], to: codexPath)
        let preview = try #require(f.inspect(agent()))
        #expect(preview.sessionID == "turn-a")
        #expect(preview.lastUserPromptPreview == "Latest request")
        #expect(preview.lastAssistantReplyPreview == "Latest reply")
        #expect(preview.recentTools.isEmpty)
        #expect(preview.updatedAt == Date(timeIntervalSince1970: 1_794_132_002.5))
    }

    @Test func codexEventMessagesRedactBothSides() throws {
        let f = try Fixture(); defer { f.clean() }
        let secret = "sk-ant-" + String(repeating: "a", count: 30)
        try f.write([meta(), event("user_message", "Check \(secret)"), event("agent_message", "Authorization: Bearer abc.def_ghi-123")], to: codexPath)
        let preview = try #require(f.inspect(agent()))
        #expect(preview.lastUserPromptPreview == "Check [REDACTED]")
        #expect(preview.lastAssistantReplyPreview == "Authorization: [REDACTED]")
    }

    @Test func codexRecentToolsAreBoundedAndResultsNeverBecomeReplies() throws {
        let f = try Fixture(); defer { f.clean() }
        let secret = "ghp_" + String(repeating: "a", count: 24)
        var records = [meta(), event("agent_message", "Working")]
        for index in 0..<4 {
            records.append(response(["type": "function_call", "name": "tool\(index)", "call_id": "call\(index)", "arguments": "{\"command\":\"echo \(secret)\",\"private\":\"Do not display\"}"]))
            if index < 3 { records.append(response(["type": "function_call_output", "call_id": "call\(index)", "output": "Private tool result", "is_error": index == 2])) }
        }
        let duplicate = response(["type": "function_call", "name": "duplicate", "call_id": "call3", "arguments": "{}"])
        records.append(duplicate)
        try f.write(records, to: codexPath)
        let preview = try #require(f.inspect(agent()))
        #expect(preview.recentTools.map(\.toolName) == ["tool3", "tool2", "tool1"])
        #expect(preview.recentTools.map(\.status) == ["running", "failed", "completed"])
        #expect(preview.recentTools.allSatisfy { $0.targetSummary == "echo [REDACTED]" })
        #expect(preview.lastAssistantReplyPreview == "Working")
    }

    @Test func claudeTextToolCallsAndResults() throws {
        let f = try Fixture(); defer { f.clean() }
        let secret = "AIza" + String(repeating: "b", count: 24)
        try f.write([
            claude("user", content: "Open the file"),
            claude("assistant", content: [["type": "thinking", "text": "Private reasoning"],
                                          ["type": "text", "text": "Reading\nnow"],
                                          ["type": "tool_use", "id": "read1", "name": "Read", "input": ["file_path": "/workspace/\(secret)", "secret": "Hidden argument"]]]),
            claude("user", content: [["type": "tool_result", "tool_use_id": "read1", "content": "Hidden output", "is_error": false]]),
            claude("assistant", content: [["type": "text", "text": "Done \(secret)"]])
        ], to: claudePath)
        let preview = try #require(f.inspect(agent("Claude Code")))
        #expect(preview.sessionID == "turn-a")
        #expect(preview.lastUserPromptPreview == "Open the file")
        #expect(preview.lastAssistantReplyPreview == "Done [REDACTED]")
        #expect(preview.recentTools == [SessionToolCallSummary(toolName: "Read", targetSummary: "/workspace/[REDACTED]", status: "completed")])
    }

    @Test func claudeFailedToolsSidechainsAndNonTextBlocks() throws {
        let f = try Fixture(); defer { f.clean() }
        var sidechain = claude("assistant", content: "Hidden subtask")
        sidechain["isSidechain"] = true
        try f.write([
            claude("user", content: [["type": "text", "text": "First"], ["type": "text", "text": "request"], ["type": "image", "text": "Hidden image"]]),
            claude("assistant", content: "Main reply"),
            claude("assistant", content: [["type": "tool_use", "id": "run1", "name": "Bash", "input": ["command": "swift build"]]]),
            claude("user", content: [["type": "tool_result", "tool_use_id": "run1", "is_error": true, "content": "Hidden error"]]), sidechain
        ], to: claudePath)
        let preview = try #require(f.inspect(agent("Claude Code")))
        #expect(preview.lastUserPromptPreview == "First request")
        #expect(preview.lastAssistantReplyPreview == "Main reply")
        #expect(preview.recentTools.first?.status == "failed")
    }

    @Test func explicitSessionDoesNotFallBackToAnotherSession() throws {
        let f = try Fixture(); defer { f.clean() }
        try f.write([meta("other"), event("user_message", "Other session")], to: codexPath)
        #expect(f.inspect(agent()) == nil)
        #expect(f.inspect(agent(sessionID: "../turn-a")) == nil)
        try f.write([claude("user", content: "Other session", id: "other")], to: claudePath)
        #expect(f.inspect(agent("Claude Code")) == nil)
        try f.write([meta(), meta("other"), event("user_message", "Mixed session")], to: codexPath)
        #expect(f.inspect(agent()) == nil)
    }

    @Test func projectFallbackSelectsLatestMatchingCodexFile() throws {
        let f = try Fixture(); defer { f.clean() }
        let older = ".codex/sessions/2026/11/07/older.jsonl"
        let unrelated = ".codex/sessions/2026/11/08/unrelated.jsonl"
        try f.write([meta("older"), event("user_message", "Old request")], to: older)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: f.home.appendingPathComponent(older).path)
        try f.write([meta(), event("user_message", "Current request")], to: codexPath)
        try f.write([meta("unrelated", root: "/workspace/other"), event("user_message", "Unrelated request")], to: unrelated)
        let preview = try #require(f.inspect(agent(sessionID: nil, root: "/workspace/app/.")))
        #expect(preview.sessionID == "turn-a")
        #expect(preview.lastUserPromptPreview == "Current request")
        #expect(f.inspect(agent(sessionID: nil, root: "/workspace/ap")) == nil)
        #expect(f.inspect(agent(sessionID: nil, root: nil)) == nil)
        #expect(f.inspect(agent(sessionID: nil, root: "/")) == nil)
        #expect(f.inspect(agent(sessionID: nil, root: f.home.path)) == nil)
    }

    @Test func claudeProjectDirectoryAndFilenameFallback() throws {
        let f = try Fixture(); defer { f.clean() }
        let record: [String: Any] = ["type": "user", "message": ["content": "Directory-associated request"]]
        try f.write([record], to: claudePath)
        #expect(f.inspect(agent("Claude Code", sessionID: nil))?.lastUserPromptPreview == "Directory-associated request")
        #expect(f.inspect(agent("Claude Code"))?.sessionID == "turn-a")
        #expect(f.inspect(agent("Claude Code", sessionID: nil, root: "/workspace/other")) == nil)
        // Explicit identifiers work across projects without associating a different session by cwd.
        #expect(f.inspect(agent("Claude Code", root: "/workspace/other"))?.sessionID == "turn-a")
    }

    @Test func newestEmptySessionDoesNotExposeOlderConversation() throws {
        let f = try Fixture(); defer { f.clean() }
        let older = ".codex/sessions/2026/11/07/older.jsonl"
        try f.write([meta("older"), event("user_message", "Old request")], to: older)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: f.home.appendingPathComponent(older).path)
        try f.write([meta()], to: codexPath)
        #expect(f.inspect(agent(sessionID: nil)) == nil)
    }

    @Test func largeCodexTailSkipsPartialRecordsAndOldHeadMessages() throws {
        let f = try Fixture(); defer { f.clean() }
        try f.write([meta(), event("user_message", "Old head prompt")], to: codexPath)
        var data = try Data(contentsOf: f.home.appendingPathComponent(codexPath))
        // One oversized record straddles the tail boundary and must be discarded.
        data.append(Data(("{\"type\":\"ignored\",\"text\":\"" + String(repeating: "x", count: 100_000) + "\"}\n").utf8))
        data.append(try JSONSerialization.data(withJSONObject: event("agent_message", "Recent reply")))
        data.append(Data("\n{malformed}\n{\"incomplete\":".utf8))
        try f.write(data, to: codexPath)
        let preview = try #require(f.inspect(agent(sessionID: nil)))
        #expect(preview.sessionID == "turn-a")
        #expect(preview.lastUserPromptPreview == nil)
        #expect(preview.lastAssistantReplyPreview == "Recent reply")
    }

    @Test func largeClaudeTailAndFinalRecordWithoutNewline() throws {
        let f = try Fixture(); defer { f.clean() }
        try f.write([claude("user", content: "Old head prompt")], to: claudePath)
        var data = try Data(contentsOf: f.home.appendingPathComponent(claudePath))
        data.append(Data((String(repeating: " ", count: 100_000) + "\n").utf8))
        data.append(try JSONSerialization.data(withJSONObject: claude("user", content: "Recent request")))
        try f.write(data, to: claudePath)
        #expect(f.inspect(agent("Claude Code", sessionID: nil))?.lastUserPromptPreview == "Recent request")
    }

    @Test func oversizedOnlyMessageAndMalformedFilesAreUnavailable() throws {
        let f = try Fixture(); defer { f.clean() }
        try f.write([meta(), event("user_message", String(repeating: "x", count: 100_000))], to: codexPath)
        #expect(f.inspect(agent()) == nil)
        try f.write(Data("not json\n[]\nnull\n{\"type\":4}\n".utf8), to: codexPath)
        #expect(f.inspect(agent()) == nil)
        try f.write(Data(), to: codexPath)
        #expect(f.inspect(agent()) == nil)
        #expect(f.inspect(agent("OpenCode")) == nil)
    }

    @Test func symlinkFilesAreRejectedForBothProviders() throws {
        let f = try Fixture(); defer { f.clean() }
        for (name, path, records) in [("Codex", codexPath, [meta(), event("user_message", "Hidden target")]),
                                      ("Claude Code", claudePath, [claude("user", content: "Hidden target")])] {
            let target = "target-\(name).jsonl"
            try f.write(records, to: target)
            let link = f.home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.home.appendingPathComponent(target))
            #expect(f.inspect(agent(name)) == nil)
        }
    }

    @Test func symlinkParentDirectoriesAndNonRegularFilesAreRejected() throws {
        let f = try Fixture(); defer { f.clean() }
        try f.write([meta(), event("user_message", "Hidden target")], to: "outside/sessions/2026/11/08/turn-a.jsonl")
        try FileManager.default.createSymbolicLink(at: f.home.appendingPathComponent(".codex"), withDestinationURL: f.home.appendingPathComponent("outside"))
        #expect(f.inspect(agent()) == nil)
        let fifo = f.home.appendingPathComponent(claudePath)
        try FileManager.default.createDirectory(at: fifo.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(f.inspect(agent("Claude Code")) == nil)
    }

    @Test func runningTaskIsRedactedAndIncludedWithinThreeTools() throws {
        let f = try Fixture(); defer { f.clean() }
        let secret = "sk-" + String(repeating: "a", count: 24)
        try f.write([meta()] + (0..<3).map { response(["type": "function_call", "name": "tool\($0)", "call_id": "call\($0)", "arguments": "{}"] ) }, to: codexPath)
        let preview = try #require(f.inspect(agent(task: "Active turn · Running: swift test \(secret)")))
        #expect(preview.recentTools.count == 3)
        #expect(preview.recentTools.first == SessionToolCallSummary(toolName: "swift", targetSummary: "swift test [REDACTED]", status: "running"))
        #expect(preview.recentTools.map(\.toolName) == ["swift", "tool2", "tool1"])
        #expect(f.inspect(agent(stopped: true))?.recentTools.count == 3)
    }

    @Test func activeChildrenRequireMatchingUserAndAncestry() throws {
        let f = try Fixture(); defer { f.clean() }
        let rows = [process(), process("git", pid: 401, parent: 400, uid: 502),
                    process("swift", pid: 402, parent: 400, stopped: true),
                    process("rg", pid: 403, parent: 999), process("sh", pid: 404, parent: 400),
                    process("cargo", pid: 405, parent: 404)]
        let preview = try #require(f.inspect(agent(), processes: rows))
        #expect(preview.sessionID == nil)
        #expect(preview.lastUserPromptPreview == nil)
        #expect(preview.recentTools == [SessionToolCallSummary(toolName: "cargo", targetSummary: nil, status: "running")])
        #expect(f.inspect(agent(stopped: true), processes: rows) == nil)
        #expect(f.inspect(agent(task: "Todo: Review code")) == nil)
    }

    @Test func allDisplayedFieldsAreSanitizedAndBounded() throws {
        let f = try Fixture(); defer { f.clean() }
        let secret = "sk-" + String(repeating: "a", count: 24)
        let long = String(repeating: "x", count: 300)
        try f.write([
            meta(secret), event("user_message", long), event("agent_message", long),
            response(["type": "function_call", "name": "\0\(secret)\n", "call_id": "call1", "arguments": ["cmd": ["echo", secret]]]),
            response(["type": "custom_tool_call", "name": long, "call_id": "call2", "input": "Hidden arbitrary text"])
        ], to: codexPath)
        let preview = try #require(f.inspect(agent(sessionID: secret)))
        #expect(preview.sessionID == "[REDACTED]")
        #expect(preview.lastUserPromptPreview?.count == 160)
        #expect(preview.lastAssistantReplyPreview?.count == 160)
        #expect(preview.recentTools.first?.toolName.count == 64)
        #expect(preview.recentTools.first?.targetSummary == nil)
        #expect(preview.recentTools.last?.toolName == "[REDACTED]")
        #expect(preview.recentTools.last?.targetSummary == "echo [REDACTED]")
        let encoded = String(decoding: try JSONEncoder().encode(preview), as: UTF8.self)
        #expect(!encoded.contains(secret))
        #expect(!encoded.contains("Hidden arbitrary text"))
    }
}
