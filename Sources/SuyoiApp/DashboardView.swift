import AppKit
import SwiftUI
import SuyoiCore

private let leafGreen = Color.accentColor

struct DashboardView: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            if let release = model.availableUpdate {
                updateBar(release)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
            if let banner = model.actionBanner {
                bannerBar(banner)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    switch model.tab {
                    case .agents: agentsSection
                    case .ports: portsSection
                    case .quotas: QuotasSectionView(model: model)
                    case .cleanup: cleanupSection
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            footer
        }
        .frame(width: 440, height: 580)
        .sheet(item: $model.selectedAgent) { agent in
            ProcessDetailView(
                subject: .agent(agent),
                steerModeLabel: model.steerModeLabel(for: agent),
                steerPromptText: $model.steerPromptText,
                isSteering: model.isSteering,
                onFocusAgent: { model.focusTerminalOrIDE(for: $0) },
                onSteerAgent: { model.sendSteerPrompt(to: $0) },
                onStopAgent: { model.stopAgent($0, force: $1) },
                onDismiss: { model.selectedAgent = nil }
            )
        }
        .sheet(item: $model.selectedServer) { server in
            ProcessDetailView(
                subject: .server(server),
                onOpenServer: { model.openServerInBrowser($0) },
                onCopyServerURL: { model.copyServerURL($0) },
                onStopServer: { model.stopServer($0, force: $1) },
                onDismiss: { model.selectedServer = nil }
            )
        }
        .sheet(isPresented: $model.isShowingCleanupPreview) {
            if let report = model.cleanup {
                CleanupPreviewView(
                    report: report,
                    recheckingCandidateIDs: model.recheckingCandidateIDs,
                    trashedHistory: model.trashedHistory,
                    onTrashCandidate: { model.trashCandidate($0) },
                    onRecheckCandidate: { model.recheckCandidate($0) },
                    onTrashWorktree: { model.trashWorktree($0) },
                    onRestoreTrashedItem: { model.restoreTrashedItem($0) },
                    onTrashAllEligible: { model.trashAllReviewable() },
                    onDismiss: { model.isShowingCleanupPreview = false }
                )
            }
        }
        .sheet(isPresented: $model.isShowingSettings) {
            SettingsView(model: model)
        }
    }

    // MARK: - Header, Banner & Native Segmented Tab Bar

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("Suyoi")
                .font(.system(size: 13, weight: .semibold))

            Text("·")
                .foregroundStyle(.tertiary)

            Text("\(model.agentRows.count) agents · \(model.developmentServerGroups.count) servers")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer()

            if !model.activeWarnings.isEmpty {
                Button {
                    model.isShowingNotesPopover.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                        Text("\(model.activeWarnings.count)")
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                    }
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: .systemOrange).opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .help(model.activeWarnings.joined(separator: "\n"))
                .popover(isPresented: $model.isShowingNotesPopover, arrowEdge: .bottom) {
                    notesPopover
                }
            }

            Button {
                model.togglePopoverPinned()
            } label: {
                Image(systemName: model.isPopoverPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.isPopoverPinned ? leafGreen : .secondary)
                    .frame(width: 22, height: 22)
                    .background(
                        model.isPopoverPinned ? leafGreen.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .help(model.isPopoverPinned ? "Pinned (Sticky): stays open when clicking outside" : "Pin panel: keep open when clicking outside")
            .accessibilityLabel(model.isPopoverPinned ? "Unpin panel" : "Pin panel")
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 8)
    }

    private func updateBar(_ release: AppReleaseInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(leafGreen)
            Text("Suyoi v\(release.version) is available")
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            Spacer()
            Button {
                model.installAvailableUpdate()
            } label: {
                if model.isInstallingUpdate {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("Updating…")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                } else {
                    Text("Update & Relaunch")
                        .font(.system(size: 10.5, weight: .semibold))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
            .disabled(model.isInstallingUpdate)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            leafGreen.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(leafGreen.opacity(0.35), lineWidth: 0.5)
        )
    }

    private func bannerBar(_ banner: ActionBanner) -> some View {
        HStack(spacing: 6) {
            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(banner.isError ? Color(nsColor: .systemOrange) : Color(nsColor: .systemGreen))
            Text(banner.message)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Spacer()
            Button {
                model.actionBanner = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    private var notesPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Inspection Notes", systemImage: "info.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                Spacer()
            }
            ForEach(Array(model.activeWarnings.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 6) {
                    Circle()
                        .fill(Color(nsColor: .systemOrange))
                        .frame(width: 4, height: 4)
                        .padding(.top, 5)
                    Text(item)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            Text("Suyoi reports partial or skipped metadata honestly rather than guessing.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 300)
    }

    private var tabBar: some View {
        Picker("", selection: $model.tab) {
            Text(segmentedTitle(.agents, count: model.snapshot.map { !model.agentRows.isEmpty ? model.agentRows.count : $0.agents.count }))
                .tag(DashboardTab.agents)
            Text(segmentedTitle(.ports, count: model.snapshot.map { _ in model.developmentServerGroups.count }))
                .tag(DashboardTab.ports)
            Text(segmentedTitle(.quotas, count: model.quotaSnapshot.map { _ in model.activeQuotaProvidersCount }))
                .tag(DashboardTab.quotas)
            Text(segmentedTitle(.cleanup, count: model.cleanup.map { _ in model.allCleanupCandidates.count }))
                .tag(DashboardTab.cleanup)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.regular)
    }

    private func segmentedTitle(_ tab: DashboardTab, count: Int?) -> String {
        guard let count else { return tab.rawValue }
        return "\(tab.rawValue) (\(count))"
    }

    // MARK: - Agents Section

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionSubheader(
                title: "Active Coding Agents",
                trailing: "Focus · steer · reveal · stop"
            )
            if model.snapshot != nil {
                let rows = model.agentRows
                if rows.isEmpty {
                    emptyState(
                        "No active coding agents found",
                        detail: "Supported agents (Claude Code, Codex, OpenCode, Aider, Gemini CLI — including Node/Python wrappers) will appear here when running.",
                        symbol: "terminal"
                    )
                } else {
                    ForEach(rows, id: \.id) { row in
                        let rowID = "agent-\(row.id)"
                        AgentCardRow(
                            obs: row,
                            quotaItem: model.combinedQuotaItem(forAgentName: row.agentName),
                            steerModeLabel: model.steerModeLabel(for: row),
                            isSteerComposerOpen: model.steeringAgentID == row.id,
                            steerPromptText: $model.steerPromptText,
                            isSteering: model.isSteering,
                            isHovered: model.hoveredRowID == rowID,
                            onHover: { model.hoveredRowID = $0 ? rowID : (model.hoveredRowID == rowID ? nil : model.hoveredRowID) },
                            onFocus: { model.focusTerminalOrIDE(for: row) },
                            onToggleSteer: { model.toggleSteerComposer(for: row) },
                            onSendSteer: { model.sendSteerPrompt(to: row) },
                            onStop: { model.stopAgent(row) },
                            onSelect: { model.selectedAgent = row }
                        )
                    }
                }
            } else {
                loadingState
            }
        }
    }

    // MARK: - Servers Section

    private var portsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionSubheader(
                title: "Development Servers",
                trailing: "Open localhost · copy URL · stop"
            )
            if model.snapshot != nil {
                let devGroups = model.developmentServerGroups
                let other = model.otherListeners
                if devGroups.isEmpty {
                    emptyState(
                        "No development servers active",
                        detail: "Local Node, Vite, Next.js, Python, Rust, Go, and Swift servers listening on TCP ports will be grouped here.",
                        symbol: "network"
                    )
                } else {
                    ForEach(devGroups, id: \.id) { group in
                        let rowID = "server-\(group.id)"
                        ServerGroupCardRow(
                            group: group,
                            healthBadge: model.serverHealthBadge(for: group),
                            namedURL: model.namedServerURL(for: group),
                            isHovered: model.hoveredRowID == rowID,
                            onHover: { model.hoveredRowID = $0 ? rowID : (model.hoveredRowID == rowID ? nil : model.hoveredRowID) },
                            onOpenBrowser: { model.openServerInBrowser(group) },
                            onOpenNamedURL: { model.openServerNamedLocalhost(group) },
                            onCopyURL: { model.copyServerURL(group) },
                            onCopyNamedURL: { model.copyServerNamedLocalhostURL(group) },
                            onStop: { model.stopServer(group) },
                            onSelect: { model.selectedServer = group }
                        )
                    }
                }

                if !other.isEmpty {
                    DisclosureGroup(isExpanded: $model.showOtherListeners) {
                        VStack(spacing: 6) {
                            ForEach(other, id: \.id) { listener in
                                compactListenerRow(listener)
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        HStack(spacing: 6) {
                            Text("Other user TCP listeners")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text("\(other.count)")
                                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                        }
                    }
                    .padding(.top, 4)
                }
            } else {
                loadingState
            }
        }
    }

    private func compactListenerRow(_ listener: Listener) -> some View {
        HStack(spacing: 8) {
            Button {
                if let url = URL(string: "http://localhost:\(listener.port)") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text(":\(listener.port)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(leafGreen)
                    .frame(width: 52, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("Open http://localhost:\(listener.port)")

            Text(listener.processName)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(listener.address) · PID \(listener.pid)")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(listener.exposure == "All interfaces" ? "All IF" : "Local")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Color.primary.opacity(0.05), in: Capsule())

            Button {
                model.stopListener(listener)
            } label: {
                Image(systemName: "stop.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.red.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help("Stop \(listener.processName) (PID \(listener.pid))")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .surfaceCardStyle(isHovered: false)
    }

    // MARK: - Storage Section

    private var cleanupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if model.cleanup != nil {
                    ForEach(CleanupScopeFilter.allCases, id: \.self) { filter in
                        Button {
                            model.cleanupFilter = filter
                        } label: {
                            Text(filter.rawValue)
                                .font(.system(size: 10.5, weight: model.cleanupFilter == filter ? .semibold : .medium))
                                .foregroundStyle(model.cleanupFilter == filter ? leafGreen : .secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3.5)
                                .background(
                                    model.cleanupFilter == filter ? leafGreen.opacity(0.12) : Color.primary.opacity(0.04),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    let scopeLabel = (model.scanAllWorkspaces && model.scannedWorkspaceRoots.count > 1)
                        ? "\(shortenHomePath(model.cleanupRoot.path)) + \(model.scannedWorkspaceRoots.count - 1) workspaces"
                        : shortenHomePath(model.cleanupRoot.path)
                    Text("\(scopeLabel) builds & allowlisted agent caches")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .help(
                            model.scanAllWorkspaces && model.scannedWorkspaceRoots.count > 1
                                ? model.scannedWorkspaceRoots.map { shortenHomePath($0.path) }.joined(separator: ", ")
                                : shortenHomePath(model.cleanupRoot.path)
                        )
                }

                Spacer()

                if model.cleanup != nil && !model.allCleanupCandidates.isEmpty {
                    Button {
                        model.isShowingCleanupPreview = true
                    } label: {
                        Label("Preview", systemImage: "shield.lefthalf.filled")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button {
                    model.scanCleanup()
                } label: {
                    if model.isScanning {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("Scanning…")
                        }
                    } else {
                        Label(model.cleanup == nil ? "Scan" : "Rescan", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.isScanning)
            }

            if !model.trashedHistory.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Label("Recently Moved to Trash (\(model.trashedHistory.count))", systemImage: "arrow.uturn.backward.circle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(leafGreen)
                        Spacer()
                    }
                    ForEach(model.trashedHistory.prefix(3)) { item in
                        HStack(spacing: 6) {
                            Text(URL(fileURLWithPath: item.originalPath).lastPathComponent)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .lineLimit(1)
                            Text("· \(item.category)")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                model.restoreTrashedItem(item)
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "arrow.uturn.backward")
                                        .font(.system(size: 9, weight: .semibold))
                                    Text("Put Back")
                                        .font(.system(size: 9.5, weight: .semibold))
                                }
                                .foregroundStyle(leafGreen)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(leafGreen.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(model.isPerformingAction)
                            .help("Restore \(shortenHomePath(item.originalPath)) from macOS Trash")
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .surfaceCardStyle(isHovered: false)
            }

            if let report = model.cleanup {
                HStack(spacing: 6) {
                    Text("\(formatBytes(model.totalCleanupBytes)) observed")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(leafGreen)
                    Text("· \(model.reviewableCleanupCandidates.count) ready for Trash (\(report.discoveredCount) total)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !model.reviewableCleanupCandidates.isEmpty {
                        Button {
                            model.trashAllReviewable()
                        } label: {
                            Label("Trash Ready (\(formatBytes(model.totalReviewableBytes)))", systemImage: "trash")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .disabled(model.isPerformingAction)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(leafGreen.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                let items = model.filteredCleanupCandidates
                if items.isEmpty {
                    emptyState(
                        "No items in this category",
                        detail: "Switch filter or run a scan to inspect generated folders and allowlisted agent caches.",
                        symbol: "folder.badge.checkmark"
                    )
                } else {
                    ForEach(items, id: \.path) { candidate in
                        let rowID = "cleanup-\(candidate.id)"
                        CleanupCandidateCardRow(
                            candidate: candidate,
                            assessment: model.assessment(for: candidate),
                            diagnostic: model.diagnosticDetail(for: candidate),
                            isHighImpact: model.isHighImpactCandidate(candidate),
                            isRechecking: model.recheckingCandidateIDs.contains(candidate.id),
                            isHovered: model.hoveredRowID == rowID,
                            onHover: { model.hoveredRowID = $0 ? rowID : (model.hoveredRowID == rowID ? nil : model.hoveredRowID) },
                            onTrash: { model.trashCandidate(candidate) },
                            onRecheck: { model.recheckCandidate(candidate) },
                            onOpenPreview: { model.isShowingCleanupPreview = true }
                        )
                    }
                }
            } else if !model.isScanning {
                emptyState(
                    "Ready for storage scan & cleanup",
                    detail: "Finds generated build folders in ~/Developer and allowlisted agent caches (Codex, Claude, OpenCode, Cursor, npm, Cargo, Poetry) so you can move them safely to macOS Trash.",
                    symbol: "externaldrive.badge.checkmark"
                )
            }
        }
    }

    // MARK: - Shared Helpers

    private func sectionSubheader(title: String, trailing: String) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Spacer()
            Text(trailing)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.bottom, 2)
    }

    private var loadingState: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Inspecting local workspace…")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 32)
    }

    private func emptyState(_ title: String, detail: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(leafGreen)
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
            }
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCardStyle(isHovered: false)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.6)
            HStack(spacing: 6) {
                Circle()
                    .fill(model.isSnapshotStale ? Color.orange : leafGreen)
                    .frame(width: 5, height: 5)
                Text(
                    model.isRefreshing
                        ? "Refreshing…"
                        : model.snapshot.map { "Updated \($0.capturedAt.formatted(date: .omitted, time: .shortened))\(model.isSnapshotStale ? " · stale" : "")" }
                            ?? "Not yet inspected"
                )
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

                Text("· Safe Trash & SIGTERM")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)

                Spacer()

                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .disabled(model.isRefreshing)
                .help("Refresh local inventory")
                .accessibilityLabel("Refresh local inventory")

                Menu {
                    if let release = model.availableUpdate {
                        Button("Update to v\(release.version) & Relaunch") {
                            model.installAvailableUpdate()
                        }
                        .disabled(model.isInstallingUpdate)
                    }
                    Button(model.isCheckingForUpdates ? "Checking for Updates…" : "Check for Updates…") {
                        model.checkForUpdates()
                    }
                    .disabled(model.isCheckingForUpdates || model.isInstallingUpdate)
                    Divider()
                    Button("Settings…") {
                        model.settingsTab = .general
                        model.isShowingSettings = true
                    }
                    .keyboardShortcut(",")
                    Button("About Suyoi…") {
                        model.settingsTab = .about
                        model.isShowingSettings = true
                    }
                    Divider()
                    Button("Quit Suyoi") {
                        NSApplication.shared.terminate(nil)
                    }
                    .keyboardShortcut("q")
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 20)
                .help("Suyoi menu")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
        }
    }
}

// MARK: - Interactive Row Subviews

private struct AgentCardRow: View {
    let obs: AgentObservation
    let quotaItem: CombinedProviderQuotaItem?
    let steerModeLabel: String?
    let isSteerComposerOpen: Bool
    @Binding var steerPromptText: String
    let isSteering: Bool
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let onFocus: () -> Void
    let onToggleSteer: () -> Void
    let onSendSteer: () -> Void
    let onStop: () -> Void
    let onSelect: () -> Void

    private var activityBadge: (label: String, tint: Color) {
        if obs.process.isStopped || obs.activityState == .stopped {
            return ("Stopped", Color(nsColor: .systemOrange))
        }
        switch obs.activityState {
        case .active:
            return ("Working", Color(nsColor: .systemGreen))
        case .waiting:
            return ("Waiting", Color(nsColor: .systemOrange))
        case .idle:
            return ("Idle", .secondary)
        case .stopped:
            return ("Stopped", Color(nsColor: .systemOrange))
        case nil:
            return (obs.process.cpuPercent >= 1.0 ? "Working" : (obs.process.tty != nil ? "Waiting" : "Idle"),
                    obs.process.cpuPercent >= 1.0 ? Color(nsColor: .systemGreen) : (obs.process.tty != nil ? Color(nsColor: .systemOrange) : .secondary))
        }
    }

    var body: some View {
        let memory = obs.process.footprintBytes ?? obs.process.residentBytes
        let badgeInfo = activityBadge

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Button(action: onSelect) {
                    HStack(alignment: .center, spacing: 10) {
                        ZStack(alignment: .bottomTrailing) {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                                .frame(width: 28, height: 28)
                            Image(systemName: "terminal")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.primary.opacity(0.85))
                                .frame(width: 28, height: 28)
                            Circle()
                                .fill(badgeInfo.tint)
                                .frame(width: 7.5, height: 7.5)
                                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.2))
                                .offset(x: 2, y: 2)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Text(obs.agentName)
                                    .font(.system(size: 12.5, weight: .semibold))
                                statusBadge(badgeInfo.label, tint: badgeInfo.tint)
                                if let terminal = obs.terminalApp {
                                    statusBadge(terminal, tint: .secondary)
                                }
                                if !obs.childServerPorts.isEmpty {
                                    statusBadge(obs.childServerPorts.map { ":\($0)" }.joined(separator: " "), tint: leafGreen)
                                }
                            }

                            if let project = obs.project {
                                HStack(spacing: 4) {
                                    Image(systemName: "folder.fill")
                                        .font(.system(size: 9))
                                        .foregroundStyle(leafGreen)
                                    Text(project.name)
                                        .font(.system(size: 11, weight: .medium))
                                    if let branch = project.gitBranch {
                                        Text("· \(branch)\(project.isWorktree ? " (wt)" : "")")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .lineLimit(1)
                            } else if let cwd = obs.process.cwd {
                                Text(shortenHomePath(cwd))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            if let title = obs.sessionTitle, !title.isEmpty {
                                HStack(spacing: 4) {
                                    Image(systemName: "bubble.left.and.text.bubble.right.fill")
                                        .font(.system(size: 8.5))
                                        .foregroundStyle(.secondary)
                                    Text(title)
                                        .font(.system(size: 10.5, weight: .medium))
                                        .foregroundStyle(.primary.opacity(0.88))
                                        .lineLimit(1)
                                }
                            }

                            if let task = obs.currentTask, !task.isEmpty {
                                HStack(spacing: 4) {
                                    Image(systemName: "bolt.horizontal.circle.fill")
                                        .font(.system(size: 9))
                                        .foregroundStyle(leafGreen)
                                    Text(task)
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundStyle(leafGreen)
                                        .lineLimit(1)
                                }
                            }

                            HStack(spacing: 5) {
                                Text("PID \(obs.process.pid)")
                                if let tty = obs.process.tty {
                                    Text("· \(tty)")
                                }
                                if let detail = obs.activityDetail {
                                    Text("· \(detail)")
                                        .lineLimit(1)
                                }
                            }
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.tertiary)

                            if let quotaItem {
                                CompactAgentQuotaBar(item: quotaItem)
                            }
                        }

                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 6) {
                        if let steerModeLabel {
                            Button(action: onToggleSteer) {
                                Image(systemName: isSteerComposerOpen ? "paperplane.circle.fill" : "paperplane.fill")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(leafGreen)
                            }
                            .buttonStyle(.plain)
                            .help("Steer \(obs.agentName) via \(steerModeLabel)")
                        }

                        Button(action: onFocus) {
                            Image(systemName: "macwindow")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(leafGreen)
                        }
                        .buttonStyle(.plain)
                        .help("Focus \(obs.terminalApp ?? "Terminal / IDE") window")

                        if let path = obs.project?.rootPath ?? obs.process.cwd {
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            } label: {
                                Image(systemName: "folder")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Reveal in Finder")
                        }

                        if obs.process.identity.isActionEligible {
                            Button(action: onStop) {
                                Image(systemName: "stop.circle")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.red.opacity(0.85))
                            }
                            .buttonStyle(.plain)
                            .help("Stop \(obs.agentName) (SIGTERM)")
                        }
                    }

                    Text("\(String(format: "%.1f%%", obs.process.cpuPercent)) · \(formatBytes(memory))")
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            if isSteerComposerOpen, let steerModeLabel {
                Divider().opacity(0.5)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(leafGreen)
                        Text("Steer via \(steerModeLabel)")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(leafGreen)
                        if let sid = obs.sessionID {
                            Text("· \(sid.prefix(16))")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(action: onToggleSteer) {
                            Image(systemName: "xmark")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    HStack(spacing: 6) {
                        TextField("Send instruction or command to \(obs.agentName)…", text: $steerPromptText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                            .disabled(isSteering)
                            .onSubmit {
                                onSendSteer()
                            }

                        Button(action: onSendSteer) {
                            if isSteering {
                                ProgressView().controlSize(.mini)
                            } else {
                                Label("Send", systemImage: "arrow.up.circle.fill")
                                    .font(.system(size: 10.5, weight: .semibold))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isSteering || steerPromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .surfaceCardStyle(isHovered: isHovered)
        .onHover(perform: onHover)
    }
}

private struct ServerGroupCardRow: View {
    let group: ServerGroup
    let healthBadge: ServerHealthBadge?
    let namedURL: URL?
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let onOpenBrowser: () -> Void
    let onOpenNamedURL: () -> Void
    let onCopyURL: () -> Void
    let onCopyNamedURL: () -> Void
    let onStop: () -> Void
    let onSelect: () -> Void

    private func badgeTint(for badge: ServerHealthBadge) -> Color {
        switch badge.state {
        case .idleStale: return Color(nsColor: .systemOrange)
        case .active: return Color(nsColor: .systemGreen)
        case .warm: return .secondary
        }
    }

    var body: some View {
        let primaryPort = group.listeners.first.map { ":\($0.port)" } ?? "—"
        let extraCount = max(0, group.listeners.count - 1)
        let memory = group.footprintBytes ?? group.residentBytes

        HStack(alignment: .center, spacing: 10) {
            Button(action: onOpenBrowser) {
                VStack(spacing: 1) {
                    Text(primaryPort)
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(leafGreen)
                    if extraCount > 0 {
                        Text("+\(extraCount) more")
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(leafGreen.opacity(0.8))
                    }
                }
                .frame(width: 56, height: 32)
                .background(leafGreen.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Open http://localhost\(primaryPort) in browser")

            Button(action: onSelect) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(group.project?.name ?? group.name)
                                .font(.system(size: 12.5, weight: .semibold))
                                .lineLimit(1)
                            if let framework = group.project?.framework {
                                statusBadge(framework, tint: leafGreen)
                            }
                            if group.stoppedByAgentBoundary {
                                statusBadge("Agent child", tint: .blue)
                            }
                            if let healthBadge {
                                statusBadge(healthBadge.label, tint: badgeTint(for: healthBadge))
                                    .help(healthBadge.detail)
                            }
                        }

                        if let namedURL, let host = namedURL.host, let port = namedURL.port {
                            HStack(spacing: 5) {
                                Button(action: onOpenNamedURL) {
                                    HStack(spacing: 3) {
                                        Image(systemName: "link")
                                            .font(.system(size: 8.5, weight: .semibold))
                                        Text("\(host):\(port)")
                                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                            .lineLimit(1)
                                    }
                                    .foregroundStyle(leafGreen)
                                }
                                .buttonStyle(.plain)
                                .help("Open \(namedURL.absoluteString) in browser")

                                Button(action: onCopyNamedURL) {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 8.5))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Copy \(namedURL.absoluteString)")
                            }
                        }

                        if let project = group.project {
                            HStack(spacing: 4) {
                                if let branch = project.gitBranch {
                                    Text("\(branch)\(project.isWorktree ? " (wt)" : "") ·")
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Text(shortenHomePath(project.rootPath))
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }

                        Text("\(group.name) · PID \(group.rootPID)\(group.memberPIDs.count > 1 ? " (\(group.memberPIDs.count) procs)" : "") · \(group.listeners.first?.exposure ?? "Loopback")")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    Button(action: onOpenBrowser) {
                        Image(systemName: "globe")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(leafGreen)
                    }
                    .buttonStyle(.plain)
                    .help("Open in Browser")

                    Button(action: onCopyURL) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy localhost URL")

                    if let rootPath = group.project?.rootPath {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: rootPath)])
                        } label: {
                            Image(systemName: "folder")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Reveal Project in Finder")
                    }

                    Button(action: onStop) {
                        Image(systemName: "stop.circle")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.red.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .help("Stop Server (SIGTERM)")
                }

                HStack(spacing: 4) {
                    if let cpu = group.cpuPercent {
                        Text(String(format: "%.1f%%", cpu))
                            .monospacedDigit()
                    }
                    if memory > 0 {
                        Text("· \(formatBytes(memory))")
                    }
                }
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .surfaceCardStyle(isHovered: isHovered)
        .onHover(perform: onHover)
    }
}

private struct CleanupCandidateCardRow: View {
    let candidate: CleanupCandidate
    let assessment: SafetyAssessment?
    let diagnostic: SafetyDiagnosticDetail?
    let isHighImpact: Bool
    let isRechecking: Bool
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let onTrash: () -> Void
    let onRecheck: () -> Void
    let onOpenPreview: () -> Void

    private var isReviewable: Bool {
        assessment?.isReviewableForTrash == true
    }

    private var blockedTooltip: String {
        if let diagnostic {
            return "\(diagnostic.headline) (\(diagnostic.checkName)) — \(diagnostic.remediationHint)"
        }
        if isReviewable && isHighImpact {
            return "High-impact cache or environment (excluded from bulk Trash All Ready; can be moved to Trash individually)"
        }
        guard let reasons = assessment?.blockedReasons, !reasons.isEmpty else {
            return candidate.partial ? "Partial measurement — scan hit entry or time budget." : "Ready for macOS Trash."
        }
        return reasons.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: candidate.scope == .agentCache ? "sparkles.rectangle.stack" : "hammer.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(leafGreen)

                Text(candidate.agentName.map { "\($0) · \(candidate.category)" } ?? candidate.category)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)

                if assessment != nil {
                    Button(action: onOpenPreview) {
                        if isReviewable && isHighImpact {
                            statusBadge("Manual Trash", tint: Color(nsColor: .systemOrange))
                        } else {
                            HStack(spacing: 3) {
                                Image(systemName: isReviewable ? "checkmark.shield.fill" : "shield.fill")
                                    .font(.system(size: 8.5))
                                Text(isReviewable ? "Ready" : "Protected")
                                    .font(.system(size: 9, weight: .medium))
                            }
                            .foregroundStyle(isReviewable ? leafGreen : Color.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(
                                (isReviewable ? leafGreen : Color.secondary).opacity(0.10),
                                in: Capsule()
                            )
                        }
                    }
                    .buttonStyle(.plain)
                    .help(blockedTooltip)
                }

                Spacer(minLength: 4)

                Text("\(candidate.partial ? "≥ " : "")\(formatBytes(candidate.bytes))")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }

            HStack(alignment: .center, spacing: 8) {
                Text(shortenHomePath(candidate.path))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(candidate.path)

                Spacer(minLength: 4)

                if let allocated = candidate.allocatedBytes, allocated != candidate.bytes {
                    Text("\(formatBytes(allocated)) disk")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: candidate.path)])
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")

                if isReviewable {
                    Button(action: onTrash) {
                        HStack(spacing: 3) {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                            Text("Trash")
                                .font(.system(size: 9.5, weight: .medium))
                        }
                        .foregroundStyle(.red)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red.opacity(0.10), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Move to macOS Trash")
                } else if diagnostic?.canRecheck == true {
                    Button(action: onRecheck) {
                        HStack(spacing: 3) {
                            if isRechecking {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 9.5, weight: .semibold))
                            }
                            Text("Recheck")
                                .font(.system(size: 9.5, weight: .medium))
                        }
                        .foregroundStyle(leafGreen)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(leafGreen.opacity(0.10), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isRechecking)
                    .help(diagnostic?.remediationHint ?? "Recheck safety for this item")
                }
            }

            if !isReviewable, let diagnostic {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text("\(diagnostic.headline) · \(diagnostic.remediationHint)")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .help("\(diagnostic.headline) (\(diagnostic.checkName)): \(diagnostic.remediationHint)")
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .surfaceCardStyle(isHovered: isHovered)
        .onHover(perform: onHover)
    }
}

// MARK: - Formatting & Styling Utilities

private func statusBadge(_ text: String, tint: Color) -> some View {
    Text(text)
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 5.5)
        .padding(.vertical, 1.5)
        .background(tint.opacity(0.11), in: Capsule())
}

private func formatBytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
}

private func shortenHomePath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

private extension View {
    func surfaceCardStyle(isHovered: Bool) -> some View {
        self
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        Color(nsColor: .separatorColor).opacity(isHovered ? 0.95 : 0.45),
                        lineWidth: 0.5
                    )
            )
    }
}
