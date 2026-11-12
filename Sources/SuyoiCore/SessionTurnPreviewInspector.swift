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

    private static let secretPatterns: [NSRegularExpression] = [
        #"(?i:Bearer)\s+[A-Za-z0-9._~+/-]+=*"#,
        #"sk-[A-Za-z0-9_-]{12,}"#,
        #"gh[pousr]_[A-Za-z0-9]{12,}"#,
        #"github_pat_[A-Za-z0-9_]{20,}"#,
        #"AKIA[0-9A-Z]{16}"#,
        #"xox[baprs]-[A-Za-z0-9-]{10,}"#,
        #"AIza[A-Za-z0-9_-]{16,}"#,
        #"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}(?:\.[A-Za-z0-9_-]+)?"#,
        #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|$)"#,
        #"(?<=://)[^/\s:@]+:[^/\s@]+(?=@)"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    public static func sanitizeAndRedact(_ raw: String, maxLength: Int = 160) -> String? {
        guard maxLength > 0 else { return nil }
        var text = String(String.UnicodeScalarView(raw.unicodeScalars.compactMap { scalar in
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return Unicode.Scalar(32) }
            return CharacterSet.controlCharacters.contains(scalar) ? nil : scalar
        }))
        for expression in secretPatterns {
            text = expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "[REDACTED]")
        }
        text = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        return text.count > maxLength ? String(text.prefix(maxLength - 1)) + "…" : text
    }

    public func inspectPreview(for agent: AgentObservation, allProcesses: [ObservedProcess] = []) -> SessionTurnPreview? {
        let running = runningTool(for: agent, allProcesses: allProcesses)
        let isCodex = agent.agentName == "Codex"
        guard isCodex || agent.agentName == "Claude Code",
              let cwd = agent.process.cwd, cwd.hasPrefix("/"), cwd != "/",
              let evidence = SessionFileEvidence.live(for: agent.process,
                beneath: homeDirectory.appendingPathComponent(isCodex ? ".codex/sessions" : ".claude/projects")),
              let source = readSource(evidence.url, evidence: evidence, uid: agent.process.uid) else {
            return toolOnly(running, agent: agent)
        }
        let association = association(in: source, codex: isCodex)
        guard association.ids.count == 1, let id = association.ids.first,
              let directory = association.cwd, directory.hasPrefix("/"),
              URL(fileURLWithPath: directory).standardizedFileURL.path == URL(fileURLWithPath: cwd).standardizedFileURL.path else {
            return toolOnly(running, agent: agent)
        }
        let stem = evidence.url.deletingPathExtension().lastPathComponent
        guard isCodex ? stem.hasSuffix("-" + id) : stem == id else { return toolOnly(running, agent: agent) }
        return nonemptyPreview(source, codex: isCodex, id: id, running: running)
    }

    /// Reads an explicitly identified historical session, separate from a live row preview.
    public func inspectSelectedSession(_ sessionID: String, for agent: AgentObservation,
                                allProcesses: [ObservedProcess] = []) -> SessionTurnPreview? {
        let running = runningTool(for: agent, allProcesses: allProcesses)
        if agent.agentName == "OpenCode" || agent.agentName == "Gemini CLI" {
            guard let requestedID = AgentContextValidation.sessionID(sessionID) else { return toolOnly(running, agent: agent) }
            return inspectAdditionalPreview(for: agent, sessionID: requestedID, running: running) ?? toolOnly(running, agent: agent)
        }
        let isCodex = agent.agentName == "Codex"
        guard isCodex || agent.agentName == "Claude Code" else { return toolOnly(running, agent: agent) }
        guard let requestedID = AgentContextValidation.sessionID(sessionID) else { return nil }
        for file in candidateFiles(codex: isCodex, sessionID: requestedID) {
            guard let source = readSource(file.url) else { continue }
            let association = association(in: source, codex: isCodex)
            let stem = file.url.deletingPathExtension().lastPathComponent
            guard association.ids == [requestedID] ||
                (association.ids.isEmpty && (stem == requestedID || (isCodex && stem.hasSuffix("-" + requestedID)))) else { continue }
            return nonemptyPreview(source, codex: isCodex, id: requestedID, running: running)
        }
        return toolOnly(running, agent: agent)
    }

    private func association(in source: Source, codex: Bool) -> (ids: Set<String>, cwd: String?) {
        let records = source.header + source.tail
        let metadata = codex
            ? records.filter { $0["type"] as? String == "session_meta" }.compactMap { $0["payload"] as? [String: Any] }
            : records
        let ids = Set(metadata.compactMap { $0[codex ? "id" : "sessionId"] as? String })
        if ids.contains(where: { AgentContextValidation.sessionID($0) == nil }) { return (["", "invalid"], nil) }
        let directories = Set(metadata.compactMap { $0["cwd"] as? String })
        return (ids, directories.count == 1 ? directories.first : nil)
    }

    private func nonemptyPreview(_ source: Source, codex: Bool, id: String, running: SessionToolCallSummary?) -> SessionTurnPreview? {
        let preview = parse(source.tail, codex: codex, sessionID: id, modifiedAt: source.modifiedAt, running: running)
        return preview.lastUserPromptPreview != nil || preview.lastAssistantReplyPreview != nil || !preview.recentTools.isEmpty ? preview : nil
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

    private func readSource(_ url: URL, document: Bool = false, evidence: SessionFileEvidence? = nil, uid: Int = Int(getuid())) -> Source? {
        guard QuotaParsing.safePath(url) else { return nil }
        let descriptor = SessionFileEvidence.openRegular(url)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        if let evidence, SessionFileEvidence.readIdentity(descriptor, uid: uid) != evidence.identity { return nil }
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
            if document {
                guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
                let items = (object as? [String: Any]).map { [$0] } ?? (object as? [[String: Any]])
                guard let items else { return nil }
                return Source(header: [], tail: items, modifiedAt: modified)
            }
            return Source(header: [], tail: records(data), modifiedAt: modified)
        }
        // A truncated JSON document cannot safely establish message boundaries or association.
        guard !document else { return nil }
        // Reserve 8 KB for association metadata and 56 KB for the live tail: 64 KB total.
        guard var header = read(8 * 1_024, offset: 0),
              var tail = read(56 * 1_024, offset: info.st_size - off_t(56 * 1_024)) else { return nil }
        if let end = header.lastIndex(of: 10) { header = Data(header.prefix(through: end)) } else { header = Data() }
        if let start = tail.firstIndex(of: 10) { tail.removeSubrange(...start) } else { tail = Data() }
        return Source(header: records(header), tail: records(tail), modifiedAt: modified)
    }

    private func additionalCandidates(openCode: Bool, sessionID: String) -> [Candidate] {
        var files: [Candidate] = []
        var remaining = 4_096
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        func visit(_ directory: URL, nested: Bool = false, chats: Bool = false) {
            guard remaining > 0, ProcessInfo.processInfo.systemUptime < deadline, QuotaParsing.safePath(directory),
                  let entries = FileManager.default.enumerator(at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey],
                    options: [.skipsSubdirectoryDescendants]) else { return }
            while remaining > 0, ProcessInfo.processInfo.systemUptime < deadline, let url = entries.nextObject() as? URL {
                remaining -= 1
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                      values.isSymbolicLink != true else { continue }
                if nested, values.isDirectory == true {
                    visit(chats ? url.appendingPathComponent("chats") : url)
                } else if values.isRegularFile == true, ["json", "jsonl"].contains(url.pathExtension) {
                    files.append(Candidate(url: url, modifiedAt: values.contentModificationDate ?? .distantPast))
                }
            }
        }
        if openCode {
            visit(homeDirectory.appendingPathComponent(".local/share/opencode/storage/message").appendingPathComponent(sessionID))
            visit(homeDirectory.appendingPathComponent(".open-code/sessions"))
            visit(homeDirectory.appendingPathComponent(".local/share/opencode/sessions"))
        } else {
            visit(homeDirectory.appendingPathComponent(".gemini/tmp"), nested: true, chats: true)
            visit(homeDirectory.appendingPathComponent(".gemini/sessions"))
        }
        return Array(files.sorted {
            $0.modifiedAt == $1.modifiedAt ? $0.url.path < $1.url.path : $0.modifiedAt > $1.modifiedAt
        }.prefix(128))
    }

    private func additionalMessages(_ records: [[String: Any]]) -> [[String: Any]] {
        records.flatMap { record -> [[String: Any]] in
            if let messages = record["messages"] as? [[String: Any]] { return messages }
            return [record]
        }
    }

    private func inspectAdditionalPreview(for agent: AgentObservation, sessionID: String, running: SessionToolCallSummary?) -> SessionTurnPreview? {
        let openCode = agent.agentName == "OpenCode"
        let messageDirectory = homeDirectory
            .appendingPathComponent(".local/share/opencode/storage/message")
            .appendingPathComponent(sessionID)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var selected: [(Candidate, Source)] = []
        for file in additionalCandidates(openCode: openCode, sessionID: sessionID) {
            guard let source = readSource(file.url, document: file.url.pathExtension == "json") else { continue }
            let metadata = source.header + source.tail
            let messages = additionalMessages(metadata)
            let bodies = messages.map { $0["message"] as? [String: Any] ?? $0 }
            let objects = metadata + messages + bodies + bodies.compactMap { $0["info"] as? [String: Any] }
                + bodies.flatMap { $0["parts"] as? [[String: Any]] ?? [] }
            let rawIDs = objects.flatMap { object in ["sessionID", "sessionId", "session_id"].compactMap { object[$0] as? String } }
            guard rawIDs.allSatisfy({ AgentContextValidation.sessionID($0) == sessionID }) else { continue }
            let parentDir = file.url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            let messageFile = openCode && parentDir == messageDirectory
            if rawIDs.isEmpty {
                let stem = file.url.deletingPathExtension().lastPathComponent
                guard messageFile || stem == sessionID || stem.hasSuffix("-" + sessionID) else { continue }
            }
            // Combine individual message files only; a session document is a separate snapshot.
            if let first = selected.first {
                let firstParentDir = first.0.url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
                guard messageFile, firstParentDir == messageDirectory else { continue }
            }
            selected.append((file, source))
            if !messageFile { break }
        }
        guard let newest = selected.first else { return nil }
        let newestParentDir = newest.0.url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        var ordered = Array(selected.reversed())
        if openCode, newestParentDir == messageDirectory {
            ordered.sort {
                let lhs = additionalMessageDate($0.1.tail.first ?? [:]) ?? $0.1.modifiedAt
                let rhs = additionalMessageDate($1.1.tail.first ?? [:]) ?? $1.1.modifiedAt
                return lhs == rhs ? $0.0.url.path < $1.0.url.path : lhs < rhs
            }
        }
        var records = ordered.flatMap { additionalMessages($0.1.tail) }
        if openCode, newestParentDir == messageDirectory {
            records = records.map { openCodeMessageWithParts($0, sessionID: sessionID) }
        }
        let preview = parseAdditional(records, openCode: openCode, sessionID: sessionID, modifiedAt: newest.1.modifiedAt, running: running)
        return preview.lastUserPromptPreview != nil || preview.lastAssistantReplyPreview != nil || !preview.recentTools.isEmpty ? preview : nil
    }

    private func additionalMessageDate(_ record: [String: Any]) -> Date? {
        let message = record["message"] as? [String: Any] ?? record
        if let date = QuotaParsing.date(message["timestamp"]) { return date }
        let info = message["info"] as? [String: Any] ?? message
        if let milliseconds = (info["time"] as? [String: Any])?["created"] as? NSNumber {
            return QuotaParsing.date(milliseconds.doubleValue / 1_000)
        }
        return nil
    }

    private func openCodeMessageWithParts(_ record: [String: Any], sessionID: String) -> [String: Any] {
        guard record["parts"] == nil, record["content"] == nil else { return record }
        let info = record["info"] as? [String: Any] ?? record
        guard let id = (info["id"] as? String).flatMap(AgentContextValidation.sessionID) else { return record }
        // Some OpenCode versions store message bodies separately from their session metadata.
        let directory = homeDirectory.appendingPathComponent(".local/share/opencode/storage/part").appendingPathComponent(id)
        guard QuotaParsing.safePath(directory),
              let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [], options: [.skipsSubdirectoryDescendants]) else { return record }
        var urls: [URL] = []
        let deadline = ProcessInfo.processInfo.systemUptime + 0.1
        while urls.count < 128, ProcessInfo.processInfo.systemUptime < deadline, let url = entries.nextObject() as? URL {
            urls.append(url)
        }
        let parts = urls.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.suffix(8).compactMap { url -> [String: Any]? in
            guard let part = readSource(url, document: true)?.tail.first,
                  part["sessionID"] as? String == sessionID, part["messageID"] as? String == id else { return nil }
            return part
        }
        var message = record
        message["parts"] = parts
        return message
    }

    private func parseAdditional(_ records: [[String: Any]], openCode: Bool, sessionID: String, modifiedAt: Date,
                                 running: SessionToolCallSummary?) -> SessionTurnPreview {
        var user: String?
        var assistant: String?
        var tools: [Tool] = []
        var updatedAt: Date?
        func addTool(_ item: [String: Any]) {
            let function = item["function"] as? [String: Any] ?? item
            guard let rawName = (function["name"] ?? item["tool"]) as? String,
                  let name = Self.sanitizeAndRedact(rawName, maxLength: 64) else { return }
            let state = item["state"] as? [String: Any] ?? item
            let rawInput = state["input"] ?? function["args"] ?? function["arguments"] ?? item["args"]
            var input = rawInput as? [String: Any]
            if let raw = rawInput as? String, let data = raw.data(using: .utf8) {
                input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
            let target = ["file_path", "filePath", "path", "url", "command", "cmd", "pattern", "query"].compactMap { key -> String? in
                if let value = input?[key] as? String { return Self.sanitizeAndRedact(value) }
                if let value = input?[key] as? [String] { return Self.sanitizeAndRedact(value.joined(separator: " ")) }
                return nil
            }.first
            let rawStatus = state["status"] as? String ?? ""
            let status = ["error", "failed", "cancelled"].contains(rawStatus) ? "failed"
                : ["completed", "complete", "success", "finished"].contains(rawStatus) ? "completed" : "running"
            let id = (item["callID"] ?? item["id"]) as? String
            if let id { tools.removeAll { $0.id == id } }
            tools.append(Tool(id: id, name: name, target: target, status: status))
            if tools.count > 3 { tools.removeFirst() }
        }
        for record in records {
            let message = record["message"] as? [String: Any] ?? record
            let info = message["info"] as? [String: Any] ?? message
            let role = (info["role"] ?? info["type"]) as? String ?? ""
            let assistantRoles = openCode ? ["assistant"] : ["model", "gemini", "assistant"]
            guard role == "user" || assistantRoles.contains(role) else { continue }
            let content = message["parts"] ?? message["content"] ?? message["text"]
            let text: String?
            if let blocks = content as? [[String: Any]] {
                text = Self.sanitizeAndRedact(blocks.compactMap { block -> String? in
                    guard block["thought"] as? Bool != true,
                          block["type"] == nil || block["type"] as? String == "text" else { return nil }
                    return block["text"] as? String
                }.joined(separator: " "))
            } else { text = (content as? String).flatMap { Self.sanitizeAndRedact($0) } }
            if let text { if role == "user" { user = text } else { assistant = text } }
            if role != "user" {
                for tool in message["toolCalls"] as? [[String: Any]] ?? message["tool_calls"] as? [[String: Any]] ?? [] { addTool(tool) }
                for part in content as? [[String: Any]] ?? [] {
                    if part["type"] as? String == "tool" { addTool(part) }
                    if let function = part["functionCall"] as? [String: Any] { addTool(function) }
                }
            }
            if let date = additionalMessageDate(record), updatedAt == nil || date > updatedAt! { updatedAt = date }
        }
        var recent = tools.reversed().map(\.summary)
        if let running { recent.insert(running, at: 0) }
        return SessionTurnPreview(sessionID: Self.sanitizeAndRedact(sessionID, maxLength: 96), lastUserPromptPreview: user,
                                  lastAssistantReplyPreview: assistant, recentTools: Array(recent.prefix(3)), updatedAt: updatedAt ?? modifiedAt)
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
