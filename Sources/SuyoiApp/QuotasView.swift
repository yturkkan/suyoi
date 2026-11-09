import AppKit
import SwiftUI
import SuyoiCore

struct QuotasSectionView: View {
    @ObservedObject var model: DashboardModel

    private var accent: Color {
        ThemeStyling.accentColor(for: model.experienceTheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            liveHeaderCard

            if let snapshot = model.quotaSnapshot {
                let items = model.displayQuotaItems(from: snapshot)
                if items.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("All subscriptions are currently hidden")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Open Settings to choose which AI subscriptions to display and change their order.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Button("Open Settings…") {
                            model.isShowingSettings = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(accent)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .themedSurfaceCard(theme: model.experienceTheme, isHovered: false)
                } else {
                    ForEach(items, id: \.provider) { item in
                        let rowID = "quota-\(item.provider.rawValue)"
                        QuotaProviderCard(
                            item: item,
                            theme: model.experienceTheme,
                            isHovered: model.hoveredRowID == rowID,
                            isPollingLive: model.isPollingLiveQuotas && model.isLiveQuotaEnabled,
                            onHover: { hovering in
                                model.hoveredRowID = hovering ? rowID : (model.hoveredRowID == rowID ? nil : model.hoveredRowID)
                            },
                            onRefreshLive: {
                                model.refreshSingleLiveQuota(for: item.provider)
                            },
                            isLiveEnabled: model.isLiveQuotaEnabled
                        )
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Inspecting local AI usage & quota telemetry…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 32)
            }
        }
    }

    private var liveHeaderCard: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: model.isLiveQuotaEnabled ? "antenna.radiowaves.left.and.right" : "internaldrive")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(model.isLiveQuotaEnabled ? Color.blue : accent)
                .frame(width: 28, height: 28)
                .background(
                    (model.isLiveQuotaEnabled ? Color.blue : accent).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Account quotas")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("Account-wide")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
                Text(
                    model.isLiveQuotaEnabled
                        ? "Polls Codex, Claude & Gemini usage windows in-memory using existing CLI OAuth tokens alongside local rolling token counters."
                        : "Reads only numeric token & rate-limit counters from local session files. No network calls."
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }

            Spacer(minLength: 6)

            if model.isLiveQuotaEnabled {
                Button {
                    model.refreshLiveQuotas()
                } label: {
                    if model.isPollingLiveQuotas {
                        ProgressView().controlSize(.mini)
                    } else {
                        Label("Refresh", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isPollingLiveQuotas)
                .help("Poll live provider quota endpoints now")
            }

            Button {
                model.setLiveQuotaEnabled(!model.isLiveQuotaEnabled)
            } label: {
                Text(model.isLiveQuotaEnabled ? "Live: ON" : "Enable Live")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.isLiveQuotaEnabled ? Color.white : Color.primary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4.5)
                    .background(
                        model.isLiveQuotaEnabled ? Color.blue : Color.primary.opacity(0.08),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .help("Toggle live OAuth quota polling (Codex, Claude & Gemini)")

            Button {
                model.isShowingSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Reorder or show/hide subscriptions")
            .accessibilityLabel("Subscription settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .themedSurfaceCard(theme: model.experienceTheme, isHovered: false)
    }
}

struct CombinedProviderQuotaItem: Equatable, Sendable {
    let provider: QuotaProvider
    let local: ProviderQuotaStatus?
    let live: ProviderQuotaStatus?

    var displayName: String {
        switch provider {
        case .codex: return "OpenAI Codex"
        case .claude: return "Claude Code"
        case .gemini: return "Gemini CLI"
        case .openCode: return "OpenCode"
        case .cursor: return "Cursor"
        }
    }

    var symbolName: String {
        switch provider {
        case .codex: return "sparkles"
        case .claude: return "brain.head.profile"
        case .gemini: return "aqi.medium"
        case .openCode: return "chevron.left.forwardslash.chevron.right"
        case .cursor: return "cursorarrow.rays"
        }
    }

    var effectivePlanType: String? {
        live?.planType ?? local?.planType
    }

    var effectiveWindows: [QuotaWindow] {
        if let liveWindows = live?.windows, !liveWindows.isEmpty {
            return liveWindows
        }
        return local?.windows ?? []
    }

    var effectiveSourceForWindows: QuotaSourceKind? {
        if let liveWindows = live?.windows, !liveWindows.isEmpty {
            return .liveAPI
        }
        if let localWindows = local?.windows, !localWindows.isEmpty {
            return .localTelemetry
        }
        if live?.status == .complete || live?.status == .partial {
            return .liveAPI
        }
        if local?.status == .complete || local?.status == .partial {
            return .localTelemetry
        }
        return nil
    }

    var localTokenSummaries: [TokenUsageSummary] {
        local?.tokenUsage ?? []
    }

    var effectiveCredits: QuotaCredits? {
        live?.credits ?? local?.credits
    }

    var effectiveExtraUsage: QuotaExtraUsage? {
        live?.extraUsage ?? local?.extraUsage
    }

    var effectiveLastActivityAt: Date? {
        local?.lastActivityAt ?? live?.lastActivityAt
    }

    var effectiveObservedAt: Date? {
        live?.observedAt ?? local?.observedAt
    }

    var hasAnyData: Bool {
        !effectiveWindows.isEmpty ||
        localTokenSummaries.contains(where: { $0.status != .unavailable && ($0.totalTokens != nil || $0.inputTokens != nil || $0.outputTokens != nil) }) ||
        effectivePlanType != nil ||
        effectiveLastActivityAt != nil
    }

    var combinedWarnings: [String] {
        var list: [String] = []
        if let local {
            list.append(contentsOf: local.warnings)
        }
        if let live {
            list.append(contentsOf: live.warnings.filter { $0 != "Live polling disabled" })
        }
        var seen = Set<String>()
        return list.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

private struct QuotaProviderCard: View {
    let item: CombinedProviderQuotaItem
    let theme: SuyoiExperienceTheme
    let isHovered: Bool
    let isPollingLive: Bool
    let onHover: (Bool) -> Void
    let onRefreshLive: () -> Void
    let isLiveEnabled: Bool

    private var accent: Color {
        ThemeStyling.accentColor(for: theme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow

            let windows = item.effectiveWindows
            if !windows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                        QuotaWindowProgressRow(window: window, accent: accent)
                    }
                }
            }

            let validTokens = item.localTokenSummaries.filter {
                $0.status != .unavailable && ($0.totalTokens != nil || $0.inputTokens != nil || $0.outputTokens != nil)
            }
            if !validTokens.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("LOCAL ROLLING TOKEN CONSUMPTION")
                        .font(.system(size: 9.5, weight: .bold))
                        .tracking(0.4)
                        .foregroundStyle(.secondary)
                    ForEach(validTokens, id: \.windowMinutes) { summary in
                        TokenUsageRow(summary: summary)
                    }
                }
                .padding(.top, windows.isEmpty ? 0 : 2)
            }

            if let credits = item.effectiveCredits, (credits.hasCredits == true || credits.unlimited == true || credits.balance != nil) {
                creditsRow(credits)
            }

            if let extra = item.effectiveExtraUsage, extra.isEnabled == true {
                extraUsageRow(extra)
            }

            if !item.hasAnyData {
                Text(
                    item.combinedWarnings.first
                        ?? "No local usage records found for \(item.displayName) yet."
                )
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }

            footerMetadataRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .themedSurfaceCard(theme: theme, isHovered: isHovered)
        .onHover(perform: onHover)
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            Image(systemName: item.symbolName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent)

            Text(item.displayName)
                .font(.system(size: 13.5, weight: .bold))

            if let plan = item.effectivePlanType, !plan.isEmpty {
                Text(plan.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(accent.opacity(0.12), in: Capsule())
            }

            Spacer()

            if let source = item.effectiveSourceForWindows {
                HStack(spacing: 4) {
                    Circle()
                        .fill(source == .liveAPI ? Color.blue : accent)
                        .frame(width: 5, height: 5)
                    Text(source == .liveAPI ? "Live OAuth" : "Local Telemetry")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(source == .liveAPI ? Color.blue : accent)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background((source == .liveAPI ? Color.blue : accent).opacity(0.10), in: Capsule())
            } else {
                Text("Unavailable")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.05), in: Capsule())
            }

            if isLiveEnabled && (item.provider == .codex || item.provider == .claude || item.provider == .gemini) {
                Button(action: onRefreshLive) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(isPollingLive)
                .help("Refresh live OAuth quota for \(item.displayName)")
                .accessibilityLabel("Refresh live OAuth quota for \(item.displayName)")
            }
        }
    }

    private func creditsRow(_ credits: QuotaCredits) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "creditcard")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            if credits.unlimited == true {
                Text("Credits: Unlimited")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(accent)
            } else if let balance = credits.balance {
                Text(String(format: "Credits balance: %.2f", balance))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func extraUsageRow(_ extra: QuotaExtraUsage) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "plus.circle")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            let currencyPrefix = extra.currency.map { "\($0) " } ?? ""
            if let used = extra.used, let limit = extra.limit {
                Text(String(format: "Extra usage: %@%.2f / %.2f", currencyPrefix, used, limit))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                Text("Extra metered usage enabled")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footerMetadataRow: some View {
        HStack(spacing: 6) {
            Text("Account-wide quota")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            if let lastAct = item.effectiveLastActivityAt {
                Text("· Last active \(formatRelativeTime(lastAct))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            } else if let obsAt = item.effectiveObservedAt {
                Text("· Checked \(obsAt.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }
}

private struct QuotaWindowProgressRow: View {
    let window: QuotaWindow
    let accent: Color

    private var label: String {
        switch window.kind {
        case .fiveHour:
            return "5-Hour Window"
        case .sevenDay:
            return "7-Day Weekly Limit"
        case .sevenDayOpus:
            return "7-Day Opus Limit"
        case .sevenDaySonnet:
            return "7-Day Sonnet Limit"
        }
    }

    private var barColor: Color {
        guard let pct = window.usedPercent else { return .secondary }
        if pct >= 90 { return .red }
        if pct >= 65 { return .orange }
        return accent
    }

    var body: some View {
        let clamped = min(max(window.usedPercent ?? 0, 0), 100)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.primary)

                Spacer()

                if let resetsAt = window.resetsAt {
                    Text(formatResetCountdown(resetsAt))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                }

                if let pct = window.usedPercent {
                    let remaining = max(0, min(100, 100.0 - pct))
                    Text(String(format: "%.0f%% left (%.0f%% used)", remaining, pct))
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(barColor)
                        .fixedSize(horizontal: true, vertical: false)
                } else {
                    Text("—")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(barColor)
                        .frame(width: max(4, geo.size.width * CGFloat(clamped / 100.0)))
                }
            }
            .frame(height: 6)
        }
    }
}

private struct TokenUsageRow: View {
    let summary: TokenUsageSummary

    private var windowLabel: String {
        if summary.windowMinutes == 300 {
            return "Last 5h (300m)"
        } else if summary.windowMinutes == 10080 {
            return "Last 7d (7d)"
        } else {
            return "\(summary.windowMinutes)m window"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(windowLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)

            HStack(spacing: 6) {
                if let total = summary.totalTokens {
                    Text("\(formatTokenCount(total)) total")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                }
                if let input = summary.inputTokens {
                    Text("· \(formatTokenCount(input)) in")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if let cached = summary.cacheReadTokens, cached > 0 {
                    Text("· \(formatTokenCount(cached)) cache")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if let output = summary.outputTokens {
                    Text("· \(formatTokenCount(output)) out")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)

            Spacer(minLength: 0)
        }
    }
}

/// Compact inline account-wide quota summary bar shown inside matching Agent rows on the Agents tab.
struct CompactAgentQuotaBar: View {
    let item: CombinedProviderQuotaItem
    var theme: SuyoiExperienceTheme = .nativeGlass

    private var accent: Color {
        ThemeStyling.accentColor(for: theme)
    }

    var body: some View {
        let primaryWindow = item.effectiveWindows.first(where: { $0.kind == .fiveHour })
            ?? item.effectiveWindows.first(where: { $0.kind == .sevenDay })
        let token5h = item.localTokenSummaries.first(where: { $0.windowMinutes == 300 && ($0.totalTokens ?? 0) > 0 })
        let token7d = item.localTokenSummaries.first(where: { $0.windowMinutes == 10080 && ($0.totalTokens ?? 0) > 0 })

        if primaryWindow != nil || token5h != nil || token7d != nil {
            HStack(spacing: 6) {
                if let plan = item.effectivePlanType, !plan.isEmpty {
                    Text(plan.uppercased())
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(accent.opacity(0.12), in: Capsule())
                        .fixedSize(horizontal: true, vertical: false)
                }

                if let win = primaryWindow, let pct = win.usedPercent {
                    let windowLabel = win.kind == .fiveHour ? "5h" : "7d"
                    miniWindowPill(title: windowLabel, percent: pct, resetsAt: win.resetsAt)
                } else if let t5 = token5h, let tot = t5.totalTokens {
                    Text("\(formatTokenCount(tot)) tok (5h)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let t7 = token7d, let tot = t7.totalTokens {
                    Text("\(formatTokenCount(tot)) tok (7d)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .lineLimit(1)
        }
    }

    private func miniWindowPill(title: String, percent: Double, resetsAt: Date?) -> some View {
        let color: Color = percent >= 90 ? .red : (percent >= 65 ? .orange : accent)
        let clamped = min(max(percent, 0), 100)
        let remaining = max(0, min(100, 100.0 - clamped))
        return HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.10))
                    .frame(width: 24, height: 4.5)
                Capsule()
                    .fill(color)
                    .frame(width: max(2, 24 * CGFloat(clamped / 100.0)), height: 4.5)
            }
            Text(String(format: "%.0f%% left", remaining))
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .fixedSize(horizontal: true, vertical: false)
            if let resetsAt {
                Text("(\(formatShortCountdown(resetsAt)))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private func formatTokenCount(_ count: UInt64) -> String {
    if count >= 1_000_000_000 {
        return String(format: "%.2fB", Double(count) / 1_000_000_000.0)
    } else if count >= 1_000_000 {
        return String(format: "%.1fM", Double(count) / 1_000_000.0)
    } else if count >= 1_000 {
        return String(format: "%.1fK", Double(count) / 1_000.0)
    }
    return "\(count)"
}

private func formatResetCountdown(_ date: Date, now: Date = Date()) -> String {
    let remaining = date.timeIntervalSince(now)
    guard remaining > 0 else { return "resets soon" }
    guard remaining.isFinite, remaining < 315_360_000 else { return "resets later" }
    let totalMinutes = max(1, Int(ceil(remaining / 60.0)))
    let days = totalMinutes / 1440
    let hours = (totalMinutes % 1440) / 60
    let minutes = totalMinutes % 60
    if days > 0 {
        return "resets in \(days)d \(hours)h"
    } else if hours > 0 {
        return "resets in \(hours)h \(minutes)m"
    } else {
        return "resets in \(minutes)m"
    }
}

private func formatShortCountdown(_ date: Date, now: Date = Date()) -> String {
    let remaining = date.timeIntervalSince(now)
    guard remaining > 0 else { return "now" }
    guard remaining.isFinite, remaining < 315_360_000 else { return "later" }
    let totalMinutes = max(1, Int(ceil(remaining / 60.0)))
    let days = totalMinutes / 1440
    let hours = (totalMinutes % 1440) / 60
    let minutes = totalMinutes % 60
    if days > 0 {
        return "\(days)d \(hours)h"
    } else if hours > 0 {
        return "\(hours)h \(minutes)m"
    } else {
        return "\(minutes)m"
    }
}

private func formatRelativeTime(_ date: Date, now: Date = Date()) -> String {
    let elapsed = now.timeIntervalSince(date)
    guard elapsed.isFinite, elapsed >= 0, elapsed < 315_360_000 else { return "just now" }
    let diff = Int(elapsed)
    if diff < 60 { return "just now" }
    let minutes = diff / 60
    if minutes < 60 { return "\(minutes)m ago" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h ago" }
    let days = hours / 24
    return "\(days)d ago"
}
