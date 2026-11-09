import Foundation

struct AgentActivityEvaluator {
    func evaluate(process: ObservedProcess, allProcesses: [ObservedProcess], now: Date = Date()) -> (state: AgentActivityState, detail: String, lastActivityAt: Date?, statusSource: AgentStatusSource) {
        if process.isStopped { return (.stopped, "Suspended (SIGSTOP)", nil, .processOnly) }
        let tree = ProcessTree(processes: allProcesses)
        let tools: Set<String> = ["git", "rg", "swift", "cargo", "npm", "pnpm", "bun", "pytest", "go"]
        let activeChild = tree.descendants(of: process.pid).contains { pid in
            guard let child = tree.processesByPID[pid], !child.isStopped else { return false }
            return child.cpuPercent >= 0.5 || tools.contains(child.name)
        }
        if process.cpuPercent >= 1 || activeChild { return (.active, "Active CPU / running child command", now, .processOnly) }
        return (.idle, "No process activity detected", nil, .processOnly)
    }
}
