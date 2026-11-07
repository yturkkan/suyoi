import Foundation
import Testing
@testable import SuyoiCore

private struct InventoryProcessFixture: ProcessInspecting {
    let observation: Observation<[ObservedProcess]>
    func inspectProcesses(uid: Int) -> Observation<[ObservedProcess]> {
        Observation(value: observation.value.filter { $0.uid == uid }, status: observation.status,
            warnings: observation.warnings, capturedAt: observation.capturedAt)
    }
}

private struct InventoryListenerFixture: ListenerInspecting {
    let observation: Observation<[Listener]>
    func inspectListeners(uid: Int) -> Observation<[Listener]> { observation }
}

private final class InventoryProjectFixture: ProjectResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    let context: ProjectContext?
    init(context: ProjectContext?) { self.context = context }
    var resolvedPaths: [String] {
        lock.lock(); defer { lock.unlock() }
        return paths
    }
    func resolveProject(at directory: URL) -> Observation<ProjectContext?> {
        lock.lock(); paths.append(directory.path); lock.unlock()
        return Observation(value: context, status: .partial, warnings: ["Shared warning", "Project metadata incomplete"], capturedAt: Date())
    }
}

private struct InventoryCleanupFixture: CleanupScanning {
    let report: CleanupReport
    func scan(root: URL, entryLimit: Int, timeLimit: TimeInterval) -> CleanupReport { report }
}

private struct InventorySafetyFixture: SafetyEvaluating {
    func assess(candidate: CleanupCandidate, processes: Observation<[ObservedProcess]>, worktrees: Observation<[WorktreeRecord]>) -> SafetyAssessment {
        SafetyAssessment(candidateID: candidate.id, usage: .unknown, regenerability: .unverified("Fixture has no regenerability evidence"),
            blockedReasons: worktrees.warnings, isReviewableForTrash: false)
    }
}

@Suite("Inventory coordination")
struct InventoryIntegrationTests {
    private func process(_ pid: Int, parent: Int = 1, executable: String, cwd: String? = nil) -> ObservedProcess {
        ObservedProcess(pid: pid, parentPID: parent, uid: 501, cpuPercent: 1, residentBytes: 100,
            executable: executable, startTimeMicroseconds: UInt64(pid) * 1_000_000, cwd: cwd)
    }

    @Test func resolvesEachRelevantDirectoryOnceAndConnectsAgentsToServers() throws {
        let cwd = "/fixture/project/package"
        let rows = [
            process(1, parent: 0, executable: "/Applications/Terminal.app/Contents/MacOS/Terminal"),
            process(10, executable: "/usr/local/bin/codex", cwd: cwd),
            process(11, parent: 10, executable: "/usr/local/bin/npm", cwd: cwd),
            process(12, parent: 11, executable: "/usr/local/bin/node", cwd: cwd),
            process(20, executable: "/bin/unrelated", cwd: "/fixture/unrelated")
        ]
        let listeners = [Listener(pid: 12, processName: "node", address: "127.0.0.1", port: 3000),
                         Listener(pid: 12, processName: "node", address: "::1", port: 3001)]
        let context = ProjectContext(rootPath: "/fixture/project", name: "Fixture", framework: "Next.js", gitBranch: "main", gitCommit: nil, isWorktree: false)
        let resolver = InventoryProjectFixture(context: context)
        let before = Date()
        let service = InventoryService(
            processInspector: InventoryProcessFixture(observation: Observation(value: rows, status: .partial, warnings: ["Shared warning"], capturedAt: before)),
            listenerInspector: InventoryListenerFixture(observation: Observation(value: listeners, status: .complete, warnings: ["Shared warning"], capturedAt: before)),
            projectResolver: resolver)
        let snapshot = service.captureSnapshot(uid: 501)
        #expect(snapshot.processes == rows)
        #expect(snapshot.listeners == listeners)
        #expect(resolver.resolvedPaths == [cwd])
        #expect(snapshot.projectsByPath[cwd] == context)
        #expect(snapshot.projectsByPath[context.rootPath] == context)
        #expect(snapshot.warnings == ["Shared warning", "Project metadata incomplete"])
        let agent = try #require(snapshot.agentObservations.first)
        #expect(agent.project == context)
        #expect(agent.terminalApp == "Terminal")
        #expect(agent.statusSource == .processOnly)
        #expect(agent.childServerPorts == [3000, 3001])
        let server = try #require(snapshot.serverGroups.first)
        #expect(snapshot.serverGroups.count == 1)
        #expect(server.project == context)
        #expect(server.rootPID == 11)
        #expect(server.memberPIDs == [11, 12])
        #expect(snapshot.capturedAt >= before)
        #expect(snapshot.capturedAt <= Date())
        let encoded = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(InventorySnapshot.self, from: encoded) == snapshot)
    }

    @Test func inheritsAgentDirectoryAndPreservesUnavailableWarnings() {
        let resolver = InventoryProjectFixture(context: nil)
        let rows = [process(1, parent: 0, executable: "/bin/zsh", cwd: "/fixture/shared"),
                    process(2, executable: "/usr/local/bin/claude"),
                    process(3, executable: "/usr/local/bin/codex")]
        let service = InventoryService(
            processInspector: InventoryProcessFixture(observation: Observation(value: rows, status: .partial, warnings: ["Process partial"], capturedAt: Date())),
            listenerInspector: InventoryListenerFixture(observation: Observation(value: [], status: .unavailable, warnings: ["Listeners unavailable"], capturedAt: Date())),
            projectResolver: resolver)
        let snapshot = service.captureSnapshot(uid: 501)
        #expect(resolver.resolvedPaths == ["/fixture/shared"])
        #expect(snapshot.projectsByPath.isEmpty)
        #expect(snapshot.agentObservations.count == 2)
        #expect(snapshot.agentObservations.allSatisfy { $0.project == nil })
        #expect(snapshot.warnings.contains("Listeners unavailable"))
        #expect(snapshot.serverGroups.isEmpty)
    }

    @Test func resolvesDistinctAgentAndStandaloneServerDirectories() {
        let rows = [process(10, parent: 0, executable: "/usr/local/bin/codex", cwd: "/fixture/agent"),
                    process(20, parent: 0, executable: "/usr/local/bin/node", cwd: "/fixture/server"),
                    process(30, parent: 0, executable: "/bin/unrelated", cwd: "/fixture/unrelated")]
        let resolver = InventoryProjectFixture(context: nil)
        let service = InventoryService(
            processInspector: InventoryProcessFixture(observation: Observation(value: rows, status: .complete, warnings: [], capturedAt: Date())),
            listenerInspector: InventoryListenerFixture(observation: Observation(value: [Listener(pid: 20, processName: "node", address: "127.0.0.1", port: 8080)], status: .complete, warnings: [], capturedAt: Date())),
            projectResolver: resolver)
        let snapshot = service.captureSnapshot(uid: 501)
        #expect(resolver.resolvedPaths == ["/fixture/agent", "/fixture/server"])
        #expect(snapshot.serverGroups.count == 1)
        #expect(snapshot.agentObservations.first?.childServerPorts == [])
    }

    @Test func unavailableCollectorsDoNotResolveProjects() {
        let resolver = InventoryProjectFixture(context: nil)
        let service = InventoryService(
            processInspector: InventoryProcessFixture(observation: Observation(value: [], status: .unavailable, warnings: ["Unavailable"], capturedAt: Date())),
            listenerInspector: InventoryListenerFixture(observation: Observation(value: [], status: .unavailable, warnings: ["Unavailable"], capturedAt: Date())),
            projectResolver: resolver)
        let snapshot = service.captureSnapshot(uid: 501)
        #expect(snapshot.warnings == ["Unavailable"])
        #expect(snapshot.processes.isEmpty)
        #expect(snapshot.agentObservations.isEmpty)
        #expect(resolver.resolvedPaths.isEmpty)
    }

    @Test func cleanupIncludesAllowlistedCachesAndOptionalSafety() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex/cache"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("cache".utf8).write(to: home.appendingPathComponent(".codex/cache/item"))
        let candidate = CleanupCandidate(path: home.appendingPathComponent("project/.build").path, category: "Swift build output", bytes: 20, partial: false)
        let service = InventoryService(
            processInspector: InventoryProcessFixture(observation: Observation(value: [], status: .unavailable, warnings: ["Process unavailable"], capturedAt: Date())),
            cleanupScanner: InventoryCleanupFixture(report: CleanupReport(candidates: [candidate], warnings: ["Project partial"], partial: true)),
            safetyEvaluator: InventorySafetyFixture())
        let report = service.scanCleanup(root: home, homeDirectory: home)
        #expect(report.candidates == [candidate])
        #expect(report.agentCacheCandidates.count == 1)
        #expect(report.agentCacheCandidates.first?.agentName == "Codex")
        #expect(report.discoveredCount == 2)
        #expect(report.partial)
        #expect(report.assessments.count == 2)
        #expect(report.assessments.values.allSatisfy { !$0.isReviewableForTrash })
        #expect(report.warnings.contains("Process unavailable"))
        #expect(report.warnings.contains("Worktree inspection was not provided."))
    }

    @Test func partialProcessInventoryCanClearArtifactsWithoutWorktreeCollector() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let artifactURL = home.appendingPathComponent("project/dist")
        try FileManager.default.createDirectory(at: artifactURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex/cache"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("{}".utf8).write(to: home.appendingPathComponent("project/package.json"))
        let artifact = CleanupCandidate(path: artifactURL.path, category: "Build output", bytes: 20, partial: false,
            fileIdentity: FileMetadataReader().identity(at: artifactURL))
        let observation = Observation<[ObservedProcess]>(value: [], status: .partial, warnings: ["Partial process inventory"], capturedAt: Date())
        let service = InventoryService(processInspector: InventoryProcessFixture(observation: observation),
            cleanupScanner: InventoryCleanupFixture(report: CleanupReport(candidates: [artifact], warnings: [], partial: false)),
            safetyEvaluator: SafetyEvaluator(homeDirectory: home))
        let report = service.scanCleanup(root: home, homeDirectory: home)
        #expect(report.worktrees.isEmpty)
        #expect(report.warnings.contains("Worktree inspection was not provided."))
        #expect(report.warnings.contains("Partial process inventory"))
        #expect(report.assessments[artifact.id]?.isReviewableForTrash == true)
        #expect(report.agentCacheCandidates.count == 1)
        #expect(report.assessments.values.allSatisfy { $0.isReviewableForTrash })

        let unavailable = InventoryService(
            processInspector: InventoryProcessFixture(observation: Observation(value: [], status: .unavailable, warnings: [], capturedAt: Date())),
            cleanupScanner: InventoryCleanupFixture(report: CleanupReport(candidates: [artifact], warnings: [], partial: false)),
            safetyEvaluator: SafetyEvaluator(homeDirectory: home))
        #expect(unavailable.scanCleanup(root: home, homeDirectory: home).assessments.values.allSatisfy { !$0.isReviewableForTrash })
    }

}
