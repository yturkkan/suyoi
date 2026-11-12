import Foundation
import Testing
import SuyoiCore

struct ContractTests {
    @Test func phase4AgentContextRoundTripsAndDefaultsForLegacyPayloads() throws {
        let legacy = Data(#"{"id":42,"agentName":"Codex","process":{"pid":42,"parentPID":1,"uid":501,"cpuPercent":0,"residentBytes":0,"executable":"/bin/codex"},"statusSource":{"processOnly":{}},"childServerPorts":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(AgentObservation.self, from: legacy)
        #expect(decoded.sessionID == nil && decoded.sessionTitle == nil && decoded.currentTask == nil)
        let defaults = AgentObservation(id: 42, agentName: "Codex", process: decoded.process,
            project: nil, terminalApp: nil, statusSource: .processOnly, childServerPorts: [])
        #expect(defaults == decoded)
        try roundTrip(defaults)
        let enriched = AgentObservation(id: 42, agentName: "Codex", process: decoded.process,
            project: nil, terminalApp: "Terminal", statusSource: .verifiedAdapter("fixture"),
            childServerPorts: [], sessionID: "00000000-0000-4000-8000-000000000042",
            sessionTitle: "Contract checks", currentTask: "Running: swift test")
        try roundTrip(enriched)
        #expect(enriched.sessionID == "00000000-0000-4000-8000-000000000042")
        #expect(enriched.sessionTitle == "Contract checks")
        #expect(enriched.currentTask == "Running: swift test")
        var payload = try #require(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        for key in ["sessionID", "sessionTitle", "currentTask"] { payload[key] = NSNull() }
        #expect(try JSONDecoder().decode(AgentObservation.self,
            from: JSONSerialization.data(withJSONObject: payload)) == defaults)
    }

    @Test func steeringContractsRoundTripAndSupportIndependentImplementations() throws {
        for mode in [AgentSteerMode.terminalTTY, .tmuxPane, .weztermPane, .kittyWindow, .openCodeSession, .codexResume, .claudeResume, .geminiResume] {
            try roundTrip(mode)
            try roundTrip(AgentSteerOutcome(agentID: 42, mode: mode, succeeded: true, detail: "Submitted"))
            try roundTrip(AgentSteerOutcome(agentID: 42, mode: mode, succeeded: false, error: "Identity mismatch"))
            try roundTrip(AgentSteerOutcome(agentID: 42, mode: mode, succeeded: false))
        }
        #expect(AgentSteerMode.terminalTTY.isLiveTerminalDelivery)
        #expect(AgentSteerMode.tmuxPane.isLiveTerminalDelivery)
        #expect(AgentSteerMode.weztermPane.isLiveTerminalDelivery)
        #expect(AgentSteerMode.kittyWindow.isLiveTerminalDelivery)
        #expect(!AgentSteerMode.openCodeSession.isLiveTerminalDelivery)
        #expect(!AgentSteerMode.codexResume.isLiveTerminalDelivery)
        #expect(!AgentSteerMode.claudeResume.isLiveTerminalDelivery)
        #expect(!AgentSteerMode.geminiResume.isLiveTerminalDelivery)
        let minimal = Data(#"{"agentID":42,"mode":"terminalTTY","succeeded":false}"#.utf8)
        let outcome = try JSONDecoder().decode(AgentSteerOutcome.self, from: minimal)
        #expect(outcome.detail == nil && outcome.error == nil)
        let process = ObservedProcess(pid: 42, parentPID: 1, uid: 501, cpuPercent: 0,
                                      residentBytes: 0, executable: "/bin/codex")
        let agent = AgentObservation(id: 42, agentName: "Codex", process: process,
            project: nil, terminalApp: nil, statusSource: .processOnly, childServerPorts: [])
        let steering: any AgentSteering = SteeringContractFixture()
        #expect(steering.steer(agent: agent, prompt: "Fixture only", uid: 501)
            == AgentSteerOutcome(agentID: 42, mode: .codexResume, succeeded: false, error: "Fixture unavailable"))
    }

    @Test func legacyPayloadsRetainRequiredFieldsAndDefaultEnrichment() throws {
        let decoder = JSONDecoder()
        let process = try decoder.decode(ObservedProcess.self, from: Data(#"{"pid":42,"parentPID":1,"uid":501,"cpuPercent":0.5,"residentBytes":1024,"executable":"/bin/codex"}"#.utf8))
        #expect(process.startTimeMicroseconds == nil)
        #expect(process.cwd == nil && process.tty == nil && !process.isStopped)
        #expect(process.footprintBytes == nil && process.cpuNanoseconds == nil)
        #expect(!process.identity.isActionEligible)
        let snapshot = try decoder.decode(InventorySnapshot.self, from: Data(#"{"processes":[],"listeners":[],"warnings":[],"capturedAt":0}"#.utf8))
        #expect(snapshot.agentObservations.isEmpty && snapshot.serverGroups.isEmpty && snapshot.projectsByPath.isEmpty)
        let report = try decoder.decode(CleanupReport.self, from: Data(#"{"candidates":[{"path":"/project/.build","category":"Swift build output","bytes":10,"partial":false}],"warnings":[],"partial":false}"#.utf8))
        #expect(report.candidates.first?.scope == .projectArtifact)
        #expect(report.candidates.first?.allocatedBytes == nil && report.candidates.first?.fileIdentity == nil && report.candidates.first?.agentName == nil)
        #expect(report.agentCacheCandidates.isEmpty && report.worktrees.isEmpty && report.assessments.isEmpty && report.discoveredCount == 0)
        #expect(throws: DecodingError.self) { try decoder.decode(ObservedProcess.self, from: Data(#"{"pid":42}"#.utf8)) }
        #expect(throws: DecodingError.self) { try decoder.decode(CleanupCandidate.self, from: Data(#"{"path":"/project/.build"}"#.utf8)) }
        #expect(throws: DecodingError.self) { try decoder.decode(InventorySnapshot.self, from: Data(#"{"processes":[]}"#.utf8)) }
        #expect(throws: DecodingError.self) { try decoder.decode(CleanupReport.self, from: Data(#"{"candidates":[]}"#.utf8)) }
    }

    @Test func identityRequiresAllMetadataAndIgnoresEncodedEligibility() throws {
        for identity in [
            ProcessIdentity(pid: 0, uid: 501, startTimeMicroseconds: 1, executablePath: "/bin/tool"),
            ProcessIdentity(pid: 42, uid: -1, startTimeMicroseconds: 1, executablePath: "/bin/tool"),
            ProcessIdentity(pid: 42, uid: 501, startTimeMicroseconds: nil, executablePath: "/bin/tool"),
            ProcessIdentity(pid: 42, uid: 501, startTimeMicroseconds: 0, executablePath: "/bin/tool"),
            ProcessIdentity(pid: 42, uid: 501, startTimeMicroseconds: 1, executablePath: "tool"),
            ProcessIdentity(pid: 42, uid: 501, startTimeMicroseconds: 1, executablePath: "")
        ] { #expect(!identity.isActionEligible) }
        let forged = Data(#"{"pid":42,"uid":501,"startTimeMicroseconds":null,"executablePath":"/bin/tool","isActionEligible":true}"#.utf8)
        #expect(!(try JSONDecoder().decode(ProcessIdentity.self, from: forged)).isActionEligible)
        #expect(ProcessIdentity(pid: 42, uid: 0, startTimeMicroseconds: 1, executablePath: "/bin/tool").isActionEligible)
    }

    @Test func enrichedContractsRoundTripWithoutLosingEvidence() throws {
        let process = ObservedProcess(pid: 42, parentPID: 1, uid: 501, cpuPercent: 1.5, residentBytes: 100, executable: "/usr/local/bin/node", startTimeMicroseconds: 55, cwd: "/project", tty: "ttys001", isStopped: true, footprintBytes: 120, cpuNanoseconds: 500, agentInvocation: AgentInvocation(agentName: "Claude Code", runtime: "node", entrypoint: "claude"))
        #expect(process.agentName == "Claude Code")
        let project = ProjectContext(rootPath: "/project", name: "project", framework: "Swift", gitBranch: "feature", gitCommit: "abc", isWorktree: true)
        let listener = Listener(pid: 42, processName: "node", address: "::1", port: 3000)
        let agent = AgentObservation(id: 42, agentName: "Claude Code", process: process, project: project, terminalApp: "Terminal", statusSource: .verifiedAdapter("fixture"), childServerPorts: [3000], activityState: .waiting, activityDetail: "Idle on TTY", lastActivityAt: Date(timeIntervalSince1970: 2), terminalPID: 10)
        let server = ServerGroup(id: "server", rootPID: 42, name: "project", memberPIDs: [42], listeners: [listener], project: project, cpuPercent: 1.5, residentBytes: 100, footprintBytes: 120, startedAt: Date(timeIntervalSince1970: 1), stoppedByAgentBoundary: true)
        let candidate = CleanupCandidate(path: "/project/.build", category: "Swift", bytes: 100, partial: false, scope: .agentCache, allocatedBytes: 128, fileIdentity: FileIdentity(device: 1, inode: 2), agentName: "Codex")
        let assessment = SafetyAssessment(candidateID: candidate.id, usage: .unknown, regenerability: .lockfileVerified("lock"), blockedReasons: ["Unknown usage"], isReviewableForTrash: false)
        let worktree = WorktreeRecord(path: "/project", branch: "feature", headCommit: "abc", isMain: false, isDirty: true, isLocked: false, isMergedToDefault: nil, usage: .inUse, blockedReasons: ["Dirty"])
        try roundTrip(InventorySnapshot(processes: [process], listeners: [listener], warnings: ["partial"], capturedAt: Date(timeIntervalSince1970: 1), agentObservations: [agent], serverGroups: [server], projectsByPath: [project.rootPath: project]))
        try roundTrip(CleanupReport(candidates: [candidate], warnings: [], partial: true, agentCacheCandidates: [candidate], worktrees: [worktree], assessments: [candidate.id: assessment], discoveredCount: 1))
        try roundTrip(ActionPreview(id: "preview", createdAt: Date(timeIntervalSince1970: 1), candidates: [candidate], assessments: [candidate.id: assessment], blockedCount: 1, eligibleCount: 0, totalLogicalBytes: 100, totalAllocatedBytes: 128))
        try roundTrip(ProcessExecutionReport(outcomes: [ProcessActionOutcome(pid: 42, signal: 15, succeeded: true)], warnings: []))
        try roundTrip(TrashExecutionReport(outcomes: [TrashItemOutcome(candidateID: candidate.id, path: candidate.path, trashedURL: "/Users/test/.Trash/.build", bytes: 100, succeeded: true)], warnings: []))
        try roundTrip(Observation(value: [process], status: .partial, warnings: ["limited"], capturedAt: Date(timeIntervalSince1970: 1)))
        try roundTrip(process.identity)
        try roundTrip(AgentStatusSource.processOnly)
        try roundTrip(AgentActivityState.waiting)
        try roundTrip(Regenerability.cacheDirectory)
        try roundTrip(Regenerability.unverified("reason"))
    }

    @Test func publicProtocolsSupportIndependentImplementations() {
        let fixture = ContractFixture()
        let processes: any ProcessInspecting = fixture
        let listeners: any ListenerInspecting = fixture
        let projects: any ProjectResolving = fixture
        let cleanup: any CleanupScanning = CleanupScanner()
        let safety: any SafetyEvaluating = fixture
        let root = URL(fileURLWithPath: "/fixture/not-present")
        #expect(processes.inspectProcesses(uid: 501).status == .unavailable)
        #expect(listeners.inspectListeners(uid: 501).status == .complete)
        #expect(projects.resolveProject(at: root).value == nil)
        #expect(cleanup.scan(root: root, entryLimit: 0, timeLimit: 0).partial)
        let candidate = CleanupCandidate(path: root.path, category: "Fixture", bytes: 0, partial: true)
        #expect(!safety.assess(candidate: candidate, processes: fixture.inspectProcesses(uid: 501), worktrees: Observation(value: [], status: .unavailable, warnings: [], capturedAt: Date())).isReviewableForTrash)
    }

    @Test func quotaContractsRoundTripWithSeparateSourcesAndWindows() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = [300, 10080].map { minutes in
            TokenUsageSummary(windowMinutes: minutes,
                startedAt: date.addingTimeInterval(-Double(minutes * 60)), endedAt: date,
                inputTokens: 100, outputTokens: 50, cacheReadTokens: 30,
                cacheCreationTokens: 20, reasoningTokens: 10, totalTokens: 210, status: .partial)
        }
        let local = ProviderQuotaStatus(provider: .codex, source: .localTelemetry,
            observedAt: date, status: .partial, planType: "pro",
            windows: [QuotaWindow(kind: .fiveHour, windowMinutes: 300, usedPercent: 25,
                                  resetsAt: date.addingTimeInterval(60)),
                      QuotaWindow(kind: .sevenDay, windowMinutes: 10080, usedPercent: 75)],
            tokenUsage: usage, credits: QuotaCredits(hasCredits: true, unlimited: false, balance: 12.5),
            lastActivityAt: date, warnings: ["Scan budget reached"])
        let live = ProviderQuotaStatus(provider: .claude, source: .liveAPI,
            observedAt: date, status: .complete, planType: "max",
            windows: [QuotaWindow(kind: .fiveHour, windowMinutes: 300, usedPercent: 0),
                      QuotaWindow(kind: .sevenDay, windowMinutes: 10080, usedPercent: 20),
                      QuotaWindow(kind: .sevenDayOpus, windowMinutes: 10080, usedPercent: 40),
                      QuotaWindow(kind: .sevenDaySonnet, windowMinutes: 10080, usedPercent: 10)],
            extraUsage: QuotaExtraUsage(isEnabled: true, used: 12, limit: 100, currency: "USD"))
        let snapshot = QuotaSnapshot(capturedAt: date, providers: [local, live])
        try roundTrip(snapshot)
        #expect(snapshot.quotaSummary(for: "Codex", source: .localTelemetry) == local)
        #expect(snapshot.quotaSummary(for: "Claude Code", source: .liveAPI) == live)
        #expect(snapshot.quotaSummary(for: "Codex", source: .liveAPI) == nil)
        #expect(snapshot.quotaSummary(for: "Unknown", source: .localTelemetry) == nil)
        #expect(QuotaSnapshot(capturedAt: date, providers: [local, local])
            .quotaSummary(for: "Codex", source: .localTelemetry) == nil)
        for provider in QuotaProvider.allCases { try roundTrip(provider) }
    }

    @Test func quotaUnknownIsNotZeroAndLegacyAgentNeedsNoQuota() throws {
        let date = Date(timeIntervalSince1970: 1)
        let unknown = TokenUsageSummary(windowMinutes: 300, startedAt: date, endedAt: date, status: .unavailable)
        let zero = TokenUsageSummary(windowMinutes: 300, startedAt: date, endedAt: date,
                                     inputTokens: 0, outputTokens: 0, totalTokens: 0, status: .complete)
        try roundTrip(unknown)
        try roundTrip(zero)
        #expect(unknown.inputTokens == nil && zero.inputTokens == 0)
        #expect(unknown != zero)
        try roundTrip(QuotaWindow(kind: .fiveHour))
        try roundTrip(QuotaCredits())
        try roundTrip(QuotaExtraUsage())
        try roundTrip(ProviderQuotaStatus(provider: .gemini, source: .localTelemetry,
                                         observedAt: date, status: .unavailable))
        let legacy = Data(#"{"id":42,"agentName":"Codex","process":{"pid":42,"parentPID":1,"uid":501,"cpuPercent":0,"residentBytes":0,"executable":"/bin/codex"},"statusSource":{"processOnly":{}},"childServerPorts":[]}"#.utf8)
        let agent = try JSONDecoder().decode(AgentObservation.self, from: legacy)
        #expect(QuotaSnapshot(capturedAt: date).quotaSummary(for: agent.agentName, source: .localTelemetry) == nil)
    }

    @Test func quotaProtocolsSupportIndependentImplementations() async throws {
        let fixture = QuotaContractFixture()
        let local: any QuotaInspecting = fixture
        let live: any LiveQuotaPolling = fixture
        let date = Date(timeIntervalSince1970: 1)
        #expect(local.inspectQuotas(at: date) == QuotaSnapshot(capturedAt: date))
        let disabled = await live.pollQuota(for: .codex, permission: .disabled, at: date)
        #expect(disabled.status == .unavailable && disabled.windows.isEmpty)
        let requested = await live.pollQuota(for: .claude, permission: .userInitiated, at: date)
        #expect(requested.provider == .claude && requested.source == .liveAPI)
        try roundTrip(disabled)
        try roundTrip(requested)
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws {
        #expect(try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value)) == value)
    }
}

private struct ContractFixture: ProcessInspecting, ListenerInspecting, ProjectResolving, SafetyEvaluating {
    func inspectProcesses(uid: Int) -> Observation<[ObservedProcess]> {
        Observation(value: [], status: .unavailable, warnings: ["fixture unavailable"], capturedAt: Date())
    }
    func inspectListeners(uid: Int) -> Observation<[Listener]> {
        Observation(value: [], status: .complete, warnings: [], capturedAt: Date())
    }
    func resolveProject(at directory: URL) -> Observation<ProjectContext?> {
        Observation(value: nil, status: .partial, warnings: ["fixture unresolved"], capturedAt: Date())
    }
    func assess(candidate: CleanupCandidate, processes: Observation<[ObservedProcess]>, worktrees: Observation<[WorktreeRecord]>) -> SafetyAssessment {
        SafetyAssessment(candidateID: candidate.id, usage: .unknown, regenerability: .unverified("fixture"), blockedReasons: ["Unknown usage"], isReviewableForTrash: false)
    }
}

private struct QuotaContractFixture: QuotaInspecting, LiveQuotaPolling {
    func inspectQuotas(at date: Date) -> QuotaSnapshot {
        QuotaSnapshot(capturedAt: date)
    }

    func pollQuota(for provider: QuotaProvider, permission: LiveQuotaPermission, at date: Date) async -> ProviderQuotaStatus {
        ProviderQuotaStatus(provider: provider, source: .liveAPI, observedAt: date,
                            status: .unavailable,
                            warnings: [permission == .disabled ? "Live polling disabled" : "Fixture unavailable"])
    }
}

private struct SteeringContractFixture: AgentSteering {
    func steer(agent: AgentObservation, prompt: String, uid: Int) -> AgentSteerOutcome {
        AgentSteerOutcome(agentID: agent.id, mode: .codexResume, succeeded: false, error: "Fixture unavailable")
    }
}
