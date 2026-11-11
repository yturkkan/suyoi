import Foundation

public struct QuotaBurnEstimate: Equatable, Sendable {
    public let provider: QuotaProvider
    public let windowKind: QuotaWindowKind
    public let percentPerHour: Double
    public let estimatedExhaustionAt: Date?
    public let resetsAt: Date?
    public let willDepleteBeforeReset: Bool
    public let summaryText: String

    public init(
        provider: QuotaProvider,
        windowKind: QuotaWindowKind,
        percentPerHour: Double,
        estimatedExhaustionAt: Date?,
        resetsAt: Date?,
        willDepleteBeforeReset: Bool,
        summaryText: String
    ) {
        self.provider = provider
        self.windowKind = windowKind
        self.percentPerHour = percentPerHour
        self.estimatedExhaustionAt = estimatedExhaustionAt
        self.resetsAt = resetsAt
        self.willDepleteBeforeReset = willDepleteBeforeReset
        self.summaryText = summaryText
    }
}

public struct ProviderRecommendation: Equatable, Sendable {
    public let provider: QuotaProvider
    public let displayName: String
    public let remainingPercent: Double
    public let reason: String

    public init(provider: QuotaProvider, displayName: String, remainingPercent: Double, reason: String) {
        self.provider = provider
        self.displayName = displayName
        self.remainingPercent = remainingPercent
        self.reason = reason
    }
}

public struct QuotaBurnRateTracker: Sendable {
    private struct Sample: Sendable {
        let timestamp: Date
        let usedPercent: Double
        let resetsAt: Date?
    }

    private struct Key: Hashable, Sendable {
        let provider: QuotaProvider
        let kind: QuotaWindowKind
    }

    private var samplesByKey: [Key: [Sample]] = [:]

    public init() {}

    public mutating func record(
        windowsByProvider: [QuotaProvider: [QuotaWindow]],
        at now: Date = Date()
    ) {
        let cutoff = now.addingTimeInterval(-7_200)
        for (provider, windows) in windowsByProvider {
            for window in windows {
                guard let used = window.usedPercent, used.isFinite, (0...100).contains(used) else { continue }
                let key = Key(provider: provider, kind: window.kind)
                var history = (samplesByKey[key] ?? []).filter { $0.timestamp >= cutoff }
                if let last = history.last {
                    // Reset sample history if a quota window reset occurred.
                    let resetChanged = last.resetsAt != nil && window.resetsAt != nil
                        && abs(last.resetsAt!.timeIntervalSince(window.resetsAt!)) > 60
                    let droppedSharply = last.usedPercent - used >= 15.0
                    if resetChanged || droppedSharply {
                        history.removeAll()
                    } else if now.timeIntervalSince(last.timestamp) < 15 && abs(used - last.usedPercent) < 0.05 {
                        continue
                    }
                }
                history.append(Sample(timestamp: now, usedPercent: used, resetsAt: window.resetsAt))
                if history.count > 24 {
                    history.removeFirst(history.count - 24)
                }
                samplesByKey[key] = history
            }
        }
    }

    public func estimate(
        for provider: QuotaProvider,
        window: QuotaWindow,
        now: Date = Date()
    ) -> QuotaBurnEstimate? {
        guard let currentUsed = window.usedPercent, currentUsed.isFinite, (0...100).contains(currentUsed) else {
            return nil
        }
        let key = Key(provider: provider, kind: window.kind)
        guard let history = samplesByKey[key], history.count >= 2,
              let oldest = history.first, let newest = history.last else {
            return nil
        }
        let elapsedSeconds = newest.timestamp.timeIntervalSince(oldest.timestamp)
        guard elapsedSeconds >= 60 else { return nil }
        let deltaPercent = newest.usedPercent - oldest.usedPercent
        let ratePerHour = (deltaPercent / elapsedSeconds) * 3_600.0
        guard ratePerHour.isFinite, ratePerHour >= 0.5 else { return nil }

        let remainingPercent = max(0, 100.0 - currentUsed)
        let hoursToExhaust = remainingPercent / ratePerHour
        let exhaustionDate = hoursToExhaust.isFinite
            ? now.addingTimeInterval(hoursToExhaust * 3_600.0)
            : nil
        let willDeplete: Bool
        if let exhaustionDate, let resetsAt = window.resetsAt, resetsAt > now {
            willDeplete = exhaustionDate < resetsAt
        } else {
            willDeplete = remainingPercent <= 0.1 || hoursToExhaust < 1.5
        }

        let rateLabel = ratePerHour >= 10
            ? String(format: "~%.0f%%/h", ratePerHour)
            : String(format: "~%.1f%%/h", ratePerHour)
        let summary: String
        if remainingPercent <= 0.5 {
            summary = "\(rateLabel) · limit exhausted"
        } else if willDeplete {
            summary = "\(rateLabel) · depletes in \(Self.formatDuration(hours: hoursToExhaust))"
        } else if window.resetsAt != nil {
            summary = "\(rateLabel) · safe until reset"
        } else {
            summary = "\(rateLabel) · ~\(Self.formatDuration(hours: hoursToExhaust)) headroom"
        }

        return QuotaBurnEstimate(
            provider: provider,
            windowKind: window.kind,
            percentPerHour: ratePerHour,
            estimatedExhaustionAt: exhaustionDate,
            resetsAt: window.resetsAt,
            willDepleteBeforeReset: willDeplete,
            summaryText: summary
        )
    }

    public func recommendProvider(
        windowsByProvider: [QuotaProvider: [QuotaWindow]],
        visibleProviders: [QuotaProvider],
        now: Date = Date()
    ) -> ProviderRecommendation? {
        struct Candidate {
            let provider: QuotaProvider
            let remaining: Double
            let score: Double
            let reason: String
        }

        var candidates: [Candidate] = []
        for provider in visibleProviders {
            guard let windows = windowsByProvider[provider], !windows.isEmpty else { continue }
            let relevant = windows.filter { ($0.usedPercent?.isFinite == true) }
            guard !relevant.isEmpty else { continue }
            guard let bottleneck = relevant.max(by: { ($0.usedPercent ?? 0) < ($1.usedPercent ?? 0) }),
                  let maxUsed = bottleneck.usedPercent else { continue }
            let remaining = max(0, min(100, 100.0 - maxUsed))
            guard remaining >= 5.0 else { continue }

            let burn = estimate(for: provider, window: bottleneck, now: now)
            var score = remaining
            let reason: String
            if burn?.willDepleteBeforeReset == true {
                score -= 35.0
                reason = String(format: "%.0f%% left (high burn pace)", remaining)
            } else if let burn {
                score -= min(15.0, burn.percentPerHour * 0.4)
                reason = String(format: "%.0f%% left · %@", remaining, burn.summaryText)
            } else {
                reason = String(format: "%.0f%% remaining headroom", remaining)
            }
            candidates.append(Candidate(provider: provider, remaining: remaining, score: score, reason: reason))
        }

        guard candidates.count >= 2,
              let best = candidates.max(by: { $0.score < $1.score }) else {
            return nil
        }
        return ProviderRecommendation(
            provider: best.provider,
            displayName: Self.displayName(for: best.provider),
            remainingPercent: best.remaining,
            reason: best.reason
        )
    }

    private static func displayName(for provider: QuotaProvider) -> String {
        switch provider {
        case .codex: return "OpenAI Codex"
        case .claude: return "Claude Code"
        case .gemini: return "Gemini CLI"
        case .openCode: return "OpenCode"
        case .cursor: return "Cursor"
        }
    }

    private static func formatDuration(hours: Double) -> String {
        let totalMinutes = max(1, Int((hours * 60.0).rounded()))
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        if h >= 24 {
            let d = h / 24
            let remH = h % 24
            return remH > 0 ? "\(d)d \(remH)h" : "\(d)d"
        }
        if h > 0 {
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        return "\(m)m"
    }
}
