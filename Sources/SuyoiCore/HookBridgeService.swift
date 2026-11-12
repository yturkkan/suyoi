import CryptoKit
import Darwin
import Dispatch
import Foundation

public struct HookBridgeClient: Sendable {
    public let inboxDirectory: URL
    public let outboxDirectory: URL
    private let hookOwner: @Sendable () -> ObservedProcess?
    private let processLookup: @Sendable (Int32, Int) -> ObservedProcess?

    public init(
        inboxDirectory: URL = HookBridgeClient.defaultInboxDirectory(),
        outboxDirectory: URL = HookBridgeClient.defaultOutboxDirectory()
    ) {
        self.init(inboxDirectory: inboxDirectory, outboxDirectory: outboxDirectory,
                  hookOwner: { Self.claudeAncestor() }, processLookup: { DarwinProcessReader().process(pid: $0, uid: $1) })
    }

    init(inboxDirectory: URL, outboxDirectory: URL,
         hookOwner: @escaping @Sendable () -> ObservedProcess?,
         processLookup: @escaping @Sendable (Int32, Int) -> ObservedProcess?) {
        self.inboxDirectory = inboxDirectory
        self.outboxDirectory = outboxDirectory
        self.hookOwner = hookOwner
        self.processLookup = processLookup
    }

    public static func defaultInboxDirectory(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appendingPathComponent("Library/Application Support/\(SuyoiAppIdentity.supportFolderName)/approvals/inbox", isDirectory: true)
    }

    public static func defaultOutboxDirectory(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appendingPathComponent("Library/Application Support/\(SuyoiAppIdentity.supportFolderName)/approvals/outbox", isDirectory: true)
    }

    private struct Envelope: Codable {
        let version: Int
        let fields: Data
        let scope: ApprovalScope?
    }

    /// Synchronous Claude Code hook transport. Only a reduced event reaches the inbox.
    public func forwardEventAndWait(
        _ inputData: Data,
        timeout: TimeInterval = 120.0,
        pollInterval: TimeInterval = 0.05
    ) -> Data {
        guard !inputData.isEmpty, inputData.count <= 65_536,
              let object = try? JSONSerialization.jsonObject(with: inputData) as? [String: Any],
              let name = object["hook_event_name"] as? String, let event = HookEventKind(rawValue: name) else {
            return Self.invalidPayload
        }
        func deny(_ reason: String) -> Data { Self.claudeReply(.init(decision: "block", reason: reason), event: event) }
        let decisionEvent = event == .preToolUse || event == .permissionRequest
        guard decisionEvent || event == .sessionStart || event == .sessionEnd || event == .stop else { return Data() }
        guard let sessionID = object["session_id"] as? String, AgentApprovalController.validSessionID(sessionID) else {
            return deny("Invalid hook payload")
        }

        let owner = hookOwner().flatMap { process -> ObservedProcess? in
            UUID(uuidString: sessionID) != nil && Self.isClaude(process) ? process : nil
        }
        let cwd = Self.validProject(object["cwd"] as? String)
        let verified = owner.flatMap { process -> ObservedProcess? in
            guard let cwd, Self.validProject(process.cwd) == cwd else { return nil }
            return process
        }

        if !decisionEvent && owner == nil { return Data() }
        let inbox = HookBridgeFiles.openDirectory(inboxDirectory)
        guard inbox >= 0 else { return deny("Hook bridge unavailable") }
        defer { close(inbox) }
        let now = Date()
        HookBridgeFiles.pruneStaleFiles(in: inbox, suffix: ".json", olderThan: 180, now: now)
        HookBridgeFiles.pruneStaleFiles(in: inbox, suffix: ".lifetime", olderThan: Self.lifetimeMaxAge, now: now)

        var scope: ApprovalScope?
        if let owner {
            let key = Self.scopeFilename(process: owner.identity, sessionID: sessionID)
            switch event {
            case .sessionStart:
                // A new lifetime retires any previous grant even when its project cannot be verified.
                if verified != nil {
                    if !HookBridgeFiles.writeAtomically(Data(UUID().uuidString.utf8), name: key, directory: inbox) {
                        _ = unlinkat(inbox, key, 0)
                    }
                } else {
                    _ = unlinkat(inbox, key, 0)
                }
                return Data()
            case .sessionEnd:
                _ = unlinkat(inbox, key, 0)
                return Data()
            default:
                if let verified, let cwd, let generation = Self.readGeneration(key, directory: inbox, now: now) {
                    scope = ApprovalScope(process: verified.identity, sessionID: sessionID, projectPath: cwd,
                                          generation: generation)
                }
            }
        }
        if event == .stop {
            if let scope,
               let fields = try? JSONSerialization.data(withJSONObject: ["hook_event_name": name, "session_id": sessionID]),
               let envelope = try? JSONEncoder().encode(Envelope(version: 1, fields: fields, scope: scope)) {
                _ = HookBridgeFiles.writeAtomically(envelope, name: UUID().uuidString + ".json", directory: inbox)
            }
            return Data()
        }
        guard decisionEvent else { return Data() }
        if event == .preToolUse, object["requires_approval"] as? Bool == false { return Data() }
        guard timeout.isFinite, timeout > 0 else { return deny("Approval timed out") }
        guard let tool = (object["tool_name"] as? String).flatMap({ Self.display($0, limit: 128) }) else {
            return deny("Missing tool name")
        }

        let originalInput = object["tool_input"] as? [String: Any] ?? [:]
        let prepared = Self.reducedInput(originalInput, isQuestionTool: tool == "AskUserQuestion")
        guard let prepared else { return deny("Unsupported question format") }
        var fields: [String: Any] = ["hook_event_name": name, "session_id": sessionID, "tool_name": tool,
                                     "agent_name": verified == nil ? "Claude Code Hook" : "Claude Code",
                                     "tool_input": prepared.fields]
        if let cwd { fields["cwd"] = cwd }
        if let verified { fields["pid"] = verified.pid }
        guard let data = try? JSONSerialization.data(withJSONObject: fields),
              let envelope = try? JSONEncoder().encode(Envelope(version: 1, fields: data, scope: scope)) else {
            return deny("Invalid hook payload")
        }

        let outbox = HookBridgeFiles.openDirectory(outboxDirectory)
        guard outbox >= 0 else { return deny("Hook bridge unavailable") }
        defer { close(outbox) }
        HookBridgeFiles.pruneStaleFiles(in: outbox, suffix: ".response.json", olderThan: 180, now: now)
        let id = UUID().uuidString
        let requestName = id + ".json"
        guard HookBridgeFiles.writeAtomically(envelope, name: requestName, directory: inbox) else {
            return deny("Hook bridge unavailable")
        }
        let responseName = id + ".response.json"
        defer {
            _ = unlinkat(inbox, requestName, 0)
            _ = unlinkat(outbox, responseName, 0)
        }
        let started = ProcessInfo.processInfo.systemUptime
        let interval = pollInterval.isFinite && pollInterval > 0 ? max(0.001, pollInterval) : 0.05
        while true {
            let remaining = timeout - (ProcessInfo.processInfo.systemUptime - started)
            guard remaining > 0 else { return deny("Approval timed out") }
            switch HookBridgeFiles.readBoundedFile(name: responseName, directory: outbox, maxBytes: 16_384) {
            case .missing:
                Thread.sleep(forTimeInterval: min(interval, remaining))
            case .invalid:
                return deny("Invalid approval response")
            case .data(let data):
                guard let reply = try? JSONDecoder().decode(AgentApprovalController.Reply.self, from: data),
                      ["approve", "block"].contains(reply.decision) else { return deny("Invalid approval response") }
                if reply.decision == "approve", let scope, !scopeIsCurrent(scope, directory: inbox) {
                    return deny("Hook session ended")
                }
                var updatedInput: [String: Any]?
                if reply.decision == "approve", let question = prepared.originalQuestion {
                    guard let label = reply.answer, let index = prepared.labels.firstIndex(of: label) else {
                        return deny("Question requires an answer")
                    }
                    var input = originalInput
                    input["answers"] = [question: prepared.originalLabels[index]]
                    updatedInput = input
                }
                return Self.claudeReply(reply, event: event, updatedInput: updatedInput)
            }
        }
    }

    /// The scope marker is changed by the lifecycle hook before it returns. An older
    /// pending request cannot regain the previous lifetime by arriving late.
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
        HookBridgeFiles.pruneStaleFiles(in: inbox, suffix: ".lifetime", olderThan: Self.lifetimeMaxAge, now: now)
        HookBridgeFiles.pruneStaleFiles(in: outbox, suffix: ".response.json", olderThan: maxPendingAge, now: now)
        let names = HookBridgeFiles.directoryEntryNames(inbox).compactMap { name -> (String, Date)? in
            guard name.hasSuffix(".json"), UUID(uuidString: String(name.dropLast(5))) != nil,
                  let date = HookBridgeFiles.modificationDate(name: name, directory: inbox) else { return nil }
            return (name, date)
        }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }
        var addedCount = 0
        for (name, timestamp) in names.prefix(100) {
            let readResult = HookBridgeFiles.readBoundedFile(name: name, directory: inbox, maxBytes: 65_536)
            guard unlinkat(inbox, name, 0) == 0,
                  abs(now.timeIntervalSince(timestamp)) <= maxPendingAge, case .data(let data) = readResult,
                  let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.version == 1 else { continue }
            let responseName = String(name.dropLast(5)) + ".response.json"
            let created = controller.ingestHookEvent(envelope.fields, scope: envelope.scope, now: timestamp, isScopeCurrent: {
                guard let scope = envelope.scope else { return false }
                let fd = HookBridgeFiles.openDirectory(inboxDirectory)
                guard fd >= 0 else { return false }
                defer { close(fd) }
                return scopeIsCurrent(scope, directory: fd)
            }) { replyData in
                let fd = HookBridgeFiles.openDirectory(outboxDirectory)
                guard fd >= 0 else { return }
                defer { close(fd) }
                _ = HookBridgeFiles.writeAtomically(replyData, name: responseName, directory: fd)
            }
            if created != nil { addedCount += 1 }
        }
        return addedCount
    }

    private static let lifetimeMaxAge: TimeInterval = 86_400

    private static func validProject(_ raw: String?) -> String? {
        guard let raw, raw.hasPrefix("/"), raw.utf8.count <= 4_096,
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format }) else { return nil }
        return URL(fileURLWithPath: raw).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func isClaude(_ process: ObservedProcess) -> Bool {
        process.identity.isActionEligible && process.uid == Int(getuid()) && !process.isStopped
            && AgentRecognizer.agentName(for: process) == "Claude Code"
    }

    private static func claudeAncestor() -> ObservedProcess? {
        let uid = Int(getuid())
        let reader = DarwinProcessReader()
        var pid = getppid()
        for _ in 0..<12 {
            guard pid > 1, let process = reader.process(pid: pid, uid: uid),
                  let parent = Int32(exactly: process.parentPID), parent != pid else { return nil }
            if AgentRecognizer.isAgent(process) { return isClaude(process) ? process : nil }
            pid = parent
        }
        return nil
    }

    private static func scopeFilename(process: ProcessIdentity, sessionID: String) -> String {
        let material = "\(process.uid)\0\(process.pid)\0\(process.startTimeMicroseconds ?? 0)\0\(process.executablePath)\0\(sessionID)"
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined() + ".lifetime"
    }

    private static func readGeneration(_ key: String, directory: Int32, now: Date) -> UUID? {
        guard let date = HookBridgeFiles.modificationDate(name: key, directory: directory),
              abs(now.timeIntervalSince(date)) <= lifetimeMaxAge,
              case .data(let data) = HookBridgeFiles.readBoundedFile(name: key, directory: directory, maxBytes: 36),
              let value = String(data: data, encoding: .utf8) else { return nil }
        return UUID(uuidString: value)
    }

    private func scopeIsCurrent(_ scope: ApprovalScope, directory: Int32) -> Bool {
        guard let pid = Int32(exactly: scope.process.pid), let process = processLookup(pid, scope.process.uid),
              process.identity == scope.process, Self.isClaude(process),
              Self.validProject(process.cwd) == scope.projectPath else { return false }
        let key = Self.scopeFilename(process: scope.process, sessionID: scope.sessionID)
        return Self.readGeneration(key, directory: directory, now: Date()) == scope.generation
    }

    private static func display(_ raw: String, limit: Int) -> String? {
        SessionTurnPreviewInspector.sanitizeAndRedact(raw, maxLength: limit)
    }

    private struct ReducedInput {
        let fields: [String: Any]
        let originalQuestion: String?
        let labels: [String]
        let originalLabels: [String]
    }

    private static func reducedInput(_ input: [String: Any], isQuestionTool: Bool) -> ReducedInput? {
        if isQuestionTool {
            guard let questions = input["questions"] as? [[String: Any]], questions.count == 1,
                  let question = questions.first, question["multiSelect"] as? Bool != true,
                  let text = question["question"] as? String, let summary = display(text, limit: 1_024),
                  let options = question["options"] as? [[String: Any]], (1...32).contains(options.count) else { return nil }
            let original = options.compactMap { $0["label"] as? String }
            let labels = original.compactMap { display($0, limit: 512) }
            guard labels.count == options.count, Set(labels).count == labels.count else { return nil }
            return ReducedInput(fields: ["question": summary, "options": labels],
                                originalQuestion: text, labels: labels, originalLabels: original)
        }
        let candidate = (input["command"] as? String) ?? (input["file_path"] as? String)
        let summary = candidate.flatMap { display($0, limit: 1_024) }
        var fields: [String: Any] = summary.map { ["command": $0] } ?? [:]
        // The summary is display-only (whitespace collapsed, secrets redacted, truncated).
        // If it differs from what the agent will actually execute, the controller must not
        // treat it as the verbatim command for read-only auto-approval.
        if let candidate, summary != candidate {
            fields["command_sanitized"] = true
        }
        return ReducedInput(fields: fields,
                            originalQuestion: nil, labels: [], originalLabels: [])
    }

    private static func claudeReply(_ reply: AgentApprovalController.Reply, event: HookEventKind,
                                    updatedInput: [String: Any]? = nil) -> Data {
        let allowed = reply.decision == "approve"
        let behavior = allowed ? "allow" : "deny"
        var output: [String: Any] = ["hookEventName": event.rawValue]
        switch event {
        case .preToolUse:
            output["permissionDecision"] = behavior
            if let reason = reply.reason { output["permissionDecisionReason"] = reason }
            if let updatedInput { output["updatedInput"] = updatedInput }
        case .permissionRequest:
            var decision: [String: Any] = ["behavior": behavior]
            if let reason = reply.reason { decision["message"] = reason }
            if let updatedInput { decision["updatedInput"] = updatedInput }
            output["decision"] = decision
        default: return Data()
        }
        return (try? JSONSerialization.data(withJSONObject: ["hookSpecificOutput": output], options: [.sortedKeys])) ?? invalidPayload
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
        var path = url.path
        if ["/var/", "/tmp/", "/etc/"].contains(where: { path.hasPrefix($0) }) { path = "/private" + path }
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard descriptor >= 0 else { return -1 }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            close(descriptor)
            return -1
        }
        return descriptor
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
              metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0, metadata.st_nlink == 1,
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
