import AppKit
import SwiftUI
import SuyoiCore

struct ProcessDetailView: View {
    enum Subject {
        case agent(AgentObservation)
        case server(ServerGroup)
    }

    let subject: Subject
    var theme: SuyoiExperienceTheme = .nativeGlass
    var isEmbedded: Bool = false
    let turnPreview: SessionTurnPreview?
    let steerMode: AgentSteerMode?
    let steerModeLabel: String?
    let steerSessionTargets: [NativeSessionTarget]
    @Binding var selectedSteerSessionID: String?
    let isLoadingSteerSessions: Bool
    let canSendSteer: Bool
    @Binding var steerPromptText: String
    let isSteering: Bool
    let isPerformingAction: Bool
    let onPrepareSteerSessions: ((AgentObservation) -> Void)?
    let onRefreshSteerSessions: ((AgentObservation) -> Void)?
    let onFocusAgent: ((AgentObservation) -> Void)?
    let onSteerAgent: ((AgentObservation) -> Void)?
    let onStopAgent: ((AgentObservation, Bool) -> Void)?
    let onOpenServer: ((ServerGroup) -> Void)?
    let onCopyServerURL: ((ServerGroup) -> Void)?
    let onStopServer: ((ServerGroup, Bool) -> Void)?
    let onDismiss: () -> Void

    private var forceStopConfirmation = SwiftUI.State(initialValue: false)
    private var sessionPickerPresentation = SwiftUI.State(initialValue: false)

    private var accent: Color {
        ThemeStyling.accentColor(for: theme)
    }

    init(
        subject: Subject,
        theme: SuyoiExperienceTheme = .nativeGlass,
        isEmbedded: Bool = false,
        turnPreview: SessionTurnPreview? = nil,
        steerMode: AgentSteerMode? = nil,
        steerModeLabel: String? = nil,
        steerSessionTargets: [NativeSessionTarget] = [],
        selectedSteerSessionID: Binding<String?> = .constant(nil),
        isLoadingSteerSessions: Bool = false,
        canSendSteer: Bool = false,
        steerPromptText: Binding<String> = .constant(""),
        isSteering: Bool = false,
        isPerformingAction: Bool = false,
        onPrepareSteerSessions: ((AgentObservation) -> Void)? = nil,
        onRefreshSteerSessions: ((AgentObservation) -> Void)? = nil,
        onFocusAgent: ((AgentObservation) -> Void)? = nil,
        onSteerAgent: ((AgentObservation) -> Void)? = nil,
        onStopAgent: ((AgentObservation, Bool) -> Void)? = nil,
        onOpenServer: ((ServerGroup) -> Void)? = nil,
        onCopyServerURL: ((ServerGroup) -> Void)? = nil,
        onStopServer: ((ServerGroup, Bool) -> Void)? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.subject = subject
        self.theme = theme
        self.isEmbedded = isEmbedded
        self.turnPreview = turnPreview
        self.steerMode = steerMode
        self.steerModeLabel = steerModeLabel
        self.steerSessionTargets = steerSessionTargets
        self._selectedSteerSessionID = selectedSteerSessionID
        self.isLoadingSteerSessions = isLoadingSteerSessions
        self.canSendSteer = canSendSteer
        self._steerPromptText = steerPromptText
        self.isSteering = isSteering
        self.isPerformingAction = isPerformingAction
        self.onPrepareSteerSessions = onPrepareSteerSessions
        self.onRefreshSteerSessions = onRefreshSteerSessions
        self.onFocusAgent = onFocusAgent
        self.onSteerAgent = onSteerAgent
        self.onStopAgent = onStopAgent
        self.onOpenServer = onOpenServer
        self.onCopyServerURL = onCopyServerURL
        self.onStopServer = onStopServer
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerBar
            actionToolbar
            Divider().opacity(0.6)

            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    switch subject {
                    case .agent(let obs):
                        agentContent(obs)
                            .task(id: obs.process.identity) {
                                onPrepareSteerSessions?(obs)
                            }
                    case .server(let group):
                        serverContent(group)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)
            }
        }
        .padding(isEmbedded ? 12 : 16)
        .frame(
            maxWidth: isEmbedded ? .infinity : 460,
            maxHeight: isEmbedded ? .infinity : 520,
            alignment: .topLeading
        )
        .confirmationDialog(
            "Force Stop Process?",
            isPresented: forceStopConfirmation.projectedValue
        ) {
            Button("Force Stop (SIGKILL)", role: .destructive) {
                switch subject {
                case .agent(let obs):
                    onStopAgent?(obs, true)
                case .server(let group):
                    onStopServer?(group, true)
                }
                if !isEmbedded {
                    onDismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("SIGKILL immediately terminates the verified process without allowing cleanup handlers to run. Use standard Stop (SIGTERM) first whenever possible.")
        }
        .sheet(isPresented: sessionPickerPresentation.projectedValue) {
            sessionPickerSheet
        }
    }

    // MARK: - Header & Primary Action Toolbar

    @ViewBuilder
    private var headerBar: some View {
        HStack(alignment: .center, spacing: 8) {
            switch subject {
            case .agent(let obs):
                let profile = SessionJumpRouter.visualProfile(for: obs.agentName)
                let profileColor = Color(red: profile.accentRed, green: profile.accentGreen, blue: profile.accentBlue)
                Image(systemName: profile.symbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(profileColor)
                    .frame(width: 26, height: 26)
                    .background(profileColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 1.5) {
                    HStack(spacing: 6) {
                        Text(obs.agentName)
                            .font(.system(size: 14, weight: .bold))
                        Text(verbatim: "PID \(String(obs.process.pid))")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text(obs.project?.name ?? shortenPath(obs.process.cwd ?? "Workspace not linked"))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            case .server(let group):
                Image(systemName: "network")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 26, height: 26)
                    .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 1.5) {
                    HStack(spacing: 6) {
                        Text(group.project?.name ?? group.name)
                            .font(.system(size: 14, weight: .bold))
                            .lineLimit(1)
                        Text(verbatim: "PID \(String(group.rootPID))")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text(group.listeners.map { ":\(String($0.port))" }.joined(separator: ", "))
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if isEmbedded {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear selection")
                .accessibilityLabel("Clear selection")
            } else {
                Button("Done") { onDismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var actionToolbar: some View {
        switch subject {
        case .agent(let obs):
            HStack(spacing: 6) {
                Button {
                    onFocusAgent?(obs)
                } label: {
                    Label("Focus", systemImage: "macwindow")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(accent)
                .help("Focus \(obs.terminalApp ?? "Terminal or IDE") window")

                if let path = obs.project?.rootPath ?? obs.process.cwd, path.hasPrefix("/") {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    } label: {
                        Label("Finder", systemImage: "folder")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Spacer(minLength: 4)

                if obs.process.identity.isActionEligible {
                    Button {
                        onStopAgent?(obs, false)
                        if !isEmbedded { onDismiss() }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isPerformingAction)
                    .help("Send SIGTERM after re-verifying process identity")

                    Menu {
                        Button(role: .destructive) {
                            forceStopConfirmation.wrappedValue = true
                        } label: {
                            Label("Force Stop (SIGKILL)…", systemImage: "bolt.slash.fill")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 12.5))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 22)
                    .disabled(isPerformingAction)
                    .help("More process actions (Force Stop SIGKILL)")
                    .accessibilityLabel("More process actions")
                }
            }
        case .server(let group):
            HStack(spacing: 6) {
                if let primary = group.listeners.first {
                    Button {
                        onOpenServer?(group)
                    } label: {
                        Label("Open", systemImage: "globe")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(accent)
                    .help("Open the local server on port \(primary.port)")

                    Button {
                        onCopyServerURL?(group)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Copy the local server URL")
                }

                Spacer(minLength: 4)

                Button {
                    onStopServer?(group, false)
                    if !isEmbedded { onDismiss() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isPerformingAction)
                .help("Send SIGTERM to verified server group members")

                Menu {
                    Button(role: .destructive) {
                        forceStopConfirmation.wrappedValue = true
                    } label: {
                        Label("Force Stop Group (SIGKILL)…", systemImage: "bolt.slash.fill")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 12.5))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 22)
                .disabled(isPerformingAction)
                .help("More server group actions (Force Stop SIGKILL)")
                .accessibilityLabel("More server group actions")
            }
        }
    }

    // MARK: - Agent Inspector Content

    @ViewBuilder
    private func agentContent(_ obs: AgentObservation) -> some View {
        steeringSection(obs)

        detailSection("Identity, Project & Session") {
            detailRow("Provider", value: obs.agentName)
            if let project = obs.project {
                detailRow("Project", value: project.name)
                if let branch = project.gitBranch {
                    detailRow("Git Branch", value: branch + (project.isWorktree ? " (worktree)" : ""), monospaced: true)
                } else if let commit = project.gitCommit {
                    detailRow("Git HEAD", value: commit + " (detached)", monospaced: true)
                }
                detailRow("Workspace Root", value: shortenPath(project.rootPath), monospaced: true)
            } else if let cwd = obs.process.cwd {
                detailRow("Working Dir", value: cwd == "/" ? "/ (Desktop daemon root)" : shortenPath(cwd), monospaced: true)
            } else {
                detailRow("Working Dir", value: "Not reported")
            }

            if let title = obs.sessionTitle, !title.isEmpty {
                detailRow("Session Title", value: title)
            }
            if let sid = obs.sessionID, !sid.isEmpty {
                detailRow("Observed ID", value: sid, monospaced: true)
            } else {
                detailRow("Session Link", value: "No single session linked to process")
            }
            if let task = obs.currentTask, !task.isEmpty {
                detailRow("Live Activity", value: task, monospaced: true)
            }
        }

        if let turnPreview,
           (turnPreview.lastUserPromptPreview != nil || turnPreview.lastAssistantReplyPreview != nil || !turnPreview.recentTools.isEmpty) {
            detailSection("Turn & Tool Preview") {
                if let prompt = turnPreview.lastUserPromptPreview {
                    detailRow("User Prompt", value: prompt)
                }
                if let reply = turnPreview.lastAssistantReplyPreview {
                    detailRow("Assistant", value: reply)
                }
                if !turnPreview.recentTools.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recent Tools")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        ForEach(Array(turnPreview.recentTools.enumerated()), id: \.offset) { _, tool in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(tool.status == "running" ? Color.green : (tool.status == "failed" ? Color.red : Color.secondary))
                                    .frame(width: 6, height: 6)
                                Text(tool.toolName)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                if let target = tool.targetSummary, !target.isEmpty {
                                    Text(target)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                                Text(tool.status)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let updated = turnPreview.updatedAt {
                    detailRow("Updated", value: updated.formatted(date: .omitted, time: .standard))
                }
            }
        }

        detailSection("Status & Activity") {
            detailRow("State", value: activityLabel(for: obs))
            detailRow("PID / Parent", value: "\(String(obs.process.pid)) · PPID \(String(obs.process.parentPID))", monospaced: true)
            if let tty = obs.process.tty {
                detailRow("TTY", value: tty, monospaced: true)
            }
            if let terminal = obs.terminalApp {
                detailRow("Host App", value: terminal + (obs.terminalPID.map { " (PID \(String($0)))" } ?? ""))
            }
            detailRow("CPU / Memory", value: "\(String(format: "%.1f%%", obs.process.cpuPercent)) · \(bytes(obs.process.footprintBytes ?? obs.process.residentBytes))", monospaced: true)
            if !obs.childServerPorts.isEmpty {
                detailRow("Listening Ports", value: obs.childServerPorts.map { ":\(String($0))" }.joined(separator: ", "), monospaced: true)
            }
            detailRow("Executable", value: shortenPath(obs.process.executable), monospaced: true)
        }
    }

    @ViewBuilder
    private func steeringSection(_ obs: AgentObservation) -> some View {
        detailSection("Steer or Continue Session") {
            if let mode = steerMode, let steerModeLabel {
                HStack(spacing: 6) {
                    Image(systemName: mode == .terminalTTY ? "terminal.fill" : "arrow.turn.down.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                    Text(mode == .terminalTTY ? "Live Terminal Delivery (\(steerModeLabel))" : steerModeLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                }

                if mode != .terminalTTY {
                    Text("Starts a separate continuation for the selected session.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if isLoadingSteerSessions {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Loading verified local sessions…")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    } else if steerSessionTargets.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("No verified local \(obs.agentName) sessions found for this workspace.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let onRefreshSteerSessions {
                                Button {
                                    onRefreshSteerSessions(obs)
                                } label: {
                                    Label("Refresh Sessions", systemImage: "arrow.clockwise")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .buttonStyle(.link)
                                .help("Rescan local \(obs.agentName) sessions")
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text("Target Project & Session")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if steerSessionTargets.count > 4 {
                                    Button("Browse All (\(steerSessionTargets.count))…") {
                                        sessionPickerPresentation.wrappedValue = true
                                    }
                                    .buttonStyle(.link)
                                    .font(.system(size: 11, weight: .medium))
                                }
                                if let onRefreshSteerSessions {
                                    Button {
                                        onRefreshSteerSessions(obs)
                                    } label: {
                                        Image(systemName: "arrow.clockwise")
                                            .font(.system(size: 10.5, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Refresh local \(obs.agentName) sessions")
                                    .accessibilityLabel("Refresh local sessions")
                                }
                            }

                            Picker("Target Session", selection: $selectedSteerSessionID) {
                                Text("Select a project & session…").tag(Optional<String>.none)
                                ForEach(steerSessionTargets) { target in
                                    Text(formatSessionTargetOption(target))
                                        .tag(Optional(target.sessionID))
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)

                            if let selectedID = selectedSteerSessionID,
                               let chosen = steerSessionTargets.first(where: { $0.sessionID == selectedID }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(accent)
                                    Text("\(URL(fileURLWithPath: chosen.projectPath).lastPathComponent) · \(chosen.title ?? chosen.sessionID)")
                                        .font(.system(size: 11, weight: .medium))
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                        }
                    }
                } else {
                    Text("Sends instruction to \(obs.terminalApp ?? "Terminal") (\(obs.process.tty ?? "TTY")).")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 6) {
                    TextField(
                        mode == .terminalTTY
                            ? "Send instruction to \(obs.agentName)…"
                            : (selectedSteerSessionID == nil ? "Select a session above first…" : "Continue selected \(obs.agentName) session…"),
                        text: $steerPromptText
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .disabled(isSteering || (mode != .terminalTTY && selectedSteerSessionID == nil))
                    .onSubmit {
                        if canSendSteer {
                            onSteerAgent?(obs)
                        }
                    }

                    Button {
                        onSteerAgent?(obs)
                    } label: {
                        if isSteering {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(mode == .terminalTTY ? "Send" : "Continue", systemImage: "paperplane.fill")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(accent)
                    .disabled(!canSendSteer)
                }
                .padding(.top, 2)
            } else {
                let diag = SafetyDiagnostics.explainSteeringUnavailable(for: obs)
                detailRow("Status", value: diag.headline)
                detailRow("Next Step", value: diag.remediationHint)
            }
        }
    }

    private var sessionPickerSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Choose Session to Continue", systemImage: "list.bullet.rectangle")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Button("Done") {
                    sessionPickerPresentation.wrappedValue = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text("Select the exact project and session to launch a continuation run. No session is selected automatically.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(steerSessionTargets) { target in
                        let isSelected = selectedSteerSessionID == target.sessionID
                        Button {
                            selectedSteerSessionID = target.sessionID
                            sessionPickerPresentation.wrappedValue = false
                        } label: {
                            HStack(alignment: .center, spacing: 10) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(isSelected ? accent : .secondary)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(URL(fileURLWithPath: target.projectPath).lastPathComponent)
                                            .font(.system(size: 12.5, weight: .semibold))
                                        if let title = target.title, !title.isEmpty {
                                            Text("· \(title)")
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundStyle(.primary.opacity(0.9))
                                                .lineLimit(1)
                                        }
                                    }
                                    HStack(spacing: 6) {
                                        Text(shortenPath(target.projectPath))
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Text("· \(target.sessionID.prefix(18))")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                Spacer()
                                if let updated = target.updatedAt {
                                    Text(updated.formatted(date: .abbreviated, time: .shortened))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(9)
                            .background(
                                isSelected ? accent.opacity(0.14) : Color(nsColor: .controlBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 500, height: 380)
    }

    private func formatSessionTargetOption(_ target: NativeSessionTarget) -> String {
        let project = URL(fileURLWithPath: target.projectPath).lastPathComponent
        let titleOrID = (target.title?.isEmpty == false) ? target.title! : String(target.sessionID.prefix(18))
        if let updated = target.updatedAt {
            return "\(project) · \(titleOrID) (\(updated.formatted(date: .omitted, time: .shortened)))"
        }
        return "\(project) · \(titleOrID)"
    }

    // MARK: - Server Inspector Content

    @ViewBuilder
    private func serverContent(_ group: ServerGroup) -> some View {
        detailSection("Server Group & Listeners") {
            detailRow("Root Process", value: "\(group.name) (PID \(String(group.rootPID)))", monospaced: true)
            detailRow("Member PIDs", value: group.memberPIDs.map(String.init).joined(separator: ", "), monospaced: true)
            detailRow("Listeners", value: group.listeners.map { "\($0.address):\(String($0.port)) (\($0.exposure))" }.joined(separator: " · "), monospaced: true)
            if let namedURL = ServerPresentation.namedLocalhostURL(for: group) {
                HStack(alignment: .top, spacing: 8) {
                    Text("Named URL")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 96, alignment: .leading)
                    Button {
                        NSWorkspace.shared.open(namedURL)
                    } label: {
                        Text(namedURL.absoluteString)
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(accent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .help("Open \(namedURL.absoluteString) in browser")
                    Spacer(minLength: 0)
                }
            }
            if let badge = ServerPresentation.healthBadge(for: group) {
                detailRow("Health", value: "\(badge.label) — \(badge.detail)")
            }
            if let startedAt = group.startedAt {
                detailRow("Started", value: startedAt.formatted(date: .abbreviated, time: .shortened))
            }
            if group.stoppedByAgentBoundary {
                detailRow("Boundary", value: "Isolated from parent coding agent")
            }
        }

        if let project = group.project {
            detailSection("Project Context") {
                detailRow("Project", value: project.name)
                if let framework = project.framework {
                    detailRow("Framework", value: framework)
                }
                if let branch = project.gitBranch {
                    detailRow("Git Branch", value: branch + (project.isWorktree ? " (worktree)" : ""), monospaced: true)
                }
                detailRow("Root Path", value: shortenPath(project.rootPath), monospaced: true)
            }
        }

        detailSection("Deduplicated Resources") {
            if let cpu = group.cpuPercent {
                detailRow("CPU", value: String(format: "%.1f%%", cpu), monospaced: true)
            }
            if let footprint = group.footprintBytes {
                detailRow("Footprint", value: bytes(footprint), monospaced: true)
            }
            detailRow("Resident (RSS)", value: bytes(group.residentBytes), monospaced: true)
        }
    }

    private func detailSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .themedSurfaceCard(theme: theme, isHovered: false)
        }
    }

    private func detailRow(_ label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.system(size: 11.5, design: monospaced ? .monospaced : .default))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func activityLabel(for obs: AgentObservation) -> String {
        if obs.process.isStopped || obs.activityState == .stopped {
            return "Stopped"
        }
        switch obs.activityState {
        case .active: return "Working"
        case .waiting: return "Waiting for Input"
        case .idle, nil: return "Quiet"
        case .stopped: return "Stopped"
        }
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func shortenPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
