import Foundation

public struct WorktreeInspector: Sendable {
    private let runner: any CommandRunning
    private let openFileCheck: (@Sendable (String) -> UsageState)?
    public init(runner: any CommandRunning = CommandRunner(), openFileCheck: (@Sendable (String) -> UsageState)? = nil) {
        self.runner = runner; self.openFileCheck = openFileCheck
    }

    public func inspect(root: URL, processes: Observation<[ObservedProcess]> = Observation(value: [], status: .unavailable, warnings: [], capturedAt: Date())) -> Observation<[WorktreeRecord]> {
        var warnings: [String] = []
        let repos = discoverRepositories(root: root, warnings: &warnings)
        guard !repos.isEmpty else {
            return Observation(value: [], status: warnings.isEmpty ? .complete : .partial,
                warnings: warnings, capturedAt: Date())
        }
        guard let git = ReadOnlyWorktreeGit(runner: runner) else {
            return Observation(value: [], status: .unavailable,
                warnings: warnings + ["Could not start read-only Git inspection"], capturedAt: Date())
        }
        var records: [WorktreeRecord] = []
        var seen = Set<String>()
        for repo in repos {
            guard let entries = entries(in: repo.path, git: git) else {
                warnings.append("Could not inspect worktrees in \(repo.path)"); continue
            }
            for (index, entry) in entries.enumerated() {
                let canonical = URL(fileURLWithPath: entry.path).standardizedFileURL.resolvingSymlinksInPath().path
                guard seen.insert(canonical).inserted else { continue }
                var reasons: [String] = []
                let isMain = index == 0
                var dirty = false
                var merged: Bool?
                if isMain { reasons.append("Main working tree") }
                if entry.bare { reasons.append("Bare repository") }
                if entry.locked { reasons.append("Worktree is locked") }
                if entry.prunable { reasons.append("Worktree is prunable or unavailable") }
                let treeURL = URL(fileURLWithPath: entry.path)
                let pathVerified = entry.path.hasPrefix("/") && FileMetadataReader().identity(at: treeURL) != nil && treeURL.standardizedFileURL.resolvingSymlinksInPath().path == treeURL.standardizedFileURL.path
                if !pathVerified { reasons.append("Worktree path is unavailable or contains a symlink") }
                if !isMain && !entry.bare {
                    if pathVerified {
                        let blocker: String?
                        if let tracked = git.trackedPaths(entry.path) {
                            blocker = git.filterBlocker(entry.path, tracked: tracked)
                                ?? git.statusBlocker(entry.path, head: entry.head, branch: entry.branch)
                        } else {
                            blocker = "Could not verify the worktree Git index"
                        }
                        dirty = blocker != nil
                        if let blocker { reasons.append(blocker) }
                        merged = mergeStatus(path: entry.path, head: entry.head, git: git)
                    } else {
                        dirty = true
                        reasons.append("Could not verify worktree status")
                    }
                    if merged != true { reasons.append("Worktree is not verified merged to the default branch") }
                }
                let cwd = NodeModulesSafety.workingDirectoryUsage(root: treeURL, processes: processes)
                var usage = cwd.0
                reasons.append(contentsOf: cwd.1)
                if let check = openFileCheck, pathVerified {
                    let open = check(entry.path)
                    if open == .inUse { usage = .inUse }
                    else if open == .unknown && usage == .clear { usage = .unknown }
                }
                if !pathVerified && usage == .clear { usage = .unknown }
                if usage == .unknown { reasons.append("Worktree usage could not be verified") }
                if usage == .inUse { reasons.append("Worktree is in use") }
                records.append(WorktreeRecord(path: entry.path, branch: entry.branch, headCommit: entry.head, isMain: isMain,
                                              isDirty: dirty, isLocked: entry.locked, isMergedToDefault: merged,
                                              usage: usage, blockedReasons: reasons))
            }
        }
        return Observation(value: records, status: warnings.isEmpty ? .complete : .partial, warnings: warnings, capturedAt: Date())
    }

    /// Returns nil for malformed or incomplete NUL-delimited output. Branch names
    /// remain full refs so detached and named branches cannot be confused.
    public static func parsePorcelain(_ text: String) -> [WorktreeRecord]? {
        parseEntries(text)?.enumerated().map { index, entry in
            WorktreeRecord(path: entry.path, branch: entry.branch, headCommit: entry.head, isMain: index == 0,
                           isDirty: false, isLocked: entry.locked, isMergedToDefault: nil, usage: .unknown,
                           blockedReasons: (index == 0 ? ["Main working tree"] : []) + (entry.locked ? ["Worktree is locked"] : []) + (entry.prunable ? ["Worktree is prunable or unavailable"] : []) + ["Worktree usage could not be verified"])
        }
    }

    private struct Entry {
        var path: String
        var branch: String?
        var head: String?
        var bare = false
        var locked = false
        var prunable = false
    }

    private static func parseEntries(_ text: String) -> [Entry]? {
        guard !text.isEmpty, text.hasSuffix("\0\0") else { return nil }
        var entries: [Entry] = []
        var current: Entry?
        for field in text.components(separatedBy: "\0") {
            if field.isEmpty {
                if let entry = current { entries.append(entry); current = nil }
                continue
            }
            if field.hasPrefix("worktree ") {
                guard current == nil else { return nil }
                let path = String(field.dropFirst(9))
                guard path.hasPrefix("/") else { return nil }
                current = Entry(path: path)
            } else {
                guard current != nil else { return nil }
                if field.hasPrefix("HEAD ") { current?.head = String(field.dropFirst(5)) }
                else if field.hasPrefix("branch ") { current?.branch = String(field.dropFirst(7)) }
                else if field == "detached" { current?.branch = nil }
                else if field == "bare" { current?.bare = true }
                else if field == "locked" || field.hasPrefix("locked ") { current?.locked = true }
                else if field == "prunable" || field.hasPrefix("prunable ") { current?.prunable = true }
                else { return nil }
            }
        }
        return entries.isEmpty ? nil : entries
    }

    /// Re-read registration and status after potentially slow usage checks.
    func freshTrashBlocker(_ worktree: WorktreeRecord,
                           inspectContents: (ReadOnlyWorktreeGit.TrackedPaths) -> String?) -> String? {
        guard let git = ReadOnlyWorktreeGit(runner: runner),
              let entries = entries(in: worktree.path, git: git) else {
            return "Could not verify live worktree registration"
        }
        let matching = entries.enumerated().filter { $0.element.path == worktree.path }
        guard matching.count == 1, let (index, entry) = matching.first, index != 0,
              !entry.bare, !entry.locked, !entry.prunable, entry.branch == worktree.branch,
              entry.head == worktree.headCommit else {
            return "Worktree registration, branch, or commit changed during verification"
        }
        guard mergeStatus(path: worktree.path, head: entry.head, git: git) == true else {
            return "Worktree is not verified merged to the default branch"
        }
        guard let trackedPaths = git.trackedPaths(worktree.path) else {
            return "Could not verify the worktree Git index"
        }
        if let blocker = git.filterBlocker(worktree.path, tracked: trackedPaths) { return blocker }
        if let blocker = git.statusBlocker(worktree.path, head: entry.head, branch: entry.branch) { return blocker }
        return inspectContents(trackedPaths)
    }

    private func entries(in path: String, git: ReadOnlyWorktreeGit) -> [Entry]? {
        guard let result = git.command(path, ["worktree", "list", "--porcelain", "-z"]),
              ReadOnlyWorktreeGit.successful(result), let text = String(data: result.stdout, encoding: .utf8) else { return nil }
        return Self.parseEntries(text)
    }

    private func mergeStatus(path: String, head: String?, git: ReadOnlyWorktreeGit) -> Bool? {
        guard let head, !head.isEmpty, head.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        for ref in ["refs/heads/main", "refs/heads/master", "refs/remotes/origin/HEAD"] {
            guard let exists = git.command(path, ["rev-parse", "--verify", "--quiet", ref]),
                  ReadOnlyWorktreeGit.complete(exists) else { return nil }
            if exists.exitCode == 1 { continue }
            guard exists.exitCode == 0, !exists.stdout.isEmpty,
                  let ancestor = git.command(path, ["merge-base", "--is-ancestor", head, ref]),
                  ReadOnlyWorktreeGit.complete(ancestor) else { return nil }
            if ancestor.exitCode == 0 { return true }
            if ancestor.exitCode == 1 { return false }
            return nil
        }
        return nil
    }

    private func discoverRepositories(root: URL, warnings: inout [String]) -> [URL] {
        let reader = FileMetadataReader()
        let normalizedRoot = root.standardizedFileURL
        guard normalizedRoot.path.hasPrefix("/"), reader.identity(at: normalizedRoot) != nil else {
            warnings.append("Repository root is unavailable or contains a symlink"); return []
        }
        guard normalizedRoot.deletingLastPathComponent().resolvingSymlinksInPath().path == normalizedRoot.deletingLastPathComponent().path else {
            warnings.append("Repository root is unavailable or contains a symlink"); return []
        }
        let canonicalRoot = normalizedRoot.resolvingSymlinksInPath()
        var repos: [URL] = []
        var visited = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        func visit(_ directory: URL, depth: Int) {
            guard visited < 10_000, ProcessInfo.processInfo.systemUptime < deadline else {
                if !warnings.contains("Repository discovery budget exceeded") { warnings.append("Repository discovery budget exceeded") }
                return
            }
            visited += 1
            let resolvedDir = directory.standardizedFileURL
            if reader.identity(at: resolvedDir.appendingPathComponent(".git")) != nil { repos.append(resolvedDir) }
            guard depth < 3 else { return }
            var enumerationFailed = false
            guard let children = FileManager.default.enumerator(at: resolvedDir,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsSubdirectoryDescendants], errorHandler: { _, _ in
                    enumerationFailed = true; return true
                }) else {
                warnings.append("Could not discover repositories in \(resolvedDir.path)"); return
            }
            do {
                while let child = children.nextObject() as? URL {
                    if visited >= 10_000 || ProcessInfo.processInfo.systemUptime >= deadline {
                        if !warnings.contains("Repository discovery budget exceeded") { warnings.append("Repository discovery budget exceeded") }
                        break
                    }
                    visited += 1
                    let name = child.lastPathComponent
                    if ["node_modules", ".build", ".git"].contains(name) { continue }
                    let childURL = resolvedDir.appendingPathComponent(name)
                    guard reader.identity(at: childURL) != nil else { continue }
                    let values = try childURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if values.isDirectory == true && values.isSymbolicLink != true { visit(childURL, depth: depth + 1) }
                }
            } catch { warnings.append("Could not discover repositories in \(resolvedDir.path)") }
            if enumerationFailed { warnings.append("Could not discover all repositories in \(resolvedDir.path)") }
        }
        visit(canonicalRoot, depth: 0)
        return repos
    }
}
