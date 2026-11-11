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

public struct ScopedApprovalPolicy: Codable, Equatable, Sendable {
    public var autoApproveReadOnlyTools: Bool
    public var applyToAllVerifiedProjects: Bool
    public var allowedProjectPaths: Set<String>

    public init(
        autoApproveReadOnlyTools: Bool = false,
        applyToAllVerifiedProjects: Bool = true,
        allowedProjectPaths: Set<String> = []
    ) {
        self.autoApproveReadOnlyTools = autoApproveReadOnlyTools
        self.applyToAllVerifiedProjects = applyToAllVerifiedProjects
        self.allowedProjectPaths = allowedProjectPaths
    }
}

public struct AutoApprovedToolRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let agentName: String
    public let toolName: String
    public let projectPath: String
    public let summary: String
    public let approvedAt: Date

    public init(
        id: String = UUID().uuidString,
        agentName: String,
        toolName: String,
        projectPath: String,
        summary: String,
        approvedAt: Date
    ) {
        self.id = id
        self.agentName = agentName
        self.toolName = toolName
        self.projectPath = projectPath
        self.summary = summary
        self.approvedAt = approvedAt
    }
}

struct ApprovalScope: Codable, Equatable, Sendable {
    let process: ProcessIdentity
    let sessionID: String
    let projectPath: String
    let generation: UUID
}

/// In-memory hook decisions. State transitions are atomic; responders run after unlocking
/// and may reenter the controller. Concurrent responders must provide their own synchronization.
public final class AgentApprovalController: @unchecked Sendable {
    private typealias Responder = @Sendable (Data) -> Void

    private struct Entry {
        let request: PendingApprovalRequest
        let isQuestion: Bool
        let responder: Responder?
        let scope: ApprovalScope?
        let isScopeCurrent: @Sendable () -> Bool

        var currentScope: ApprovalScope? {
            guard let scope, isScopeCurrent() else { return nil }
            return scope
        }
    }

    struct Reply: Codable {
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

    private static let directReadOnlyToolNames: Set<String> = [
        "read", "view", "glob", "grep", "ls", "readfile", "listdir", "findfiles"
    ]

    private static let forbiddenShellScalars: Set<Unicode.Scalar> = [
        ";", "|", "&", "`", "$", ">", "<", "(", ")", "\n", "\r", "\\"
    ]

    private static let forbiddenGitFlags: Set<String> = [
        "-c", "--exec", "--output", "--ext-diff", "--textconv",
        "-f", "--force", "-d", "-D", "-m", "-M", "--delete", "--unset"
    ]

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var grants: [Entry] = []
    private var policy = ScopedApprovalPolicy()
    private var autoApprovedHistory: [AutoApprovedToolRecord] = []

    public init() {}

    public func scopedPolicy() -> ScopedApprovalPolicy {
        lock.withLock { policy }
    }

    public func setScopedPolicy(_ newPolicy: ScopedApprovalPolicy) {
        let normalizedPaths = Set(newPolicy.allowedProjectPaths.compactMap { raw -> String? in
            guard raw.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: raw).resolvingSymlinksInPath().standardizedFileURL.path
        })
        let sanitized = ScopedApprovalPolicy(
            autoApproveReadOnlyTools: newPolicy.autoApproveReadOnlyTools,
            applyToAllVerifiedProjects: newPolicy.applyToAllVerifiedProjects,
            allowedProjectPaths: normalizedPaths
        )
        let newlyApproved: [Entry] = lock.withLock {
            policy = sanitized
            guard sanitized.autoApproveReadOnlyTools else { return [] }
            return removeEntries { entry in
                guard !entry.isQuestion, let scope = entry.currentScope else { return false }
                let matchesProject = sanitized.applyToAllVerifiedProjects
                    || sanitized.allowedProjectPaths.contains(scope.projectPath)
                guard matchesProject,
                      Self.isSafeReadOnlyTool(toolName: entry.request.toolName, command: entry.request.toolName.caseInsensitiveCompare("Bash") == .orderedSame ? entry.request.summary : nil) else {
                    return false
                }
                recordAutoApprovalLocked(request: entry.request, projectPath: scope.projectPath, now: Date())
                return true
            }
        }
        if !newlyApproved.isEmpty {
            respond(to: newlyApproved, with: Reply(decision: "approve"))
        }
    }

    public func recentAutoApprovedRecords() -> [AutoApprovedToolRecord] {
        lock.withLock { autoApprovedHistory }
    }

    public static func isSafeReadOnlyTool(toolName: String, command: String?) -> Bool {
        let lowerTool = toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if directReadOnlyToolNames.contains(lowerTool) {
            return command == nil
        }
        guard lowerTool == "bash", let rawCommand = command else {
            return false
        }
        let trimmed = rawCommand.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 512 else { return false }
        for scalar in trimmed.unicodeScalars {
            if forbiddenShellScalars.contains(scalar) || unsafeScalar(scalar) {
                return false
            }
        }
        let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count >= 2, tokens[0] == "git" else { return false }
        for token in tokens.dropFirst() {
            if forbiddenGitFlags.contains(token)
                || token.hasPrefix("-c")
                || token.hasPrefix("--output=")
                || token.hasPrefix("--exec=") {
                return false
            }
        }
        let subcommand = tokens[1]
        switch subcommand {
        case "status", "diff", "log", "show":
            return true
        case "rev-parse":
            return tokens.dropFirst(2).allSatisfy {
                ["--abbrev-ref", "--short", "--show-toplevel", "--git-dir", "HEAD"].contains($0)
            }
        case "branch":
            return tokens.dropFirst(2) == ["--show-current"]
        default:
            return false
        }
    }

    public func pendingRequests() -> [PendingApprovalRequest] {
        lock.withLock { entries.map(\.request) }
    }

    /// Removes pending requests older than `maxAge` and notifies their responders with a block decision.
    @discardableResult
    public func pruneExpiredRequests(olderThan maxAge: TimeInterval = 180, now: Date = Date()) -> Int {
        guard maxAge.isFinite, maxAge > 0 else { return 0 }
        let expired: [Entry] = lock.withLock {
            grants.removeAll { $0.currentScope == nil }
            return removeEntries {
                now.timeIntervalSince($0.request.requestedAt) > maxAge || ($0.scope != nil && $0.currentScope == nil)
            }
        }
        respond(to: expired, with: Reply(decision: "block", reason: "Approval request expired"))
        return expired.count
    }

    public func canAutoApprove(request: PendingApprovalRequest) -> Bool {
        lock.withLock {
            entries.contains { $0.request == request && !$0.isQuestion && $0.currentScope != nil }
        }
    }

    public func activeAutoApproveRequests() -> [PendingApprovalRequest] {
        lock.withLock {
            grants.removeAll { $0.currentScope == nil }
            return grants.map(\.request)
        }
    }

    public func isSessionAutoApproved(for request: PendingApprovalRequest) -> Bool {
        lock.withLock {
            guard let entry = (entries + grants).first(where: { $0.request == request }),
                  let scope = entry.currentScope else { return false }
            return grants.contains { $0.currentScope == scope }
        }
    }

    public func matchesAgent(_ request: PendingApprovalRequest, agent: AgentObservation,
                             verifiedSessionID: String? = nil) -> Bool {
        guard request.agentName == agent.agentName, request.pid == agent.process.pid,
              let cwd = agent.process.cwd, cwd.hasPrefix("/"),
              request.projectPath == URL(fileURLWithPath: cwd).resolvingSymlinksInPath().standardizedFileURL.path,
              verifiedSessionID == nil || verifiedSessionID == request.sessionID else { return false }
        return lock.withLock {
            (entries + grants).contains {
                $0.request == request && $0.currentScope?.process == agent.process.identity
            }
        }
    }

    public func setSessionAutoApprove(_ enabled: Bool, for request: PendingApprovalRequest) {
        if enabled {
            _ = submitDecision(.allowForSession, forRequestID: request.id)
        } else {
            lock.withLock { grants.removeAll { $0.request == request } }
        }
    }

    @discardableResult
    public func submitDecision(_ decision: ApprovalDecision, forRequestID id: String) -> Bool {
        let result: ([Entry], Reply)? = lock.withLock {
            guard let index = entries.firstIndex(where: { $0.request.id == id }) else { return nil }
            let entry = entries[index]
            let scope = entry.currentScope
            let reply: Reply
            switch decision {
            case .allowOnce, .allowForSession:
                guard !entry.isQuestion, entry.scope == nil || scope != nil,
                      decision != .allowForSession || scope != nil else { return nil }
                reply = Reply(decision: "approve")
            case .deny(let reason):
                reply = Reply(decision: "block", reason: Self.clean(reason, limit: 1_024))
            case .answerQuestion(let option):
                guard entry.isQuestion, entry.scope == nil || scope != nil,
                      entry.request.questionOptions.contains(option) else { return nil }
                reply = Reply(decision: "approve", answer: option)
            }
            entries.remove(at: index)
            var resolved = [entry]
            if decision == .allowForSession, let scope {
                grants.removeAll { $0.currentScope == nil || $0.scope == scope }
                if grants.count == 50 { grants.removeFirst() }
                // Retain the scope and revalidation, not the original response callback.
                grants.append(Entry(request: entry.request, isQuestion: false, responder: nil,
                                    scope: scope, isScopeCurrent: entry.isScopeCurrent))
                resolved += removeEntries { !$0.isQuestion && $0.currentScope == scope }
            }
            return (resolved, reply)
        }
        guard let (resolved, reply) = result else { return false }
        respond(to: resolved, with: reply)
        return true
    }

    /// Accepts at most 64 KiB and keeps at most 50 pending requests.
    @discardableResult
    public func ingestHookEvent(_ data: Data, now: Date = Date(),
                                responder: (@Sendable (Data) -> Void)? = nil) -> PendingApprovalRequest? {
        ingestHookEvent(data, scope: nil, now: now, responder: responder)
    }

    @discardableResult
    func ingestHookEvent(_ data: Data, scope: ApprovalScope?, now: Date = Date(),
                         isScopeCurrent: @escaping @Sendable () -> Bool = { false },
                         responder: (@Sendable (Data) -> Void)? = nil) -> PendingApprovalRequest? {
        guard data.count <= 65_536,
              let hook = try? JSONDecoder().decode(Hook.self, from: data),
              Self.validSessionID(hook.session_id) else {
            responder?(Reply(decision: "block", reason: "Invalid hook event").data)
            return nil
        }
        if hook.hook_event_name == .stop {
            guard let scope, scope.sessionID == hook.session_id, isScopeCurrent() else { return nil }
            let cancelled = lock.withLock {
                removeEntries { $0.scope == scope && $0.request.requestedAt <= now }
            }
            respond(to: cancelled, with: Reply(decision: "block", reason: "Agent turn stopped"))
            return nil
        }
        guard hook.hook_event_name == .permissionRequest || hook.hook_event_name == .preToolUse else { return nil }
        if hook.hook_event_name == .preToolUse && hook.requires_approval == false { return nil }
        if let scope {
            guard scope.sessionID == hook.session_id, scope.process.pid == hook.pid,
                  scope.projectPath == hook.cwd, hook.agent_name == "Claude Code", isScopeCurrent() else {
                responder?(Reply(decision: "block", reason: "Hook session ended").data)
                return nil
            }
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
        let rawCommand = input?.command
        let immediate: Reply? = lock.withLock {
            if let scope {
                guard isScopeCurrent() else { return Reply(decision: "block", reason: "Hook session ended") }
                if !isQuestion && grants.contains(where: { $0.currentScope == scope }) {
                    return Reply(decision: "approve")
                }
                if !isQuestion, policy.autoApproveReadOnlyTools {
                    let projectAllowed = policy.applyToAllVerifiedProjects
                        || policy.allowedProjectPaths.contains(scope.projectPath)
                    if projectAllowed && Self.isSafeReadOnlyTool(toolName: toolName, command: rawCommand) {
                        recordAutoApprovalLocked(request: request, projectPath: scope.projectPath, now: now)
                        return Reply(decision: "approve")
                    }
                }
            }
            guard entries.count < 50 else {
                return Reply(decision: "block", reason: "Approval queue is full")
            }
            entries.append(Entry(request: request, isQuestion: isQuestion, responder: responder,
                                 scope: scope, isScopeCurrent: isScopeCurrent))
            return nil
        }
        if let immediate {
            responder?(immediate.data)
            return nil
        }
        return request
    }

    private func recordAutoApprovalLocked(request: PendingApprovalRequest, projectPath: String, now: Date) {
        let record = AutoApprovedToolRecord(
            id: request.id,
            agentName: request.agentName,
            toolName: request.toolName,
            projectPath: projectPath,
            summary: request.summary,
            approvedAt: now
        )
        autoApprovedHistory.insert(record, at: 0)
        if autoApprovedHistory.count > 30 {
            autoApprovedHistory.removeLast(autoApprovedHistory.count - 30)
        }
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

    static func validSessionID(_ value: String) -> Bool {
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
