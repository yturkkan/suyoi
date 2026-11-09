import Foundation

public enum StatusBarDisplayStyle: String, CaseIterable, Codable, Sendable {
    case iconOnly = "Icon Only"
    case agentsAndServers = "Agents & Servers"
    case agentsServersAndQuota = "Agents, Servers & Quota %"
    case agentsAndMemory = "Agents & Memory"
}

public enum DashboardFilterAndBadgeFormatter {
    public static func formatStatusBarTitle(
        style: StatusBarDisplayStyle,
        agents: [AgentObservation],
        servers: [ServerGroup],
        pendingApprovalsCount: Int = 0,
        highestQuotaPercent: Double? = nil
    ) -> String {
        let safeApprovals = max(0, pendingApprovalsCount)

        if style == .iconOnly {
            return safeApprovals > 0 ? " ⏳\(safeApprovals)" : ""
        }

        if agents.isEmpty && servers.isEmpty && safeApprovals == 0 {
            return ""
        }

        let waitingCount = agents.filter { $0.activityState == .waiting }.count
        let attentionCount = max(waitingCount, safeApprovals)

        var parts: [String] = []
        if !agents.isEmpty {
            if attentionCount > 0 {
                parts.append("\(agents.count)A·\(attentionCount)⏳")
            } else {
                parts.append("\(agents.count)A")
            }
        } else if safeApprovals > 0 {
            parts.append("⏳\(safeApprovals)")
        }

        if !servers.isEmpty {
            parts.append("\(servers.count)S")
        }

        let base = parts.isEmpty ? "" : " " + parts.joined(separator: " ")

        switch style {
        case .iconOnly:
            return safeApprovals > 0 ? " ⏳\(safeApprovals)" : ""
        case .agentsAndServers:
            return base
        case .agentsServersAndQuota:
            if let pct = highestQuotaPercent, pct.isFinite {
                return base + " · \(Int(pct.rounded()))%"
            }
            return base
        case .agentsAndMemory:
            let totalBytes = agents.reduce(Int64(0)) { partial, agent in
                partial + max(0, agent.process.footprintBytes ?? agent.process.residentBytes)
            }
            if totalBytes > 0 {
                return base + " · \(formatCompactMemory(totalBytes))"
            }
            return base
        }
    }

    public static func formatCompactMemory(_ bytes: Int64) -> String {
        let clamped = max(0, bytes)
        let gb = Double(clamped) / 1_073_741_824.0
        if gb >= 1.0 {
            return String(format: "%.1fG", gb)
        }
        let mb = Double(clamped) / 1_048_576.0
        if mb >= 1.0 {
            return "\(Int(mb.rounded()))M"
        }
        let kb = Double(clamped) / 1024.0
        if kb >= 1.0 {
            return "\(Int(kb.rounded()))K"
        }
        return "\(clamped)B"
    }

    public static func filterAgents(_ agents: [AgentObservation], query: String) -> [AgentObservation] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return agents }
        let needle = trimmed.lowercased()

        return agents.filter { agent in
            let fields: [String?] = [
                agent.agentName,
                agent.project?.name,
                agent.project?.gitBranch,
                agent.project?.rootPath,
                agent.process.cwd,
                agent.sessionTitle,
                agent.currentTask,
                agent.process.tty,
                String(agent.process.pid)
            ]
            return fields.contains { value in
                guard let value else { return false }
                return value.lowercased().contains(needle)
            }
        }
    }

    public static func filterServers(_ groups: [ServerGroup], query: String) -> [ServerGroup] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return groups }
        let needle = trimmed.lowercased()

        return groups.filter { group in
            var fields: [String?] = [
                group.name,
                group.project?.name,
                group.project?.framework,
                group.project?.gitBranch,
                String(group.rootPID),
                ServerPresentation.namedLocalhostURL(for: group)?.host
            ]
            for listener in group.listeners {
                fields.append(String(listener.port))
                fields.append(":\(listener.port)")
            }
            return fields.contains { value in
                guard let value else { return false }
                return value.lowercased().contains(needle)
            }
        }
    }

    public static func filterCleanupCandidates(_ candidates: [CleanupCandidate], query: String) -> [CleanupCandidate] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return candidates }
        let needle = trimmed.lowercased()

        return candidates.filter { candidate in
            let fields: [String?] = [
                candidate.path,
                candidate.category,
                candidate.agentName
            ]
            return fields.contains { value in
                guard let value else { return false }
                return value.lowercased().contains(needle)
            }
        }
    }

    public static func filterListeners(_ listeners: [Listener], query: String) -> [Listener] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return listeners }
        let needle = trimmed.lowercased()

        return listeners.filter { listener in
            let fields: [String] = [
                listener.processName,
                listener.address,
                listener.exposure,
                String(listener.port),
                ":\(listener.port)",
                String(listener.pid)
            ]
            return fields.contains { $0.lowercased().contains(needle) }
        }
    }
}
