import Foundation
import Darwin
import Testing
@testable import SuyoiCore

// End-to-end execution safety regressions.
// Process identities are synthetic; command and Trash sinks are injected spies.
private final class ReviewState: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [ObservedProcess] = []
    private var trashPaths: [String] = []
    func setProcesses(_ value: [ObservedProcess]) { lock.lock(); defer { lock.unlock() }; processes = value }
    func snapshot() -> [ObservedProcess] { lock.lock(); defer { lock.unlock() }; return processes }
    func recordTrash(_ path: String) { lock.lock(); defer { lock.unlock() }; trashPaths.append(path) }
    func trashed() -> [String] { lock.lock(); defer { lock.unlock() }; return trashPaths }
}

private struct ReviewProcesses: ProcessInspecting {
    let state: ReviewState
    func inspectProcesses(uid: Int) -> Observation<[ObservedProcess]> {
        Observation(value: state.snapshot(), status: .complete, warnings: [], capturedAt: Date())
    }
}
private struct ReviewListeners: ListenerInspecting {
    func inspectListeners(uid: Int) -> Observation<[Listener]> {
        Observation(value: [], status: .complete, warnings: [], capturedAt: Date())
    }
}
private struct ReviewSteerRunner: CommandRunning {
    func run(_ request: CommandRequest) throws -> CommandResult {
        CommandResult(exitCode: 0, stdout: Data(), stderr: Data(), timedOut: false, truncated: false)
    }
}
private struct ReviewSteerLauncher: NativeAgentJobLaunching {
    func launch(executable: String, arguments: [String], workingDirectory: URL?) throws {}
}

@Suite("Independent review regressions")
struct ReviewRegressionTests {
    private func process(_ pid: Int, parent: Int = 1, executable: String = "/tools/node", cwd: String = "/fixture/project") -> ObservedProcess {
        ObservedProcess(pid: pid, parentPID: parent, uid: Int(getuid()), cpuPercent: 0, residentBytes: 0,
            executable: executable, startTimeMicroseconds: 100, cwd: cwd)
    }
    private func service(home: URL, state: ReviewState) -> InventoryService {
        InventoryService(processInspector: ReviewProcesses(state: state), listenerInspector: ReviewListeners(),
            safetyEvaluator: SafetyEvaluator(homeDirectory: home, openFileCheck: { _ in .clear }),
            worktreeInspector: WorktreeInspector())
    }
    private func cache(_ relative: String, home: URL) throws -> CleanupCandidate {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return CleanupCandidate(path: url.path, category: "Review fixture", bytes: 42, partial: false,
            scope: .agentCache, fileIdentity: FileMetadataReader().identity(at: url))
    }

    @Test func reviewSharedPortMustNotMergeAcrossCodingAgentEvenInSameProject() {
        let outer = process(700001)
        let agent = process(700002, parent: outer.pid, executable: "/tools/codex")
        let inner = process(700003, parent: agent.pid)
        let project = ProjectContext(rootPath: "/fixture/project", name: "Fixture", framework: nil,
            gitBranch: nil, gitCommit: nil, isWorktree: false)
        let groups = ProcessTree(processes: [outer, agent, inner]).groupServers(listeners: [
            Listener(pid: outer.pid, processName: "node", address: "127.0.0.1", port: 3000),
            Listener(pid: inner.pid, processName: "node", address: "::1", port: 3000)
        ], projectsByPath: [project.rootPath: project])
        #expect(groups.count == 2, "Agent boundary must survive shared-port merging")
        #expect(!groups.contains { $0.memberPIDs.contains(outer.pid) && $0.memberPIDs.contains(inner.pid) })
    }

    @Test func reviewHistoricalSessionMustNotAuthorizeSingletonDaemonSteering() throws {
        let fixture = try QuotaFixture(); defer { fixture.clean() }
        try fixture.write([
            ["type": "session_meta", "payload": ["id": "historical-session", "cwd": "/unrelated-workspace"]],
            ["type": "event_msg", "payload": ["type": "task_started"]]
        ], to: ".codex/sessions/2026/11/07/session.jsonl")
        let daemon = process(700011, executable: "/tools/codex", cwd: "/")
        let context = AgentTaskInspector(homeDirectory: fixture.home).inspect(agentName: "Codex",
            process: daemon, projectRoot: nil, allProcesses: [daemon])
        let selected = AgentObservation(id: daemon.pid, agentName: "Codex", process: daemon,
            project: nil, terminalApp: nil, statusSource: .processOnly, childServerPorts: [],
            sessionID: context.sessionID, sessionTitle: context.sessionTitle, currentTask: context.currentTask)
        let outcome = AgentSteerer(processLookup: { _, _ in daemon }, runner: ReviewSteerRunner(),
            executableResolver: { "/tools/" + $0 }, homeDirectory: fixture.home,
            nativeJobLauncher: ReviewSteerLauncher())
            .steer(agent: selected, prompt: "Review fixture: do no work", uid: Int(getuid()))
        #expect(!outcome.succeeded, "Unrelated historical session must not authorize a new instruction")
    }

    @Test func reviewNewProtectedDescendantMustBlockWholeDirectoryTrash() throws {
        let fixture = try QuotaFixture(); defer { fixture.clean() }
        let candidate = try cache(".cache/opencode", home: fixture.home)
        let sensitive = URL(fileURLWithPath: candidate.path).appendingPathComponent("credentials/protected.txt")
        try FileManager.default.createDirectory(at: sensitive.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("synthetic fixture only".utf8).write(to: sensitive)
        #expect(AgentCacheCatalog.isForbiddenPath(sensitive, homeDirectory: fixture.home))
        #expect(FileMetadataReader().identity(at: URL(fileURLWithPath: candidate.path)) == candidate.fileIdentity)
        let state = ReviewState()
        let inventory = service(home: fixture.home, state: state)
        let report = ActionExecutor(trashHandler: { url in state.recordTrash(url.path); return nil })
            .moveCandidatesToTrash(candidates: [candidate]) {
                inventory.assessCandidateForTrash($0, homeDirectory: fixture.home)
            }
        #expect(report.trashedCount == 0, "A newly protected child must protect its containing directory")
        #expect(state.trashed().isEmpty)
    }

    @Test func reviewBulkTrashMustRecheckSecondCandidateAfterFirstAction() throws {
        let fixture = try QuotaFixture(); defer { fixture.clean() }
        let first = try cache(".cache/opencode", home: fixture.home)
        let second = try cache(".cache/codex-runtimes", home: fixture.home)
        let state = ReviewState()
        let inventory = service(home: fixture.home, state: state)
        // Both items are clear in the preview; DashboardModel requests fresh evidence during execution.
        let assessments = inventory.reassessCandidatesForTrash([first, second], homeDirectory: fixture.home)
        #expect(assessments[first.id]?.isReviewableForTrash == true)
        #expect(assessments[second.id]?.isReviewableForTrash == true)
        let newlyActive = process(700021, executable: "/tools/python3", cwd: second.path)
        let report = ActionExecutor(trashHandler: { url in
            state.recordTrash(url.path)
            if url.path == first.path { state.setProcesses([newlyActive]) }
            return nil
        }).moveCandidatesToTrash(candidates: [first, second]) {
            inventory.assessCandidateForTrash($0, homeDirectory: fixture.home)
        }
        #expect(report.trashedCount == 1, "The second candidate became active after preflight")
        #expect(!state.trashed().contains(second.path))
        #expect(inventory.reassessCandidatesForTrash([second], homeDirectory: fixture.home)[second.id]?.isReviewableForTrash == false)
    }
}
