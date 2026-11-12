import Darwin
import Foundation
import SQLite3

/// A specific local provider session offered for explicit selection.
public struct NativeSessionTarget: Equatable, Identifiable, Sendable {
    public var id: String { sessionID }
    public let sessionID: String
    public let mode: AgentSteerMode
    public let projectPath: String
    public let title: String?
    public let updatedAt: Date?
    public let isLikelyActiveInProcess: Bool
    let source: URL
    let fileIdentity: FileIdentity
    let projectIdentity: FileIdentity
    let rowIdentity: ProcessIdentity
    let table: String?

    init(
        sessionID: String,
        mode: AgentSteerMode,
        projectPath: String,
        title: String?,
        updatedAt: Date?,
        source: URL,
        fileIdentity: FileIdentity,
        projectIdentity: FileIdentity,
        rowIdentity: ProcessIdentity,
        table: String?,
        isLikelyActiveInProcess: Bool = false
    ) {
        self.sessionID = sessionID
        self.mode = mode
        self.projectPath = projectPath
        self.title = title
        self.updatedAt = updatedAt
        self.source = source
        self.fileIdentity = fileIdentity
        self.projectIdentity = projectIdentity
        self.rowIdentity = rowIdentity
        self.table = table
        self.isLikelyActiveInProcess = isLikelyActiveInProcess
    }

    public static func == (lhs: NativeSessionTarget, rhs: NativeSessionTarget) -> Bool {
        lhs.sessionID == rhs.sessionID
            && lhs.mode == rhs.mode
            && lhs.projectPath == rhs.projectPath
            && lhs.title == rhs.title
            && lhs.updatedAt == rhs.updatedAt
            && lhs.source == rhs.source
            && lhs.fileIdentity == rhs.fileIdentity
            && lhs.projectIdentity == rhs.projectIdentity
            && lhs.rowIdentity == rhs.rowIdentity
            && lhs.table == rhs.table
    }
}

#if DEBUG
public extension NativeSessionTarget {
    static func dashboardFixture(sessionID: String, projectPath: String, title: String,
                                 updatedAt: Date, rowIdentity: ProcessIdentity) -> NativeSessionTarget {
        let unverified = FileIdentity(device: -1, inode: 0)
        return NativeSessionTarget(sessionID: sessionID, mode: .codexResume, projectPath: projectPath,
            title: title, updatedAt: updatedAt, source: URL(fileURLWithPath: "/fixture/unavailable"),
            fileIdentity: unverified, projectIdentity: unverified, rowIdentity: rowIdentity, table: nil)
    }
}
#endif

struct SessionFileEvidence: Equatable, Sendable {
    let url: URL
    let identity: FileIdentity

    init(url: URL, identity: FileIdentity) {
        self.url = url
        self.identity = identity
    }

    static func filesystemPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return ["/var/", "/tmp/", "/etc/"].contains(where: { path.hasPrefix($0) }) ? "/private" + path : path
    }

    static func openRegular(_ url: URL) -> Int32 {
        open(filesystemPath(url), O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY)
    }

    static func readIdentity(_ descriptor: Int32, uid: Int) -> FileIdentity? {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Int(info.st_uid) == uid,
              info.st_nlink == 1 else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }

    /// Exact writable descriptor evidence is intentionally limited to the selected PID.
    static func live(for process: ObservedProcess, beneath root: URL) -> SessionFileEvidence? {
        let identity = process.identity
        guard identity.isActionEligible, identity.uid == Int(getuid()), let pid = Int32(exactly: identity.pid),
              let live = DarwinProcessReader().process(pid: pid, uid: identity.uid), live.identity == identity,
              live.cwd == process.cwd, !live.isStopped else { return nil }
        let capacity = 512
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let bytes = fds.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        let stride = MemoryLayout<proc_fdinfo>.stride
        guard bytes > 0, Int(bytes) % stride == 0, Int(bytes) < capacity * stride else { return nil }
        let prefix = filesystemPath(root) + "/"
        let deadline = ProcessInfo.processInfo.systemUptime + 0.05
        var match: SessionFileEvidence?
        for descriptor in fds.prefix(Int(bytes) / stride) where descriptor.proc_fdtype == PROX_FDTYPE_VNODE {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            var details = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &details, size) == size else { return nil }
            guard details.pfi.fi_openflags & UInt32(FWRITE) != 0 else { continue }
            let path = withUnsafeBytes(of: &details.pvip.vip_path) { bytes in
                String(bytes: bytes.prefix(while: { $0 != 0 }), encoding: .utf8)
            }
            guard let path, path.hasSuffix(".jsonl") else { continue }
            let url = URL(fileURLWithPath: path)
            guard filesystemPath(url).hasPrefix(prefix) else { continue }
            let info = details.pvip.vip_vi.vi_stat
            guard Int(info.vst_uid) == identity.uid, info.vst_mode & S_IFMT == S_IFREG else { return nil }
            let file = SessionFileEvidence(url: url,
                identity: FileIdentity(device: Int32(bitPattern: info.vst_dev), inode: info.vst_ino))
            if let match, match != file { return nil }
            match = file
        }
        guard let current = DarwinProcessReader().process(pid: pid, uid: identity.uid),
              current.identity == identity, current.cwd == process.cwd, !current.isStopped else { return nil }
        return match
    }
}

struct NativeSessionCatalog: Sendable {
    let homeDirectory: URL

    init(homeDirectory: URL) {
        self.homeDirectory = URL(fileURLWithPath: SessionFileEvidence.filesystemPath(homeDirectory), isDirectory: true)
    }

    var codexHome: URL { homeDirectory.appendingPathComponent(".codex", isDirectory: true) }
    var codexRoot: URL { codexHome.appendingPathComponent("sessions", isDirectory: true) }
    var openCodeDB: URL { homeDirectory.appendingPathComponent(".local/share/opencode/opencode.db") }
    var claudeHome: URL { homeDirectory.appendingPathComponent(".claude", isDirectory: true) }
    var claudeProjectsRoot: URL { claudeHome.appendingPathComponent("projects", isDirectory: true) }

    func choices(for agent: AgentObservation) -> [NativeSessionTarget] {
        guard let mode = AgentSteerer.nativeMode(for: agent) else { return [] }
        let project = rowProject(agent)
        switch mode {
        case .codexResume:
            let liveEvidence = SessionFileEvidence.live(for: agent.process, beneath: codexRoot)
            var entries: [NativeSessionTarget] = []
            for (url, date) in codexFiles() {
                guard let metadata = codexMetadata(url, uid: agent.process.uid),
                      let projectIdentity = directoryIdentity(metadata.project),
                      project.map({ metadata.project == $0 || metadata.project.hasPrefix($0 + "/") }) ?? true else { continue }
                let isLive = liveEvidence.map {
                    SessionFileEvidence.filesystemPath($0.url) == SessionFileEvidence.filesystemPath(url)
                        && $0.identity == metadata.identity
                } ?? false
                entries.append(NativeSessionTarget(sessionID: metadata.id, mode: mode, projectPath: metadata.project,
                    title: nil, updatedAt: date, source: url, fileIdentity: metadata.identity,
                    projectIdentity: projectIdentity, rowIdentity: agent.process.identity, table: nil,
                    isLikelyActiveInProcess: isLive))
            }
            let groups = Dictionary(grouping: entries, by: \.sessionID)
            return Array(entries.lazy.filter { groups[$0.sessionID]?.count == 1 }.prefix(24))
        case .openCodeSession:
            return openCodeTargets(for: agent, project: project)
        case .claudeResume:
            let liveEvidence = SessionFileEvidence.live(for: agent.process, beneath: claudeProjectsRoot)
            var entries: [NativeSessionTarget] = []
            for (url, date) in claudeFiles() {
                guard let metadata = claudeMetadata(url, uid: agent.process.uid),
                      let projectIdentity = directoryIdentity(metadata.project),
                      project.map({ metadata.project == $0 || metadata.project.hasPrefix($0 + "/") }) ?? true else { continue }
                let isLive = liveEvidence.map {
                    SessionFileEvidence.filesystemPath($0.url) == SessionFileEvidence.filesystemPath(url)
                        && $0.identity == metadata.identity
                } ?? false
                entries.append(NativeSessionTarget(sessionID: metadata.id, mode: mode, projectPath: metadata.project,
                    title: metadata.title, updatedAt: date, source: url, fileIdentity: metadata.identity,
                    projectIdentity: projectIdentity, rowIdentity: agent.process.identity, table: nil,
                    isLikelyActiveInProcess: isLive))
            }
            let groups = Dictionary(grouping: entries, by: \.sessionID)
            return Array(entries.lazy.filter { groups[$0.sessionID]?.count == 1 }.prefix(24))
        case .terminalTTY, .tmuxPane, .weztermPane, .kittyWindow, .geminiResume:
            return []
        }
    }

    func verifiedCodexTarget(for agent: AgentObservation) -> NativeSessionTarget? {
        guard AgentSteerer.nativeMode(for: agent) == .codexResume,
              let cwd = canonicalProject(agent.process.cwd),
              let evidence = SessionFileEvidence.live(for: agent.process, beneath: codexRoot),
              let metadata = codexMetadata(evidence.url, uid: agent.process.uid),
              metadata.project == cwd, metadata.identity == evidence.identity,
              let projectIdentity = directoryIdentity(cwd) else { return nil }
        return NativeSessionTarget(sessionID: metadata.id, mode: .codexResume, projectPath: metadata.project,
            title: nil, updatedAt: nil, source: evidence.url, fileIdentity: metadata.identity,
            projectIdentity: projectIdentity, rowIdentity: agent.process.identity, table: nil,
            isLikelyActiveInProcess: true)
    }

    func validate(_ target: NativeSessionTarget, for agent: AgentObservation, live: ObservedProcess) -> Bool {
        guard target.rowIdentity == live.identity, live.identity == agent.process.identity,
              AgentSteerer.nativeMode(for: agent) == target.mode, AgentRecognizer.agentName(for: live) == agent.agentName,
              normalizedDirectory(live.cwd) == normalizedDirectory(agent.process.cwd),
              projectIsCurrent(target) else { return false }
        if let project = rowProject(agent),
           target.projectPath != project && !target.projectPath.hasPrefix(project + "/") { return false }
        switch target.mode {
        case .codexResume:
            guard SessionFileEvidence.filesystemPath(target.source).hasPrefix(codexRoot.path + "/"),
                  let metadata = codexMetadata(target.source, uid: live.uid) else { return false }
            guard metadata.id == target.sessionID, metadata.project == target.projectPath,
                  metadata.identity == target.fileIdentity else { return false }
            guard let matches = exactCodexRollouts(sessionID: target.sessionID), matches.count == 1,
                  SessionFileEvidence.filesystemPath(matches[0]) == SessionFileEvidence.filesystemPath(target.source) else {
                return false
            }
            return codexIndexAgrees(with: target, uid: live.uid)
        case .openCodeSession:
            return openCodeTargets(for: agent, project: target.projectPath, id: target.sessionID).contains {
                $0.sessionID == target.sessionID && $0.source == target.source && $0.fileIdentity == target.fileIdentity
                    && $0.projectPath == target.projectPath && $0.table == target.table
            }
        case .claudeResume:
            guard SessionFileEvidence.filesystemPath(target.source).hasPrefix(claudeProjectsRoot.path + "/"),
                  let metadata = claudeMetadata(target.source, uid: live.uid),
                  metadata.id == target.sessionID,
                  metadata.project == target.projectPath,
                  metadata.identity == target.fileIdentity,
                  let matches = exactClaudeSessions(sessionID: target.sessionID),
                  matches.count == 1,
                  SessionFileEvidence.filesystemPath(matches[0]) == SessionFileEvidence.filesystemPath(target.source) else {
                return false
            }
            return true
        case .terminalTTY, .tmuxPane, .weztermPane, .kittyWindow, .geminiResume:
            return false
        }
    }

    func projectIsCurrent(_ target: NativeSessionTarget) -> Bool {
        canonicalProject(target.projectPath) == target.projectPath
            && directoryIdentity(target.projectPath) == target.projectIdentity
    }

    private func directoryIdentity(_ path: String) -> FileIdentity? {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let fd = open(SessionFileEvidence.filesystemPath(url), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }

    private func rowProject(_ agent: AgentObservation) -> String? {
        canonicalProject(agent.project?.rootPath ?? agent.process.cwd)
    }

    private func canonicalProject(_ raw: String?) -> String? {
        guard let path = normalizedDirectory(raw), path != "/", path != homeDirectory.resolvingSymlinksInPath().standardizedFileURL.path else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return path
    }

    private func normalizedDirectory(_ raw: String?) -> String? {
        guard let raw, raw.hasPrefix("/"), raw.utf8.count <= 4_096,
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format }) else { return nil }
        return URL(fileURLWithPath: raw).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private struct CodexRecord: Decodable {
        struct Payload: Decodable { let id: String; let cwd: String }
        let type: String
        let payload: Payload
    }

    private func codexMetadata(_ url: URL, uid: Int) -> (id: String, project: String, identity: FileIdentity)? {
        let fd = SessionFileEvidence.openRegular(url)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard let identity = SessionFileEvidence.readIdentity(fd, uid: uid) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 8 * 1_024)
        let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard count > 0, let end = bytes.prefix(count).firstIndex(of: 10),
              let record = try? JSONDecoder().decode(CodexRecord.self, from: Data(bytes[..<end])),
              record.type == "session_meta", let id = UUID(uuidString: record.payload.id),
              Self.rolloutSessionID(url) == id,
              let project = canonicalProject(record.payload.cwd) else { return nil }
        return (id.uuidString.lowercased(), project, identity)
    }

    private static func rolloutSessionID(_ url: URL) -> UUID? {
        let name = url.lastPathComponent
        guard name.hasPrefix("rollout-") else { return nil }
        let extensionLength = name.hasSuffix(".jsonl") ? 6 : (name.hasSuffix(".jsonl.zst") ? 10 : 0)
        guard extensionLength > 0 else { return nil }
        let pieces = name.dropLast(extensionLength).split(separator: "_", omittingEmptySubsequences: false)
        guard (1...2).contains(pieces.count), let original = pieces.first, original.count > 36,
              original.dropLast(36).hasSuffix("-") else { return nil }
        if pieces.count == 2, UUID(uuidString: String(pieces[1])) == nil { return nil }
        return UUID(uuidString: String(original.suffix(36)))
    }

    private func codexFiles() -> [(URL, Date)] {
        var entries: [(URL, Date)] = []
        var remaining = 8_192
        let deadline = ProcessInfo.processInfo.systemUptime + 0.75
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        func visit(_ directory: URL, depth: Int) {
            guard remaining > 0, ProcessInfo.processInfo.systemUptime < deadline, QuotaParsing.safePath(directory),
                  let children = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys),
                    options: [.skipsSubdirectoryDescendants]) else { return }
            while remaining > 0, ProcessInfo.processInfo.systemUptime < deadline, let file = children.nextObject() as? URL {
                remaining -= 1
                guard let values = try? file.resourceValues(forKeys: keys), values.isSymbolicLink != true else { continue }
                if depth == 3 {
                    if values.isRegularFile == true, file.pathExtension == "jsonl", Self.rolloutSessionID(file) != nil {
                        entries.append((file, values.contentModificationDate ?? .distantPast))
                    }
                } else if values.isDirectory == true {
                    let name = file.lastPathComponent
                    if name.utf8.count == (depth == 0 ? 4 : 2), name.utf8.allSatisfy({ (48...57).contains($0) }) {
                        visit(file, depth: depth + 1)
                    }
                }
            }
        }
        visit(codexRoot, depth: 0)
        return Array(entries.sorted { $0.1 == $1.1 ? $0.0.path < $1.0.path : $0.1 > $1.1 }.prefix(128))
    }

    private func exactCodexRollouts(sessionID: String) -> [URL]? {
        guard let id = UUID(uuidString: sessionID) else { return nil }
        var remaining = 8_192
        let deadline = ProcessInfo.processInfo.systemUptime + 0.75
        let archived = codexHome.appendingPathComponent("archived_sessions", isDirectory: true)
        var matches: [URL] = []
        for root in [codexRoot, archived] {
            var info = stat()
            if root == archived, lstat(SessionFileEvidence.filesystemPath(root), &info) != 0, errno == ENOENT { continue }
            var complete = true
            let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey]
            guard QuotaParsing.safePath(root), let files = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: Array(keys), errorHandler: { _, _ in complete = false; return false }) else { return nil }
            while let url = files.nextObject() as? URL {
                guard remaining > 0, ProcessInfo.processInfo.systemUptime < deadline, files.level <= 16,
                      let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else { return nil }
                remaining -= 1
                if values.isRegularFile == true, Self.rolloutSessionID(url) == id {
                    matches.append(url)
                    if matches.count > 1 { return matches }
                }
            }
            guard complete else { return nil }
        }
        return matches
    }

    private func codexIndexAgrees(with target: NativeSessionTarget, uid: Int) -> Bool {
        var complete = true
        guard let files = FileManager.default.enumerator(at: codexHome, includingPropertiesForKeys: [],
            options: [.skipsSubdirectoryDescendants], errorHandler: { _, _ in complete = false; return false }) else { return false }
        var budget = 256
        var databases = 0
        while let url = files.nextObject() as? URL {
            guard budget > 0 else { return false }
            budget -= 1
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "sqlite", name.hasPrefix("state_"), name.count > 6,
                  name.dropFirst(6).utf8.allSatisfy({ (48...57).contains($0) }) else { continue }
            databases += 1
            guard databases <= 8 else { return false }
            let agrees = withReadOnlyDatabase(url, uid: uid) { db, _ -> Bool? in
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, "SELECT rollout_path FROM threads WHERE id = ? LIMIT 2", -1, &statement, nil) == SQLITE_OK,
                      let statement else { return nil }
                defer { sqlite3_finalize(statement) }
                guard Self.bind(target.sessionID, to: statement) else { return nil }
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return true }
                guard status == SQLITE_ROW, let path = Self.text(statement, column: 0), path.hasPrefix("/") else { return nil }
                return SessionFileEvidence.filesystemPath(URL(fileURLWithPath: path)) == SessionFileEvidence.filesystemPath(target.source)
                    && sqlite3_step(statement) == SQLITE_DONE
            }
            guard agrees == true else { return false }
        }
        return complete
    }

    private func withReadOnlyDatabase<T>(_ url: URL, uid: Int, read: (OpaquePointer, FileIdentity) -> T?) -> T? {
        let descriptor = SessionFileEvidence.openRegular(url)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        guard let identity = SessionFileEvidence.readIdentity(descriptor, uid: uid) else { return nil }
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(SessionFileEvidence.filesystemPath(url), &handle,
                                    SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
        defer { if let handle { sqlite3_close(handle) } }
        guard result == SQLITE_OK, let db = handle else { return nil }
        sqlite3_busy_timeout(db, 50)
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 256 * 1_024)
        var deadline = DispatchTime.now().uptimeNanoseconds + 250_000_000
        let output = withUnsafeMutablePointer(to: &deadline) { deadlinePointer in
            sqlite3_progress_handler(db, 1_000, { pointer in
                guard let pointer else { return 1 }
                return DispatchTime.now().uptimeNanoseconds >= pointer.assumingMemoryBound(to: UInt64.self).pointee ? 1 : 0
            }, deadlinePointer)
            defer { sqlite3_progress_handler(db, 0, nil, nil) }
            return read(db, identity)
        }
        let current = SessionFileEvidence.openRegular(url)
        guard current >= 0 else { return nil }
        defer { close(current) }
        return SessionFileEvidence.readIdentity(current, uid: uid) == identity ? output : nil
    }

    private static func bind(_ value: String, to statement: OpaquePointer) -> Bool {
        value.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) } == SQLITE_OK
    }

    private static func text(_ statement: OpaquePointer, column: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, column),
              (1...4_096).contains(sqlite3_column_bytes(statement, column)) else { return nil }
        return String(bytes: UnsafeBufferPointer(start: value, count: Int(sqlite3_column_bytes(statement, column))), encoding: .utf8)
    }

    private func openCodeTargets(for agent: AgentObservation, project: String?, id: String? = nil) -> [NativeSessionTarget] {
        let url = openCodeDB
        return withReadOnlyDatabase(url, uid: agent.process.uid) { db, fileIdentity -> [NativeSessionTarget]? in
            guard let tables = Self.openCodeTables(db) else { return nil }
            let table = tables.contains("session_v2") ? "session_v2" : "session"
            guard tables.contains(table) else { return [] }
            var query = "SELECT id, title, directory, time_updated FROM \(table)"
            if id != nil { query += " WHERE id = ? LIMIT 2" }
            else if project != nil { query += " WHERE directory = ? ORDER BY time_updated DESC LIMIT 24" }
            else { query += " ORDER BY time_updated DESC LIMIT 48" }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
            defer { sqlite3_finalize(statement) }
            if let parameter = id ?? project, !Self.bind(parameter, to: statement) { return nil }
            var entries: [NativeSessionTarget] = []
            var rows = 0
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                rows += 1
                if let sessionID = Self.text(statement, column: 0).flatMap(AgentContextValidation.sessionID), sessionID.hasPrefix("ses_"),
                   let directory = canonicalProject(Self.text(statement, column: 2)), project == nil || project == directory,
                   let projectIdentity = directoryIdentity(directory) {
                    let ms = sqlite3_column_int64(statement, 3)
                    entries.append(NativeSessionTarget(sessionID: sessionID, mode: .openCodeSession,
                        projectPath: directory, title: Self.text(statement, column: 1).flatMap { SessionTurnPreviewInspector.sanitizeAndRedact($0, maxLength: 100) },
                        updatedAt: ms > 0 ? Date(timeIntervalSince1970: Double(ms) / 1_000) : nil,
                        source: url, fileIdentity: fileIdentity, projectIdentity: projectIdentity,
                        rowIdentity: agent.process.identity, table: table))
                }
                status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else { return nil }
            if let id {
                guard rows == 1, let entry = entries.first else { return [] }
                if table == "session_v2", tables.contains("session"),
                   !openCodeLegacyRowAgrees(db, sessionID: id, project: entry.projectPath) { return [] }
                return [entry]
            }
            let groups = Dictionary(grouping: entries, by: \.sessionID)
            return Array(entries.lazy.filter { groups[$0.sessionID]?.count == 1 }.prefix(24))
        } ?? []
    }

    private static func openCodeTables(_ db: OpaquePointer) -> Set<String>? {
        var statement: OpaquePointer?
        let query = "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('session_v2', 'session')"
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        var tables: Set<String> = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            guard let name = text(statement, column: 0) else { return nil }
            tables.insert(name)
            status = sqlite3_step(statement)
        }
        return status == SQLITE_DONE ? tables : nil
    }

    /// Migration can leave the old row in place. It must agree if a legacy CLI can still see it.
    private func openCodeLegacyRowAgrees(_ db: OpaquePointer, sessionID: String, project: String) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT directory FROM session WHERE id = ? LIMIT 2", -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }
        guard Self.bind(sessionID, to: statement) else { return false }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return true }
        return status == SQLITE_ROW && canonicalProject(Self.text(statement, column: 0)) == project
            && sqlite3_step(statement) == SQLITE_DONE
    }

    private func claudeFiles() -> [(URL, Date)] {
        var entries: [(URL, Date)] = []
        var remaining = 8_192
        let deadline = ProcessInfo.processInfo.systemUptime + 0.75
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        func visit(_ directory: URL, depth: Int) {
            guard remaining > 0, ProcessInfo.processInfo.systemUptime < deadline, QuotaParsing.safePath(directory),
                  let children = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys),
                    options: [.skipsSubdirectoryDescendants]) else { return }
            while remaining > 0, ProcessInfo.processInfo.systemUptime < deadline, let file = children.nextObject() as? URL {
                remaining -= 1
                guard let values = try? file.resourceValues(forKeys: keys), values.isSymbolicLink != true else { continue }
                if depth == 1 {
                    let stem = file.deletingPathExtension().lastPathComponent
                    if values.isRegularFile == true, file.pathExtension == "jsonl", UUID(uuidString: stem) != nil {
                        entries.append((file, values.contentModificationDate ?? .distantPast))
                    }
                } else if depth == 0, values.isDirectory == true {
                    visit(file, depth: 1)
                }
            }
        }
        visit(claudeProjectsRoot, depth: 0)
        return Array(entries.sorted { $0.1 == $1.1 ? $0.0.path < $1.0.path : $0.1 > $1.1 }.prefix(128))
    }

    private func claudeMetadata(_ url: URL, uid: Int) -> (id: String, project: String, title: String?, identity: FileIdentity)? {
        guard url.pathExtension == "jsonl" else { return nil }
        let stem = url.deletingPathExtension().lastPathComponent
        guard let fileUUID = UUID(uuidString: stem) else { return nil }
        let expectedID = fileUUID.uuidString.lowercased()
        guard stem.lowercased() == expectedID else { return nil }

        let fd = SessionFileEvidence.openRegular(url)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard let identity = SessionFileEvidence.readIdentity(fd, uid: uid) else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0 else { return nil }

        func readChunk(_ count: Int, offset: off_t) -> Data? {
            var data = Data(count: count)
            let length = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, offset) }
            guard length >= 0 else { return nil }
            data.count = length
            return data
        }
        func parseLines(_ data: Data) -> [[String: Any]] {
            data.split(separator: 10).compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
        }

        let records: [[String: Any]]
        let budget = 64 * 1_024
        if info.st_size <= budget {
            guard let data = readChunk(Int(info.st_size), offset: 0) else { return nil }
            records = parseLines(data)
        } else {
            let half = 32 * 1_024
            guard var header = readChunk(half, offset: 0),
                  var tail = readChunk(half, offset: info.st_size - off_t(half)) else { return nil }
            if let end = header.lastIndex(of: 10) { header = Data(header.prefix(through: end)) } else { header = Data() }
            if let start = tail.firstIndex(of: 10) { tail.removeSubrange(...start) } else { tail = Data() }
            records = parseLines(header) + parseLines(tail)
        }
        guard !records.isEmpty else { return nil }

        var sawSessionID = false
        var resolvedProject: String?
        var summaryTitle: String?
        var firstUserPrompt: String?

        for record in records {
            if let rawID = record["sessionId"] {
                guard let idString = rawID as? String,
                      UUID(uuidString: idString)?.uuidString.lowercased() == expectedID else {
                    return nil
                }
                sawSessionID = true
            }
            if let rawCwd = record["cwd"] {
                guard let cwdString = rawCwd as? String,
                      let canonical = canonicalProject(cwdString) else {
                    return nil
                }
                if let existing = resolvedProject, existing != canonical {
                    return nil
                }
                resolvedProject = canonical
            }
            if let customTitle = record["customTitle"] as? String,
               let clean = SessionTurnPreviewInspector.sanitizeAndRedact(customTitle, maxLength: 80) {
                summaryTitle = clean
            } else if record["type"] as? String == "summary",
                      let summary = record["summary"] as? String,
                      let clean = SessionTurnPreviewInspector.sanitizeAndRedact(summary, maxLength: 80) {
                summaryTitle = clean
            } else if firstUserPrompt == nil,
                      record["type"] as? String == "user",
                      record["isMeta"] as? Bool != true,
                      let text = Self.extractClaudeUserText(from: record["message"]),
                      let clean = SessionTurnPreviewInspector.sanitizeAndRedact(text, maxLength: 80) {
                firstUserPrompt = clean
            }
        }

        guard sawSessionID, let project = resolvedProject else { return nil }
        return (expectedID, project, summaryTitle ?? firstUserPrompt, identity)
    }

    private static func extractClaudeUserText(from rawMessage: Any?) -> String? {
        guard let message = rawMessage as? [String: Any] else { return nil }
        if let content = message["content"] as? String {
            return content
        }
        if let blocks = message["content"] as? [[String: Any]] {
            for block in blocks where (block["type"] as? String ?? "text") == "text" {
                if let text = block["text"] as? String, !text.isEmpty {
                    return text
                }
            }
        }
        return nil
    }

    private func exactClaudeSessions(sessionID: String) -> [URL]? {
        guard let id = UUID(uuidString: sessionID) else { return nil }
        var remaining = 8_192
        let deadline = ProcessInfo.processInfo.systemUptime + 0.75
        var complete = true
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey]
        guard QuotaParsing.safePath(claudeProjectsRoot),
              let files = FileManager.default.enumerator(at: claudeProjectsRoot,
                includingPropertiesForKeys: Array(keys),
                errorHandler: { _, _ in complete = false; return false }) else { return nil }
        var matches: [URL] = []
        while let url = files.nextObject() as? URL {
            guard remaining > 0, ProcessInfo.processInfo.systemUptime < deadline, files.level <= 8,
                  let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else { return nil }
            remaining -= 1
            if values.isRegularFile == true, url.pathExtension == "jsonl",
               UUID(uuidString: url.deletingPathExtension().lastPathComponent) == id {
                matches.append(url)
                if matches.count > 1 { return matches }
            }
        }
        guard complete else { return nil }
        return matches
    }
}
