import Darwin
import Foundation

public enum StorageCategory: String, Codable, CaseIterable, Equatable, Sendable {
    case xcodeAndSimulators = "Xcode & Simulators"
    case dependencies = "Dependencies"
    case buildOutputs = "Build Outputs"
    case pythonAndEnvs = "Python & Virtual Envs"
    case toolchainCaches = "Toolchain Caches"
    case aiAgentStorage = "AI Agent Caches"

    public var shortTitle: String {
        switch self {
        case .xcodeAndSimulators: return "Xcode"
        case .dependencies: return "Packages"
        case .buildOutputs: return "Builds"
        case .pythonAndEnvs: return "Python"
        case .toolchainCaches: return "Toolchains"
        case .aiAgentStorage: return "AI Caches"
        }
    }

    public var symbolName: String {
        switch self {
        case .xcodeAndSimulators: return "hammer.circle.fill"
        case .dependencies: return "shippingbox.fill"
        case .buildOutputs: return "gearshape.2.fill"
        case .pythonAndEnvs: return "terminal.fill"
        case .toolchainCaches: return "wrench.and.screwdriver.fill"
        case .aiAgentStorage: return "sparkles.rectangle.stack.fill"
        }
    }
}

public enum StorageItemSafety: Codable, Equatable, Sendable {
    /// Safe to clean immediately; included in "Select Recommended".
    case ready
    /// Cleanable by user (e.g. `.venv`, iOS DeviceSupport, HuggingFace models), excluded from blind 1-click auto-selection.
    case highImpactReview(reason: String)
    /// Protected because a live process is currently executing inside this workspace or using this cache.
    case inUse(processSummary: String)

    public var isCleanable: Bool {
        switch self {
        case .ready, .highImpactReview:
            return true
        case .inUse:
            return false
        }
    }

    public var isRecommendedDefault: Bool {
        if case .ready = self { return true }
        return false
    }
}

public struct IndexedStorageItem: Identifiable, Codable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let displayName: String
    public let subtitle: String
    public let projectName: String?
    public let projectRootPath: String?
    public let category: StorageCategory
    public let ecosystemLabel: String
    public let bytes: Int64
    public let allocatedBytes: Int64
    public let fileCount: Int
    public let lastModifiedAt: Date?
    public let fileIdentity: FileIdentity
    public var safety: StorageItemSafety

    public init(
        path: String,
        displayName: String,
        subtitle: String,
        projectName: String? = nil,
        projectRootPath: String? = nil,
        category: StorageCategory,
        ecosystemLabel: String,
        bytes: Int64,
        allocatedBytes: Int64,
        fileCount: Int,
        lastModifiedAt: Date?,
        fileIdentity: FileIdentity,
        safety: StorageItemSafety
    ) {
        self.path = path
        self.displayName = displayName
        self.subtitle = subtitle
        self.projectName = projectName
        self.projectRootPath = projectRootPath
        self.category = category
        self.ecosystemLabel = ecosystemLabel
        self.bytes = bytes
        self.allocatedBytes = allocatedBytes
        self.fileCount = fileCount
        self.lastModifiedAt = lastModifiedAt
        self.fileIdentity = fileIdentity
        self.safety = safety
    }

    public var effectiveBytes: Int64 {
        max(bytes, allocatedBytes > 0 ? min(allocatedBytes, bytes * 2 + 65_536) : bytes)
    }

    public func ageDays(from reference: Date = Date()) -> Int? {
        guard let lastModifiedAt else { return nil }
        let seconds = max(0, reference.timeIntervalSince(lastModifiedAt))
        return Int(seconds / 86_400)
    }
}

public struct StorageIndexProgress: Equatable, Sendable {
    public let isIndexing: Bool
    public let phase: String
    public let currentPath: String
    public let scannedDirectories: Int
    public let discoveredCount: Int
    public let totalBytes: Int64
    public let readyBytes: Int64
    public let fractionCompleted: Double

    public init(
        isIndexing: Bool,
        phase: String,
        currentPath: String,
        scannedDirectories: Int,
        discoveredCount: Int,
        totalBytes: Int64,
        readyBytes: Int64,
        fractionCompleted: Double
    ) {
        self.isIndexing = isIndexing
        self.phase = phase
        self.currentPath = currentPath
        self.scannedDirectories = scannedDirectories
        self.discoveredCount = discoveredCount
        self.totalBytes = totalBytes
        self.readyBytes = readyBytes
        self.fractionCompleted = min(max(fractionCompleted, 0), 1)
    }

    public static let idle = StorageIndexProgress(
        isIndexing: false,
        phase: "Idle",
        currentPath: "",
        scannedDirectories: 0,
        discoveredCount: 0,
        totalBytes: 0,
        readyBytes: 0,
        fractionCompleted: 0
    )
}

public struct StorageIndexReport: Codable, Equatable, Sendable {
    public let items: [IndexedStorageItem]
    public let scannedRoots: [String]
    public let scannedDirectories: Int
    public let indexedAt: Date

    public init(
        items: [IndexedStorageItem],
        scannedRoots: [String],
        scannedDirectories: Int,
        indexedAt: Date
    ) {
        self.items = items
        self.scannedRoots = scannedRoots
        self.scannedDirectories = scannedDirectories
        self.indexedAt = indexedAt
    }

    public var totalBytes: Int64 {
        items.reduce(0) { $0 + $1.bytes }
    }

    public var readyBytes: Int64 {
        items.filter { $0.safety.isRecommendedDefault }.reduce(0) { $0 + $1.bytes }
    }

    public var cleanableBytes: Int64 {
        items.filter { $0.safety.isCleanable }.reduce(0) { $0 + $1.bytes }
    }

    public func bytes(for category: StorageCategory) -> Int64 {
        items.filter { $0.category == category }.reduce(0) { $0 + $1.bytes }
    }
}

/// High-speed, symlink-safe deep storage indexer for developer workspaces, monorepos,
/// Xcode DerivedData/Simulators, package manager stores, and AI coding agent caches.
public struct DeepStorageIndexer: Sendable {
    public static let defaultWorkspaceFolderNames: [String] = [
        "Developer",
        "Projects",
        "Code",
        "repos",
        "workspace",
        "Workspaces",
        "GitHub",
        "Documents/GitHub",
        "Documents/Projects",
        "src",
        "dev",
        "work",
        "Sites",
        "Apps",
        "Desktop"
    ]

    private let homeDirectory: URL
    private let maxWorkspaceDepth: Int
    private let minimumBytes: Int64
    private let trashHandler: @Sendable (URL) throws -> URL?

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        maxWorkspaceDepth: Int = 8,
        minimumBytes: Int64 = 4_096,
        trashHandler: @escaping @Sendable (URL) throws -> URL? = { url in
            var resulting: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            return resulting as URL?
        }
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL.resolvingSymlinksInPath()
        self.maxWorkspaceDepth = max(2, min(maxWorkspaceDepth, 14))
        self.minimumBytes = max(1, minimumBytes)
        self.trashHandler = trashHandler
    }

    // MARK: - Default Root Discovery & Disk Cache

    public static func discoverWorkspaceRoots(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        primaryRoot: URL? = nil,
        customRoots: [URL] = [],
        includeAutoDetected: Bool = true
    ) -> [URL] {
        let home = homeDirectory.standardizedFileURL.resolvingSymlinksInPath()
        var candidates: [URL] = []
        if let primaryRoot {
            candidates.append(primaryRoot.standardizedFileURL.resolvingSymlinksInPath())
        }
        candidates.append(contentsOf: customRoots.map { $0.standardizedFileURL.resolvingSymlinksInPath() })
        if includeAutoDetected {
            for rel in defaultWorkspaceFolderNames {
                candidates.append(home.appendingPathComponent(rel, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath())
            }
        }

        var accepted: [URL] = []
        for url in candidates {
            let path = url.path
            guard path.hasPrefix("/"), path != "/", path != home.path else { continue }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
            if accepted.contains(where: { path == $0.path || path.hasPrefix($0.path + "/") }) {
                continue
            }
            accepted.removeAll { $0.path.hasPrefix(path + "/") }
            accepted.append(url)
        }
        return accepted
    }

    public static func cacheFileURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory
            .standardizedFileURL
            .appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent(SuyoiAppIdentity.supportFolderName, isDirectory: true)
            .appendingPathComponent("storage-index-v2.json")
    }

    public static func loadCachedReport(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> StorageIndexReport? {
        let url = cacheFileURL(homeDirectory: homeDirectory)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let report = try? decoder.decode(StorageIndexReport.self, from: data) else { return nil }
        // Filter out items already deleted from disk since the cached snapshot.
        let stillExisting = report.items.filter { FileManager.default.fileExists(atPath: $0.path) }
        return StorageIndexReport(
            items: stillExisting,
            scannedRoots: report.scannedRoots,
            scannedDirectories: report.scannedDirectories,
            indexedAt: report.indexedAt
        )
    }

    public static func saveCachedReport(_ report: StorageIndexReport, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let url = cacheFileURL(homeDirectory: homeDirectory)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(report) else { return }
        try? data.write(to: url, options: .atomic)
        chmod(url.path, S_IRUSR | S_IWUSR)
    }

    // MARK: - Full Deep Indexing

    public func indexAll(
        workspaceRoots: [URL],
        includeSystemAndAgentCaches: Bool = true,
        liveProcesses: [ObservedProcess] = [],
        isCancelled: (@Sendable () -> Bool)? = nil,
        onProgress: (@Sendable (StorageIndexProgress) -> Void)? = nil
    ) -> StorageIndexReport {
        var discovered: [IndexedStorageItem] = []
        var seenPaths = Set<String>()
        var scannedDirs = 0
        var totalBytes: Int64 = 0
        var readyBytes: Int64 = 0
        var lastEmitUptime: TimeInterval = 0

        let dedupedRoots = Self.discoverWorkspaceRoots(
            homeDirectory: homeDirectory,
            primaryRoot: nil,
            customRoots: workspaceRoots,
            includeAutoDetected: false
        )

        let totalStages = Double(max(1, dedupedRoots.count + (includeSystemAndAgentCaches ? 2 : 0)))
        var completedStages = 0.0

        func emit(phase: String, currentPath: String, force: Bool = false) {
            guard let onProgress else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard force || (now - lastEmitUptime) >= 0.12 else { return }
            lastEmitUptime = now
            onProgress(
                StorageIndexProgress(
                    isIndexing: true,
                    phase: phase,
                    currentPath: shortenForProgress(currentPath),
                    scannedDirectories: scannedDirs,
                    discoveredCount: discovered.count,
                    totalBytes: totalBytes,
                    readyBytes: readyBytes,
                    fractionCompleted: min(0.98, completedStages / totalStages)
                )
            )
        }

        func appendItem(_ item: IndexedStorageItem) {
            guard item.bytes >= minimumBytes || item.allocatedBytes >= minimumBytes else { return }
            let normalized = URL(fileURLWithPath: item.path).standardizedFileURL.path
            guard seenPaths.insert(normalized).inserted else { return }
            discovered.append(item)
            totalBytes += item.bytes
            if item.safety.isRecommendedDefault {
                readyBytes += item.bytes
            }
        }

        // 1. Scan Xcode, Simulators, Toolchains, and AI Agent Caches first (usually huge & fast to locate)
        if includeSystemAndAgentCaches && isCancelled?() != true {
            emit(phase: "Indexing Xcode, Simulators & Toolchain Caches", currentPath: "~/Library/Developer", force: true)
            let cacheTargets = collectSystemAndAgentCacheTargets()
            for (idx, target) in cacheTargets.enumerated() {
                if isCancelled?() == true { break }
                scannedDirs += 1
                emit(phase: "Indexing \(target.category.rawValue)", currentPath: target.url.path)
                if let built = measureAndBuildCacheItem(target, liveProcesses: liveProcesses) {
                    appendItem(built)
                }
                completedStages = min(2.0, Double(idx + 1) / Double(max(1, cacheTargets.count)) * 2.0)
            }
            completedStages = 2.0
        }

        // 2. Deep recursive scan of all workspace & monorepo roots
        for (rootIdx, rootURL) in dedupedRoots.enumerated() {
            if isCancelled?() == true { break }
            emit(phase: "Scanning Workspace \(rootURL.lastPathComponent)", currentPath: rootURL.path, force: true)
            scanWorkspaceTree(
                root: rootURL,
                liveProcesses: liveProcesses,
                isCancelled: isCancelled,
                onDirectoryVisited: { dirPath in
                    scannedDirs += 1
                    emit(phase: "Scanning \(rootURL.lastPathComponent)", currentPath: dirPath)
                },
                onItemFound: { item in
                    appendItem(item)
                    emit(phase: "Indexed \(item.displayName)", currentPath: item.path)
                }
            )
            completedStages = (includeSystemAndAgentCaches ? 2.0 : 0.0) + Double(rootIdx + 1)
        }

        let sortedItems = discovered.sorted { lhs, rhs in
            if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
            return lhs.path < rhs.path
        }

        let report = StorageIndexReport(
            items: sortedItems,
            scannedRoots: dedupedRoots.map(\.path),
            scannedDirectories: scannedDirs,
            indexedAt: Date()
        )

        onProgress?(
            StorageIndexProgress(
                isIndexing: false,
                phase: "Complete",
                currentPath: "",
                scannedDirectories: scannedDirs,
                discoveredCount: sortedItems.count,
                totalBytes: report.totalBytes,
                readyBytes: report.readyBytes,
                fractionCompleted: 1.0
            )
        )
        return report
    }

    /// Re-evaluates live process `inUse` states without rescanning disk sizes.
    public func refreshSafetyStates(in report: StorageIndexReport, liveProcesses: [ObservedProcess]) -> StorageIndexReport {
        let updated = report.items.map { item -> IndexedStorageItem in
            var copy = item
            copy.safety = evaluateSafety(
                path: item.path,
                projectRootPath: item.projectRootPath,
                category: item.category,
                ecosystemLabel: item.ecosystemLabel,
                isBaseHighImpact: isInherentlyHighImpact(path: item.path, ecosystemLabel: item.ecosystemLabel),
                liveProcesses: liveProcesses
            )
            return copy
        }
        return StorageIndexReport(
            items: updated,
            scannedRoots: report.scannedRoots,
            scannedDirectories: report.scannedDirectories,
            indexedAt: report.indexedAt
        )
    }

    // MARK: - Safe macOS Trash Execution with Put Back Evidence

    public func moveItemsToTrash(
        _ items: [IndexedStorageItem],
        liveProcesses: [ObservedProcess]
    ) -> TrashExecutionReport {
        let ordered = items.sorted {
            let aCount = URL(fileURLWithPath: $0.path).standardizedFileURL.pathComponents.count
            let bCount = URL(fileURLWithPath: $1.path).standardizedFileURL.pathComponents.count
            return aCount != bCount ? aCount < bCount : $0.path < $1.path
        }

        var trashedAncestors: [String] = []
        var outcomes: [TrashItemOutcome] = []
        var reclaimedBytes: Int64 = 0

        for item in ordered {
            let url = URL(fileURLWithPath: item.path).standardizedFileURL
            func fail(_ message: String) -> TrashItemOutcome {
                TrashItemOutcome(candidateID: item.id, path: item.path, bytes: 0, succeeded: false, error: message)
            }

            if trashedAncestors.contains(where: { url.path == $0 || url.path.hasPrefix($0 + "/") }) {
                continue
            }

            guard !isProtectedPath(url) else {
                outcomes.append(fail("Protected system, Git, or credential directory cannot be moved to Trash"))
                continue
            }

            guard hasNoSymlinkInTargetOrAncestors(url),
                  let currentIdentity = readDirectoryOrFileIdentity(at: url),
                  currentIdentity == item.fileIdentity else {
                outcomes.append(fail("Directory changed on disk or contains a symlink in its path; rescan first"))
                continue
            }

            let freshSafety = evaluateSafety(
                path: url.path,
                projectRootPath: item.projectRootPath,
                category: item.category,
                ecosystemLabel: item.ecosystemLabel,
                isBaseHighImpact: false,
                liveProcesses: liveProcesses
            )
            if case .inUse(let summary) = freshSafety {
                outcomes.append(fail("Currently in use (\(summary))"))
                continue
            }

            let recoveryPrep = TrashRecoveryEvidence.prepare(original: url, expectedIdentity: item.fileIdentity)

            do {
                let resultingURL = try trashHandler(url)
                trashedAncestors.append(url.path)
                let bytes = max(0, item.bytes)
                reclaimedBytes = reclaimedBytes > Int64.max - bytes ? Int64.max : reclaimedBytes + bytes
                outcomes.append(
                    TrashItemOutcome(
                        candidateID: item.id,
                        path: item.path,
                        trashedURL: resultingURL?.path,
                        bytes: bytes,
                        succeeded: true,
                        recovery: recoveryPrep?.completed(at: resultingURL)
                    )
                )
            } catch {
                outcomes.append(fail("macOS Trash failed: \(error.localizedDescription)"))
            }
        }

        return TrashExecutionReport(outcomes: outcomes, reclaimedBytes: reclaimedBytes)
    }

    // MARK: - Workspace Recursive Discovery

    private struct ArtifactMatch {
        let category: StorageCategory
        let ecosystemLabel: String
        let highImpactReason: String?
    }

    private static let skippedTraversalDirectoryNames: Set<String> = [
        ".git", ".hg", ".svn", ".Trash", "Library", "Applications", "Pictures", "Music", "Movies"
    ]

    private func scanWorkspaceTree(
        root: URL,
        liveProcesses: [ObservedProcess],
        isCancelled: (@Sendable () -> Bool)?,
        onDirectoryVisited: (String) -> Void,
        onItemFound: (IndexedStorageItem) -> Void
    ) {
        let rootResolved = root.standardizedFileURL.resolvingSymlinksInPath()
        guard !isProtectedPath(rootResolved) else { return }

        func walk(directory: URL, depth: Int, enclosingProjectRoot: URL?) {
            if isCancelled?() == true || depth > maxWorkspaceDepth { return }
            onDirectoryVisited(directory.path)

            guard let fd = openNoFollowDirectory(directory) else { return }
            guard let stream = fdopendir(fd) else {
                close(fd)
                return
            }
            defer { closedir(stream) }

            var childSubdirs: [String] = []
            var regularFiles = Set<String>()
            var hasGitMarker = false

            while let entry = readdir(stream) {
                let name = withUnsafeBytes(of: &entry.pointee.d_name) { bytes in
                    bytes.baseAddress.flatMap { String(validatingUTF8: $0.assumingMemoryBound(to: CChar.self)) }
                }
                guard let name, name != ".", name != ".." else { continue }
                if name == ".git" {
                    hasGitMarker = true
                    continue
                }
                var st = stat()
                guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                let mode = st.st_mode & S_IFMT
                if mode == S_IFLNK {
                    continue
                } else if mode == S_IFDIR {
                    childSubdirs.append(name)
                } else if mode == S_IFREG {
                    regularFiles.insert(name)
                }
            }

            let isProjectRootHere = hasGitMarker || !regularFiles.isDisjoint(with: Self.projectManifestFilenames)
            let activeProjectRoot = isProjectRootHere ? directory : enclosingProjectRoot

            for subdirName in childSubdirs.sorted() {
                if isCancelled?() == true { return }
                if Self.skippedTraversalDirectoryNames.contains(subdirName) { continue }
                let childURL = directory.appendingPathComponent(subdirName, isDirectory: true)
                if isProtectedPath(childURL) { continue }

                if subdirName == "Carthage" {
                    let carthageBuild = childURL.appendingPathComponent("Build", isDirectory: true)
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: carthageBuild.path, isDirectory: &isDir), isDir.boolValue {
                        if let item = buildWorkspaceArtifactItem(
                            artifactURL: carthageBuild,
                            projectRoot: activeProjectRoot ?? directory,
                            match: ArtifactMatch(category: .dependencies, ecosystemLabel: "Carthage Build", highImpactReason: nil),
                            liveProcesses: liveProcesses
                        ) {
                            onItemFound(item)
                        }
                        continue
                    }
                }

                if let match = classifyArtifactDirectory(
                    name: subdirName,
                    url: childURL,
                    siblingFiles: regularFiles,
                    siblingDirs: Set(childSubdirs)
                ) {
                    let ownerProject = activeProjectRoot ?? directory
                    if let item = buildWorkspaceArtifactItem(
                        artifactURL: childURL,
                        projectRoot: ownerProject,
                        match: match,
                        liveProcesses: liveProcesses
                    ) {
                        onItemFound(item)
                    }
                    // Prune traversal inside matched artifact directories!
                    continue
                }

                if depth < maxWorkspaceDepth {
                    walk(directory: childURL, depth: depth + 1, enclosingProjectRoot: activeProjectRoot)
                }
            }
        }

        walk(directory: rootResolved, depth: 0, enclosingProjectRoot: nil)
    }

    private static let projectManifestFilenames: Set<String> = [
        "package.json", "pnpm-workspace.yaml", "tsconfig.json", "Cargo.toml", "Package.swift",
        "pyproject.toml", "requirements.txt", "Pipfile", "setup.py", "Podfile", "Cartfile",
        "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "pom.xml",
        "go.mod", "pubspec.yaml", "CMakeLists.txt", "Makefile", "nx.json", "turbo.json"
    ]

    private static let jsOrBuildManifestFilenames: Set<String> = [
        "package.json", "tsconfig.json", "vite.config.ts", "vite.config.js", "vite.config.mjs",
        "next.config.js", "next.config.mjs", "next.config.ts", "webpack.config.js", "rollup.config.js",
        "astro.config.mjs", "svelte.config.js", "nuxt.config.ts", "angular.json",
        "build.gradle", "build.gradle.kts", "CMakeLists.txt"
    ]

    private func classifyArtifactDirectory(
        name: String,
        url: URL,
        siblingFiles: Set<String>,
        siblingDirs: Set<String>
    ) -> ArtifactMatch? {
        switch name {
        case "node_modules":
            return ArtifactMatch(category: .dependencies, ecosystemLabel: "Node Packages (node_modules)", highImpactReason: nil)
        case ".pnpm-store":
            return ArtifactMatch(category: .dependencies, ecosystemLabel: "pnpm Store", highImpactReason: nil)
        case "Pods":
            guard siblingFiles.contains("Podfile") || siblingFiles.contains("Podfile.lock") else { return nil }
            return ArtifactMatch(category: .dependencies, ecosystemLabel: "CocoaPods (Pods)", highImpactReason: nil)
        case ".dart_tool":
            guard siblingFiles.contains("pubspec.yaml") else { return nil }
            return ArtifactMatch(category: .dependencies, ecosystemLabel: "Flutter / Dart (.dart_tool)", highImpactReason: nil)

        case ".build":
            guard siblingFiles.contains("Package.swift")
                    || FileManager.default.fileExists(atPath: url.appendingPathComponent("workspace-state.json").path)
                    || FileManager.default.fileExists(atPath: url.appendingPathComponent("checkouts").path) else {
                return nil
            }
            return ArtifactMatch(category: .buildOutputs, ecosystemLabel: "SwiftPM Build (.build)", highImpactReason: nil)

        case "target":
            guard siblingFiles.contains("Cargo.toml") || siblingFiles.contains("pom.xml") else { return nil }
            let label = siblingFiles.contains("Cargo.toml") ? "Rust Cargo Build (target)" : "Maven Build (target)"
            return ArtifactMatch(category: .buildOutputs, ecosystemLabel: label, highImpactReason: nil)

        case ".next":
            return ArtifactMatch(category: .buildOutputs, ecosystemLabel: "Next.js Build (.next)", highImpactReason: nil)
        case ".nuxt":
            return ArtifactMatch(category: .buildOutputs, ecosystemLabel: "Nuxt Build (.nuxt)", highImpactReason: nil)
        case ".output":
            guard siblingFiles.contains("nuxt.config.ts") || siblingFiles.contains("nuxt.config.js") || siblingFiles.contains("package.json") else { return nil }
            return ArtifactMatch(category: .buildOutputs, ecosystemLabel: "Nitro / Nuxt Output (.output)", highImpactReason: nil)
        case ".svelte-kit":
            return ArtifactMatch(category: .buildOutputs, ecosystemLabel: "SvelteKit (.svelte-kit)", highImpactReason: nil)
        case ".astro":
            return ArtifactMatch(category: .buildOutputs, ecosystemLabel: "Astro (.astro)", highImpactReason: nil)
        case ".angular":
            return ArtifactMatch(category: .buildOutputs, ecosystemLabel: "Angular Cache (.angular)", highImpactReason: nil)
        case ".expo":
            return ArtifactMatch(category: .buildOutputs, ecosystemLabel: "Expo Cache (.expo)", highImpactReason: nil)
        case ".vercel":
            guard FileManager.default.fileExists(atPath: url.appendingPathComponent("output").path)
                    || FileManager.default.fileExists(atPath: url.appendingPathComponent("cache").path) else { return nil }
            return ArtifactMatch(category: .buildOutputs, ecosystemLabel: "Vercel Local Output (.vercel)", highImpactReason: nil)
        case ".turbo":
            return ArtifactMatch(category: .buildOutputs, ecosystemLabel: "Turborepo Cache (.turbo)", highImpactReason: nil)
        case ".vite":
            return ArtifactMatch(category: .buildOutputs, ecosystemLabel: "Vite Cache (.vite)", highImpactReason: nil)
        case ".parcel-cache":
            return ArtifactMatch(category: .buildOutputs, ecosystemLabel: "Parcel Cache (.parcel-cache)", highImpactReason: nil)
        case ".gradle":
            return ArtifactMatch(category: .buildOutputs, ecosystemLabel: "Gradle Local Cache (.gradle)", highImpactReason: nil)

        case "dist", "build", "out":
            guard !siblingFiles.isDisjoint(with: Self.jsOrBuildManifestFilenames) else { return nil }
            // Never treat a directory containing its own package.json/Cargo.toml/.git as a generated output dir
            guard !FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path),
                  !FileManager.default.fileExists(atPath: url.appendingPathComponent("src").path) else {
                return nil
            }
            return ArtifactMatch(category: .buildOutputs, ecosystemLabel: "Build Output (\(name))", highImpactReason: nil)

        case ".venv", "venv", ".env-venv":
            guard FileManager.default.fileExists(atPath: url.appendingPathComponent("pyvenv.cfg").path) else { return nil }
            return ArtifactMatch(
                category: .pythonAndEnvs,
                ecosystemLabel: "Python Virtual Env (\(name))",
                highImpactReason: "Recreate with uv venv / python -m venv"
            )
        case "__pycache__":
            return ArtifactMatch(category: .pythonAndEnvs, ecosystemLabel: "Python Bytecode (__pycache__)", highImpactReason: nil)
        case ".pytest_cache":
            return ArtifactMatch(category: .pythonAndEnvs, ecosystemLabel: "Pytest Cache (.pytest_cache)", highImpactReason: nil)
        case ".mypy_cache":
            return ArtifactMatch(category: .pythonAndEnvs, ecosystemLabel: "Mypy Cache (.mypy_cache)", highImpactReason: nil)
        case ".ruff_cache":
            return ArtifactMatch(category: .pythonAndEnvs, ecosystemLabel: "Ruff Cache (.ruff_cache)", highImpactReason: nil)
        case ".tox":
            return ArtifactMatch(category: .pythonAndEnvs, ecosystemLabel: "Tox Environments (.tox)", highImpactReason: "Recreate with tox")
        default:
            return nil
        }
    }

    private func buildWorkspaceArtifactItem(
        artifactURL: URL,
        projectRoot: URL,
        match: ArtifactMatch,
        liveProcesses: [ObservedProcess]
    ) -> IndexedStorageItem? {
        guard let identity = readDirectoryOrFileIdentity(at: artifactURL) else { return nil }
        let measured = fastMeasureDirectory(at: artifactURL)
        guard measured.bytes > 0 || measured.allocatedBytes > 0 else { return nil }

        let parentURL = artifactURL.deletingLastPathComponent()
        let projectName: String = {
            if parentURL.path == projectRoot.path {
                return projectRoot.lastPathComponent
            }
            return "\(projectRoot.lastPathComponent)/\(parentURL.lastPathComponent)"
        }()

        let displayName = "\(projectName) · \(artifactURL.lastPathComponent)"
        let safety = evaluateSafety(
            path: artifactURL.path,
            projectRootPath: parentURL.path,
            category: match.category,
            ecosystemLabel: match.ecosystemLabel,
            isBaseHighImpact: match.highImpactReason != nil,
            highImpactHint: match.highImpactReason,
            liveProcesses: liveProcesses
        )

        return IndexedStorageItem(
            path: artifactURL.path,
            displayName: displayName,
            subtitle: match.ecosystemLabel,
            projectName: projectName,
            projectRootPath: parentURL.path,
            category: match.category,
            ecosystemLabel: match.ecosystemLabel,
            bytes: measured.bytes,
            allocatedBytes: measured.allocatedBytes,
            fileCount: measured.fileCount,
            lastModifiedAt: measured.latestModification,
            fileIdentity: identity,
            safety: safety
        )
    }

    // MARK: - System, Xcode, Toolchain & AI Cache Discovery

    private struct CacheTarget {
        let url: URL
        let displayName: String
        let subtitle: String
        let category: StorageCategory
        let highImpactReason: String?
    }

    private func collectSystemAndAgentCacheTargets() -> [CacheTarget] {
        var targets: [CacheTarget] = []

        func addDirect(_ relativePath: String, title: String, subtitle: String, category: StorageCategory, highImpact: String? = nil) {
            let url = homeDirectory.appendingPathComponent(relativePath, isDirectory: true).standardizedFileURL
            guard !isProtectedPath(url), hasNoSymlinkInTargetOrAncestors(url) else { return }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return }
            targets.append(CacheTarget(url: url, displayName: title, subtitle: subtitle, category: category, highImpactReason: highImpact))
        }

        func addChildren(of relativeParent: String, prefixLabel: String, subtitle: String, category: StorageCategory, highImpact: String? = nil) {
            let parent = homeDirectory.appendingPathComponent(relativeParent, isDirectory: true).standardizedFileURL
            guard hasNoSymlinkInTargetOrAncestors(parent),
                  let children = try? FileManager.default.contentsOfDirectory(
                      at: parent,
                      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                      options: [.skipsHiddenFiles]
                  ) else { return }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let vals = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      vals.isDirectory == true, vals.isSymbolicLink != true,
                      !isProtectedPath(child) else { continue }
                let cleanChildName = Self.cleanDerivedDataName(child.lastPathComponent)
                targets.append(
                    CacheTarget(
                        url: child.standardizedFileURL,
                        displayName: "\(prefixLabel) · \(cleanChildName)",
                        subtitle: subtitle,
                        category: category,
                        highImpactReason: highImpact
                    )
                )
            }
        }

        // 1. Xcode & Simulators (broken down per-project for DerivedData & per-OS for DeviceSupport!)
        addChildren(
            of: "Library/Developer/Xcode/DerivedData",
            prefixLabel: "DerivedData",
            subtitle: "Xcode DerivedData Build Cache",
            category: .xcodeAndSimulators
        )
        addChildren(
            of: "Library/Developer/Xcode/iOS DeviceSupport",
            prefixLabel: "iOS DeviceSupport",
            subtitle: "Xcode iOS Debug Symbols",
            category: .xcodeAndSimulators,
            highImpact: "Re-downloaded when physical iOS device is attached"
        )
        addChildren(
            of: "Library/Developer/Xcode/watchOS DeviceSupport",
            prefixLabel: "watchOS DeviceSupport",
            subtitle: "Xcode watchOS Debug Symbols",
            category: .xcodeAndSimulators,
            highImpact: "Re-downloaded when Apple Watch is attached"
        )
        addDirect("Library/Developer/CoreSimulator/Caches", title: "CoreSimulator Caches", subtitle: "iOS Simulator Runtime Cache", category: .xcodeAndSimulators)
        addDirect("Library/Caches/com.apple.dt.Xcode", title: "Xcode App Cache", subtitle: "com.apple.dt.Xcode", category: .xcodeAndSimulators)

        // 2. Toolchain & Package Manager Global Caches
        addDirect("Library/Caches/org.swift.swiftpm", title: "SwiftPM Package Cache", subtitle: "Swift Package Manager", category: .toolchainCaches)
        addDirect("Library/Caches/CocoaPods", title: "CocoaPods Cache", subtitle: "CocoaPods Specs & Tarballs", category: .toolchainCaches)
        addDirect(".npm/_cacache", title: "npm Global Cache", subtitle: "~/.npm/_cacache", category: .toolchainCaches)
        addDirect("Library/Caches/pnpm", title: "pnpm Cache", subtitle: "~/Library/Caches/pnpm", category: .toolchainCaches)
        addDirect("Library/pnpm/store", title: "pnpm Content Store", subtitle: "~/Library/pnpm/store", category: .toolchainCaches)
        addDirect("Library/Caches/Yarn", title: "Yarn Cache", subtitle: "~/Library/Caches/Yarn", category: .toolchainCaches)
        addDirect(".bun/install/cache", title: "Bun Package Cache", subtitle: "~/.bun/install/cache", category: .toolchainCaches)
        addDirect(".cargo/registry/cache", title: "Rust Cargo Crate Cache", subtitle: "~/.cargo/registry/cache", category: .toolchainCaches)
        addDirect(".gradle/caches", title: "Gradle Global Cache", subtitle: "~/.gradle/caches", category: .toolchainCaches)
        addDirect("Library/Caches/pip", title: "pip Download Cache", subtitle: "~/Library/Caches/pip", category: .toolchainCaches)
        addDirect("Library/Caches/uv", title: "uv Package Cache", subtitle: "~/Library/Caches/uv", category: .toolchainCaches)
        addDirect(".cache/uv", title: "uv Cache (~/.cache/uv)", subtitle: "~/.cache/uv", category: .toolchainCaches)
        addDirect("Library/Caches/Homebrew", title: "Homebrew Downloads Cache", subtitle: "~/Library/Caches/Homebrew", category: .toolchainCaches)
        addDirect("Library/Caches/node-gyp", title: "node-gyp Headers Cache", subtitle: "~/Library/Caches/node-gyp", category: .toolchainCaches)
        addDirect("Library/Caches/electron", title: "Electron Binary Cache", subtitle: "~/Library/Caches/electron", category: .toolchainCaches)
        addDirect(
            "Library/Caches/ms-playwright",
            title: "Playwright Browsers",
            subtitle: "~/Library/Caches/ms-playwright",
            category: .toolchainCaches,
            highImpact: "Reinstall with npx playwright install"
        )
        addDirect(
            ".cache/puppeteer",
            title: "Puppeteer Browsers",
            subtitle: "~/.cache/puppeteer",
            category: .toolchainCaches,
            highImpact: "Browser binaries cache"
        )
        addDirect(
            ".cache/huggingface",
            title: "HuggingFace Model Weights",
            subtitle: "~/.cache/huggingface",
            category: .toolchainCaches,
            highImpact: "Large ML model weights"
        )

        // 3. AI Coding Agent Caches & Debug Logs
        addDirect(".claude/cache", title: "Claude Code · Cache", subtitle: "~/.claude/cache", category: .aiAgentStorage)
        addDirect(".claude/downloads", title: "Claude Code · Downloads", subtitle: "~/.claude/downloads", category: .aiAgentStorage)
        addDirect(".claude/debug", title: "Claude Code · Debug Logs", subtitle: "~/.claude/debug", category: .aiAgentStorage)
        addDirect(".codex/cache", title: "Codex · Cache", subtitle: "~/.codex/cache", category: .aiAgentStorage)
        addDirect(".codex/log", title: "Codex · Logs", subtitle: "~/.codex/log", category: .aiAgentStorage)
        addDirect("Library/Caches/com.openai.codex", title: "Codex Desktop · Cache", subtitle: "~/Library/Caches/com.openai.codex", category: .aiAgentStorage)
        addDirect(".cache/codex-runtimes", title: "Codex · Sandbox Runtimes", subtitle: "~/.cache/codex-runtimes", category: .aiAgentStorage)
        addDirect(".cache/opencode", title: "OpenCode · Cache", subtitle: "~/.cache/opencode", category: .aiAgentStorage)
        addDirect(".local/share/opencode/log", title: "OpenCode · Logs", subtitle: "~/.local/share/opencode/log", category: .aiAgentStorage)
        addDirect(".cursor/cache", title: "Cursor · CLI Cache", subtitle: "~/.cursor/cache", category: .aiAgentStorage)
        addDirect("Library/Application Support/Cursor/Cache", title: "Cursor · App Cache", subtitle: "Application Support/Cursor/Cache", category: .aiAgentStorage)
        addDirect("Library/Application Support/Cursor/Code Cache", title: "Cursor · Code Cache", subtitle: "Application Support/Cursor/Code Cache", category: .aiAgentStorage)
        addDirect("Library/Application Support/Cursor/GPUCache", title: "Cursor · GPU Cache", subtitle: "Application Support/Cursor/GPUCache", category: .aiAgentStorage)
        addDirect("Library/Application Support/Cursor/CachedData", title: "Cursor · CachedData", subtitle: "Application Support/Cursor/CachedData", category: .aiAgentStorage)
        addDirect("Library/Application Support/Windsurf/Cache", title: "Windsurf · Cache", subtitle: "Application Support/Windsurf/Cache", category: .aiAgentStorage)
        addDirect("Library/Application Support/Windsurf/CachedData", title: "Windsurf · CachedData", subtitle: "Application Support/Windsurf/CachedData", category: .aiAgentStorage)
        addDirect("Library/Application Support/Code/Cache", title: "VS Code · Cache", subtitle: "Application Support/Code/Cache", category: .aiAgentStorage)
        addDirect("Library/Application Support/Code/CachedData", title: "VS Code · CachedData", subtitle: "Application Support/Code/CachedData", category: .aiAgentStorage)

        return targets
    }

    private static func cleanDerivedDataName(_ folderName: String) -> String {
        guard let dashIndex = folderName.lastIndex(of: "-") else { return folderName }
        let suffix = folderName[folderName.index(after: dashIndex)...]
        if suffix.count >= 20 && suffix.allSatisfy({ $0.isLetter || $0.isNumber }) {
            return String(folderName[..<dashIndex])
        }
        return folderName
    }

    private func measureAndBuildCacheItem(_ target: CacheTarget, liveProcesses: [ObservedProcess]) -> IndexedStorageItem? {
        guard let identity = readDirectoryOrFileIdentity(at: target.url) else { return nil }
        let measured = fastMeasureDirectory(at: target.url)
        guard measured.bytes > 0 || measured.allocatedBytes > 0 else { return nil }

        let safety = evaluateSafety(
            path: target.url.path,
            projectRootPath: nil,
            category: target.category,
            ecosystemLabel: target.subtitle,
            isBaseHighImpact: target.highImpactReason != nil,
            highImpactHint: target.highImpactReason,
            liveProcesses: liveProcesses
        )

        return IndexedStorageItem(
            path: target.url.path,
            displayName: target.displayName,
            subtitle: target.subtitle,
            projectName: nil,
            projectRootPath: nil,
            category: target.category,
            ecosystemLabel: target.subtitle,
            bytes: measured.bytes,
            allocatedBytes: measured.allocatedBytes,
            fileCount: measured.fileCount,
            lastModifiedAt: measured.latestModification,
            fileIdentity: identity,
            safety: safety
        )
    }

    // MARK: - Smart Non-Blocking Safety Evaluation

    private func evaluateSafety(
        path: String,
        projectRootPath: String?,
        category: StorageCategory,
        ecosystemLabel: String,
        isBaseHighImpact: Bool,
        highImpactHint: String? = nil,
        liveProcesses: [ObservedProcess]
    ) -> StorageItemSafety {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path

        // 1. Check if any live process has its working directory inside this artifact or its owning project folder
        for proc in liveProcesses where proc.pid > 1 && !proc.isStopped {
            if let cwd = proc.cwd {
                let normCwd = URL(fileURLWithPath: cwd).standardizedFileURL.path
                if normCwd == normalizedPath || normCwd.hasPrefix(normalizedPath + "/") {
                    return .inUse(processSummary: "\(proc.name) (PID \(proc.pid))")
                }
                if let projectRootPath {
                    let normProj = URL(fileURLWithPath: projectRootPath).standardizedFileURL.path
                    if normCwd == normProj || normCwd.hasPrefix(normProj + "/") {
                        // Only block if it's an active dev runtime, compiler, or coding agent in that project
                        if isWorkspaceConsumerProcess(proc) {
                            return .inUse(processSummary: "\(proc.agentName ?? proc.name) (PID \(proc.pid))")
                        }
                    }
                }
            }

            // 2. Protect active Xcode builds & running Electron IDE caches
            let execName = proc.name.lowercased()
            if category == .xcodeAndSimulators,
               normalizedPath.contains("/DerivedData/"),
               ["xcodebuild", "swift-frontend", "clang", "sourcekit-lsp"].contains(execName) {
                if let cwd = proc.cwd, normalizedPath.lowercased().contains(URL(fileURLWithPath: cwd).lastPathComponent.lowercased()) {
                    return .inUse(processSummary: "\(proc.name) building")
                }
            }
            if normalizedPath.contains("/Application Support/Cursor/") && execName == "cursor" {
                return .inUse(processSummary: "Cursor is open")
            }
            if normalizedPath.contains("/Application Support/Windsurf/") && execName == "windsurf" {
                return .inUse(processSummary: "Windsurf is open")
            }
            if normalizedPath.contains("/Application Support/Code/") && execName == "code" {
                return .inUse(processSummary: "VS Code is open")
            }
        }

        if isBaseHighImpact || isInherentlyHighImpact(path: normalizedPath, ecosystemLabel: ecosystemLabel) {
            return .highImpactReview(reason: highImpactHint ?? "Manual review recommended before cleaning")
        }
        return .ready
    }

    private func isWorkspaceConsumerProcess(_ proc: ObservedProcess) -> Bool {
        if proc.agentName != nil { return true }
        let name = proc.name.lowercased()
        let activeTools: Set<String> = [
            "node", "bun", "deno", "vite", "next-server", "esbuild", "turbopack",
            "python", "python3", "uvicorn", "gunicorn", "pytest",
            "cargo", "rustc", "rust-analyzer",
            "swift", "swift-frontend", "xcodebuild",
            "java", "gradle", "mvn", "go"
        ]
        return activeTools.contains(name) || name.hasPrefix("python3.")
    }

    private func isInherentlyHighImpact(path: String, ecosystemLabel: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent
        if [".venv", "venv", ".env-venv", ".tox"].contains(name) { return true }
        if path.contains("/iOS DeviceSupport/") || path.contains("/watchOS DeviceSupport/") { return true }
        if path.contains("/.cache/huggingface") || path.contains("/ms-playwright") || path.contains("/.cache/puppeteer") {
            return true
        }
        return false
    }

    private func isProtectedPath(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let systemRoots: Set<String> = [
            "/", "/Users", "/System", "/Library", "/Applications",
            "/bin", "/sbin", "/usr", "/var", "/private", "/etc", "/tmp"
        ]
        if systemRoots.contains(path) || path == homeDirectory.path {
            return true
        }
        let userTopFolders = ["Desktop", "Documents", "Downloads", "Pictures", "Music", "Movies", "Public"]
        for folder in userTopFolders {
            if path == homeDirectory.appendingPathComponent(folder).path {
                return true
            }
        }
        let components = path.split(separator: "/").map(String.init)
        if components.contains(".git") || components.contains(".ssh") || components.contains(".gnupg") || components.contains(".aws") {
            return true
        }

        let protectedHomeRelativePrefixes = [
            ".claude/projects",
            ".claude/settings.json",
            ".codex/sessions",
            ".codex/archived_sessions",
            ".codex/auth.json",
            ".local/share/opencode/opencode.db",
            ".local/share/opencode/storage",
            "Library/Application Support/Cursor/User",
            ".gemini/sessions",
            ".gemini/settings.json"
        ]
        for rel in protectedHomeRelativePrefixes {
            let full = homeDirectory.appendingPathComponent(rel).standardizedFileURL.path
            if path == full || path.hasPrefix(full + "/") {
                return true
            }
        }
        return false
    }

    // MARK: - Fast POSIX Directory Measurement & Identity

    private struct DirectoryMeasurement {
        var bytes: Int64 = 0
        var allocatedBytes: Int64 = 0
        var fileCount: Int = 0
        var latestModification: Date?
    }

    private func fastMeasureDirectory(at rootURL: URL, maxEntries: Int = 450_000) -> DirectoryMeasurement {
        var measurement = DirectoryMeasurement()
        var rootStat = stat()
        let physicalRoot = physicalPath(for: rootURL.path)
        guard lstat(physicalRoot, &rootStat) == 0, (rootStat.st_mode & S_IFMT) == S_IFDIR else {
            return measurement
        }
        let rootDevice = rootStat.st_dev
        var latestSec = rootStat.st_mtimespec.tv_sec
        var entriesVisited = 0

        func walkDescriptor(_ fd: Int32, depth: Int) {
            guard let stream = fdopendir(fd) else {
                close(fd)
                return
            }
            defer { closedir(stream) }

            while entriesVisited < maxEntries, let entry = readdir(stream) {
                let name = withUnsafeBytes(of: &entry.pointee.d_name) { bytes in
                    bytes.baseAddress.flatMap { String(validatingUTF8: $0.assumingMemoryBound(to: CChar.self)) }
                }
                guard let name, name != ".", name != ".." else { continue }
                entriesVisited += 1

                var st = stat()
                guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0,
                      st.st_dev == rootDevice else { continue }

                if st.st_mtimespec.tv_sec > latestSec {
                    latestSec = st.st_mtimespec.tv_sec
                }

                let fileType = st.st_mode & S_IFMT
                if fileType == S_IFREG {
                    measurement.fileCount += 1
                    let logical = max(0, Int64(st.st_size))
                    let allocated = max(0, Int64(st.st_blocks) * 512)
                    measurement.bytes = measurement.bytes > Int64.max - logical ? Int64.max : measurement.bytes + logical
                    measurement.allocatedBytes = measurement.allocatedBytes > Int64.max - allocated ? Int64.max : measurement.allocatedBytes + allocated
                } else if fileType == S_IFDIR && depth < 48 {
                    let childFD = openat(fd, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                    if childFD >= 0 {
                        walkDescriptor(childFD, depth: depth + 1)
                    }
                }
            }
        }

        if let fd = openNoFollowDirectory(rootURL) {
            walkDescriptor(fd, depth: 0)
        }
        if latestSec > 0 {
            measurement.latestModification = Date(timeIntervalSince1970: TimeInterval(latestSec))
        }
        return measurement
    }

    private func openNoFollowDirectory(_ url: URL) -> Int32? {
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        let path = physicalPath(for: url.standardizedFileURL.path)
        let fd = open(path, flags)
        return fd >= 0 ? fd : nil
    }

    private func readDirectoryOrFileIdentity(at url: URL) -> FileIdentity? {
        let path = physicalPath(for: url.standardizedFileURL.path)
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK else { return nil }
        return FileIdentity(device: st.st_dev, inode: UInt64(st.st_ino))
    }

    private func hasNoSymlinkInTargetOrAncestors(_ url: URL) -> Bool {
        var current = physicalPath(for: url.standardizedFileURL.path)
        guard current.hasPrefix("/"), current != "/" else { return false }
        while current != "/" && !current.isEmpty {
            var st = stat()
            guard lstat(current, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK else { return false }
            current = (current as NSString).deletingLastPathComponent
        }
        return true
    }

    private func physicalPath(for rawPath: String) -> String {
        for alias in ["/var", "/tmp", "/etc"] {
            if rawPath == alias || rawPath.hasPrefix(alias + "/") {
                return "/private" + rawPath
            }
        }
        return rawPath
    }

    private func shortenForProgress(_ path: String) -> String {
        if path.hasPrefix(homeDirectory.path + "/") {
            return "~" + path.dropFirst(homeDirectory.path.count)
        }
        return path
    }
}
