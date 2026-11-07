import Foundation

public struct ProcessTree: Sendable {
    public let processesByPID: [Int: ObservedProcess]
    public let childrenByParent: [Int: [Int]]
    private let agentBoundary: @Sendable (ObservedProcess) -> Bool

    public init(processes: [ObservedProcess], agentBoundary: @escaping @Sendable (ObservedProcess) -> Bool = { AgentRecognizer.isAgent($0) }) {
        // A snapshot can contain a PID twice during collection. Prefer the newer instance.
        var index: [Int: ObservedProcess] = [:]
        for process in processes where process.pid > 0 {
            if let old = index[process.pid], (old.startTimeMicroseconds ?? 0) > (process.startTimeMicroseconds ?? 0) { continue }
            index[process.pid] = process
        }
        self.processesByPID = index
        var children: [Int: [Int]] = [:]
        for process in index.values where process.parentPID != process.pid {
            children[process.parentPID, default: []].append(process.pid)
        }
        self.childrenByParent = children.mapValues { $0.sorted() }
        self.agentBoundary = { AgentRecognizer.isAgent($0) || agentBoundary($0) }
    }

    public func ancestors(of pid: Int, maxDepth: Int = 64) -> [Int] {
        var result: [Int] = []
        var visited: Set<Int> = [pid]
        var current = pid
        for _ in 0..<max(0, min(maxDepth, 64)) {
            guard let child = processesByPID[current], let parent = processesByPID[child.parentPID],
                  child.uid == parent.uid, visited.insert(parent.pid).inserted else { break }
            result.append(parent.pid)
            current = parent.pid
        }
        return result
    }

    public func descendants(of pid: Int, maxDepth: Int = 64) -> [Int] {
        var result: [Int] = []
        var visited: Set<Int> = [pid]
        var queue: [(Int, Int)] = [(pid, 0)]
        var offset = 0
        while offset < queue.count {
            let (parent, depth) = queue[offset]
            offset += 1
            guard depth < max(0, min(maxDepth, 64)) else { continue }
            for child in childrenByParent[parent] ?? [] where visited.insert(child).inserted {
                guard processesByPID[child]?.uid == processesByPID[parent]?.uid else { continue }
                result.append(child)
                queue.append((child, depth + 1))
            }
        }
        return result
    }

    private static func isShell(_ name: String) -> Bool { ["zsh", "bash", "fish", "sh", "tcsh", "ksh", "login"].contains(name) }
    private static func isRunner(_ name: String) -> Bool {
        ["node", "bun", "deno", "npm", "pnpm", "yarn", "npx", "python", "python3", "uv", "ruby", "cargo", "go", "sh", "bash", "zsh"].contains(name)
            || name.hasPrefix("python3")
    }
    private static func isGUI(_ process: ObservedProcess) -> Bool { process.executable.contains(".app/Contents/") }

    public func groupServers(listeners: [Listener], projectsByPath: [String: ProjectContext] = [:]) -> [ServerGroup] {
        struct Candidate {
            var root: Int
            var members: Set<Int>
            var listeners: [Listener]
            var boundary: Bool
        }
        func isBoundary(_ process: ObservedProcess) -> Bool {
            agentBoundary(process) || Self.isShell(process.name) || Self.isGUI(process)
        }

        var candidates: [Candidate] = []
        for listener in listeners {
            var root = listener.pid
            var visited: Set<Int> = [root]
            var members: Set<Int> = [root]
            var boundary = false
            for _ in 0..<64 {
                guard let child = processesByPID[root], let parent = processesByPID[child.parentPID], child.uid == parent.uid else { break }
                if agentBoundary(parent) { boundary = true; break }
                // A protected process that owns a listener stays in its own group.
                guard !isBoundary(child), !Self.isGUI(parent), !visited.contains(parent.pid),
                      Self.isRunner(parent.name) else { break }
                let siblings = childrenByParent[parent.pid] ?? []
                // Shells remain user launch contexts even with a single child.
                if Self.isShell(parent.name) { break }
                let sameProject = child.cwd != nil && child.cwd != "/" && child.cwd == parent.cwd
                let directLauncher = siblings.count == 1 && ["npm", "pnpm", "yarn", "npx", "uv", "cargo", "go"].contains(parent.name)
                    && (child.cwd == nil || parent.cwd == nil || sameProject)
                guard sameProject || directLauncher else { break }
                root = parent.pid
                visited.insert(root)
                members.insert(root)
            }
            candidates.append(Candidate(root: root, members: members, listeners: [listener], boundary: boundary))
        }
        func safelyRelated(_ descendant: Int, _ ancestor: Int) -> Bool {
            let lineage = ancestors(of: descendant)
            guard let pathEnd = lineage.firstIndex(of: ancestor) else { return false }
            let path = [descendant] + Array(lineage.prefix(through: pathEnd))
            let projects = Set(path.compactMap { pid -> String? in
                guard let cwd = processesByPID[pid]?.cwd, cwd != "/" else { return nil }
                return projectsByPath[cwd]?.rootPath ?? cwd
            })
            return projects.count <= 1 && path.allSatisfy { pid in
                guard let process = processesByPID[pid] else { return false }
                return !isBoundary(process)
            }
        }
        // A fixed-point merge handles chains of reloader/shared-port relationships.
        var changed = true
        while changed {
            changed = false
            outer: for i in candidates.indices {
                for j in candidates.indices where j > i {
                    let a = candidates[i], b = candidates[j]
                    let sharedPort = !Set(a.listeners.map(\.port)).isDisjoint(with: b.listeners.map(\.port))
                    let safeConnection = sharedPort && a.members.contains { member in
                        b.members.contains { safelyRelated(member, $0) || safelyRelated($0, member) }
                    }
                    guard !a.members.isDisjoint(with: b.members) || safeConnection else { continue }
                    let root = ancestors(of: a.root).contains(b.root) ? b.root : a.root
                    candidates[i] = Candidate(root: root, members: a.members.union(b.members), listeners: a.listeners + b.listeners, boundary: a.boundary || b.boundary)
                    candidates.remove(at: j)
                    changed = true
                    break outer
                }
            }
        }
        return candidates.map { item in
            // Include non-listening worker children, but prune other users, agents,
            // GUI processes and explicitly different working directories.
            var members = item.members
            var queue = [(item.root, 0)]
            var seen = Set<Int>()
            var offset = 0
            let cwd = processesByPID[item.root]?.cwd
                ?? item.listeners.compactMap { processesByPID[$0.pid]?.cwd }.first
            while offset < queue.count {
                let (pid, depth) = queue[offset]; offset += 1
                guard depth <= 64, seen.insert(pid).inserted else { continue }
                if let process = processesByPID[pid] {
                    guard !isBoundary(process),
                          process.uid == processesByPID[item.root]?.uid,
                          process.cwd == nil || cwd == nil || process.cwd == cwd else { continue }
                    members.insert(pid)
                    for child in childrenByParent[pid] ?? [] { queue.append((child, depth + 1)) }
                }
            }
            let memberProcesses = members.sorted().compactMap { processesByPID[$0] }
            let resources = ServerResources(processes: memberProcesses)
            let root = processesByPID[item.root]
            let startedAt = root?.startTimeMicroseconds.map { Date(timeIntervalSince1970: Double($0) / 1_000_000) }
            let uniqueListeners = Dictionary(item.listeners.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted { $0.id < $1.id }
            return ServerGroup(id: "\(item.root):\(root?.startTimeMicroseconds.map(String.init) ?? "unknown")", rootPID: item.root,
                name: root?.name ?? item.listeners.first?.processName ?? "Unknown", memberPIDs: members.sorted(), memberIdentities: memberProcesses.compactMap(\.identity), listeners: uniqueListeners,
                project: cwd.flatMap { projectsByPath[$0] }, cpuPercent: resources.cpuPercent,
                residentBytes: resources.residentBytes, footprintBytes: resources.footprintBytes,
                startedAt: startedAt, stoppedByAgentBoundary: item.boundary)
        }.sorted { $0.rootPID < $1.rootPID }
    }
}
