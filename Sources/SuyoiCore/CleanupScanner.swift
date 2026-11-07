import Foundation

public struct CleanupScanner: CleanupScanning {
    private static let sharedMeasurementCache = IncrementalDirectoryCache()
    private let identityReader: @Sendable (URL) -> FileIdentity?
    private let measurementCache: IncrementalDirectoryCache?

    public init() {
        self.identityReader = { FileMetadataReader().identity(at: $0) }
        self.measurementCache = Self.sharedMeasurementCache
    }

    init(identityReader: @escaping @Sendable (URL) -> FileIdentity?) {
        self.identityReader = identityReader
        self.measurementCache = nil
    }

    public func scan(root: URL, entryLimit: Int = 100_000, timeLimit: TimeInterval = 10) -> CleanupReport {
        scan(root: root, agentHomeDirectory: nil, entryLimit: entryLimit, timeLimit: timeLimit)
    }

    public func scan(root: URL, agentHomeDirectory: URL?, entryLimit: Int = 100_000, timeLimit: TimeInterval = 10) -> CleanupReport {
        let reader = FileMetadataReader()
        let fm = FileManager.default
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + max(0, timeLimit)
        guard entryLimit > 0, timeLimit > 0 else {
            return CleanupReport(candidates: [], warnings: ["Scan stopped at its time or entry budget. Results are partial."], partial: true)
        }
        let normalized = root.standardizedFileURL
        guard reader.identity(at: normalized) != nil,
              (try? normalized.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return CleanupReport(candidates: [], warnings: ["Scan root is missing, unreadable, or a symbolic link."], partial: true)
        }
        let canonicalRoot = normalized.resolvingSymlinksInPath()
        // Reserve part of the common budget for the optional separate cache scan.
        let projectLimit = agentHomeDirectory == nil ? entryLimit : (entryLimit + 1) / 2
        let highBudget = entryLimit >= 1_000_000
        let discoveryLimit = highBudget ? projectLimit : (projectLimit >= 4_000 ? min(projectLimit, max(1_000, projectLimit / 4)) : max(1, projectLimit / 2))
        let projectDeadline = agentHomeDirectory == nil ? deadline : started + max(0, timeLimit) / 2
        let discoveryDeadline = highBudget ? projectDeadline : started + max(0, projectDeadline - started) / 2
        let categories = ["node_modules": "Dependency installation", ".build": "Swift build output", ".turbo": "Turbo cache", ".vite": "Vite cache"]
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        var entries = 0
        var discoveryPartial = false
        var warnings: [String] = []
        var discovered: [(URL, String)] = []
        func warn(_ message: String) {
            discoveryPartial = true
            if warnings.count < 20 { warnings.append(message) }
        }
        func visit(_ directory: URL, depth: Int) {
            guard !discoveryPartial || (entries < discoveryLimit && ProcessInfo.processInfo.systemUptime < discoveryDeadline) else { return }
            guard let children = fm.enumerator(at: directory, includingPropertiesForKeys: keys, options: [.skipsSubdirectoryDescendants], errorHandler: { _, _ in
                warn("Could not list \(directory.lastPathComponent).")
                return true
            }) else { warn("Could not list \(directory.lastPathComponent)."); return }
            while true {
                guard entries < discoveryLimit, ProcessInfo.processInfo.systemUptime < discoveryDeadline else { discoveryPartial = true; return }
                guard let child = children.nextObject() as? URL else { return }
                entries += 1
                guard reader.canonicalPath(child, relativeTo: canonicalRoot) != nil else { continue }
                guard let metadata = try? child.resourceValues(forKeys: Set(keys)) else { warn("Could not inspect \(child.lastPathComponent)."); continue }
                guard metadata.isDirectory == true, metadata.isSymbolicLink != true else { continue }
                let name = child.lastPathComponent
                if let category = categories[name] ?? ((name == "cache" && directory.lastPathComponent == ".next") ? "Next.js cache" : nil) {
                    discovered.append((child, category))
                    continue
                }
                if name.hasPrefix(".") && name != ".next" { continue }
                if directory.lastPathComponent == ".next" { continue }
                if depth < 3 { visit(child, depth: depth + 1) }
            }
        }
        visit(canonicalRoot, depth: 0)
        var remaining = max(0, projectLimit - entries)
        var candidates: [CleanupCandidate] = []
        var partial = discoveryPartial
        for (index, item) in discovered.enumerated() {
            let count = discovered.count - index
            let now = ProcessInfo.processInfo.systemUptime
            let sliceDeadline = now + max(0, projectDeadline - now) / Double(count)
            let valid = reader.canonicalPath(item.0, relativeTo: canonicalRoot) != nil
            let preIdentity = identityReader(item.0)
            let measurement: FileMetadataReader.Measurement
            if valid, entryLimit >= 100_000, let cached = measurementCache?.cachedBytes(for: item.0) {
                measurement = FileMetadataReader.Measurement(bytes: cached, allocatedBytes: cached, allocatedAvailable: true, entries: 1, partial: false)
            } else if valid {
                let measured = reader.measure(item.0, entryLimit: highBudget ? remaining : remaining / count, deadline: highBudget ? projectDeadline : sliceDeadline)
                if !measured.partial {
                    measurementCache?.record(bytes: measured.bytes, for: item.0)
                }
                measurement = measured
            } else {
                measurement = FileMetadataReader.Measurement(partial: true, warnings: ["Candidate changed during scan."])
            }
            let postIdentity = identityReader(item.0)
            let identityChanged = preIdentity == nil || preIdentity != postIdentity
            let candidatePartial = measurement.partial || identityChanged
            remaining -= measurement.entries
            warnings.append(contentsOf: measurement.warnings)
            if identityChanged { warnings.append("Candidate changed during scan.") }
            partial = partial || candidatePartial
            candidates.append(CleanupCandidate(path: item.0.path, category: item.1, bytes: measurement.bytes, partial: candidatePartial, allocatedBytes: measurement.allocatedAvailable ? measurement.allocatedBytes : nil, fileIdentity: valid && !identityChanged ? postIdentity : nil))
        }
        var agentCandidates: [CleanupCandidate] = []
        if let home = agentHomeDirectory {
            let agent = AgentCacheCatalog().scanAgentCaches(homeDirectory: home, entryLimit: max(0, entryLimit - projectLimit), timeLimit: max(0, deadline - ProcessInfo.processInfo.systemUptime))
            agentCandidates = agent.candidates
            warnings.append(contentsOf: agent.warnings)
            partial = partial || agent.partial
        }
        if partial { warnings.append("Scan stopped at its time or entry budget or could not inspect all entries. Results are partial.") }
        return CleanupReport(candidates: candidates.sorted { $0.bytes > $1.bytes }, warnings: warnings, partial: partial, agentCacheCandidates: agentCandidates, discoveredCount: discovered.count + agentCandidates.count)
    }
}
