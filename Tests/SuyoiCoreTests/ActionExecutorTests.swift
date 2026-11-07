import Foundation
import Darwin
import Testing
@testable import SuyoiCore

private final class ActionCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var signals: [(Int32, Int32)] = []
    private var paths: [String] = []
    private var assessments: [String] = []
    func signal(_ pid: Int32, _ signal: Int32) { lock.lock(); defer { lock.unlock() }; signals.append((pid, signal)) }
    func trash(_ url: URL) { lock.lock(); defer { lock.unlock() }; paths.append(url.path) }
    func assess(_ candidate: CleanupCandidate) { lock.lock(); defer { lock.unlock() }; assessments.append(candidate.path) }
    var sent: [(Int32, Int32)] { lock.lock(); defer { lock.unlock() }; return signals }
    var trashed: [String] { lock.lock(); defer { lock.unlock() }; return paths }
    var assessed: [String] { lock.lock(); defer { lock.unlock() }; return assessments }
}

private struct ActionFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("suyoi-actions-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func candidate(_ path: String, partial: Bool = false, identity: FileIdentity? = nil) throws -> CleanupCandidate {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return CleanupCandidate(path: url.path, category: "fixture", bytes: 42, partial: partial,
            fileIdentity: identity ?? FileMetadataReader().identity(at: url))
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private func actionAssessment(_ candidate: CleanupCandidate, allowed: Bool = true) -> SafetyAssessment {
    SafetyAssessment(candidateID: candidate.id, usage: allowed ? .clear : .inUse, regenerability: .cacheDirectory,
        blockedReasons: allowed ? [] : ["In use"], isReviewableForTrash: allowed)
}

private struct ActionEvidenceFixture: ProcessInspecting, ListenerInspecting, CommandRunning {
    let processes: ObservationStatus
    let listeners: ObservationStatus

    func inspectProcesses(uid: Int) -> Observation<[ObservedProcess]> {
        Observation(value: [], status: processes, warnings: [], capturedAt: Date())
    }

    func inspectListeners(uid: Int) -> Observation<[Listener]> {
        Observation(value: [], status: listeners, warnings: [], capturedAt: Date())
    }

    func run(_ request: CommandRequest) throws -> CommandResult {
        throw CocoaError(.fileReadNoPermission)
    }
}

struct ActionExecutorTests {
    private func process(pid: Int = 2_000_000_001, parent: Int = 1, uid: Int = 501, start: UInt64 = 100, executable: String = "/usr/bin/node") -> ObservedProcess {
        ObservedProcess(pid: pid, parentPID: parent, uid: uid, cpuPercent: 0, residentBytes: 0,
            executable: executable, startTimeMicroseconds: start)
    }

    @Test func matchingProcessReceivesRequestedSignal() {
        let live = process()
        let calls = ActionCalls()
        let executor = ActionExecutor(processLookup: { _, _ in live }, signalSender: { pid, sig in calls.signal(pid, sig); return 0 })
        let normal = executor.stopProcess(identity: live.identity, uid: 501)
        let force = executor.stopProcess(identity: live.identity, force: true, uid: 501)
        #expect(normal.succeededCount == 1)
        #expect(normal.failedCount == 0)
        #expect(force.outcomes.first?.signal == SIGKILL)
        #expect(calls.sent.map { $0.1 } == [SIGTERM, SIGKILL])
    }

    @Test func staleOrMissingProcessesNeverReceiveSignals() {
        let expected = process().identity
        let variants: [ObservedProcess?] = [process(start: 101), process(executable: "/bin/python"), process(uid: 502),
                                           process(pid: 2_000_000_002), nil]
        for live in variants {
            let calls = ActionCalls()
            let executor = ActionExecutor(processLookup: { _, _ in live }, signalSender: { pid, sig in calls.signal(pid, sig); return 0 })
            let report = executor.stopProcess(identity: expected, uid: 501)
            #expect(report.failedCount == 1)
            #expect(report.outcomes.first?.error == "Process identity changed or process already exited")
            #expect(calls.sent.isEmpty)
        }
    }

    @Test func invalidIdentityAndWrongCallerNeverLookupOrSignal() {
        let calls = ActionCalls()
        let executor = ActionExecutor(processLookup: { pid, _ in calls.signal(pid, 0); return nil },
            signalSender: { pid, sig in calls.signal(pid, sig); return 0 })
        let identities = [process(uid: 502).identity, process(pid: 1).identity, process(pid: Int(getpid())).identity,
                          process(start: 0).identity, process(executable: "node").identity,
                          process(pid: Int(Int32.max) + 1).identity]
        for identity in identities { #expect(executor.stopProcess(identity: identity, uid: 501).failedCount == 1) }
        #expect(calls.sent.isEmpty)
    }

    @Test func signalDeliveryFailureIsReported() {
        let live = process()
        let executor = ActionExecutor(processLookup: { _, _ in live }, signalSender: { _, _ in -1 })
        let report = executor.stopProcess(identity: live.identity, uid: 501)
        #expect(report.failedCount == 1)
        #expect(report.outcomes.first?.error != nil)
    }

    @Test func serverMembersStopChildrenFirstAndRespectAgentBoundary() {
        let root = process(pid: 2_000_000_001, executable: "/bin/codex")
        let child = process(pid: 2_000_000_002, parent: root.pid)
        let grandchild = process(pid: 2_000_000_003, parent: child.pid)
        let rows = [root, child, grandchild]
        let calls = ActionCalls()
        let executor = ActionExecutor(processLookup: { pid, _ in rows.first { $0.pid == Int(pid) } },
            signalSender: { pid, sig in calls.signal(pid, sig); return 0 })
        func group(_ boundary: Bool, members: [Int]) -> ServerGroup {
            ServerGroup(id: "fixture", rootPID: root.pid, name: "fixture", memberPIDs: members, listeners: [], project: nil,
                cpuPercent: nil, residentBytes: 0, footprintBytes: nil, startedAt: nil, stoppedByAgentBoundary: boundary)
        }
        let bounded = executor.stopServerGroup(group: group(true, members: [root.pid, child.pid, grandchild.pid, child.pid]), processes: rows, uid: 501)
        #expect(bounded.succeededCount == 2)
        #expect(bounded.warnings.count == 1)
        #expect(calls.sent.map { Int($0.0) } == [grandchild.pid, child.pid])
        let full = executor.stopServerGroup(group: group(false, members: [root.pid, child.pid, grandchild.pid]), processes: rows, force: true, uid: 501)
        #expect(full.outcomes.map { $0.pid } == [grandchild.pid, child.pid, root.pid])
        #expect(full.outcomes.allSatisfy { $0.signal == SIGKILL })
        let fallback = executor.stopServerGroup(group: group(false, members: []), processes: rows, uid: 501)
        #expect(fallback.outcomes.map { $0.pid } == [root.pid])
        let missing = executor.stopServerGroup(group: group(false, members: [99]), processes: rows, uid: 501)
        #expect(missing.failedCount == 1)
    }

    @Test func eligibleCandidatesUseTrashHandlerAndDeduplicateOverlap() throws {
        let fixture = try ActionFixture(); defer { fixture.remove() }
        let parent = try fixture.candidate("project/dist")
        let child = try fixture.candidate("project/dist/nested")
        let other = try fixture.candidate("project/dist-other")
        let calls = ActionCalls()
        let executor = ActionExecutor(trashHandler: { url in calls.trash(url); return url.appendingPathExtension("trashed") })
        let report = executor.moveCandidatesToTrash(candidates: [child, parent, other, parent]) { candidate in
            calls.assess(candidate)
            return actionAssessment(candidate)
        }
        #expect(report.trashedCount == 2)
        #expect(report.reclaimedBytes == 84)
        #expect(calls.trashed == [parent.path, other.path])
        #expect(calls.assessed == [parent.path, other.path])
        #expect(report.outcomes.filter { !$0.succeeded }.count == 2)
        #expect(report.outcomes.filter { $0.succeeded }.allSatisfy { $0.trashedURL?.hasSuffix(".trashed") == true })
    }

    @Test func dictionaryApprovalAloneNeverReachesTrash() throws {
        let fixture = try ActionFixture(); defer { fixture.remove() }
        let candidate = try fixture.candidate("project/dist")
        let calls = ActionCalls()
        let executor: any ActionExecuting = ActionExecutor(trashHandler: { url in calls.trash(url); return nil })
        let report = executor.moveCandidatesToTrash(candidates: [candidate], assessments: [candidate.id: actionAssessment(candidate)])
        #expect(report.trashedCount == 0)
        #expect(report.reclaimedBytes == 0)
        #expect(report.outcomes.count == 1)
        #expect(report.outcomes.first?.error != nil)
        #expect(calls.trashed.isEmpty)
    }

    @Test(arguments: ["clear", "partialProcesses", "partialListeners", "missingWorktree", "partialWorktree", "unknownOpenFiles"])
    func trashRequiresCompleteLiveEvidence(_ scenario: String) throws {
        let fixture = try ActionFixture(); defer { fixture.remove() }
        let candidate = try fixture.candidate("project/dist")
        let project = URL(fileURLWithPath: candidate.path).deletingLastPathComponent()
        try Data("{}".utf8).write(to: project.appendingPathComponent("package.json"))
        if scenario == "partialWorktree" {
            try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: false)
        }
        let collectors = ActionEvidenceFixture(
            processes: scenario == "partialProcesses" ? .partial : .complete,
            listeners: scenario == "partialListeners" ? .partial : .complete
        )
        let service = InventoryService(processInspector: collectors, listenerInspector: collectors,
            safetyEvaluator: SafetyEvaluator(homeDirectory: fixture.root, openFileCheck: { _ in
                scenario == "unknownOpenFiles" ? .unknown : .clear
            }), worktreeInspector: scenario == "missingWorktree" ? nil : WorktreeInspector(runner: collectors))
        let calls = ActionCalls()
        let executor = ActionExecutor(trashHandler: { url in calls.trash(url); return nil })
        let report = executor.moveCandidatesToTrash(candidates: [candidate]) {
            service.assessCandidateForTrash($0, homeDirectory: fixture.root)
        }
        if scenario == "clear" {
            #expect(report.trashedCount == 1)
            #expect(report.reclaimedBytes == 42)
            #expect(calls.trashed == [candidate.path])
        } else {
            #expect(report.trashedCount == 0)
            #expect(report.reclaimedBytes == 0)
            #expect(calls.trashed.isEmpty)
        }
    }

    @Test func serverGroupRejectsEmptyMissingAndReusedMembersWithoutSignallingThem() {
        let root = process()
        let member = process(pid: root.pid + 1, parent: root.pid)
        let missingPID = root.pid + 2
        let reused = process(pid: member.pid, parent: root.pid, start: 101)
        let calls = ActionCalls()
        let executor = ActionExecutor(processLookup: { pid, _ in
            Int(pid) == root.pid ? root : reused
        }, signalSender: { pid, sig in calls.signal(pid, sig); return 0 })
        let group = ServerGroup(id: "fixture", rootPID: root.pid, name: "fixture",
            memberPIDs: [root.pid, member.pid, missingPID], listeners: [], project: nil,
            cpuPercent: nil, residentBytes: 0, footprintBytes: nil, startedAt: nil, stoppedByAgentBoundary: false)
        let empty = executor.stopServerGroup(group: group, processes: [], uid: 501)
        #expect(empty.failedCount == 3)
        #expect(calls.sent.isEmpty)
        let report = executor.stopServerGroup(group: group, processes: [root, member], uid: 501)
        #expect(report.succeededCount == 1)
        #expect(report.failedCount == 2)
        #expect(report.outcomes.filter { !$0.succeeded }.allSatisfy { $0.error != nil })
        #expect(calls.sent.map { Int($0.0) } == [root.pid])
    }

    @Test func serverBoundarySkipsWrappedAgentMembersBeforeLookup() {
        let root = process()
        let agent = ObservedProcess(pid: root.pid + 1, parentPID: root.pid, uid: 501,
            cpuPercent: 0, residentBytes: 0, executable: "/usr/bin/node", startTimeMicroseconds: 100,
            agentInvocation: AgentInvocation(agentName: "Codex", runtime: "node", entrypoint: "codex"))
        let calls = ActionCalls()
        let executor = ActionExecutor(processLookup: { pid, _ in
            #expect(Int(pid) != agent.pid)
            return root
        }, signalSender: { pid, sig in calls.signal(pid, sig); return 0 })
        let group = ServerGroup(id: "fixture", rootPID: root.pid, name: "fixture",
            memberPIDs: [root.pid, agent.pid], listeners: [], project: nil,
            cpuPercent: nil, residentBytes: 0, footprintBytes: nil, startedAt: nil, stoppedByAgentBoundary: true)
        let report = executor.stopServerGroup(group: group, processes: [root, agent], uid: 501)
        #expect(report.succeededCount == 1)
        #expect(report.warnings.count == 1)
        #expect(calls.sent.map { Int($0.0) } == [root.pid])
    }

    @Test(arguments: ["unchanged", "deletedLock", "deletedManifest", "symlinkLock"])
    func trashRechecksProjectLockfileAtExecution(_ scenario: String) throws {
        let fixture = try ActionFixture(); defer { fixture.remove() }
        let candidate = try fixture.candidate("project/node_modules")
        let root = URL(fileURLWithPath: candidate.path).deletingLastPathComponent()
        let manifest = root.appendingPathComponent("package.json")
        let lock = root.appendingPathComponent("package-lock.json")
        try Data().write(to: manifest)
        try Data().write(to: lock)
        let observation = Observation<[ObservedProcess]>(value: [], status: .complete, warnings: [], capturedAt: Date())
        let calls = ActionCalls()
        let executor = ActionExecutor(trashHandler: { url in calls.trash(url); return nil })
        let report = executor.moveCandidatesToTrash(candidates: [candidate]) { candidate in
            let assessment = NodeModulesSafety().assess(candidate: candidate, processes: observation)
            #expect(assessment.isReviewableForTrash)
            do {
                switch scenario {
                case "deletedLock": try FileManager.default.removeItem(at: lock)
                case "deletedManifest": try FileManager.default.removeItem(at: manifest)
                case "symlinkLock":
                    try FileManager.default.removeItem(at: lock)
                    try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: manifest)
                default: break
                }
            } catch {
                Issue.record(error)
                return nil
            }
            return assessment
        }
        if scenario == "unchanged" {
            #expect(report.trashedCount == 1)
            #expect(calls.trashed == [candidate.path])
        } else {
            #expect(report.trashedCount == 0)
            #expect(report.reclaimedBytes == 0)
            #expect(report.outcomes.first?.error == "Project manifest or lockfile changed since the safety assessment")
            #expect(calls.trashed.isEmpty)
        }
    }

    @Test func blockedMissingPartialAndChangedIdentitiesNeverReachTrash() throws {
        let fixture = try ActionFixture(); defer { fixture.remove() }
        let missing = try fixture.candidate("missing/dist")
        let blocked = try fixture.candidate("blocked/dist")
        let partial = try fixture.candidate("partial/dist", partial: true)
        let changed = try fixture.candidate("changed/dist", identity: FileIdentity(device: -1, inode: 1))
        let original = try fixture.candidate("unidentified/dist")
        let unidentified = CleanupCandidate(path: original.path, category: "fixture", bytes: 10, partial: false)
        let calls = ActionCalls()
        let executor = ActionExecutor(trashHandler: { url in calls.trash(url); return nil })
        let report = executor.moveCandidatesToTrash(candidates: [missing, blocked, partial, changed, unidentified]) { candidate in
            candidate.id == missing.id ? nil : actionAssessment(candidate, allowed: candidate.id != blocked.id)
        }
        #expect(report.trashedCount == 0)
        #expect(report.reclaimedBytes == 0)
        #expect(report.outcomes.count == 5)
        #expect(report.outcomes.allSatisfy { !$0.succeeded })
        #expect(calls.trashed.isEmpty)
    }

    @Test func revalidatesBothDeviceAndInodeUsingInjectedReader() throws {
        let fixture = try ActionFixture(); defer { fixture.remove() }
        let candidate = try fixture.candidate("project/dist")
        let expected = try #require(candidate.fileIdentity)
        for changed in [FileIdentity(device: expected.device, inode: expected.inode + 1),
                        FileIdentity(device: expected.device == 0 ? 1 : 0, inode: expected.inode)] {
            let calls = ActionCalls()
            let executor = ActionExecutor(identityReader: { _ in changed }, trashHandler: { url in calls.trash(url); return nil })
            let report = executor.moveCandidatesToTrash(candidates: [candidate]) { actionAssessment($0) }
            #expect(report.trashedCount == 0)
            #expect(calls.trashed.isEmpty)
        }
    }

    @Test func rejectsCandidateAndParentSymlinkSwapsEvenWithMatchingInjectedIdentity() throws {
        let fixture = try ActionFixture(); defer { fixture.remove() }
        for swapParent in [false, true] {
            let base = swapParent ? "parent" : "candidate"
            let candidate = try fixture.candidate(base + "/dist")
            let url = URL(fileURLWithPath: candidate.path)
            let original = swapParent ? url.deletingLastPathComponent() : url
            let saved = original.appendingPathExtension("saved")
            try FileManager.default.moveItem(at: original, to: saved)
            try FileManager.default.createSymbolicLink(at: original, withDestinationURL: saved)
            let calls = ActionCalls()
            let executor = ActionExecutor(identityReader: { _ in candidate.fileIdentity }, trashHandler: { url in calls.trash(url); return nil })
            let report = executor.moveCandidatesToTrash(candidates: [candidate]) { actionAssessment($0) }
            #expect(report.trashedCount == 0)
            #expect(calls.trashed.isEmpty)
        }
    }

    @Test func trashErrorsAreReportedWithoutCountingBytes() throws {
        let fixture = try ActionFixture(); defer { fixture.remove() }
        let candidate = try fixture.candidate("project/dist")
        let calls = ActionCalls()
        let executor = ActionExecutor(trashHandler: { url in
            calls.trash(url)
            throw CocoaError(.fileWriteNoPermission)
        })
        let report = executor.moveCandidatesToTrash(candidates: [candidate]) { actionAssessment($0) }
        #expect(report.trashedCount == 0)
        #expect(report.reclaimedBytes == 0)
        #expect(report.outcomes.first?.error != nil)
        #expect(calls.trashed == [candidate.path])
    }
}
