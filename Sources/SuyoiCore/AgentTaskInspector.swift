import Foundation
import Darwin
import SQLite3

public struct AgentTaskContext: Equatable, Sendable {
    /// Session metadata selected for display. It carries no proof of live process ownership.
    public let sessionID: String?
    public let sessionTitle: String?
    public let currentTask: String?

    public init(sessionID: String? = nil, sessionTitle: String? = nil, currentTask: String? = nil) {
        self.sessionID = sessionID.flatMap { AgentContextValidation.sessionID($0) }
        self.sessionTitle = AgentContextValidation.label(sessionTitle, limit: 100)
        self.currentTask = AgentContextValidation.label(currentTask, limit: 120)
    }
}

enum AgentContextValidation {
    static func sessionID(_ value: String) -> String? {
        guard !value.isEmpty, value.utf8.count <= 96, !value.hasPrefix("-"),
              value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 }) else { return nil }
        return value
    }
    static func label(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let clean = String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : String(clean.prefix(limit))
    }
}

/// Local metadata only. No conversation, prompt or arbitrary command arguments are decoded.
public struct AgentTaskInspector: Sendable {
    private let homeDirectory: URL
    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) { self.homeDirectory = homeDirectory }

    public func inspect(agentName: String, process: ObservedProcess, projectRoot: String?, allProcesses: [ObservedProcess], now: Date = Date()) -> AgentTaskContext {
        let tree = ProcessTree(processes: allProcesses)
        let tools: Set<String> = ["swift", "swift-frontend", "cargo", "git", "rg", "npm", "pnpm", "bun", "node", "python", "python3", "pytest", "go", "xcodebuild", "make"]
        let child = tree.descendants(of: process.pid).compactMap { tree.processesByPID[$0] }.first {
            !$0.isStopped && (tools.contains($0.name) || $0.cpuPercent >= 0.5)
        }
        let running = child.flatMap { AgentContextValidation.label("Running: \($0.name)", limit: 120) }
        let homePath = homeDirectory.standardizedFileURL.path
        let specificDir: String? = (projectRoot ?? process.cwd).flatMap { raw in
            let p = URL(fileURLWithPath: raw).standardizedFileURL.path
            return (p == "/" || p == homePath) ? nil : p
        }
        if let target = specificDir {
            // Project metadata cannot disambiguate two live agents of the same kind in one project.
            let peers = allProcesses.filter {
                $0.pid != process.pid && $0.uid == process.uid && AgentRecognizer.agentName(for: $0) == agentName &&
                $0.cwd.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == target
            }
            guard peers.isEmpty else { return AgentTaskContext(currentTask: running) }
        }
        let context: AgentTaskContext
        switch agentName {
        case "OpenCode": context = openCode(directory: specificDir, running: running)
        case "Codex": context = codex(directory: specificDir, running: running)
        default: context = AgentTaskContext(currentTask: running)
        }
        // Keep generic-directory labels visible while omitting the ambiguous
        // identifier when another live process of this provider could own it.
        let hasProviderPeer = allProcesses.contains {
            $0.pid != process.pid && $0.uid == process.uid && !$0.isStopped &&
            AgentRecognizer.agentName(for: $0) == agentName
        }
        guard specificDir == nil, hasProviderPeer else { return context }
        return AgentTaskContext(sessionTitle: context.sessionTitle, currentTask: context.currentTask)
    }

    private func openCode(directory: String?, running: String?) -> AgentTaskContext {
        let url = homeDirectory.appendingPathComponent(".local/share/opencode/opencode.db")
        guard QuotaParsing.safePath(url), (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return AgentTaskContext(currentTask: running) }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close(handle) }
            return AgentTaskContext(currentTask: running)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 256 * 1024)
        func columns(_ statement: OpaquePointer) -> [String?] {
            (0..<sqlite3_column_count(statement)).map { index in
                guard let bytes = sqlite3_column_text(statement, index) else { return nil }
                return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, index))), as: UTF8.self)
            }
        }
        func row(_ sql: String, parameter: String) -> [String?]? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
            defer { sqlite3_finalize(statement) }
            let bound = parameter.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            guard bound == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return columns(statement)
        }
        func rowNoParam(_ sql: String) -> [String?]? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return columns(statement)
        }
        let session = directory.map {
            row("SELECT id, title FROM session_v2 WHERE directory = ? ORDER BY time_updated DESC LIMIT 1", parameter: $0)
        } ?? rowNoParam("SELECT id, title, directory, idle_outcome FROM session_v2 ORDER BY time_updated DESC LIMIT 1")
        guard let session,
              let rawID = session[0], let id = AgentContextValidation.sessionID(rawID) else { return AgentTaskContext(currentTask: running) }
        var title = session[1]
        if directory == nil, let dir = session[2], !dir.isEmpty, let text = title, !text.isEmpty {
            title = "\(URL(fileURLWithPath: dir).lastPathComponent) · \(text)"
        }
        let todo = row("SELECT status, content FROM todo WHERE session_id = ? ORDER BY CASE WHEN status = 'in_progress' THEN 0 WHEN status = 'pending' THEN 1 ELSE 2 END, position ASC, time_updated DESC LIMIT 1", parameter: id)
        var task: String?
        if let todo, let content = AgentContextValidation.label(todo[1], limit: 120) {
            if todo[0] == "in_progress" { task = "Todo: \(content)" }
            else if todo[0] == "pending" { task = "Next: \(content)" }
        }
        if directory == nil, task == nil, running == nil, let outcome = session[3], !outcome.isEmpty {
            task = "Last turn: \(outcome)"
        }
        return AgentTaskContext(sessionID: id, sessionTitle: title, currentTask: [running, task].compactMap { $0 }.joinedNonempty())
    }

    // Decode only approved metadata and event discriminators, never message/prompt bodies.
    private struct Record: Decodable {
        let type: String
        let payload: Payload?
        struct Payload: Decodable {
            let id: String?
            let cwd: String?
            let type: String?
        }
        private enum CodingKeys: String, CodingKey { case type, payload }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decode(String.self, forKey: .type)
            payload = ["session_meta", "event_msg"].contains(type) ? try c.decodeIfPresent(Payload.self, forKey: .payload) : nil
        }
    }

    private func codex(directory: String?, running: String?) -> AgentTaskContext {
        let files = recentCodexFiles()
        for (file, _) in directory == nil ? Array(files.prefix(1)) : files {
            let records = boundedRecords(file)
            guard let meta = records.first(where: { $0.type == "session_meta" })?.payload,
                  let rawID = meta.id, let id = AgentContextValidation.sessionID(rawID) else { continue }
            if let directory {
                guard let cwd = meta.cwd, cwd.hasPrefix("/"), URL(fileURLWithPath: cwd).standardizedFileURL.path == directory else { continue }
            }
            let state = records.last { $0.type == "event_msg" && ["task_started", "task_complete", "turn_aborted"].contains($0.payload?.type ?? "") }?.payload?.type
            let task: String?
            switch state {
            case "task_started": task = running.map { "Active turn · \($0)" } ?? "Active turn in progress"
            case "task_complete": task = running.map { "Turn complete · \($0)" } ?? "Turn complete · waiting for prompt"
            case "turn_aborted": task = running.map { "Turn aborted · \($0)" } ?? "Turn aborted · waiting for prompt"
            default: task = running
            }
            let title = directory == nil ? meta.cwd.map { "\(URL(fileURLWithPath: $0).lastPathComponent) session" } : nil
            return AgentTaskContext(sessionID: id, sessionTitle: title, currentTask: task)
        }
        return AgentTaskContext(currentTask: running)
    }

    private func recentCodexFiles() -> [(URL, Date)] {
        var found: [(URL, Date)] = []
        var budget = 10_000
        let deadline = Date().addingTimeInterval(1)
        func visit(_ directory: URL, level: Int) {
            guard budget > 0, Date() < deadline, QuotaParsing.safePath(directory),
                  let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey], options: [.skipsSubdirectoryDescendants]) else { return }
            while budget > 0, Date() < deadline, let url = entries.nextObject() as? URL {
                budget -= 1
                guard QuotaParsing.safePath(url), let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey]) else { continue }
                if level < 3, v.isDirectory == true {
                    let name = url.lastPathComponent
                    guard name.count == (level == 0 ? 4 : 2), name.utf8.allSatisfy({ (48...57).contains($0) }),
                          let n = Int(name), level == 0 || (1...(level == 1 ? 12 : 31)).contains(n) else { continue }
                    visit(url, level: level + 1)
                } else if level == 3, v.isRegularFile == true, url.pathExtension == "jsonl" {
                    found.append((url, v.contentModificationDate ?? .distantPast))
                }
            }
        }
        visit(homeDirectory.appendingPathComponent(".codex/sessions"), level: 0)
        return Array(found.sorted { $0.1 == $1.1 ? $0.0.path < $1.0.path : $0.1 > $1.1 }.prefix(12))
    }

    private func boundedRecords(_ url: URL) -> [Record] {
        guard QuotaParsing.safePath(url) else { return [] }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return [] }
        func readChunk(_ count: Int) -> Data {
            var data = Data(count: count)
            let n = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, count) }
            data.count = max(0, n)
            return data
        }
        let limit = 256 * 1024
        var chunks: [Data] = []
        if info.st_size <= limit { chunks = [readChunk(Int(info.st_size))] }
        else {
            var head = readChunk(64 * 1024)
            if let end = head.lastIndex(of: 10) { head = head.prefix(through: end) } else { head = Data() }
            guard lseek(fd, info.st_size - off_t(192 * 1024), SEEK_SET) >= 0 else { return [] }
            var tail = readChunk(192 * 1024)
            if let start = tail.firstIndex(of: 10) { tail.removeSubrange(...start) } else { tail = Data() }
            chunks = [head, tail]
        }
        let decoder = JSONDecoder()
        return chunks.flatMap { $0.split(separator: 10).compactMap { try? decoder.decode(Record.self, from: Data($0)) } }
    }
}

private extension Array where Element == String {
    func joinedNonempty() -> String? { isEmpty ? nil : joined(separator: " · ") }
}
