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
    /// Collect live evidence when called for each candidate. Return nil if it cannot be assessed.
    func moveCandidatesToTrash(candidates: [CleanupCandidate],
                               freshAssessment: @Sendable (CleanupCandidate) -> SafetyAssessment?) -> TrashExecutionReport
}

public extension ActionExecuting {
    /// Kept for existing callers. A precomputed assessment cannot authorize a Trash operation.
    func moveCandidatesToTrash(candidates: [CleanupCandidate], assessments _: [String: SafetyAssessment]) -> TrashExecutionReport {
        TrashExecutionReport(outcomes: candidates.map {
            TrashItemOutcome(candidateID: $0.id, path: $0.path, bytes: 0, succeeded: false,
                             error: "Trash requires a live safety assessment for each candidate")
        })
    }
}

/// Explicit user action only. Revalidate current-user process and target identity
/// at execution time; pass prompt as data via argv, never interpolated script code.
public protocol AgentSteering: Sendable {
    func steer(agent: AgentObservation, prompt: String, uid: Int) -> AgentSteerOutcome
    func steer(agent: AgentObservation, target: NativeSessionTarget, prompt: String, uid: Int) -> AgentSteerOutcome
}

public extension AgentSteering {
    func steer(agent: AgentObservation, target: NativeSessionTarget, prompt: String, uid: Int) -> AgentSteerOutcome {
        AgentSteerOutcome(agentID: agent.id, mode: target.mode, succeeded: false, error: "Native continuation is unavailable")
    }
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
