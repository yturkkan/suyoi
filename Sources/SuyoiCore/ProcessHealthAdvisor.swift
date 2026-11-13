import Foundation

public struct OrphanToolProcess: Equatable, Identifiable, Sendable {
    public var id: Int { process.pid }
    public let process: ObservedProcess
    public let kindLabel: String

    public init(process: ObservedProcess, kindLabel: String) {
        self.process = process
        self.kindLabel = kindLabel
    }
}

public struct StuckAgentDiagnostic: Equatable, Sendable {
    public let agentID: Int
    public let consecutiveHighCPUSamples: Int
    public let cpuPercent: Double
    public let summary: String

    public init(agentID: Int, consecutiveHighCPUSamples: Int, cpuPercent: Double, summary: String) {
        self.agentID = agentID
        self.consecutiveHighCPUSamples = consecutiveHighCPUSamples
        self.cpuPercent = cpuPercent
        self.summary = summary
    }
}

public enum ProcessHealthAdvisor {
    /// Finds reparented (`PPID == 1`) MCP / stdio tool helper processes that outlived their parent coding agent.
    /// Never exposes raw CLI arguments; only returns normalized helper kind labels.
    public static func detectOrphanToolProcesses(
        in snapshot: InventorySnapshot,
        uid: Int = Int(getuid()),
        classifyMCPProcess: ((Int32, String) -> String?)? = nil
    ) -> [OrphanToolProcess] {
        let agentPIDs = Set(snapshot.agentObservations.map { $0.process.pid })
        var serverMemberPIDs = Set<Int>()
        for group in snapshot.serverGroups {
            serverMemberPIDs.formUnion(group.memberPIDs)
        }
        for listener in snapshot.listeners {
            serverMemberPIDs.insert(listener.pid)
        }

        let reader = ProcessArgumentsReader()
        let classifier = classifyMCPProcess ?? { pid, execPath in
            reader.mcpHelperKind(pid: pid, executablePath: execPath)
        }

        var orphans: [OrphanToolProcess] = []
        for proc in snapshot.processes {
            guard proc.uid == uid,
                  proc.parentPID == 1,
                  proc.pid > 1,
                  !proc.isStopped,
                  proc.identity.isActionEligible,
                  !agentPIDs.contains(proc.pid),
                  !serverMemberPIDs.contains(proc.pid),
                  AgentRecognizer.runningProviderName(for: proc) == nil,
                  let pid32 = Int32(exactly: proc.pid),
                  let kind = classifier(pid32, proc.executable) else {
                continue
            }
            orphans.append(OrphanToolProcess(process: proc, kindLabel: kind))
        }
        return orphans.sorted {
            if $0.process.residentBytes != $1.process.residentBytes {
                return $0.process.residentBytes > $1.process.residentBytes
            }
            return $0.process.pid < $1.process.pid
        }
    }
}

public struct StuckAgentTracker: Sendable {
    private struct SampleState: Sendable {
        let identity: ProcessIdentity
        var highCPUCount: Int
        var lastObservedSessionUpdate: Date?
    }

    private var statesByPID: [Int: SampleState] = [:]

    public init() {}

    public mutating func evaluate(
        agents: [AgentObservation],
        turnPreviews: [Int: SessionTurnPreview] = [:],
        cpuThreshold: Double = 85.0,
        requiredSamples: Int = 3
    ) -> [Int: StuckAgentDiagnostic] {
        var nextStates: [Int: SampleState] = [:]
        var diagnostics: [Int: StuckAgentDiagnostic] = [:]

        for agent in agents where !agent.process.isStopped && agent.activityState != .stopped {
            let pid = agent.process.pid
            let identity = agent.process.identity
            let latestUpdate = turnPreviews[agent.id]?.updatedAt ?? agent.lastActivityAt
            let isHighCPU = agent.process.cpuPercent.isFinite && agent.process.cpuPercent >= cpuThreshold

            var sample: SampleState
            if let existing = statesByPID[pid], existing.identity == identity {
                let progressed: Bool
                if let prev = existing.lastObservedSessionUpdate, let curr = latestUpdate {
                    progressed = curr > prev.addingTimeInterval(0.5)
                } else {
                    progressed = existing.lastObservedSessionUpdate == nil && latestUpdate != nil
                }

                if isHighCPU && !progressed {
                    sample = SampleState(
                        identity: identity,
                        highCPUCount: existing.highCPUCount + 1,
                        lastObservedSessionUpdate: latestUpdate ?? existing.lastObservedSessionUpdate
                    )
                } else {
                    sample = SampleState(
                        identity: identity,
                        highCPUCount: isHighCPU ? 1 : 0,
                        lastObservedSessionUpdate: latestUpdate ?? existing.lastObservedSessionUpdate
                    )
                }
            } else {
                sample = SampleState(
                    identity: identity,
                    highCPUCount: isHighCPU ? 1 : 0,
                    lastObservedSessionUpdate: latestUpdate
                )
            }

            nextStates[pid] = sample
            if sample.highCPUCount >= max(2, requiredSamples) {
                diagnostics[agent.id] = StuckAgentDiagnostic(
                    agentID: agent.id,
                    consecutiveHighCPUSamples: sample.highCPUCount,
                    cpuPercent: agent.process.cpuPercent,
                    summary: String(
                        format: "High CPU (%.0f%%) across %d checks without new session output",
                        agent.process.cpuPercent,
                        sample.highCPUCount
                    )
                )
            }
        }

        statesByPID = nextStates
        return diagnostics
    }
}
