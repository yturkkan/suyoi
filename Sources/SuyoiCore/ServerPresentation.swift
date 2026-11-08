import Foundation

public struct ServerHealthBadge: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case active, warm, idleStale
    }

    public let state: State
    public let label: String
    public let detail: String

    public init(state: State, label: String, detail: String) {
        self.state = state
        self.label = label
        self.detail = detail
    }
}

public enum ServerPresentation {
    /// Replaces separators and non-ASCII characters with a single interior hyphen.
    public static func sanitizedSubdomain(from rawName: String) -> String? {
        var bytes: [UInt8] = []
        for byte in rawName.utf8 {
            let lowercase = (65...90).contains(byte) ? byte + 32 : byte
            if (97...122).contains(lowercase) || (48...57).contains(lowercase) {
                bytes.append(lowercase)
            } else if !bytes.isEmpty && bytes.last != 45 {
                bytes.append(45)
            }
            if bytes.count == 63 { break }
        }
        if bytes.last == 45 { bytes.removeLast() }
        let label = String(decoding: bytes, as: UTF8.self)
        return label.isEmpty || label == "localhost" ? nil : label
    }

    public static func namedLocalhostURL(for group: ServerGroup) -> URL? {
        guard let port = group.listeners.first?.port, (1...65535).contains(port),
              let subdomain = sanitizedSubdomain(from: group.project?.name ?? group.name) else { return nil }
        return URL(string: "http://\(subdomain).localhost:\(port)")
    }

    public static func standardLocalhostURL(for group: ServerGroup) -> URL? {
        guard let port = group.listeners.first?.port, (1...65535).contains(port) else { return nil }
        return URL(string: "http://localhost:\(port)")
    }

    public static func healthBadge(
        for group: ServerGroup,
        now: Date = Date(),
        staleThresholdSeconds: TimeInterval = 7200
    ) -> ServerHealthBadge? {
        guard let startedAt = group.startedAt else { return nil }
        let uptime = now.timeIntervalSince(startedAt)
        guard uptime.isFinite, uptime >= 0,
              let minutes = Int(exactly: (uptime / 60).rounded(.down)) else { return nil }

        let hours = minutes / 60
        let compactDuration = hours > 0 ? "\(hours)h" : "\(minutes)m"
        let duration = hours > 0
            ? "\(hours) \(hours == 1 ? "hour" : "hours")"
            : "\(minutes) \(minutes == 1 ? "minute" : "minutes")"
        let lowCPU = (group.cpuPercent ?? 0) < 0.2

        if uptime >= staleThresholdSeconds && lowCPU {
            return ServerHealthBadge(state: .idleStale, label: "Idle \(compactDuration)",
                detail: "Server has been running for \(duration) with low current CPU activity (below 0.2%); it may be idle or stale.")
        }
        guard uptime >= 60 else { return nil }
        return ServerHealthBadge(state: lowCPU ? .warm : .active, label: "Up \(compactDuration)",
            detail: "Server has been running for \(duration).")
    }
}
