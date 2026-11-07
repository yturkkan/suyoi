import Foundation

public struct AlertEvent: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case agentWaiting, quotaWarning, quotaCritical, quotaReset
    }

    public let id: String
    public let kind: Kind
    public let title: String
    public let body: String

    public init(id: String, kind: Kind, title: String, body: String) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
    }
}

/// Stateful, offline transitions only. Evaluation does not deliver notifications.
public struct AlertStateTracker: Sendable {
    private struct Waiting: Sendable {
        let identity: ProcessIdentity
    }
    private struct WindowState: Sendable {
        var resetsAt: Date?
        var severity = 0
        var previousPercent: Double?
        var cycle: UInt64 = 0
    }
    private var waiting: [Waiting] = []
    private var windows: [String: WindowState] = [:]
    private var waitingSequence: UInt64 = 0

    public init() {}

    public mutating func evaluate(
        agents: [AgentObservation],
        quotas: [QuotaProvider: ProviderQuotaStatus],
        warningPercent: Double = 85,
        criticalPercent: Double = 95
    ) -> [AlertEvent] {
        var events: [AlertEvent] = []
        var nextWaiting: [Waiting] = []
        for agent in agents {
            let identity = agent.process.identity
            guard agent.activityState == .waiting, !agent.process.isStopped,
                  !agents.contains(where: { $0.process.identity == identity && ($0.activityState != .waiting || $0.process.isStopped) }),
                  !nextWaiting.contains(where: { $0.identity == identity }) else { continue }
            nextWaiting.append(Waiting(identity: identity))
            guard !waiting.contains(where: { $0.identity == identity }) else { continue }
            waitingSequence &+= 1
            let name = Self.label(agent.agentName, fallback: "Agent")
            let project = agent.project.map { " in " + Self.label($0.name, fallback: "project") } ?? ""
            events.append(AlertEvent(id: "waiting-\(waitingSequence)", kind: .agentWaiting,
                title: "\(name) is waiting", body: "\(name) (PID \(identity.pid))\(project) is waiting for input."))
        }
        waiting = nextWaiting

        guard warningPercent.isFinite, criticalPercent.isFinite,
              warningPercent >= 0, warningPercent <= criticalPercent, criticalPercent <= 100 else { return events }
        // Stable ordering also makes notification delivery and fixture results reproducible.
        for provider in QuotaProvider.allCases {
            guard let status = quotas[provider], status.provider == provider, status.status != .unavailable else { continue }
            var grouped: [String: [QuotaWindow]] = [:]
            var order: [String] = []
            for window in status.windows {
                guard window.kind == .fiveHour || window.kind == .sevenDay else { continue }
                let minutes = window.windowMinutes ?? Self.defaultMinutes(window.kind)
                guard minutes > 0 else { continue }
                let key = "\(provider.rawValue)-\(window.kind.rawValue)-\(minutes)"
                if grouped[key] == nil { order.append(key) }
                grouped[key, default: []].append(window)
            }
            for key in order {
                guard let observations = grouped[key], let window = observations.first,
                      observations.allSatisfy({ $0 == window }),
                      let percent = window.usedPercent, percent.isFinite, (0...100).contains(percent),
                      window.resetsAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true else { continue }
                var state = windows[key] ?? WindowState(resetsAt: window.resetsAt)
                let timestampChanged = state.resetsAt != nil && window.resetsAt != nil && state.resetsAt != window.resetsAt
                // Custom thresholds below 20% recover only below their warning threshold,
                // avoiding a reset followed immediately by another warning at flat usage.
                let recoveryThreshold = min(20, warningPercent)
                let recovered = state.severity > 0 && percent < recoveryThreshold
                    && state.previousPercent.map { $0 >= recoveryThreshold } == true
                if timestampChanged || recovered {
                    if state.severity > 0 {
                        events.append(Self.quotaEvent(key: key, cycle: state.cycle, kind: .quotaReset, provider: provider, window: window))
                    }
                    state.severity = 0
                    state.cycle &+= 1
                }
                // Missing reset evidence does not erase a previously observed timestamp.
                if let reset = window.resetsAt { state.resetsAt = reset }
                let severity = percent >= criticalPercent ? 2 : (percent >= warningPercent ? 1 : 0)
                if severity > state.severity {
                    let kind: AlertEvent.Kind = severity == 2 ? .quotaCritical : .quotaWarning
                    events.append(Self.quotaEvent(key: key, cycle: state.cycle, kind: kind, provider: provider, window: window))
                    state.severity = severity
                }
                state.previousPercent = percent
                windows[key] = state
            }
        }
        return events
    }

    private static func defaultMinutes(_ kind: QuotaWindowKind) -> Int {
        kind == .fiveHour ? 300 : 10080
    }

    private static func quotaEvent(key: String, cycle: UInt64, kind: AlertEvent.Kind, provider: QuotaProvider, window: QuotaWindow) -> AlertEvent {
        let providerName: String = switch provider {
        case .codex: "Codex"
        case .claude: "Claude"
        case .gemini: "Gemini"
        case .openCode: "OpenCode"
        case .cursor: "Cursor"
        }
        let minutes = window.windowMinutes ?? defaultMinutes(window.kind)
        let windowName = "\(minutes)-minute account-wide quota"
        let title: String
        let body: String
        switch kind {
        case .quotaReset:
            title = "\(providerName) quota reset"
            body = "The \(windowName) has started a new cycle or recovered below 20%."
        case .quotaCritical:
            title = "\(providerName) quota critical"
            body = "The \(windowName) has reached the critical threshold."
        default:
            title = "\(providerName) quota warning"
            body = "The \(windowName) has reached the warning threshold."
        }
        return AlertEvent(id: "quota-\(key)-\(cycle)-\(kind.rawValue)", kind: kind, title: title, body: body)
    }

    private static func label(_ value: String, fallback: String) -> String {
        let clean = String(value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format
        }.prefix(160)).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return clean.isEmpty ? fallback : String(clean.prefix(80))
    }
}
