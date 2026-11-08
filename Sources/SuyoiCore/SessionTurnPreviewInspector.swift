import Foundation
import Darwin

public struct SessionToolCallSummary: Codable, Equatable, Sendable {
    public let toolName: String
    public let targetSummary: String?
    public let status: String

    public init(toolName: String, targetSummary: String?, status: String) {
        self.toolName = toolName
        self.targetSummary = targetSummary
        self.status = status
    }
}

public struct SessionTurnPreview: Codable, Equatable, Sendable {
    public let sessionID: String?
    public let lastUserPromptPreview: String?
    public let lastAssistantReplyPreview: String?
    /// Newest first, including an observed running tool when available.
    public let recentTools: [SessionToolCallSummary]
    public let updatedAt: Date?

    public init(sessionID: String?, lastUserPromptPreview: String?, lastAssistantReplyPreview: String?, recentTools: [SessionToolCallSummary], updatedAt: Date?) {
        self.sessionID = sessionID
        self.lastUserPromptPreview = lastUserPromptPreview
        self.lastAssistantReplyPreview = lastAssistantReplyPreview
        self.recentTools = recentTools
        self.updatedAt = updatedAt
    }
}

/// On-demand, local display only. A preview does not establish live session ownership.
/// No records, prompts, tool outputs, or read errors are persisted or logged.
public struct SessionTurnPreviewInspector: Sendable {
    private let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    public static func sanitizeAndRedact(_ raw: String, maxLength: Int = 160) -> String? {
        guard maxLength > 0 else { return nil }
        var text = String(String.UnicodeScalarView(raw.unicodeScalars.compactMap { scalar in
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return Unicode.Scalar(32) }
            return CharacterSet.controlCharacters.contains(scalar) ? nil : scalar
        }))
        let patterns = [
            #"sk-[A-Za-z0-9_-]{12,}"#,
            #"gh[pousr]_[A-Za-z0-9]{12,}"#,
            #"AIza[A-Za-z0-9_-]{16,}"#,
            #"(?i:Bearer)\s+[A-Za-z0-9._-]+"#,
            #"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}(?:\.[A-Za-z0-9_-]+)?"#
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            text = expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "[REDACTED]")
        }
        text = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        return text.count > maxLength ? String(text.prefix(maxLength - 1)) + "…" : text
    }

    public func inspectPreview(for agent: AgentObservation, allProcesses: [ObservedProcess] = []) -> SessionTurnPreview? {
        let running = runningTool(for: agent, allProcesses: allProcesses)
        let isCodex = agent.agentName == "Codex"
        guard isCodex || agent.agentName == "Claude Code" else { return nil }
        let requestedID = agent.sessionID.flatMap(AgentContextValidation.sessionID)
        // An invalid explicit identifier must never broaden discovery to another session.
        guard agent.sessionID == nil || requestedID != nil else { return nil }
        let root = (agent.project?.rootPath ?? agent.process.cwd).flatMap { raw -> String? in
            guard raw.hasPrefix("/") else { return nil }
            let path = URL(fileURLWithPath: raw).standardizedFileURL.path
            return path == "/" || path == homeDirectory.standardizedFileURL.path ? nil : path
        }
        guard requestedID != nil || root != nil else { return toolOnly(running, agent: agent) }

        for file in candidateFiles(codex: isCodex, sessionID: requestedID) {
            guard let source = readSource(file.url) else { continue }
            let metadata = source.header + source.tail
            let ids: [String]
            let directory: String?
            if isCodex {
                let payloads = metadata.filter { $0["type"] as? String == "session_meta" }.compactMap { $0["payload"] as? [String: Any] }
                ids = payloads.compactMap { ($0["id"] as? String).flatMap(AgentContextValidation.sessionID) }
                directory = payloads.compactMap { $0["cwd"] as? String }.first
            } else {
                ids = metadata.compactMap { ($0["sessionId"] as? String).flatMap(AgentContextValidation.sessionID) }
                directory = metadata.compactMap { $0["cwd"] as? String }.first
            }
            // Conflicting session metadata must never be associated by project alone.
            guard Set(ids).count <= 1 else { continue }
            let filenameID = isCodex ? nil : AgentContextValidation.sessionID(file.url.deletingPathExtension().lastPathComponent)
            let id = ids.first ?? filenameID
            if let requestedID {
                if let id {
                    guard id == requestedID else { continue }
                } else {
                    let stem = file.url.deletingPathExtension().lastPathComponent
                    guard stem == requestedID || stem.hasSuffix("-" + requestedID) else { continue }
                }
            } else if let root {
                if let directory {
                    guard directory.hasPrefix("/"), URL(fileURLWithPath: directory).standardizedFileURL.path == root else { continue }
                } else {
                    guard !isCodex, file.url.deletingLastPathComponent().lastPathComponent == encodedClaudeDirectory(root) else { continue }
                }
            }
            let preview = parse(source.tail, codex: isCodex, sessionID: id ?? requestedID, modifiedAt: source.modifiedAt, running: running)
            if preview.lastUserPromptPreview != nil || preview.lastAssistantReplyPreview != nil || !preview.recentTools.isEmpty {
                return preview
            }
            // The selected latest session may be empty; do not show an older session's conversation.
            return nil
        }
        return toolOnly(running, agent: agent)
    }

    private struct Candidate {
        let url: URL
        let modifiedAt: Date
    }

    private func candidateFiles(codex: Bool, sessionID: String?) -> [Candidate] {
        let base = homeDirectory.appendingPathComponent(codex ? ".codex/sessions" : ".claude/projects")
        var files: [Candidate] = []
        var remaining = 4_096
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        func visit(_ directory: URL, depth: Int) {
            guard remaining > 0, ProcessInfo.processInfo.systemUptime < deadline, QuotaParsing.safePath(directory),
                  let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey], options: [.skipsSubdirectoryDescendants]) else { return }
            while remaining > 0, ProcessInfo.processInfo.systemUptime < deadline, let url = entries.nextObject() as? URL {
                remaining -= 1
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                      values.isSymbolicLink != true else { continue }
                let leafDepth = codex ? 3 : 1
                if values.isDirectory == true, depth < leafDepth {
                    if codex {
                        let name = url.lastPathComponent
                        guard name.count == (depth == 0 ? 4 : 2), name.utf8.allSatisfy({ (48...57).contains($0) }),
                              let number = Int(name), depth == 0 || (1...(depth == 1 ? 12 : 31)).contains(number) else { continue }
                    }
                    visit(url, depth: depth + 1)
                } else if depth == leafDepth, values.isRegularFile == true, url.pathExtension == "jsonl" {
                    files.append(Candidate(url: url, modifiedAt: values.contentModificationDate ?? .distantPast))
                }
            }
        }
        visit(base, depth: 0)
        return Array(files.sorted {
            if let sessionID {
                func matches(_ file: Candidate) -> Bool {
                    let stem = file.url.deletingPathExtension().lastPathComponent
                    return stem == sessionID || stem.hasSuffix("-" + sessionID)
                }
                if matches($0) != matches($1) { return matches($0) }
            }
            return $0.modifiedAt == $1.modifiedAt ? $0.url.path < $1.url.path : $0.modifiedAt > $1.modifiedAt
        }.prefix(128))
    }

    private struct Source {
        let header: [[String: Any]]
        let tail: [[String: Any]]
        let modifiedAt: Date
    }

    private func readSource(_ url: URL) -> Source? {
        guard QuotaParsing.safePath(url) else { return nil }
        // Only the standard macOS filesystem aliases are canonicalized; user symlinks remain rejected.
        var path = url.path
        if ["/var/", "/tmp/", "/etc/"].contains(where: { path.hasPrefix($0) }) { path = "/private" + path }
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else { return nil }
        func read(_ count: Int, offset: off_t) -> Data? {
            var data = Data(count: count)
            let length = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, count, offset) }
            guard length >= 0 else { return nil }
            data.count = length
            return data
        }
        func records(_ data: Data) -> [[String: Any]] {
            data.split(separator: 10).compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
        }
        let budget = 64 * 1_024
        let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        if info.st_size <= budget {
            guard let data = read(Int(info.st_size), offset: 0) else { return nil }
            return Source(header: [], tail: records(data), modifiedAt: modified)
        }
        // Reserve 8 KB for association metadata and 56 KB for the live tail: 64 KB total.
        guard var header = read(8 * 1_024, offset: 0),
              var tail = read(56 * 1_024, offset: info.st_size - off_t(56 * 1_024)) else { return nil }
        if let end = header.lastIndex(of: 10) { header = Data(header.prefix(through: end)) } else { header = Data() }
        if let start = tail.firstIndex(of: 10) { tail.removeSubrange(...start) } else { tail = Data() }
        return Source(header: records(header), tail: records(tail), modifiedAt: modified)
    }

    private struct Tool {
        let id: String?
        let name: String
        let target: String?
        var status: String

        var summary: SessionToolCallSummary { SessionToolCallSummary(toolName: name, targetSummary: target, status: status) }
    }

    private func parse(_ records: [[String: Any]], codex: Bool, sessionID: String?, modifiedAt: Date, running: SessionToolCallSummary?) -> SessionTurnPreview {
        var user: String?
        var assistant: String?
        var tools: [Tool] = []
        var updatedAt: Date?
        func addTool(_ item: [String: Any], claude: Bool) {
            guard let raw = item["name"] as? String,
                  let name = Self.sanitizeAndRedact(raw, maxLength: 64) else { return }
            let id = item[claude ? "id" : "call_id"] as? String
            var input = item[claude ? "input" : "arguments"] as? [String: Any]
            if input == nil, let arguments = item["arguments"] as? String, let data = arguments.data(using: .utf8) {
                input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
            // Display one useful target field, never the complete argument dictionary or result body.
            let target = ["file_path", "path", "url", "command", "cmd", "pattern", "query"].compactMap { key -> String? in
                if let value = input?[key] as? String { return Self.sanitizeAndRedact(value) }
                if let values = input?[key] as? [String] { return Self.sanitizeAndRedact(values.joined(separator: " ")) }
                return nil
            }.first
            if let id, tools.contains(where: { $0.id == id }) { return }
            tools.append(Tool(id: id, name: name, target: target, status: "running"))
            if tools.count > 3 { tools.removeFirst() }
        }
        func finishTool(_ item: [String: Any], claude: Bool) {
            guard let id = item[claude ? "tool_use_id" : "call_id"] as? String,
                  let index = tools.lastIndex(where: { $0.id == id }) else { return }
            tools[index].status = item["is_error"] as? Bool == true || ["failed", "error"].contains(item["status"] as? String ?? "") ? "failed" : "completed"
        }
        for record in records {
            var recognized = false
            if codex, record["type"] as? String == "event_msg", let payload = record["payload"] as? [String: Any],
               let message = payload["message"] as? String {
                if payload["type"] as? String == "user_message", let text = Self.sanitizeAndRedact(message) { user = text; recognized = true }
                if payload["type"] as? String == "agent_message", let text = Self.sanitizeAndRedact(message) { assistant = text; recognized = true }
            } else if codex, record["type"] as? String == "response_item", let payload = record["payload"] as? [String: Any] {
                switch payload["type"] as? String {
                case "message":
                    let role = payload["role"] as? String
                    if let text = messageText(payload["content"]), role == "user" || role == "assistant" {
                        if role == "user" { user = text } else { assistant = text }
                        recognized = true
                    }
                case "function_call", "custom_tool_call": addTool(payload, claude: false); recognized = true
                case "function_call_output", "custom_tool_call_output": finishTool(payload, claude: false); recognized = true
                default: break
                }
            } else if !codex, record["isSidechain"] as? Bool != true,
                      let type = record["type"] as? String, type == "user" || type == "assistant",
                      let message = record["message"] as? [String: Any] {
                if let text = messageText(message["content"]) {
                    if type == "user" { user = text } else { assistant = text }
                    recognized = true
                }
                for block in message["content"] as? [[String: Any]] ?? [] {
                    if type == "assistant", block["type"] as? String == "tool_use" { addTool(block, claude: true); recognized = true }
                    if type == "user", block["type"] as? String == "tool_result" { finishTool(block, claude: true); recognized = true }
                }
            }
            if recognized, let date = QuotaParsing.date(record["timestamp"]), updatedAt == nil || date > updatedAt! { updatedAt = date }
        }
        var recent = tools.reversed().map(\.summary)
        if let running { recent.insert(running, at: 0) }
        return SessionTurnPreview(sessionID: sessionID.flatMap { Self.sanitizeAndRedact($0, maxLength: 96) }, lastUserPromptPreview: user,
                                  lastAssistantReplyPreview: assistant, recentTools: Array(recent.prefix(3)), updatedAt: updatedAt ?? modifiedAt)
    }

    private func messageText(_ content: Any?) -> String? {
        if let text = content as? String { return Self.sanitizeAndRedact(text) }
        guard let blocks = content as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { block -> String? in
            guard ["text", "input_text", "output_text"].contains(block["type"] as? String ?? "") else { return nil }
            return block["text"] as? String
        }
        return Self.sanitizeAndRedact(texts.joined(separator: " "))
    }

    private func encodedClaudeDirectory(_ root: String) -> String {
        String(root.map { character in
            character.isASCII && (character.isLetter || character.isNumber) ? character : "-"
        })
    }

    private func runningTool(for agent: AgentObservation, allProcesses: [ObservedProcess]) -> SessionToolCallSummary? {
        if !agent.process.isStopped, let task = agent.currentTask {
            for part in task.components(separatedBy: " · ") where part.hasPrefix("Running: ") {
                let label = String(part.dropFirst("Running: ".count))
                if let name = label.split(whereSeparator: { $0.isWhitespace }).first.flatMap({ Self.sanitizeAndRedact(String($0), maxLength: 64) }) {
                    return SessionToolCallSummary(toolName: name, targetSummary: Self.sanitizeAndRedact(label), status: "running")
                }
            }
        }
        guard !agent.process.isStopped else { return nil }
        let processes = allProcesses.contains(where: { $0.pid == agent.process.pid }) ? allProcesses : allProcesses + [agent.process]
        let tree = ProcessTree(processes: processes)
        let knownTools: Set<String> = ["swift", "swift-frontend", "cargo", "git", "rg", "npm", "pnpm", "bun", "node", "python", "python3", "pytest", "go", "xcodebuild", "make"]
        for pid in tree.descendants(of: agent.process.pid).sorted() {
            guard let process = tree.processesByPID[pid], process.uid == agent.process.uid, !process.isStopped,
                  knownTools.contains(process.name), let name = Self.sanitizeAndRedact(process.name, maxLength: 64) else { continue }
            return SessionToolCallSummary(toolName: name, targetSummary: nil, status: "running")
        }
        return nil
    }

    private func toolOnly(_ running: SessionToolCallSummary?, agent: AgentObservation) -> SessionTurnPreview? {
        guard let running else { return nil }
        return SessionTurnPreview(sessionID: nil, lastUserPromptPreview: nil, lastAssistantReplyPreview: nil,
                                  recentTools: [running], updatedAt: agent.lastActivityAt)
    }
}
