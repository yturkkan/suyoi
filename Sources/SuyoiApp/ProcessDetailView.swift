import AppKit
import SwiftUI
import SuyoiCore

struct ProcessDetailView: View {
    enum Subject {
        case agent(AgentObservation)
        case server(ServerGroup)
    }

    let subject: Subject
    let turnPreview: SessionTurnPreview?
    let steerModeLabel: String?
    @Binding var steerPromptText: String
    let isSteering: Bool
    let onFocusAgent: ((AgentObservation) -> Void)?
    let onSteerAgent: ((AgentObservation) -> Void)?
    let onStopAgent: ((AgentObservation, Bool) -> Void)?
    let onOpenServer: ((ServerGroup) -> Void)?
    let onCopyServerURL: ((ServerGroup) -> Void)?
    let onStopServer: ((ServerGroup, Bool) -> Void)?
    let onDismiss: () -> Void
    private let leafGreen = Color.accentColor

    init(
        subject: Subject,
        turnPreview: SessionTurnPreview? = nil,
        steerModeLabel: String? = nil,
        steerPromptText: Binding<String> = .constant(""),
        isSteering: Bool = false,
        onFocusAgent: ((AgentObservation) -> Void)? = nil,
        onSteerAgent: ((AgentObservation) -> Void)? = nil,
        onStopAgent: ((AgentObservation, Bool) -> Void)? = nil,
        onOpenServer: ((ServerGroup) -> Void)? = nil,
        onCopyServerURL: ((ServerGroup) -> Void)? = nil,
        onStopServer: ((ServerGroup, Bool) -> Void)? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.subject = subject
        self.turnPreview = turnPreview
        self.steerModeLabel = steerModeLabel
        self._steerPromptText = steerPromptText
        self.isSteering = isSteering
        self.onFocusAgent = onFocusAgent
        self.onSteerAgent = onSteerAgent
        self.onStopAgent = onStopAgent
        self.onOpenServer = onOpenServer
        self.onCopyServerURL = onCopyServerURL
        self.onStopServer = onStopServer
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                switch subject {
                case .agent(let obs):
                    let profile = SessionJumpRouter.visualProfile(for: obs.agentName)
                    Label(obs.agentName, systemImage: profile.symbolName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(red: profile.accentRed, green: profile.accentGreen, blue: profile.accentBlue))
                case .server(let group):
                    Label(group.project?.name ?? group.name, systemImage: "network")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(leafGreen)
                }
                Spacer()
                Button("Done") { onDismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            actionToolbar

            Divider().opacity(0.6)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch subject {
                    case .agent(let obs):
                        agentContent(obs)
                    case .server(let group):
                        serverContent(group)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(width: 420, height: 450)
    }

    @ViewBuilder
    private var actionToolbar: some View {
        switch subject {
        case .agent(let obs):
            HStack(spacing: 8) {
                if obs.terminalApp != nil || obs.terminalPID != nil {
                    Button {
                        onFocusAgent?(obs)
                    } label: {
                        Label("Focus \(obs.terminalApp ?? "Terminal")", systemImage: "macwindow")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                if let path = obs.project?.rootPath ?? obs.process.cwd {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    } label: {
                        Label("Finder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Spacer()
                if obs.process.identity.isActionEligible {
                    Button {
                        onStopAgent?(obs, false)
                        onDismiss()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(role: .destructive) {
                        onStopAgent?(obs, true)
                        onDismiss()
                    } label: {
                        Text("Force Kill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        case .server(let group):
            HStack(spacing: 8) {
                if let primary = group.listeners.first {
                    Button {
                        onOpenServer?(group)
                    } label: {
                        Label("Open :\(primary.port)", systemImage: "globe")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button {
                        onCopyServerURL?(group)
                    } label: {
                        Label("Copy URL", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Spacer()
                Button {
                    onStopServer?(group, false)
                    onDismiss()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(role: .destructive) {
                    onStopServer?(group, true)
                    onDismiss()
                } label: {
                    Text("Force Kill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func agentContent(_ obs: AgentObservation) -> some View {
        detailSection("Session & Live Task") {
            if let title = obs.sessionTitle {
                detailRow("Session Title", value: title)
            }
            if let task = obs.currentTask {
                detailRow("Current Task", value: task, monospaced: true)
            }
            if let sid = obs.sessionID {
                detailRow("Session ID", value: sid, monospaced: true)
            }
            if let steerModeLabel {
                detailRow("Steer Channel", value: steerModeLabel)
                HStack(spacing: 6) {
                    TextField("Send instruction to \(obs.agentName)…", text: $steerPromptText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .disabled(isSteering)
                        .onSubmit {
                            onSteerAgent?(obs)
                        }
                    Button {
                        onSteerAgent?(obs)
                    } label: {
                        if isSteering {
                            ProgressView().controlSize(.mini)
                        } else {
                            Label("Send", systemImage: "paperplane.fill")
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isSteering || steerPromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.top, 2)
            } else {
                let diag = SafetyDiagnostics.explainSteeringUnavailable(for: obs)
                detailRow("Steering Status", value: "\(diag.headline) (\(diag.checkName))")
                detailRow("Next Step", value: diag.remediationHint)
            }
        }

        if let turnPreview,
           (turnPreview.lastUserPromptPreview != nil || turnPreview.lastAssistantReplyPreview != nil || !turnPreview.recentTools.isEmpty) {
            detailSection("Live Turn & Tool Activity Preview") {
                if let prompt = turnPreview.lastUserPromptPreview {
                    detailRow("Last User Prompt", value: prompt)
                }
                if let reply = turnPreview.lastAssistantReplyPreview {
                    detailRow("Assistant Reply", value: reply)
                }
                if !turnPreview.recentTools.isEmpty {
                    let toolsText = turnPreview.recentTools.map { tool in
                        if let target = tool.targetSummary, !target.isEmpty {
                            return "\(tool.toolName) (\(target)) [\(tool.status)]"
                        }
                        return "\(tool.toolName) [\(tool.status)]"
                    }.joined(separator: " · ")
                    detailRow("Recent Tools", value: toolsText, monospaced: true)
                }
            }
        }

        detailSection("Status & Activity") {
            if let state = obs.activityState {
                detailRow("Activity State", value: state.rawValue.capitalized)
            }
            if let detail = obs.activityDetail {
                detailRow("Activity Signal", value: detail)
            }
            if let last = obs.lastActivityAt {
                detailRow("Last State Update", value: last.formatted(date: .abbreviated, time: .standard))
            }
            detailRow("Observation", value: statusDescription(obs.statusSource))
            detailRow("PID / Parent", value: "\(obs.process.pid) · PPID \(obs.process.parentPID)")
            detailRow("Executable", value: displayPath(obs.process.executable), monospaced: true)
            if let invocation = obs.process.agentInvocation, let runtime = invocation.runtime {
                detailRow("Wrapper Runtime", value: "\(runtime) → \(invocation.entrypoint ?? obs.agentName)", monospaced: true)
            }
            if let tty = obs.process.tty {
                detailRow("TTY", value: tty, monospaced: true)
            }
            if let terminal = obs.terminalApp {
                detailRow("Host / Terminal", value: terminal + (obs.terminalPID.map { " (PID \($0))" } ?? ""))
            }
            detailRow("Identity check", value: obs.process.identity.isActionEligible ? "Complete (PID + start time + path captured)" : "Partial metadata")
        }

        if let project = obs.project {
            projectSection(project)
        } else if let cwd = obs.process.cwd {
            detailSection("Working Directory") {
                detailRow("Path", value: displayPath(cwd), monospaced: true)
            }
        }

        detailSection("Resources") {
            detailRow("CPU", value: String(format: "%.1f%%", obs.process.cpuPercent))
            if let footprint = obs.process.footprintBytes {
                detailRow("Physical Footprint", value: bytes(footprint))
            }
            detailRow("Resident Memory (RSS)", value: bytes(obs.process.residentBytes))
            if !obs.childServerPorts.isEmpty {
                detailRow("Child Server Ports", value: obs.childServerPorts.map { ":\($0)" }.joined(separator: ", "), monospaced: true)
            }
        }

        Text("Stopping re-verifies PID, start time, executable path, and UID immediately before signaling.")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func serverContent(_ group: ServerGroup) -> some View {
        detailSection("Server Group") {
            detailRow("Root Process", value: "\(group.name) (PID \(group.rootPID))", monospaced: true)
            detailRow("Member PIDs", value: group.memberPIDs.map(String.init).joined(separator: ", "), monospaced: true)
            detailRow("Ports", value: group.listeners.map { "\($0.address):\($0.port) (\($0.exposure))" }.joined(separator: " · "), monospaced: true)
            if let namedURL = ServerPresentation.namedLocalhostURL(for: group) {
                HStack(alignment: .center, spacing: 8) {
                    Text("Named URL")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 120, alignment: .leading)
                    Button {
                        NSWorkspace.shared.open(namedURL)
                    } label: {
                        Text(namedURL.absoluteString)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(leafGreen)
                    }
                    .buttonStyle(.plain)
                    .help("Open \(namedURL.absoluteString) in browser")
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(namedURL.absoluteString, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy \(namedURL.absoluteString)")
                    Spacer(minLength: 0)
                }
            }
            if let badge = ServerPresentation.healthBadge(for: group) {
                detailRow("Health & Uptime", value: "\(badge.label) — \(badge.detail)")
            }
            if let startedAt = group.startedAt {
                detailRow("Started", value: startedAt.formatted(date: .abbreviated, time: .shortened))
            }
            if group.stoppedByAgentBoundary {
                detailRow("Agent Boundary", value: "Isolated from parent coding agent")
            }
        }

        if let project = group.project {
            projectSection(project)
        }

        detailSection("Deduplicated Resources") {
            if let cpu = group.cpuPercent {
                detailRow("CPU", value: String(format: "%.1f%%", cpu))
            }
            if let footprint = group.footprintBytes {
                detailRow("Physical Footprint", value: bytes(footprint))
            }
            detailRow("Resident Memory (RSS)", value: bytes(group.residentBytes))
        }

        Text("Shared worker processes are counted once per server group. Stopping signals member processes without killing a parent coding agent.")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func projectSection(_ project: ProjectContext) -> some View {
        detailSection("Project Context") {
            detailRow("Project", value: project.name)
            if let framework = project.framework {
                detailRow("Framework", value: framework)
            }
            if let branch = project.gitBranch {
                detailRow("Git Branch", value: branch + (project.isWorktree ? " (worktree)" : ""), monospaced: true)
            } else if let commit = project.gitCommit {
                detailRow("Git HEAD", value: commit + " (detached)", monospaced: true)
            }
            detailRow("Root", value: displayPath(project.rootPath), monospaced: true)
            Button("Reveal Project in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.rootPath)])
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
        }
    }

    private func detailSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func detailRow(_ label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: monospaced ? .monospaced : .default))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func statusDescription(_ source: AgentStatusSource) -> String {
        switch source {
        case .processOnly:
            return "Process & runtime signals"
        case .verifiedAdapter(let adapter):
            return "Verified via \(adapter)"
        }
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
