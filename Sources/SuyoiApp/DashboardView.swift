import AppKit
import SwiftUI
import SuyoiCore

struct DashboardView: View {
    @ObservedObject var model: DashboardModel

    private var accent: Color {
        ThemeStyling.accentColor(for: model.experienceTheme)
    }

    private var activeAgentSelection: AgentObservation? {
        if let selected = model.selectedAgent,
           let refreshed = model.agentRows.first(where: { $0.id == selected.id }) {
            return refreshed
        }
        if let steerID = model.steeringAgentID,
           let matched = model.agentRows.first(where: { $0.id == steerID }) {
            return matched
        }
        return model.filteredAgentRows.first
    }

    private var activeServerSelection: ServerGroup? {
        if let selected = model.selectedServer,
           let refreshed = model.developmentServerGroups.first(where: { $0.id == selected.id }) {
            return refreshed
        }
        return model.filteredDevelopmentServerGroups.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            toolbarRow
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            if let release = model.availableUpdate {
                updateBar(release)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
            Divider()

            Group {
                switch model.tab {
                case .agents:
                    agentsWorkspace
                case .ports:
                    serversWorkspace
                case .quotas:
                    ScrollView {
                        QuotasSectionView(model: model)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                case .cleanup:
                    ScrollView {
                        cleanupSection
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            footer
        }
        .fontDesign(model.themeTokens.usesMonospacedChrome ? .monospaced : .default)
        .frame(width: 700, height: 600)
        .sheet(isPresented: $model.isShowingCleanupPreview) {
            if let report = model.cleanup {
                CleanupPreviewView(
                    report: report,
                    theme: model.experienceTheme,
                    recheckingCandidateIDs: model.recheckingCandidateIDs,
                    trashedHistory: model.trashedHistory,
                    canRestoreItem: { model.canRestoreTrashedItem($0) },
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

    // MARK: - Header & Toolbar

    private var header: some View {
        let agentCount = model.agentRows.count
        let serverCount = model.developmentServerGroups.count
        return HStack(spacing: 8) {
            Image(systemName: model.isParallelBuild ? "leaf.circle.fill" : "leaf.fill")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(accent)

            Text(model.appDisplayName)
                .font(.system(size: 14, weight: .bold))

            Text("·")
                .foregroundStyle(.tertiary)

            Text("\(agentCount) agent\(agentCount == 1 ? "" : "s") · \(serverCount) server\(serverCount == 1 ? "" : "s")")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if !model.pendingApprovals.isEmpty {
                Text("· \(model.pendingApprovals.count) approval\(model.pendingApprovals.count == 1 ? "" : "s") waiting")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .monospacedDigit()
            }

            Spacer()

            if !model.activeWarnings.isEmpty {
                Button {
                    model.isShowingNotesPopover.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10.5))
                        Text("\(model.activeWarnings.count)")
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                    }
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Color(nsColor: .systemOrange).opacity(0.14), in: Capsule())
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
                HStack(spacing: 4) {
                    Image(systemName: model.isPopoverPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .semibold))
                    if model.isPopoverPinned {
                        Text("Pinned")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                }
                .foregroundStyle(model.isPopoverPinned ? accent : .secondary)
                .padding(.horizontal, model.isPopoverPinned ? 7 : 5)
                .frame(height: 22)
                .background(
                    model.isPopoverPinned ? accent.opacity(0.14) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .help(model.isPopoverPinned ? "Pinned: stays open when clicking outside" : "Pin panel: keep open when clicking outside")
            .accessibilityLabel(model.isPopoverPinned ? "Unpin panel" : "Pin panel")
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 8)
    }

    private var toolbarRow: some View {
        HStack(spacing: 10) {
            Picker("Section", selection: $model.tab) {
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
            .frame(width: model.tab == .quotas ? nil : 410)

            if model.tab != .quotas {
                searchBar
            }
        }
    }

    private func segmentedTitle(_ tab: DashboardTab, count: Int?) -> String {
        guard let count else { return tab.rawValue }
        return "\(tab.rawValue) (\(count))"
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(
                model.tab == .agents
                    ? "Filter provider, project, branch, session, PID…"
                    : (model.tab == .ports ? "Filter port, framework, project…" : "Filter caches or build folders…"),
                text: $model.searchQuery
            )
            .textFieldStyle(.plain)
            .font(.system(size: 11.5))
            if !model.searchQuery.isEmpty {
                Button {
                    model.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: ThemeStyling.cardCornerRadius(for: model.experienceTheme), style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ThemeStyling.cardCornerRadius(for: model.experienceTheme), style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 0.6)
        )
    }

    private func updateBar(_ release: AppReleaseInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(accent)
            Text("Suyoi v\(release.version) is available")
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
            Spacer()
            Button {
                model.installAvailableUpdate()
            } label: {
                if model.isInstallingUpdate {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("Updating…")
                            .font(.system(size: 11, weight: .semibold))
                    }
                } else {
                    Text("Update & Relaunch")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(accent)
            .disabled(model.isInstallingUpdate)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            accent.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(accent.opacity(0.35), lineWidth: 0.5)
        )
    }

    private var notesPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Inspection Notes", systemImage: "info.circle.fill")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                Spacer()
            }
            ForEach(Array(model.activeWarnings.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 6) {
                    Circle()
                        .fill(Color(nsColor: .systemOrange))
                        .frame(width: 4.5, height: 4.5)
                        .padding(.top, 5)
                    Text(item)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            Text("Suyoi reports partial or skipped metadata honestly rather than guessing.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 320)
    }

    // MARK: - Two-Column Agents Workspace (Option A)

    private var agentsWorkspace: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !model.pendingApprovals.isEmpty {
                        sectionSubheader(
                            title: "Pending Approvals (\(model.pendingApprovals.count))",
                            trailing: "Approve · session · deny"
                        )
                        ForEach(model.pendingApprovals) { req in
                            let isSafeReadOnly = req.questionOptions.isEmpty && AgentApprovalController.isSafeReadOnlyTool(
                                toolName: req.toolName,
                                command: req.toolName.caseInsensitiveCompare("Bash") == .orderedSame ? req.summary : nil
                            )
                            PendingApprovalCardView(
                                request: req,
                                canAutoApprove: model.canAutoApprove(req),
                                canAutoApproveProjectReadOnly: model.canAutoApprove(req) && isSafeReadOnly && (req.projectPath?.hasPrefix("/") == true),
                                accent: accent,
                                onDecision: { decision in
                                    model.submitApprovalDecision(decision, for: req)
                                },
                                onEnableProjectReadOnly: {
                                    if let path = req.projectPath {
                                        model.enableReadOnlyAutoApproveForProject(path)
                                    }
                                }
                            )
                        }
                    }

                    if !model.autoApprovedSessions.isEmpty {
                        ActiveAutoApproveSessionsBar(
                            grants: model.autoApprovedSessions,
                            accent: accent,
                            onRevoke: { req in
                                model.revokeAutoApproval(req)
                            }
                        )
                    }

                    if !model.worktreeCollisions.isEmpty {
                        WorktreeCollisionWarningBar(
                            collisions: model.worktreeCollisions,
                            onIsolateFirst: { group in
                                if let target = model.agentRows.first(where: { group.agentIDs.contains($0.id) }) {
                                    model.createIsolatedWorktree(for: target)
                                }
                            }
                        )
                    }

                    if !model.orphanToolProcesses.isEmpty {
                        OrphanMCPHelpersBar(
                            orphans: model.orphanToolProcesses,
                            isPerformingAction: model.isPerformingAction,
                            onStopOne: { model.stopOrphanProcess($0) },
                            onStopAll: { model.stopAllOrphanProcesses() }
                        )
                    }

                    sectionSubheader(
                        title: "Coding Agents (\(model.filteredAgentRows.count))",
                        trailing: "Select to inspect & steer"
                    )

                    if model.snapshot != nil {
                        let rows = model.filteredAgentRows
                        if rows.isEmpty {
                            emptyState(
                                model.searchQuery.isEmpty ? "No coding agents running" : "No agents match '\(model.searchQuery)'",
                                detail: "Supported coding agents (Claude Code, Codex, OpenCode, Gemini CLI, Cursor, Windsurf, Aider, Copilot, Goose, Amp, Droid, Kiro) appear here when active.",
                                symbol: "terminal"
                            )
                        } else {
                            let selectedID = activeAgentSelection?.id
                            ForEach(rows, id: \.id) { row in
                                let rowID = "agent-\(row.id)"
                                AgentCardRow(
                                    obs: row,
                                    visualProfile: model.visualProfile(for: row.agentName),
                                    mascotState: model.mascotState(for: row),
                                    theme: model.experienceTheme,
                                    turnPreview: model.turnPreview(for: row),
                                    isAutoApproved: model.isSessionAutoApproved(for: row),
                                    quotaItem: model.combinedQuotaItem(forAgentName: row.agentName),
                                    steerModeLabel: model.steerModeLabel(for: row),
                                    collision: model.collisionGroup(for: row),
                                    diffSummary: model.diffSummary(for: row),
                                    stuckDiagnostic: model.stuckDiagnostic(for: row),
                                    isSelected: selectedID == row.id,
                                    isHovered: model.hoveredRowID == rowID,
                                    onHover: { model.hoveredRowID = $0 ? rowID : (model.hoveredRowID == rowID ? nil : model.hoveredRowID) },
                                    onFocus: { model.focusTerminalOrIDE(for: row) },
                                    onSelectAndSteer: {
                                        model.selectedAgent = row
                                        model.prepareSteerSessions(for: row)
                                    },
                                    onStop: { model.stopAgent(row) },
                                    onSelect: {
                                        model.selectedAgent = row
                                        model.prepareSteerSessions(for: row)
                                    }
                                )
                            }
                        }
                    } else {
                        loadingState
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(width: 390, alignment: .leading)
            }
            .frame(width: 390)
            .clipped()

            Divider()

            Group {
                if let agent = activeAgentSelection {
                    ProcessDetailView(
                        subject: .agent(agent),
                        theme: model.experienceTheme,
                        isEmbedded: true,
                        turnPreview: model.turnPreview(for: agent),
                        steerMode: model.steerMode(for: agent),
                        steerModeLabel: model.steerModeLabel(for: agent),
                        steerSessionTargets: model.steerSessionTargets,
                        selectedSteerSessionID: $model.selectedSteerSessionID,
                        isLoadingSteerSessions: model.isLoadingSteerSessions,
                        canSendSteer: model.canSendSteerPrompt(to: agent),
                        steerPromptText: $model.steerPromptText,
                        isSteering: model.isSteering,
                        isPerformingAction: model.isPerformingAction,
                        snippets: model.allSteeringSnippets,
                        continuationJobs: model.continuationJobs(for: agent),
                        collisionGroup: model.collisionGroup(for: agent),
                        diffSummary: model.diffSummary(for: agent),
                        stuckDiagnostic: model.stuckDiagnostic(for: agent),
                        onPrepareSteerSessions: { model.prepareSteerSessions(for: $0) },
                        onRefreshSteerSessions: { model.reloadSteerSessions(for: $0) },
                        onFocusAgent: { model.focusTerminalOrIDE(for: $0) },
                        onSteerAgent: { model.sendSteerPrompt(to: $0) },
                        onStopAgent: { model.stopAgent($0, force: $1) },
                        onApplySnippet: { model.applySteeringSnippet($0) },
                        onCancelContinuationJob: { model.cancelContinuationJob($0) },
                        onCreateIsolatedWorktree: { model.createIsolatedWorktree(for: $0) },
                        onDismiss: {
                            model.selectedAgent = nil
                            model.resetSteerComposer()
                        }
                    )
                } else {
                    inspectorEmptyState(
                        title: "No Agent Selected",
                        detail: "Select a running coding agent on the left to inspect its project context, recent tool calls, and session steering controls.",
                        symbol: "sidebar.right"
                    )
                }
            }
            .frame(width: 309)
            .background(Color.primary.opacity(0.02))
        }
    }

    // MARK: - Two-Column Servers Workspace (Option A)

    private var serversWorkspace: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    sectionSubheader(
                        title: "Development Servers (\(model.filteredDevelopmentServerGroups.count))",
                        trailing: "Open · copy URL · stop"
                    )
                    if model.snapshot != nil {
                        let devGroups = model.filteredDevelopmentServerGroups
                        let other = model.filteredOtherListeners
                        if devGroups.isEmpty && (other.isEmpty || model.searchQuery.isEmpty) {
                            emptyState(
                                model.searchQuery.isEmpty ? "No development servers active" : "No servers match '\(model.searchQuery)'",
                                detail: "Local Node, Vite, Next.js, Python, Rust, Go, and Swift servers listening on TCP ports are grouped here.",
                                symbol: "network"
                            )
                        } else {
                            let selectedID = activeServerSelection?.id
                            ForEach(devGroups, id: \.id) { group in
                                let rowID = "server-\(group.id)"
                                ServerGroupCardRow(
                                    group: group,
                                    theme: model.experienceTheme,
                                    healthBadge: model.serverHealthBadge(for: group),
                                    namedURL: model.namedServerURL(for: group),
                                    isSelected: selectedID == group.id,
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
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundStyle(.secondary)
                                    Text("\(other.count)")
                                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 5.5)
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(width: 390, alignment: .leading)
            }
            .frame(width: 390)
            .clipped()

            Divider()

            Group {
                if let server = activeServerSelection {
                    ProcessDetailView(
                        subject: .server(server),
                        theme: model.experienceTheme,
                        isEmbedded: true,
                        isPerformingAction: model.isPerformingAction,
                        onOpenServer: { model.openServerInBrowser($0) },
                        onCopyServerURL: { model.copyServerURL($0) },
                        onStopServer: { model.stopServer($0, force: $1) },
                        onDismiss: { model.selectedServer = nil }
                    )
                } else {
                    inspectorEmptyState(
                        title: "No Server Selected",
                        detail: "Select a development server group on the left to inspect its member PIDs, ports, named localhost URL, and deduplicated memory.",
                        symbol: "network"
                    )
                }
            }
            .frame(width: 309)
            .background(Color.primary.opacity(0.02))
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
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accent)
                    .frame(width: 54, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("Open http://localhost:\(listener.port)")

            Text(listener.processName)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(listener.address) · PID \(String(listener.pid))")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(listener.exposure == "All interfaces" ? "All IF" : "Local")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5.5)
                .padding(.vertical, 1.5)
                .background(Color.primary.opacity(0.05), in: Capsule())

            Button {
                model.stopListener(listener)
            } label: {
                Image(systemName: "stop.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.red.opacity(0.85))
            }
            .buttonStyle(.plain)
            .disabled(model.isPerformingAction)
            .help("Stop \(listener.processName) (PID \(String(listener.pid)))")
            .accessibilityLabel("Stop \(listener.processName)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .themedSurfaceCard(theme: model.experienceTheme, isHovered: false)
    }

    // MARK: - Storage Section

    private var cleanupSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                if model.cleanup != nil {
                    ForEach(CleanupScopeFilter.allCases, id: \.self) { filter in
                        Button {
                            model.cleanupFilter = filter
                        } label: {
                            Text(filter.rawValue)
                                .font(.system(size: 11.5, weight: model.cleanupFilter == filter ? .semibold : .medium))
                                .foregroundStyle(model.cleanupFilter == filter ? accent : .secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    model.cleanupFilter == filter ? accent.opacity(0.14) : Color.primary.opacity(0.05),
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
                        .font(.system(size: 11.5, weight: .medium))
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
                        Label("Safety Preview", systemImage: "shield.lefthalf.filled")
                            .font(.system(size: 11.5, weight: .medium))
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
                                .font(.system(size: 11.5, weight: .medium))
                        }
                    } else {
                        Label(model.cleanup == nil ? "Scan" : "Rescan", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(accent)
                .disabled(model.isScanning)
            }

            if !model.trashedHistory.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Recently Moved to Trash (\(model.trashedHistory.count))", systemImage: "arrow.uturn.backward.circle.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(accent)
                        Spacer()
                    }
                    ForEach(model.trashedHistory.prefix(3)) { item in
                        let restorable = model.canRestoreTrashedItem(item)
                        HStack(spacing: 8) {
                            Text(URL(fileURLWithPath: item.originalPath).lastPathComponent)
                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                .lineLimit(1)
                            Text("· \(item.category)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text("· \(shortenHomePath(item.originalPath))")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(item.originalPath)
                            Spacer()
                            Button {
                                model.restoreTrashedItem(item)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: restorable ? "arrow.uturn.backward" : "exclamationmark.circle")
                                        .font(.system(size: 10, weight: .semibold))
                                    Text(restorable ? "Put Back" : "Unavailable")
                                        .font(.system(size: 10.5, weight: .semibold))
                                }
                                .foregroundStyle(restorable ? accent : .secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background((restorable ? accent : Color.secondary).opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(model.isPerformingAction || !restorable)
                            .help(
                                restorable
                                    ? "Restore \(shortenHomePath(item.originalPath)) from macOS Trash"
                                    : "Put Back unavailable: original and trashed item identity evidence could not be verified"
                            )
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .themedSurfaceCard(theme: model.experienceTheme, isHovered: false)
            }

            if !model.staleSessionLogs.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(model.staleSessionLogs.count) session log\(model.staleSessionLogs.count == 1 ? "" : "s") older than \(model.sessionLogRetentionDays)d (\(formatBytes(model.totalStaleSessionLogBytes)))")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Older session logs; usage is checked before moving to macOS Trash.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        model.trashAllStaleSessionLogs()
                    } label: {
                        Label("Move Aged Logs to Trash", systemImage: "trash")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.isPerformingAction)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .themedSurfaceCard(theme: model.experienceTheme, isHovered: false)
            }

            if let report = model.cleanup {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Text("\(formatBytes(model.totalCleanupBytes)) observed")
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(accent)
                        Text("· \(model.reviewableCleanupCandidates.count) ready (\(report.discoveredCount) total)")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !model.reviewableCleanupCandidates.isEmpty {
                        Button {
                            model.selectAllReviewableCandidates()
                        } label: {
                            Text(model.selectedReviewableCandidates.count == model.reviewableCleanupCandidates.count ? "Deselect All" : "Select Ready")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        if !model.selectedReviewableCandidates.isEmpty {
                            Button {
                                model.trashSelectedCandidates()
                            } label: {
                                Label("Trash Selected (\(model.selectedReviewableCandidates.count) · \(formatBytes(model.selectedReviewableBytes)))", systemImage: "trash")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(accent)
                            .disabled(model.isPerformingAction)
                        } else {
                            Button {
                                model.trashAllReviewable()
                            } label: {
                                Label("Trash Ready (\(formatBytes(model.totalReviewableBytes)))", systemImage: "trash")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(accent)
                            .disabled(model.isPerformingAction)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

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
                            theme: model.experienceTheme,
                            assessment: model.assessment(for: candidate),
                            diagnostic: model.diagnosticDetail(for: candidate),
                            isHighImpact: model.isHighImpactCandidate(candidate),
                            isSelected: model.isCandidateSelected(candidate),
                            isRechecking: model.recheckingCandidateIDs.contains(candidate.id),
                            isPerformingAction: model.isPerformingAction,
                            isHovered: model.hoveredRowID == rowID,
                            onHover: { model.hoveredRowID = $0 ? rowID : (model.hoveredRowID == rowID ? nil : model.hoveredRowID) },
                            onToggleSelect: { model.toggleCandidateSelection(candidate) },
                            onTrash: { model.trashCandidate(candidate) },
                            onRecheck: { model.recheckCandidate(candidate) },
                            onOpenPreview: { model.isShowingCleanupPreview = true }
                        )
                    }
                }
            } else if !model.isScanning {
                emptyState(
                    "Ready for storage scan & cleanup",
                    detail: "Finds generated build folders in \(model.cleanupRootDisplayPath) and allowlisted agent caches (Codex, Claude, OpenCode, Cursor, npm, Cargo, Poetry) so you can move them safely to macOS Trash.",
                    symbol: "externaldrive.badge.checkmark"
                )
            }
        }
    }

    // MARK: - Shared Helpers & Footer

    private func sectionSubheader(title: String, trailing: String) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            Spacer()
            Text(trailing)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 2)
    }

    private var loadingState: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Inspecting local workspace…")
                .font(.system(size: 12))
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
                    .foregroundStyle(accent)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedSurfaceCard(theme: model.experienceTheme, isHovered: false)
    }

    private func inspectorEmptyState(title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.6)
            HStack(spacing: 8) {
                Circle()
                    .fill(model.isSnapshotStale ? Color.orange : accent)
                    .frame(width: 6, height: 6)
                Text(
                    model.isRefreshing
                        ? "Refreshing…"
                        : model.snapshot.map { "Updated \($0.capturedAt.formatted(date: .omitted, time: .shortened))\(model.isSnapshotStale ? " · stale" : "")" }
                            ?? "Not yet inspected"
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)

                if let banner = model.actionBanner {
                    HStack(spacing: 5) {
                        Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(banner.isError ? Color(nsColor: .systemOrange) : Color(nsColor: .systemGreen))
                        Text(banner.message)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Button {
                            model.actionBanner = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss message")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        (banner.isError ? Color(nsColor: .systemOrange) : accent).opacity(0.12),
                        in: Capsule()
                    )
                } else {
                    Text("· Safe Trash & SIGTERM")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 4)

                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11.5, weight: .medium))
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
                        .font(.system(size: 12.5))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 22)
                .help("Suyoi menu")
                .accessibilityLabel("Suyoi menu")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Approval & Active Grant Subviews

private struct PendingApprovalCardView: View {
    let request: PendingApprovalRequest
    let canAutoApprove: Bool
    var canAutoApproveProjectReadOnly: Bool = false
    let accent: Color
    let onDecision: (ApprovalDecision) -> Void
    var onEnableProjectReadOnly: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: request.questionOptions.isEmpty ? "hand.raised.fill" : "questionmark.bubble.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                Text(request.agentName)
                    .font(.system(size: 13, weight: .bold))
                statusBadge(request.toolName, tint: Color(nsColor: .systemOrange))
                Spacer()
                if let pid = request.pid {
                    Text(verbatim: "PID \(String(pid))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                if let path = request.projectPath, !path.isEmpty {
                    Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "folder.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                        .help(path)
                }
                Text("Session \(request.sessionID.prefix(16))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(request.summary)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.92))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if !request.questionOptions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(request.questionOptions.prefix(4), id: \.self) { option in
                        Button(option) {
                            onDecision(.answerQuestion(selectedOption: option))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(accent)
                    }
                    Spacer()
                    Button("Dismiss") {
                        onDecision(.deny(reason: "Dismissed"))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                HStack(spacing: 6) {
                    Button {
                        onDecision(.allowOnce)
                    } label: {
                        Label("Approve", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(Color(nsColor: .systemGreen))

                    if canAutoApprove {
                        Button {
                            onDecision(.allowForSession)
                        } label: {
                            Text("Session")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Allow tools for this verified Claude Code session")
                    }

                    if canAutoApproveProjectReadOnly, let onEnableProjectReadOnly {
                        Button {
                            onEnableProjectReadOnly()
                        } label: {
                            Text("Read-Only OK")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Auto-approve verified read-only tools in this project")
                    }

                    Spacer()

                    Button(role: .destructive) {
                        onDecision(.deny(reason: "Denied by user in Suyoi"))
                    } label: {
                        Label("Deny", systemImage: "xmark.circle")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            Color(nsColor: .systemOrange).opacity(0.09),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color(nsColor: .systemOrange).opacity(0.45), lineWidth: 0.8)
        )
    }
}

private struct WorktreeCollisionWarningBar: View {
    let collisions: [WorktreeCollisionGroup]
    let onIsolateFirst: (WorktreeCollisionGroup) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("SHARED WORKTREE COLLISIONS (\(collisions.count))")
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(Color(nsColor: .systemOrange))
            ForEach(collisions) { group in
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                    Text("\(group.projectName) · \(group.agentIDs.count) agents")
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                    if let branch = group.gitBranch {
                        Text("(\(branch))")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button("Isolate Worktree") {
                        onIsolateFirst(group)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("Create a clean sibling git worktree branch and copy its path")
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Color(nsColor: .systemOrange).opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
    }
}

private struct OrphanMCPHelpersBar: View {
    let orphans: [OrphanToolProcess]
    let isPerformingAction: Bool
    let onStopOne: (OrphanToolProcess) -> Void
    let onStopAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("ORPHAN MCP HELPERS (\(orphans.count))")
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                Spacer()
                if orphans.count > 1 {
                    Button("Stop All") {
                        onStopAll()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(isPerformingAction)
                }
            }
            ForEach(orphans.prefix(4)) { orphan in
                HStack(spacing: 6) {
                    Image(systemName: "puzzlepiece.extension.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Text(orphan.kindLabel)
                        .font(.system(size: 11.5, weight: .semibold))
                    Text("· PID \(String(orphan.process.pid)) · \(formatBytes(orphan.process.footprintBytes ?? orphan.process.residentBytes))")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button("Stop") {
                        onStopOne(orphan)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(isPerformingAction)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
    }
}

private struct ActiveAutoApproveSessionsBar: View {
    let grants: [PendingApprovalRequest]
    let accent: Color
    let onRevoke: (PendingApprovalRequest) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("AUTO-APPROVED SESSIONS (\(grants.count))")
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            ForEach(grants) { grant in
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(accent)
                    Text(grant.agentName)
                        .font(.system(size: 11.5, weight: .semibold))
                    if let path = grant.projectPath, !path.isEmpty {
                        Text("· \(URL(fileURLWithPath: path).lastPathComponent)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text("· \(grant.sessionID.prefix(12))")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer()
                    Button("Revoke") {
                        onRevoke(grant)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("Revoke session auto-approval")
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
    }
}

// MARK: - Aligned Compact Agent Row

private struct AgentCardRow: View {
    let obs: AgentObservation
    let visualProfile: AgentClientVisualProfile
    let mascotState: MascotAnimationState
    let theme: SuyoiExperienceTheme
    let turnPreview: SessionTurnPreview?
    let isAutoApproved: Bool
    let quotaItem: CombinedProviderQuotaItem?
    let steerModeLabel: String?
    var collision: WorktreeCollisionGroup? = nil
    var diffSummary: WorktreeDiffSummary? = nil
    var stuckDiagnostic: StuckAgentDiagnostic? = nil
    let isSelected: Bool
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let onFocus: () -> Void
    let onSelectAndSteer: () -> Void
    let onStop: () -> Void
    let onSelect: () -> Void

    private var accent: Color {
        ThemeStyling.accentColor(for: theme)
    }

    private var activityDotTint: Color {
        if obs.process.isStopped || obs.activityState == .stopped {
            return Color(nsColor: .systemOrange)
        }
        switch obs.activityState {
        case .active:
            return Color(nsColor: .systemGreen)
        case .waiting:
            return Color(nsColor: .systemOrange)
        case .idle, nil:
            return .secondary
        case .stopped:
            return Color(nsColor: .systemOrange)
        }
    }

    private var projectAndBranchLine: (title: String, branch: String?, isFallbackPath: Bool) {
        if let project = obs.project {
            let branch = project.gitBranch.map { $0 + (project.isWorktree ? " (wt)" : "") }
            return (project.name, branch, false)
        }
        if let cwd = obs.process.cwd, !cwd.isEmpty {
            if cwd == "/" {
                return ("Desktop daemon (/)", nil, true)
            }
            return (shortenHomePath(cwd), nil, true)
        }
        return ("Workspace not linked", nil, true)
    }

    private var sessionAndTaskLine: String {
        var parts: [String] = []
        if let title = obs.sessionTitle, !title.isEmpty {
            parts.append(title)
        } else if let sid = obs.sessionID, !sid.isEmpty {
            parts.append("Session \(sid.prefix(12))")
        }
        if let task = obs.currentTask, !task.isEmpty {
            parts.append(task)
        } else if let tool = turnPreview?.recentTools.first {
            parts.append("\(tool.toolName)\(tool.targetSummary.map { " · \($0)" } ?? "")")
        } else if let reply = turnPreview?.lastAssistantReplyPreview ?? turnPreview?.lastUserPromptPreview {
            parts.append(reply)
        }
        if parts.isEmpty {
            return "Session not linked · click to inspect"
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let memory = obs.process.footprintBytes ?? obs.process.residentBytes
        let profileAccent = Color(
            red: visualProfile.accentRed,
            green: visualProfile.accentGreen,
            blue: visualProfile.accentBlue
        )
        let projectInfo = projectAndBranchLine
        let portCount = obs.childServerPorts.count

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Button(action: onSelect) {
                    HStack(alignment: .top, spacing: 8) {
                        ZStack(alignment: .bottomTrailing) {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(profileAccent.opacity(0.15))
                                .frame(width: 28, height: 28)
                            Image(systemName: visualProfile.symbolName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(profileAccent)
                                .frame(width: 28, height: 28)
                            Circle()
                                .fill(activityDotTint)
                                .frame(width: 7.5, height: 7.5)
                                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.2))
                                .offset(x: 2, y: 2)
                        }
                        .padding(.top, 1)

                        VStack(alignment: .leading, spacing: 3.5) {
                            // Line 1: Provider + Activity Badge + Concise Port Count Badge
                            HStack(spacing: 5) {
                                Text(obs.agentName)
                                    .font(.system(size: 13.5, weight: .bold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                PixelMascotBadgeView(state: mascotState, theme: theme)

                                if isAutoApproved {
                                    statusBadge("Auto-OK", tint: accent)
                                }

                                if let collision {
                                    statusBadge("\(collision.agentIDs.count) agents", tint: Color(nsColor: .systemOrange))
                                        .help("Shared worktree collision in \(collision.projectName)")
                                }

                                if stuckDiagnostic != nil {
                                    statusBadge("High CPU", tint: Color(nsColor: .systemRed))
                                        .help("Sustained high CPU without turn progress")
                                }

                                if let diff = diffSummary, !diff.isClean {
                                    statusBadge("+\(diff.addedLines) -\(diff.deletedLines)", tint: Color(nsColor: .systemGreen))
                                        .help("\(diff.totalTouchedFiles) uncommitted file(s)")
                                }

                                if portCount == 1, let firstPort = obs.childServerPorts.first {
                                    statusBadge(":\(String(firstPort))", tint: accent)
                                } else if portCount > 1 {
                                    statusBadge("\(portCount) ports", tint: accent)
                                        .help(obs.childServerPorts.map { ":\(String($0))" }.joined(separator: ", "))
                                }
                            }
                            .lineLimit(1)

                            // Line 2: Project / Branch + Terminal Host
                            HStack(spacing: 5) {
                                Image(systemName: projectInfo.isFallbackPath ? "terminal" : "folder.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(projectInfo.isFallbackPath ? .secondary : accent)
                                Text(projectInfo.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .help(obs.project?.rootPath ?? obs.process.cwd ?? projectInfo.title)
                                if let branch = projectInfo.branch {
                                    Text("· \(branch)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .help(branch)
                                }
                                if let terminal = obs.terminalApp {
                                    Text("· \(terminal)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }

                            // Line 3: Validated Session / Active Task Summary
                            Text(sessionAndTaskLine)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)

                            if let quotaItem {
                                CompactAgentQuotaBar(item: quotaItem, theme: theme)
                                    .padding(.top, 1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Dedicated Trailing Action & Resource Column
                VStack(alignment: .trailing, spacing: 5) {
                    HStack(spacing: 6) {
                        if let steerModeLabel {
                            Button(action: onSelectAndSteer) {
                                Image(systemName: "paperplane.fill")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(accent)
                            }
                            .buttonStyle(.plain)
                            .help(steerModeLabel)
                            .accessibilityLabel("Steer \(obs.agentName)")
                        }

                        Button(action: onFocus) {
                            Image(systemName: "macwindow")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(accent)
                        }
                        .buttonStyle(.plain)
                        .help("Focus \(obs.terminalApp ?? "Terminal / IDE") window")
                        .accessibilityLabel("Focus \(obs.agentName)")

                        if obs.process.identity.isActionEligible {
                            Button(action: onStop) {
                                Image(systemName: "stop.circle")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.red.opacity(0.85))
                            }
                            .buttonStyle(.plain)
                            .help("Stop \(obs.agentName) (SIGTERM)")
                            .accessibilityLabel("Stop \(obs.agentName)")
                        }
                    }

                    Text("\(String(format: "%.1f%%", obs.process.cpuPercent)) · \(formatBytes(memory))")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)

                    Text(verbatim: "PID \(String(obs.process.pid))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedSurfaceCard(theme: theme, isHovered: isHovered || isSelected)
        .overlay(
            RoundedRectangle(cornerRadius: ThemeStyling.cardCornerRadius(for: theme), style: .continuous)
                .strokeBorder(isSelected ? accent : Color.clear, lineWidth: isSelected ? 1.5 : 0)
        )
        .onHover(perform: onHover)
    }
}

// MARK: - Aligned Compact Server Row

private struct ServerGroupCardRow: View {
    let group: ServerGroup
    let theme: SuyoiExperienceTheme
    let healthBadge: ServerHealthBadge?
    let namedURL: URL?
    let isSelected: Bool
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let onOpenBrowser: () -> Void
    let onOpenNamedURL: () -> Void
    let onCopyURL: () -> Void
    let onCopyNamedURL: () -> Void
    let onStop: () -> Void
    let onSelect: () -> Void

    private var accent: Color {
        ThemeStyling.accentColor(for: theme)
    }

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

        HStack(alignment: .top, spacing: 10) {
            Button(action: onOpenBrowser) {
                VStack(spacing: 1) {
                    Text(primaryPort)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(accent)
                    if extraCount > 0 {
                        Text("+\(extraCount) more")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(accent.opacity(0.85))
                    }
                }
                .frame(width: 58, height: 34)
                .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Open http://localhost\(primaryPort) in browser")

            Button(action: onSelect) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3.5) {
                        HStack(spacing: 5) {
                            Text(group.project?.name ?? group.name)
                                .font(.system(size: 13.5, weight: .bold))
                                .lineLimit(1)
                            if let framework = group.project?.framework {
                                statusBadge(framework, tint: accent)
                            }
                            if let healthBadge {
                                statusBadge(healthBadge.label, tint: badgeTint(for: healthBadge))
                                    .help(healthBadge.detail)
                            }
                        }

                        if let namedURL, let host = namedURL.host, let port = namedURL.port {
                            HStack(spacing: 5) {
                                Image(systemName: "link")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(accent)
                                Text("\(host):\(port)")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(accent)
                                    .lineLimit(1)
                            }
                        }

                        HStack(spacing: 5) {
                            if let branch = group.project?.gitBranch {
                                Text("\(branch)\(group.project?.isWorktree == true ? " (wt)" : "") ·")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Text("\(group.name) · PID \(String(group.rootPID))")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .trailing, spacing: 5) {
                HStack(spacing: 6) {
                    Button(action: onOpenBrowser) {
                        Image(systemName: "globe")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(accent)
                    }
                    .buttonStyle(.plain)
                    .help("Open in Browser")

                    Button(action: onCopyURL) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy localhost URL")

                    Button(action: onStop) {
                        Image(systemName: "stop.circle")
                            .font(.system(size: 12))
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
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedSurfaceCard(theme: theme, isHovered: isHovered || isSelected)
        .overlay(
            RoundedRectangle(cornerRadius: ThemeStyling.cardCornerRadius(for: theme), style: .continuous)
                .strokeBorder(isSelected ? accent : Color.clear, lineWidth: isSelected ? 1.5 : 0)
        )
        .onHover(perform: onHover)
    }
}

// MARK: - Storage Candidate Row

private struct CleanupCandidateCardRow: View {
    let candidate: CleanupCandidate
    let theme: SuyoiExperienceTheme
    let assessment: SafetyAssessment?
    let diagnostic: SafetyDiagnosticDetail?
    let isHighImpact: Bool
    let isSelected: Bool
    let isRechecking: Bool
    let isPerformingAction: Bool
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let onToggleSelect: () -> Void
    let onTrash: () -> Void
    let onRecheck: () -> Void
    let onOpenPreview: () -> Void

    private var accent: Color {
        ThemeStyling.accentColor(for: theme)
    }

    private var isReviewable: Bool {
        assessment?.isReviewableForTrash == true
    }

    private var blockedTooltip: String {
        if let diagnostic {
            return "\(diagnostic.headline) (\(diagnostic.checkName)) — \(diagnostic.remediationHint)"
        }
        if isReviewable && isHighImpact {
            return "High-impact cache or environment (excluded from bulk Trash Ready; can be moved to Trash individually)"
        }
        guard let reasons = assessment?.blockedReasons, !reasons.isEmpty else {
            return candidate.partial ? "Partial measurement — scan hit entry or time budget." : "Ready for macOS Trash."
        }
        return reasons.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 7) {
                if isReviewable {
                    Button(action: onToggleSelect) {
                        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(isSelected ? accent : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isSelected ? "Deselect item" : "Select item for batch Trash")
                }

                Image(systemName: candidate.scope == .agentCache ? "sparkles.rectangle.stack" : "hammer.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(accent)

                Text(candidate.agentName.map { "\($0) · \(candidate.category)" } ?? candidate.category)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                if assessment != nil {
                    Button(action: onOpenPreview) {
                        if isReviewable && isHighImpact {
                            statusBadge("Manual Trash", tint: Color(nsColor: .systemOrange))
                        } else {
                            HStack(spacing: 3.5) {
                                Image(systemName: isReviewable ? "checkmark.shield.fill" : "shield.fill")
                                    .font(.system(size: 9.5))
                                Text(isReviewable ? "Ready" : "Protected")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundStyle(isReviewable ? accent : Color.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(
                                (isReviewable ? accent : Color.secondary).opacity(0.12),
                                in: Capsule()
                            )
                        }
                    }
                    .buttonStyle(.plain)
                    .help(blockedTooltip)
                }

                Spacer(minLength: 4)

                Text("\(candidate.partial ? "≥ " : "")\(formatBytes(candidate.bytes))")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }

            HStack(alignment: .center, spacing: 8) {
                Text(shortenHomePath(candidate.path))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(candidate.path)

                Spacer(minLength: 4)

                if let allocated = candidate.allocatedBytes, allocated != candidate.bytes {
                    Text("\(formatBytes(allocated)) disk")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: candidate.path)])
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")

                if isReviewable {
                    Button(action: onTrash) {
                        HStack(spacing: 3.5) {
                            Image(systemName: "trash")
                                .font(.system(size: 10.5))
                            Text("Trash")
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        .foregroundStyle(.red)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Color.red.opacity(0.10), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isPerformingAction)
                    .help("Move to macOS Trash")
                } else if diagnostic?.canRecheck == true {
                    Button(action: onRecheck) {
                        HStack(spacing: 3.5) {
                            if isRechecking {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            Text("Recheck")
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        .foregroundStyle(accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(accent.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isRechecking || isPerformingAction)
                    .help(diagnostic?.remediationHint ?? "Recheck safety for this item")
                }
            }

            if !isReviewable, let diagnostic {
                HStack(spacing: 5) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(diagnostic.headline)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .help("\(diagnostic.headline) (\(diagnostic.checkName)): \(diagnostic.remediationHint)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .themedSurfaceCard(theme: theme, isHovered: isHovered)
        .onHover(perform: onHover)
    }
}

// MARK: - Formatting & Styling Utilities

private func statusBadge(_ text: String, tint: Color) -> some View {
    Text(text)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background(tint.opacity(0.12), in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
}

private func formatBytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
}

private func shortenHomePath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}
