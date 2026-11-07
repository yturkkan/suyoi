import Foundation

public struct SafetyEvaluator: SafetyEvaluating, Sendable {
    private let homeDirectory: URL
    private let openFileCheck: (@Sendable (String) -> UsageState)?
    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                openFileCheck: (@Sendable (String) -> UsageState)? = nil) {
        self.homeDirectory = homeDirectory
        self.openFileCheck = openFileCheck
    }

    /// Preserve an injected usage check while supplying live inspection when absent.
    func forLiveAssessment(homeDirectory: URL?) -> SafetyEvaluator {
        SafetyEvaluator(homeDirectory: homeDirectory ?? self.homeDirectory,
                        openFileCheck: openFileCheck ?? { OpenFileInspector().checkPathInUse($0) })
    }

    public func assess(candidate: CleanupCandidate, processes: Observation<[ObservedProcess]>, worktrees: Observation<[WorktreeRecord]>) -> SafetyAssessment {
        let reader = FileMetadataReader()
        let url = URL(fileURLWithPath: candidate.path)
        var reasons: [String] = []
        if !candidate.path.hasPrefix("/") || reader.canonicalPath(url, relativeTo: homeDirectory) == nil {
            reasons.append("Candidate path is unavailable, outside the trusted root, or contains a symlink")
        }
        if AgentCacheCatalog.isForbiddenPath(url, homeDirectory: homeDirectory) { reasons.append("Forbidden or sensitive path") }
        if candidate.partial { reasons.append("Candidate measurement is partial") }
        if let expected = candidate.fileIdentity {
            if reader.identity(at: url) != expected { reasons.append("Candidate file identity changed") }
        } else { reasons.append("Missing file identity (device/inode)") }
        var usage: UsageState = .unknown
        var regenerability: Regenerability = .unverified("Not verified")
        switch candidate.scope {
        case .agentCache:
            if AgentCacheCatalog.isAllowlisted(url: url, homeDirectory: homeDirectory) {
                regenerability = .cacheDirectory
            } else {
                regenerability = .unverified("Cache path is not allowlisted")
                reasons.append("Cache path is not allowlisted")
            }
            let cwd = NodeModulesSafety.workingDirectoryUsage(root: url, processes: processes)
            usage = cwd.0
            reasons.append(contentsOf: cwd.1)
            if let name = candidate.agentName,
               processes.value.contains(where: { AgentRecognizer.agentName(for: $0)?.caseInsensitiveCompare(name) == .orderedSame }) {
                usage = .inUse
                reasons.append("\(name) is currently running")
            }
            if let check = openFileCheck { usage = Self.combine(usage, check(candidate.path)) }
        case .projectArtifact:
            let result = NodeModulesSafety().assess(candidate: candidate, processes: processes)
            usage = result.usage; regenerability = result.regenerability
            reasons.append(contentsOf: result.blockedReasons)
            for tree in worktrees.value where NodeModulesSafety.contains(candidate.path, in: tree.path) {
                if worktrees.status != .complete { reasons.append("Worktree inventory could not be fully verified") }
                reasons.append(contentsOf: tree.blockedReasons)
                if tree.isDirty { reasons.append("Candidate is inside a dirty worktree") }
                if tree.usage != .clear {
                    if tree.usage == .inUse { usage = .inUse } else if usage == .clear { usage = .unknown }
                    reasons.append("Candidate worktree is in use or usage is unknown")
                }
            }
            if let check = openFileCheck { usage = Self.combine(usage, check(candidate.path)) }
        case .worktree:
            if worktrees.status != .complete { reasons.append("Worktree inventory could not be fully verified") }
            if let tree = worktrees.value.first(where: {
                URL(fileURLWithPath: $0.path).standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath()
            }) {
                usage = tree.usage
                reasons.append(contentsOf: tree.blockedReasons)
                if tree.isMain { reasons.append("Main working tree") }
                if tree.isDirty { reasons.append("Worktree has uncommitted changes") }
                if tree.isLocked { reasons.append("Worktree is locked") }
                if tree.isMergedToDefault != true { reasons.append("Worktree is not verified merged to the default branch") }
            } else { reasons.append("Worktree record not found") }
            // A clean/merged checkout is still source code, not a regenerable cache.
            regenerability = .unverified("Worktree regeneration is not verified")
            reasons.append("Worktree regeneration is not verified")
        }
        if candidate.scope == .agentCache {
            for tree in worktrees.value where NodeModulesSafety.contains(candidate.path, in: tree.path) {
                if worktrees.status != .complete { reasons.append("Worktree inventory could not be fully verified") }
                reasons.append(contentsOf: tree.blockedReasons)
                if tree.isDirty { reasons.append("Candidate is inside a dirty worktree") }
                usage = Self.combine(usage, tree.usage)
            }
        }
        if usage == .unknown { reasons.append("Active usage could not be verified") }
        if usage == .inUse && reasons.isEmpty { reasons.append("Candidate has open files") }
        let verified: Bool
        switch regenerability { case .lockfileVerified, .cacheDirectory: verified = true; case .unverified: verified = false }
        if reasons.isEmpty, usage == .clear, verified, let expected = candidate.fileIdentity,
           let blocker = reader.trashDescendantBlocker(at: url, expectedIdentity: expected, homeDirectory: homeDirectory) {
            reasons.append(blocker)
        }
        var seen = Set<String>()
        reasons = reasons.filter { seen.insert($0).inserted }
        return SafetyAssessment(candidateID: candidate.id, usage: usage, regenerability: regenerability, blockedReasons: reasons,
                                isReviewableForTrash: reasons.isEmpty && usage == .clear && verified && !candidate.partial && candidate.fileIdentity != nil)
    }

    private static func combine(_ a: UsageState, _ b: UsageState) -> UsageState {
        if a == .inUse || b == .inUse { return .inUse }
        return a == .unknown || b == .unknown ? .unknown : .clear
    }
}

// Catalog roots and direct non-sensitive children of ~/.cache are eligible cache roots.
extension AgentCacheCatalog {
    public static func isAllowlisted(url: URL, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let home = homeDirectory.standardizedFileURL.resolvingSymlinksInPath()
        return !isForbiddenPath(url, homeDirectory: home) && (Self.locations.map(\.0).contains {
            home.appendingPathComponent($0).standardizedFileURL == url.standardizedFileURL
        } || url.standardizedFileURL.deletingLastPathComponent() == home.appendingPathComponent(".cache").standardizedFileURL)
    }
}

public extension SafetyEvaluating {
    /// Assess a batch against one fresh inventory, failing closed on missing listeners.
    func evaluate(candidates: [CleanupCandidate], processes: Observation<[ObservedProcess]>,
                  listeners: Observation<[Listener]>, worktrees: Observation<[WorktreeRecord]>) -> [String: SafetyAssessment] {
        var assessments: [String: SafetyAssessment] = [:]
        for candidate in candidates {
            let assessment = assess(candidate: candidate, processes: processes, worktrees: worktrees)
            if listeners.status != .complete && assessment.usage != .inUse {
                assessments[candidate.id] = SafetyAssessment(candidateID: candidate.id, usage: .unknown,
                    regenerability: assessment.regenerability,
                    blockedReasons: assessment.blockedReasons + ["Listener inventory could not be fully verified"],
                    isReviewableForTrash: false)
            } else {
                assessments[candidate.id] = assessment
            }
        }
        return assessments
    }
}
