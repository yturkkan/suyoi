import Darwin
import Dispatch
import Foundation

public struct HookBridgeClient: Sendable {
    public let inboxDirectory: URL
    public let outboxDirectory: URL

    public init(
        inboxDirectory: URL = HookBridgeClient.defaultInboxDirectory(),
        outboxDirectory: URL = HookBridgeClient.defaultOutboxDirectory()
    ) {
        self.inboxDirectory = inboxDirectory
        self.outboxDirectory = outboxDirectory
    }

    public static func defaultInboxDirectory(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appendingPathComponent("Library/Application Support/Suyoi/approvals/inbox", isDirectory: true)
    }

    public static func defaultOutboxDirectory(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appendingPathComponent("Library/Application Support/Suyoi/approvals/outbox", isDirectory: true)
    }

    /// Synchronous transport for hook subprocesses; call off the main thread.
    public func forwardEventAndWait(
        _ inputData: Data,
        timeout: TimeInterval = 120.0,
        pollInterval: TimeInterval = 0.05
    ) -> Data {
        guard !inputData.isEmpty, inputData.count <= 65_536,
              let object = try? JSONSerialization.jsonObject(with: inputData) as? [String: Any],
              let event = object["hook_event_name"] as? String,
              let session = object["session_id"] as? String,
              !session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Self.invalidPayload
        }
        let lifecycle = ["Stop", "SessionEnd", "SessionStart", "PostToolUse", "Notification"].contains(event)
        guard lifecycle || event == "PermissionRequest" || event == "PreToolUse" else {
            return Self.invalidPayload
        }

        let inbox = HookBridgeFiles.openDirectory(inboxDirectory)
        guard inbox >= 0 else { return Self.unavailable }
        defer { close(inbox) }
        let requestName = UUID().uuidString + ".json"
        if lifecycle {
            guard HookBridgeFiles.writeAtomically(inputData, name: requestName, directory: inbox) else {
                return Self.unavailable
            }
            return Data(#"{"decision":"approve"}"#.utf8)
        }

        guard timeout.isFinite, timeout > 0 else { return Self.timedOut }
        let outbox = HookBridgeFiles.openDirectory(outboxDirectory)
        guard outbox >= 0 else { return Self.unavailable }
        defer { close(outbox) }
        guard HookBridgeFiles.writeAtomically(inputData, name: requestName, directory: inbox) else {
            return Self.unavailable
        }
        let responseName = String(requestName.dropLast(5)) + ".response.json"
        // Only transport-owned spool entries are unlinked; these are not user storage cleanup.
        defer {
            _ = unlinkat(inbox, requestName, 0)
            _ = unlinkat(outbox, responseName, 0)
        }
        let started = ProcessInfo.processInfo.systemUptime
        let interval = pollInterval.isFinite && pollInterval > 0 ? max(0.001, pollInterval) : 0.05
        while true {
            let remaining = timeout - (ProcessInfo.processInfo.systemUptime - started)
            guard remaining > 0 else { return Self.timedOut }
            switch HookBridgeFiles.readBoundedFile(name: responseName, directory: outbox, maxBytes: 16_384) {
            case .missing:
                Thread.sleep(forTimeInterval: min(interval, remaining))
            case .invalid:
                return Data(#"{"decision":"block","reason":"Invalid approval response"}"#.utf8)
            case .data(let data):
                return data
            }
        }
    }

    /// Safely drains queued hook JSON files from the inbox directory using descriptor-pinned `O_NOFOLLOW`
    /// reads, routes responses atomically to the outbox directory, and prunes expired requests/responses.
    @discardableResult
    public func drainInbox(
        into controller: AgentApprovalController,
        maxPendingAge: TimeInterval = 180.0,
        now: Date = Date()
    ) -> Int {
        controller.pruneExpiredRequests(olderThan: maxPendingAge, now: now)
        let inbox = HookBridgeFiles.openDirectory(inboxDirectory)
        guard inbox >= 0 else { return 0 }
        defer { close(inbox) }
        let outbox = HookBridgeFiles.openDirectory(outboxDirectory)
        guard outbox >= 0 else { return 0 }
        defer { close(outbox) }

        HookBridgeFiles.pruneStaleFiles(in: inbox, suffix: ".json", olderThan: maxPendingAge, now: now)
        HookBridgeFiles.pruneStaleFiles(in: outbox, suffix: ".response.json", olderThan: maxPendingAge, now: now)

        let names = HookBridgeFiles.directoryEntryNames(inbox)
            .filter { !$0.hasPrefix(".") && $0.hasSuffix(".json") }
            .sorted()
        let outboxURL = outboxDirectory
        var addedCount = 0
        for name in names {
            let fileTimestamp = HookBridgeFiles.modificationDate(name: name, directory: inbox) ?? now
            let readResult = HookBridgeFiles.readBoundedFile(name: name, directory: inbox, maxBytes: 65_536)
            _ = unlinkat(inbox, name, 0)
            guard now.timeIntervalSince(fileTimestamp) <= maxPendingAge,
                  case .data(let data) = readResult else { continue }
            let responseName = String(name.dropLast(5)) + ".response.json"
            let created = controller.ingestHookEvent(data, now: fileTimestamp) { replyData in
                let fd = HookBridgeFiles.openDirectory(outboxURL)
                guard fd >= 0 else { return }
                defer { close(fd) }
                _ = HookBridgeFiles.writeAtomically(replyData, name: responseName, directory: fd)
            }
            if created != nil {
                addedCount += 1
            }
        }
        return addedCount
    }

    public static func simulatedApprovalPayload(
        sessionID: String = "sim-session-1",
        agentName: String = "Claude Code",
        toolName: String = "Bash",
        command: String = "git status --short",
        question: String? = nil,
        options: [String] = []
    ) -> Data {
        var input: [String: Any] = ["command": command]
        if let question { input["question"] = question }
        if !options.isEmpty { input["options"] = options }
        let payload: [String: Any] = [
            "hook_event_name": "PermissionRequest", "session_id": sessionID,
            "agent_name": agentName, "tool_name": toolName, "tool_input": input
        ]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
    }

    private static let invalidPayload = Data(#"{"decision":"block","reason":"Invalid hook payload"}"#.utf8)
    private static let timedOut = Data(#"{"decision":"block","reason":"Approval timed out"}"#.utf8)
    private static let unavailable = Data(#"{"decision":"block","reason":"Hook bridge unavailable"}"#.utf8)
}

/// Directory notifications are coalesced by Dispatch. The callback should rescan the inbox.
public final class ApprovalInboxWatcher: @unchecked Sendable {
    private let inboxDirectory: URL
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "suyoi.approval-inbox", qos: .userInitiated)
    private let lock = NSLock()
    private var source: DispatchSourceFileSystemObject?
    private var generation: UUID?

    public init(
        inboxDirectory: URL = HookBridgeClient.defaultInboxDirectory(),
        onChange: @escaping @Sendable () -> Void
    ) {
        self.inboxDirectory = inboxDirectory
        self.onChange = onChange
    }

    public func start() {
        lock.withLock {
            guard source == nil else { return }
            let descriptor = HookBridgeFiles.openDirectory(inboxDirectory)
            guard descriptor >= 0 else { return }
            let token = UUID()
            let watcher = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .extend, .attrib, .rename], queue: queue
            )
            watcher.setEventHandler { [weak self] in
                guard let self, self.lock.withLock({ self.generation == token }) else { return }
                self.onChange()
            }
            watcher.setCancelHandler { close(descriptor) }
            generation = token
            source = watcher
            watcher.activate()
        }
    }

    /// Cancels future notifications; an already-running callback may finish.
    public func stop() {
        lock.withLock {
            generation = nil
            source?.cancel()
            source = nil
        }
    }

    deinit { stop() }
}

private enum HookBridgeFiles {
    enum Response {
        case missing
        case invalid
        case data(Data)
    }

    static func openDirectory(_ url: URL) -> Int32 {
        guard url.isFileURL, !url.path.utf8.contains(0) else { return -1 }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { return -1 }
        // Pin the directory so subsequent reads, writes and cleanup cannot follow a replaced path.
        return open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }

    static func writeAtomically(_ data: Data, name: String, directory: Int32) -> Bool {
        let temporary = "." + UUID().uuidString + ".tmp"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return false }
        defer {
            close(descriptor)
            _ = unlinkat(directory, temporary, 0)
        }
        let written = data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return false }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        return written && renameat(directory, temporary, directory, name) == 0
    }

    static func readBoundedFile(name: String, directory: Int32, maxBytes: Int) -> Response {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return errno == ENOENT ? .missing : .invalid }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= 0, metadata.st_size <= off_t(maxBytes) else { return .invalid }
        // Read one extra byte to detect growth after fstat, without unbounded allocation.
        var bytes = [UInt8](repeating: 0, count: maxBytes + 1)
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress!.advanced(by: offset), $0.count - offset)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { return .invalid }
            if count == 0 { break }
            offset += count
        }
        guard offset <= maxBytes else { return .invalid }
        return .data(Data(bytes.prefix(offset)))
    }

    static func directoryEntryNames(_ directory: Int32) -> [String] {
        let copy = dup(directory)
        guard copy >= 0 else { return [] }
        guard let stream = fdopendir(copy) else {
            close(copy)
            return []
        }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafeBytes(of: &entry.pointee.d_name) { bytes in
                bytes.baseAddress.flatMap { String(validatingUTF8: $0.assumingMemoryBound(to: CChar.self)) }
            }
            if let name, name != ".", name != ".." {
                names.append(name)
            }
        }
        return names
    }

    static func modificationDate(name: String, directory: Int32) -> Date? {
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return Date(
            timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)
                + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        )
    }

    static func pruneStaleFiles(in directory: Int32, suffix: String, olderThan maxAge: TimeInterval, now: Date) {
        guard maxAge.isFinite, maxAge > 0 else { return }
        let cutoff = now.addingTimeInterval(-maxAge)
        for name in directoryEntryNames(directory) where !name.hasPrefix(".") && name.hasSuffix(suffix) {
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let modifiedAt = Date(
                timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)
                    + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
            )
            if modifiedAt < cutoff {
                _ = unlinkat(directory, name, 0)
            }
        }
    }
}
