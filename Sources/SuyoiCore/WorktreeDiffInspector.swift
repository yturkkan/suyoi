import Foundation

public struct WorktreeDiffSummary: Codable, Equatable, Sendable {
    public let projectPath: String
    public let changedFiles: Int
    public let untrackedFiles: Int
    public let addedLines: Int
    public let deletedLines: Int
    public let sampleFiles: [String]

    public var isClean: Bool {
        changedFiles == 0 && untrackedFiles == 0 && addedLines == 0 && deletedLines == 0
    }

    public var totalTouchedFiles: Int {
        changedFiles + untrackedFiles
    }

    public init(
        projectPath: String,
        changedFiles: Int,
        untrackedFiles: Int,
        addedLines: Int,
        deletedLines: Int,
        sampleFiles: [String]
    ) {
        self.projectPath = projectPath
        self.changedFiles = changedFiles
        self.untrackedFiles = untrackedFiles
        self.addedLines = addedLines
        self.deletedLines = deletedLines
        self.sampleFiles = sampleFiles
    }
}

/// Inspects live uncommitted Git diff statistics without writing lock files or invoking repository hooks.
public struct WorktreeDiffInspector: Sendable {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = CommandRunner()) {
        self.runner = runner
    }

    public func inspectActiveProjects(for agents: [AgentObservation], maxProjects: Int = 8) -> [String: WorktreeDiffSummary] {
        var seen: Set<String> = []
        var orderedPaths: [String] = []
        for agent in agents where !agent.process.isStopped {
            guard let rawPath = agent.project?.rootPath ?? agent.process.cwd,
                  rawPath.hasPrefix("/"), rawPath != "/" else { continue }
            let canonical = URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().standardizedFileURL.path
            if seen.insert(canonical).inserted {
                orderedPaths.append(canonical)
                if orderedPaths.count >= maxProjects { break }
            }
        }
        guard !orderedPaths.isEmpty else { return [:] }
        let readOnlyGit = ReadOnlyWorktreeGit(runner: runner)
        var results: [String: WorktreeDiffSummary] = [:]
        for path in orderedPaths {
            if let summary = inspect(projectPath: path, readOnlyGit: readOnlyGit) {
                results[path] = summary
            }
        }
        return results
    }

    public func inspect(projectPath: String) -> WorktreeDiffSummary? {
        inspect(projectPath: projectPath, readOnlyGit: ReadOnlyWorktreeGit(runner: runner))
    }

    private func inspect(projectPath: String, readOnlyGit: ReadOnlyWorktreeGit?) -> WorktreeDiffSummary? {
        guard projectPath.hasPrefix("/"), projectPath != "/", let git = readOnlyGit else {
            return nil
        }
        guard let statusResult = git.command(
            projectPath,
            ["status", "--porcelain=v2", "-z", "--untracked-files=all"],
            timeout: 2.5
        ), statusResult.exitCode == 0, !statusResult.timedOut, !statusResult.truncated else {
            return nil
        }

        let statusParsed = Self.parsePorcelainV2ZeroTerminated(statusResult.stdout)
        var added = 0
        var deleted = 0

        if statusParsed.changedCount > 0 {
            if let diffResult = git.command(projectPath, ["diff", "--numstat", "HEAD", "-z"], timeout: 2.5),
               diffResult.exitCode == 0, !diffResult.timedOut, !diffResult.truncated {
                let stats = Self.parseNumstatZeroTerminated(diffResult.stdout)
                added = stats.added
                deleted = stats.deleted
            } else if let unstagedResult = git.command(projectPath, ["diff", "--numstat", "-z"], timeout: 2.5),
                      unstagedResult.exitCode == 0, !unstagedResult.timedOut, !unstagedResult.truncated {
                let stats = Self.parseNumstatZeroTerminated(unstagedResult.stdout)
                added = stats.added
                deleted = stats.deleted
            }
        }

        return WorktreeDiffSummary(
            projectPath: projectPath,
            changedFiles: statusParsed.changedCount,
            untrackedFiles: statusParsed.untrackedCount,
            addedLines: added,
            deletedLines: deleted,
            sampleFiles: statusParsed.sampleFiles
        )
    }

    static func parsePorcelainV2ZeroTerminated(_ data: Data) -> (changedCount: Int, untrackedCount: Int, sampleFiles: [String]) {
        guard !data.isEmpty else { return (0, 0, []) }
        let records = data.split(separator: 0, omittingEmptySubsequences: true)
        var changed = 0
        var untracked = 0
        var samples: [String] = []
        var index = 0
        while index < records.count {
            let record = records[index]
            guard let first = record.first else {
                index += 1
                continue
            }
            // '1' ordinary changed, '2' rename/copy (followed by origPath NUL record), 'u' unmerged, '?' untracked
            if first == 49 || first == 117 { // '1' or 'u'
                changed += 1
                if samples.count < 5, let path = extractTrailingPath(from: record) {
                    samples.append(path)
                }
                index += 1
            } else if first == 50 { // '2' rename/copy has an extra NUL-terminated original path
                changed += 1
                if samples.count < 5, let path = extractTrailingPath(from: record) {
                    samples.append(path)
                }
                index += 2
            } else if first == 63 { // '?'
                untracked += 1
                if samples.count < 5, record.count > 2,
                   let raw = String(data: record.dropFirst(2), encoding: .utf8) {
                    let clean = sanitizeDisplayPath(raw)
                    if !clean.isEmpty { samples.append(clean) }
                }
                index += 1
            } else {
                index += 1
            }
        }
        return (changed, untracked, samples)
    }

    static func parseNumstatZeroTerminated(_ data: Data) -> (added: Int, deleted: Int) {
        guard !data.isEmpty else { return (0, 0) }
        let records = data.split(separator: 0, omittingEmptySubsequences: true)
        var totalAdded = 0
        var totalDeleted = 0
        var index = 0
        while index < records.count {
            let record = records[index]
            guard let text = String(data: record, encoding: .utf8) else {
                index += 1
                continue
            }
            let parts = text.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else {
                index += 1
                continue
            }
            if let a = Int(parts[0]), a > 0 { totalAdded += a }
            if let d = Int(parts[1]), d > 0 { totalDeleted += d }
            // In `-z` mode, renames have an empty third field followed by two NUL-separated path records.
            if parts[2].isEmpty {
                index += 3
            } else {
                index += 1
            }
        }
        return (totalAdded, totalDeleted)
    }

    private static func extractTrailingPath(from record: Data.SubSequence) -> String? {
        guard let text = String(data: record, encoding: .utf8) else { return nil }
        // Porcelain v2 '1' has 8 space-separated header fields before path; '2' has 9; 'u' has 10.
        let spaceCount: Int
        if text.hasPrefix("1 ") {
            spaceCount = 8
        } else if text.hasPrefix("2 ") {
            spaceCount = 9
        } else if text.hasPrefix("u ") {
            spaceCount = 10
        } else {
            return nil
        }
        var seenSpaces = 0
        var cursor = text.startIndex
        while cursor < text.endIndex && seenSpaces < spaceCount {
            if text[cursor] == " " {
                seenSpaces += 1
            }
            cursor = text.index(after: cursor)
        }
        guard seenSpaces == spaceCount, cursor < text.endIndex else { return nil }
        let clean = sanitizeDisplayPath(String(text[cursor...]))
        return clean.isEmpty ? nil : clean
    }

    private static func sanitizeDisplayPath(_ raw: String) -> String {
        let filtered = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(filtered.prefix(120))
    }
}
