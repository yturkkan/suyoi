import Foundation

public struct SafetyDiagnosticDetail: Equatable, Sendable {
    public let headline: String
    public let checkName: String
    public let remediationHint: String
    public let canRecheck: Bool

    public init(headline: String, checkName: String, remediationHint: String, canRecheck: Bool) {
        self.headline = headline
        self.checkName = checkName
        self.remediationHint = remediationHint
        self.canRecheck = canRecheck
    }
}

/// Static explanations deliberately exclude raw paths, process names and error text.
public enum SafetyDiagnostics {
    public static func explain(assessment: SafetyAssessment, candidate: CleanupCandidate? = nil) -> SafetyDiagnosticDetail {
        let reasons = assessment.blockedReasons.map { String($0.prefix(2048)).lowercased() }
        func has(_ fragments: String...) -> Bool {
            reasons.contains { reason in fragments.contains { reason.contains($0) } }
        }
        func detail(_ headline: String, _ check: String, _ hint: String, _ recheck: Bool = true) -> SafetyDiagnosticDetail {
            SafetyDiagnosticDetail(headline: headline, checkName: check, remediationHint: hint, canRecheck: recheck)
        }
        // Structural protections precede transient usage and regenerability checks.
        if has("forbidden", "protected descendant", "protected path") || has("contains a sensitive path") {
            return detail("This item contains protected data", "Protected paths", "Keep this item. Sensitive paths and their parent directories are excluded from cleanup.", false)
        }
        if has("symlink", "identity", "outside the trusted root") {
            return detail("The item's identity could not be verified", "File identity", "Rescan the original directory. Cleanup requires a matching device and inode and a path without symlinks.")
        }
        if has("worktree is locked", "locked worktree", "git lock", "mid-merge") {
            return detail("Git is protecting this worktree", "Git worktree lock", "Finish the Git operation and review the worktree's lock state in Git, then rescan.")
        }
        if has("dirty worktree", "uncommitted changes", "worktree is dirty") {
            return detail("The worktree has uncommitted changes", "Git worktree changes", "Review and preserve your changes in Git before rescanning.")
        }
        if assessment.usage == .inUse || has("open files", "in use by", "currently running", "active process", "active agent", "active server") {
            return detail("This item is being used", "Active usage", "Finish the related work and close the processes or files using this item, then recheck.")
        }
        if assessment.usage == .unknown || candidate?.partial == true || has("partial", "budget", "could not be fully", "could not be verified", "unavailable", "incomplete", "observation", "record not found") {
            return detail("Safety evidence is incomplete", "Complete safety evidence", "Recheck after current activity settles. Cleanup stays blocked until process, listener and directory checks complete.")
        }
        if has("missing package.json") {
            return detail("The dependency manifest is missing", "Dependency manifest", "Restore the project's package.json from its trusted source, then rescan to verify dependencies can be recreated.")
        }
        if has("no lockfile", "missing lockfile") {
            return detail("A dependency lockfile is missing", "Dependency lockfile", "Restore or generate the project's valid lockfile with its package manager, then rescan.")
        }
        if has("manual", "high-impact", "high impact") || candidate.map({ AgentCacheCatalog.isHighImpactCachePath($0.path) }) == true {
            return detail("This cache needs individual review", "Manual cache review", "Review downloads, environments and runtime data individually before any explicit Trash action. This item is excluded from bulk cleanup.", false)
        }
        if assessment.isReviewableForTrash && assessment.blockedReasons.isEmpty {
            return detail("Safety checks passed at the last scan", "Safety checks", "Review the item before choosing Trash. Identity and usage will be checked again at execution.")
        }
        return detail("Cleanup safety has not been established", "Safety verification", "Review this item and rescan. Cleanup remains blocked until all required safety checks pass.")
    }

    public static func explainSteeringUnavailable(for agent: AgentObservation) -> SafetyDiagnosticDetail {
        guard agent.process.identity.isActionEligible else {
            return SafetyDiagnosticDetail(headline: "The agent's identity is incomplete", checkName: "Process identity",
                remediationHint: "Refresh the agent inventory. Steering requires a current, complete process identity.", canRecheck: true)
        }
        guard !agent.process.isStopped, agent.activityState != .stopped else {
            return SafetyDiagnosticDetail(headline: "The agent process is stopped", checkName: "Process activity",
                remediationHint: "Resume the agent in its terminal, then refresh the inventory.", canRecheck: true)
        }
        guard AgentSteerer.preferredMode(for: agent)?.isLiveTerminalDelivery == true else {
            return SafetyDiagnosticDetail(headline: "No supported terminal target is available", checkName: "Terminal association",
                remediationHint: "Use the agent in Terminal, iTerm2, or tmux and refresh. A session identifier alone does not prove live process ownership.", canRecheck: true)
        }
        return SafetyDiagnosticDetail(headline: "The steering target needs live verification", checkName: "Live steering verification",
            remediationHint: "Bring the agent to the foreground in its terminal and recheck. Sending requires a fresh identity, unique terminal association and foreground ownership check.", canRecheck: true)
    }
}
