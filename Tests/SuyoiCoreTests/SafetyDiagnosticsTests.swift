import Foundation
import Testing
@testable import SuyoiCore

@Suite("SafetyDiagnosticsTests")
struct SafetyDiagnosticsTests {
    private func assessment(_ reasons: [String], usage: UsageState = .clear, ready: Bool = false) -> SafetyAssessment {
        SafetyAssessment(candidateID: "/private/SECRET_PATH", usage: usage, regenerability: .cacheDirectory, blockedReasons: reasons, isReviewableForTrash: ready)
    }
    private func agent(tty: String? = nil, terminal: String? = nil, start: UInt64? = 10, stopped: Bool = false) -> AgentObservation {
        AgentObservation(id: 42, agentName: "SECRET_AGENT", process: ObservedProcess(pid: 42, parentPID: 1, uid: 501, cpuPercent: 0, residentBytes: 0, executable: "/private/SECRET_PATH", startTimeMicroseconds: start, tty: tty, isStopped: stopped), project: nil, terminalApp: terminal, statusSource: .processOnly, childServerPorts: [], sessionID: "SECRET_SESSION", sessionTitle: "SECRET_TITLE", currentTask: "SECRET_TASK")
    }
    @Test func protectedPathsTakePriority() {
        let detail = SafetyDiagnostics.explain(assessment: assessment(["Worktree is locked", "Candidate contains a forbidden or sensitive path"]))
        #expect(detail.checkName == "Protected paths")
        #expect(!detail.canRecheck)
        #expect(detail.remediationHint.contains("Keep this item"))
        #expect(detail.remediationHint.contains("excluded from cleanup"))
    }
    @Test func lockedAndDirtyWorktrees() {
        let locked = SafetyDiagnostics.explain(assessment: assessment(["Worktree is locked"]))
        #expect(locked.checkName == "Git worktree lock")
        #expect(locked.remediationHint.contains("Finish the Git operation"))
        #expect(locked.canRecheck)
        #expect(SafetyDiagnostics.explain(assessment: assessment(["Worktree has uncommitted changes"])).checkName == "Git worktree changes")
    }
    @Test func usageAndDependencyMappings() {
        for reason in ["Candidate has open files", "Project is in use by SECRET (PID 100)", "SECRET is currently running", "Active server is using candidate"] {
            let detail = SafetyDiagnostics.explain(assessment: assessment([reason], usage: .inUse))
            #expect(detail.checkName == "Active usage")
            #expect(detail.canRecheck)
        }
        #expect(SafetyDiagnostics.explain(assessment: assessment(["Missing package.json in project root"])).checkName == "Dependency manifest")
        #expect(SafetyDiagnostics.explain(assessment: assessment(["No lockfile"])).checkName == "Dependency lockfile")
    }
    @Test func identityAndIncompleteEvidence() {
        for reason in ["Candidate file identity changed", "Missing file identity (device/inode)", "Candidate path is unavailable, outside the trusted root, or contains a symlink"] {
            #expect(SafetyDiagnostics.explain(assessment: assessment([reason])).checkName == "File identity")
        }
        for reason in ["Candidate contents could not be fully checked for sensitive paths", "Traversal budget exceeded", "Process observation is unavailable", "Candidate measurement is partial", "Listener inventory could not be fully verified"] {
            #expect(SafetyDiagnostics.explain(assessment: assessment([reason])).checkName == "Complete safety evidence")
        }
    }
    @Test func manualCachesAndSafeFallbacks() {
        let candidate = CleanupCandidate(path: "/private/SECRET_PATH/.venv", category: ".venv", bytes: 0, partial: false)
        let detail = SafetyDiagnostics.explain(assessment: assessment([], ready: true), candidate: candidate)
        #expect(detail.checkName == "Manual cache review")
        #expect(detail.remediationHint.contains("individually"))
        #expect(detail.remediationHint.contains("excluded from bulk cleanup"))
        #expect(!detail.canRecheck)
        #expect(SafetyDiagnostics.explain(assessment: assessment([], ready: true)).checkName == "Safety checks")
        #expect(SafetyDiagnostics.explain(assessment: assessment(["SECRET_RAW_ERROR /private/path"])).checkName == "Safety verification")
    }
    @Test func noRawDetailsEscape() {
        let detail = SafetyDiagnostics.explain(assessment: assessment(["SECRET_RAW_ERROR /private/path\n\u{001B}"]))
        let text = detail.headline + detail.checkName + detail.remediationHint
        #expect(!text.contains("SECRET"))
        #expect(!text.contains("/private"))
        #expect(!text.contains("\u{001B}"))
    }
    @Test func steeringFailsClosedAndNeedsLiveVerification() {
        #expect(SafetyDiagnostics.explainSteeringUnavailable(for: agent(start: nil)).checkName == "Process identity")
        #expect(SafetyDiagnostics.explainSteeringUnavailable(for: agent()).checkName == "Terminal association")
        #expect(SafetyDiagnostics.explainSteeringUnavailable(for: agent(tty: "not-a-tty", terminal: "Terminal")).checkName == "Terminal association")
        #expect(SafetyDiagnostics.explainSteeringUnavailable(for: agent(tty: "ttys001", terminal: "Other")).checkName == "Terminal association")
        #expect(SafetyDiagnostics.explainSteeringUnavailable(for: agent(tty: "ttys001", terminal: "Terminal", stopped: true)).checkName == "Process activity")
        #expect(SafetyDiagnostics.explainSteeringUnavailable(for: agent(tty: "ttys001", terminal: "tmux", stopped: true)).checkName == "Process activity")
        for terminal in ["Terminal", "tmux"] {
            let detail = SafetyDiagnostics.explainSteeringUnavailable(for: agent(tty: "ttys001", terminal: terminal))
            #expect(detail.checkName == "Live steering verification")
            #expect(detail.canRecheck)
            #expect(!(detail.headline + detail.remediationHint).contains("SECRET"))
        }
    }
}
