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
        func writeJSON(_ object: [String: Any], to path: String) throws {
            try write(JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), to: path)
        }
        func inspect(_ agent: AgentObservation, processes: [ObservedProcess] = []) -> SessionTurnPreview? {
            let inspector = SessionTurnPreviewInspector(homeDirectory: home)
            if let sessionID = agent.sessionID {
                return inspector.inspectSelectedSession(sessionID, for: agent, allProcesses: processes)
            }
            return inspector.inspectPreview(for: agent, allProcesses: processes)
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
        "Bearer /fixture+key~with_padding==",
        "Bearer sk-fixture123456789/with+padding==",
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

    @Test func liveRowsCannotReadUnverifiedSessionText() throws {
        let f = try Fixture(); defer { f.clean() }
        try f.write([meta(), event("user_message", "Unrelated conversation")], to: codexPath)
        try f.write([claude("user", content: "Unrelated conversation")], to: claudePath)
        let inspector = SessionTurnPreviewInspector(homeDirectory: f.home)
        for row in [agent(sessionID: nil), agent(), agent("Claude Code", sessionID: nil), agent("Claude Code")] {
            #expect(inspector.inspectPreview(for: row)?.lastUserPromptPreview == nil)
        }
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

    @Test func explicitSelectionDoesNotUseProjectRecency() throws {
        let f = try Fixture(); defer { f.clean() }
        let older = ".codex/sessions/2026/11/07/older.jsonl"
        let unrelated = ".codex/sessions/2026/11/08/unrelated.jsonl"
        try f.write([meta("older"), event("user_message", "Old request")], to: older)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: f.home.appendingPathComponent(older).path)
        try f.write([meta(), event("user_message", "Current request")], to: codexPath)
        try f.write([meta("unrelated", root: "/workspace/other"), event("user_message", "Unrelated request")], to: unrelated)
        let preview = try #require(f.inspect(agent(root: "/workspace/app/.")))
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
        #expect(f.inspect(agent("Claude Code", sessionID: nil)) == nil)
        #expect(f.inspect(agent("Claude Code"))?.lastUserPromptPreview == "Directory-associated request")
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
        #expect(f.inspect(agent()) == nil)
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
        let preview = try #require(f.inspect(agent()))
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
        #expect(f.inspect(agent("Claude Code"))?.lastUserPromptPreview == "Recent request")
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

    @Test func openCodeMessageFilesExtractLatestTextAndRedactedTools() throws {
        let f = try Fixture(); defer { f.clean() }
        let base = ".local/share/opencode/storage/message/turn-a"
        let secret = "sk-" + String(repeating: "a", count: 24)
        let messages: [[String: Any]] = [
            ["role": "user", "sessionID": "turn-a", "parts": [["type": "text", "text": "Earlier request"]]],
            ["role": "user", "sessionID": "turn-a", "parts": [["type": "text", "text": "Check\n\(secret)"]]],
            ["info": ["role": "assistant", "sessionID": "turn-a"], "timestamp": timestamp,
             "parts": [["type": "reasoning", "text": "Hidden reasoning"],
                       ["type": "text", "text": "Reply \(secret)"],
                       ["type": "tool", "tool": "Read\n\(secret)", "callID": "call1",
                        "state": ["status": "completed", "input": ["filePath": "/workspace/\(secret)", "private": "Hidden argument"], "output": "Hidden result"]]]]
        ]
        for (index, message) in messages.enumerated() {
            let path = "\(base)/message-\(index).json"
            try f.writeJSON(message, to: path)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(100 + index))], ofItemAtPath: f.home.appendingPathComponent(path).path)
        }
        let preview = try #require(f.inspect(agent("OpenCode")))
        #expect(preview.sessionID == "turn-a")
        #expect(preview.lastUserPromptPreview == "Check [REDACTED]")
        #expect(preview.lastAssistantReplyPreview == "Reply [REDACTED]")
        #expect(preview.recentTools == [SessionToolCallSummary(toolName: "Read [REDACTED]", targetSummary: "/workspace/[REDACTED]", status: "completed")])
        let encoded = String(decoding: try JSONEncoder().encode(preview), as: UTF8.self)
        #expect(!encoded.contains(secret))
        #expect(!encoded.contains("Hidden"))
    }

    @Test(arguments: [".open-code/sessions/turn-a.jsonl", ".local/share/opencode/sessions/turn-a.json"])
    func openCodeSessionLayouts(_ path: String) throws {
        let f = try Fixture(); defer { f.clean() }
        let messages: [[String: Any]] = [
            ["role": "user", "content": "Review changes"],
            ["role": "assistant", "content": "Reviewed", "tool_calls": [
                ["id": "call1", "function": ["name": "shell", "arguments": "{\"command\":\"git diff\"}"]]
            ]]
        ]
        if path.hasSuffix("jsonl") { try f.write(messages, to: path) }
        else { try f.writeJSON(["sessionID": "turn-a", "messages": messages], to: path) }
        let preview = try #require(f.inspect(agent("OpenCode")))
        #expect(preview.lastUserPromptPreview == "Review changes")
        #expect(preview.lastAssistantReplyPreview == "Reviewed")
        #expect(preview.recentTools == [SessionToolCallSummary(toolName: "shell", targetSummary: "git diff", status: "running")])
    }

    @Test func openCodeMessageChronologyUsesCreationTimeOverFileModificationTime() throws {
        let f = try Fixture(); defer { f.clean() }
        let base = ".local/share/opencode/storage/message/turn-a"
        for (file, text, created, modified) in [("a", "Latest prompt", 1_794_132_002_000.0, 100.0), ("z", "Earlier prompt", 1_794_132_000_000.0, 200.0)] {
            let path = "\(base)/\(file).json"
            try f.writeJSON(["role": "user", "sessionID": "turn-a", "time": ["created": created], "content": text], to: path)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)], ofItemAtPath: f.home.appendingPathComponent(path).path)
        }
        let preview = try #require(f.inspect(agent("OpenCode")))
        #expect(preview.lastUserPromptPreview == "Latest prompt")
        #expect(preview.updatedAt == Date(timeIntervalSince1970: 1_794_132_002))
    }

    @Test func openCodeSeparatePartsRequireMatchingSessionAndMessage() throws {
        let f = try Fixture(); defer { f.clean() }
        let secret = "ghp_" + String(repeating: "d", count: 24)
        try f.writeJSON(["id": "msg-a", "sessionID": "turn-a", "role": "user"], to: ".local/share/opencode/storage/message/turn-a/msg-a.json")
        let base = ".local/share/opencode/storage/part/msg-a"
        try f.writeJSON(["sessionID": "turn-a", "messageID": "msg-a", "type": "text", "text": "Check \(secret)"], to: "\(base)/part-a.json")
        try f.writeJSON(["sessionID": "other", "messageID": "msg-a", "type": "text", "text": "Hidden session"], to: "\(base)/part-b.json")
        try f.writeJSON(["sessionID": "turn-a", "messageID": "msg-other", "type": "text", "text": "Hidden message"], to: "\(base)/part-c.json")
        try f.writeJSON(["sessionID": "turn-a", "messageID": "msg-a", "type": "text", "text": "Hidden symlink"], to: "target.json")
        try FileManager.default.createSymbolicLink(at: f.home.appendingPathComponent("\(base)/part-d.json"), withDestinationURL: f.home.appendingPathComponent("target.json"))
        #expect(f.inspect(agent("OpenCode"))?.lastUserPromptPreview == "Check [REDACTED]")
    }

    @Test(arguments: [".gemini/tmp/project/chats/session-current.json", ".gemini/sessions/turn-a.jsonl"])
    func geminiChatLayoutsRedactMessagesAndToolCalls(_ path: String) throws {
        let f = try Fixture(); defer { f.clean() }
        let secret = "AIza" + String(repeating: "b", count: 24)
        let records: [[String: Any]] = [
            ["sessionId": "turn-a"],
            ["type": "user", "content": "Earlier request"],
            ["role": "user", "content": [["text": "Check \(secret)"]]],
            ["role": "model", "timestamp": timestamp, "parts": [
                ["text": "Hidden thought", "thought": true], ["text": "Checked\n\(secret)"],
                ["functionCall": ["name": "run_shell_command", "args": ["command": "echo \(secret)"]]]
            ]],
            ["type": "gemini", "content": "Done \(secret)", "thoughts": [["text": "Hidden reasoning"]], "toolCalls": [
                ["id": "call2", "name": "Read \(secret)", "args": ["file_path": "/workspace/\(secret)", "secret": "Hidden input"], "status": "success", "result": "Hidden output"]
            ]],
            ["type": "info", "content": "Hidden info"], ["role": "tool", "content": "Hidden tool output"]
        ]
        if path.hasSuffix("jsonl") { try f.write(records, to: path) }
        else { try f.writeJSON(["sessionId": "turn-a", "messages": Array(records.dropFirst())], to: path) }
        let preview = try #require(f.inspect(agent("Gemini CLI")))
        #expect(preview.lastUserPromptPreview == "Check [REDACTED]")
        #expect(preview.lastAssistantReplyPreview == "Done [REDACTED]")
        #expect(preview.recentTools == [
            SessionToolCallSummary(toolName: "Read [REDACTED]", targetSummary: "/workspace/[REDACTED]", status: "completed"),
            SessionToolCallSummary(toolName: "run_shell_command", targetSummary: "echo [REDACTED]", status: "running")
        ])
        let encoded = String(decoding: try JSONEncoder().encode(preview), as: UTF8.self)
        #expect(!encoded.contains(secret))
        #expect(!encoded.contains("Hidden"))
    }

    @Test(arguments: ["OpenCode", "Gemini CLI", "Cursor", "Aider", "Windsurf", "Antigravity CLI"])
    func otherAgentsHaveRunningChildAndTaskFallbacks(_ name: String) throws {
        let f = try Fixture(); defer { f.clean() }
        let rows = [process("sh", pid: 401, parent: 400), process("swift", pid: 402, parent: 401)]
        let preview = try #require(f.inspect(agent(name), processes: rows))
        #expect(preview.sessionID == nil)
        #expect(preview.lastUserPromptPreview == nil)
        #expect(preview.lastAssistantReplyPreview == nil)
        #expect(preview.recentTools == [SessionToolCallSummary(toolName: "swift", targetSummary: nil, status: "running")])
        #expect(f.inspect(agent(name, stopped: true), processes: rows) == nil)
        #expect(f.inspect(agent(name), processes: [process("git", pid: 401, parent: 400, uid: 502)]) == nil)
        #expect(f.inspect(agent(name), processes: [process("git", pid: 401, parent: 999)]) == nil)
        #expect(f.inspect(agent(name)) == nil)
        let secret = "ghp_" + String(repeating: "c", count: 24)
        #expect(f.inspect(agent(name, task: "Running: git show \(secret)"))?.recentTools.first?.targetSummary == "git show [REDACTED]")
    }

    @Test(arguments: ["OpenCode", "Gemini CLI"])
    func additionalProviderToolListsAreBoundedAndIncludeRunningWork(_ name: String) throws {
        let f = try Fixture(); defer { f.clean() }
        let path = name == "OpenCode" ? ".local/share/opencode/sessions/turn-a.json" : ".gemini/tmp/project/chats/turn-a.json"
        let secret = "sk-" + String(repeating: "e", count: 24)
        let tools: [[String: Any]] = (0..<4).map { index in
            ["id": "call\(index)", "name": "tool\(index)", "args": ["command": "echo \(secret)"], "status": index == 2 ? "error" : "success"]
        }
        try f.writeJSON(["sessionID": "turn-a", "messages": [["role": "assistant", "toolCalls": tools]]], to: path)
        let preview = try #require(f.inspect(agent(name, task: "Running: swift build")))
        #expect(preview.recentTools.map(\.toolName) == ["swift", "tool3", "tool2"])
        #expect(preview.recentTools.map(\.status) == ["running", "completed", "failed"])
        #expect(preview.recentTools.last?.targetSummary == "echo [REDACTED]")
    }

    @Test(arguments: ["OpenCode", "Gemini CLI"])
    func additionalProvidersRejectUnassociatedAndMixedSessions(_ name: String) throws {
        let f = try Fixture(); defer { f.clean() }
        let path = name == "OpenCode" ? ".local/share/opencode/sessions/turn-a.json" : ".gemini/tmp/project/chats/turn-a.json"
        try f.writeJSON(["sessionId": "other", "messages": [["role": "user", "content": "Unrelated prompt"]]], to: path)
        #expect(f.inspect(agent(name)) == nil)
        #expect(f.inspect(agent(name, sessionID: nil)) == nil)
        #expect(f.inspect(agent(name, sessionID: "../turn-a")) == nil)
        #expect(f.inspect(agent(name, sessionID: "../turn-a", task: "Running: git diff"))?.recentTools.first?.toolName == "git")
        try f.writeJSON(["sessionId": "turn-a", "messages": [["sessionID": "other", "role": "user", "content": "Mixed prompt"]]], to: path)
        #expect(f.inspect(agent(name)) == nil)
    }

    @Test func geminiSelectsLatestMatchingSessionWithoutShowingOlderEmptySnapshot() throws {
        let f = try Fixture(); defer { f.clean() }
        let base = ".gemini/tmp/project/chats"
        for (name, id, text, time) in [("old", "turn-a", "Old prompt", 100), ("new", "turn-a", "Current prompt", 200), ("unrelated", "other", "Unrelated prompt", 300)] {
            let path = "\(base)/\(name).json"
            try f.writeJSON(["sessionId": id, "messages": [["role": "user", "content": text]]], to: path)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(time))], ofItemAtPath: f.home.appendingPathComponent(path).path)
        }
        #expect(f.inspect(agent("Gemini CLI"))?.lastUserPromptPreview == "Current prompt")
        try f.writeJSON(["sessionId": "turn-a", "messages": []], to: "\(base)/new.json")
        #expect(f.inspect(agent("Gemini CLI")) == nil)
    }

    @Test(arguments: ["OpenCode", "Gemini CLI"])
    func additionalProvidersRejectSymlinksNonRegularAndOversizedDocuments(_ name: String) throws {
        let f = try Fixture(); defer { f.clean() }
        let path = name == "OpenCode" ? ".local/share/opencode/sessions/turn-a.json" : ".gemini/tmp/project/chats/turn-a.json"
        let payload: [String: Any] = ["sessionId": "turn-a", "messages": [["role": "user", "content": "Hidden prompt"]]]
        try f.writeJSON(payload, to: "target.json")
        let url = f.home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: f.home.appendingPathComponent("target.json"))
        #expect(f.inspect(agent(name)) == nil)
        try FileManager.default.removeItem(at: url)
        #expect(mkfifo(url.path, 0o600) == 0)
        #expect(f.inspect(agent(name)) == nil)
        try FileManager.default.removeItem(at: url)
        try f.writeJSON(["sessionId": "turn-a", "messages": [["role": "user", "content": String(repeating: "x", count: 70_000)]]], to: path)
        #expect(f.inspect(agent(name)) == nil)
        #expect(f.inspect(agent(name, task: "Running: git diff"))?.recentTools.first?.toolName == "git")
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        try f.writeJSON(payload, to: "turn-a.json")
        try FileManager.default.createSymbolicLink(at: url.deletingLastPathComponent(), withDestinationURL: f.home)
        #expect(f.inspect(agent(name)) == nil)
    }

    @Test(arguments: [".open-code/sessions/turn-a.jsonl", ".gemini/sessions/turn-a.jsonl"])
    func additionalProviderJSONLTailsRemainBounded(_ path: String) throws {
        let f = try Fixture(); defer { f.clean() }
        try f.write([["sessionId": "turn-a"], ["role": "user", "content": "Old head prompt"]], to: path)
        var data = try Data(contentsOf: f.home.appendingPathComponent(path))
        data.append(Data(("{\"role\":\"user\",\"content\":\"" + String(repeating: "x", count: 100_000) + "\"}\n").utf8))
        data.append(try JSONSerialization.data(withJSONObject: ["role": path.hasPrefix(".gemini") ? "model" : "assistant", "content": "Recent reply"]))
        try f.write(data, to: path)
        let preview = try #require(f.inspect(agent(path.hasPrefix(".gemini") ? "Gemini CLI" : "OpenCode")))
        #expect(preview.lastUserPromptPreview == nil)
        #expect(preview.lastAssistantReplyPreview == "Recent reply")
    }
}
