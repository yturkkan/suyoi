import AppKit
import SwiftUI
import SuyoiCore

private let settingsAccent = Color.accentColor

struct SettingsView: View {
    @ObservedObject var model: DashboardModel
    @State private var newSnippetTrigger = ""
    @State private var newSnippetTitle = ""
    @State private var newSnippetPrompt = ""

    var body: some View {
        VStack(spacing: 0) {
            headerBar
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Picker("", selection: $model.settingsTab) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch model.settingsTab {
                    case .general:
                        generalContent
                    case .about:
                        aboutContent
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }

            Divider()

            footerBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(width: 410, height: 500)
        .onAppear {
            model.refreshClaudeHookStatus()
        }
    }

    // MARK: - Header & Footer

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: model.settingsTab == .general ? "gearshape.fill" : "info.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(model.settingsTab == .general ? "Settings" : "About Suyoi")
                .font(.system(size: 13.5, weight: .semibold))

            Spacer()

            Button {
                model.isShowingSettings = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close Settings")
        }
    }

    private var footerBar: some View {
        HStack {
            if model.settingsTab == .general {
                Text("\(model.visibleProvidersCount) of \(model.providerOrder.count) subscriptions visible")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            } else {
                Text("© 2026 Y. Türkkan (@yturkkan)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") {
                model.isShowingSettings = false
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - General Tab

    private var generalContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("SURFACE, THEME & AUDIO CUES")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)

                VStack(spacing: 0) {
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Display Surface")
                                .font(.system(size: 11.5, weight: .medium))
                            Text("Menu bar popover, top-center Notch Dynamic Island, or movable Floating Companion.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        Picker("", selection: Binding(
                            get: { model.surfaceMode },
                            set: { model.setSurfaceMode($0) }
                        )) {
                            ForEach(SuyoiSurfaceMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 165)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)

                    Divider()
                        .padding(.leading, 12)

                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Menu Bar Badge Style")
                                .font(.system(size: 11.5, weight: .medium))
                            Text("Configure status item title: icon only, counts, quota %, or agent RAM.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        Picker("", selection: Binding(
                            get: { model.statusBarStyle },
                            set: { model.setStatusBarStyle($0) }
                        )) {
                            ForEach(StatusBarDisplayStyle.allCases, id: \.self) { style in
                                Text(style.rawValue).tag(style)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 165)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)

                    Divider()
                        .padding(.leading, 12)

                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Experience Theme")
                                .font(.system(size: 11.5, weight: .medium))
                            Text("Switches accent palette, card geometry, and pixel/monospaced styling.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        Picker("", selection: Binding(
                            get: { model.experienceTheme },
                            set: { model.setExperienceTheme($0) }
                        )) {
                            ForEach(SuyoiExperienceTheme.allCases, id: \.self) { theme in
                                Text(theme.rawValue).tag(theme)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 165)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)

                    Divider()
                        .padding(.leading, 12)

                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Semantic Audio Cues")
                                .font(.system(size: 11.5, weight: .medium))
                            Text("Plays sounds on agent attention, completion, and quota alerts.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        Button("Test") {
                            model.playTestSound()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Picker("", selection: Binding(
                            get: { model.soundMode },
                            set: { model.setSoundMode($0) }
                        )) {
                            ForEach(SuyoiSoundMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 145)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)

                    if model.soundMode == .soundPack {
                        Divider()
                            .padding(.leading, 12)

                        HStack(alignment: .center, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("OpenPeon Sound Pack")
                                    .font(.system(size: 11.5, weight: .medium))
                                Text(model.availableSoundPacks.isEmpty
                                     ? "No packs found in ~/.openpeon/packs (install built-in 8-bit pack or rescan)."
                                     : "\(model.availableSoundPacks.count) CESP pack(s) discovered.")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 6)
                            if !model.availableSoundPacks.isEmpty {
                                Picker("", selection: Binding(
                                    get: { model.selectedSoundPackID ?? model.availableSoundPacks.first?.id ?? "" },
                                    set: { model.setSelectedSoundPackID($0) }
                                )) {
                                    ForEach(model.availableSoundPacks) { pack in
                                        Text(pack.displayName).tag(pack.id)
                                    }
                                }
                                .labelsHidden()
                                .controlSize(.small)
                                .frame(width: 120)
                            }
                            Button("Install 8-Bit") {
                                model.installBuiltInRetroSoundPack()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .help("Install and activate the built-in Suyoi 8-Bit Chiptune OpenPeon pack")

                            Button("Rescan") {
                                model.reloadSoundPacks()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                    }

                    Divider()
                        .padding(.leading, 12)

                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .center, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("Claude Code Hook Installer")
                                        .font(.system(size: 11.5, weight: .medium))
                                    claudeHookBadge
                                }
                                Text("Safely merges `--hook-bridge` into `~/.claude/settings.json` with automatic `.suyoi-backup`.")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 6)
                            Button(hookPrimaryButtonTitle) {
                                model.installClaudeHooks()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }

                        Toggle(isOn: Binding(
                            get: { model.includePreToolUseHook },
                            set: { model.setIncludePreToolUseHook($0) }
                        )) {
                            Text("Also register PreToolUse hook (review tool calls before execution)")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                        .toggleStyle(.checkbox)
                        .controlSize(.small)

                        HStack(spacing: 6) {
                            if case .installed = model.claudeHookStatus {
                                Button("Uninstall Hooks") {
                                    model.uninstallClaudeHooks()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            } else if case .outdated = model.claudeHookStatus {
                                Button("Uninstall Hooks") {
                                    model.uninstallClaudeHooks()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            }

                            Button("Copy Snippet") {
                                model.copyHookSnippet()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)

                            Button("Simulate Approval") {
                                model.simulateApprovalRequest(isQuestion: false)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)

                            Button("Simulate Question") {
                                model.simulateApprovalRequest(isQuestion: true)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)

                            Spacer()
                        }

                        Divider()

                        HStack(alignment: .center, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Auto-Approve Verified Read-Only Tools")
                                    .font(.system(size: 11.5, weight: .medium))
                                Text("Auto-approves Read/Glob/Grep/LS & pure `git status`/`diff`/`log` on verified live sessions.")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 6)
                            Toggle("", isOn: Binding(
                                get: { model.scopedApprovalPolicy.autoApproveReadOnlyTools },
                                set: { model.setAutoApproveReadOnlyTools($0) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        }

                        if model.scopedApprovalPolicy.autoApproveReadOnlyTools {
                            Toggle(isOn: Binding(
                                get: { model.scopedApprovalPolicy.applyToAllVerifiedProjects },
                                set: { model.setApplyReadOnlyToAllProjects($0) }
                            )) {
                                Text("Apply to all verified workspaces (otherwise only selected projects)")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                            }
                            .toggleStyle(.checkbox)
                            .controlSize(.small)

                            let scopedPaths = model.scopedApprovalPolicy.allowedProjectPaths.sorted()
                            if !model.scopedApprovalPolicy.applyToAllVerifiedProjects && !scopedPaths.isEmpty {
                                VStack(alignment: .leading, spacing: 3) {
                                    ForEach(scopedPaths, id: \.self) { path in
                                        HStack(spacing: 6) {
                                            Image(systemName: "folder.fill")
                                                .font(.system(size: 9.5))
                                                .foregroundStyle(settingsAccent)
                                            Text(URL(fileURLWithPath: path).lastPathComponent)
                                                .font(.system(size: 10.5, weight: .medium))
                                                .lineLimit(1)
                                            Spacer()
                                            Button("Remove") {
                                                model.removeReadOnlyProject(path)
                                            }
                                            .buttonStyle(.borderless)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }

                            if !model.autoApprovedToolHistory.isEmpty {
                                Text("Auto-approved \(model.autoApprovedToolHistory.count) verified read-only call(s) this session.")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("STEERING SLASH SNIPPETS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Built-in triggers (`/test`, `/diff`, `/review`, `/commit`, `/continue`) expand automatically when steering any agent.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                    if !model.customSnippets.isEmpty {
                        ForEach(model.customSnippets) { snippet in
                            HStack(spacing: 6) {
                                Text(snippet.trigger)
                                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                    .foregroundStyle(settingsAccent)
                                Text(snippet.title)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .lineLimit(1)
                                Spacer()
                                Button {
                                    model.removeCustomSnippet(snippet)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Remove \(snippet.trigger)")
                            }
                        }
                    }

                    HStack(spacing: 6) {
                        TextField("/lint", text: $newSnippetTrigger)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 72)
                        TextField("Title", text: $newSnippetTitle)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                            .frame(width: 92)
                        TextField("Expanded instruction…", text: $newSnippetPrompt)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                        Button("Add") {
                            if model.addCustomSnippet(trigger: newSnippetTrigger, title: newSnippetTitle, prompt: newSnippetPrompt) {
                                newSnippetTrigger = ""
                                newSnippetTitle = ""
                                newSnippetPrompt = ""
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(newSnippetTrigger.trimmingCharacters(in: .whitespaces).isEmpty || newSnippetPrompt.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("AI SUBSCRIPTIONS & DISPLAY ORDER")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset Default") {
                        model.resetQuotaPreferences()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 10.5, weight: .medium))
                }

                VStack(spacing: 0) {
                    ForEach(Array(model.providerOrder.enumerated()), id: \.element) { index, provider in
                        providerRow(provider: provider, index: index, total: model.providerOrder.count)
                        if index < model.providerOrder.count - 1 {
                            Divider()
                                .padding(.leading, 34)
                        }
                    }
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
                )

                Text("Checked providers appear in the Quotas tab and on matching Agent cards.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("QUOTA TELEMETRY & STORAGE SCAN")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)

                VStack(spacing: 0) {
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Live OAuth Quota Polling")
                                .font(.system(size: 11.5, weight: .medium))
                            Text("Enabled by default. Queries remaining 5h & 7d limit windows in-memory for Codex, Claude, and Gemini using existing CLI OAuth tokens.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Toggle("", isOn: Binding(
                            get: { model.isLiveQuotaEnabled },
                            set: { model.setLiveQuotaEnabled($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)

                    Divider()
                        .padding(.leading, 12)

                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Primary Project Scan Folder")
                                .font(.system(size: 11.5, weight: .medium))
                            HStack(spacing: 4) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(settingsAccent)
                                Text(model.cleanupRootDisplayPath)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        Spacer(minLength: 6)
                        Button("Choose…") {
                            model.chooseCleanupRootFolder()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("Reset") {
                            model.resetCleanupRootFolder()
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)

                    Divider()
                        .padding(.leading, 12)

                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Scan All Common Workspaces")
                                .font(.system(size: 11.5, weight: .medium))
                            Text("Also scan ~/Projects, ~/Code, ~/repos, ~/workspace, and ~/Desktop in addition to the primary folder.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Toggle("", isOn: Binding(
                            get: { model.scanAllWorkspaces },
                            set: { model.setScanAllWorkspaces($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("NOTIFICATIONS & STARTUP")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)

                VStack(spacing: 0) {
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Agent Waiting & Quota Alerts")
                                .font(.system(size: 11.5, weight: .medium))
                            Text("Notifies when a coding agent is waiting for input or a quota window crosses 85% / 95%.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Toggle("", isOn: Binding(
                            get: { model.areNotificationsEnabled },
                            set: { model.setNotificationsEnabled($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)

                    Divider()
                        .padding(.leading, 12)

                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Launch Suyoi at Login")
                                .font(.system(size: 11.5, weight: .medium))
                            Text("Starts Suyoi in the macOS menu bar automatically when you sign in.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Toggle("", isOn: Binding(
                            get: { model.isLaunchAtLoginEnabled },
                            set: { model.setLaunchAtLoginEnabled($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
                )
            }
        }
    }

    // MARK: - About Tab

    private var aboutContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(model.appDisplayName)
                            .font(.system(size: 16, weight: .bold))
                        Text("v.\(model.currentAppVersion)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                    Text("Native macOS Developer & AI Agent Companion")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Created by Y. Türkkan (@yturkkan)")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(settingsAccent)
                    Text("macOS 14+ · Swift 6 · AppKit & SwiftUI")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
            )

            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 9) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(settingsAccent)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Designed & Developed by Y. Türkkan")
                            .font(.system(size: 11.5, weight: .semibold))
                        Text("Clean-room native macOS engineering with zero external dependencies.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()
                }

                let repoSlug = model.isParallelBuild ? "yturkkan/suyoi-next" : "yturkkan/suyoi"
                let repoURL = "https://github.com/\(repoSlug)"
                HStack(spacing: 7) {
                    Button {
                        if let url = URL(string: "https://x.com/yturkkan") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("X · @yturkkan", systemImage: "at")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("https://x.com/yturkkan")

                    Button {
                        if let url = URL(string: "https://www.linkedin.com/in/yturkkan") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("LinkedIn", systemImage: "person.text.rectangle")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("https://www.linkedin.com/in/yturkkan")

                    Button {
                        if let url = URL(string: repoURL) {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("GitHub · \(repoSlug)", systemImage: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(repoURL)

                    Spacer()
                }
            }
            .padding(11)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
            )

            VStack(alignment: .leading, spacing: 8) {
                aboutFeatureRow(
                    symbol: "terminal.fill",
                    title: "Live Agent & Task Visibility + Native Steering",
                    detail: "Inspects running coding agents (Codex, Claude Code, OpenCode, Gemini CLI, Aider), shows active session tasks, and steers sessions via Terminal/iTerm2/tmux or native CLI."
                )
                Divider()
                aboutFeatureRow(
                    symbol: "chart.bar.fill",
                    title: "Hybrid 5-Hour & 7-Day Quota Tracking",
                    detail: "Combines in-memory OAuth quota windows (enabled by default for Codex, Claude, and Gemini) with offline local rolling token counters and reset countdowns."
                )
                Divider()
                aboutFeatureRow(
                    symbol: "network",
                    title: "Dev Server Grouping & Port Control",
                    detail: "Groups multi-worker localhost servers by project and git branch with one-click browser launch, URL copy, and agent-boundary-safe stopping."
                )
                Divider()
                aboutFeatureRow(
                    symbol: "checkmark.shield.fill",
                    title: "Verified Process & macOS Trash Safety",
                    detail: "Re-verifies PID, start time, executable path, and UID before signaling, and re-verifies device/inode identity before moving caches or build folders to macOS Trash."
                )
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
            )

            HStack(spacing: 8) {
                if let release = model.availableUpdate {
                    Button {
                        model.installAvailableUpdate()
                    } label: {
                        Label(
                            model.isInstallingUpdate ? "Updating…" : "Update to v\(release.version) & Relaunch",
                            systemImage: "arrow.down.circle.fill"
                        )
                        .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(model.isInstallingUpdate)
                } else {
                    Button {
                        model.checkForUpdates()
                    } label: {
                        Label(
                            model.isCheckingForUpdates ? "Checking…" : "Check for Updates…",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                        .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(model.isCheckingForUpdates || model.isInstallingUpdate)
                }

                Button {
                    if let url = URL(string: "https://github.com/yturkkan/suyoi") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("GitHub Repository", systemImage: "link")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                } label: {
                    Label("Reveal App in Finder", systemImage: "folder")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()
            }
        }
    }

    private func aboutFeatureRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(settingsAccent)
                .frame(width: 18, alignment: .center)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Provider Row

    private func providerRow(provider: QuotaProvider, index: Int, total: Int) -> some View {
        let isVisible = model.isProviderVisible(provider)
        return HStack(spacing: 9) {
            Button {
                model.toggleProviderVisibility(provider)
            } label: {
                Image(systemName: isVisible ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isVisible ? settingsAccent : .secondary)
            }
            .buttonStyle(.plain)
            .help(isVisible ? "Hide \(providerDisplayName(provider))" : "Show \(providerDisplayName(provider))")

            Image(systemName: providerSymbolName(provider))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isVisible ? .primary : .secondary)
                .frame(width: 16)

            Text(providerDisplayName(provider))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(isVisible ? .primary : .secondary)

            if !isVisible {
                Text("Hidden")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }

            Spacer()

            HStack(spacing: 3) {
                Button {
                    model.moveProvider(provider, direction: -1)
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9.5, weight: .bold))
                        .frame(width: 20, height: 18)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(index == 0)
                .opacity(index == 0 ? 0.3 : 1.0)
                .help("Move up")

                Button {
                    model.moveProvider(provider, direction: 1)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9.5, weight: .bold))
                        .frame(width: 20, height: 18)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(index == total - 1)
                .opacity(index == total - 1 ? 0.3 : 1.0)
                .help("Move down")
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6.5)
        .contentShape(Rectangle())
    }

    private func providerDisplayName(_ provider: QuotaProvider) -> String {
        switch provider {
        case .codex: return "OpenAI Codex"
        case .claude: return "Claude Code"
        case .gemini: return "Gemini CLI"
        case .openCode: return "OpenCode"
        case .cursor: return "Cursor"
        }
    }

    private var hookPrimaryButtonTitle: String {
        switch model.claudeHookStatus {
        case .notInstalled:
            return "Install Hooks"
        case .installed(_, let includesPreToolUse):
            return includesPreToolUse == model.includePreToolUseHook ? "Reinstall" : "Update Hooks"
        case .outdated:
            return "Update Hooks"
        case .blocked:
            return "Retry Install"
        }
    }

    @ViewBuilder
    private var claudeHookBadge: some View {
        switch model.claudeHookStatus {
        case .installed(_, let includesPreToolUse):
            Text(includesPreToolUse ? "Installed (+PreToolUse)" : "Installed")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(Color(nsColor: .systemGreen))
                .padding(.horizontal, 5.5)
                .padding(.vertical, 1.5)
                .background(Color(nsColor: .systemGreen).opacity(0.14), in: Capsule())
        case .outdated:
            Text("Update Needed")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(Color(nsColor: .systemOrange))
                .padding(.horizontal, 5.5)
                .padding(.vertical, 1.5)
                .background(Color(nsColor: .systemOrange).opacity(0.14), in: Capsule())
        case .blocked:
            Text("Blocked")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(Color(nsColor: .systemRed))
                .padding(.horizontal, 5.5)
                .padding(.vertical, 1.5)
                .background(Color(nsColor: .systemRed).opacity(0.14), in: Capsule())
        case .notInstalled:
            Text("Not Installed")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5.5)
                .padding(.vertical, 1.5)
                .background(Color.primary.opacity(0.06), in: Capsule())
        }
    }

    private func providerSymbolName(_ provider: QuotaProvider) -> String {
        switch provider {
        case .codex: return "sparkles"
        case .claude: return "brain.head.profile"
        case .gemini: return "aqi.medium"
        case .openCode: return "chevron.left.forwardslash.chevron.right"
        case .cursor: return "cursorarrow.rays"
        }
    }
}
