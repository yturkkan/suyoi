import Foundation
import Darwin

/// Uses the existing Trash outcome and logical-byte accounting contract.
public typealias CleanupExecutionReport = TrashExecutionReport

public struct StaleSessionLogSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let agentName: String
    public let path: String
    public let bytes: Int64
    public let modifiedAt: Date
    public let identity: FileIdentity

    public init(id: String, agentName: String, path: String, bytes: Int64, modifiedAt: Date, identity: FileIdentity) {
        self.id = id
        self.agentName = agentName
        self.path = path
        self.bytes = bytes
        self.modifiedAt = modifiedAt
        self.identity = identity
    }
}

/// Inspects names and filesystem metadata without reading session contents.
public struct SessionLogRetentionScanner: Sendable {
    private let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    public func scanStaleSessionLogs(
        olderThanDays: Int = 14,
        activeAgents: [AgentObservation] = [],
        now: Date = Date()
    ) -> [StaleSessionLogSummary] {
        let cutoff = now.addingTimeInterval(-Double(max(1, olderThanDays)) * 86_400)
        var logs: [StaleSessionLogSummary] = []

        func visit(_ components: [String], remainingDepth: Int, codex: Bool) {
            let names = withDirectory(components) { descriptor in
                directoryNames(descriptor)
            } ?? []
            for name in names {
                let child = components + [name]
                if remainingDepth > 0 {
                    if codex && !Self.isDateComponent(name, index: 3 - remainingDepth) { continue }
                    visit(child, remainingDepth: remainingDepth - 1, codex: codex)
                } else {
                    let url = url(for: child)
                    guard url.pathExtension == "jsonl",
                          !isAssociated(url, activeAgents: activeAgents),
                          let metadata = metadata(at: child), metadata.modifiedAt < cutoff else { continue }
                    logs.append(StaleSessionLogSummary(id: url.path, agentName: codex ? "Codex" : "Claude Code",
                        path: url.path, bytes: metadata.bytes, modifiedAt: metadata.modifiedAt, identity: metadata.identity))
                }
            }
        }

        visit([".codex", "sessions"], remainingDepth: 3, codex: true)
        visit([".claude", "projects"], remainingDepth: 1, codex: false)
        return logs.sorted { $0.bytes == $1.bytes ? $0.path < $1.path : $0.bytes > $1.bytes }
    }

    public func trashStaleLogs(
        _ logs: [StaleSessionLogSummary],
        olderThanDays: Int = 14,
        activeAgents: [AgentObservation] = [],
        liveAgents: (() -> [AgentObservation])? = nil,
        now: Date = Date(),
        trashItem: (URL) throws -> URL? = { url in
            var resulting: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            return resulting as URL?
        }
    ) -> CleanupExecutionReport {
        let cutoff = now.addingTimeInterval(-Double(max(1, olderThanDays)) * 86_400)
        var outcomes: [TrashItemOutcome] = []
        var movedPaths = Set<String>()
        var movedIdentities: [FileIdentity] = []
        var bytes: Int64 = 0
        for log in logs {
            func failed(_ reason: String) -> TrashItemOutcome {
                TrashItemOutcome(candidateID: log.id, path: log.path, bytes: 0, succeeded: false, error: reason)
            }
            guard let components = allowedComponents(log.path) else {
                outcomes.append(failed("Session log path is outside the allowed layout"))
                continue
            }
            let target = url(for: components)
            guard !movedPaths.contains(target.path), !movedIdentities.contains(log.identity) else {
                outcomes.append(failed("Session log was already moved to Trash"))
                continue
            }
            let currentActiveAgents = liveAgents?() ?? activeAgents
            guard !isAssociated(target, activeAgents: currentActiveAgents) else {
                outcomes.append(failed("Session log is associated with an active agent"))
                continue
            }
            guard let live = metadata(at: components), live.identity == log.identity else {
                outcomes.append(failed("Session log is unavailable, contains a symlink, or its identity changed"))
                continue
            }
            guard live.modifiedAt < cutoff else {
                outcomes.append(failed("Session log is no longer older than the retention period"))
                continue
            }
            do {
                // Trash is path-based; a filesystem change after verification remains possible.
                let destination = try trashItem(target)
                movedPaths.insert(target.path)
                movedIdentities.append(live.identity)
                bytes = bytes > Int64.max - live.bytes ? Int64.max : bytes + live.bytes
                outcomes.append(TrashItemOutcome(candidateID: log.id, path: log.path,
                    trashedURL: destination?.path, bytes: live.bytes, succeeded: true))
            } catch {
                outcomes.append(failed("Could not move session log to Trash"))
            }
        }
        return CleanupExecutionReport(outcomes: outcomes, reclaimedBytes: bytes,
            warnings: ["Reported bytes are logical sizes moved to Trash; disk space is not necessarily freed."])
    }

    private struct Metadata {
        let identity: FileIdentity
        let bytes: Int64
        let modifiedAt: Date
    }

    private func metadata(at components: [String]) -> Metadata? {
        guard let name = components.last else { return nil }
        return withDirectory(Array(components.dropLast())) { descriptor -> Metadata? in
            var relative = stat()
            var absolute = stat()
            guard fstatat(descriptor, name, &relative, AT_SYMLINK_NOFOLLOW) == 0,
                  (relative.st_mode & S_IFMT) == S_IFREG,
                  lstat(url(for: components).path, &absolute) == 0,
                  (absolute.st_mode & S_IFMT) == S_IFREG,
                  relative.st_dev == absolute.st_dev, relative.st_ino == absolute.st_ino,
                  relative.st_size == absolute.st_size,
                  relative.st_mtimespec.tv_sec == absolute.st_mtimespec.tv_sec,
                  relative.st_mtimespec.tv_nsec == absolute.st_mtimespec.tv_nsec else { return nil }
            return Metadata(identity: FileIdentity(device: absolute.st_dev, inode: UInt64(absolute.st_ino)),
                bytes: max(0, Int64(absolute.st_size)),
                modifiedAt: Date(timeIntervalSince1970: Double(absolute.st_mtimespec.tv_sec)
                    + Double(absolute.st_mtimespec.tv_nsec) / 1_000_000_000))
        } ?? nil
    }

    /// Each directory is opened relative to `/` without following links (normalizing macOS system root links).
    private func withDirectory<T>(_ components: [String], body: (Int32) -> T) -> T? {
        guard homeDirectory.path.hasPrefix("/"), !homeDirectory.path.contains("\0") else { return nil }
        var normalizedHome = homeDirectory.path
        for rootLink in ["/var/", "/tmp/", "/etc/"] where normalizedHome.hasPrefix(rootLink) {
            normalizedHome = "/private" + normalizedHome
            break
        }
        let homeComponents = normalizedHome.split(separator: "/").map(String.init)
        let allComponents = homeComponents + components
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var descriptor = open("/", flags)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        for component in allComponents {
            guard component != ".", component != "..", !component.contains("/"), !component.contains("\0") else { return nil }
            let child = openat(descriptor, component, flags)
            guard child >= 0 else { return nil }
            close(descriptor)
            descriptor = child
        }
        return body(descriptor)
    }

    private func directoryNames(_ descriptor: Int32) -> [String] {
        let copy = dup(descriptor)
        guard copy >= 0 else { return [] }
        guard let stream = fdopendir(copy) else { close(copy); return [] }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafeBytes(of: &entry.pointee.d_name) { bytes in
                bytes.baseAddress.flatMap { String(validatingUTF8: $0.assumingMemoryBound(to: CChar.self)) }
            }
            if let name, name != ".", name != ".." { names.append(name) }
        }
        return names
    }

    private func url(for components: [String]) -> URL {
        components.reduce(homeDirectory) { $0.appendingPathComponent($1) }
    }

    private func allowedComponents(_ path: String) -> [String]? {
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        let target = URL(fileURLWithPath: path).standardizedFileURL
        let prefix = homeDirectory.path == "/" ? "/" : homeDirectory.path + "/"
        guard target.path == path, path.hasPrefix(prefix), target.pathExtension == "jsonl" else { return nil }
        let components = path.dropFirst(prefix.count).split(separator: "/").map(String.init)
        if components.count == 6, components.prefix(2) == [".codex", "sessions"],
           (0..<3).allSatisfy({ Self.isDateComponent(components[$0 + 2], index: $0) }) { return components }
        if components.count == 4, components.prefix(2) == [".claude", "projects"] { return components }
        return nil
    }

    private static func isDateComponent(_ name: String, index: Int) -> Bool {
        guard name.utf8.count == (index == 0 ? 4 : 2),
              name.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(name) else { return false }
        return index == 0 || (1...(index == 1 ? 12 : 31)).contains(number)
    }

    private func isAssociated(_ url: URL, activeAgents: [AgentObservation]) -> Bool {
        let parent = url.deletingLastPathComponent()
        return activeAgents.contains { agent in
            if let session = agent.sessionID, !session.isEmpty, url.lastPathComponent.contains(session) { return true }
            return [agent.project?.rootPath, agent.process.cwd].compactMap { $0 }.contains { path in
                guard path.hasPrefix("/"), !path.contains("\0") else { return false }
                let project = URL(fileURLWithPath: path).standardizedFileURL.path
                if parent.path == project { return true }
                guard parent.deletingLastPathComponent().path == homeDirectory.appendingPathComponent(".claude/projects").path else { return false }
                let encoded = String(project.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
                return parent.lastPathComponent == encoded
            }
        }
    }
}
