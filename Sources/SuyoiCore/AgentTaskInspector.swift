import Foundation
import Darwin

public struct AgentTaskContext: Equatable, Sendable {
    /// Session metadata linked by the inspector to the observed process.
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
        return SessionTurnPreviewInspector.sanitizeAndRedact(value, maxLength: limit)
    }
}

/// Local metadata only. No conversation, prompt or arbitrary command arguments are decoded.
public struct AgentTaskInspector: Sendable {
    private let homeDirectory: URL
    private let liveFile: @Sendable (ObservedProcess, URL) -> SessionFileEvidence?

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.init(homeDirectory: homeDirectory, liveFile: { SessionFileEvidence.live(for: $0, beneath: $1) })
    }

    init(homeDirectory: URL, liveFile: @escaping @Sendable (ObservedProcess, URL) -> SessionFileEvidence?) {
        self.homeDirectory = homeDirectory
        self.liveFile = liveFile
    }

    public func nativeSessionTargets(for agent: AgentObservation) -> [NativeSessionTarget] {
        NativeSessionCatalog(homeDirectory: homeDirectory).choices(for: agent)
    }

    public func inspect(agentName: String, process: ObservedProcess, projectRoot _: String?,
                        allProcesses: [ObservedProcess], now _: Date = Date()) -> AgentTaskContext {
        let tree = ProcessTree(processes: allProcesses)
        let tools: Set<String> = ["swift", "swift-frontend", "cargo", "git", "rg", "npm", "pnpm", "bun", "node", "python", "python3", "pytest", "go", "xcodebuild", "make"]
        let child = tree.descendants(of: process.pid).sorted().compactMap { tree.processesByPID[$0] }.first {
            $0.uid == process.uid && !$0.isStopped && (tools.contains($0.name) || $0.cpuPercent >= 0.5)
        }
        let running = child.flatMap { AgentContextValidation.label("Running: \($0.name)", limit: 120) }
        let base = homeDirectory.appendingPathComponent(".codex/sessions", isDirectory: true)
        guard agentName == "Codex", let cwd = process.cwd, cwd.hasPrefix("/"),
              cwd != "/", URL(fileURLWithPath: cwd).standardizedFileURL.path != homeDirectory.standardizedFileURL.path,
              let file = liveFile(process, base),
              SessionFileEvidence.filesystemPath(file.url).hasPrefix(SessionFileEvidence.filesystemPath(base) + "/") else {
            return AgentTaskContext(currentTask: running)
        }
        return codex(file: file, uid: process.uid, cwd: cwd, running: running)
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

    private func codex(file: SessionFileEvidence, uid: Int, cwd: String, running: String?) -> AgentTaskContext {
        let records = boundedRecords(file, uid: uid)
        let headers = records.filter { $0.type == "session_meta" }
        guard headers.count == 1, let meta = headers.first?.payload,
              let rawID = meta.id, let id = AgentContextValidation.sessionID(rawID),
              file.url.deletingPathExtension().lastPathComponent.hasSuffix("-" + id),
              let directory = meta.cwd, directory.hasPrefix("/"),
              URL(fileURLWithPath: directory).standardizedFileURL.path == URL(fileURLWithPath: cwd).standardizedFileURL.path else {
            return AgentTaskContext(currentTask: running)
        }
        let state = records.last { $0.type == "event_msg" && ["task_started", "task_complete", "turn_aborted"].contains($0.payload?.type ?? "") }?.payload?.type
        let task: String?
        switch state {
        case "task_started": task = running.map { "Active turn · \($0)" } ?? "Active turn in progress"
        case "task_complete": task = running.map { "Turn complete · \($0)" } ?? "Turn complete · waiting for prompt"
        case "turn_aborted": task = running.map { "Turn aborted · \($0)" } ?? "Turn aborted · waiting for prompt"
        default: task = running
        }
        return AgentTaskContext(sessionID: id, currentTask: task)
    }

    private func boundedRecords(_ file: SessionFileEvidence, uid: Int) -> [Record] {
        let fd = SessionFileEvidence.openRegular(file.url)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var info = stat()
        guard SessionFileEvidence.readIdentity(fd, uid: uid) == file.identity,
              fstat(fd, &info) == 0, info.st_size >= 0 else { return [] }
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
