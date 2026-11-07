import Foundation

// Synchronous read-only boundaries. Observation status distinguishes unknown from empty.
public protocol ProcessInspecting: Sendable {
    func inspectProcesses(uid: Int) -> Observation<[ObservedProcess]>
}

public protocol ListenerInspecting: Sendable {
    func inspectListeners(uid: Int) -> Observation<[Listener]>
}

public protocol ProjectResolving: Sendable {
    func resolveProject(at directory: URL) -> Observation<ProjectContext?>
}

public protocol CleanupScanning: Sendable {
    func scan(root: URL, entryLimit: Int, timeLimit: TimeInterval) -> CleanupReport
}

public protocol SafetyEvaluating: Sendable {
    func assess(candidate: CleanupCandidate, processes: Observation<[ObservedProcess]>, worktrees: Observation<[WorktreeRecord]>) -> SafetyAssessment
}

public protocol ActionExecuting: Sendable {
    func stopProcess(identity: ProcessIdentity, force: Bool, uid: Int) -> ProcessExecutionReport
    func stopServerGroup(group: ServerGroup, processes: [ObservedProcess], force: Bool, uid: Int) -> ProcessExecutionReport
    func moveCandidatesToTrash(candidates: [CleanupCandidate], assessments: [String: SafetyAssessment]) -> TrashExecutionReport
}

/// Explicit user action only. Revalidate current-user process and target identity
/// at execution time; pass prompt as data via argv, never interpolated script code.
public protocol AgentSteering: Sendable {
    func steer(agent: AgentObservation, prompt: String, uid: Int) -> AgentSteerOutcome
}

/// Offline only. Bound file/line sizes, traversal and elapsed work; skip text fields.
/// Missing, malformed or truncated evidence must remain unavailable/partial.
public protocol QuotaInspecting: Sendable {
    func inspectQuotas(at date: Date) -> QuotaSnapshot
}

/// No credential lookup or network work when permission is disabled. Implementers
/// must also check cancellation, bound requests and never return credentials/raw errors.
/// Secrets remain private to the adapter, in memory, only for the authorized request.
public protocol LiveQuotaPolling: Sendable {
    func pollQuota(for provider: QuotaProvider, permission: LiveQuotaPermission, at date: Date) async -> ProviderQuotaStatus
}
