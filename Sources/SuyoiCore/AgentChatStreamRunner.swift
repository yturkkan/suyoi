import Darwin
import Foundation

public enum AgentChatStreamEvent: Equatable, Sendable {
    case sessionStarted(String)
    case assistantMessageUpdated(id: String, text: String)
    case toolCallUpdated(SessionChatTurn)
    case error(String)
    case finished(exitCode: Int32)
}

public struct AgentChatStreamRequest: Equatable, Sendable {
    public let provider: SessionProviderKind
    public let sessionID: String?
    public let projectPath: String
    public let prompt: String
    public let preferredExecutablePath: String?

    public init(
        provider: SessionProviderKind,
        sessionID: String? = nil,
        projectPath: String,
        prompt: String,
        preferredExecutablePath: String? = nil
    ) {
        self.provider = provider
        self.sessionID = sessionID
        self.projectPath = projectPath
        self.prompt = prompt
        self.preferredExecutablePath = preferredExecutablePath
    }
}

public enum AgentChatStreamError: LocalizedError, Equatable, Sendable {
    case unsupportedProvider(SessionProviderKind)
    case emptyOrInvalidPrompt
    case invalidWorkspaceDirectory(String)
    case invalidSessionID(String)
    case executableNotFound(SessionProviderKind, binaryName: String)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedProvider(let provider):
            return "\(provider.rawValue) does not support direct CLI chat streaming."
        case .emptyOrInvalidPrompt:
            return "Message must contain between 1 and 12,000 characters."
        case .invalidWorkspaceDirectory(let path):
            return "Workspace folder is unavailable on disk: \(path)"
        case .invalidSessionID:
            return "Session identifier is invalid and cannot be resumed."
        case .executableNotFound(let provider, let binaryName):
            return "\(provider.rawValue) CLI ('\(binaryName)') was not found in PATH, Homebrew, NVM/fnm, or user bin folders."
        case .launchFailed(let detail):
            return "Failed to start CLI process: \(detail)"
        }
    }
}

/// Stateful NDJSON + plain-text fallback stream parser for Codex, Gemini CLI, OpenCode, and Claude Code.
public struct AgentStreamLineParser: Sendable {
    private let provider: SessionProviderKind
    private var emittedSessionID: String?
    private var counter: Int = 0
    private var emittedErrorFlag: Bool = false
    private var emittedAssistantFlag: Bool = false

    // Gemini streaming buffers (delta chunks concatenate without trimming inter-token spaces)
    private var geminiMessageIndex: Int = 1
    private var geminiAssistantBuffer: String = ""

    // OpenCode cumulative/delta per-part text buffers
    private var openCodeDefaultIndex: Int = 1
    private var openCodeTextByID: [String: String] = [:]

    // Plain-text fallback buffer for non-JSON lines
    private var plainFallbackBuffer: String = ""

    // Tool metadata cache keyed by tool call ID so tool_result updates retain tool name & target summary
    private struct ToolMeta: Sendable {
        let name: String
        let summary: String
    }
    private var toolMetaByID: [String: ToolMeta] = [:]

    private static let ansiEscapeRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"\u001B\[[0-9;?]*[ -/]*[@-~]"#
    )

    public init(provider: SessionProviderKind) {
        self.provider = provider
    }

    public var hasEmittedError: Bool { emittedErrorFlag }
    public var hasEmittedAssistantText: Bool { emittedAssistantFlag }

    public mutating func parseLine(_ rawLine: String) -> [AgentChatStreamEvent] {
        var line = rawLine
        if line.hasSuffix("\r") {
            line.removeLast()
        }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if trimmed.first == "{",
           let data = trimmed.data(using: .utf8),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            switch provider {
            case .codex:
                return parseCodexJSON(json)
            case .gemini:
                return parseGeminiJSON(json)
            case .openCode:
                return parseOpenCodeJSON(json)
            case .claude:
                return parseClaudeJSON(json)
            case .cursor, .other:
                return []
            }
        }

        // Plain-text fallback if a CLI outputs non-JSON text on stdout
        let stripped = Self.stripANSIEscapes(line)
        guard !stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        if plainFallbackBuffer.isEmpty {
            plainFallbackBuffer = stripped
        } else {
            plainFallbackBuffer += "\n" + stripped
        }
        guard let clean = WorkspaceSessionIndexer.sanitizeMultilineText(plainFallbackBuffer, maxLength: 24_000) else {
            return []
        }
        emittedAssistantFlag = true
        return [.assistantMessageUpdated(id: "stream-plain-1", text: clean)]
    }

    // MARK: - Codex (`codex exec --json`)

    private mutating func parseCodexJSON(_ dict: [String: Any]) -> [AgentChatStreamEvent] {
        var events: [AgentChatStreamEvent] = []
        if let tid = (dict["thread_id"] as? String) ?? (dict["session_id"] as? String) {
            appendSessionIfNeeded(tid, into: &events)
        }

        let type = (dict["type"] as? String ?? "").lowercased()
        switch type {
        case "thread.started":
            if let tid = dict["thread_id"] as? String {
                appendSessionIfNeeded(tid, into: &events)
            }

        case "item.started", "item.updated", "item.completed":
            guard let item = dict["item"] as? [String: Any] else { break }
            let rawItemID = (item["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "idx-\(nextCounter())"
            let itemType = (item["type"] as? String ?? "").lowercased()

            if itemType == "agent_message" || (itemType == "message" && ((item["role"] as? String)?.lowercased() != "user")) {
                if let text = extractCodexItemText(item),
                   let clean = WorkspaceSessionIndexer.sanitizeMultilineText(text, maxLength: 24_000) {
                    emittedAssistantFlag = true
                    events.append(.assistantMessageUpdated(id: "codex-\(rawItemID)", text: clean))
                }
            } else if ["command_execution", "file_change", "mcp_tool_call", "web_search", "function_call"].contains(itemType) {
                let (toolName, summary) = summarizeCodexToolItem(item, itemType: itemType)
                let status: String
                if type == "item.completed" {
                    let rawStatus = (item["status"] as? String ?? "").lowercased()
                    let exitCode = (item["exit_code"] as? Int) ?? 0
                    if rawStatus == "failed" || rawStatus == "declined" || rawStatus == "error" || exitCode != 0 {
                        status = "failed"
                    } else {
                        status = "completed"
                    }
                } else {
                    status = "running"
                }
                events.append(
                    .toolCallUpdated(
                        SessionChatTurn(
                            id: "codex-tool-\(rawItemID)",
                            kind: .toolCall,
                            text: summary,
                            toolName: toolName,
                            toolStatus: status,
                            timestamp: Date()
                        )
                    )
                )
            }

        case "error":
            if let msg = (dict["message"] as? String).flatMap({ Self.cleanErrorMessage($0) }) {
                emittedErrorFlag = true
                events.append(.error(msg))
            }

        case "turn.failed":
            let errText = ((dict["error"] as? [String: Any])?["message"] as? String)
                ?? (dict["message"] as? String)
            if let msg = errText.flatMap({ Self.cleanErrorMessage($0) }) {
                emittedErrorFlag = true
                events.append(.error(msg))
            }

        default:
            break
        }
        return events
    }

    private func extractCodexItemText(_ item: [String: Any]) -> String? {
        if let text = item["text"] as? String, !text.isEmpty {
            return text
        }
        if let content = item["content"] as? [[String: Any]] {
            let parts = content.compactMap { block -> String? in
                let bType = (block["type"] as? String ?? "text").lowercased()
                guard bType == "output_text" || bType == "text" else { return nil }
                return block["text"] as? String
            }
            if !parts.isEmpty {
                return parts.joined(separator: "\n\n")
            }
        }
        return nil
    }

    private func summarizeCodexToolItem(_ item: [String: Any], itemType: String) -> (String, String) {
        switch itemType {
        case "command_execution":
            let cmd = (item["command"] as? String)
                .flatMap { SessionTurnPreviewInspector.sanitizeAndRedact($0, maxLength: 160) }
                ?? "shell"
            return ("shell", cmd)
        case "file_change":
            if let changes = item["changes"] as? [[String: Any]] {
                let paths = changes.compactMap { $0["path"] as? String }
                if !paths.isEmpty,
                   let clean = SessionTurnPreviewInspector.sanitizeAndRedact(paths.joined(separator: ", "), maxLength: 160) {
                    return ("patch", clean)
                }
            }
            return ("patch", "Apply workspace file changes")
        case "mcp_tool_call":
            let tool = (item["tool"] as? String) ?? (item["server"] as? String) ?? "mcp"
            let summary = Self.summarizeToolParameters(item["arguments"] as? [String: Any]) ?? tool
            return (tool, summary)
        case "web_search":
            let query = (item["query"] as? String)
                .flatMap { SessionTurnPreviewInspector.sanitizeAndRedact($0, maxLength: 160) }
                ?? "web search"
            return ("web_search", query)
        default:
            let name = (item["name"] as? String) ?? "tool"
            let summary = Self.summarizeToolParameters(item["input"] as? [String: Any]) ?? name
            return (name, summary)
        }
    }

    // MARK: - Gemini CLI (`gemini --output-format stream-json`)

    private mutating func parseGeminiJSON(_ dict: [String: Any]) -> [AgentChatStreamEvent] {
        var events: [AgentChatStreamEvent] = []
        if let sid = (dict["session_id"] as? String) ?? (dict["sessionId"] as? String) {
            appendSessionIfNeeded(sid, into: &events)
        }

        let type = (dict["type"] as? String ?? "").lowercased()
        switch type {
        case "init":
            break

        case "message":
            let role = (dict["role"] as? String ?? "").lowercased()
            // Ignore echoed user prompt; user bubble is already rendered in the timeline.
            guard role != "user" else { break }
            guard let chunk = (dict["content"] as? String) ?? (dict["text"] as? String),
                  !chunk.isEmpty else { break }
            let isDelta = (dict["delta"] as? Bool) == true
            if isDelta {
                geminiAssistantBuffer += chunk
            } else if geminiAssistantBuffer.isEmpty || chunk.hasPrefix(geminiAssistantBuffer) {
                geminiAssistantBuffer = chunk
            } else {
                geminiMessageIndex += 1
                geminiAssistantBuffer = chunk
            }
            if let clean = WorkspaceSessionIndexer.sanitizeMultilineText(geminiAssistantBuffer, maxLength: 24_000) {
                emittedAssistantFlag = true
                events.append(.assistantMessageUpdated(id: "gemini-msg-\(geminiMessageIndex)", text: clean))
            }

        case "tool_use":
            if !geminiAssistantBuffer.isEmpty {
                geminiMessageIndex += 1
                geminiAssistantBuffer = ""
            }
            let toolID = (dict["tool_id"] as? String) ?? (dict["id"] as? String) ?? "idx-\(nextCounter())"
            let rawName = (dict["tool_name"] as? String) ?? (dict["name"] as? String) ?? "tool"
            let toolName = SessionTurnPreviewInspector.sanitizeAndRedact(rawName, maxLength: 64) ?? "tool"
            let params = (dict["parameters"] as? [String: Any])
                ?? (dict["input"] as? [String: Any])
                ?? (dict["args"] as? [String: Any])
            let summary = Self.summarizeToolParameters(params) ?? toolName
            toolMetaByID[toolID] = ToolMeta(name: toolName, summary: summary)
            events.append(
                .toolCallUpdated(
                    SessionChatTurn(
                        id: "gemini-tool-\(toolID)",
                        kind: .toolCall,
                        text: summary,
                        toolName: toolName,
                        toolStatus: "running",
                        timestamp: Date()
                    )
                )
            )

        case "tool_result":
            let toolID = (dict["tool_id"] as? String) ?? (dict["tool_use_id"] as? String) ?? (dict["id"] as? String) ?? ""
            guard !toolID.isEmpty else { break }
            let statusStr = (dict["status"] as? String ?? "").lowercased()
            let isErr = (dict["is_error"] as? Bool == true) || statusStr == "error" || statusStr == "failed"
            let meta = toolMetaByID[toolID] ?? ToolMeta(name: "tool", summary: "tool")
            events.append(
                .toolCallUpdated(
                    SessionChatTurn(
                        id: "gemini-tool-\(toolID)",
                        kind: .toolCall,
                        text: meta.summary,
                        toolName: meta.name,
                        toolStatus: isErr ? "failed" : "completed",
                        timestamp: Date()
                    )
                )
            )

        case "error":
            let rawErr = (dict["message"] as? String)
                ?? ((dict["error"] as? [String: Any])?["message"] as? String)
                ?? (dict["error"] as? String)
            if let msg = rawErr.flatMap({ Self.cleanErrorMessage($0) }) {
                emittedErrorFlag = true
                events.append(.error(msg))
            }

        case "result":
            let statusStr = (dict["status"] as? String ?? "").lowercased()
            if statusStr == "error" || (dict["is_error"] as? Bool == true) {
                let rawErr = ((dict["error"] as? [String: Any])?["message"] as? String)
                    ?? (dict["error"] as? String)
                    ?? (dict["message"] as? String)
                if let msg = rawErr.flatMap({ Self.cleanErrorMessage($0) }) {
                    emittedErrorFlag = true
                    events.append(.error(msg))
                }
            } else if !emittedAssistantFlag,
                      let response = (dict["response"] as? String) ?? (dict["result"] as? String),
                      let clean = WorkspaceSessionIndexer.sanitizeMultilineText(response, maxLength: 24_000) {
                emittedAssistantFlag = true
                events.append(.assistantMessageUpdated(id: "gemini-msg-\(geminiMessageIndex)", text: clean))
            }

        default:
            break
        }
        return events
    }

    // MARK: - OpenCode (`opencode run --format json`)

    private mutating func parseOpenCodeJSON(_ dict: [String: Any]) -> [AgentChatStreamEvent] {
        var events: [AgentChatStreamEvent] = []
        let part = dict["part"] as? [String: Any]
        if let sid = (dict["sessionID"] as? String)
            ?? (dict["session_id"] as? String)
            ?? (part?["sessionID"] as? String) {
            appendSessionIfNeeded(sid, into: &events)
        }

        let type = (dict["type"] as? String ?? "").lowercased()
        let partType = (part?["type"] as? String ?? "").lowercased()

        if type == "text" || partType == "text" {
            let partID = (part?["id"] as? String)
                ?? (dict["id"] as? String)
                ?? "seg-\(openCodeDefaultIndex)"
            let explicitDelta = (dict["delta"] as? String) ?? (part?["delta"] as? String)
            let rawText = explicitDelta ?? (part?["text"] as? String) ?? (dict["text"] as? String)
            if let rawText, !rawText.isEmpty {
                let combined: String
                if let existing = openCodeTextByID[partID] {
                    if explicitDelta != nil {
                        combined = existing + rawText
                    } else if rawText.hasPrefix(existing) {
                        combined = rawText
                    } else if existing.hasPrefix(rawText) {
                        combined = existing
                    } else {
                        combined = existing + rawText
                    }
                } else {
                    combined = rawText
                }
                openCodeTextByID[partID] = combined
                if let clean = WorkspaceSessionIndexer.sanitizeMultilineText(combined, maxLength: 24_000) {
                    emittedAssistantFlag = true
                    events.append(.assistantMessageUpdated(id: "oc-\(partID)", text: clean))
                }
            }
        } else if type == "tool_use" || type == "tool" || partType == "tool" {
            openCodeDefaultIndex += 1
            let p = part ?? dict
            let callID = (p["callID"] as? String) ?? (p["id"] as? String) ?? "idx-\(nextCounter())"
            let rawName = (p["tool"] as? String) ?? (p["name"] as? String) ?? "tool"
            let toolName = SessionTurnPreviewInspector.sanitizeAndRedact(rawName, maxLength: 64) ?? "tool"
            let state = (p["state"] as? [String: Any]) ?? p
            let input = (state["input"] as? [String: Any]) ?? (p["input"] as? [String: Any])
            let summary = Self.summarizeToolParameters(input)
                ?? (state["title"] as? String).flatMap({ SessionTurnPreviewInspector.sanitizeAndRedact($0, maxLength: 160) })
                ?? toolName
            let rawStatus = (state["status"] as? String ?? "completed").lowercased()
            let mappedStatus: String
            if ["error", "failed", "aborted"].contains(rawStatus) {
                mappedStatus = "failed"
            } else if ["running", "pending", "in_progress"].contains(rawStatus) {
                mappedStatus = "running"
            } else {
                mappedStatus = "completed"
            }
            events.append(
                .toolCallUpdated(
                    SessionChatTurn(
                        id: "oc-tool-\(callID)",
                        kind: .toolCall,
                        text: summary,
                        toolName: toolName,
                        toolStatus: mappedStatus,
                        timestamp: Date()
                    )
                )
            )
        } else if type == "error" {
            let errDict = dict["error"] as? [String: Any]
            let dataDict = errDict?["data"] as? [String: Any]
            let rawErr = (dataDict?["message"] as? String)
                ?? (errDict?["message"] as? String)
                ?? (dict["message"] as? String)
                ?? (errDict?["name"] as? String)
            if let msg = rawErr.flatMap({ Self.cleanErrorMessage($0) }) {
                emittedErrorFlag = true
                events.append(.error(msg))
            }
        }
        return events
    }

    // MARK: - Claude Code (`claude -p --verbose --output-format stream-json`)

    private mutating func parseClaudeJSON(_ dict: [String: Any]) -> [AgentChatStreamEvent] {
        var events: [AgentChatStreamEvent] = []
        if let sid = (dict["session_id"] as? String) ?? (dict["sessionId"] as? String) {
            appendSessionIfNeeded(sid, into: &events)
        }

        let type = (dict["type"] as? String ?? "").lowercased()
        switch type {
        case "assistant":
            guard let msg = dict["message"] as? [String: Any] else { break }
            let msgID = (msg["id"] as? String) ?? "idx-\(nextCounter())"
            if let content = msg["content"] as? String,
               let clean = WorkspaceSessionIndexer.sanitizeMultilineText(content, maxLength: 24_000) {
                emittedAssistantFlag = true
                events.append(.assistantMessageUpdated(id: "claude-\(msgID)", text: clean))
            } else if let blocks = msg["content"] as? [[String: Any]] {
                var texts: [String] = []
                for block in blocks {
                    let bType = (block["type"] as? String ?? "text").lowercased()
                    if bType == "text", let txt = block["text"] as? String {
                        texts.append(txt)
                    } else if bType == "tool_use" {
                        let toolID = (block["id"] as? String) ?? "idx-\(nextCounter())"
                        let rawName = (block["name"] as? String) ?? "tool"
                        let toolName = SessionTurnPreviewInspector.sanitizeAndRedact(rawName, maxLength: 64) ?? "tool"
                        let summary = Self.summarizeToolParameters(block["input"] as? [String: Any]) ?? toolName
                        toolMetaByID[toolID] = ToolMeta(name: toolName, summary: summary)
                        events.append(
                            .toolCallUpdated(
                                SessionChatTurn(
                                    id: "claude-tool-\(toolID)",
                                    kind: .toolCall,
                                    text: summary,
                                    toolName: toolName,
                                    toolStatus: "running",
                                    timestamp: Date()
                                )
                            )
                        )
                    }
                }
                if !texts.isEmpty,
                   let clean = WorkspaceSessionIndexer.sanitizeMultilineText(texts.joined(separator: "\n\n"), maxLength: 24_000) {
                    emittedAssistantFlag = true
                    events.append(.assistantMessageUpdated(id: "claude-\(msgID)", text: clean))
                }
            }

        case "user":
            guard let msg = dict["message"] as? [String: Any],
                  let blocks = msg["content"] as? [[String: Any]] else { break }
            for block in blocks where (block["type"] as? String)?.lowercased() == "tool_result" {
                guard let toolID = block["tool_use_id"] as? String, !toolID.isEmpty else { continue }
                let isErr = (block["is_error"] as? Bool) == true
                let meta = toolMetaByID[toolID] ?? ToolMeta(name: "tool", summary: "tool")
                events.append(
                    .toolCallUpdated(
                        SessionChatTurn(
                            id: "claude-tool-\(toolID)",
                            kind: .toolCall,
                            text: meta.summary,
                            toolName: meta.name,
                            toolStatus: isErr ? "failed" : "completed",
                            timestamp: Date()
                        )
                    )
                )
            }

        case "result":
            let isErr = (dict["is_error"] as? Bool) == true || (dict["subtype"] as? String == "error_during_execution")
            if isErr {
                let rawErr = (dict["result"] as? String) ?? (dict["error"] as? String) ?? "Claude Code execution failed"
                if let msg = Self.cleanErrorMessage(rawErr) {
                    emittedErrorFlag = true
                    events.append(.error(msg))
                }
            } else if !emittedAssistantFlag,
                      let resultText = dict["result"] as? String,
                      let clean = WorkspaceSessionIndexer.sanitizeMultilineText(resultText, maxLength: 24_000) {
                emittedAssistantFlag = true
                events.append(.assistantMessageUpdated(id: "claude-result", text: clean))
            }

        case "error":
            let rawErr = (dict["message"] as? String) ?? ((dict["error"] as? [String: Any])?["message"] as? String)
            if let msg = rawErr.flatMap({ Self.cleanErrorMessage($0) }) {
                emittedErrorFlag = true
                events.append(.error(msg))
            }

        default:
            break
        }
        return events
    }

    // MARK: - Parser Helpers

    private mutating func nextCounter() -> Int {
        counter += 1
        return counter
    }

    private mutating func appendSessionIfNeeded(_ rawSessionID: String, into events: inout [AgentChatStreamEvent]) {
        guard let valid = AgentContextValidation.sessionID(rawSessionID),
              emittedSessionID != valid else { return }
        emittedSessionID = valid
        events.append(.sessionStarted(valid))
    }

    static func stripANSIEscapes(_ raw: String) -> String {
        guard let regex = ansiEscapeRegex else { return raw }
        return regex.stringByReplacingMatches(
            in: raw,
            range: NSRange(raw.startIndex..., in: raw),
            withTemplate: ""
        )
    }

    static func cleanErrorMessage(_ raw: String) -> String? {
        let stripped = stripANSIEscapes(raw)
        return WorkspaceSessionIndexer.sanitizeMultilineText(stripped, maxLength: 1_200)
    }

    private static func summarizeToolParameters(_ input: [String: Any]?) -> String? {
        guard let input else { return nil }
        let keys = ["command", "cmd", "file_path", "filePath", "path", "dir_path", "pattern", "query", "url", "description", "prompt"]
        for key in keys {
            if let str = input[key] as? String,
               let clean = SessionTurnPreviewInspector.sanitizeAndRedact(str, maxLength: 160) {
                return clean
            }
            if let arr = input[key] as? [String],
               let clean = SessionTurnPreviewInspector.sanitizeAndRedact(arr.joined(separator: " "), maxLength: 160) {
                return clean
            }
        }
        return nil
    }
}

/// Executes headless coding CLI turns (`codex`, `gemini`, `opencode`, `claude`) with live NDJSON streaming.
public final class AgentChatStreamRunner: @unchecked Sendable {
    private final class ActiveStreamEntry: @unchecked Sendable {
        let process: Process
        var wasCancelled: Bool = false

        init(process: Process) {
            self.process = process
        }
    }

    private static let commonAllowedEnvironmentKeys: [String] = [
        "USER", "LOGNAME", "TMPDIR", "SHELL", "SSH_AUTH_SOCK",
        "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME",
        "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "ALL_PROXY",
        "http_proxy", "https_proxy", "no_proxy",
        "SSL_CERT_FILE", "NODE_EXTRA_CA_CERTS"
    ]

    private static let staticUserToolRelativeDirs: [String] = [
        ".opencode/bin",
        ".local/bin",
        ".bun/bin",
        ".npm-global/bin",
        "Library/pnpm",
        ".pnpm",
        ".volta/bin",
        ".asdf/shims",
        ".local/share/mise/shims",
        ".cargo/bin",
        "bin",
        ".claude/local"
    ]

    public static let supportedChatProviders: [SessionProviderKind] = [
        .codex, .gemini, .openCode, .claude
    ]

    private let lock = NSLock()
    private var activeRuns: [UUID: ActiveStreamEntry] = [:]
    private let homeDirectory: URL
    private let baseEnvironment: [String: String]
    private let executableResolver: (@Sendable (SessionProviderKind) -> String?)?

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        executableResolver: (@Sendable (SessionProviderKind) -> String?)? = nil
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.baseEnvironment = baseEnvironment
        self.executableResolver = executableResolver
    }

    public static func cliBinaryName(for provider: SessionProviderKind) -> String? {
        switch provider {
        case .codex: return "codex"
        case .gemini: return "gemini"
        case .openCode: return "opencode"
        case .claude: return "claude"
        case .cursor, .other: return nil
        }
    }

    /// Discovers user + version-manager + system bin directories so macOS `/Applications` launches find Node/Rust CLIs.
    public static func searchDirectories(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        let home = homeDirectory.standardizedFileURL
        var ordered: [String] = []
        var seen = Set<String>()

        func appendIfDirectory(_ path: String) {
            guard path.hasPrefix("/"), path != "/", seen.insert(path).inserted else { return }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                ordered.append(path)
            }
        }

        for rel in staticUserToolRelativeDirs {
            appendIfDirectory(home.appendingPathComponent(rel, isDirectory: true).path)
        }

        // Node version managers (NVM, fnm, mise) sorted descending so newest Node runtime wins
        let versionRoots: [(parent: URL, suffix: String)] = [
            (home.appendingPathComponent(".nvm/versions/node", isDirectory: true), "bin"),
            (home.appendingPathComponent("Library/Application Support/fnm/node-versions", isDirectory: true), "installation/bin"),
            (home.appendingPathComponent(".fnm/node-versions", isDirectory: true), "installation/bin"),
            (home.appendingPathComponent(".local/share/fnm/node-versions", isDirectory: true), "installation/bin"),
            (home.appendingPathComponent(".local/share/mise/installs/node", isDirectory: true), "bin")
        ]
        for entry in versionRoots {
            if let children = try? FileManager.default.contentsOfDirectory(
                at: entry.parent,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                let sortedNames = children.map(\.lastPathComponent).sorted {
                    $0.compare($1, options: [.numeric]) == .orderedDescending
                }
                for versionName in sortedNames.prefix(8) {
                    let binDir = entry.parent
                        .appendingPathComponent(versionName, isDirectory: true)
                        .appendingPathComponent(entry.suffix, isDirectory: true)
                        .path
                    appendIfDirectory(binDir)
                }
            }
        }

        if let rawPath = baseEnvironment["PATH"] {
            for piece in rawPath.split(separator: ":") {
                appendIfDirectory(String(piece))
            }
        }

        for sys in ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"] {
            appendIfDirectory(sys)
        }

        return ordered
    }

    public static func discoverExecutable(
        for provider: SessionProviderKind,
        preferredExecutable: String? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let binary = cliBinaryName(for: provider) else { return nil }
        if let preferred = preferredExecutable,
           preferred.hasPrefix("/"),
           URL(fileURLWithPath: preferred).lastPathComponent == binary,
           FileManager.default.isExecutableFile(atPath: preferred) {
            return preferred
        }
        let dirs = searchDirectories(homeDirectory: homeDirectory, baseEnvironment: baseEnvironment)
        for dir in dirs {
            let candidate = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent(binary).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        if provider == .codex {
            let appCodex = "/Applications/Codex.app/Contents/Resources/codex"
            if FileManager.default.isExecutableFile(atPath: appCodex) {
                return appCodex
            }
        }
        return nil
    }

    public static func installedChatProviders(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [SessionProviderKind] {
        supportedChatProviders.filter { provider in
            discoverExecutable(for: provider, homeDirectory: homeDirectory, baseEnvironment: baseEnvironment) != nil
        }
    }

    public static func cleanChatPrompt(_ raw: String, maxLength: Int = 12_000) -> String? {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var scalars = String.UnicodeScalarView()
        for scalar in normalized.unicodeScalars {
            if scalar == "\n" || scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar) {
                scalars.append(scalar)
            }
        }
        let cleaned = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= maxLength else { return nil }
        return cleaned
    }

    public static func validateSessionID(_ raw: String) -> String? {
        AgentContextValidation.sessionID(raw)
    }

    public static func buildArguments(
        for request: AgentChatStreamRequest,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Result<[String], AgentChatStreamError> {
        guard cliBinaryName(for: request.provider) != nil else {
            return .failure(.unsupportedProvider(request.provider))
        }
        guard let cleanPrompt = cleanChatPrompt(request.prompt) else {
            return .failure(.emptyOrInvalidPrompt)
        }
        let validatedSessionID: String?
        if let rawSID = request.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !rawSID.isEmpty {
            guard let valid = AgentContextValidation.sessionID(rawSID) else {
                return .failure(.invalidSessionID(rawSID))
            }
            validatedSessionID = valid
        } else {
            validatedSessionID = nil
        }

        switch request.provider {
        case .codex:
            let codexHome = homeDirectory.standardizedFileURL.appendingPathComponent(".codex", isDirectory: true).path
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let quotedHome = (try? encoder.encode(codexHome)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\(codexHome)\""
            if let sid = validatedSessionID {
                return .success([
                    "exec",
                    "--json",
                    "--skip-git-repo-check",
                    "-c", "sqlite_home=" + quotedHome,
                    "resume", sid,
                    "--", cleanPrompt
                ])
            } else {
                return .success([
                    "exec",
                    "--json",
                    "--skip-git-repo-check",
                    "-c", "sqlite_home=" + quotedHome,
                    "--", cleanPrompt
                ])
            }

        case .gemini:
            if let sid = validatedSessionID {
                return .success([
                    "--resume", sid,
                    "--output-format", "stream-json",
                    "--prompt=" + cleanPrompt
                ])
            } else {
                return .success([
                    "--output-format", "stream-json",
                    "--prompt=" + cleanPrompt
                ])
            }

        case .openCode:
            if let sid = validatedSessionID {
                return .success([
                    "run", "--format", "json", "--session", sid, "--", cleanPrompt
                ])
            } else {
                return .success([
                    "run", "--format", "json", "--", cleanPrompt
                ])
            }

        case .claude:
            if let sid = validatedSessionID {
                return .success([
                    "-p", "--verbose", "--output-format", "stream-json", "--resume", sid, "--", cleanPrompt
                ])
            } else {
                return .success([
                    "-p", "--verbose", "--output-format", "stream-json", "--", cleanPrompt
                ])
            }

        case .cursor, .other:
            return .failure(.unsupportedProvider(request.provider))
        }
    }

    public static func buildEnvironment(
        for provider: SessionProviderKind,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        let home = homeDirectory.standardizedFileURL
        let pathString = searchDirectories(homeDirectory: home, baseEnvironment: baseEnvironment).joined(separator: ":")
        let langValue: String = {
            if let existing = sanitizedEnvValue(baseEnvironment["LANG"]),
               existing.uppercased().contains("UTF-8") || existing.uppercased().contains("UTF8") {
                return existing
            }
            return "en_US.UTF-8"
        }()

        var env: [String: String] = [
            "HOME": home.path,
            "PATH": pathString,
            "LANG": langValue,
            "TERM": "dumb",
            "NO_COLOR": "1",
            "GIT_OPTIONAL_LOCKS": "0"
        ]

        let providerKeys: [String]
        switch provider {
        case .codex:
            providerKeys = ["OPENAI_API_KEY", "OPENAI_BASE_URL", "OPENAI_ORG_ID"]
        case .gemini:
            providerKeys = [
                "GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_CLOUD_PROJECT",
                "GOOGLE_CLOUD_LOCATION", "GOOGLE_GENAI_USE_VERTEXAI",
                "GOOGLE_APPLICATION_CREDENTIALS", "GEMINI_MODEL"
            ]
        case .openCode:
            providerKeys = [
                "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GEMINI_API_KEY",
                "GOOGLE_GENERATIVE_AI_API_KEY", "OPENROUTER_API_KEY"
            ]
        case .claude:
            providerKeys = [
                "ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL",
                "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX"
            ]
        case .cursor, .other:
            providerKeys = []
        }

        for key in commonAllowedEnvironmentKeys + providerKeys {
            if let val = sanitizedEnvValue(baseEnvironment[key]) {
                env[key] = val
            }
        }

        switch provider {
        case .codex:
            let codexHome = home.appendingPathComponent(".codex", isDirectory: true).path
            env["CODEX_HOME"] = codexHome
            env["CODEX_SQLITE_HOME"] = codexHome
        case .openCode:
            let dbPath = home.appendingPathComponent(".local/share/opencode/opencode.db").path
            if FileManager.default.fileExists(atPath: dbPath) {
                env["OPENCODE_DB"] = dbPath
            }
        case .claude:
            let claudeDir = home.appendingPathComponent(".claude", isDirectory: true).path
            if FileManager.default.fileExists(atPath: claudeDir) {
                env["CLAUDE_CONFIG_DIR"] = claudeDir
            }
        case .gemini, .cursor, .other:
            break
        }

        return env
    }

    public func start(
        request: AgentChatStreamRequest,
        onEvent: @escaping @Sendable (AgentChatStreamEvent) -> Void
    ) -> Result<UUID, AgentChatStreamError> {
        guard let binaryName = Self.cliBinaryName(for: request.provider) else {
            return .failure(.unsupportedProvider(request.provider))
        }

        let trimmedPath = request.projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPath.hasPrefix("/"), trimmedPath != "/" else {
            return .failure(.invalidWorkspaceDirectory(request.projectPath))
        }
        let workingDir = URL(fileURLWithPath: trimmedPath, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var isDir: ObjCBool = false
        guard workingDir.path != "/",
              FileManager.default.fileExists(atPath: workingDir.path, isDirectory: &isDir),
              isDir.boolValue else {
            return .failure(.invalidWorkspaceDirectory(request.projectPath))
        }

        let arguments: [String]
        switch Self.buildArguments(for: request, homeDirectory: homeDirectory) {
        case .success(let args):
            arguments = args
        case .failure(let err):
            return .failure(err)
        }

        let resolvedExecutable: String?
        if let executableResolver {
            resolvedExecutable = executableResolver(request.provider)
        } else {
            resolvedExecutable = Self.discoverExecutable(
                for: request.provider,
                preferredExecutable: request.preferredExecutablePath,
                homeDirectory: homeDirectory,
                baseEnvironment: baseEnvironment
            )
        }
        guard let executablePath = resolvedExecutable,
              executablePath.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: executablePath) else {
            return .failure(.executableNotFound(request.provider, binaryName: binaryName))
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutReadHandle = stdoutPipe.fileHandleForReading
        let stderrReadHandle = stderrPipe.fileHandleForReading
        let outFD = stdoutReadHandle.fileDescriptor
        let errFD = stderrReadHandle.fileDescriptor
        _ = fcntl(outFD, F_SETFD, fcntl(outFD, F_GETFD) | FD_CLOEXEC)
        _ = fcntl(errFD, F_SETFD, fcntl(errFD, F_GETFD) | FD_CLOEXEC)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = workingDir
        process.environment = Self.buildEnvironment(
            for: request.provider,
            homeDirectory: homeDirectory,
            baseEnvironment: baseEnvironment
        )
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let runID = UUID()
        let entry = ActiveStreamEntry(process: process)
        lock.withLock {
            activeRuns[runID] = entry
        }

        do {
            try process.run()
        } catch {
            _ = lock.withLock { activeRuns.removeValue(forKey: runID) }
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            try? stdoutReadHandle.close()
            try? stderrReadHandle.close()
            return .failure(.launchFailed(error.localizedDescription))
        }

        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        _ = fcntl(outFD, F_SETFL, fcntl(outFD, F_GETFL) | O_NONBLOCK)
        _ = fcntl(errFD, F_SETFL, fcntl(errFD, F_GETFL) | O_NONBLOCK)

        let provider = request.provider
        let maxStderrBytes = 32 * 1_024

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var parser = AgentStreamLineParser(provider: provider)
            var lineBuffer = Data()
            var stderrCollected = Data()
            var outOpen = true
            var errOpen = true
            var exitedSinceNs: UInt64?
            var readBuf = [UInt8](repeating: 0, count: 8_192)

            func drainStdout() {
                while outOpen {
                    let n = readBuf.withUnsafeMutableBytes { ptr in
                        Darwin.read(outFD, ptr.baseAddress, ptr.count)
                    }
                    if n > 0 {
                        lineBuffer.append(contentsOf: readBuf[0..<n])
                        while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
                            let lineData = Data(lineBuffer[..<newlineIndex])
                            lineBuffer.removeSubrange(...newlineIndex)
                            let lineStr = String(decoding: lineData, as: UTF8.self)
                            for ev in parser.parseLine(lineStr) {
                                onEvent(ev)
                            }
                        }
                        if lineBuffer.count > 512 * 1_024 {
                            let chunkStr = String(decoding: lineBuffer, as: UTF8.self)
                            lineBuffer.removeAll(keepingCapacity: true)
                            for ev in parser.parseLine(chunkStr) {
                                onEvent(ev)
                            }
                        }
                    } else if n == 0 {
                        outOpen = false
                        break
                    } else if errno == EINTR {
                        continue
                    } else {
                        if errno != EAGAIN && errno != EWOULDBLOCK {
                            outOpen = false
                        }
                        break
                    }
                }
            }

            func drainStderr() {
                while errOpen {
                    let n = readBuf.withUnsafeMutableBytes { ptr in
                        Darwin.read(errFD, ptr.baseAddress, ptr.count)
                    }
                    if n > 0 {
                        let remaining = maxStderrBytes - stderrCollected.count
                        if remaining > 0 {
                            stderrCollected.append(contentsOf: readBuf[0..<min(n, remaining)])
                        }
                    } else if n == 0 {
                        errOpen = false
                        break
                    } else if errno == EINTR {
                        continue
                    } else {
                        if errno != EAGAIN && errno != EWOULDBLOCK {
                            errOpen = false
                        }
                        break
                    }
                }
            }

            while true {
                drainStdout()
                drainStderr()

                if !process.isRunning {
                    if !outOpen && !errOpen {
                        break
                    }
                    let nowNs = DispatchTime.now().uptimeNanoseconds
                    if let since = exitedSinceNs {
                        // Do not block forever if a background MCP/server grandchild retained the pipe fd
                        if nowNs - since >= 80_000_000 {
                            break
                        }
                    } else {
                        exitedSinceNs = nowNs
                    }
                }

                var pfds: [pollfd] = []
                if outOpen {
                    pfds.append(pollfd(fd: outFD, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0))
                }
                if errOpen {
                    pfds.append(pollfd(fd: errFD, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0))
                }
                if pfds.isEmpty {
                    if !process.isRunning { break }
                    usleep(15_000)
                } else {
                    let timeoutMs: Int32 = process.isRunning ? 45 : 15
                    _ = pfds.withUnsafeMutableBufferPointer { buf in
                        Darwin.poll(buf.baseAddress, nfds_t(buf.count), timeoutMs)
                    }
                }
            }

            drainStdout()
            drainStderr()
            if !lineBuffer.isEmpty {
                let finalLine = String(decoding: lineBuffer, as: UTF8.self)
                for ev in parser.parseLine(finalLine) {
                    onEvent(ev)
                }
            }

            process.waitUntilExit()
            let exitCode = process.terminationStatus
            try? stdoutReadHandle.close()
            try? stderrReadHandle.close()

            let wasCancelled: Bool = self?.lock.withLock {
                let removed = self?.activeRuns.removeValue(forKey: runID)
                return removed?.wasCancelled ?? false
            } ?? false

            if exitCode != 0, !wasCancelled, !parser.hasEmittedError {
                let rawErr = String(decoding: stderrCollected, as: UTF8.self)
                let message = AgentStreamLineParser.cleanErrorMessage(rawErr)
                    ?? "\(provider.rawValue) exited with status \(exitCode)."
                onEvent(.error(message))
            }
            onEvent(.finished(exitCode: exitCode))
        }

        return .success(runID)
    }

    @discardableResult
    public func cancel(runID: UUID) -> Bool {
        let process: Process? = lock.withLock {
            guard let entry = activeRuns[runID] else { return nil }
            entry.wasCancelled = true
            return entry.process
        }
        guard let process else { return false }
        if process.isRunning {
            process.terminate()
        }
        return true
    }

    public func cancelAll() {
        let processes: [Process] = lock.withLock {
            for entry in activeRuns.values {
                entry.wasCancelled = true
            }
            return activeRuns.values.map(\.process)
        }
        for process in processes where process.isRunning {
            process.terminate()
        }
    }

    private static func sanitizedEnvValue(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.utf8.count <= 4_096,
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return raw
    }
}
