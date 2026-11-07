import Foundation

struct AgentActivityEvaluator {
    func evaluate(process: ObservedProcess, allProcesses: [ObservedProcess], homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = Date()) -> (state: AgentActivityState, detail: String, lastActivityAt: Date?, statusSource: AgentStatusSource) {
        if process.isStopped { return (.stopped, "Suspended (SIGSTOP)", nil, .processOnly) }
        let tree = ProcessTree(processes: allProcesses)
        let tools: Set<String> = ["git", "rg", "swift", "cargo", "npm", "pnpm", "bun", "pytest", "go"]
        let activeChild = tree.descendants(of: process.pid).contains { pid in
            guard let child = tree.processesByPID[pid], !child.isStopped else { return false }
            return child.cpuPercent >= 0.5 || tools.contains(child.name)
        }
        if process.cpuPercent >= 1 || activeChild { return (.active, "Active CPU / running child command", now, .processOnly) }
        let recent = latestModification(for: process.agentName, home: homeDirectory)
        if let recent, recent <= now, now.timeIntervalSince(recent) <= 15 {
            return (.active, "Recent session state update", recent, .processOnly)
        }
        if let tty = process.tty { return (.waiting, "Attached to \(tty) · waiting for input", recent, .processOnly) }
        return (.idle, "Idle background process", recent, .processOnly)
    }

    private func latestModification(for name: String?, home: URL) -> Date? {
        let path: String
        switch name {
        case "Claude Code": path = ".claude/projects"
        case "Codex": path = ".codex/sessions"
        case "OpenCode": path = ".local/share/opencode"
        case "Aider": path = ".aider.chat.history.md"
        default: return nil
        }
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]
        var queue: [(URL, Int)] = [(home.appendingPathComponent(path), 0)]
        var offset = 0, count = 0
        var latest: Date?
        while offset < queue.count && count < 64 {
            let (url, depth) = queue[offset]; offset += 1; count += 1
            guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else { continue }
            if let date = values.contentModificationDate, latest == nil || date > latest! { latest = date }
            if depth < 2, values.isDirectory == true,
               let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [.skipsSubdirectoryDescendants]) {
                while queue.count < 64, let child = enumerator.nextObject() as? URL { queue.append((child, depth + 1)) }
            }
        }
        return latest
    }
}
