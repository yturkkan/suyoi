import Foundation
import Darwin

/// Coordinates read-only collectors without requiring a concrete safety engine.
public struct InventoryService: Sendable {
    private let processInspector: any ProcessInspecting
    private let listenerInspector: any ListenerInspecting
    private let projectResolver: any ProjectResolving
    private let cleanupScanner: any CleanupScanning
    private let safetyEvaluator: (any SafetyEvaluating)?
    private let worktreeInspector: WorktreeInspector?

    public init(
        processInspector: any ProcessInspecting = NativeProcessInspector(),
        listenerInspector: any ListenerInspecting = ListenerInspector(),
        projectResolver: any ProjectResolving = ProjectResolver(),
        cleanupScanner: any CleanupScanning = CleanupScanner(),
        safetyEvaluator: (any SafetyEvaluating)? = nil,
        worktreeInspector: WorktreeInspector? = nil
    ) {
        self.processInspector = processInspector
        self.listenerInspector = listenerInspector
        self.projectResolver = projectResolver
        self.cleanupScanner = cleanupScanner
        self.safetyEvaluator = safetyEvaluator
        self.worktreeInspector = worktreeInspector
    }

    public func captureSnapshot(uid: Int = Int(getuid())) -> InventorySnapshot {
        let processObservation = processInspector.inspectProcesses(uid: uid)
        let listenerObservation = listenerInspector.inspectListeners(uid: uid)
        let processes = processObservation.value
        let listeners = listenerObservation.value
        let tree = ProcessTree(processes: processes)
        // Group once to discover non-listening server roots and worker processes.
        let serverPIDs = Set(tree.groupServers(listeners: listeners).flatMap { [$0.rootPID] + $0.memberPIDs })
        var directories = Set<String>()
        for process in tree.processesByPID.values where AgentRecognizer.isAgent(process) || serverPIDs.contains(process.pid) {
            if let cwd = AgentRecognizer.workingDirectory(for: process, processesByPID: tree.processesByPID) {
                directories.insert(cwd)
            }
        }
        var projects: [String: ProjectContext] = [:]
        var warnings = processObservation.warnings + listenerObservation.warnings
        for cwd in directories.sorted() {
            let observation = projectResolver.resolveProject(at: URL(fileURLWithPath: cwd))
            warnings.append(contentsOf: observation.warnings)
            if let context = observation.value {
                projects[cwd] = context
                projects[context.rootPath] = context
            }
        }
        let groups = tree.groupServers(listeners: listeners, projectsByPath: projects)
        let agents = AgentRecognizer.observations(processes: processes, serverGroups: groups, projectsByPath: projects)
        return InventorySnapshot(processes: processes, listeners: listeners, warnings: Self.unique(warnings), capturedAt: Date(),
            agentObservations: agents, serverGroups: groups, projectsByPath: projects)
    }

    public func scanCleanup(root: URL, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                            entryLimit: Int = 100_000, timeLimit: TimeInterval = 10) -> CleanupReport {
        let started = ProcessInfo.processInfo.systemUptime
        let projectLimit = max(0, entryLimit) / 2
        let report = cleanupScanner.scan(root: root, entryLimit: projectLimit, timeLimit: max(0, timeLimit) / 2)
        let caches = AgentCacheCatalog().scanAgentCaches(homeDirectory: homeDirectory,
            entryLimit: max(0, entryLimit - projectLimit),
            timeLimit: max(0, timeLimit - (ProcessInfo.processInfo.systemUptime - started)))
        let agentCandidates = report.agentCacheCandidates + caches.candidates.filter { candidate in
            !report.agentCacheCandidates.contains { $0.id == candidate.id }
        }
        var assessments = report.assessments
        var warnings = report.warnings + caches.warnings
        var observedWorktrees = report.worktrees
        if let safetyEvaluator {
            let processes = processInspector.inspectProcesses(uid: Int(getuid()))
            let worktrees: Observation<[WorktreeRecord]>
            if let worktreeInspector {
                worktrees = worktreeInspector.inspect(root: root, processes: processes)
                observedWorktrees = worktrees.value
            } else {
                // No worktree evidence is inferred from the absence of a worktree collector.
                worktrees = Observation<[WorktreeRecord]>(value: report.worktrees, status: .unavailable,
                    warnings: ["Worktree inspection was not provided."], capturedAt: Date())
            }
            warnings.append(contentsOf: processes.warnings + worktrees.warnings)
            for candidate in report.candidates + agentCandidates {
                assessments[candidate.id] = safetyEvaluator.assess(candidate: candidate, processes: processes, worktrees: worktrees)
            }
        }
        return CleanupReport(candidates: report.candidates, warnings: Self.unique(warnings), partial: report.partial || caches.partial,
            agentCacheCandidates: agentCandidates, worktrees: observedWorktrees, assessments: assessments,
            discoveredCount: max(report.discoveredCount, report.candidates.count + report.agentCacheCandidates.count)
                + agentCandidates.count - report.agentCacheCandidates.count)
    }

    /// Scan each distinct workspace, but measure account-wide caches only once.
    public func scanCleanup(roots: [URL], homeDirectory: URL? = nil,
                            entryLimit: Int = 100_000, timeLimit: TimeInterval = 10.0) -> CleanupReport {
        let roots = Self.uniqueRoots(roots)
        let started = ProcessInfo.processInfo.systemUptime
        let budget = max(0, entryLimit)
        let projectBudget = roots.isEmpty ? 0 : budget / 2
        var candidates: [CleanupCandidate] = []
        var cacheCandidates: [CleanupCandidate] = []
        var warnings: [String] = []
        var partial = false
        var discoveredCount = 0
        var seen = Set<String>()
        for (index, root) in roots.enumerated() {
            let limit = projectBudget / roots.count + (index < projectBudget % roots.count ? 1 : 0)
            let remainingTime = max(0, timeLimit / 2 - (ProcessInfo.processInfo.systemUptime - started))
            let report = cleanupScanner.scan(root: root, entryLimit: limit,
                                             timeLimit: remainingTime / Double(roots.count - index))
            warnings.append(contentsOf: report.warnings)
            partial = partial || report.partial
            let newCandidates = report.candidates.filter { seen.insert($0.id).inserted }
            let newCaches = report.agentCacheCandidates.filter { seen.insert($0.id).inserted }
            candidates.append(contentsOf: newCandidates)
            cacheCandidates.append(contentsOf: newCaches)
            discoveredCount += max(report.discoveredCount, report.candidates.count + report.agentCacheCandidates.count)
                - (report.candidates.count - newCandidates.count) - (report.agentCacheCandidates.count - newCaches.count)
        }
        let caches = AgentCacheCatalog().scanAgentCaches(
            homeDirectory: homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser,
            entryLimit: budget - projectBudget,
            timeLimit: max(0, timeLimit - (ProcessInfo.processInfo.systemUptime - started)))
        let newCaches = caches.candidates.filter { seen.insert($0.id).inserted }
        cacheCandidates.append(contentsOf: newCaches)
        discoveredCount += newCaches.count
        warnings.append(contentsOf: caches.warnings)
        partial = partial || caches.partial

        let processes = processInspector.inspectProcesses(uid: Int(getuid()))
        let listeners = listenerInspector.inspectListeners(uid: Int(getuid()))
        let worktrees = inspectWorktrees(roots: roots, processes: processes)
        warnings.append(contentsOf: processes.warnings + listeners.warnings + worktrees.warnings)
        let assessments = liveSafetyEvaluator(homeDirectory: homeDirectory).evaluate(
            candidates: candidates + cacheCandidates, processes: processes, listeners: listeners, worktrees: worktrees)
        return CleanupReport(candidates: candidates, warnings: Self.unique(warnings), partial: partial,
            agentCacheCandidates: cacheCandidates, worktrees: worktrees.value, assessments: assessments,
            discoveredCount: discoveredCount)
    }

    /// Read-only preview. Trash execution requires a separate assessment for each candidate.
    public func reassessCandidatesForTrash(_ candidates: [CleanupCandidate], homeDirectory: URL? = nil) -> [String: SafetyAssessment] {
        let processes = processInspector.inspectProcesses(uid: Int(getuid()))
        let listeners = listenerInspector.inspectListeners(uid: Int(getuid()))
        let roots = Self.uniqueRoots(candidates.filter { $0.scope != .agentCache }.map(trashWorktreeRoot(for:)))
        let worktrees = inspectWorktrees(roots: roots, processes: processes)
        return liveSafetyEvaluator(homeDirectory: homeDirectory).evaluate(
            candidates: candidates, processes: processes, listeners: listeners, worktrees: worktrees)
    }

    /// Collect current evidence for one candidate during execution.
    public func assessCandidateForTrash(_ candidate: CleanupCandidate, homeDirectory: URL? = nil) -> SafetyAssessment {
        func incomplete(_ reason: String) -> SafetyAssessment {
            SafetyAssessment(candidateID: candidate.id, usage: .unknown,
                             regenerability: .unverified("Live safety evidence is incomplete"),
                             blockedReasons: [reason], isReviewableForTrash: false)
        }
        let uid = Int(getuid())
        let processes = processInspector.inspectProcesses(uid: uid)
        guard processes.status == .complete else {
            return incomplete("Process inventory could not be fully verified")
        }
        let listeners = listenerInspector.inspectListeners(uid: uid)
        guard listeners.status == .complete else {
            return incomplete("Listener inventory could not be fully verified")
        }
        let worktrees: Observation<[WorktreeRecord]>
        if candidate.scope == .agentCache {
            worktrees = Observation(value: [], status: .complete, warnings: [], capturedAt: Date())
        } else {
            worktrees = inspectWorktrees(roots: [trashWorktreeRoot(for: candidate)], processes: processes)
            guard worktrees.status == .complete else {
                return incomplete("Worktree inventory could not be fully verified")
            }
        }
        return liveSafetyEvaluator(homeDirectory: homeDirectory).assess(
            candidate: candidate, processes: processes, worktrees: worktrees)
    }

    private func trashWorktreeRoot(for candidate: CleanupCandidate) -> URL {
        let url = URL(fileURLWithPath: candidate.path)
        if candidate.scope == .worktree { return url }
        let parent = url.deletingLastPathComponent()
        return projectResolver.resolveProject(at: parent).value.map { URL(fileURLWithPath: $0.rootPath) } ?? parent
    }

    private func liveSafetyEvaluator(homeDirectory: URL?) -> any SafetyEvaluating {
        if let evaluator = safetyEvaluator as? SafetyEvaluator {
            return evaluator.forLiveAssessment(homeDirectory: homeDirectory)
        }
        return safetyEvaluator ?? SafetyEvaluator(
            homeDirectory: homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser,
            openFileCheck: { OpenFileInspector().checkPathInUse($0) })
    }

    private func inspectWorktrees(roots: [URL], processes: Observation<[ObservedProcess]>) -> Observation<[WorktreeRecord]> {
        guard let worktreeInspector else {
            return Observation(value: [], status: .unavailable,
                               warnings: ["Worktree inspection was not provided."], capturedAt: Date())
        }
        var records: [WorktreeRecord] = []
        var seen = Set<String>()
        var warnings: [String] = []
        var complete = true
        for root in roots {
            let observation = worktreeInspector.inspect(root: root, processes: processes)
            records.append(contentsOf: observation.value.filter { seen.insert($0.path).inserted })
            warnings.append(contentsOf: observation.warnings)
            complete = complete && observation.status == .complete
        }
        return Observation(value: records, status: complete ? .complete : .partial,
                           warnings: Self.unique(warnings), capturedAt: Date())
    }

    private static func uniqueRoots(_ roots: [URL]) -> [URL] {
        var seen = Set<String>()
        return roots.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
    }

    private static func unique(_ warnings: [String]) -> [String] {
        var seen = Set<String>()
        return warnings.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
