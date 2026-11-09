import CryptoKit
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
        let selfDescendants = tree.descendants(of: process.pid)
        func isSameProcessLineage(_ other: ObservedProcess) -> Bool {
            if selfDescendants.contains(other.pid) || tree.descendants(of: other.pid).contains(process.pid) {
                return true
            }
            if process.parentPID > 1 && other.parentPID == process.parentPID {
                return true
            }
            if process.cwd != "/" && other.cwd == "/" {
                return true
            }
            return false
        }
        if let target = specificDir {
            // Project metadata cannot disambiguate two live agents of the same kind in one project.
            let peers = allProcesses.filter {
                $0.pid != process.pid && $0.uid == process.uid && !isSameProcessLineage($0) &&
                AgentRecognizer.agentName(for: $0) == agentName &&
                $0.cwd.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == target
            }
            guard peers.isEmpty else { return AgentTaskContext(currentTask: running) }
        }
        let hasProviderPeer = allProcesses.contains {
            $0.pid != process.pid && $0.uid == process.uid && !$0.isStopped &&
            !isSameProcessLineage($0) &&
            AgentRecognizer.agentName(for: $0) == agentName
        }
        let context: AgentTaskContext
        switch agentName {
        case "OpenCode": context = openCode(directory: specificDir, running: running)
        case "Codex": context = codex(directory: specificDir, running: running)
        case "Gemini CLI": context = gemini(directory: specificDir, hasProviderPeer: hasProviderPeer, running: running)
        default: context = AgentTaskContext(currentTask: running)
        }
        // Keep generic-directory labels visible while omitting the ambiguous
        // identifier when another live process of this provider could own it.
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

    private struct GeminiHeader: Decodable {
        let sessionId: String?
        let session_id: String?
        let sessionID: String?
        let cwd: String?
        let projectRoot: String?
    }

    private func gemini(directory: String?, hasProviderPeer: Bool, running: String?) -> AgentTaskContext {
        let expectedBucket = directory.map { dir in
            SHA256.hash(data: Data(dir.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        for (file, bucketName) in recentGeminiFiles() {
            guard let id = extractGeminiSessionID(from: file, directory: directory, bucketName: bucketName, expectedBucket: expectedBucket, hasProviderPeer: hasProviderPeer) else {
                continue
            }
            return AgentTaskContext(sessionID: id, sessionTitle: nil, currentTask: running)
        }
        return AgentTaskContext(currentTask: running)
    }

    private func recentGeminiFiles() -> [(URL, String?)] {
        var found: [(URL, String?, Date)] = []
        var budget = 4_096
        let deadline = Date().addingTimeInterval(1)
        let tmpRoot = homeDirectory.appendingPathComponent(".gemini/tmp")
        if QuotaParsing.safePath(tmpRoot),
           let buckets = FileManager.default.enumerator(
               at: tmpRoot,
               includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
               options: [.skipsSubdirectoryDescendants]
           ) {
            while budget > 0, Date() < deadline, let bucketURL = buckets.nextObject() as? URL {
                budget -= 1
                guard QuotaParsing.safePath(bucketURL),
                      let bVal = try? bucketURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      bVal.isDirectory == true, bVal.isSymbolicLink != true else { continue }
                let chatsDir = bucketURL.appendingPathComponent("chats")
                guard QuotaParsing.safePath(chatsDir),
                      let files = FileManager.default.enumerator(
                          at: chatsDir,
                          includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey],
                          options: [.skipsSubdirectoryDescendants]
                      ) else { continue }
                while budget > 0, Date() < deadline, let fileURL = files.nextObject() as? URL {
                    budget -= 1
                    guard QuotaParsing.safePath(fileURL),
                          let fVal = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                          fVal.isRegularFile == true, fVal.isSymbolicLink != true,
                          ["json", "jsonl"].contains(fileURL.pathExtension) else { continue }
                    found.append((fileURL, bucketURL.lastPathComponent, fVal.contentModificationDate ?? .distantPast))
                }
            }
        }
        let sessionsRoot = homeDirectory.appendingPathComponent(".gemini/sessions")
        if QuotaParsing.safePath(sessionsRoot),
           let files = FileManager.default.enumerator(
               at: sessionsRoot,
               includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey],
               options: [.skipsSubdirectoryDescendants]
           ) {
            while budget > 0, Date() < deadline, let fileURL = files.nextObject() as? URL {
                budget -= 1
                guard QuotaParsing.safePath(fileURL),
                      let fVal = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                      fVal.isRegularFile == true, fVal.isSymbolicLink != true,
                      ["json", "jsonl"].contains(fileURL.pathExtension) else { continue }
                found.append((fileURL, nil, fVal.contentModificationDate ?? .distantPast))
            }
        }
        return found
            .sorted { $0.2 == $1.2 ? $0.0.path < $1.0.path : $0.2 > $1.2 }
            .prefix(12)
            .map { ($0.0, $0.1) }
    }

    private func extractGeminiSessionID(
        from url: URL,
        directory: String?,
        bucketName: String?,
        expectedBucket: String?,
        hasProviderPeer: Bool
    ) -> String? {
        guard QuotaParsing.safePath(url) else { return nil }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size <= 256 * 1024 else {
            return nil
        }
        let readCount = min(Int(info.st_size), 64 * 1024)
        var data = Data(count: readCount)
        let n = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, readCount) }
        guard n > 0 else { return nil }
        data.count = n

        let decoder = JSONDecoder()
        let header: GeminiHeader?
        if url.pathExtension == "json" {
            header = try? decoder.decode(GeminiHeader.self, from: data)
        } else {
            let firstLine = data.split(separator: 10, maxSplits: 1).first.map { Data($0) } ?? data
            header = try? decoder.decode(GeminiHeader.self, from: firstLine)
        }

        if let directory {
            if let metaDir = header?.cwd ?? header?.projectRoot, metaDir.hasPrefix("/") {
                guard URL(fileURLWithPath: metaDir).standardizedFileURL.path == directory else { return nil }
            } else if hasProviderPeer {
                guard let bucketName, let expectedBucket, bucketName == expectedBucket else { return nil }
            }
        }

        if let rawID = header?.sessionId ?? header?.session_id ?? header?.sessionID,
           let valid = AgentContextValidation.sessionID(rawID) {
            return valid
        }
        let stem = url.deletingPathExtension().lastPathComponent
        if stem.hasPrefix("session-"), let valid = AgentContextValidation.sessionID(String(stem.dropFirst(8))) {
            return valid
        }
        return AgentContextValidation.sessionID(stem)
    }
}

private extension Array where Element == String {
    func joinedNonempty() -> String? { isEmpty ? nil : joined(separator: " · ") }
}
