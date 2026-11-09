import Foundation
import Darwin
import Testing
@testable import SuyoiCore

@Suite struct SessionLogRetentionScannerTests {
    @Test func discoversOnlyOldLogsInSupportedLayoutsAndSortsBySizeThenPath() throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        let codex = try fixture.log(".codex/sessions/2026/01/02/old.jsonl", bytes: 40)
        let claude = try fixture.log(".claude/projects/project/old.jsonl", bytes: 80)
        let tie = try fixture.log(".claude/projects/project/tie.jsonl", bytes: 40)
        _ = try fixture.log(".codex/sessions/2026/01/02/recent.jsonl", daysOld: 2)
        _ = try fixture.log(".claude/projects/project/recent.jsonl", daysOld: 13)
        _ = try fixture.log(".codex/sessions/2026/01/02/exact-cutoff.jsonl", daysOld: 14)
        _ = try fixture.log(".claude/projects/project/not-a-log.txt")
        _ = try fixture.log(".codex/sessions/2026/13/02/invalid-date.jsonl")
        _ = try fixture.log(".codex/sessions/flat.jsonl")
        _ = try fixture.log(".claude/projects/project/nested/ignored.jsonl")
        let results = fixture.scan()
        #expect(results.map(\.path) == [claude.path, tie.path, codex.path])
        #expect(results.map(\.bytes) == [80, 40, 40])
        #expect(results.map(\.agentName) == ["Claude Code", "Claude Code", "Codex"])
        for result in results {
            #expect(result.id == result.path)
            #expect(result.identity == FileMetadataReader().identity(at: URL(fileURLWithPath: result.path)))
            #expect(result.modifiedAt == fixture.now.addingTimeInterval(-20 * 86_400))
        }
        let decoded = try JSONDecoder().decode([StaleSessionLogSummary].self, from: JSONEncoder().encode(results))
        #expect(decoded == results)
    }

    @Test func clampsRetentionToAtLeastOneDay() throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        let old = try fixture.log(".claude/projects/project/old.jsonl", daysOld: 2)
        _ = try fixture.log(".claude/projects/project/boundary.jsonl", daysOld: 1)
        _ = try fixture.log(".claude/projects/project/recent.jsonl", daysOld: 0)
        #expect(fixture.scanner.scanStaleSessionLogs(olderThanDays: -5, now: fixture.now).map(\.path) == [old.path])
        let report = fixture.scanner.trashStaleLogs(fixture.scan(days: 0), olderThanDays: 0, liveProcesses: { fixture.processes() }, now: fixture.now) { _ in nil }
        #expect(report.trashedCount == 1)
    }

    @Test func protectsSessionIDsInBothProvidersRegardlessOfActivityState() throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        _ = try fixture.log(".codex/sessions/2026/01/02/rollout-session-123-extra.jsonl")
        _ = try fixture.log(".claude/projects/project/session-456.jsonl")
        let unrelated = try fixture.log(".claude/projects/project/unrelated.jsonl")
        let agents = [fixture.agent(sessionID: "session-123"), fixture.agent(sessionID: "session-456")]
        #expect(fixture.scan(agents: agents).map(\.path) == [unrelated.path])
        #expect(fixture.scan(agents: [fixture.agent(sessionID: "")]).count == 3)
    }

    @Test(arguments: [false, true])
    func protectsEncodedClaudeProjectFromCwdOrProjectRoot(_ useProject: Bool) throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        let project = fixture.root.appendingPathComponent("work/my_project.v2")
        let encoded = String(project.path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        _ = try fixture.log(".claude/projects/\(encoded)/old.jsonl")
        let unrelated = try fixture.log(".claude/projects/\(encoded)-other/old.jsonl")
        let agent = fixture.agent(cwd: useProject ? "/workspace/other" : project.path,
                                  projectRoot: useProject ? project.path : nil)
        #expect(fixture.scan(agents: [agent]).map(\.path) == [unrelated.path])
        let report = fixture.scanner.trashStaleLogs(fixture.scan(), activeAgents: [agent], liveProcesses: { fixture.processes([agent.process]) }, now: fixture.now) { _ in nil }
        #expect(report.trashedCount == 1)
        #expect(report.outcomes.filter { !$0.succeeded }.count == 1)
    }

    @Test func protectsDirectParentWorkingDirectory() throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        let log = try fixture.log(".codex/sessions/2026/01/02/old.jsonl")
        #expect(fixture.scan(agents: [fixture.agent(cwd: log.deletingLastPathComponent().path)]).isEmpty)
    }

    @Test(arguments: [".codex", ".codex/sessions", ".codex/sessions/2026", ".codex/sessions/2026/01",
                      ".codex/sessions/2026/01/02", ".codex/sessions/2026/01/02/old.jsonl",
                      ".claude", ".claude/projects", ".claude/projects/project", ".claude/projects/project/old.jsonl"])
    func rejectsSymlinksAtEveryProviderPathComponent(_ relative: String) throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        let codex = relative.hasPrefix(".codex")
        _ = try fixture.log(codex ? ".codex/sessions/2026/01/02/old.jsonl" : ".claude/projects/project/old.jsonl")
        let captured = fixture.scan()
        #expect(captured.count == 1)
        let component = fixture.root.appendingPathComponent(relative)
        let original = fixture.root.appendingPathComponent("saved-original")
        try FileManager.default.moveItem(at: component, to: original)
        try FileManager.default.createSymbolicLink(at: component, withDestinationURL: original)
        #expect(fixture.scan().isEmpty)
        let report = fixture.scanner.trashStaleLogs(captured, liveProcesses: { fixture.processes() }, now: fixture.now) { _ in
            Issue.record("A symlink reached Trash")
            return nil
        }
        #expect(report.trashedCount == 0)
        #expect(report.reclaimedBytes == 0)
        #expect(report.outcomes.first?.succeeded == false)
    }

    @Test func rejectsSymlinkedHome() throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        _ = try fixture.log(".claude/projects/project/old.jsonl")
        let alias = fixture.root.appendingPathComponent("home-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root)
        #expect(SessionLogRetentionScanner(homeDirectory: alias).scanStaleSessionLogs(now: fixture.now).isEmpty)
    }

    @Test func rejectsReplacedInodeAndForgedDevice() throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        let file = try fixture.log(".claude/projects/project/old.jsonl")
        let captured = try #require(fixture.scan().first)
        try FileManager.default.moveItem(at: file, to: fixture.root.appendingPathComponent("original"))
        _ = try fixture.log(".claude/projects/project/old.jsonl")
        let replacement = try #require(fixture.scan().first)
        #expect(replacement.identity.inode != captured.identity.inode)
        let forged = StaleSessionLogSummary(id: replacement.id, agentName: replacement.agentName, path: replacement.path,
            bytes: replacement.bytes, modifiedAt: replacement.modifiedAt,
            identity: FileIdentity(device: replacement.identity.device ^ 1, inode: replacement.identity.inode))
        let report = fixture.scanner.trashStaleLogs([captured, forged], liveProcesses: { fixture.processes() }, now: fixture.now) { _ in
            Issue.record("A mismatched identity reached Trash")
            return nil
        }
        #expect(report.trashedCount == 0)
        #expect(report.outcomes.count == 2)
        #expect(report.outcomes.allSatisfy { !$0.succeeded && $0.bytes == 0 })
    }

    @Test(arguments: ["mtime", "session", "missing", "directory", "retention"])
    func rechecksEligibilityAfterDiscovery(_ change: String) throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        let file = try fixture.log(".claude/projects/project/active-session.jsonl")
        let logs = fixture.scan()
        if change == "mtime" {
            try FileManager.default.setAttributes([.modificationDate: fixture.now], ofItemAtPath: file.path)
        } else if change == "missing" || change == "directory" {
            try FileManager.default.moveItem(at: file, to: fixture.root.appendingPathComponent("original"))
            if change == "directory" { try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false) }
        }
        let agents = change == "session" ? [fixture.agent(sessionID: "active-session")] : []
        let report = fixture.scanner.trashStaleLogs(logs, olderThanDays: change == "retention" ? 30 : 14,
            activeAgents: agents, liveProcesses: { fixture.processes(agents.map(\.process)) }, now: fixture.now) { _ in
                Issue.record("An ineligible log reached Trash")
                return nil
            }
        #expect(report.trashedCount == 0)
        #expect(report.reclaimedBytes == 0)
    }

    @Test func rejectsForgedPathsOutsideAllowedLayout() throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        let outside = try fixture.log(".codex/sessions-other/old.jsonl")
        let actual = try #require(FileMetadataReader().identity(at: outside))
        let paths = [outside.path, fixture.root.path + "/.codex/sessions/../sessions-other/old.jsonl",
                     "relative.jsonl", outside.path + "\0.jsonl"]
        let forged = paths.map { StaleSessionLogSummary(id: $0, agentName: "Codex", path: $0, bytes: 10,
            modifiedAt: fixture.now.addingTimeInterval(-20 * 86_400), identity: actual) }
        let report = fixture.scanner.trashStaleLogs(forged, liveProcesses: { fixture.processes() }, now: fixture.now) { _ in
            Issue.record("An unapproved path reached Trash")
            return nil
        }
        #expect(report.outcomes.count == paths.count)
        #expect(report.trashedCount == 0)
    }

    @Test func movesToInjectedTrashAndAccountsOnlySuccessfulLiveBytes() throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        let success = try fixture.log(".codex/sessions/2026/01/02/success.jsonl", bytes: 20)
        let failure = try fixture.log(".claude/projects/project/failure.jsonl", bytes: 50)
        let logs = fixture.scan()
        // A same-inode size change must use the execution-time size, not the preview.
        let handle = try FileHandle(forWritingTo: success)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 1, count: 7))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: fixture.now.addingTimeInterval(-20 * 86_400)],
                                              ofItemAtPath: success.path)
        let trash = fixture.root.appendingPathComponent("test-trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
        var calls: [URL] = []
        let report = fixture.scanner.trashStaleLogs(logs, liveProcesses: { fixture.processes() }, now: fixture.now) { url in
            calls.append(url)
            if url == failure { throw NSError(domain: "private-diagnostic", code: 1) }
            let destination = trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
        #expect(calls == [failure, success])
        #expect(report.trashedCount == 1)
        #expect(report.reclaimedBytes == 27)
        #expect(report.outcomes.first?.bytes == 0)
        #expect(report.outcomes.first?.error == "Could not move session log to Trash")
        #expect(report.outcomes.last?.bytes == 27)
        #expect(report.outcomes.last?.trashedURL == trash.appendingPathComponent("success.jsonl").path)
        #expect(!FileManager.default.fileExists(atPath: success.path))
        #expect(FileManager.default.fileExists(atPath: failure.path))
        #expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent("success.jsonl").path))
    }

    @Test func duplicateSelectionIsCountedOnceEvenWithoutTrashDestination() throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        _ = try fixture.log(".claude/projects/project/old.jsonl", bytes: 30)
        let log = try #require(fixture.scan().first)
        var calls = 0
        let report = fixture.scanner.trashStaleLogs([log, log], liveProcesses: { fixture.processes() }, now: fixture.now) { _ in calls += 1; return nil }
        #expect(calls == 1)
        #expect(report.trashedCount == 1)
        #expect(report.reclaimedBytes == 30)
        #expect(report.outcomes.first?.trashedURL == nil)
        #expect(report.outcomes.last?.succeeded == false)
    }

    @Test func rechecksEachLogImmediatelyBeforeItsTrashCall() throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        let first = try fixture.log(".claude/projects/project/first.jsonl", bytes: 40)
        let second = try fixture.log(".claude/projects/project/second.jsonl", bytes: 20)
        let logs = fixture.scan()
        var calls: [URL] = []
        let report = fixture.scanner.trashStaleLogs(logs, liveProcesses: { fixture.processes() }, now: fixture.now) { url in
            calls.append(url)
            try FileManager.default.setAttributes([.modificationDate: fixture.now], ofItemAtPath: second.path)
            return nil
        }
        #expect(calls == [first])
        #expect(report.trashedCount == 1)
        #expect(report.reclaimedBytes == 40)
        #expect(report.outcomes.last?.succeeded == false)
    }

    @Test(arguments: [ObservationStatus.partial, .unavailable])
    func incompleteEmptyInventoryCannotDisproveKnownOwner(_ status: ObservationStatus) throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        _ = try fixture.log(".codex/sessions/2026/01/02/old-session.jsonl")
        let owner = fixture.agent(sessionID: "old-session")
        let report = fixture.scanner.trashStaleLogs(fixture.scan(), activeAgents: [owner],
            liveProcesses: { fixture.processes(status: status) }, now: fixture.now) { _ in
            Issue.record("Incomplete process evidence reached Trash")
            return nil
        }
        #expect(report.trashedCount == 0)
        #expect(report.outcomes.first?.error == "Live session ownership could not be verified")
    }

    @Test func sameProviderProcessWithUnknownSessionBlocksTrash() throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        _ = try fixture.log(".codex/sessions/2026/01/02/old-session.jsonl")
        let process = ObservedProcess(pid: 42, parentPID: 1, uid: Int(getuid()), cpuPercent: 0,
            residentBytes: 0, executable: "/usr/bin/codex", startTimeMicroseconds: 123)
        let report = fixture.scanner.trashStaleLogs(fixture.scan(),
            liveProcesses: { fixture.processes([process]) }, now: fixture.now) { _ in
            Issue.record("Unresolved session ownership reached Trash")
            return nil
        }
        #expect(report.trashedCount == 0)
        #expect(report.outcomes.first?.error == "A running agent may still own this session log")
    }

    @Test func exactFileCheckBlocksAnOpenOldLogAndAllowsItAfterClose() throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        let file = try fixture.log(".codex/sessions/2026/01/02/old-session.jsonl")
        let logs = fixture.scan()
        let capturedOwner = fixture.agent(sessionID: "old-session")
        let scanner = SessionLogRetentionScanner(homeDirectory: fixture.root)
        let handle = try FileHandle(forReadingFrom: file)
        let blocked = scanner.trashStaleLogs(logs, activeAgents: [capturedOwner],
            liveProcesses: { fixture.processes() }, now: fixture.now) { _ in
            Issue.record("An open file reached Trash")
            return nil
        }
        #expect(blocked.trashedCount == 0)
        #expect(blocked.outcomes.first?.error?.contains("is open") == true)
        try handle.close()
        let moved = scanner.trashStaleLogs(logs, activeAgents: [capturedOwner],
            liveProcesses: { fixture.processes() }, now: fixture.now) { original in
            let destination = fixture.root.appendingPathComponent("fixture-trash")
            try FileManager.default.moveItem(at: original, to: destination)
            return destination
        }
        #expect(moved.trashedCount == 1)
        #expect(moved.outcomes.first?.recovery?.fileIdentity == logs.first?.identity)
    }

    @Test func batchRequiresNewCompleteProcessEvidenceForEachItem() throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        let first = try fixture.log(".claude/projects/project/first.jsonl", bytes: 40)
        let second = try fixture.log(".claude/projects/project/second.jsonl", bytes: 20)
        var reads = 0
        let report = fixture.scanner.trashStaleLogs(fixture.scan(), liveProcesses: {
            reads += 1
            return fixture.processes(status: reads == 1 ? .complete : .partial)
        }, now: fixture.now) { url in
            #expect(url == first)
            return nil
        }
        #expect(reads == 2)
        #expect(report.trashedCount == 1)
        #expect(report.outcomes.last?.path == second.path && report.outcomes.last?.succeeded == false)
    }

    @Test func emptyOrMissingRootsReturnEmptyReports() throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        #expect(fixture.scan().isEmpty)
        let report = fixture.scanner.trashStaleLogs([], liveProcesses: { fixture.processes() }, now: fixture.now)
        #expect(report.outcomes.isEmpty)
        #expect(report.trashedCount == 0)
        #expect(report.reclaimedBytes == 0)
    }
}

private struct RetentionFixture {
    let root: URL
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var scanner: SessionLogRetentionScanner {
        SessionLogRetentionScanner(homeDirectory: root, openFileCheck: { _ in .clear })
    }

    func processes(_ value: [ObservedProcess] = [], status: ObservationStatus = .complete,
                   warnings: [String] = [], capturedAt: Date = Date()) -> Observation<[ObservedProcess]> {
        Observation(value: value, status: status, warnings: warnings, capturedAt: capturedAt)
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func log(_ path: String, bytes: Int = 10, daysOld: Int = 20) throws -> URL {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-Double(daysOld) * 86_400)],
                                              ofItemAtPath: file.path)
        return file
    }

    func scan(days: Int = 14, agents: [AgentObservation] = []) -> [StaleSessionLogSummary] {
        scanner.scanStaleSessionLogs(olderThanDays: days, activeAgents: agents, now: now)
    }

    func agent(sessionID: String? = nil, cwd: String? = nil, projectRoot: String? = nil) -> AgentObservation {
        let process = ObservedProcess(pid: 42, parentPID: 1, uid: Int(getuid()), cpuPercent: 0,
            residentBytes: 0, executable: "/usr/bin/agent", cwd: cwd)
        let project = projectRoot.map { ProjectContext(rootPath: $0, name: "project", framework: nil,
            gitBranch: nil, gitCommit: nil, isWorktree: false) }
        return AgentObservation(id: 42, agentName: "Codex", process: process, project: project,
            terminalApp: nil, statusSource: .processOnly, childServerPorts: [], activityState: .idle, sessionID: sessionID)
    }
}
