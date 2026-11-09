import Foundation
import Testing
@testable import SuyoiCore

private struct StorageSafetyProcesses: ProcessInspecting {
    func inspectProcesses(uid: Int) -> Observation<[ObservedProcess]> {
        Observation(value: [], status: .complete, warnings: [], capturedAt: Date())
    }
}

private struct StorageSafetyGit: CommandRunning {
    var globalConfigPath = "/dev/null"
    var afterGit: (@Sendable (CommandRequest) throws -> Void)? = nil

    func run(_ request: CommandRequest) throws -> CommandResult {
        var environment = request.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = globalConfigPath
        let result = try CommandRunner().run(CommandRequest(executable: request.executable,
            arguments: request.arguments, environment: environment, timeout: request.timeout,
            maximumOutputBytes: request.maximumOutputBytes, workingDirectory: request.workingDirectory))
        try afterGit?(request)
        return result
    }
}

private enum StorageSafetyError: Error { case git(String) }

private struct StorageSafetyFixture {
    let root: URL
    let repo: URL
    let linked: URL
    let fm = FileManager.default

    init() throws {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/storage-safety/fixtures", isDirectory: true)
        root = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        repo = root.appendingPathComponent("main")
        linked = root.appendingPathComponent("linked")
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
    }

    func dispose() { try? fm.removeItem(at: root) }

    @discardableResult
    func git(_ args: String..., at url: URL? = nil) throws -> String {
        let result = try StorageSafetyGit().run(CommandRequest(executable: "/usr/bin/git",
            arguments: ["-C", (url ?? repo).path] + args))
        guard result.exitCode == 0, !result.timedOut else {
            throw StorageSafetyError.git(result.stderrText)
        }
        return result.stdoutText
    }

    func createWorktree() throws {
        try git("init", "--initial-branch=main", "--template=")
        try Data("drafts/\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))
        try Data("payload.txt filter=review\n".utf8).write(to: repo.appendingPathComponent(".gitattributes"))
        try Data("tracked\n".utf8).write(to: repo.appendingPathComponent("payload.txt"))
        try git("add", ".")
        try git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
            "-c", "commit.gpgsign=false", "commit", "-m", "Fixture")
        try git("worktree", "add", "-b", "merged", linked.path)
    }

    func secondaryRecord(runner: StorageSafetyGit = StorageSafetyGit()) throws -> WorktreeRecord {
        let observation = WorktreeInspector(runner: runner).inspect(root: root,
            processes: StorageSafetyProcesses().inspectProcesses(uid: 0))
        #expect(observation.status == .complete)
        return try #require(observation.value.first { $0.path == linked.path })
    }
}

@Suite struct StorageSafetyTests {
    @Test func ignoredLocalFilePreventsWholeWorktreeTrash() throws {
        let fixture = try StorageSafetyFixture()
        defer { fixture.dispose() }
        try fixture.createWorktree()
        let local = fixture.linked.appendingPathComponent("drafts")
        try fixture.fm.createDirectory(at: local, withIntermediateDirectories: false)
        let draft = local.appendingPathComponent("uncommitted-design.txt")
        try Data("local-only data".utf8).write(to: draft)
        let ignored = try fixture.git("status", "--porcelain=v1", "--untracked-files=all", "--ignored", at: fixture.linked)
        #expect(ignored.contains("!! drafts/uncommitted-design.txt"))
        let record = try fixture.secondaryRecord()
        #expect(record.isMergedToDefault == true)
        #expect(!record.blockedReasons.isEmpty)
        let executor = WorktreeCleanupExecutor(runner: StorageSafetyGit(),
            processInspector: StorageSafetyProcesses(), openFileCheck: { _ in .clear },
            trashHandler: { _ in
                Issue.record("A worktree containing local-only data reached Trash")
                return nil
            })
        // Use the same reinspection root as DashboardModel.
        #expect(!executor.moveToTrash(worktree: record, parentRoot: fixture.linked).trashed)
        #expect(FileManager.default.fileExists(atPath: draft.path))
    }

    @Test func ordinaryFileAddedDuringUsageCheckPreventsWholeWorktreeTrash() throws {
        let fixture = try StorageSafetyFixture()
        defer { fixture.dispose() }
        try fixture.createWorktree()
        let record = try fixture.secondaryRecord()
        let draft = fixture.linked.appendingPathComponent("new-design.txt")
        let executor = WorktreeCleanupExecutor(runner: StorageSafetyGit(),
            processInspector: StorageSafetyProcesses(), openFileCheck: { path in
                if path == fixture.linked.path {
                    do { try Data("new local-only data".utf8).write(to: draft) }
                    catch { Issue.record("Could not create fixture draft") }
                }
                return .clear
            }, trashHandler: { _ in
                Issue.record("A worktree containing local-only data reached Trash")
                return nil
            })
        #expect(!executor.moveToTrash(worktree: record, parentRoot: fixture.linked).trashed)
        #expect(FileManager.default.fileExists(atPath: draft.path))
        #expect(try fixture.git("status", "--porcelain=v1", "--untracked-files=all", at: fixture.linked)
            .contains("?? new-design.txt"))
    }

    @Test func ordinaryFileAddedAfterFinalGitStatusPreventsWholeWorktreeTrash() throws {
        let fixture = try StorageSafetyFixture()
        defer { fixture.dispose() }
        try fixture.createWorktree()
        let record = try fixture.secondaryRecord()
        #expect(record.blockedReasons.isEmpty)
        let firstStatus = fixture.root.appendingPathComponent("first-status")
        let draft = fixture.linked.appendingPathComponent("written-after-status.txt")
        let runner = StorageSafetyGit(afterGit: { request in
            guard request.arguments.contains("status"), request.arguments.contains(fixture.linked.path) else { return }
            if FileManager.default.fileExists(atPath: firstStatus.path) {
                try Data("local draft".utf8).write(to: draft)
            } else {
                try Data().write(to: firstStatus)
            }
        })
        let executor = WorktreeCleanupExecutor(runner: runner, processInspector: StorageSafetyProcesses(),
            openFileCheck: { _ in .clear }, trashHandler: { _ in
                Issue.record("A file written after Git status reached Trash")
                return nil
            })
        #expect(!executor.moveToTrash(worktree: record, parentRoot: fixture.linked).trashed)
        #expect(FileManager.default.fileExists(atPath: draft.path))
    }

    @Test func previewDoesNotRunConfiguredGitCleanFilter() throws {
        let fixture = try StorageSafetyFixture()
        defer { fixture.dispose() }
        try fixture.createWorktree()
        let marker = fixture.root.appendingPathComponent("filter-ran")
        try fixture.git("config", "--local", "filter.review.clean", "touch '\(marker.path)'; cat")
        let payload = fixture.linked.appendingPathComponent("payload.txt")
        try Data("changed\n".utf8).write(to: payload)
        try fixture.fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: payload.path)
        #expect(!fixture.fm.fileExists(atPath: marker.path))
        let record = try fixture.secondaryRecord()
        #expect(record.isDirty)
        #expect(!fixture.fm.fileExists(atPath: marker.path))
    }

    @Test func sandboxBlocksFilterIntroducedAfterConfigurationCheck() throws {
        let fixture = try StorageSafetyFixture()
        defer { fixture.dispose() }
        try fixture.createWorktree()
        let marker = fixture.root.appendingPathComponent("late-filter-ran")
        let runner = StorageSafetyGit(afterGit: { request in
            guard request.arguments.contains("--get-regexp"), request.arguments.contains(fixture.linked.path) else { return }
            try fixture.git("config", "--local", "filter.review.clean", "touch '\(marker.path)'; cat")
            let payload = fixture.linked.appendingPathComponent("payload.txt")
            try Data("changed\n".utf8).write(to: payload)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: payload.path)
        })
        let record = try fixture.secondaryRecord(runner: runner)
        #expect(record.blockedReasons.contains("Could not verify worktree status"))
        #expect(!fixture.fm.fileExists(atPath: marker.path))
    }

    @Test func nestedGitMetadataPreventsWholeWorktreeTrash() throws {
        let fixture = try StorageSafetyFixture()
        defer { fixture.dispose() }
        try fixture.createWorktree()
        let tracked = fixture.repo.appendingPathComponent("src")
        try fixture.fm.createDirectory(at: tracked, withIntermediateDirectories: false)
        try Data("tracked".utf8).write(to: tracked.appendingPathComponent("file"))
        try fixture.git("add", "src")
        try fixture.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
            "-c", "commit.gpgsign=false", "commit", "-m", "Track source directory")
        try fixture.git("merge", "--ff-only", "main", at: fixture.linked)
        let record = try fixture.secondaryRecord()
        #expect(record.blockedReasons.isEmpty)
        let localMetadata = fixture.linked.appendingPathComponent("src/.git")
        let executor = WorktreeCleanupExecutor(runner: StorageSafetyGit(),
            processInspector: StorageSafetyProcesses(), openFileCheck: { path in
                guard path == fixture.linked.path else { return .clear }
                do {
                    try Data("local Git metadata".utf8).write(to: localMetadata)
                    return .clear
                } catch {
                    Issue.record("Could not create nested Git metadata")
                    return .unknown
                }
            }, trashHandler: { _ in Issue.record("Nested Git metadata reached Trash"); return nil })
        let outcome = executor.moveToTrash(worktree: record, parentRoot: fixture.linked)
        #expect(!outcome.trashed)
        #expect(outcome.error == "Worktree contains local files or directories that are not tracked by Git")
        #expect(fixture.fm.fileExists(atPath: localMetadata.path))
    }

    @Test func cleanMergedFixtureCanStillBeMovedToTrash() throws {
        let fixture = try StorageSafetyFixture()
        defer { fixture.dispose() }
        try fixture.createWorktree()
        let config = fixture.root.appendingPathComponent("isolated-global-config")
        try fixture.git("config", "--file", config.path, "filter.lfs.clean", "exit 1")
        let runner = StorageSafetyGit(globalConfigPath: config.path)
        let record = try fixture.secondaryRecord(runner: runner)
        #expect(record.blockedReasons.isEmpty)
        let destination = fixture.root.appendingPathComponent("fixture-trash")
        let executor = WorktreeCleanupExecutor(runner: runner,
            processInspector: StorageSafetyProcesses(), openFileCheck: { _ in .clear },
            trashHandler: { source in
                try FileManager.default.moveItem(at: source, to: destination)
                return destination
            })
        let outcome = executor.moveToTrash(worktree: record, parentRoot: fixture.linked)
        #expect(outcome.trashed)
        #expect(outcome.recovery?.fileIdentity == FileMetadataReader().identity(at: destination))
    }

    @Test func cachedMeasurementPreservesAllocatedSize() throws {
        let fixture = try StorageSafetyFixture()
        defer { fixture.dispose() }
        let build = fixture.repo.appendingPathComponent(".build")
        try fixture.fm.createDirectory(at: build, withIntermediateDirectories: false)
        try Data([1]).write(to: build.appendingPathComponent("artifact"))
        let scanner = CleanupScanner()
        let measured = try #require(scanner.scan(root: fixture.repo, entryLimit: 100_000).candidates.first)
        let cached = try #require(scanner.scan(root: fixture.repo, entryLimit: 100_000).candidates.first)
        #expect(!measured.partial && !cached.partial)
        #expect(measured.bytes == 1 && cached.bytes == 1)
        #expect(measured.allocatedBytes != measured.bytes)
        #expect(cached.allocatedBytes == measured.allocatedBytes)
    }
}
