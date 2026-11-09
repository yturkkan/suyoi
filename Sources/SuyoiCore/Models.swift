import Foundation

public struct ProcessIdentity: Codable, Equatable, Sendable {
    public let pid: Int
    public let uid: Int
    public let startTimeMicroseconds: UInt64?
    public let executablePath: String

    public init(pid: Int, uid: Int, startTimeMicroseconds: UInt64?, executablePath: String) {
        self.pid = pid
        self.uid = uid
        self.startTimeMicroseconds = startTimeMicroseconds
        self.executablePath = executablePath
    }
    /// Sufficient identity metadata only; this never authorizes a process action.
    public var isActionEligible: Bool {
        pid > 0 && uid >= 0 && (startTimeMicroseconds ?? 0) > 0 && executablePath.hasPrefix("/")
    }
}

public struct AgentInvocation: Codable, Equatable, Sendable {
    public let agentName: String
    public let runtime: String?
    public let entrypoint: String?

    public init(agentName: String, runtime: String? = nil, entrypoint: String? = nil) {
        self.agentName = agentName
        self.runtime = runtime
        self.entrypoint = entrypoint
    }
}

public struct ObservedProcess: Identifiable, Codable, Equatable, Sendable {
    public let pid: Int
    public let parentPID: Int
    public let uid: Int
    public let cpuPercent: Double
    public let residentBytes: Int64
    public let executable: String
    public let startTimeMicroseconds: UInt64?
    public let cwd: String?
    public let tty: String?
    public let isStopped: Bool
    public let footprintBytes: Int64?
    public let cpuNanoseconds: UInt64?
    public let agentInvocation: AgentInvocation?

    public init(pid: Int, parentPID: Int, uid: Int, cpuPercent: Double, residentBytes: Int64, executable: String, startTimeMicroseconds: UInt64? = nil, cwd: String? = nil, tty: String? = nil, isStopped: Bool = false, footprintBytes: Int64? = nil, cpuNanoseconds: UInt64? = nil, agentInvocation: AgentInvocation? = nil) {
        self.pid = pid
        self.parentPID = parentPID
        self.uid = uid
        self.cpuPercent = cpuPercent
        self.residentBytes = residentBytes
        self.executable = executable
        self.startTimeMicroseconds = startTimeMicroseconds
        self.cwd = cwd
        self.tty = tty
        self.isStopped = isStopped
        self.footprintBytes = footprintBytes
        self.cpuNanoseconds = cpuNanoseconds
        self.agentInvocation = agentInvocation
    }

    private enum CodingKeys: String, CodingKey {
        case pid, parentPID, uid, cpuPercent, residentBytes, executable, startTimeMicroseconds, cwd, tty, isStopped, footprintBytes, cpuNanoseconds, agentInvocation
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.pid = try values.decode(Int.self, forKey: .pid)
        self.parentPID = try values.decode(Int.self, forKey: .parentPID)
        self.uid = try values.decode(Int.self, forKey: .uid)
        self.cpuPercent = try values.decode(Double.self, forKey: .cpuPercent)
        self.residentBytes = try values.decode(Int64.self, forKey: .residentBytes)
        self.executable = try values.decode(String.self, forKey: .executable)
        self.startTimeMicroseconds = try values.decodeIfPresent(UInt64.self, forKey: .startTimeMicroseconds)
        self.cwd = try values.decodeIfPresent(String.self, forKey: .cwd)
        self.tty = try values.decodeIfPresent(String.self, forKey: .tty)
        self.isStopped = try values.decodeIfPresent(Bool.self, forKey: .isStopped) ?? false
        self.footprintBytes = try values.decodeIfPresent(Int64.self, forKey: .footprintBytes)
        self.cpuNanoseconds = try values.decodeIfPresent(UInt64.self, forKey: .cpuNanoseconds)
        self.agentInvocation = try values.decodeIfPresent(AgentInvocation.self, forKey: .agentInvocation)
    }
    public var id: Int { pid }
    public var name: String { URL(fileURLWithPath: executable).lastPathComponent }
    public var agentName: String? {
        if let invoked = agentInvocation?.agentName, !invoked.isEmpty {
            return invoked
        }
        switch name {
        case "codex", "Codex": return "Codex"
        case "claude": return "Claude Code"
        case "opencode": return "OpenCode"
        case "aider": return "Aider"
        case "gemini": return "Gemini CLI"
        default: return nil
        }
    }
    public var identity: ProcessIdentity {
        ProcessIdentity(pid: pid, uid: uid, startTimeMicroseconds: startTimeMicroseconds, executablePath: executable)
    }
}

public struct Listener: Identifiable, Codable, Equatable, Sendable {
    public let pid: Int
    public let processName: String
    public let address: String
    public let port: Int
    public init(pid: Int, processName: String, address: String, port: Int) {
        self.pid = pid
        self.processName = processName
        self.address = address
        self.port = port
    }
    public var id: String { "\(pid):\(address):\(port)" }
    public var isDevelopmentRuntime: Bool {
        let name = processName.lowercased()
        return ["node", "bun", "deno", "python", "python3", "ruby", "php", "java", "go", "vite", "next-server", "uvicorn", "gunicorn"].contains(name)
            || name.hasPrefix("python3.")
    }
    public var exposure: String {
        if address == "::1" || address.hasPrefix("127.") { return "Loopback" }
        if ["*", "0.0.0.0", "::"].contains(address) { return "All interfaces" }
        return "Specific interface"
    }
}

public enum ObservationStatus: String, Codable, Equatable, Sendable {
    case complete, partial, unavailable
}

public struct Observation<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public let value: Value
    public let status: ObservationStatus
    public let warnings: [String]
    public let capturedAt: Date

    public init(value: Value, status: ObservationStatus, warnings: [String], capturedAt: Date) {
        self.value = value
        self.status = status
        self.warnings = warnings
        self.capturedAt = capturedAt
    }
}

public struct ProjectContext: Codable, Equatable, Sendable {
    public let rootPath: String
    public let name: String
    public let framework: String?
    public let gitBranch: String?
    public let gitCommit: String?
    public let isWorktree: Bool

    public init(rootPath: String, name: String, framework: String?, gitBranch: String?, gitCommit: String?, isWorktree: Bool) {
        self.rootPath = rootPath
        self.name = name
        self.framework = framework
        self.gitBranch = gitBranch
        self.gitCommit = gitCommit
        self.isWorktree = isWorktree
    }
}

public enum AgentStatusSource: Codable, Equatable, Sendable {
    case processOnly
    case verifiedAdapter(String)
}

public enum AgentActivityState: String, Codable, Equatable, Sendable {
    case active
    case waiting
    case idle
    case stopped
}

public struct AgentObservation: Identifiable, Codable, Equatable, Sendable {
    public let id: Int
    public let agentName: String
    public let process: ObservedProcess
    public let project: ProjectContext?
    public let terminalApp: String?
    public let statusSource: AgentStatusSource
    public let childServerPorts: [Int]
    public let activityState: AgentActivityState?
    public let activityDetail: String?
    public let lastActivityAt: Date?
    public let terminalPID: Int?
    public let sessionID: String?
    public let sessionTitle: String?
    public let currentTask: String?

    public init(
        id: Int,
        agentName: String,
        process: ObservedProcess,
        project: ProjectContext?,
        terminalApp: String?,
        statusSource: AgentStatusSource,
        childServerPorts: [Int],
        activityState: AgentActivityState? = nil,
        activityDetail: String? = nil,
        lastActivityAt: Date? = nil,
        terminalPID: Int? = nil,
        sessionID: String? = nil,
        sessionTitle: String? = nil,
        currentTask: String? = nil
    ) {
        self.id = id
        self.agentName = agentName
        self.process = process
        self.project = project
        self.terminalApp = terminalApp
        self.statusSource = statusSource
        self.childServerPorts = childServerPorts
        self.activityState = activityState
        self.activityDetail = activityDetail
        self.lastActivityAt = lastActivityAt
        self.terminalPID = terminalPID
        self.sessionID = sessionID
        self.sessionTitle = sessionTitle
        self.currentTask = currentTask
    }

    private enum CodingKeys: String, CodingKey {
        case id, agentName, process, project, terminalApp, statusSource, childServerPorts, activityState, activityDetail, lastActivityAt, terminalPID
        case sessionID, sessionTitle, currentTask
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(Int.self, forKey: .id)
        self.agentName = try values.decode(String.self, forKey: .agentName)
        self.process = try values.decode(ObservedProcess.self, forKey: .process)
        self.project = try values.decodeIfPresent(ProjectContext.self, forKey: .project)
        self.terminalApp = try values.decodeIfPresent(String.self, forKey: .terminalApp)
        self.statusSource = try values.decode(AgentStatusSource.self, forKey: .statusSource)
        self.childServerPorts = try values.decode([Int].self, forKey: .childServerPorts)
        self.activityState = try values.decodeIfPresent(AgentActivityState.self, forKey: .activityState)
        self.activityDetail = try values.decodeIfPresent(String.self, forKey: .activityDetail)
        self.lastActivityAt = try values.decodeIfPresent(Date.self, forKey: .lastActivityAt)
        self.terminalPID = try values.decodeIfPresent(Int.self, forKey: .terminalPID)
        self.sessionID = try values.decodeIfPresent(String.self, forKey: .sessionID)
        self.sessionTitle = try values.decodeIfPresent(String.self, forKey: .sessionTitle)
        self.currentTask = try values.decodeIfPresent(String.self, forKey: .currentTask)
    }
}

public enum AgentSteerMode: String, Codable, Equatable, Sendable {
    case terminalTTY, openCodeSession, codexResume
}

/// Sanitized action result; never contains the submitted prompt or raw command output.
public struct AgentSteerOutcome: Codable, Equatable, Sendable {
    public let agentID: Int
    public let mode: AgentSteerMode
    public let succeeded: Bool
    public let detail: String?
    public let error: String?

    public init(agentID: Int, mode: AgentSteerMode, succeeded: Bool, detail: String? = nil, error: String? = nil) {
        self.agentID = agentID
        self.mode = mode
        self.succeeded = succeeded
        self.detail = detail
        self.error = error
    }
}

public struct ServerGroup: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let rootPID: Int
    public let name: String
    public let memberPIDs: [Int]
    public var memberIdentities: [ProcessIdentity]
    public let listeners: [Listener]
    public let project: ProjectContext?
    public let cpuPercent: Double?
    public let residentBytes: Int64
    public let footprintBytes: Int64?
    public let startedAt: Date?
    public let stoppedByAgentBoundary: Bool

    public init(id: String, rootPID: Int, name: String, memberPIDs: [Int], memberIdentities: [ProcessIdentity] = [], listeners: [Listener], project: ProjectContext?, cpuPercent: Double?, residentBytes: Int64, footprintBytes: Int64?, startedAt: Date?, stoppedByAgentBoundary: Bool) {
        self.id = id
        self.rootPID = rootPID
        self.name = name
        self.memberPIDs = memberPIDs
        self.memberIdentities = memberIdentities
        self.listeners = listeners
        self.project = project
        self.cpuPercent = cpuPercent
        self.residentBytes = residentBytes
        self.footprintBytes = footprintBytes
        self.startedAt = startedAt
        self.stoppedByAgentBoundary = stoppedByAgentBoundary
    }

    private enum CodingKeys: String, CodingKey {
        case id, rootPID, name, memberPIDs, memberIdentities, listeners, project, cpuPercent, residentBytes, footprintBytes, startedAt, stoppedByAgentBoundary
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(String.self, forKey: .id)
        self.rootPID = try values.decode(Int.self, forKey: .rootPID)
        self.name = try values.decode(String.self, forKey: .name)
        self.memberPIDs = try values.decode([Int].self, forKey: .memberPIDs)
        self.memberIdentities = try values.decodeIfPresent([ProcessIdentity].self, forKey: .memberIdentities) ?? []
        self.listeners = try values.decode([Listener].self, forKey: .listeners)
        self.project = try values.decodeIfPresent(ProjectContext.self, forKey: .project)
        self.cpuPercent = try values.decodeIfPresent(Double.self, forKey: .cpuPercent)
        self.residentBytes = try values.decode(Int64.self, forKey: .residentBytes)
        self.footprintBytes = try values.decodeIfPresent(Int64.self, forKey: .footprintBytes)
        self.startedAt = try values.decodeIfPresent(Date.self, forKey: .startedAt)
        self.stoppedByAgentBoundary = try values.decode(Bool.self, forKey: .stoppedByAgentBoundary)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(rootPID, forKey: .rootPID)
        try values.encode(name, forKey: .name)
        try values.encode(memberPIDs, forKey: .memberPIDs)
        try values.encode(memberIdentities, forKey: .memberIdentities)
        try values.encode(listeners, forKey: .listeners)
        try values.encodeIfPresent(project, forKey: .project)
        try values.encodeIfPresent(cpuPercent, forKey: .cpuPercent)
        try values.encode(residentBytes, forKey: .residentBytes)
        try values.encodeIfPresent(footprintBytes, forKey: .footprintBytes)
        try values.encodeIfPresent(startedAt, forKey: .startedAt)
        try values.encode(stoppedByAgentBoundary, forKey: .stoppedByAgentBoundary)
    }
}

public struct FileIdentity: Codable, Equatable, Sendable {
    public let device: Int32
    public let inode: UInt64

    public init(device: Int32, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

public enum CleanupScope: String, Codable, Equatable, Sendable {
    case projectArtifact, agentCache, worktree
}

public struct CleanupCandidate: Identifiable, Codable, Equatable, Sendable {
    public let path: String
    public let category: String
    /// Logical bytes are not unique disk blocks or a reclaimable-space estimate.
    public let bytes: Int64
    public let partial: Bool
    public let scope: CleanupScope
    public let allocatedBytes: Int64?
    public let fileIdentity: FileIdentity?
    public let agentName: String?

    public init(path: String, category: String, bytes: Int64, partial: Bool, scope: CleanupScope = .projectArtifact, allocatedBytes: Int64? = nil, fileIdentity: FileIdentity? = nil, agentName: String? = nil) {
        self.path = path
        self.category = category
        self.bytes = bytes
        self.partial = partial
        self.scope = scope
        self.allocatedBytes = allocatedBytes
        self.fileIdentity = fileIdentity
        self.agentName = agentName
    }

    private enum CodingKeys: String, CodingKey {
        case path, category, bytes, partial, scope, allocatedBytes, fileIdentity, agentName
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.path = try values.decode(String.self, forKey: .path)
        self.category = try values.decode(String.self, forKey: .category)
        self.bytes = try values.decode(Int64.self, forKey: .bytes)
        self.partial = try values.decode(Bool.self, forKey: .partial)
        self.scope = try values.decodeIfPresent(CleanupScope.self, forKey: .scope) ?? .projectArtifact
        self.allocatedBytes = try values.decodeIfPresent(Int64.self, forKey: .allocatedBytes)
        self.fileIdentity = try values.decodeIfPresent(FileIdentity.self, forKey: .fileIdentity)
        self.agentName = try values.decodeIfPresent(String.self, forKey: .agentName)
    }
    public var id: String { path }
}

public enum UsageState: String, Codable, Equatable, Sendable {
    case inUse, clear, unknown
}

public enum Regenerability: Codable, Equatable, Sendable {
    case lockfileVerified(String)
    case cacheDirectory
    case unverified(String)
}

public struct SafetyAssessment: Codable, Equatable, Sendable {
    public let candidateID: String
    public let usage: UsageState
    public let regenerability: Regenerability
    public let blockedReasons: [String]
    public let isReviewableForTrash: Bool

    public init(candidateID: String, usage: UsageState, regenerability: Regenerability, blockedReasons: [String], isReviewableForTrash: Bool) {
        self.candidateID = candidateID
        self.usage = usage
        self.regenerability = regenerability
        self.blockedReasons = blockedReasons
        self.isReviewableForTrash = isReviewableForTrash
    }
}

public struct WorktreeRecord: Codable, Equatable, Sendable {
    public let path: String
    public let branch: String?
    public let headCommit: String?
    public let isMain: Bool
    public let isDirty: Bool
    public let isLocked: Bool
    public let isMergedToDefault: Bool?
    public let usage: UsageState
    public let blockedReasons: [String]

    public init(path: String, branch: String?, headCommit: String?, isMain: Bool, isDirty: Bool, isLocked: Bool, isMergedToDefault: Bool?, usage: UsageState, blockedReasons: [String]) {
        self.path = path
        self.branch = branch
        self.headCommit = headCommit
        self.isMain = isMain
        self.isDirty = isDirty
        self.isLocked = isLocked
        self.isMergedToDefault = isMergedToDefault
        self.usage = usage
        self.blockedReasons = blockedReasons
    }
}

public struct ActionPreview: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let createdAt: Date
    public let candidates: [CleanupCandidate]
    public let assessments: [String: SafetyAssessment]
    public let blockedCount: Int
    public let eligibleCount: Int
    public let totalLogicalBytes: Int64
    public let totalAllocatedBytes: Int64?

    public init(id: String, createdAt: Date, candidates: [CleanupCandidate], assessments: [String: SafetyAssessment], blockedCount: Int, eligibleCount: Int, totalLogicalBytes: Int64, totalAllocatedBytes: Int64?) {
        self.id = id
        self.createdAt = createdAt
        self.candidates = candidates
        self.assessments = assessments
        self.blockedCount = blockedCount
        self.eligibleCount = eligibleCount
        self.totalLogicalBytes = totalLogicalBytes
        self.totalAllocatedBytes = totalAllocatedBytes
    }
}

public struct InventorySnapshot: Codable, Equatable, Sendable {
    public let processes: [ObservedProcess]
    public let listeners: [Listener]
    public let warnings: [String]
    public let capturedAt: Date
    public let agentObservations: [AgentObservation]
    public let serverGroups: [ServerGroup]
    public let projectsByPath: [String: ProjectContext]

    public init(processes: [ObservedProcess], listeners: [Listener], warnings: [String], capturedAt: Date, agentObservations: [AgentObservation] = [], serverGroups: [ServerGroup] = [], projectsByPath: [String: ProjectContext] = [:]) {
        self.processes = processes
        self.listeners = listeners
        self.warnings = warnings
        self.capturedAt = capturedAt
        self.agentObservations = agentObservations
        self.serverGroups = serverGroups
        self.projectsByPath = projectsByPath
    }

    private enum CodingKeys: String, CodingKey {
        case processes, listeners, warnings, capturedAt, agentObservations, serverGroups, projectsByPath
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.processes = try values.decode([ObservedProcess].self, forKey: .processes)
        self.listeners = try values.decode([Listener].self, forKey: .listeners)
        self.warnings = try values.decode([String].self, forKey: .warnings)
        self.capturedAt = try values.decode(Date.self, forKey: .capturedAt)
        self.agentObservations = try values.decodeIfPresent([AgentObservation].self, forKey: .agentObservations) ?? []
        self.serverGroups = try values.decodeIfPresent([ServerGroup].self, forKey: .serverGroups) ?? []
        self.projectsByPath = try values.decodeIfPresent([String: ProjectContext].self, forKey: .projectsByPath) ?? [:]
    }
    public var agents: [ObservedProcess] { processes.filter { $0.agentName != nil } }
}

public struct CleanupReport: Codable, Equatable, Sendable {
    public let candidates: [CleanupCandidate]
    public let warnings: [String]
    public let partial: Bool
    public let agentCacheCandidates: [CleanupCandidate]
    public let worktrees: [WorktreeRecord]
    public let assessments: [String: SafetyAssessment]
    public let discoveredCount: Int

    public init(candidates: [CleanupCandidate], warnings: [String], partial: Bool, agentCacheCandidates: [CleanupCandidate] = [], worktrees: [WorktreeRecord] = [], assessments: [String: SafetyAssessment] = [:], discoveredCount: Int = 0) {
        self.candidates = candidates
        self.warnings = warnings
        self.partial = partial
        self.agentCacheCandidates = agentCacheCandidates
        self.worktrees = worktrees
        self.assessments = assessments
        self.discoveredCount = discoveredCount
    }

    private enum CodingKeys: String, CodingKey {
        case candidates, warnings, partial, agentCacheCandidates, worktrees, assessments, discoveredCount
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.candidates = try values.decode([CleanupCandidate].self, forKey: .candidates)
        self.warnings = try values.decode([String].self, forKey: .warnings)
        self.partial = try values.decode(Bool.self, forKey: .partial)
        self.agentCacheCandidates = try values.decodeIfPresent([CleanupCandidate].self, forKey: .agentCacheCandidates) ?? []
        self.worktrees = try values.decodeIfPresent([WorktreeRecord].self, forKey: .worktrees) ?? []
        self.assessments = try values.decodeIfPresent([String: SafetyAssessment].self, forKey: .assessments) ?? [:]
        self.discoveredCount = try values.decodeIfPresent(Int.self, forKey: .discoveredCount) ?? 0
    }
}

public struct ProcessActionOutcome: Codable, Equatable, Sendable {
    public let pid: Int
    public let signal: Int32
    public let succeeded: Bool
    public let error: String?

    public init(pid: Int, signal: Int32, succeeded: Bool, error: String? = nil) {
        self.pid = pid
        self.signal = signal
        self.succeeded = succeeded
        self.error = error
    }
}

public struct ProcessExecutionReport: Codable, Equatable, Sendable {
    public let outcomes: [ProcessActionOutcome]
    public let succeededCount: Int
    public let failedCount: Int
    public let warnings: [String]

    public init(outcomes: [ProcessActionOutcome], succeededCount: Int? = nil, failedCount: Int? = nil, warnings: [String] = []) {
        self.outcomes = outcomes
        self.succeededCount = succeededCount ?? outcomes.filter(\.succeeded).count
        self.failedCount = failedCount ?? outcomes.filter { !$0.succeeded }.count
        self.warnings = warnings
    }
}

public struct TrashItemOutcome: Codable, Equatable, Sendable {
    public let candidateID: String
    public let path: String
    public let trashedURL: String?
    public let bytes: Int64
    public let succeeded: Bool
    public let error: String?

    public init(candidateID: String, path: String, trashedURL: String? = nil, bytes: Int64, succeeded: Bool, error: String? = nil) {
        self.candidateID = candidateID
        self.path = path
        self.trashedURL = trashedURL
        self.bytes = bytes
        self.succeeded = succeeded
        self.error = error
    }
}

public struct TrashExecutionReport: Codable, Equatable, Sendable {
    public let outcomes: [TrashItemOutcome]
    public let trashedCount: Int
    public let reclaimedBytes: Int64
    public let warnings: [String]

    public init(outcomes: [TrashItemOutcome], trashedCount: Int? = nil, reclaimedBytes: Int64? = nil, warnings: [String] = []) {
        self.outcomes = outcomes
        self.trashedCount = trashedCount ?? outcomes.filter(\.succeeded).count
        self.reclaimedBytes = reclaimedBytes ?? outcomes.filter(\.succeeded).reduce(0) { $0 + $1.bytes }
        self.warnings = warnings
    }
}

// MARK: - Quota contracts

public enum QuotaProvider: String, Codable, CaseIterable, Equatable, Sendable {
    case codex, claude, gemini, openCode, cursor
}

public enum QuotaSourceKind: String, Codable, Equatable, Sendable {
    case localTelemetry, liveAPI
}

public enum QuotaWindowKind: String, Codable, Equatable, Sendable {
    case fiveHour, sevenDay, sevenDayOpus, sevenDaySonnet
}

/// Provider-reported utilization, never inferred from local token counts.
/// Nil means unknown, including when a provider does not publish a reset time.
public struct QuotaWindow: Codable, Equatable, Sendable {
    public let kind: QuotaWindowKind
    public let windowMinutes: Int?
    public let usedPercent: Double?
    public let resetsAt: Date?

    public init(kind: QuotaWindowKind, windowMinutes: Int? = nil, usedPercent: Double? = nil, resetsAt: Date? = nil) {
        self.kind = kind
        self.windowMinutes = windowMinutes
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

/// Local consumption in [startedAt, endedAt). Missing counters are not zero.
/// Input tokens exclude cache reads/writes; adapters normalize provider semantics.
/// Total may include reasoning or other tokens: do not derive it by blindly summing fields.
public struct TokenUsageSummary: Codable, Equatable, Sendable {
    public let windowMinutes: Int
    public let startedAt: Date
    public let endedAt: Date
    public let inputTokens: UInt64?
    public let outputTokens: UInt64?
    public let cacheReadTokens: UInt64?
    public let cacheCreationTokens: UInt64?
    public let reasoningTokens: UInt64?
    public let totalTokens: UInt64?
    public let status: ObservationStatus

    public init(windowMinutes: Int, startedAt: Date, endedAt: Date, inputTokens: UInt64? = nil, outputTokens: UInt64? = nil, cacheReadTokens: UInt64? = nil, cacheCreationTokens: UInt64? = nil, reasoningTokens: UInt64? = nil, totalTokens: UInt64? = nil, status: ObservationStatus) {
        self.windowMinutes = windowMinutes
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.reasoningTokens = reasoningTokens
        self.totalTokens = totalTokens
        self.status = status
    }
}

public struct QuotaCredits: Codable, Equatable, Sendable {
    public let hasCredits: Bool?
    public let unlimited: Bool?
    public let balance: Double?

    public init(hasCredits: Bool? = nil, unlimited: Bool? = nil, balance: Double? = nil) {
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.balance = balance
    }
}

/// Amounts retain provider units; a currency is present only when explicitly known.
public struct QuotaExtraUsage: Codable, Equatable, Sendable {
    public let isEnabled: Bool?
    public let used: Double?
    public let limit: Double?
    public let currency: String?

    public init(isEnabled: Bool? = nil, used: Double? = nil, limit: Double? = nil, currency: String? = nil) {
        self.isEnabled = isEnabled
        self.used = used
        self.limit = limit
        self.currency = currency
    }
}

/// One provider/source observation. Adapters allowlist plan/model identifiers and
/// emit fixed sanitized warnings only, never raw records, response bodies or errors.
/// Account-wide quota is not attributable to a single process or project.
public struct ProviderQuotaStatus: Codable, Equatable, Sendable {
    public let provider: QuotaProvider
    public let source: QuotaSourceKind
    public let observedAt: Date
    public let status: ObservationStatus
    public let planType: String?
    public let windows: [QuotaWindow]
    public let tokenUsage: [TokenUsageSummary]
    public let credits: QuotaCredits?
    public let extraUsage: QuotaExtraUsage?
    public let lastActivityAt: Date?
    public let warnings: [String]

    public init(provider: QuotaProvider, source: QuotaSourceKind, observedAt: Date, status: ObservationStatus, planType: String? = nil, windows: [QuotaWindow] = [], tokenUsage: [TokenUsageSummary] = [], credits: QuotaCredits? = nil, extraUsage: QuotaExtraUsage? = nil, lastActivityAt: Date? = nil, warnings: [String] = []) {
        self.provider = provider
        self.source = source
        self.observedAt = observedAt
        self.status = status
        self.planType = planType
        self.windows = windows
        self.tokenUsage = tokenUsage
        self.credits = credits
        self.extraUsage = extraUsage
        self.lastActivityAt = lastActivityAt
        self.warnings = warnings
    }
}

public struct QuotaSnapshot: Codable, Equatable, Sendable {
    public let capturedAt: Date
    /// At most one observation per provider/source pair; keep local and live distinct.
    public let providers: [ProviderQuotaStatus]

    public init(capturedAt: Date, providers: [ProviderQuotaStatus] = []) {
        self.capturedAt = capturedAt
        self.providers = providers
    }

    /// Explicit source selection prevents a live refresh from disguising local data.
    /// Ambiguous duplicates fail closed instead of picking an arbitrary observation.
    public func quotaSummary(for agentName: String, source: QuotaSourceKind) -> ProviderQuotaStatus? {
        let provider: QuotaProvider
        switch agentName {
        case "Codex": provider = .codex
        case "Claude Code": provider = .claude
        case "Gemini CLI": provider = .gemini
        case "OpenCode": provider = .openCode
        case "Cursor", "Cursor Agent": provider = .cursor
        default: return nil
        }
        let matches = providers.filter { $0.provider == provider && $0.source == source }
        return matches.count == 1 ? matches.first : nil
    }
}

/// Default is disabled. Permission is supplied for each request, never inferred
/// from credential availability or encoded into a telemetry snapshot.
public enum LiveQuotaPermission: Equatable, Sendable {
    case disabled, userInitiated
}
