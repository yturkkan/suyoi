import Foundation
import Testing
@testable import SuyoiCore

private final class WorktreeTrashCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []
    func record(_ url: URL) { lock.lock(); defer { lock.unlock() }; recorded.append(url) }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return recorded }
}

private struct CleanupWorktreeRunner: CommandRunning {
    let handler: @Sendable (CommandRequest) throws -> CommandResult
    func run(_ request: CommandRequest) throws -> CommandResult {
        if let toolResult = worktreeToolStub(request) { return toolResult }
        #expect(request.executable == "/usr/bin/sandbox-exec" || request.executable == "/usr/sbin/lsof")
        #expect(!request.arguments.contains("remove"))
        #expect(!request.arguments.contains("--force"))
        return try handler(request)
    }
}

private struct CleanupWorktreeProcesses: ProcessInspecting {
    var status: ObservationStatus = .complete
    var processes: [ObservedProcess] = []
    var warnings: [String] = []
    func inspectProcesses(uid: Int) -> Observation<[ObservedProcess]> {
        Observation(value: processes, status: status, warnings: warnings, capturedAt: Date())
    }
}

private func cleanupWorktreeResult(_ text: String = "", exit: Int32 = 0,
                                   stderr: String = "", timedOut: Bool = false,
                                   truncated: Bool = false) -> CommandResult {
    CommandResult(exitCode: exit, stdout: Data(text.utf8), stderr: Data(stderr.utf8),
                  timedOut: timedOut, truncated: truncated)
}

private struct CleanupWorktreeFixture: Sendable {
    let root: URL
    let main: URL
    let linked: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("suyoi-worktree-cleanup-" + UUID().uuidString)
        main = root.appendingPathComponent("main")
        linked = root.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: main.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try Data("gitdir: fixture\n".utf8).write(to: linked.appendingPathComponent(".git"))
    }

    func record(path: String? = nil, isMain: Bool = false) -> WorktreeRecord {
        WorktreeRecord(path: path ?? linked.path, branch: "refs/heads/feature", headCommit: "bbbb",
                       isMain: isMain, isDirty: false, isLocked: false, isMergedToDefault: true,
                       usage: .clear, blockedReasons: [])
    }

    func listing(flags: String = "", branch: String = "refs/heads/feature", head: String = "bbbb",
                 includeLinked: Bool = true, linkedFirst: Bool = false) -> String {
        let mainEntry = "worktree \(main.path)\0HEAD aaaa\0branch refs/heads/main\0\0"
        let linkedEntry = "worktree \(linked.path)\0HEAD \(head)\0branch \(branch)\0" + flags + "\0"
        return includeLinked ? (linkedFirst ? linkedEntry + mainEntry : mainEntry + linkedEntry) : mainEntry
    }

    func runner(listing: String? = nil, dirty: Bool = false, merged: Bool = true,
                statusFailure: Bool = false, mergeFailure: Bool = false, trackedIndex: String = "") -> CleanupWorktreeRunner {
        let output = listing ?? self.listing()
        return CleanupWorktreeRunner { request in
            if request.executable == "/usr/sbin/lsof" { return cleanupWorktreeResult(exit: 1) }
            #expect(request.arguments.contains("core.fsmonitor=false"))
            #expect(request.environment["GIT_OPTIONAL_LOCKS"] == "0")
            if request.arguments.contains("list") { return cleanupWorktreeResult(output) }
            if request.arguments.contains("config") { return cleanupWorktreeResult(exit: 1) }
            if request.arguments.contains("ls-files") { return cleanupWorktreeResult(trackedIndex) }
            if request.arguments.contains("status") {
                return cleanupWorktreeResult(worktreeStatusFixture(dirty: dirty), exit: statusFailure ? 128 : 0)
            }
            if request.arguments.contains("rev-parse") { return cleanupWorktreeResult("aaaa\n") }
            if request.arguments.contains("merge-base") { return cleanupWorktreeResult(exit: mergeFailure ? 128 : (merged ? 0 : 1)) }
            Issue.record("Unexpected verification command")
            return cleanupWorktreeResult(exit: 128)
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite struct WorktreeCleanupExecutorTests {
    @Test func verifiedSecondaryWorktreeUsesInjectedTrashAndReturnsDestination() throws {
        let fixture = try CleanupWorktreeFixture(); defer { fixture.remove() }
        let calls = WorktreeTrashCalls()
        let destination = fixture.root.appendingPathComponent("trash/linked")
        let executor = WorktreeCleanupExecutor(runner: fixture.runner(), processInspector: CleanupWorktreeProcesses(),
            trashHandler: { url in
                calls.record(url)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: url, to: destination)
                return destination
            })
        let result = executor.moveToTrash(worktree: fixture.record(), parentRoot: fixture.root)
        #expect(result.path == fixture.linked.path)
        #expect(result.branch == "refs/heads/feature")
        #expect(result.trashed && result.trashedURL == destination && result.error == nil)
        #expect(result.recovery?.fileIdentity == FileMetadataReader().identity(at: destination))
        #expect(calls.urls == [fixture.linked])
        #expect(!FileManager.default.fileExists(atPath: fixture.linked.path))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent(".git").path))
        #expect(FileManager.default.fileExists(atPath: fixture.main.path))
    }

    @Test func mainWorktreeIsRejectedBeforeAnyInspection() throws {
        let fixture = try CleanupWorktreeFixture(); defer { fixture.remove() }
        let runner = CleanupWorktreeRunner { _ in Issue.record("Main tree must not be inspected for removal"); return cleanupWorktreeResult() }
        let executor = WorktreeCleanupExecutor(runner: runner, processInspector: CleanupWorktreeProcesses(),
            trashHandler: { _ in Issue.record("Main tree reached Trash"); return nil })
        let result = executor.moveToTrash(worktree: fixture.record(path: fixture.main.path, isMain: true), parentRoot: fixture.root)
        #expect(!result.trashed)
        #expect(result.error?.contains("Main") == true)
    }

    @Test(arguments: ["dirty", "locked", "unmerged", "cwd", "open-files", "unknown-open-files", "prunable", "main", "branch", "commit", "missing", "status-failure", "merge-failure"])
    func staleEligibleRecordCannotAuthorizeUnsafeLiveState(_ state: String) throws {
        let fixture = try CleanupWorktreeFixture(); defer { fixture.remove() }
        let calls = WorktreeTrashCalls()
        let flags = state == "locked" ? "locked review\0" : (state == "prunable" ? "prunable unavailable\0" : "")
        let listing = fixture.listing(flags: flags, branch: state == "branch" ? "refs/heads/other" : "refs/heads/feature",
                                      head: state == "commit" ? "cccc" : "bbbb",
                                      includeLinked: state != "missing", linkedFirst: state == "main")
        let processes = state == "cwd" ? [ObservedProcess(pid: 91, parentPID: 1, uid: 501, cpuPercent: 0,
            residentBytes: 0, executable: "/bin/node", cwd: fixture.linked.appendingPathComponent("src").path)] : []
        let usage: UsageState = state == "open-files" ? .inUse : (state == "unknown-open-files" ? .unknown : .clear)
        let executor = WorktreeCleanupExecutor(
            runner: fixture.runner(listing: listing, dirty: state == "dirty", merged: state != "unmerged",
                                   statusFailure: state == "status-failure", mergeFailure: state == "merge-failure"),
            processInspector: CleanupWorktreeProcesses(processes: processes), openFileCheck: { _ in usage },
            trashHandler: { url in calls.record(url); return nil })
        let result = executor.moveToTrash(worktree: fixture.record(), parentRoot: fixture.root)
        #expect(!result.trashed)
        #expect(result.trashedURL == nil)
        #expect(result.error != nil)
        #expect(calls.urls.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.linked.path))
    }

    @Test(arguments: [ObservationStatus.partial, .unavailable])
    func incompleteProcessObservationFailsClosed(_ status: ObservationStatus) throws {
        let fixture = try CleanupWorktreeFixture(); defer { fixture.remove() }
        let executor = WorktreeCleanupExecutor(runner: fixture.runner(), processInspector: CleanupWorktreeProcesses(status: status),
            openFileCheck: { _ in .clear }, trashHandler: { _ in Issue.record("Incomplete process evidence reached Trash"); return nil })
        #expect(!executor.moveToTrash(worktree: fixture.record(), parentRoot: fixture.root).trashed)
    }

    @Test func processWithUnknownWorkingDirectoryFailsClosed() throws {
        let fixture = try CleanupWorktreeFixture(); defer { fixture.remove() }
        let process = ObservedProcess(pid: 91, parentPID: 1, uid: 501, cpuPercent: 0, residentBytes: 0, executable: "/bin/node")
        let executor = WorktreeCleanupExecutor(runner: fixture.runner(), processInspector: CleanupWorktreeProcesses(processes: [process]),
            openFileCheck: { _ in .clear }, trashHandler: { _ in Issue.record("Unknown process usage reached Trash"); return nil })
        #expect(!executor.moveToTrash(worktree: fixture.record(), parentRoot: fixture.root).trashed)
    }

    @Test(arguments: ["malformed", "timeout", "truncated", "stderr", "failure", "throws"])
    func failedLiveGitInspectionFailsClosed(_ state: String) throws {
        let fixture = try CleanupWorktreeFixture(); defer { fixture.remove() }
        let listing = fixture.listing()
        let runner = CleanupWorktreeRunner { _ in
            if state == "throws" { throw CocoaError(.fileReadNoPermission) }
            return cleanupWorktreeResult(state == "malformed" ? "invalid" : listing, exit: state == "failure" ? 128 : 0,
                stderr: state == "stderr" ? "warning" : "", timedOut: state == "timeout", truncated: state == "truncated")
        }
        let executor = WorktreeCleanupExecutor(runner: runner, processInspector: CleanupWorktreeProcesses(),
            openFileCheck: { _ in .clear }, trashHandler: { _ in Issue.record("Failed inspection reached Trash"); return nil })
        #expect(!executor.moveToTrash(worktree: fixture.record(), parentRoot: fixture.root).trashed)
    }

    @Test(arguments: ["leaf-symlink", "ancestor-symlink", "file", "missing", "relative", "noncanonical"])
    func unsafePathsAreRejected(_ state: String) throws {
        let fixture = try CleanupWorktreeFixture(); defer { fixture.remove() }
        let target = fixture.root.appendingPathComponent("alias")
        var path = target.path
        switch state {
        case "leaf-symlink": try FileManager.default.createSymbolicLink(at: target, withDestinationURL: fixture.linked)
        case "ancestor-symlink":
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: fixture.root)
            path = target.appendingPathComponent("linked").path
        case "file": try Data().write(to: target)
        case "relative": path = "linked"
        case "noncanonical": path = fixture.linked.path + "/../linked"
        default: break
        }
        let executor = WorktreeCleanupExecutor(runner: fixture.runner(), processInspector: CleanupWorktreeProcesses(),
            openFileCheck: { _ in .clear }, trashHandler: { _ in Issue.record("Unsafe path reached Trash"); return nil })
        #expect(!executor.moveToTrash(worktree: fixture.record(path: path), parentRoot: fixture.root).trashed)
    }

    @Test(arguments: [".env", "secrets/password.txt", "nested/client.pem", "nested/history/events.txt"])
    func protectedDescendantsPreventTrash(_ path: String) throws {
        let fixture = try CleanupWorktreeFixture(); defer { fixture.remove() }
        let secret = fixture.linked.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: secret.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: secret)
        let executor = WorktreeCleanupExecutor(runner: fixture.runner(trackedIndex: "H 100644 aaaa 0\t\(path)\0"), processInspector: CleanupWorktreeProcesses(),
            openFileCheck: { _ in .clear }, trashHandler: { _ in Issue.record("Protected descendant reached Trash"); return nil })
        let result = executor.moveToTrash(worktree: fixture.record(), parentRoot: fixture.root)
        #expect(!result.trashed)
        #expect(result.error?.contains("sensitive") == true)
    }

    @Test func identityReplacementDuringInspectionIsRejected() throws {
        let fixture = try CleanupWorktreeFixture(); defer { fixture.remove() }
        let base = fixture.runner()
        let runner = CleanupWorktreeRunner { request in
            let result = try base.run(request)
            if request.arguments.contains("merge-base") {
                try FileManager.default.moveItem(at: fixture.linked, to: fixture.root.appendingPathComponent("original"))
                try FileManager.default.createDirectory(at: fixture.linked, withIntermediateDirectories: true)
            }
            return result
        }
        let executor = WorktreeCleanupExecutor(runner: runner, processInspector: CleanupWorktreeProcesses(),
            openFileCheck: { _ in .clear }, trashHandler: { _ in Issue.record("Changed identity reached Trash"); return nil })
        let result = executor.moveToTrash(worktree: fixture.record(), parentRoot: fixture.root)
        #expect(!result.trashed)
        #expect(result.error?.contains("identity changed") == true)
    }

    @Test func defaultOpenFileCheckIsRequiredAndRunsLive() throws {
        let fixture = try CleanupWorktreeFixture(); defer { fixture.remove() }
        let base = fixture.runner()
        let calls = WorktreeTrashCalls()
        let runner = CleanupWorktreeRunner { request in
            if request.executable == "/usr/sbin/lsof" {
                if request.arguments.contains(fixture.linked.path) { calls.record(fixture.linked) }
                return cleanupWorktreeResult("p91\n")
            }
            return try base.run(request)
        }
        let executor = WorktreeCleanupExecutor(runner: runner, processInspector: CleanupWorktreeProcesses(),
            trashHandler: { _ in Issue.record("Open files reached Trash"); return nil })
        #expect(!executor.moveToTrash(worktree: fixture.record(), parentRoot: fixture.root).trashed)
        #expect(calls.urls == [fixture.linked])
    }

    @Test func trashFailureReturnsSanitizedError() throws {
        let fixture = try CleanupWorktreeFixture(); defer { fixture.remove() }
        let calls = WorktreeTrashCalls()
        let executor = WorktreeCleanupExecutor(runner: fixture.runner(), processInspector: CleanupWorktreeProcesses(),
            openFileCheck: { _ in .clear }, trashHandler: { url in
                calls.record(url)
                throw NSError(domain: "private-diagnostic", code: 1, userInfo: [NSLocalizedDescriptionKey: "sensitive diagnostic"])
            })
        let result = executor.moveToTrash(worktree: fixture.record(), parentRoot: fixture.root)
        #expect(!result.trashed)
        #expect(result.trashedURL == nil)
        #expect(result.error == "Could not move worktree to Trash")
        #expect(calls.urls == [fixture.linked])
    }

    @Test func trashSuccessDoesNotRequireDestinationURL() throws {
        let fixture = try CleanupWorktreeFixture(); defer { fixture.remove() }
        let calls = WorktreeTrashCalls()
        let executor = WorktreeCleanupExecutor(runner: fixture.runner(), processInspector: CleanupWorktreeProcesses(),
            openFileCheck: { _ in .clear }, trashHandler: { url in calls.record(url); return nil })
        let result = executor.moveToTrash(worktree: fixture.record(), parentRoot: fixture.root)
        #expect(result.trashed)
        #expect(result.trashedURL == nil)
        #expect(result.error == nil)
        #expect(calls.urls == [fixture.linked])
    }
}
