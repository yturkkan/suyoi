import AppKit
import SwiftUI
import SuyoiCore

struct AgentsConsoleView: View {
    @ObservedObject var model: DashboardModel

    private var accent: Color {
        ThemeStyling.accentColor(for: model.experienceTheme)
    }

    private var availableProviders: [SessionProviderKind] {
        var present = Set(model.indexedSessions.map(\.provider))
        let ordered: [SessionProviderKind] = [.claude, .codex, .openCode, .cursor, .gemini, .other]
        let filtered = ordered.filter { present.remove($0) != nil }
        return filtered.isEmpty ? [.claude, .codex, .openCode, .cursor, .gemini] : filtered
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            sessionSidebar
                .frame(width: 325)
                .clipped()

            Divider()

            conversationConsole
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.02))
        }
    }

    // MARK: - Left Sidebar (Alerts + Live & Historical Session List)

    private var sessionSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    scopePill(.all, title: "All", count: model.indexedSessions.count)
                    scopePill(.live, title: "Live", count: model.liveSessionsCount)
                    scopePill(.history, title: "History", count: model.historySessionsCount)
                    Spacer()
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        providerChip(nil, label: "All Providers")
                        ForEach(availableProviders, id: \.self) { provider in
                            providerChip(provider, label: provider.shortLabel)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.primary.opacity(0.015))

            Divider().opacity(0.6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if !model.pendingApprovals.isEmpty {
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
                            onRevoke: { model.revokeAutoApproval($0) }
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

                    let sessions = model.filteredIndexedSessions
                    if sessions.isEmpty {
                        emptySidebarState
                    } else {
                        let activeID = model.activeSelectedSession?.id
                        ForEach(sessions) { session in
                            let rowID = "session-\(session.id)"
                            SessionSidebarCard(
                                session: session,
                                visualProfile: model.visualProfile(for: session.agentName),
                                theme: model.experienceTheme,
                                diffSummary: session.projectPath.flatMap { model.worktreeDiffs[$0] },
                                collision: session.liveObservation.flatMap { model.collisionGroup(for: $0) },
                                stuckDiagnostic: session.liveObservation.flatMap { model.stuckDiagnostic(for: $0) },
                                isSelected: activeID == session.id,
                                isHovered: model.hoveredRowID == rowID,
                                onHover: { hovering in
                                    model.hoveredRowID = hovering ? rowID : (model.hoveredRowID == rowID ? nil : model.hoveredRowID)
                                },
                                onSelect: {
                                    model.selectIndexedSession(session)
                                }
                            )
                        }
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
            }
        }
    }

    private func scopePill(_ filter: AgentSessionScopeFilter, title: String, count: Int) -> some View {
        let selected = model.sessionScopeFilter == filter
        return Button {
            model.sessionScopeFilter = filter
        } label: {
            HStack(spacing: 4) {
                if filter == .live && count > 0 {
                    Circle()
                        .fill(Color(nsColor: .systemGreen))
                        .frame(width: 6, height: 6)
                }
                Text(title)
                    .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .opacity(selected ? 0.95 : 0.7)
            }
            .foregroundStyle(selected ? accent : .secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                selected ? accent.opacity(0.15) : Color.primary.opacity(0.05),
                in: Capsule()
            )
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
    }

    private func providerChip(_ provider: SessionProviderKind?, label: String) -> some View {
        let selected = model.sessionProviderFilter == provider
        return Button {
            model.sessionProviderFilter = provider
        } label: {
            Text(label)
                .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? accent : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    selected ? accent.opacity(0.14) : Color.primary.opacity(0.04),
                    in: Capsule()
                )
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
    }

    private var emptySidebarState: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accent)
                Text(model.searchQuery.isEmpty ? "No matching sessions" : "No sessions match '\(model.searchQuery)'")
                    .font(.system(size: 12.5, weight: .semibold))
            }
            Text("Suyoi indexes live terminal agents and workspace history from Claude Code, Codex, OpenCode, Cursor, and Gemini CLI.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedSurfaceCard(theme: model.experienceTheme, isHovered: false)
    }

    // MARK: - Right Conversation & Steering Console

    @ViewBuilder
    private var conversationConsole: some View {
        if let session = model.activeSelectedSession {
            VStack(spacing: 0) {
                sessionHeader(for: session)
                Divider().opacity(0.65)
                conversationTimeline(for: session)
                Divider().opacity(0.65)
                steeringComposer(for: session)
            }
        } else {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Select an Agent Session")
                    .font(.system(size: 14, weight: .semibold))
                Text("Choose a live terminal agent or recent workspace session on the left to inspect its multi-turn conversation, tool calls, and send steering instructions.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func sessionHeader(for session: IndexedAgentSession) -> some View {
        let profile = model.visualProfile(for: session.agentName)
        let profileTint = Color(red: profile.accentRed, green: profile.accentGreen, blue: profile.accentBlue)
        let diff = session.projectPath.flatMap { model.worktreeDiffs[$0] }
        let collision = session.liveObservation.flatMap { model.collisionGroup(for: $0) }

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: profile.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(profileTint)
                    .frame(width: 24, height: 24)
                    .background(profileTint.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                Text(session.title)
                    .font(.system(size: 13.5, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(session.title)

                statusBadge(session.provider.rawValue, tint: profileTint)

                if let obs = session.liveObservation {
                    liveStateBadge(for: obs)
                } else {
                    statusBadge("History", tint: .secondary)
                }

                Spacer(minLength: 6)

                Button {
                    model.reloadSelectedSessionTurns()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Reload session transcript from disk")

                if let obs = session.liveObservation {
                    Button {
                        model.focusTerminalOrIDE(for: obs)
                    } label: {
                        Label(obs.terminalApp ?? "Focus", systemImage: "macwindow")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Bring \(obs.terminalApp ?? "Terminal / IDE") to front")

                    if collision != nil {
                        Button {
                            model.createIsolatedWorktree(for: obs)
                        } label: {
                            Label("Isolate Worktree", systemImage: "arrow.triangle.branch")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.isPerformingAction)
                    }

                    if obs.process.identity.isActionEligible {
                        Button(role: .destructive) {
                            model.stopAgent(obs)
                        } label: {
                            Image(systemName: "stop.circle")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.isPerformingAction)
                        .help("Stop \(obs.agentName) (PID \(obs.process.pid))")
                    }
                }
            }

            HStack(spacing: 8) {
                if let projectPath = session.projectPath, !projectPath.isEmpty {
                    Button {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: projectPath)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 10.5))
                                .foregroundStyle(accent)
                            Text(shortenHomePath(projectPath))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.primary.opacity(0.9))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Open \(projectPath) in Finder")
                } else {
                    Text(session.projectName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                if let branch = session.gitBranch, !branch.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 9.5))
                        Text(branch)
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Color.primary.opacity(0.05), in: Capsule())
                }

                if let diff, !diff.isClean {
                    statusBadge("+\(diff.addedLines) -\(diff.deletedLines) (\(diff.totalTouchedFiles)f)", tint: Color(nsColor: .systemGreen))
                        .help(diff.sampleFiles.joined(separator: "\n"))
                }

                Spacer(minLength: 4)

                if let obs = session.liveObservation {
                    let mem = obs.process.footprintBytes ?? obs.process.residentBytes
                    Text("PID \(String(obs.process.pid)) · \(String(format: "%.1f%%", obs.process.cpuPercent)) · \(formatBytes(mem))")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                } else if let sid = session.sessionID, !sid.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(sid, forType: .string)
                    } label: {
                        HStack(spacing: 3.5) {
                            Text("ID \(sid.prefix(10))")
                                .font(.system(size: 10.5, design: .monospaced))
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 9.5))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy Session ID: \(sid)")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.02))
    }

    private func liveStateBadge(for obs: AgentObservation) -> some View {
        switch obs.activityState {
        case .active:
            return statusBadge("Working", tint: Color(nsColor: .systemGreen))
        case .waiting:
            return statusBadge("Waiting", tint: Color(nsColor: .systemOrange))
        case .stopped:
            return statusBadge("Stopped", tint: Color(nsColor: .systemOrange))
        case .idle, nil:
            return statusBadge("Live · Idle", tint: accent)
        }
    }

    // MARK: - Scrollable Multi-Turn Conversation & Tool Stream

    private func conversationTimeline(for session: IndexedAgentSession) -> some View {
        let jobs = model.activeContinuationJobs(for: session)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 9) {
                    if model.isLoadingSessionTurns && model.selectedSessionTurns.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading conversation transcript…")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 36)
                    } else if model.selectedSessionTurns.isEmpty {
                        emptyConversationState(for: session)
                    } else {
                        ForEach(model.selectedSessionTurns) { turn in
                            ConversationTurnBubble(
                                turn: turn,
                                agentName: session.agentName,
                                accent: accent,
                                theme: model.experienceTheme
                            )
                            .id(turn.id)
                        }
                    }

                    ForEach(jobs) { job in
                        ContinuationJobCard(
                            job: job,
                            accent: accent,
                            onCancel: { model.cancelContinuationJob(job) }
                        )
                        .id("job-\(job.id.uuidString)")
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("console-bottom-anchor")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .onAppear {
                proxy.scrollTo("console-bottom-anchor", anchor: .bottom)
            }
            .onChange(of: session.id) { _, _ in
                proxy.scrollTo("console-bottom-anchor", anchor: .bottom)
            }
            .onChange(of: model.selectedSessionTurns.count) { _, _ in
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("console-bottom-anchor", anchor: .bottom)
                }
            }
        }
    }

    private func emptyConversationState(for session: IndexedAgentSession) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accent)
                Text(session.isLive ? "Live agent ready for steering" : "Session metadata indexed")
                    .font(.system(size: 12.5, weight: .semibold))
            }
            if let snippet = session.lastMessageSnippet, !snippet.isEmpty {
                Text(snippet)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary.opacity(0.9))
                    .textSelection(.enabled)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Text("No multi-turn transcript entries were recorded in the local session file yet. Send an instruction below to steer or resume this session.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedSurfaceCard(theme: model.experienceTheme, isHovered: false)
    }

    // MARK: - Multi-Line Steering & Resume Composer

    private func steeringComposer(for session: IndexedAgentSession) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                deliveryModeControl(for: session)

                Divider()
                    .frame(height: 14)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(model.allSteeringSnippets) { snippet in
                            Button {
                                model.applySnippetToConsole(snippet)
                            } label: {
                                Text(snippet.trigger)
                                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(accent)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2.5)
                                    .background(accent.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(!session.canSendInstruction)
                            .help("\(snippet.title): \(snippet.prompt)")
                        }
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $model.consoleComposerText)
                        .font(.system(size: 12))
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                        .frame(height: 60)
                        .disabled(!session.canSendInstruction || model.isSteering)

                    if model.consoleComposerText.isEmpty {
                        Text(composerPlaceholder(for: session))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                }
                .background(
                    Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.75), lineWidth: 0.7)
                )

                Button {
                    model.sendConsoleInstruction(to: session)
                } label: {
                    HStack(spacing: 5) {
                        if model.isSteering {
                            ProgressView().controlSize(.mini)
                            Text("Sending…")
                        } else {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 11.5, weight: .semibold))
                            Text(sendButtonTitle(for: session))
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!model.canSendConsoleInstruction(to: session))
                .help("Send instruction (⌘Return)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.025))
    }

    @ViewBuilder
    private func deliveryModeControl(for session: IndexedAgentSession) -> some View {
        if session.canSteerInLiveTerminal && session.canResumeNatively {
            HStack(spacing: 3) {
                Button {
                    model.preferLiveTerminalSteer = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 9.5))
                        Text(liveTerminalShortLabel(for: session))
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(model.preferLiveTerminalSteer ? Color(nsColor: .systemGreen) : .secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        model.preferLiveTerminalSteer ? Color(nsColor: .systemGreen).opacity(0.15) : Color.clear,
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)

                Button {
                    model.preferLiveTerminalSteer = false
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.system(size: 9.5))
                        Text("CLI Resume")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(!model.preferLiveTerminalSteer ? accent : .secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        !model.preferLiveTerminalSteer ? accent.opacity(0.15) : Color.clear,
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(2)
            .background(Color.primary.opacity(0.05), in: Capsule())
            .fixedSize(horizontal: true, vertical: false)
        } else if session.canSteerInLiveTerminal {
            statusBadge("Live · \(liveTerminalShortLabel(for: session))", tint: Color(nsColor: .systemGreen))
        } else if session.canResumeNatively {
            statusBadge("CLI Resume · \(session.provider.shortLabel)", tint: accent)
        } else {
            statusBadge("Transcript View Only", tint: .secondary)
        }
    }

    private func liveTerminalShortLabel(for session: IndexedAgentSession) -> String {
        if let obs = session.liveObservation {
            if let term = obs.terminalApp, let tty = obs.process.tty {
                return "\(term) (\(tty))"
            }
            return obs.terminalApp ?? obs.process.tty ?? "Terminal"
        }
        return "Terminal"
    }

    private func sendButtonTitle(for session: IndexedAgentSession) -> String {
        if session.canSteerInLiveTerminal && (!session.canResumeNatively || model.preferLiveTerminalSteer) {
            return "Steer"
        }
        if session.canResumeNatively {
            return session.isLive ? "Continue" : "Resume"
        }
        return "Send"
    }

    private func composerPlaceholder(for session: IndexedAgentSession) -> String {
        if session.canSteerInLiveTerminal && (!session.canResumeNatively || model.preferLiveTerminalSteer) {
            return "Send instruction directly to live \(liveTerminalShortLabel(for: session)) session… (⌘↩ to send)"
        }
        if session.canResumeNatively {
            return "Resume \(session.provider.rawValue) session in \(session.projectName) with a new prompt… (⌘↩ to send)"
        }
        return "Direct CLI steering is not available for \(session.provider.rawValue) desktop sessions."
    }
}

// MARK: - Sidebar Session Row Card (Zero Provider Truncation)

private struct SessionSidebarCard: View {
    let session: IndexedAgentSession
    let visualProfile: AgentClientVisualProfile
    let theme: SuyoiExperienceTheme
    let diffSummary: WorktreeDiffSummary?
    let collision: WorktreeCollisionGroup?
    let stuckDiagnostic: StuckAgentDiagnostic?
    let isSelected: Bool
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let onSelect: () -> Void

    private var accent: Color {
        ThemeStyling.accentColor(for: theme)
    }

    private var profileTint: Color {
        Color(red: visualProfile.accentRed, green: visualProfile.accentGreen, blue: visualProfile.accentBlue)
    }

    private var statusDotColor: Color {
        guard let obs = session.liveObservation else {
            return .secondary.opacity(0.45)
        }
        switch obs.activityState {
        case .active: return Color(nsColor: .systemGreen)
        case .waiting: return Color(nsColor: .systemOrange)
        case .stopped: return Color(nsColor: .systemOrange)
        case .idle, nil: return accent
        }
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 5) {
                // Row 1: Untruncated Provider Name + Live Status or Relative Time
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusDotColor)
                        .frame(width: 7, height: 7)

                    Image(systemName: visualProfile.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(profileTint)

                    Text(session.provider.rawValue)
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(profileTint)
                        .fixedSize(horizontal: true, vertical: false)

                    if stuckDiagnostic != nil {
                        statusBadge("Stuck CPU", tint: Color(nsColor: .systemRed))
                    } else if collision != nil {
                        statusBadge("Collision", tint: Color(nsColor: .systemOrange))
                    }

                    Spacer(minLength: 4)

                    trailingStateView
                }

                // Row 2: Session Title (up to 2 readable lines)
                Text(session.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Row 3: Project Name + Git Branch + Diff Pill
                HStack(spacing: 5) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(accent.opacity(0.9))
                    Text(session.projectName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let branch = session.gitBranch, !branch.isEmpty {
                        Text("· \(branch)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 2)

                    if let diff = diffSummary, !diff.isClean {
                        Text("+\(diff.addedLines) -\(diff.deletedLines)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color(nsColor: .systemGreen))
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }

                // Row 4: Active Task or Last Message Preview
                if let subtitle = session.liveObservation?.currentTask ?? session.lastMessageSnippet, !subtitle.isEmpty {
                    Text(subtitle.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .themedSurfaceCard(theme: theme, isHovered: isHovered || isSelected)
        .overlay(
            RoundedRectangle(cornerRadius: ThemeStyling.cardCornerRadius(for: theme), style: .continuous)
                .strokeBorder(isSelected ? accent : Color.clear, lineWidth: isSelected ? 1.5 : 0)
        )
        .onHover(perform: onHover)
    }

    @ViewBuilder
    private var trailingStateView: some View {
        if let obs = session.liveObservation {
            switch obs.activityState {
            case .active:
                statusBadge("Working", tint: Color(nsColor: .systemGreen))
            case .waiting:
                statusBadge("Waiting", tint: Color(nsColor: .systemOrange))
            case .stopped:
                statusBadge("Stopped", tint: Color(nsColor: .systemOrange))
            case .idle, nil:
                statusBadge("Live", tint: accent)
            }
        } else if let date = session.updatedAt {
            Text(relativeAgeString(from: date))
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func relativeAgeString(from date: Date) -> String {
        let delta = max(0, Int(Date().timeIntervalSince(date)))
        if delta < 60 { return "just now" }
        if delta < 3_600 { return "\(delta / 60)m ago" }
        if delta < 86_400 { return "\(delta / 3_600)h ago" }
        return "\(delta / 86_400)d ago"
    }
}

// MARK: - Conversation Turn Bubbles (.user, .toolCall, .assistant)

private struct ConversationTurnBubble: View {
    let turn: SessionChatTurn
    let agentName: String
    let accent: Color
    let theme: SuyoiExperienceTheme

    var body: some View {
        switch turn.kind {
        case .user:
            userBubble
        case .toolCall:
            toolCallCard
        case .assistant:
            assistantCard
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 36)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(accent)
                    Text("You")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(accent)
                    Spacer()
                    if let ts = turn.timestamp {
                        Text(ts.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                Text(turn.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(accent.opacity(0.32), lineWidth: 0.7)
            )
        }
    }

    private var toolCallCard: some View {
        let statusLower = (turn.toolStatus ?? "completed").lowercased()
        let isRunning = statusLower.contains("run")
        let isFailed = statusLower.contains("fail") || statusLower.contains("err")
        let tint: Color = isFailed
            ? Color(nsColor: .systemOrange)
            : (isRunning ? Color(nsColor: .systemGreen) : .secondary)

        return HStack(spacing: 8) {
            Image(systemName: toolSymbol(for: turn.toolName))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))

            Text(turn.toolName ?? "Tool")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.9))
                .fixedSize(horizontal: true, vertical: false)

            Text(turn.text.replacingOccurrences(of: "\n", with: " "))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(turn.text)

            Spacer(minLength: 4)

            if isRunning {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("running")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .systemGreen))
                }
            } else {
                Image(systemName: isFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(isFailed ? Color(nsColor: .systemOrange) : Color(nsColor: .systemGreen).opacity(0.8))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.6)
        )
    }

    private var assistantCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(accent)
                Text(agentName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.primary.opacity(0.9))
                Spacer()
                if let ts = turn.timestamp {
                    Text(ts.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            Text(turn.text)
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.94))
                .lineSpacing(2.5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedSurfaceCard(theme: theme, isHovered: false)
    }

    private func toolSymbol(for toolName: String?) -> String {
        let lower = (toolName ?? "").lowercased()
        if lower.contains("bash") || lower.contains("exec") || lower.contains("shell") || lower.contains("swift") || lower.contains("npm") || lower.contains("cargo") {
            return "terminal.fill"
        }
        if lower.contains("read") || lower.contains("grep") || lower.contains("search") || lower.contains("glob") {
            return "doc.text.magnifyingglass"
        }
        if lower.contains("edit") || lower.contains("write") || lower.contains("patch") {
            return "pencil.line"
        }
        return "wrench.and.screwdriver.fill"
    }
}

private struct ContinuationJobCard: View {
    let job: NativeContinuationJob
    let accent: Color
    let onCancel: () -> Void

    private var stateLabel: String {
        switch job.state {
        case .running: return "Running"
        case .completed: return "Completed"
        case .failed(let exitCode): return "Failed (exit \(exitCode))"
        case .cancelled: return "Cancelled"
        }
    }

    var body: some View {
        let isRunning = job.state == .running
        let tint: Color = isRunning
            ? accent
            : (job.state == .completed ? Color(nsColor: .systemGreen) : Color(nsColor: .systemOrange))

        return HStack(spacing: 8) {
            if isRunning {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: job.state == .completed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("\(job.agentName) background continuation · \(stateLabel)")
                    .font(.system(size: 11.5, weight: .semibold))
                Text("\(job.executableName) (PID \(String(job.pid))) · session \(job.sessionID.prefix(12))")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isRunning {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tint.opacity(0.30), lineWidth: 0.7)
        )
    }
}
