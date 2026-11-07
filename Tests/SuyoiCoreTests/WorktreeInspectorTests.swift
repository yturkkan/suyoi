import Foundation
import Testing
@testable import SuyoiCore

private struct WorktreeCommandStub: CommandRunning {
    let handler: @Sendable (CommandRequest) throws -> CommandResult
    func run(_ request: CommandRequest) throws -> CommandResult {
        #expect(request.executable == "/usr/bin/git")
        #expect(request.arguments.prefix(2).first == "-C")
        #expect(request.arguments.contains("core.fsmonitor=false"))
        #expect(request.environment["GIT_OPTIONAL_LOCKS"] == "0")
        #expect(request.timeout <= 4)
        return try handler(request)
    }
}

private func wtResult(_ output: String = "", exit: Int32 = 0, error: String = "", timeout: Bool = false, truncated: Bool = false) -> CommandResult {
    CommandResult(exitCode: exit, stdout: Data(output.utf8), stderr: Data(error.utf8), timedOut: timeout, truncated: truncated)
}

private struct WorktreeFixture {
    let root: URL
    let main: URL
    let linked: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("suyoi-worktree-" + UUID().uuidString).resolvingSymlinksInPath()
        main = root.appendingPathComponent("main")
        linked = root.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: main.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
    }
    var porcelain: String {
        "worktree \(main.path)\0HEAD aaaa\0branch refs/heads/main\0\0worktree \(linked.path)\0HEAD bbbb\0branch refs/heads/feature\0\0"
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private func wtProcesses(_ processes: [ObservedProcess] = [], status: ObservationStatus = .complete) -> Observation<[ObservedProcess]> {
    Observation(value: processes, status: status, warnings: [], capturedAt: Date(timeIntervalSince1970: 0))
}

struct WorktreeInspectorTests {
    @Test func parsesNULRecordsAndUnusualPaths() throws {
        let text = "worktree /fixture/main\0HEAD aaa\0branch refs/heads/main\0\0worktree /fixture/with space\nand newline\0HEAD bbb\0detached\0locked maintenance\0prunable gitdir missing\0\0"
        let records = try #require(WorktreeInspector.parsePorcelain(text))
        #expect(records.count == 2)
        #expect(records[0].isMain)
        #expect(records[0].blockedReasons.contains("Main working tree"))
        #expect(records[0].branch == "refs/heads/main")
        #expect(records[1].path == "/fixture/with space\nand newline")
        #expect(records[1].headCommit == "bbb")
        #expect(records[1].branch == nil)
        #expect(records[1].isLocked)
        #expect(records[1].blockedReasons.contains("Worktree is prunable or unavailable"))
        #expect(records[1].usage == .unknown)
        let bare = try #require(WorktreeInspector.parsePorcelain("worktree /fixture/bare\0bare\0\0"))
        #expect(bare.count == 1)
        #expect(bare[0].headCommit == nil)
    }

    @Test(arguments: ["", "worktree /fixture/main\0HEAD abc\0", "HEAD abc\0\0", "worktree relative\0\0", "worktree /a\0worktree /b\0\0", "worktree /a\0unexpected value\0\0"])
    func rejectsMalformedOutput(_ text: String) {
        #expect(WorktreeInspector.parsePorcelain(text) == nil)
    }

    @Test func cleanMergedAndMainRecords() throws {
        let fixture = try WorktreeFixture(); defer { fixture.remove() }
        let listing = fixture.porcelain
        let runner = WorktreeCommandStub { request in
            if request.arguments.contains("list") {
                #expect(request.arguments.suffix(4) == ["worktree", "list", "--porcelain", "-z"])
                return wtResult(listing)
            }
            if request.arguments.contains("status") {
                #expect(request.arguments.suffix(3) == ["status", "--porcelain=v1", "--untracked-files=all"])
                return wtResult()
            }
            if request.arguments.contains("rev-parse") { return wtResult("aaaa\n") }
            if request.arguments.contains("merge-base") { return wtResult() }
            Issue.record("Unexpected command"); return wtResult(exit: 2)
        }
        let result = WorktreeInspector(runner: runner).inspect(root: fixture.root, processes: wtProcesses())
        #expect(result.status == .complete)
        #expect(result.value.count == 2)
        let main = try #require(result.value.first { $0.isMain })
        #expect(main.blockedReasons.contains("Main working tree"))
        let linked = try #require(result.value.first { !$0.isMain })
        #expect(!linked.isDirty)
        #expect(linked.isMergedToDefault == true)
        #expect(linked.usage == .clear)
        #expect(linked.blockedReasons.isEmpty)
    }

    @Test func dirtyLockedUnmergedAndInUseAreBlocked() throws {
        let fixture = try WorktreeFixture(); defer { fixture.remove() }
        let listing = String(fixture.porcelain.dropLast()) + "locked review\0\0"
        let runner = WorktreeCommandStub { request in
            if request.arguments.contains("list") { return wtResult(listing) }
            if request.arguments.contains("status") { return wtResult("?? local-file\n") }
            if request.arguments.contains("rev-parse") { return wtResult("aaaa\n") }
            return wtResult(exit: 1)
        }
        let active = ObservedProcess(pid: 91, parentPID: 1, uid: 501, cpuPercent: 0, residentBytes: 0, executable: "/bin/node", cwd: fixture.linked.appendingPathComponent("src").path)
        let result = WorktreeInspector(runner: runner).inspect(root: fixture.root, processes: wtProcesses([active]))
        let linked = try #require(result.value.first { !$0.isMain })
        #expect(linked.isDirty)
        #expect(linked.isLocked)
        #expect(linked.isMergedToDefault == false)
        #expect(linked.usage == .inUse)
        #expect(linked.blockedReasons.contains("Worktree has uncommitted changes"))
        #expect(linked.blockedReasons.contains("Worktree is locked"))
        #expect(linked.blockedReasons.contains("Worktree is not verified merged to the default branch"))
        #expect(linked.blockedReasons.contains("Worktree is in use"))
    }

    @Test func failedStatusAndMissingDefaultRefFailClosed() throws {
        let fixture = try WorktreeFixture(); defer { fixture.remove() }
        let listing = fixture.porcelain
        let runner = WorktreeCommandStub { request in
            if request.arguments.contains("list") { return wtResult(listing) }
            if request.arguments.contains("status") { return wtResult(exit: 128, error: "unavailable") }
            return wtResult(exit: 1)
        }
        let result = WorktreeInspector(runner: runner).inspect(root: fixture.root, processes: wtProcesses(status: .unavailable))
        let linked = try #require(result.value.first { !$0.isMain })
        #expect(linked.isDirty)
        #expect(linked.blockedReasons.contains("Could not verify worktree status"))
        #expect(linked.isMergedToDefault == nil)
        #expect(linked.usage == .unknown)
    }

    @Test(arguments: ["refs/heads/master", "refs/remotes/origin/HEAD"])
    func localDefaultRefFallbacks(_ target: String) throws {
        let fixture = try WorktreeFixture(); defer { fixture.remove() }
        let listing = fixture.porcelain
        let runner = WorktreeCommandStub { request in
            if request.arguments.contains("list") { return wtResult(listing) }
            if request.arguments.contains("status") { return wtResult() }
            if request.arguments.contains("rev-parse") {
                return request.arguments.last == target ? wtResult("aaaa\n") : wtResult(exit: 1)
            }
            #expect(request.arguments.last == target)
            return wtResult()
        }
        let records = WorktreeInspector(runner: runner).inspect(root: fixture.root, processes: wtProcesses()).value
        #expect(records.first { !$0.isMain }?.isMergedToDefault == true)
    }

    @Test func timeoutTruncationWarningAndMalformedListArePartial() throws {
        let fixture = try WorktreeFixture(); defer { fixture.remove() }
        for response in [wtResult(fixture.porcelain, timeout: true), wtResult(fixture.porcelain, truncated: true), wtResult(fixture.porcelain, error: "warning"), wtResult("malformed"), wtResult(exit: 128)] {
            let runner = WorktreeCommandStub { _ in response }
            let result = WorktreeInspector(runner: runner).inspect(root: fixture.root, processes: wtProcesses())
            #expect(result.status == .partial)
            #expect(result.value.isEmpty)
            #expect(!result.warnings.isEmpty)
        }
    }

    @Test func injectedUsageCannotTurnUnknownOrBusyIntoClear() throws {
        let fixture = try WorktreeFixture(); defer { fixture.remove() }
        let listing = fixture.porcelain
        let runner = WorktreeCommandStub { request in
            if request.arguments.contains("list") { return wtResult(listing) }
            if request.arguments.contains("rev-parse") { return wtResult("aaaa\n") }
            return wtResult()
        }
        let unknown = WorktreeInspector(runner: runner, openFileCheck: { _ in .clear }).inspect(root: fixture.root)
        #expect(unknown.value.allSatisfy { $0.usage == .unknown })
        let busy = WorktreeInspector(runner: runner, openFileCheck: { _ in .inUse }).inspect(root: fixture.root, processes: wtProcesses())
        #expect(busy.value.allSatisfy { $0.usage == .inUse })
        let uncertain = WorktreeInspector(runner: runner, openFileCheck: { _ in .unknown }).inspect(root: fixture.root, processes: wtProcesses())
        #expect(uncertain.value.allSatisfy { $0.usage == .unknown })
    }

    @Test func discoverySkipsDependenciesSymlinksAndDepthFour() throws {
        let fixture = try WorktreeFixture(); defer { fixture.remove() }
        let skipped = ["node_modules/hidden/.git", ".build/hidden/.git", "a/b/c/d/.git"]
        for path in skipped {
            try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("alias"), withDestinationURL: fixture.main)
        let expected = fixture.main.path
        let listing = fixture.porcelain
        let runner = WorktreeCommandStub { request in
            #expect(request.arguments[1] == expected || !request.arguments.contains("list"))
            if request.arguments.contains("list") { return wtResult(listing) }
            if request.arguments.contains("rev-parse") { return wtResult("aaaa\n") }
            return wtResult()
        }
        let result = WorktreeInspector(runner: runner).inspect(root: fixture.root, processes: wtProcesses())
        #expect(result.status == .complete)
        #expect(result.value.count == 2)
        let symlinkRoot = WorktreeInspector(runner: runner).inspect(root: fixture.root.appendingPathComponent("alias"))
        #expect(symlinkRoot.status == .partial)
        #expect(symlinkRoot.value.isEmpty)
    }
}
