import Darwin
import Foundation
import SQLite3

public enum SessionProviderKind: String, Codable, CaseIterable, Equatable, Sendable {
    case claude = "Claude Code"
    case codex = "Codex"
    case openCode = "OpenCode"
    case cursor = "Cursor"
    case gemini = "Gemini CLI"
    case other = "Other"

    public var shortLabel: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .openCode: return "OpenCode"
        case .cursor: return "Cursor"
        case .gemini: return "Gemini"
        case .other: return "Other"
        }
    }

    public static func from(agentName: String) -> SessionProviderKind {
        let lower = agentName.lowercased()
        if lower.contains("claude") { return .claude }
        if lower.contains("codex") { return .codex }
        if lower.contains("opencode") || lower.contains("open-code") { return .openCode }
        if lower.contains("cursor") || lower.contains("windsurf") { return .cursor }
        if lower.contains("gemini") { return .gemini }
        return .other
    }
}

public struct SessionChatTurn: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case user
        case assistant
        case toolCall
    }

    public let id: String
    public let kind: Kind
    public let text: String
    public let toolName: String?
    public let toolStatus: String?
    public let timestamp: Date?

    public init(
        id: String,
        kind: Kind,
        text: String,
        toolName: String? = nil,
        toolStatus: String? = nil,
        timestamp: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.toolName = toolName
        self.toolStatus = toolStatus
        self.timestamp = timestamp
    }
}

public struct IndexedAgentSession: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let provider: SessionProviderKind
    public let agentName: String
    public let sessionID: String?
    public let title: String
    public let projectPath: String?
    public let projectName: String
    public let gitBranch: String?
    public let sourcePath: String?
    public let updatedAt: Date?
    public let isLive: Bool
    public let liveObservation: AgentObservation?
    public let canResumeNatively: Bool
    public let nativeSteerMode: AgentSteerMode?
    public let liveSteerMode: AgentSteerMode?
    public let lastMessageSnippet: String?
    public let turnCount: Int

    public init(
        id: String,
        provider: SessionProviderKind,
        agentName: String,
        sessionID: String? = nil,
        title: String,
        projectPath: String? = nil,
        projectName: String,
        gitBranch: String? = nil,
        sourcePath: String? = nil,
        updatedAt: Date? = nil,
        isLive: Bool = false,
        liveObservation: AgentObservation? = nil,
        canResumeNatively: Bool = false,
        nativeSteerMode: AgentSteerMode? = nil,
        liveSteerMode: AgentSteerMode? = nil,
        lastMessageSnippet: String? = nil,
        turnCount: Int = 0
    ) {
        self.id = id
        self.provider = provider
        self.agentName = agentName
        self.sessionID = sessionID
        self.title = title
        self.projectPath = projectPath
        self.projectName = projectName
        self.gitBranch = gitBranch
        self.sourcePath = sourcePath
        self.updatedAt = updatedAt
        self.isLive = isLive
        self.liveObservation = liveObservation
        self.canResumeNatively = canResumeNatively
        self.nativeSteerMode = nativeSteerMode
        self.liveSteerMode = liveSteerMode
        self.lastMessageSnippet = lastMessageSnippet
        self.turnCount = turnCount
    }

    public var canSteerInLiveTerminal: Bool {
        liveSteerMode?.isLiveTerminalDelivery == true
    }

    public var canSendInstruction: Bool {
        canSteerInLiveTerminal || canResumeNatively
    }
}

/// Discovers both live and historical coding agent sessions across Claude Code, Codex,
/// OpenCode, Cursor, and Gemini CLI, correlates live OS processes to their workspace
/// session files, and loads full multi-turn conversation & tool-call streams.
public struct WorkspaceSessionIndexer: Sendable {
    private let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory.standardizedFileURL
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

    /// Preserves readable multi-line formatting while stripping control bytes and redacting tokens.
    public static func sanitizeMultilineText(_ raw: String, maxLength: Int = 2_400) -> String? {
        guard maxLength > 0 else { return nil }
        let normalizedNewlines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var scalars = String.UnicodeScalarView()
        for scalar in normalizedNewlines.unicodeScalars {
            if scalar == "\n" || scalar == "\t" {
                scalars.append(scalar)
            } else if !CharacterSet.controlCharacters.contains(scalar) {
                scalars.append(scalar)
            }
        }
        var cleaned = String(scalars)
        for regex in secretPatterns {
            cleaned = regex.stringByReplacingMatches(
                in: cleaned,
                range: NSRange(cleaned.startIndex..., in: cleaned),
                withTemplate: "[REDACTED]"
            )
        }
        // Collapse 3+ consecutive blank lines down to 2 for clean chat bubbles.
        while cleaned.contains("\n\n\n") {
            cleaned = cleaned.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        if cleaned.count > maxLength {
            return String(cleaned.prefix(maxLength - 1)) + "…"
        }
        return cleaned
    }

    public static func isNoiseUserPrompt(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let noisePrefixes = [
            "<local-command",
            "<command-name>",
            "<command-message>",
            "<system-reminder>",
            "<environment_context>",
            "<user_instructions>",
            "Caveat: The messages below were generated by the user while running local commands"
        ]
        return noisePrefixes.contains { trimmed.hasPrefix($0) }
    }

    // MARK: - Session Discovery & Live Correlation

    public func indexSessions(
        liveAgents: [AgentObservation],
        allProcesses: [ObservedProcess] = [],
        maxPerProvider: Int = 36
    ) -> [IndexedAgentSession] {
        let cap = max(4, min(maxPerProvider, 120))
        var diskSessions: [IndexedAgentSession] = []
        diskSessions.append(contentsOf: discoverClaudeSessions(limit: cap))
        diskSessions.append(contentsOf: discoverCodexSessions(limit: cap))
        diskSessions.append(contentsOf: discoverOpenCodeSessions(limit: cap))
        diskSessions.append(contentsOf: discoverGeminiSessions(limit: max(8, cap / 2)))
        diskSessions.append(contentsOf: discoverCursorSessions(limit: max(8, cap / 2)))

        // Sort disk sessions newest first so live process correlation picks the freshest match.
        diskSessions.sort { lhs, rhs in
            let lDate = lhs.updatedAt ?? .distantPast
            let rDate = rhs.updatedAt ?? .distantPast
            if lDate != rDate { return lDate > rDate }
            return lhs.id < rhs.id
        }

        var matchedDiskIndices = Set<Int>()
        var correlatedResults: [IndexedAgentSession] = []

        // Count live agents per (provider, canonicalProject) so ambiguous multi-instance
        // directories never guess which transcript belongs to which terminal.
        var liveCountByProviderAndDir: [String: Int] = [:]
        for obs in liveAgents {
            let provider = SessionProviderKind.from(agentName: obs.agentName)
            if let dir = canonicalExistingDirectory(obs.project?.rootPath ?? obs.process.cwd) {
                liveCountByProviderAndDir["\(provider.rawValue)\0\(dir)", default: 0] += 1
            }
        }

        for obs in liveAgents {
            let provider = SessionProviderKind.from(agentName: obs.agentName)
            let canonicalObsProject = canonicalExistingDirectory(obs.project?.rootPath ?? obs.process.cwd)
            let liveSteer = AgentSteerer.preferredMode(for: obs)

            var bestMatchIndex: Int?
            let explicitID = obs.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let explicitID, !explicitID.isEmpty {
                // 1. Exact sessionID match only — never fall back to another session's transcript
                // when we already know this live process's session identifier.
                bestMatchIndex = diskSessions.indices.first { idx in
                    !matchedDiskIndices.contains(idx)
                        && diskSessions[idx].provider == provider
                        && diskSessions[idx].sessionID?.lowercased() == explicitID.lowercased()
                }
            } else if let canonicalObsProject,
                      liveCountByProviderAndDir["\(provider.rawValue)\0\(canonicalObsProject)"] == 1 {
                // 2. Unambiguous single-instance exact directory match, and only if the session
                // file has been active since (within 60s of) the live process start time.
                let realEpochCutoffMicros: UInt64 = 1_000_000_000_000_000 // ~2001-09-09; synthetic test values are small
                let earliestPlausibleUpdate: Date? = {
                    guard let micros = obs.process.startTimeMicroseconds, micros >= realEpochCutoffMicros else {
                        return nil
                    }
                    return Date(timeIntervalSince1970: Double(micros) / 1_000_000).addingTimeInterval(-60)
                }()
                bestMatchIndex = diskSessions.indices.first { idx in
                    guard !matchedDiskIndices.contains(idx),
                          diskSessions[idx].provider == provider,
                          diskSessions[idx].projectPath == canonicalObsProject else { return false }
                    if let earliestPlausibleUpdate, let updatedAt = diskSessions[idx].updatedAt,
                       updatedAt < earliestPlausibleUpdate {
                        return false
                    }
                    return true
                }
            }

            if let idx = bestMatchIndex {
                matchedDiskIndices.insert(idx)
                let disk = diskSessions[idx]
                let mergedProjectPath = disk.projectPath ?? canonicalObsProject
                let mergedProjectName = obs.project?.name
                    ?? mergedProjectPath.map { URL(fileURLWithPath: $0).lastPathComponent }
                    ?? disk.projectName
                let mergedBranch = obs.project?.gitBranch ?? disk.gitBranch
                let mergedUpdated = maxDate(obs.lastActivityAt, disk.updatedAt)
                let mergedSnippet = obs.currentTask ?? disk.lastMessageSnippet
                correlatedResults.append(
                    IndexedAgentSession(
                        id: disk.id,
                        provider: disk.provider,
                        agentName: obs.agentName,
                        sessionID: disk.sessionID ?? obs.sessionID,
                        title: obs.sessionTitle ?? disk.title,
                        projectPath: mergedProjectPath,
                        projectName: mergedProjectName,
                        gitBranch: mergedBranch,
                        sourcePath: disk.sourcePath,
                        updatedAt: mergedUpdated,
                        isLive: true,
                        liveObservation: obs,
                        canResumeNatively: disk.canResumeNatively,
                        nativeSteerMode: disk.nativeSteerMode,
                        liveSteerMode: liveSteer,
                        lastMessageSnippet: mergedSnippet,
                        turnCount: disk.turnCount
                    )
                )
            } else {
                let fallbackProjectName = obs.project?.name
                    ?? canonicalObsProject.map { URL(fileURLWithPath: $0).lastPathComponent }
                    ?? "Workspace"
                let fallbackTitle = obs.sessionTitle
                    ?? obs.currentTask
                    ?? "\(obs.agentName) · \(fallbackProjectName)"
                let validID = obs.sessionID.flatMap { AgentContextValidation.sessionID($0) }
                let nativeMode = Self.nativeResumeMode(for: provider)
                let canResume = validID != nil && canonicalObsProject != nil && nativeMode != nil
                correlatedResults.append(
                    IndexedAgentSession(
                        id: "live-\(obs.id)",
                        provider: provider,
                        agentName: obs.agentName,
                        sessionID: validID,
                        title: fallbackTitle,
                        projectPath: canonicalObsProject,
                        projectName: fallbackProjectName,
                        gitBranch: obs.project?.gitBranch,
                        sourcePath: nil,
                        updatedAt: obs.lastActivityAt ?? Date(),
                        isLive: true,
                        liveObservation: obs,
                        canResumeNatively: canResume,
                        nativeSteerMode: canResume ? nativeMode : nil,
                        liveSteerMode: liveSteer,
                        lastMessageSnippet: obs.currentTask ?? obs.activityDetail,
                        turnCount: 0
                    )
                )
            }
        }

        for (idx, disk) in diskSessions.enumerated() where !matchedDiskIndices.contains(idx) {
            correlatedResults.append(disk)
        }

        return correlatedResults.sorted { lhs, rhs in
            if lhs.isLive != rhs.isLive {
                return lhs.isLive
            }
            if lhs.isLive && rhs.isLive {
                let lRank = Self.liveActivityRank(lhs.liveObservation?.activityState)
                let rRank = Self.liveActivityRank(rhs.liveObservation?.activityState)
                if lRank != rRank { return lRank < rRank }
            }
            let lDate = lhs.updatedAt ?? .distantPast
            let rDate = rhs.updatedAt ?? .distantPast
            if lDate != rDate { return lDate > rDate }
            return lhs.id < rhs.id
        }
    }

    private static func liveActivityRank(_ state: AgentActivityState?) -> Int {
        switch state {
        case .waiting: return 0
        case .active: return 1
        case .idle, .none: return 2
        case .stopped: return 3
        }
    }

    private static func nativeResumeMode(for provider: SessionProviderKind) -> AgentSteerMode? {
        switch provider {
        case .claude: return .claudeResume
        case .codex: return .codexResume
        case .openCode: return .openCodeSession
        case .cursor, .gemini, .other: return nil
        }
    }

    // MARK: - Conversation & Tool Stream Loading

    public func loadConversationTurns(
        for session: IndexedAgentSession,
        allProcesses: [ObservedProcess] = [],
        maxTurns: Int = 60
    ) -> [SessionChatTurn] {
        let cap = max(6, min(maxTurns, 150))
        var turns: [SessionChatTurn] = []

        switch session.provider {
        case .claude:
            if let sourcePath = session.sourcePath {
                turns = loadClaudeTurns(at: URL(fileURLWithPath: sourcePath), maxTurns: cap)
            } else if let sessionID = session.sessionID, let found = findClaudeFile(sessionID: sessionID) {
                turns = loadClaudeTurns(at: found, maxTurns: cap)
            }
        case .codex:
            if let sourcePath = session.sourcePath {
                turns = loadCodexTurns(at: URL(fileURLWithPath: sourcePath), maxTurns: cap)
            } else if let sessionID = session.sessionID, let found = findCodexFile(sessionID: sessionID) {
                turns = loadCodexTurns(at: found, maxTurns: cap)
            }
        case .openCode:
            if let sessionID = session.sessionID {
                turns = loadOpenCodeTurns(sessionID: sessionID, maxTurns: cap)
            }
        case .gemini:
            if let sourcePath = session.sourcePath {
                turns = loadGeminiTurns(at: URL(fileURLWithPath: sourcePath), maxTurns: cap)
            }
        case .cursor, .other:
            break
        }

        if let obs = session.liveObservation,
           let running = liveRunningToolTurn(for: obs, allProcesses: allProcesses) {
            let alreadyShown = turns.suffix(3).contains {
                $0.kind == .toolCall && $0.toolStatus == "running" && $0.toolName == running.toolName
            }
            if !alreadyShown {
                turns.append(running)
            }
        }

        if turns.count > cap {
            turns = Array(turns.suffix(cap))
        }
        return turns
    }

    // MARK: - Claude Code Discovery & Turn Parsing

    private func discoverClaudeSessions(limit: Int) -> [IndexedAgentSession] {
        let root = homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true)
        let files = collectJSONLFiles(under: root, exactDepth: 1, maxCandidates: limit * 3)
        var sessions: [IndexedAgentSession] = []
        var seenIDs = Set<String>()

        for file in files.prefix(limit) {
            guard let chunk = readHeadAndTailRecords(url: file.url, headBytes: 24 * 1_024, tailBytes: 32 * 1_024) else {
                continue
            }
            let stem = file.url.deletingPathExtension().lastPathComponent
            let records = chunk.header + chunk.tail
            guard !records.isEmpty else { continue }

            var sessionID: String? = UUID(uuidString: stem)?.uuidString.lowercased()
            var cwd: String?
            var gitBranch: String?
            var customTitle: String?
            var firstUserPrompt: String?
            var lastSnippet: String?
            var turnCount = 0

            for record in records {
                if let rawID = record["sessionId"] as? String,
                   let valid = AgentContextValidation.sessionID(rawID) {
                    sessionID = valid
                }
                if cwd == nil, let rawCwd = record["cwd"] as? String {
                    cwd = rawCwd
                }
                if let branch = record["gitBranch"] as? String, !branch.isEmpty, branch != "HEAD" {
                    gitBranch = SessionTurnPreviewInspector.sanitizeAndRedact(branch, maxLength: 64)
                }
                if let title = record["customTitle"] as? String,
                   let clean = SessionTurnPreviewInspector.sanitizeAndRedact(title, maxLength: 96) {
                    customTitle = clean
                } else if record["type"] as? String == "summary",
                          let summary = record["summary"] as? String,
                          let clean = SessionTurnPreviewInspector.sanitizeAndRedact(summary, maxLength: 96) {
                    customTitle = clean
                }

                guard record["isSidechain"] as? Bool != true, record["isMeta"] as? Bool != true else { continue }
                let type = record["type"] as? String
                if type == "user" || type == "assistant",
                   let message = record["message"] as? [String: Any],
                   let text = extractClaudeMessageText(message["content"]) {
                    if type == "user" && Self.isNoiseUserPrompt(text) {
                        continue
                    }
                    turnCount += 1
                    if type == "user", firstUserPrompt == nil {
                        firstUserPrompt = SessionTurnPreviewInspector.sanitizeAndRedact(text, maxLength: 96)
                    }
                    if let snippet = SessionTurnPreviewInspector.sanitizeAndRedact(text, maxLength: 140) {
                        lastSnippet = snippet
                    }
                }
            }

            guard let validSessionID = sessionID.flatMap({ AgentContextValidation.sessionID($0) }),
                  seenIDs.insert(validSessionID).inserted else { continue }
            guard turnCount > 0 || customTitle != nil else { continue }

            let canonicalProject = canonicalExistingDirectory(cwd)
            let fallbackPath = cwd.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0).standardizedFileURL.path : nil }
            let effectiveProjectPath = canonicalProject ?? fallbackPath
            let projectName = effectiveProjectPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Claude Project"
            let title = customTitle ?? firstUserPrompt ?? "Session \(validSessionID.prefix(8))"
            let canResume = canonicalProject != nil && UUID(uuidString: validSessionID) != nil

            sessions.append(
                IndexedAgentSession(
                    id: "claude:\(validSessionID)",
                    provider: .claude,
                    agentName: "Claude Code",
                    sessionID: validSessionID,
                    title: title,
                    projectPath: effectiveProjectPath,
                    projectName: projectName,
                    gitBranch: gitBranch,
                    sourcePath: file.url.path,
                    updatedAt: file.modifiedAt,
                    isLive: false,
                    liveObservation: nil,
                    canResumeNatively: canResume,
                    nativeSteerMode: canResume ? .claudeResume : nil,
                    liveSteerMode: nil,
                    lastMessageSnippet: lastSnippet,
                    turnCount: max(1, turnCount)
                )
            )
        }
        return sessions
    }

    private func loadClaudeTurns(at url: URL, maxTurns: Int) -> [SessionChatTurn] {
        guard let records = readTailRecordsForConversation(url: url, maxBytes: 256 * 1_024) else { return [] }
        var turns: [SessionChatTurn] = []
        var toolTurnIndexByCallID: [String: Int] = [:]
        var counter = 0

        for record in records {
            guard record["isSidechain"] as? Bool != true, record["isMeta"] as? Bool != true else { continue }
            guard let type = record["type"] as? String,
                  (type == "user" || type == "assistant"),
                  let message = record["message"] as? [String: Any] else { continue }
            let timestamp = QuotaParsing.date(record["timestamp"])

            if type == "user" {
                if let blocks = message["content"] as? [[String: Any]] {
                    for block in blocks where block["type"] as? String == "tool_result" {
                        if let callID = block["tool_use_id"] as? String,
                           let idx = toolTurnIndexByCallID[callID] {
                            let failed = (block["is_error"] as? Bool) == true
                            let existing = turns[idx]
                            turns[idx] = SessionChatTurn(
                                id: existing.id,
                                kind: .toolCall,
                                text: existing.text,
                                toolName: existing.toolName,
                                toolStatus: failed ? "failed" : "completed",
                                timestamp: existing.timestamp
                            )
                        }
                    }
                }
                if let rawText = extractClaudeMessageText(message["content"]),
                   !Self.isNoiseUserPrompt(rawText),
                   let clean = Self.sanitizeMultilineText(rawText) {
                    counter += 1
                    turns.append(SessionChatTurn(id: "u-\(counter)", kind: .user, text: clean, timestamp: timestamp))
                }
            } else if type == "assistant" {
                if let rawStr = message["content"] as? String,
                   let clean = Self.sanitizeMultilineText(rawStr) {
                    counter += 1
                    turns.append(SessionChatTurn(id: "a-\(counter)", kind: .assistant, text: clean, timestamp: timestamp))
                } else if let blocks = message["content"] as? [[String: Any]] {
                    for block in blocks {
                        let bType = (block["type"] as? String) ?? "text"
                        if bType == "text" || bType == "output_text" || bType == "input_text" {
                            if let rawText = block["text"] as? String,
                               let clean = Self.sanitizeMultilineText(rawText) {
                                counter += 1
                                turns.append(SessionChatTurn(id: "a-\(counter)", kind: .assistant, text: clean, timestamp: timestamp))
                            }
                        } else if bType == "tool_use" {
                            guard let rawTool = block["name"] as? String,
                                  let toolName = SessionTurnPreviewInspector.sanitizeAndRedact(rawTool, maxLength: 64) else {
                                continue
                            }
                            let input = block["input"] as? [String: Any]
                            let summary = extractToolTargetSummary(from: input) ?? toolName
                            counter += 1
                            let callID = (block["id"] as? String) ?? "t-\(counter)"
                            let idx = turns.count
                            turns.append(
                                SessionChatTurn(
                                    id: "tool-\(counter)",
                                    kind: .toolCall,
                                    text: summary,
                                    toolName: toolName,
                                    toolStatus: "completed",
                                    timestamp: timestamp
                                )
                            )
                            toolTurnIndexByCallID[callID] = idx
                        }
                    }
                }
            }
        }
        return Array(turns.suffix(maxTurns))
    }

    private func extractClaudeMessageText(_ rawContent: Any?) -> String? {
        if let str = rawContent as? String {
            return str
        }
        guard let blocks = rawContent as? [[String: Any]] else { return nil }
        let parts = blocks.compactMap { block -> String? in
            let type = (block["type"] as? String) ?? "text"
            guard type == "text" || type == "input_text" || type == "output_text" else { return nil }
            return block["text"] as? String
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Codex Discovery & Turn Parsing

    private func discoverCodexSessions(limit: Int) -> [IndexedAgentSession] {
        let sessionsRoot = homeDirectory.appendingPathComponent(".codex/sessions", isDirectory: true)
        let archivedRoot = homeDirectory.appendingPathComponent(".codex/archived_sessions", isDirectory: true)
        let activeFiles = collectJSONLFiles(under: sessionsRoot, exactDepth: 3, maxCandidates: limit * 3)
        let archivedFiles = collectJSONLFiles(under: archivedRoot, exactDepth: 0, maxCandidates: limit)
        let allFiles = (activeFiles + archivedFiles).sorted { $0.modifiedAt > $1.modifiedAt }

        var sessions: [IndexedAgentSession] = []
        var seenIDs = Set<String>()

        for file in allFiles.prefix(limit) {
            guard let chunk = readHeadAndTailRecords(url: file.url, headBytes: 16 * 1_024, tailBytes: 32 * 1_024) else {
                continue
            }
            let records = chunk.header + chunk.tail
            guard !records.isEmpty else { continue }

            var sessionID: String?
            var cwd: String?
            var gitBranch: String?
            var firstUserPrompt: String?
            var lastSnippet: String?
            var turnCount = 0

            for record in records {
                let type = record["type"] as? String
                if type == "session_meta", let payload = record["payload"] as? [String: Any] {
                    if let rawID = payload["id"] as? String, let uuid = UUID(uuidString: rawID) {
                        sessionID = uuid.uuidString.lowercased()
                    }
                    if let rawCwd = payload["cwd"] as? String {
                        cwd = rawCwd
                    }
                    if let gitDict = payload["git"] as? [String: Any],
                       let branch = gitDict["branch"] as? String, !branch.isEmpty {
                        gitBranch = SessionTurnPreviewInspector.sanitizeAndRedact(branch, maxLength: 64)
                    }
                } else if type == "event_msg", let payload = record["payload"] as? [String: Any],
                          let msg = payload["message"] as? String {
                    let msgType = payload["type"] as? String
                    if (msgType == "user_message" || msgType == "agent_message"), !Self.isNoiseUserPrompt(msg) {
                        turnCount += 1
                        if msgType == "user_message", firstUserPrompt == nil {
                            firstUserPrompt = SessionTurnPreviewInspector.sanitizeAndRedact(msg, maxLength: 96)
                        }
                        if let snippet = SessionTurnPreviewInspector.sanitizeAndRedact(msg, maxLength: 140) {
                            lastSnippet = snippet
                        }
                    }
                } else if type == "response_item", let payload = record["payload"] as? [String: Any],
                          payload["type"] as? String == "message" {
                    let role = payload["role"] as? String
                    if (role == "user" || role == "assistant"),
                       let text = extractClaudeMessageText(payload["content"]),
                       !Self.isNoiseUserPrompt(text) {
                        turnCount += 1
                        if role == "user", firstUserPrompt == nil {
                            firstUserPrompt = SessionTurnPreviewInspector.sanitizeAndRedact(text, maxLength: 96)
                        }
                        if let snippet = SessionTurnPreviewInspector.sanitizeAndRedact(text, maxLength: 140) {
                            lastSnippet = snippet
                        }
                    }
                }
            }

            if sessionID == nil {
                sessionID = Self.extractRolloutUUID(from: file.url)?.uuidString.lowercased()
            }
            guard let validID = sessionID.flatMap({ AgentContextValidation.sessionID($0) }),
                  seenIDs.insert(validID).inserted else { continue }

            let canonicalProject = canonicalExistingDirectory(cwd)
            let fallbackPath = cwd.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0).standardizedFileURL.path : nil }
            let effectiveProjectPath = canonicalProject ?? fallbackPath
            let projectName = effectiveProjectPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Codex Workspace"
            let title = firstUserPrompt ?? "Codex · \(projectName)"
            let canResume = canonicalProject != nil && UUID(uuidString: validID) != nil

            sessions.append(
                IndexedAgentSession(
                    id: "codex:\(validID)",
                    provider: .codex,
                    agentName: "Codex",
                    sessionID: validID,
                    title: title,
                    projectPath: effectiveProjectPath,
                    projectName: projectName,
                    gitBranch: gitBranch,
                    sourcePath: file.url.path,
                    updatedAt: file.modifiedAt,
                    isLive: false,
                    liveObservation: nil,
                    canResumeNatively: canResume,
                    nativeSteerMode: canResume ? .codexResume : nil,
                    liveSteerMode: nil,
                    lastMessageSnippet: lastSnippet,
                    turnCount: max(1, turnCount)
                )
            )
        }
        return sessions
    }

    private func loadCodexTurns(at url: URL, maxTurns: Int) -> [SessionChatTurn] {
        guard let records = readTailRecordsForConversation(url: url, maxBytes: 256 * 1_024) else { return [] }
        var turns: [SessionChatTurn] = []
        var toolTurnIndexByCallID: [String: Int] = [:]
        var counter = 0

        func appendUniqueMessage(kind: SessionChatTurn.Kind, rawText: String, timestamp: Date?) {
            guard !Self.isNoiseUserPrompt(rawText),
                  let clean = Self.sanitizeMultilineText(rawText) else { return }
            if let last = turns.last, last.kind == kind, last.text == clean {
                return
            }
            counter += 1
            let prefix = kind == .user ? "u" : "a"
            turns.append(SessionChatTurn(id: "\(prefix)-\(counter)", kind: kind, text: clean, timestamp: timestamp))
        }

        for record in records {
            let timestamp = QuotaParsing.date(record["timestamp"])
            let recordType = record["type"] as? String

            if recordType == "event_msg", let payload = record["payload"] as? [String: Any],
               let msg = payload["message"] as? String {
                let pType = payload["type"] as? String
                if pType == "user_message" {
                    appendUniqueMessage(kind: .user, rawText: msg, timestamp: timestamp)
                } else if pType == "agent_message" {
                    appendUniqueMessage(kind: .assistant, rawText: msg, timestamp: timestamp)
                }
            } else if recordType == "response_item", let payload = record["payload"] as? [String: Any] {
                switch payload["type"] as? String {
                case "message":
                    let role = payload["role"] as? String
                    if let rawText = extractClaudeMessageText(payload["content"]) {
                        if role == "user" {
                            appendUniqueMessage(kind: .user, rawText: rawText, timestamp: timestamp)
                        } else if role == "assistant" {
                            appendUniqueMessage(kind: .assistant, rawText: rawText, timestamp: timestamp)
                        }
                    }
                case "function_call", "custom_tool_call":
                    guard let rawName = payload["name"] as? String,
                          let toolName = SessionTurnPreviewInspector.sanitizeAndRedact(rawName, maxLength: 64) else {
                        continue
                    }
                    var argsDict = payload["arguments"] as? [String: Any]
                    if argsDict == nil, let rawArgs = payload["arguments"] as? String,
                       let data = rawArgs.data(using: .utf8) {
                        argsDict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    }
                    let summary = extractToolTargetSummary(from: argsDict) ?? toolName
                    counter += 1
                    let callID = (payload["call_id"] as? String) ?? "c-\(counter)"
                    let idx = turns.count
                    turns.append(
                        SessionChatTurn(
                            id: "tool-\(counter)",
                            kind: .toolCall,
                            text: summary,
                            toolName: toolName,
                            toolStatus: "completed",
                            timestamp: timestamp
                        )
                    )
                    toolTurnIndexByCallID[callID] = idx
                case "function_call_output", "custom_tool_call_output":
                    if let callID = payload["call_id"] as? String,
                       let idx = toolTurnIndexByCallID[callID] {
                        let failed = ["failed", "error"].contains((payload["status"] as? String ?? "").lowercased())
                        let existing = turns[idx]
                        turns[idx] = SessionChatTurn(
                            id: existing.id,
                            kind: .toolCall,
                            text: existing.text,
                            toolName: existing.toolName,
                            toolStatus: failed ? "failed" : "completed",
                            timestamp: existing.timestamp
                        )
                    }
                default:
                    break
                }
            }
        }
        return Array(turns.suffix(maxTurns))
    }

    private static func extractRolloutUUID(from url: URL) -> UUID? {
        let stem = url.deletingPathExtension().lastPathComponent
        if let uuid = UUID(uuidString: stem) { return uuid }
        guard stem.count >= 36 else { return nil }
        let suffix = String(stem.suffix(36))
        return UUID(uuidString: suffix)
    }

    // MARK: - OpenCode Discovery & Turn Parsing

    private func discoverOpenCodeSessions(limit: Int) -> [IndexedAgentSession] {
        var sessions: [IndexedAgentSession] = []
        var seenIDs = Set<String>()

        let dbURL = homeDirectory.appendingPathComponent(".local/share/opencode/opencode.db")
        if let dbRows = queryOpenCodeSessionsFromSQLite(at: dbURL, limit: limit) {
            for row in dbRows where seenIDs.insert(row.sessionID).inserted {
                let canonical = canonicalExistingDirectory(row.directory)
                let projectName = (canonical ?? row.directory).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "OpenCode"
                let canResume = canonical != nil && row.sessionID.hasPrefix("ses_")
                sessions.append(
                    IndexedAgentSession(
                        id: "opencode:\(row.sessionID)",
                        provider: .openCode,
                        agentName: "OpenCode",
                        sessionID: row.sessionID,
                        title: row.title ?? "OpenCode · \(projectName)",
                        projectPath: canonical ?? row.directory,
                        projectName: projectName,
                        gitBranch: nil,
                        sourcePath: dbURL.path,
                        updatedAt: row.updatedAt,
                        isLive: false,
                        liveObservation: nil,
                        canResumeNatively: canResume,
                        nativeSteerMode: canResume ? .openCodeSession : nil,
                        liveSteerMode: nil,
                        lastMessageSnippet: row.title,
                        turnCount: 1
                    )
                )
            }
        }

        // JSON storage fallback (~/.local/share/opencode/storage/session/<project>/<ses_*.json>)
        let storageSessionRoot = homeDirectory.appendingPathComponent(".local/share/opencode/storage/session", isDirectory: true)
        let jsonFiles = collectFiles(under: storageSessionRoot, extensions: ["json"], maxDepth: 2, maxCandidates: limit * 2)
        for file in jsonFiles where sessions.count < limit {
            guard let dict = readJSONDictionary(at: file.url),
                  let rawID = (dict["id"] as? String) ?? (dict["sessionID"] as? String),
                  let sessionID = AgentContextValidation.sessionID(rawID),
                  seenIDs.insert(sessionID).inserted else { continue }
            let rawDir = (dict["directory"] as? String) ?? (dict["cwd"] as? String)
            let canonical = canonicalExistingDirectory(rawDir)
            let projectName = (canonical ?? rawDir).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "OpenCode"
            let title = (dict["title"] as? String).flatMap { SessionTurnPreviewInspector.sanitizeAndRedact($0, maxLength: 96) }
                ?? "OpenCode · \(projectName)"
            let updatedAt: Date? = {
                if let timeDict = dict["time"] as? [String: Any],
                   let ms = QuotaParsing.number(timeDict["updated"] ?? timeDict["created"]) {
                    return Date(timeIntervalSince1970: ms > 10_000_000_000 ? ms / 1_000 : ms)
                }
                return file.modifiedAt
            }()
            let canResume = canonical != nil && sessionID.hasPrefix("ses_")
            sessions.append(
                IndexedAgentSession(
                    id: "opencode:\(sessionID)",
                    provider: .openCode,
                    agentName: "OpenCode",
                    sessionID: sessionID,
                    title: title,
                    projectPath: canonical ?? rawDir,
                    projectName: projectName,
                    gitBranch: nil,
                    sourcePath: file.url.path,
                    updatedAt: updatedAt,
                    isLive: false,
                    liveObservation: nil,
                    canResumeNatively: canResume,
                    nativeSteerMode: canResume ? .openCodeSession : nil,
                    liveSteerMode: nil,
                    lastMessageSnippet: title,
                    turnCount: 1
                )
            )
        }
        return sessions
    }

    private struct OpenCodeSessionRow {
        let sessionID: String
        let title: String?
        let directory: String?
        let updatedAt: Date?
    }

    private func queryOpenCodeSessionsFromSQLite(at url: URL, limit: Int) -> [OpenCodeSessionRow]? {
        withReadOnlySQLite(url) { db in
            let tables = sqliteTableNames(db)
            let table = tables.contains("session_v2") ? "session_v2" : (tables.contains("session") ? "session" : nil)
            guard let table else { return [] }
            let sql = "SELECT id, title, directory, time_updated FROM \(table) ORDER BY time_updated DESC LIMIT \(max(1, min(limit, 80)))"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
            defer { sqlite3_finalize(stmt) }

            var rows: [OpenCodeSessionRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let rawID = sqliteColumnString(stmt, 0),
                      let validID = AgentContextValidation.sessionID(rawID) else { continue }
                let title = sqliteColumnString(stmt, 1).flatMap { SessionTurnPreviewInspector.sanitizeAndRedact($0, maxLength: 96) }
                let directory = sqliteColumnString(stmt, 2)
                let ms = sqlite3_column_int64(stmt, 3)
                let date = ms > 0 ? Date(timeIntervalSince1970: ms > 10_000_000_000 ? Double(ms) / 1_000 : Double(ms)) : nil
                rows.append(OpenCodeSessionRow(sessionID: validID, title: title, directory: directory, updatedAt: date))
            }
            return rows
        }
    }

    private func loadOpenCodeTurns(sessionID: String, maxTurns: Int) -> [SessionChatTurn] {
        guard let validID = AgentContextValidation.sessionID(sessionID) else { return [] }
        // 1. Check storage/message/<sessionID>/*.json + storage/part/<messageID>/*.json
        let messageDir = homeDirectory
            .appendingPathComponent(".local/share/opencode/storage/message", isDirectory: true)
            .appendingPathComponent(validID, isDirectory: true)
        let msgFiles = collectFiles(under: messageDir, extensions: ["json"], maxDepth: 0, maxCandidates: 120)
            .sorted { $0.modifiedAt < $1.modifiedAt }

        var turns: [SessionChatTurn] = []
        var counter = 0

        for msgFile in msgFiles {
            guard let msgDict = readJSONDictionary(at: msgFile.url) else { continue }
            let info = (msgDict["info"] as? [String: Any]) ?? msgDict
            let role = (info["role"] as? String) ?? ""
            guard role == "user" || role == "assistant" else { continue }
            let timestamp: Date? = {
                if let timeDict = info["time"] as? [String: Any],
                   let ms = QuotaParsing.number(timeDict["created"]) {
                    return Date(timeIntervalSince1970: ms > 10_000_000_000 ? ms / 1_000 : ms)
                }
                return msgFile.modifiedAt
            }()

            var parts: [[String: Any]] = (msgDict["parts"] as? [[String: Any]]) ?? []
            if parts.isEmpty, let msgID = (info["id"] as? String).flatMap({ AgentContextValidation.sessionID($0) }) {
                let partDir = homeDirectory
                    .appendingPathComponent(".local/share/opencode/storage/part", isDirectory: true)
                    .appendingPathComponent(msgID, isDirectory: true)
                let partFiles = collectFiles(under: partDir, extensions: ["json"], maxDepth: 0, maxCandidates: 32)
                    .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
                parts = partFiles.compactMap { readJSONDictionary(at: $0.url) }
            }

            if let textContent = msgDict["content"] as? String,
               let clean = Self.sanitizeMultilineText(textContent) {
                counter += 1
                turns.append(SessionChatTurn(id: "oc-\(counter)", kind: role == "user" ? .user : .assistant, text: clean, timestamp: timestamp))
            }

            var textFragments: [String] = []
            for part in parts {
                let pType = (part["type"] as? String) ?? "text"
                if pType == "text", let txt = part["text"] as? String {
                    textFragments.append(txt)
                } else if pType == "tool" {
                    let toolName = ((part["tool"] as? String) ?? "tool")
                    let state = (part["state"] as? [String: Any]) ?? part
                    let input = state["input"] as? [String: Any]
                    let summary = extractToolTargetSummary(from: input) ?? toolName
                    let rawStatus = (state["status"] as? String ?? "completed").lowercased()
                    let status = ["error", "failed"].contains(rawStatus) ? "failed" : (rawStatus == "running" ? "running" : "completed")
                    counter += 1
                    turns.append(
                        SessionChatTurn(
                            id: "oc-t-\(counter)",
                            kind: .toolCall,
                            text: summary,
                            toolName: SessionTurnPreviewInspector.sanitizeAndRedact(toolName, maxLength: 64),
                            toolStatus: status,
                            timestamp: timestamp
                        )
                    )
                }
            }
            if !textFragments.isEmpty,
               let clean = Self.sanitizeMultilineText(textFragments.joined(separator: "\n\n")) {
                counter += 1
                turns.append(
                    SessionChatTurn(
                        id: "oc-\(counter)",
                        kind: role == "user" ? .user : .assistant,
                        text: clean,
                        timestamp: timestamp
                    )
                )
            }
        }

        if !turns.isEmpty {
            return Array(turns.suffix(maxTurns))
        }

        // 2. SQLite message/part table fallback if present in opencode.db
        let dbURL = homeDirectory.appendingPathComponent(".local/share/opencode/opencode.db")
        if let sqliteTurns = queryOpenCodeTurnsFromSQLite(at: dbURL, sessionID: validID, maxTurns: maxTurns), !sqliteTurns.isEmpty {
            return sqliteTurns
        }
        return []
    }

    private func queryOpenCodeTurnsFromSQLite(at url: URL, sessionID: String, maxTurns: Int) -> [SessionChatTurn]? {
        withReadOnlySQLite(url, maxCellBytes: 64 * 1_024) { db in
            let tables = sqliteTableNames(db)
            let msgTable = tables.contains("message_v2") ? "message_v2" : (tables.contains("message") ? "message" : nil)
            guard let msgTable else { return [] }
            let sql = "SELECT id, data, time_created FROM \(msgTable) WHERE session_id = ? ORDER BY time_created ASC LIMIT \(maxTurns)"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            guard sqliteBindText(stmt, index: 1, value: sessionID) else { return [] }

            var msgRows: [(id: String, role: String, timestamp: Date?, inlineText: String?)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let msgID = sqliteColumnString(stmt, 0),
                      let rawJSON = sqliteColumnString(stmt, 1, maxBytes: 64 * 1_024),
                      let data = rawJSON.data(using: .utf8),
                      let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                let role = (dict["role"] as? String) ?? ""
                let ms = sqlite3_column_int64(stmt, 2)
                let ts = ms > 0 ? Date(timeIntervalSince1970: ms > 10_000_000_000 ? Double(ms) / 1_000 : Double(ms)) : nil
                let inline = (dict["content"] as? String) ?? (dict["text"] as? String)
                msgRows.append((msgID, role, ts, inline))
            }

            let partTable = tables.contains("part_v2") ? "part_v2" : (tables.contains("part") ? "part" : nil)
            var turns: [SessionChatTurn] = []
            var counter = 0

            for row in msgRows where row.role == "user" || row.role == "assistant" {
                if let inline = row.inlineText, let clean = Self.sanitizeMultilineText(inline) {
                    counter += 1
                    turns.append(SessionChatTurn(id: "ocdb-\(counter)", kind: row.role == "user" ? .user : .assistant, text: clean, timestamp: row.timestamp))
                    continue
                }
                guard let partTable else { continue }
                let partSQL = "SELECT data FROM \(partTable) WHERE message_id = ? ORDER BY id ASC LIMIT 24"
                var pStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, partSQL, -1, &pStmt, nil) == SQLITE_OK, let pStmt else { continue }
                defer { sqlite3_finalize(pStmt) }
                guard sqliteBindText(pStmt, index: 1, value: row.id) else { continue }
                var texts: [String] = []
                while sqlite3_step(pStmt) == SQLITE_ROW {
                    guard let rawPart = sqliteColumnString(pStmt, 0, maxBytes: 64 * 1_024),
                          let pData = rawPart.data(using: .utf8),
                          let pDict = (try? JSONSerialization.jsonObject(with: pData)) as? [String: Any] else { continue }
                    let pType = (pDict["type"] as? String) ?? "text"
                    if pType == "text", let t = pDict["text"] as? String {
                        texts.append(t)
                    } else if pType == "tool" {
                        let toolName = (pDict["tool"] as? String) ?? "tool"
                        let state = (pDict["state"] as? [String: Any]) ?? pDict
                        let summary = extractToolTargetSummary(from: state["input"] as? [String: Any]) ?? toolName
                        counter += 1
                        turns.append(SessionChatTurn(id: "ocdb-t-\(counter)", kind: .toolCall, text: summary, toolName: toolName, toolStatus: "completed", timestamp: row.timestamp))
                    }
                }
                if !texts.isEmpty, let clean = Self.sanitizeMultilineText(texts.joined(separator: "\n\n")) {
                    counter += 1
                    turns.append(SessionChatTurn(id: "ocdb-\(counter)", kind: row.role == "user" ? .user : .assistant, text: clean, timestamp: row.timestamp))
                }
            }
            return Array(turns.suffix(maxTurns))
        }
    }

    // MARK: - Gemini CLI Discovery & Turn Parsing

    private func discoverGeminiSessions(limit: Int) -> [IndexedAgentSession] {
        var candidates: [DatedFile] = []
        let tmpRoot = homeDirectory.appendingPathComponent(".gemini/tmp", isDirectory: true)
        if let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: tmpRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) {
            for dir in projectDirs.prefix(64) {
                let chatsDir = dir.appendingPathComponent("chats", isDirectory: true)
                candidates.append(contentsOf: collectFiles(under: chatsDir, extensions: ["json", "jsonl"], maxDepth: 0, maxCandidates: 16))
            }
        }
        let sessionsDir = homeDirectory.appendingPathComponent(".gemini/sessions", isDirectory: true)
        candidates.append(contentsOf: collectFiles(under: sessionsDir, extensions: ["json", "jsonl"], maxDepth: 1, maxCandidates: limit))
        candidates.sort { $0.modifiedAt > $1.modifiedAt }

        var sessions: [IndexedAgentSession] = []
        var seenIDs = Set<String>()

        for file in candidates.prefix(limit) {
            let messages = readGeminiMessages(at: file.url)
            guard !messages.isEmpty else { continue }
            let stem = file.url.deletingPathExtension().lastPathComponent
            let rawSessionID = (messages.first?["sessionId"] as? String) ?? stem
            guard let validID = AgentContextValidation.sessionID(rawSessionID),
                  seenIDs.insert(validID).inserted else { continue }

            var firstUser: String?
            var lastSnippet: String?
            var count = 0
            for msg in messages {
                let role = ((msg["type"] ?? msg["role"]) as? String ?? "").lowercased()
                guard role == "user" || role == "gemini" || role == "model" || role == "assistant" else { continue }
                if let text = extractGeminiText(msg), !text.isEmpty {
                    count += 1
                    if role == "user", firstUser == nil {
                        firstUser = SessionTurnPreviewInspector.sanitizeAndRedact(text, maxLength: 96)
                    }
                    lastSnippet = SessionTurnPreviewInspector.sanitizeAndRedact(text, maxLength: 140)
                }
            }
            guard count > 0 else { continue }
            sessions.append(
                IndexedAgentSession(
                    id: "gemini:\(validID)",
                    provider: .gemini,
                    agentName: "Gemini CLI",
                    sessionID: validID,
                    title: firstUser ?? "Gemini · \(validID.prefix(8))",
                    projectPath: nil,
                    projectName: "Gemini CLI",
                    gitBranch: nil,
                    sourcePath: file.url.path,
                    updatedAt: file.modifiedAt,
                    isLive: false,
                    liveObservation: nil,
                    canResumeNatively: false,
                    nativeSteerMode: nil,
                    liveSteerMode: nil,
                    lastMessageSnippet: lastSnippet,
                    turnCount: count
                )
            )
        }
        return sessions
    }

    private func loadGeminiTurns(at url: URL, maxTurns: Int) -> [SessionChatTurn] {
        let messages = readGeminiMessages(at: url)
        var turns: [SessionChatTurn] = []
        var counter = 0
        for msg in messages {
            let role = ((msg["type"] ?? msg["role"]) as? String ?? "").lowercased()
            let timestamp = QuotaParsing.date(msg["timestamp"])
            if role == "user", let txt = extractGeminiText(msg), let clean = Self.sanitizeMultilineText(txt) {
                counter += 1
                turns.append(SessionChatTurn(id: "gm-\(counter)", kind: .user, text: clean, timestamp: timestamp))
            } else if ["gemini", "model", "assistant"].contains(role) {
                if let txt = extractGeminiText(msg), let clean = Self.sanitizeMultilineText(txt) {
                    counter += 1
                    turns.append(SessionChatTurn(id: "gm-\(counter)", kind: .assistant, text: clean, timestamp: timestamp))
                }
                for call in (msg["toolCalls"] as? [[String: Any]]) ?? [] {
                    let name = (call["name"] as? String) ?? "tool"
                    let args = call["args"] as? [String: Any]
                    let summary = extractToolTargetSummary(from: args) ?? name
                    counter += 1
                    turns.append(SessionChatTurn(id: "gm-t-\(counter)", kind: .toolCall, text: summary, toolName: name, toolStatus: "completed", timestamp: timestamp))
                }
            }
        }
        return Array(turns.suffix(maxTurns))
    }

    private func readGeminiMessages(at url: URL) -> [[String: Any]] {
        if url.pathExtension == "json" {
            guard let dict = readJSONDictionary(at: url, maxBytes: 512 * 1_024) else { return [] }
            if let messages = dict["messages"] as? [[String: Any]] {
                return messages
            }
            return [dict]
        } else {
            return readTailRecordsForConversation(url: url, maxBytes: 256 * 1_024) ?? []
        }
    }

    private func extractGeminiText(_ msg: [String: Any]) -> String? {
        if let content = msg["content"] as? String { return content }
        if let text = msg["text"] as? String { return text }
        if let blocks = msg["content"] as? [[String: Any]] {
            let parts = blocks.compactMap { block -> String? in
                guard block["thought"] as? Bool != true else { return nil }
                return block["text"] as? String
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        }
        return nil
    }

    // MARK: - Cursor Workspace & Composer Discovery

    private func discoverCursorSessions(limit: Int) -> [IndexedAgentSession] {
        let storageRoot = homeDirectory
            .appendingPathComponent("Library/Application Support/Cursor/User/workspaceStorage", isDirectory: true)
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: storageRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var datedDirs: [(url: URL, modifiedAt: Date)] = []
        for dir in dirs {
            guard let vals = try? dir.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                  vals.isDirectory == true, vals.isSymbolicLink != true else { continue }
            let stateDB = dir.appendingPathComponent("state.vscdb")
            let mtime = (try? stateDB.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? vals.contentModificationDate
                ?? .distantPast
            datedDirs.append((dir, mtime))
        }
        datedDirs.sort { $0.modifiedAt > $1.modifiedAt }

        var sessions: [IndexedAgentSession] = []
        for entry in datedDirs.prefix(max(limit, 24)) where sessions.count < limit {
            let workspaceJSON = entry.url.appendingPathComponent("workspace.json")
            guard let wsDict = readJSONDictionary(at: workspaceJSON, maxBytes: 32 * 1_024),
                  let folderURI = wsDict["folder"] as? String,
                  let folderURL = URL(string: folderURI),
                  folderURL.isFileURL else { continue }
            let projectPath = folderURL.standardizedFileURL.path
            let projectName = URL(fileURLWithPath: projectPath).lastPathComponent
            let stateDB = entry.url.appendingPathComponent("state.vscdb")

            let composers = readCursorComposers(from: stateDB)
            if composers.isEmpty {
                continue
            }
            for comp in composers.prefix(4) where sessions.count < limit {
                sessions.append(
                    IndexedAgentSession(
                        id: "cursor:\(entry.url.lastPathComponent):\(comp.id)",
                        provider: .cursor,
                        agentName: "Cursor",
                        sessionID: comp.id,
                        title: comp.title ?? "Cursor Composer · \(projectName)",
                        projectPath: projectPath,
                        projectName: projectName,
                        gitBranch: nil,
                        sourcePath: stateDB.path,
                        updatedAt: comp.updatedAt ?? entry.modifiedAt,
                        isLive: false,
                        liveObservation: nil,
                        canResumeNatively: false,
                        nativeSteerMode: nil,
                        liveSteerMode: nil,
                        lastMessageSnippet: comp.subtitle ?? "Cursor workspace session in \(projectName)",
                        turnCount: 1
                    )
                )
            }
        }
        return sessions
    }

    private struct CursorComposerMeta {
        let id: String
        let title: String?
        let subtitle: String?
        let updatedAt: Date?
    }

    private func readCursorComposers(from dbURL: URL) -> [CursorComposerMeta] {
        withReadOnlySQLite(dbURL, maxCellBytes: 256 * 1_024) { db in
            let sql = "SELECT value FROM ItemTable WHERE key = 'composer.composerData' LIMIT 1"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW,
                  let raw = sqliteColumnString(stmt, 0, maxBytes: 256 * 1_024),
                  let data = raw.data(using: .utf8),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let list = root["allComposers"] as? [[String: Any]] else {
                return []
            }
            var items: [CursorComposerMeta] = []
            for item in list.prefix(12) {
                guard let rawID = item["composerId"] as? String,
                      let validID = AgentContextValidation.sessionID(rawID) else { continue }
                let title = (item["name"] as? String).flatMap { SessionTurnPreviewInspector.sanitizeAndRedact($0, maxLength: 96) }
                let subtitle = (item["subtitle"] as? String).flatMap { SessionTurnPreviewInspector.sanitizeAndRedact($0, maxLength: 120) }
                let ms = QuotaParsing.number(item["lastUpdatedAt"] ?? item["createdAt"])
                let updated = ms.map { Date(timeIntervalSince1970: $0 > 10_000_000_000 ? $0 / 1_000 : $0) }
                if title != nil || updated != nil {
                    items.append(CursorComposerMeta(id: validID, title: title, subtitle: subtitle, updatedAt: updated))
                }
            }
            return items.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        } ?? []
    }

    // MARK: - Low-Level Safe File & SQLite Helpers

    private struct DatedFile {
        let url: URL
        let modifiedAt: Date
    }

    private func collectJSONLFiles(under root: URL, exactDepth: Int, maxCandidates: Int) -> [DatedFile] {
        var results: [DatedFile] = []
        var budget = 6_000
        let deadline = ProcessInfo.processInfo.systemUptime + 0.9
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]

        func walk(_ dir: URL, depth: Int) {
            guard budget > 0, ProcessInfo.processInfo.systemUptime < deadline,
                  let enumerator = FileManager.default.enumerator(
                      at: dir,
                      includingPropertiesForKeys: Array(keys),
                      options: [.skipsSubdirectoryDescendants]
                  ) else { return }
            while budget > 0, ProcessInfo.processInfo.systemUptime < deadline,
                  let item = enumerator.nextObject() as? URL {
                budget -= 1
                guard let vals = try? item.resourceValues(forKeys: keys), vals.isSymbolicLink != true else { continue }
                if depth < exactDepth {
                    if vals.isDirectory == true {
                        walk(item, depth: depth + 1)
                    }
                } else if vals.isRegularFile == true, item.pathExtension == "jsonl" {
                    results.append(DatedFile(url: item, modifiedAt: vals.contentModificationDate ?? .distantPast))
                }
            }
        }

        walk(root, depth: 0)
        results.sort { $0.modifiedAt > $1.modifiedAt }
        return Array(results.prefix(maxCandidates))
    }

    private func collectFiles(under root: URL, extensions: Set<String>, maxDepth: Int, maxCandidates: Int) -> [DatedFile] {
        var results: [DatedFile] = []
        var budget = 4_000
        let deadline = ProcessInfo.processInfo.systemUptime + 0.6
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]

        func walk(_ dir: URL, depth: Int) {
            guard budget > 0, ProcessInfo.processInfo.systemUptime < deadline,
                  let enumerator = FileManager.default.enumerator(
                      at: dir,
                      includingPropertiesForKeys: Array(keys),
                      options: [.skipsSubdirectoryDescendants]
                  ) else { return }
            while budget > 0, ProcessInfo.processInfo.systemUptime < deadline,
                  let item = enumerator.nextObject() as? URL {
                budget -= 1
                guard let vals = try? item.resourceValues(forKeys: keys), vals.isSymbolicLink != true else { continue }
                if vals.isRegularFile == true, extensions.contains(item.pathExtension.lowercased()) {
                    results.append(DatedFile(url: item, modifiedAt: vals.contentModificationDate ?? .distantPast))
                } else if vals.isDirectory == true, depth < maxDepth {
                    walk(item, depth: depth + 1)
                }
            }
        }

        walk(root, depth: 0)
        results.sort { $0.modifiedAt > $1.modifiedAt }
        return Array(results.prefix(maxCandidates))
    }

    private func findClaudeFile(sessionID: String) -> URL? {
        let root = homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true)
        return collectJSONLFiles(under: root, exactDepth: 1, maxCandidates: 160).first {
            $0.url.deletingPathExtension().lastPathComponent.lowercased() == sessionID.lowercased()
        }?.url
    }

    private func findCodexFile(sessionID: String) -> URL? {
        let root = homeDirectory.appendingPathComponent(".codex/sessions", isDirectory: true)
        return collectJSONLFiles(under: root, exactDepth: 3, maxCandidates: 160).first {
            let stem = $0.url.deletingPathExtension().lastPathComponent.lowercased()
            return stem == sessionID.lowercased() || stem.hasSuffix("-" + sessionID.lowercased())
        }?.url
    }

    private func readHeadAndTailRecords(url: URL, headBytes: Int, tailBytes: Int) -> (header: [[String: Any]], tail: [[String: Any]])? {
        let fd = SessionFileEvidence.openRegular(url)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size > 0 else { return nil }

        func preadChunk(_ count: Int, offset: off_t) -> Data? {
            var buf = Data(count: count)
            let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, offset) }
            guard n >= 0 else { return nil }
            buf.count = n
            return buf
        }
        func parseJSONLines(_ data: Data) -> [[String: Any]] {
            data.split(separator: 10).compactMap { line in
                (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
            }
        }

        let totalBudget = headBytes + tailBytes
        if st.st_size <= totalBudget {
            guard let full = preadChunk(Int(st.st_size), offset: 0) else { return nil }
            return ([], parseJSONLines(full))
        }
        guard var head = preadChunk(headBytes, offset: 0),
              var tail = preadChunk(tailBytes, offset: st.st_size - off_t(tailBytes)) else { return nil }
        if let end = head.lastIndex(of: 10) { head = Data(head.prefix(through: end)) } else { head = Data() }
        if let start = tail.firstIndex(of: 10) { tail.removeSubrange(...start) } else { tail = Data() }
        return (parseJSONLines(head), parseJSONLines(tail))
    }

    private func readTailRecordsForConversation(url: URL, maxBytes: Int) -> [[String: Any]]? {
        let fd = SessionFileEvidence.openRegular(url)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size > 0 else { return nil }

        let readSize = min(Int(st.st_size), maxBytes)
        let offset = st.st_size > maxBytes ? st.st_size - off_t(maxBytes) : 0
        var data = Data(count: readSize)
        let n = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, readSize, offset) }
        guard n > 0 else { return nil }
        data.count = n
        if offset > 0 {
            if let firstNewline = data.firstIndex(of: 10) {
                data.removeSubrange(...firstNewline)
            } else {
                return []
            }
        }
        return data.split(separator: 10).compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
        }
    }

    private func readJSONDictionary(at url: URL, maxBytes: Int = 128 * 1_024) -> [String: Any]? {
        let fd = SessionFileEvidence.openRegular(url)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size > 0, st.st_size <= maxBytes else {
            return nil
        }
        var data = Data(count: Int(st.st_size))
        let n = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, Int(st.st_size), 0) }
        guard n > 0 else { return nil }
        data.count = n
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func withReadOnlySQLite<T>(_ url: URL, maxCellBytes: Int32 = 16_384, body: (OpaquePointer) -> T?) -> T? {
        let fd = SessionFileEvidence.openRegular(url)
        guard fd >= 0 else { return nil }
        close(fd)

        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(
            SessionFileEvidence.filesystemPath(url),
            &handle,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW,
            nil
        )
        defer { if let handle { sqlite3_close(handle) } }
        guard rc == SQLITE_OK, let db = handle else { return nil }
        sqlite3_busy_timeout(db, 60)
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, max(maxCellBytes, 262_144))
        return body(db)
    }

    private func sqliteTableNames(_ db: OpaquePointer) -> Set<String> {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type = 'table'", -1, &stmt, nil) == SQLITE_OK,
              let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        var names = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqliteColumnString(stmt, 0) {
                names.insert(name)
            }
        }
        return names
    }

    private func sqliteColumnString(_ stmt: OpaquePointer, _ col: Int32, maxBytes: Int32 = 4_096) -> String? {
        guard let ptr = sqlite3_column_text(stmt, col) else { return nil }
        let len = sqlite3_column_bytes(stmt, col)
        guard len > 0, len <= maxBytes else { return nil }
        return String(bytes: UnsafeBufferPointer(start: ptr, count: Int(len)), encoding: .utf8)
    }

    private func sqliteBindText(_ stmt: OpaquePointer, index: Int32, value: String) -> Bool {
        value.withCString {
            sqlite3_bind_text(stmt, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } == SQLITE_OK
    }

    private func extractToolTargetSummary(from input: [String: Any]?) -> String? {
        guard let input else { return nil }
        let keys = ["command", "cmd", "file_path", "filePath", "path", "pattern", "query", "url", "description", "prompt"]
        for key in keys {
            if let str = input[key] as? String,
               let clean = SessionTurnPreviewInspector.sanitizeAndRedact(str, maxLength: 140) {
                return clean
            }
            if let arr = input[key] as? [String],
               let clean = SessionTurnPreviewInspector.sanitizeAndRedact(arr.joined(separator: " "), maxLength: 140) {
                return clean
            }
        }
        return nil
    }

    private func liveRunningToolTurn(for agent: AgentObservation, allProcesses: [ObservedProcess]) -> SessionChatTurn? {
        guard !agent.process.isStopped else { return nil }
        if let task = agent.currentTask, task.hasPrefix("Running: ") {
            let label = String(task.dropFirst("Running: ".count))
            let tool = label.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? label
            return SessionChatTurn(
                id: "live-tool-\(agent.id)",
                kind: .toolCall,
                text: label,
                toolName: tool,
                toolStatus: "running",
                timestamp: agent.lastActivityAt ?? Date()
            )
        }
        let combined = allProcesses.contains(where: { $0.pid == agent.process.pid }) ? allProcesses : allProcesses + [agent.process]
        let tree = ProcessTree(processes: combined)
        let knownTools: Set<String> = ["swift", "swift-frontend", "cargo", "git", "rg", "npm", "pnpm", "bun", "node", "python", "python3", "pytest", "go", "xcodebuild", "make"]
        for pid in tree.descendants(of: agent.process.pid).sorted() {
            if let proc = tree.processesByPID[pid], proc.uid == agent.process.uid, !proc.isStopped, knownTools.contains(proc.name) {
                return SessionChatTurn(
                    id: "live-tool-\(proc.pid)",
                    kind: .toolCall,
                    text: proc.name,
                    toolName: proc.name,
                    toolStatus: "running",
                    timestamp: Date()
                )
            }
        }
        return nil
    }

    private func canonicalExistingDirectory(_ raw: String?) -> String? {
        guard let raw, raw.hasPrefix("/"), raw.utf8.count <= 4_096,
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        let resolved = URL(fileURLWithPath: raw).resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved != "/", resolved != homeDirectory.resolvingSymlinksInPath().standardizedFileURL.path else {
            return nil
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return resolved
    }

    private func maxDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (l?, r?): return max(l, r)
        case let (l?, nil): return l
        case let (nil, r?): return r
        case (nil, nil): return nil
        }
    }
}
