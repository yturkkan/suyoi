import Darwin
import Foundation

/// Run Git builtins without repository-controlled helpers, writes, or network access.
struct ReadOnlyWorktreeGit {
    private static let profile = """
        (version 1)
        (allow default)
        (deny process-fork)
        (deny process-exec)
        (allow process-exec (literal (param "GIT")))
        (deny network*)
        (deny file-write*)
        (allow file-write* (literal "/dev/null"))
        """

    private let runner: any CommandRunning
    private let executable: String

    init?(runner: any CommandRunning) {
        let root = URL(fileURLWithPath: "/")
        guard let tool = try? runner.run(CommandRequest(executable: "/usr/bin/xcrun",
            arguments: ["--no-cache", "--find", "git"], timeout: 4, maximumOutputBytes: 4096, workingDirectory: root)),
              Self.successful(tool), let output = String(data: tool.stdout, encoding: .utf8),
              output.hasSuffix("\n") else { return nil }
        let path = String(output.dropLast())
        guard path.hasPrefix("/"), path.hasSuffix("/git"), !path.contains("\n"), !path.contains("\0") else { return nil }
        let url = URL(fileURLWithPath: path)
        guard url.standardizedFileURL.resolvingSymlinksInPath().path == path,
              let signature = try? runner.run(CommandRequest(executable: "/usr/bin/codesign",
                arguments: ["--verify", "--strict", "-R=anchor apple and identifier \"com.apple.git\"", path],
                timeout: 4, maximumOutputBytes: 4096, workingDirectory: root)),
              Self.successful(signature) else { return nil }
        self.runner = runner
        executable = path
    }

    func command(_ path: String, _ arguments: [String], timeout: TimeInterval = 4) -> CommandResult? {
        try? runner.run(CommandRequest(executable: "/usr/bin/sandbox-exec",
            arguments: ["-D", "GIT=\(executable)", "-p", Self.profile, executable, "-C", path, "--no-pager",
                "--work-tree=\(path)",
                "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false", "-c", "core.ignoreStat=false",
                "-c", "core.trustctime=true", "-c", "core.checkStat=default", "-c", "advice.graftFileDeprecated=false"] + arguments,
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C",
                "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0", "GIT_ALLOW_PROTOCOL": "",
                "GIT_NO_LAZY_FETCH": "1", "GIT_NO_REPLACE_OBJECTS": "1", "GIT_GRAFT_FILE": "/dev/null"],
            timeout: timeout))
    }

    static func successful(_ result: CommandResult) -> Bool {
        result.exitCode == 0 && complete(result)
    }

    static func complete(_ result: CommandResult) -> Bool {
        !result.timedOut && !result.truncated && result.stderr.isEmpty
    }

    struct TrackedPaths {
        var files: [Data: mode_t] = [Data(".git".utf8): S_IFREG]
        var directories = Set<Data>()

        func permits(_ path: String, mode: mode_t) -> Bool {
            let key = Data(path.utf8)
            let type = mode & S_IFMT
            return type == S_IFDIR ? directories.contains(key) : files[key] == type
        }
    }

    func trackedPaths(_ path: String) -> TrackedPaths? {
        guard let result = command(path, ["ls-files", "-v", "--stage", "-z"]), Self.successful(result),
              result.stdout.isEmpty || result.stdout.last == 0 else { return nil }
        var paths = TrackedPaths()
        for record in result.stdout.split(separator: 0, omittingEmptySubsequences: false).dropLast() {
            let fields = record.split(separator: 9, maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, let header = String(data: fields[0], encoding: .ascii),
                  let name = String(data: fields[1], encoding: .utf8) else { return nil }
            let metadata = header.split(separator: " ")
            // H is an ordinary tracked entry. Lowercase and other states include
            // assume-unchanged, skip-worktree, and unresolved index entries.
            guard metadata.count == 4, metadata[0] == "H", metadata[3] == "0" else { return nil }
            let type: mode_t
            switch metadata[1] {
            case "100644", "100755": type = S_IFREG
            case "120000": type = S_IFLNK
            default: return nil // Submodules and sparse directory entries need separate proof.
            }
            let components = name.split(separator: "/", omittingEmptySubsequences: false)
            guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" }),
                  paths.files.updateValue(type, forKey: Data(fields[1])) == nil else { return nil }
            var parent = ""
            for component in components.dropLast() {
                parent += parent.isEmpty ? String(component) : "/" + component
                paths.directories.insert(Data(parent.utf8))
            }
        }
        return paths
    }

    func filterBlocker(_ path: String, tracked: TrackedPaths) -> String? {
        let unavailable = "Could not verify worktree Git filter configuration"
        guard let filters = command(path, ["config", "--includes", "-z", "--name-only", "--get-regexp", "^filter\\."]),
              Self.complete(filters) else { return unavailable }
        if filters.exitCode == 1 && filters.stdout.isEmpty { return nil }
        guard filters.exitCode == 0, filters.stdout.last == 0 else { return unavailable }
        var drivers = Set<Data>()
        for key in filters.stdout.split(separator: 0) {
            let name = key.dropFirst(7)
            guard let delimiter = name.lastIndex(of: 46), delimiter > name.startIndex else { return unavailable }
            drivers.insert(Data(name[..<delimiter]))
        }

        // A globally installed driver is common. Only reject a worktree
        // when a tracked path actually uses one of the configured drivers.
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        var arguments: [String] = []
        var argumentBytes = 0
        func checkBatch() -> String? {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0,
                  let result = command(path, ["check-attr", "--all", "-z", "--"] + arguments, timeout: remaining),
                  Self.successful(result) else { return unavailable }
            if result.stdout.isEmpty { return nil }
            let fields = result.stdout.split(separator: 0, omittingEmptySubsequences: false).dropLast()
            guard result.stdout.last == 0, fields.count.isMultiple(of: 3) else { return unavailable }
            let filterName = Data("filter".utf8)
            for index in stride(from: 0, to: fields.count, by: 3) {
                if fields[index + 1] == filterName, drivers.contains(Data(fields[index + 2])) {
                    return "Worktree uses configured Git filters that cannot be verified safely"
                }
            }
            return nil
        }

        for name in tracked.files.keys where name != Data(".git".utf8) {
            let byteCount = name.count + 1
            guard byteCount <= 64 * 1024 else { return unavailable }
            if argumentBytes + byteCount > 64 * 1024 || arguments.count == 1_024 {
                if let blocker = checkBatch() { return blocker }
                arguments.removeAll(keepingCapacity: true)
                argumentBytes = 0
            }
            arguments.append(String(decoding: name, as: UTF8.self))
            argumentBytes += byteCount
        }
        return arguments.isEmpty ? nil : checkBatch()
    }

    func statusBlocker(_ path: String, head: String?, branch: String?) -> String? {
        guard let head, let status = command(path, ["status", "--porcelain=v2", "--branch", "-z",
            "--no-ahead-behind", "--untracked-files=all", "--ignored=traditional"]),
              Self.successful(status), status.stdout.last == 0 else {
            return "Could not verify worktree status"
        }
        let records = status.stdout.split(separator: 0)
        let branchName = branch.map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst(11)) : $0 } ?? "(detached)"
        guard records.first == Data("# branch.oid \(head)".utf8),
              records.dropFirst().first == Data("# branch.head \(branchName)".utf8) else {
            return "Worktree branch or commit changed during verification"
        }
        let changes = records.dropFirst(2).drop(while: {
            $0.starts(with: Data("# branch.upstream ".utf8)) || $0.starts(with: Data("# branch.ab ".utf8))
        })
        guard let first = changes.first else { return nil }
        // Whole-worktree Trash only permits versioned contents. Ignored paths
        // can hold unique local data and have no blanket disposable exemption.
        if first.starts(with: [33, 32]) { return "Worktree contains ignored local files" }
        return "Worktree has uncommitted changes"
    }
}
