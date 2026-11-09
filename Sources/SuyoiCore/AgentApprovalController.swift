import Foundation

public enum HookEventKind: String, Codable, Equatable, Sendable {
    case sessionStart = "SessionStart"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case permissionRequest = "PermissionRequest"
    case notification = "Notification"
    case stop = "Stop"
    case sessionEnd = "SessionEnd"
}

public struct PendingApprovalRequest: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let sessionID: String
    public let agentName: String
    public let pid: Int?
    public let projectPath: String?
    public let toolName: String
    public let summary: String
    public let questionOptions: [String]
    public let requestedAt: Date

    public init(id: String, sessionID: String, agentName: String, pid: Int?, projectPath: String?,
                toolName: String, summary: String, questionOptions: [String], requestedAt: Date) {
        self.id = id
        self.sessionID = sessionID
        self.agentName = agentName
        self.pid = pid
        self.projectPath = projectPath
        self.toolName = toolName
        self.summary = summary
        self.questionOptions = questionOptions
        self.requestedAt = requestedAt
    }
}

public enum ApprovalDecision: Codable, Equatable, Sendable {
    case allowOnce
    case allowForSession
    case deny(reason: String?)
    case answerQuestion(selectedOption: String)
}

/// In-memory hook decisions. State transitions are atomic; responders run after unlocking
/// and may reenter the controller. Concurrent responders must provide their own synchronization.
public final class AgentApprovalController: @unchecked Sendable {
    private typealias Responder = @Sendable (Data) -> Void

    private struct Entry {
        let request: PendingApprovalRequest
        let isQuestion: Bool
        let responder: Responder?
    }

    private struct Reply: Encodable {
        let decision: String
        var reason: String? = nil
        var answer: String? = nil

        var data: Data {
            // Only strings are encoded; retain a blocking fallback if encoding ever fails.
            (try? JSONEncoder().encode(self)) ?? Data(#"{"decision":"block"}"#.utf8)
        }
    }

    private struct Hook: Decodable {
        let hook_event_name: HookEventKind
        let session_id: String
        var agent_name: String?
        var client: String?
        var pid: Int?
        var cwd: String?
        var tool_name: String?
        var tool_input: Input?
        var requires_approval: Bool?
    }

    private struct Input: Decodable {
        var command: String?
        var file_path: String?
        var question: String?
        var options: [Option]?
        var questions: [Question]?
    }

    private struct Question: Decodable {
        var question: String?
        var options: [Option]?
        var multiSelect: Bool?
    }

    private struct Option: Decodable {
        let label: String

        private enum CodingKeys: String, CodingKey { case label }

        init(from decoder: Decoder) throws {
            if let text = try? decoder.singleValueContainer().decode(String.self) {
                label = text
            } else {
                label = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .label)
            }
        }
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var autoApprovedSessions: Set<String> = []

    public init() {}

    public func pendingRequests() -> [PendingApprovalRequest] {
        lock.withLock { entries.map(\.request) }
    }

    /// Removes pending requests older than `maxAge` and notifies their responders with a block decision.
    @discardableResult
    public func pruneExpiredRequests(olderThan maxAge: TimeInterval = 180, now: Date = Date()) -> Int {
        guard maxAge.isFinite, maxAge > 0 else { return 0 }
        let expired: [Entry] = lock.withLock {
            removeEntries { now.timeIntervalSince($0.request.requestedAt) > maxAge }
        }
        respond(to: expired, with: Reply(decision: "block", reason: "Approval request expired"))
        return expired.count
    }

    public func isSessionAutoApproved(_ sessionID: String) -> Bool {
        lock.withLock { autoApprovedSessions.contains(sessionID) }
    }

    /// Enabling also resolves existing tool requests; questions always require an answer.
    public func setSessionAutoApprove(_ enabled: Bool, sessionID: String) {
        guard Self.validSessionID(sessionID) else { return }
        let approved: [Entry] = lock.withLock {
            if enabled {
                autoApprovedSessions.insert(sessionID)
                return removeEntries { $0.request.sessionID == sessionID && !$0.isQuestion }
            }
            autoApprovedSessions.remove(sessionID)
            return []
        }
        respond(to: approved, with: Reply(decision: "approve"))
    }

    @discardableResult
    public func submitDecision(_ decision: ApprovalDecision, forRequestID id: String) -> Bool {
        let result: ([Entry], Reply)? = lock.withLock {
            guard let index = entries.firstIndex(where: { $0.request.id == id }) else { return nil }
            let entry = entries[index]
            let reply: Reply
            switch decision {
            case .allowOnce, .allowForSession:
                guard !entry.isQuestion else { return nil }
                reply = Reply(decision: "approve")
            case .deny(let reason):
                reply = Reply(decision: "block", reason: Self.clean(reason, limit: 1_024))
            case .answerQuestion(let option):
                guard entry.isQuestion, entry.request.questionOptions.contains(option) else { return nil }
                reply = Reply(decision: "approve", answer: option)
            }
            entries.remove(at: index)
            var resolved = [entry]
            if decision == .allowForSession {
                autoApprovedSessions.insert(entry.request.sessionID)
                resolved += removeEntries {
                    $0.request.sessionID == entry.request.sessionID && !$0.isQuestion
                }
            }
            return (resolved, reply)
        }
        guard let (resolved, reply) = result else { return false }
        respond(to: resolved, with: reply)
        return true
    }

    /// Accepts at most 64 KiB and keeps at most 50 pending requests. Invalid or overflow
    /// requests receive a blocking response. Stop/end also unblock waiters with a denial.
    /// PreToolUse is gated unless requires_approval is explicitly false.
    @discardableResult
    public func ingestHookEvent(_ data: Data, now: Date = Date(),
                                responder: (@Sendable (Data) -> Void)? = nil) -> PendingApprovalRequest? {
        guard data.count <= 65_536,
              let hook = try? JSONDecoder().decode(Hook.self, from: data),
              Self.validSessionID(hook.session_id) else {
            responder?(Reply(decision: "block", reason: "Invalid hook event").data)
            return nil
        }

        switch hook.hook_event_name {
        case .stop, .sessionEnd:
            let cancelled = lock.withLock {
                if hook.hook_event_name == .sessionEnd { autoApprovedSessions.remove(hook.session_id) }
                return removeEntries { $0.request.sessionID == hook.session_id }
            }
            respond(to: cancelled, with: Reply(decision: "block", reason: "Session stopped"))
            return nil
        case .permissionRequest, .preToolUse:
            if hook.hook_event_name == .preToolUse && hook.requires_approval == false { return nil }
        default:
            return nil
        }

        guard let toolName = Self.clean(hook.tool_name, limit: 128) else {
            responder?(Reply(decision: "block", reason: "Missing tool name").data)
            return nil
        }
        let input = hook.tool_input
        // The public decision contract supports one selected option, not compound answers.
        if let questions = input?.questions,
           questions.count != 1 || questions.first?.multiSelect == true {
            responder?(Reply(decision: "block", reason: "Unsupported question format").data)
            return nil
        }
        let question = input?.questions?.first
        let options = question?.options ?? input?.options ?? []
        let isQuestion = toolName.caseInsensitiveCompare("AskUserQuestion") == .orderedSame
            || input?.question != nil || input?.questions != nil || !options.isEmpty
        // Never truncate the choice list or merge labels that become identical after sanitization.
        let labels = options.compactMap { Self.clean($0.label, limit: 512) }
        guard options.count <= 32, options.allSatisfy({ $0.label.unicodeScalars.count <= 512 }),
              labels.count == options.count, Set(labels).count == labels.count else {
            responder?(Reply(decision: "block", reason: "Invalid question options").data)
            return nil
        }
        let summary = Self.clean(question?.question ?? input?.question ?? input?.command ?? input?.file_path,
                                 limit: 1_024) ?? toolName
        let request = PendingApprovalRequest(
            id: UUID().uuidString, sessionID: hook.session_id,
            agentName: Self.clean(hook.agent_name, limit: 128) ?? Self.clean(hook.client, limit: 128) ?? "Unknown",
            pid: hook.pid.flatMap { $0 > 0 && $0 <= Int(Int32.max) ? $0 : nil },
            projectPath: Self.clean(hook.cwd, limit: 4_096), toolName: toolName,
            summary: summary, questionOptions: labels, requestedAt: now
        )
        let immediate: Reply? = lock.withLock {
            if !isQuestion && autoApprovedSessions.contains(hook.session_id) {
                return Reply(decision: "approve")
            }
            guard entries.count < 50 else {
                return Reply(decision: "block", reason: "Approval queue is full")
            }
            entries.append(Entry(request: request, isQuestion: isQuestion, responder: responder))
            return nil
        }
        if let immediate {
            responder?(immediate.data)
            return nil
        }
        return request
    }

    /// Returns a POSIX-shell command for a bridge that reads hook JSON from stdin.
    /// It does not install hooks or assume a provider-specific configuration schema.
    public static func hookSnippet(for agentName: String, bridgeExecutablePath: String) -> String {
        guard bridgeExecutablePath.hasPrefix("/"), bridgeExecutablePath.utf8.count <= 4_096,
              !bridgeExecutablePath.unicodeScalars.contains(where: unsafeScalar) else {
            return "# An absolute bridge executable path without control characters is required."
        }
        let name = clean(agentName, limit: 128) ?? "agent"
        let quotedPath = "'" + bridgeExecutablePath.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        return "# \(name) hook command; pass hook JSON on stdin.\n\(quotedPath)"
    }

    // Call only while holding lock.
    private func removeEntries(where predicate: (Entry) -> Bool) -> [Entry] {
        let removed = entries.filter(predicate)
        entries.removeAll(where: predicate)
        return removed
    }

    private func respond(to entries: [Entry], with reply: Reply) {
        let data = reply.data
        for entry in entries { entry.responder?(data) }
    }

    private static func validSessionID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: unsafeScalar)
    }

    private static func unsafeScalar(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
            || scalar.properties.generalCategory == .format
    }

    private static func clean(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let scalars = value.unicodeScalars.prefix(limit).map { unsafeScalar($0) ? Unicode.Scalar(" ") : $0 }
        let result = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}
