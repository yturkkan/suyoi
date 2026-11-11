import Darwin
import Foundation

public struct WorktreeCollisionGroup: Equatable, Identifiable, Sendable {
    public var id: String { projectPath }
    public let projectPath: String
    public let projectName: String
    public let gitBranch: String?
    public let agentIDs: [Int]
    public let agentNames: [String]
    public let activeCount: Int

    public init(
        projectPath: String,
        projectName: String,
        gitBranch: String?,
        agentIDs: [Int],
        agentNames: [String],
        activeCount: Int
    ) {
        self.projectPath = projectPath
        self.projectName = projectName
        self.gitBranch = gitBranch
        self.agentIDs = agentIDs
        self.agentNames = agentNames
        self.activeCount = activeCount
    }
}

public struct WorktreeCreationOutcome: Equatable, Sendable {
    public let succeeded: Bool
    public let worktreePath: String?
    public let branchName: String?
    public let error: String?

    public init(succeeded: Bool, worktreePath: String? = nil, branchName: String? = nil, error: String? = nil) {
        self.succeeded = succeeded
        self.worktreePath = worktreePath
        self.branchName = branchName
        self.error = error
    }
}

public enum AgentCollisionDetector {
    public static func canonicalProjectPath(for agent: AgentObservation) -> String? {
        let raw = agent.project?.rootPath ?? agent.process.cwd
        guard let raw, raw.hasPrefix("/"), raw != "/" else { return nil }
        return URL(fileURLWithPath: raw).resolvingSymlinksInPath().standardizedFileURL.path
    }

    public static func detectCollisions(in agents: [AgentObservation]) -> [WorktreeCollisionGroup] {
        var buckets: [String: [AgentObservation]] = [:]
        var order: [String] = []
        for agent in agents where !agent.process.isStopped && agent.activityState != .stopped {
            guard let path = canonicalProjectPath(for: agent) else { continue }
            if buckets[path] == nil {
                order.append(path)
            }
            buckets[path, default: []].append(agent)
        }

        var groups: [WorktreeCollisionGroup] = []
        for path in order {
            guard let members = buckets[path], members.count >= 2 else { continue }
            let firstProject = members.compactMap(\.project).first
            let name = firstProject?.name ?? URL(fileURLWithPath: path).lastPathComponent
            let branch = firstProject?.gitBranch
            let activeCount = members.filter { $0.activityState == .active }.count
            groups.append(
                WorktreeCollisionGroup(
                    projectPath: path,
                    projectName: name,
                    gitBranch: branch,
                    agentIDs: members.map(\.id),
                    agentNames: members.map(\.agentName),
                    activeCount: activeCount
                )
            )
        }
        return groups
    }

    public static func sanitizeBranchSlug(_ raw: String) -> String? {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var chars: [Character] = []
        var prevHyphen = false
        for scalar in lowered.unicodeScalars {
            let v = scalar.value
            if (97...122).contains(v) || (48...57).contains(v) {
                chars.append(Character(scalar))
                prevHyphen = false
            } else if v == 45 || v == 95 || v == 32 || v == 47 {
                if !chars.isEmpty && !prevHyphen {
                    chars.append("-")
                    prevHyphen = true
                }
            }
        }
        while chars.last == "-" { chars.removeLast() }
        let slug = String(chars.prefix(36))
        return slug.isEmpty ? nil : slug
    }

    public static func createIsolatedWorktree(
        from repoPath: String,
        branchSlug: String,
        runner: any CommandRunning = CommandRunner()
    ) -> WorktreeCreationOutcome {
        guard repoPath.hasPrefix("/"), repoPath != "/" else {
            return WorktreeCreationOutcome(succeeded: false, error: "Repository path must be an absolute project directory")
        }
        guard let cleanSlug = sanitizeBranchSlug(branchSlug) else {
            return WorktreeCreationOutcome(succeeded: false, error: "Worktree name must contain letters or digits")
        }
        let repoURL = URL(fileURLWithPath: repoPath).standardizedFileURL
        guard repoURL.resolvingSymlinksInPath().path == repoURL.path else {
            return WorktreeCreationOutcome(succeeded: false, error: "Repository path contains symlinks and cannot be branched safely")
        }
        var repoStat = stat()
        guard lstat(repoURL.path, &repoStat) == 0, (repoStat.st_mode & S_IFMT) == S_IFDIR else {
            return WorktreeCreationOutcome(succeeded: false, error: "Repository directory does not exist")
        }
        let parentURL = repoURL.deletingLastPathComponent()
        guard parentURL.path.hasPrefix("/"), parentURL.path != "/" else {
            return WorktreeCreationOutcome(succeeded: false, error: "Cannot create sibling worktree at filesystem root")
        }
        let repoName = repoURL.lastPathComponent
        let destinationURL = parentURL.appendingPathComponent("\(repoName)-\(cleanSlug)", isDirectory: true)
        var destStat = stat()
        guard lstat(destinationURL.path, &destStat) != 0 && errno == ENOENT else {
            return WorktreeCreationOutcome(
                succeeded: false,
                error: "Target directory \(destinationURL.lastPathComponent) already exists"
            )
        }

        let branchName = "suyoi/\(cleanSlug)"
        let request = CommandRequest(
            executable: "/usr/bin/git",
            arguments: ["-C", repoURL.path, "worktree", "add", "-b", branchName, destinationURL.path],
            environment: [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "LC_ALL": "C",
                "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                "GIT_TERMINAL_PROMPT": "0"
            ],
            timeout: 10,
            maximumOutputBytes: 16 * 1_024,
            workingDirectory: parentURL
        )
        do {
            let result = try runner.run(request)
            guard result.exitCode == 0, !result.timedOut else {
                return WorktreeCreationOutcome(
                    succeeded: false,
                    error: result.timedOut ? "git worktree add timed out" : "git could not create isolated worktree (branch may already exist)"
                )
            }
            return WorktreeCreationOutcome(
                succeeded: true,
                worktreePath: destinationURL.path,
                branchName: branchName
            )
        } catch {
            return WorktreeCreationOutcome(succeeded: false, error: "Unable to execute git worktree command")
        }
    }
}
