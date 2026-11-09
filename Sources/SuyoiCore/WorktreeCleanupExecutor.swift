import Foundation
import Darwin

public struct WorktreeTrashOutcome: Equatable, Sendable {
    public let path: String
    public let branch: String?
    public let trashed: Bool
    public let trashedURL: URL?
    public let error: String?
    public let recovery: TrashRecoveryEvidence?

    public init(path: String, branch: String?, trashed: Bool, trashedURL: URL?, error: String?,
                recovery: TrashRecoveryEvidence? = nil) {
        self.path = path
        self.branch = branch
        self.trashed = trashed
        self.trashedURL = trashedURL
        self.error = error
        self.recovery = recovery
    }
}

/// Explicit user actions only. A preview record cannot replace live safety checks.
public struct WorktreeCleanupExecutor: Sendable {
    private let runner: any CommandRunning
    private let processInspector: any ProcessInspecting
    private let openFileCheck: @Sendable (String) -> UsageState
    private let trashHandler: @Sendable (URL) throws -> URL?

    public init(
        runner: any CommandRunning = CommandRunner(),
        processInspector: any ProcessInspecting = NativeProcessInspector(),
        openFileCheck: (@Sendable (String) -> UsageState)? = nil,
        trashHandler: @escaping @Sendable (URL) throws -> URL? = { url in
            var resulting: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            return resulting as URL?
        }
    ) {
        self.runner = runner
        self.processInspector = processInspector
        self.openFileCheck = openFileCheck ?? { OpenFileInspector(runner: runner).checkPathInUse($0) }
        self.trashHandler = trashHandler
    }

    public func moveToTrash(worktree: WorktreeRecord, parentRoot: URL) -> WorktreeTrashOutcome {
        func failure(_ error: String) -> WorktreeTrashOutcome {
            WorktreeTrashOutcome(path: worktree.path, branch: worktree.branch,
                                 trashed: false, trashedURL: nil, error: error)
        }
        guard !worktree.isMain else { return failure("Main working trees cannot be moved to Trash") }
        guard !worktree.isDirty, !worktree.isLocked, worktree.isMergedToDefault == true,
              worktree.usage == .clear, worktree.blockedReasons.isEmpty else {
            return failure("Worktree was not eligible for Trash")
        }
        guard worktree.path.hasPrefix("/"), !worktree.path.contains("\0") else {
            return failure("Worktree path is unsafe")
        }
        let url = URL(fileURLWithPath: URL(fileURLWithPath: worktree.path).standardizedFileURL.path, isDirectory: false)
        let reader = FileMetadataReader()
        guard url.path == worktree.path, url.path != "/", Self.isCanonicalDirectory(url),
              !AgentCacheCatalog.isForbiddenPath(url, homeDirectory: URL(fileURLWithPath: "/")),
              let identity = reader.identity(at: url) else {
            return failure("Worktree path is unavailable, unsafe, or contains a symlink")
        }

        let liveProcesses = processInspector.inspectProcesses(uid: Int(getuid()))
        guard liveProcesses.status == .complete, liveProcesses.warnings.isEmpty,
              liveProcesses.value.allSatisfy({ $0.cwd?.hasPrefix("/") == true }) else {
            return failure("Live process usage could not be fully verified")
        }
        let inspector = WorktreeInspector(runner: runner, openFileCheck: openFileCheck)
        let inspection = inspector.inspect(root: parentRoot, processes: liveProcesses)
        guard inspection.status == .complete, inspection.warnings.isEmpty else {
            return failure("Live worktree inspection is unavailable or incomplete")
        }
        let matches = inspection.value.filter { $0.path == url.path }
        guard matches.count == 1, let live = matches.first else {
            return failure("Worktree is no longer uniquely registered")
        }
        guard !live.isMain else { return failure("Main working trees cannot be moved to Trash") }
        guard live.branch == worktree.branch, live.headCommit == worktree.headCommit else {
            return failure("Worktree branch or commit changed since inspection")
        }
        guard !live.isDirty, !live.isLocked, live.isMergedToDefault == true,
              live.usage == .clear, live.blockedReasons.isEmpty else {
            return failure(live.blockedReasons.first ?? "Worktree failed live safety verification")
        }
        guard !inspection.value.contains(where: { $0.isMain && NodeModulesSafety.contains($0.path, in: url.path) }) else {
            return failure("Worktree contains a main working tree")
        }
        guard Self.isCanonicalDirectory(url), reader.identity(at: url) == identity else {
            return failure("Worktree file identity changed during verification")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let policyRoot = url.path.hasPrefix(home.path + "/") ? home : URL(fileURLWithPath: "/")
        if let blocker = inspector.freshTrashBlocker(live, inspectContents: { paths in
            var entries = 0
            if let blocker = reader.trashDescendantBlocker(at: url, expectedIdentity: identity, homeDirectory: policyRoot,
                permitsWorktreeEntry: { path, mode in
                    guard paths.permits(path, mode: mode) else { return false }
                    entries += 1
                    return true
                }) {
                return blocker
            }
            return entries == paths.files.count + paths.directories.count
                ? nil : "Worktree contents changed during verification"
        }) {
            return failure(blocker)
        }
        guard Self.isCanonicalDirectory(url),
              let recovery = TrashRecoveryEvidence.prepare(original: url, expectedIdentity: identity) else {
            return failure("Worktree file identity changed during verification")
        }
        do {
            let resulting = try trashHandler(url)
            return WorktreeTrashOutcome(path: worktree.path, branch: worktree.branch,
                                        trashed: true, trashedURL: resulting, error: nil,
                                        recovery: recovery.completed(at: resulting))
        } catch {
            return failure("Could not move worktree to Trash")
        }
    }

    private static func isCanonicalDirectory(_ url: URL) -> Bool {
        guard url.isFileURL, url.standardizedFileURL.path == url.path,
              url.resolvingSymlinksInPath().path == url.path else { return false }
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return false }
        let parent = url.deletingLastPathComponent().standardizedFileURL
        var parentInfo = stat()
        guard lstat(parent.path, &parentInfo) == 0, (parentInfo.st_mode & S_IFMT) == S_IFDIR else { return false }
        return parent.resolvingSymlinksInPath().path == parent.path
    }
}
