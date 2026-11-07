import Foundation
import Testing
@testable import SuyoiCore

@Suite("AlertEvaluatorTests")
struct AlertEvaluatorTests {
    private func agent(_ state: AgentActivityState? = .waiting, start: UInt64 = 10, uid: Int = 501, executable: String = "/bin/codex") -> AgentObservation {
        AgentObservation(id: 42, agentName: "Codex\n\u{001B}",
            process: ObservedProcess(pid: 42, parentPID: 1, uid: uid, cpuPercent: 0, residentBytes: 0, executable: executable, startTimeMicroseconds: start),
            project: ProjectContext(rootPath: "/private/secret", name: "Demo\n", framework: nil, gitBranch: nil, gitCommit: nil, isWorktree: false),
            terminalApp: nil, statusSource: .processOnly, childServerPorts: [], activityState: state,
            activityDetail: "PRIVATE_DETAIL", sessionID: "PRIVATE_SESSION", sessionTitle: "PRIVATE_TITLE", currentTask: "PRIVATE_TASK")
    }
    private func quota(_ percent: Double?, reset: TimeInterval? = 100, kind: QuotaWindowKind = .fiveHour, minutes: Int? = 300) -> QuotaWindow {
        QuotaWindow(kind: kind, windowMinutes: minutes, usedPercent: percent, resetsAt: reset.map(Date.init(timeIntervalSince1970:)))
    }
    private func statuses(_ windows: [QuotaWindow], provider: QuotaProvider = .codex) -> [QuotaProvider: ProviderQuotaStatus] {
        [provider: ProviderQuotaStatus(provider: provider, source: .localTelemetry, observedAt: Date(timeIntervalSince1970: 1), status: .complete, windows: windows)]
    }
    @Test func waitingStreaksAndAbsence() {
        var tracker = AlertStateTracker()
        #expect(tracker.evaluate(agents: [agent(), agent()], quotas: [:]).map(\.kind) == [.agentWaiting])
        #expect(tracker.evaluate(agents: [agent()], quotas: [:]).isEmpty)
        #expect(tracker.evaluate(agents: [agent(.active)], quotas: [:]).isEmpty)
        #expect(tracker.evaluate(agents: [agent()], quotas: [:]).count == 1)
        _ = tracker.evaluate(agents: [], quotas: [:])
        #expect(tracker.evaluate(agents: [agent()], quotas: [:]).count == 1)
    }
    @Test func contradictoryDuplicatesAndStoppedAgentsFailClosed() {
        var tracker = AlertStateTracker()
        #expect(tracker.evaluate(agents: [agent(), agent(.active)], quotas: [:]).isEmpty)
        #expect(tracker.evaluate(agents: [agent(.stopped)], quotas: [:]).isEmpty)
        #expect(tracker.evaluate(agents: [agent()], quotas: [:]).count == 1)
        #expect(tracker.evaluate(agents: [agent(), agent(nil)], quotas: [:]).isEmpty)
        #expect(tracker.evaluate(agents: [agent()], quotas: [:]).count == 1)
    }
    @Test func fullIdentityAndPrivacy() {
        var tracker = AlertStateTracker()
        let first = tracker.evaluate(agents: [agent()], quotas: [:])[0]
        #expect(first.body.contains("42"))
        #expect(first.body.contains("Demo"))
        #expect(!first.body.contains("PRIVATE"))
        #expect(!first.body.contains("/private"))
        #expect(!first.body.contains("\n"))
        #expect(!first.title.contains("\u{001B}"))
        #expect(!first.id.contains("/bin"))
        #expect(tracker.evaluate(agents: [agent(start: 11)], quotas: [:]).count == 1)
        #expect(tracker.evaluate(agents: [agent(start: 11, uid: 502)], quotas: [:]).count == 1)
        #expect(tracker.evaluate(agents: [agent(start: 11, uid: 502, executable: "/bin/other")], quotas: [:]).count == 1)
        var independent = AlertStateTracker()
        #expect(independent.evaluate(agents: [agent()], quotas: [:])[0].id == first.id)
    }
    @Test func warningEscalatesOnce() {
        var tracker = AlertStateTracker()
        #expect(tracker.evaluate(agents: [], quotas: statuses([quota(84)])).isEmpty)
        #expect(tracker.evaluate(agents: [], quotas: statuses([quota(85)])).map(\.kind) == [.quotaWarning])
        #expect(tracker.evaluate(agents: [], quotas: statuses([quota(90)])).isEmpty)
        #expect(tracker.evaluate(agents: [], quotas: statuses([quota(95)])).map(\.kind) == [.quotaCritical])
        #expect(tracker.evaluate(agents: [], quotas: statuses([quota(99)])).isEmpty)
        #expect(tracker.evaluate(agents: [], quotas: statuses([quota(87)])).isEmpty)
    }
    @Test func initialCriticalSkipsWarningAndLowUsageRearms() {
        var tracker = AlertStateTracker()
        #expect(tracker.evaluate(agents: [], quotas: statuses([quota(96)])).map(\.kind) == [.quotaCritical])
        #expect(tracker.evaluate(agents: [], quotas: statuses([quota(50)])).isEmpty)
        #expect(tracker.evaluate(agents: [], quotas: statuses([quota(20)])).isEmpty)
        #expect(tracker.evaluate(agents: [], quotas: statuses([quota(19)])).map(\.kind) == [.quotaReset])
        #expect(tracker.evaluate(agents: [], quotas: statuses([quota(10)])).isEmpty)
        #expect(tracker.evaluate(agents: [], quotas: statuses([quota(86)])).map(\.kind) == [.quotaWarning])
    }
    @Test func timestampResetAndDeduplication() {
        var tracker = AlertStateTracker()
        _ = tracker.evaluate(agents: [], quotas: statuses([quota(90), quota(90)]))
        #expect(tracker.evaluate(agents: [], quotas: statuses([quota(1, reset: 200), quota(1, reset: 200)])).map(\.kind) == [.quotaReset])
        #expect(tracker.evaluate(agents: [], quotas: statuses([quota(1, reset: 200)])).isEmpty)
        #expect(tracker.evaluate(agents: [], quotas: statuses([quota(90, reset: 200)])).map(\.kind) == [.quotaWarning])
        #expect(tracker.evaluate(agents: [], quotas: statuses([quota(96, reset: 300)])).map(\.kind) == [.quotaReset, .quotaCritical])
    }
    @Test func independentWindowsAndProviders() {
        var tracker = AlertStateTracker()
        let windows = [quota(90), quota(96, kind: .sevenDay, minutes: 10080)]
        let first = tracker.evaluate(agents: [], quotas: statuses(windows))
        #expect(first.map(\.kind) == [.quotaWarning, .quotaCritical])
        #expect(Set(first.map(\.id)).count == 2)
        #expect(tracker.evaluate(agents: [], quotas: statuses(windows, provider: .claude)).count == 2)
        #expect(tracker.evaluate(agents: [], quotas: statuses(windows)).isEmpty)
    }
    @Test func specializedWindowsAndAmbiguousDuplicatesAreIgnored() {
        var tracker = AlertStateTracker()
        #expect(tracker.evaluate(agents: [], quotas: statuses([quota(99, kind: .sevenDayOpus, minutes: 10080)])).isEmpty)
        #expect(tracker.evaluate(agents: [], quotas: statuses([quota(90), quota(96)])).isEmpty)
        #expect(tracker.evaluate(agents: [], quotas: statuses([quota(90)])).map(\.kind) == [.quotaWarning])
    }
    @Test func invalidReadingsDoNotChangeState() {
        var tracker = AlertStateTracker()
        for value in [Double.nan, .infinity, -.infinity, -1, 101] {
            #expect(tracker.evaluate(agents: [], quotas: statuses([quota(value)])).isEmpty)
        }
        _ = tracker.evaluate(agents: [], quotas: statuses([quota(90)]))
        #expect(tracker.evaluate(agents: [], quotas: statuses([quota(.nan, reset: 200)])).isEmpty)
        #expect(tracker.evaluate(agents: [], quotas: statuses([quota(90)])).isEmpty)
        #expect(tracker.evaluate(agents: [], quotas: statuses([quota(nil)])).isEmpty)
    }
    @Test func lowCustomThresholdsDoNotRepeatWhileUsageIsFlat() {
        var tracker = AlertStateTracker()
        #expect(tracker.evaluate(agents: [], quotas: statuses([quota(10)]), warningPercent: 10, criticalPercent: 15).map(\.kind) == [.quotaWarning])
        #expect(tracker.evaluate(agents: [], quotas: statuses([quota(10)]), warningPercent: 10, criticalPercent: 15).isEmpty)
        #expect(tracker.evaluate(agents: [], quotas: statuses([quota(15)]), warningPercent: 10, criticalPercent: 15).map(\.kind) == [.quotaCritical])
        #expect(tracker.evaluate(agents: [], quotas: statuses([quota(15)]), warningPercent: 10, criticalPercent: 15).isEmpty)
        #expect(tracker.evaluate(agents: [], quotas: statuses([quota(12)]), warningPercent: 10, criticalPercent: 15).isEmpty)
        #expect(tracker.evaluate(agents: [], quotas: statuses([quota(5)]), warningPercent: 10, criticalPercent: 15).map(\.kind) == [.quotaReset])
        #expect(tracker.evaluate(agents: [], quotas: statuses([quota(5)]), warningPercent: 10, criticalPercent: 15).isEmpty)
    }
    @Test func customThresholdsAndMissingDuration() {
        var tracker = AlertStateTracker()
        #expect(tracker.evaluate(agents: [], quotas: statuses([quota(60, minutes: nil)]), warningPercent: 60, criticalPercent: 70).map(\.kind) == [.quotaWarning])
        #expect(tracker.evaluate(agents: [], quotas: statuses([quota(70, minutes: nil)]), warningPercent: 60, criticalPercent: 70).map(\.kind) == [.quotaCritical])
        var invalid = AlertStateTracker()
        #expect(invalid.evaluate(agents: [], quotas: statuses([quota(99)]), warningPercent: .nan).isEmpty)
    }
}
