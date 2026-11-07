import Foundation

public struct NodeModulesSafety: Sendable {
    public init() {}

    public func assess(candidate: CleanupCandidate, processes: Observation<[ObservedProcess]>) -> SafetyAssessment {
        let url = URL(fileURLWithPath: candidate.path).standardizedFileURL
        let parentRoot = Self.projectRoot(for: url)
        let recognizedRoot = Self.recognizedProjectRoot(from: parentRoot)
        let root = recognizedRoot ?? parentRoot
        let regenerability: Regenerability
        if url.lastPathComponent == "node_modules" {
            regenerability = Self.verifyRegenerability(nodeModulesURL: url)
        } else if Self.generatedFolders.contains(url.lastPathComponent)
                    || (url.lastPathComponent == "cache" && url.deletingLastPathComponent().lastPathComponent == ".next") {
            regenerability = recognizedRoot != nil ? .cacheDirectory : .unverified("Unrecognized project root")
        } else {
            regenerability = .unverified("Unknown project artifact")
        }
        let (usage, usageReasons) = Self.workingDirectoryUsage(root: url, processes: processes, projectRoot: root)
        var reasons = usageReasons
        if case .unverified(let reason) = regenerability {
            reasons.append(reason == "Missing package.json" ? "Missing package.json in project root" : reason)
        }
        let verified: Bool
        switch regenerability { case .cacheDirectory, .lockfileVerified: verified = true; case .unverified: verified = false }
        return SafetyAssessment(candidateID: candidate.id, usage: usage, regenerability: regenerability, blockedReasons: reasons,
                                isReviewableForTrash: reasons.isEmpty && usage == .clear && verified && !candidate.partial && candidate.fileIdentity != nil)
    }

    public static func verifyRegenerability(nodeModulesURL: URL) -> Regenerability {
        let root = nodeModulesURL.deletingLastPathComponent()
        guard isRegularFile(root.appendingPathComponent("package.json")) else { return .unverified("Missing package.json") }
        let locks = ["package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb", "bun.lock", "npm-shrinkwrap.json"]
        guard let lock = locks.first(where: { isRegularFile(root.appendingPathComponent($0)) }) else { return .unverified("No lockfile") }
        return .lockfileVerified(lock)
    }

    public static func verifyProjectRegenerability(for candidate: CleanupCandidate, rootURL: URL) -> Regenerability {
        let url = URL(fileURLWithPath: candidate.path).standardizedFileURL
        guard candidate.scope == .projectArtifact, url.lastPathComponent == "node_modules",
              rootURL.standardizedFileURL == url.deletingLastPathComponent() else {
            return .unverified("Unknown dependency installation")
        }
        return verifyRegenerability(nodeModulesURL: url)
    }

    private static let generatedFolders: Set<String> = [
        ".build", ".next", "target", "dist", ".turbo", ".vite", ".parcel-cache", ".svelte-kit", ".nuxt", ".astro",
        ".pytest_cache", ".ruff_cache", ".mypy_cache", "__pycache__", ".venv", "venv"
    ]

    private static func isRecognizedProject(_ root: URL) -> Bool {
        ["package.json", "Package.swift", "Cargo.toml", "pyproject.toml", "go.mod", "setup.py", "requirements.txt"].contains {
            isRegularFile(root.appendingPathComponent($0))
        } || (FileMetadataReader().identity(at: root.appendingPathComponent(".git")) != nil)
    }

    private static func recognizedProjectRoot(from directory: URL) -> URL? {
        var current = directory
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath()
        for _ in 0..<8 {
            guard current.path != "/", current != home else { break }
            if isRecognizedProject(current) { return current }
            current.deleteLastPathComponent()
        }
        return nil
    }

    static func projectRoot(for url: URL) -> URL {
        let parent = url.deletingLastPathComponent()
        return url.lastPathComponent == "cache" && parent.lastPathComponent == ".next" ? parent.deletingLastPathComponent() : parent
    }

    static func contains(_ path: String, in root: String) -> Bool {
        let value = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        let base = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
        return value == base || value.hasPrefix(base == "/" ? "/" : base + "/")
    }

    static func workingDirectoryUsage(root: URL, processes: Observation<[ObservedProcess]>, projectRoot: URL? = nil) -> (UsageState, [String]) {
        guard processes.status != .unavailable else { return (.unknown, ["Process observation is unavailable"]) }
        let byPID = ProcessTree(processes: processes.value).processesByPID
        if let active = processes.value.first(where: { process in
            if let cwd = process.cwd {
                if contains(cwd, in: root.path) { return true }
                if let projectRoot, contains(cwd, in: projectRoot.path) { return true }
            }
            guard let projectRoot, AgentRecognizer.isAgent(process),
                  let cwd = AgentRecognizer.workingDirectory(for: process, processesByPID: byPID) else { return false }
            return contains(cwd, in: projectRoot.path)
        }) {
            return (.inUse, ["Project is in use by \(active.name) (PID \(active.pid))"])
        }
        return (.clear, [])
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        let reader = FileMetadataReader()
        return reader.canonicalPath(url, relativeTo: url.deletingLastPathComponent()) != nil
            && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
}
