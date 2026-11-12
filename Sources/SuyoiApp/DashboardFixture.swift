#if DEBUG
import AppKit
import SwiftUI
import SuyoiCore

enum DashboardFixture {
    static let bundleIdentifier = "local.suyoi.fixture"

    fileprivate enum Scenario: String {
        case overview, approval, steering, showcase
    }

    @MainActor
    static func run(arguments: [String]) -> Never {
        let bundle = Bundle.main
        let keys = ["SuyoiFixtureTab", "SuyoiFixtureTheme", "SuyoiFixtureScenario"]
        let values = arguments.isEmpty
            ? keys.compactMap { bundle.object(forInfoDictionaryKey: $0) as? String }
            : Array(arguments.dropFirst())
        let tabs: [String: DashboardTab] = ["agents": .agents, "servers": .ports, "quotas": .quotas, "storage": .cleanup]
        let themes: [String: SuyoiExperienceTheme] = [
            "glass": .nativeGlass, "native": .macOSSystem, "pixel": .pixelArcade, "olive": .pixelOlive
        ]
        guard bundle.bundleIdentifier == bundleIdentifier,
              arguments.isEmpty || arguments.first == "--dashboard-fixture",
              values.count == 3, let tab = tabs[values[0]], let theme = themes[values[1]],
              let scenario = Scenario(rawValue: values[2]) else {
            fputs("A fixture bundle and valid tab, theme and scenario are required.\n", stderr)
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let menuBar = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let quit = NSMenuItem(title: "Quit Suyoi Fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = app
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        menuBar.addItem(appItem)
        app.mainMenu = menuBar
        let delegate = WindowDelegate(tab: tab, theme: theme, sample: Sample(scenario: scenario))
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
        exit(0)
    }

    @MainActor
    static func exportScreenshots(to outputDirectoryPath: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        if let darkAppearance = NSAppearance(named: .darkAqua) {
            app.appearance = darkAppearance
        }

        let outputURL = URL(fileURLWithPath: outputDirectoryPath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        } catch {
            fputs("Failed to create screenshot directory \(outputURL.path): \(error.localizedDescription)\n", stderr)
            exit(1)
        }

        let showcaseSample = Sample(scenario: .showcase)

        // 1. Unified Agents & Multi-Turn Chat Steering Console (Native Glass · 920x660)
        let agentsModel = DashboardModel(fixture: showcaseSample, tab: .agents, theme: .nativeGlass)
        agentsModel.onToggleDetachedWindow = {}
        let shot1 = SequoiaWindowCanvas(canvasSize: CGSize(width: 980, height: 720), windowCornerRadius: 14) {
            DashboardView(model: agentsModel)
                .frame(width: 920, height: 660)
                .background(Color(red: 0.10, green: 0.11, blue: 0.14))
        }
        writeScreenshot(
            shot1,
            size: CGSize(width: 980, height: 720),
            to: outputURL.appendingPathComponent("01-agents-console-chat-steering.png")
        )

        // 2. Deep Background Storage Indexer & Ready Cleanup (Native Glass · 920x660)
        let storageModel = DashboardModel(fixture: showcaseSample, tab: .cleanup, theme: .nativeGlass)
        storageModel.onToggleDetachedWindow = {}
        let shot2 = SequoiaWindowCanvas(canvasSize: CGSize(width: 980, height: 720), windowCornerRadius: 14) {
            DashboardView(model: storageModel)
                .frame(width: 920, height: 660)
                .background(Color(red: 0.10, green: 0.11, blue: 0.14))
        }
        writeScreenshot(
            shot2,
            size: CGSize(width: 980, height: 720),
            to: outputURL.appendingPathComponent("02-deep-storage-indexer-cleanup.png")
        )

        // 3. Notch Dynamic Island (Inline Reply + AskUserQuestion Chips) & Floating Companion
        let inlineSteerNotchSnapshot = IslandSurfaceSnapshot(
            activeAgentCount: 2,
            waitingAgentCount: 1,
            pendingApprovalCount: 0,
            serverCount: 1,
            primaryAgentName: "Codex",
            primaryAgentTask: "Running: swift test --filter Phase6SessionAndStorageTests",
            isWaitingForInput: true,
            canInlineSteerPrimary: true,
            primarySteerModeSummary: "WezTerm (ttys004)",
            theme: .nativeGlass
        )
        let questionNotchSnapshot = IslandSurfaceSnapshot(
            activeAgentCount: 2,
            waitingAgentCount: 1,
            pendingApprovalCount: 1,
            serverCount: 1,
            primaryAgentName: "Claude Code",
            primaryAgentTask: "Waiting for question answer",
            isWaitingForInput: true,
            firstApprovalID: "question-1",
            firstApprovalToolName: "Claude Code · AskUserQuestion",
            firstApprovalSummary: "Which verification target should run before packaging Suyoi Next?",
            firstApprovalIsQuestion: true,
            firstApprovalOptions: ["SuyoiCoreTests", "Full Suite + App", "Skip Tests", "Lint Only"],
            canInlineSteerPrimary: true,
            primarySteerModeSummary: "Terminal (ttys007)",
            theme: .nativeGlass
        )
        let islandShowcase = ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.08, blue: 0.15),
                    Color(red: 0.04, green: 0.05, blue: 0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("NOTCH DYNAMIC ISLAND · INLINE TERMINAL STEERING (WEZTERM / KITTY / TMUX / TTY)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(0.6)
                        .foregroundStyle(.white.opacity(0.65))
                    IslandWindowController.debugNotchPreview(
                        snapshot: inlineSteerNotchSnapshot,
                        isReplyingInline: true,
                        replyDraft: "/test and summarize any failing assertions",
                        isHovered: true
                    )
                    .frame(width: 460, height: 104)
                    .shadow(color: .black.opacity(0.55), radius: 16, y: 8)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("NOTCH DYNAMIC ISLAND · INTERACTIVE ASKUSERQUESTION OPTION CHIPS")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(0.6)
                        .foregroundStyle(.white.opacity(0.65))
                    IslandWindowController.debugNotchPreview(
                        snapshot: questionNotchSnapshot,
                        isReplyingInline: false,
                        replyDraft: "",
                        isHovered: true
                    )
                    .frame(width: 460, height: 104)
                    .shadow(color: .black.opacity(0.55), radius: 16, y: 8)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("FLOATING COMPANION · INLINE REPLY COMPOSER")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(0.6)
                        .foregroundStyle(.white.opacity(0.65))
                    IslandWindowController.debugBuddyPreview(
                        snapshot: inlineSteerNotchSnapshot,
                        isReplyingInline: true,
                        replyDraft: "/diff"
                    )
                    .frame(width: 340, height: 78)
                    .shadow(color: .black.opacity(0.55), radius: 16, y: 8)
                }
            }
            .padding(28)
        }
        .frame(width: 760, height: 450)
        .environment(\.colorScheme, .dark)

        writeScreenshot(
            islandShowcase,
            size: CGSize(width: 760, height: 450),
            to: outputURL.appendingPathComponent("03-notch-island-inline-steer-questions.png")
        )

        // 4. Quotas + Burn-Rate Depletion Forecast + Best Headroom Recommendation
        let quotasModel = DashboardModel(fixture: showcaseSample, tab: .quotas, theme: .nativeGlass)
        quotasModel.onToggleDetachedWindow = {}
        let shot4 = SequoiaWindowCanvas(canvasSize: CGSize(width: 980, height: 720), windowCornerRadius: 14) {
            DashboardView(model: quotasModel)
                .frame(width: 920, height: 660)
                .background(Color(red: 0.10, green: 0.11, blue: 0.14))
        }
        writeScreenshot(
            shot4,
            size: CGSize(width: 980, height: 720),
            to: outputURL.appendingPathComponent("04-quotas-burn-rate-forecast.png")
        )

        // 5. Settings: One-Click Claude Hook Installer + Read-Only Auto-Approve + Slash Snippets
        let settingsModel = DashboardModel(fixture: showcaseSample, tab: .agents, theme: .nativeGlass)
        let shot5 = SequoiaWindowCanvas(canvasSize: CGSize(width: 490, height: 800), windowCornerRadius: 14) {
            SettingsView(model: settingsModel)
                .frame(width: 410, height: 740)
                .background(Color(red: 0.11, green: 0.12, blue: 0.15))
        }
        writeScreenshot(
            shot5,
            size: CGSize(width: 490, height: 800),
            to: outputURL.appendingPathComponent("05-settings-hooks-readonly-snippets.png")
        )

        // 6. Pixel Arcade Theme Showcase (920x660)
        let pixelModel = DashboardModel(fixture: showcaseSample, tab: .agents, theme: .pixelArcade)
        pixelModel.onToggleDetachedWindow = {}
        let shot6 = SequoiaWindowCanvas(canvasSize: CGSize(width: 980, height: 720), windowCornerRadius: 14) {
            DashboardView(model: pixelModel)
                .frame(width: 920, height: 660)
                .background(Color(red: 0.07, green: 0.08, blue: 0.11))
        }
        writeScreenshot(
            shot6,
            size: CGSize(width: 980, height: 720),
            to: outputURL.appendingPathComponent("06-pixel-arcade-theme.png")
        )

        print("Exported 6 Retina screenshots to \(outputURL.path)")
        exit(0)
    }

    @MainActor
    private static func writeScreenshot<Content: View>(
        _ content: Content,
        size: CGSize,
        to destinationURL: URL
    ) {
        let darkContent = content
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.isOpaque = true
        window.backgroundColor = NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.10, alpha: 1.0)
        if let darkAqua = NSAppearance(named: .darkAqua) {
            window.appearance = darkAqua
        }

        let hostingView = NSHostingView(rootView: darkContent)
        hostingView.frame = NSRect(origin: .zero, size: size)
        if let darkAqua = NSAppearance(named: .darkAqua) {
            hostingView.appearance = darkAqua
        }
        window.contentView = hostingView
        window.setFrameOrigin(NSPoint(x: 80, y: 80))
        window.makeKeyAndOrderFront(nil)

        RunLoop.main.run(until: Date().addingTimeInterval(0.28))
        activateVisualEffectsRecursively(in: hostingView)
        hostingView.needsLayout = true
        hostingView.layoutSubtreeIfNeeded()
        hostingView.needsDisplay = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))

        let pixelWidth = Int(size.width * 2.0)
        let pixelHeight = Int(size.height * 2.0)
        var pngData: Data?

        if let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) {
            bitmapRep.size = size
            hostingView.cacheDisplay(in: hostingView.bounds, to: bitmapRep)
            if bitmapHasVisibleContent(bitmapRep) {
                pngData = bitmapRep.representation(using: .png, properties: [:])
            }
        }

        if pngData == nil {
            let renderer = ImageRenderer(content: darkContent)
            renderer.scale = 2.0
            if let nsImage = renderer.nsImage,
               let tiff = nsImage.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff) {
                pngData = rep.representation(using: .png, properties: [:])
            }
        }

        window.orderOut(nil)

        guard let finalPNG = pngData, finalPNG.count > 2_048 else {
            fputs("Failed to rasterize non-empty PNG for \(destinationURL.lastPathComponent)\n", stderr)
            exit(1)
        }
        do {
            try finalPNG.write(to: destinationURL, options: .atomic)
            print("Saved \(destinationURL.lastPathComponent) (\(finalPNG.count) bytes, \(pixelWidth)x\(pixelHeight) px)")
        } catch {
            fputs("Failed to write \(destinationURL.path): \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func activateVisualEffectsRecursively(in view: NSView) {
        if let darkAqua = NSAppearance(named: .darkAqua) {
            view.appearance = darkAqua
        }
        if let effectView = view as? NSVisualEffectView {
            effectView.state = .active
            effectView.material = .hudWindow
        }
        for subview in view.subviews {
            activateVisualEffectsRecursively(in: subview)
        }
    }

    private static func bitmapHasVisibleContent(_ rep: NSBitmapImageRep) -> Bool {
        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        guard w > 20, h > 20 else { return false }
        var distinctShades = Set<Int>()
        for yStep in stride(from: h / 8, to: h, by: max(1, h / 8)) {
            for xStep in stride(from: w / 8, to: w, by: max(1, w / 8)) {
                if let color = rep.colorAt(x: xStep, y: yStep)?.usingColorSpace(.deviceRGB) {
                    let bucket = Int(color.redComponent * 255) * 65_536
                        + Int(color.greenComponent * 255) * 256
                        + Int(color.blueComponent * 255)
                    distinctShades.insert(bucket)
                    if distinctShades.count >= 4 {
                        return true
                    }
                }
            }
        }
        return false
    }

    @MainActor
    private struct SequoiaWindowCanvas<Content: View>: View {
        let canvasSize: CGSize
        let windowCornerRadius: CGFloat
        @ViewBuilder let content: () -> Content

        var body: some View {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.07, green: 0.09, blue: 0.16),
                        Color(red: 0.04, green: 0.05, blue: 0.09)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                content()
                    .clipShape(RoundedRectangle(cornerRadius: windowCornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: windowCornerRadius, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.6), radius: 22, y: 10)
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .environment(\.colorScheme, .dark)
        }
    }

    @MainActor
    private final class WindowDelegate: NSObject, NSApplicationDelegate {
        private let tab: DashboardTab
        private let theme: SuyoiExperienceTheme
        private let sample: Sample
        private var window: NSWindow?

        init(tab: DashboardTab, theme: SuyoiExperienceTheme, sample: Sample) {
            self.tab = tab
            self.theme = theme
            self.sample = sample
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            let model = DashboardModel(fixture: sample, tab: tab, theme: theme)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: AppDelegate.popoverSize),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Suyoi Fixture · \(tab.rawValue) · \(theme.rawValue)"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(
                rootView: DashboardView(model: model).allowsHitTesting(false).accessibilityHidden(true)
            )
            window.center()
            window.makeKeyAndOrderFront(nil)
            self.window = window
        }

        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
            true
        }
    }

    struct Sample {
        let root = URL(fileURLWithPath: "/fixture/workspaces", isDirectory: true)
        let inventory: InventorySnapshot
        let quotas: QuotaSnapshot
        let liveQuotas: [QuotaProvider: ProviderQuotaStatus]
        let cleanup: CleanupReport
        let staleSessionLogs: [StaleSessionLogSummary]
        let sessionTargets: [NativeSessionTarget]
        let selectedSteerSessionID: String?
        let steeringAgentID: Int?
        let instruction: String
        let approvals: [PendingApprovalRequest]
        let turnPreviews: [Int: SessionTurnPreview]
        let surfaceMode: SuyoiSurfaceMode
        let worktreeCollisions: [WorktreeCollisionGroup]
        let worktreeDiffs: [String: WorktreeDiffSummary]
        let orphanToolProcesses: [OrphanToolProcess]
        let stuckAgents: [Int: StuckAgentDiagnostic]
        let continuationJobs: [NativeContinuationJob]
        let claudeHookStatus: ClaudeHookInstallStatus
        let includePreToolUseHook: Bool
        let scopedApprovalPolicy: ScopedApprovalPolicy
        let autoApprovedToolHistory: [AutoApprovedToolRecord]
        let customSnippets: [SteeringSnippet]
        let burnRateTracker: QuotaBurnRateTracker
        let indexedSessions: [IndexedAgentSession]
        let turnsBySessionID: [String: [SessionChatTurn]]
        let storageReport: StorageIndexReport
        let storageProgress: StorageIndexProgress
        let selectedStorageItemIDs: Set<String>

        fileprivate init(scenario: Scenario) {
            let now = Date()
            let web = ProjectContext(rootPath: root.path + "/customer-dashboard",
                name: "customer-dashboard", framework: "Next.js",
                gitBranch: "feature/account-usage-and-reset-windows", gitCommit: "e8bc410", isWorktree: true)
            let service = ProjectContext(rootPath: root.path + "/notification-service",
                name: "notification-service", framework: "SwiftPM", gitBranch: "main", gitCommit: "c7ab391", isWorktree: false)
            let codex = ObservedProcess(pid: 90_101, parentPID: 1, uid: 501, cpuPercent: 14.2,
                residentBytes: 436_000_000, executable: "/fixture/bin/codex", startTimeMicroseconds: 101,
                cwd: scenario == .steering ? "/" : web.rootPath, tty: scenario == .showcase ? "ttys004" : nil)
            let claude = ObservedProcess(pid: 90_102, parentPID: 1, uid: 501, cpuPercent: 0.4,
                residentBytes: 324_000_000, executable: "/fixture/bin/claude", startTimeMicroseconds: 102,
                cwd: service.rootPath, tty: "ttys007")
            let openCode = ObservedProcess(pid: 90_103, parentPID: 1, uid: 501, cpuPercent: 92.4,
                residentBytes: 170_000_000, executable: "/fixture/bin/opencode", startTimeMicroseconds: 103,
                cwd: web.rootPath, tty: scenario == .showcase ? "ttys009" : nil)
            let server = ObservedProcess(pid: 90_104, parentPID: codex.pid, uid: 501, cpuPercent: 2.8,
                residentBytes: 592_000_000, executable: "/fixture/bin/node", startTimeMicroseconds: 104, cwd: web.rootPath)
            let orphanMCP1 = ObservedProcess(pid: 90_210, parentPID: 1, uid: 501, cpuPercent: 0.1,
                residentBytes: 84_000_000, executable: "/fixture/bin/node", startTimeMicroseconds: 210, cwd: web.rootPath)
            let orphanMCP2 = ObservedProcess(pid: 90_211, parentPID: 1, uid: 501, cpuPercent: 0.0,
                residentBytes: 62_000_000, executable: "/fixture/bin/npx", startTimeMicroseconds: 211, cwd: service.rootPath)

            let ports = [3000, 3001, 5173]
            let listeners = ports.map { Listener(pid: server.pid, processName: "node", address: "127.0.0.1", port: $0) }
            let codexSession = "205926f6-c738-4b6a-8204-e032447c1303"
            let agents = [
                AgentObservation(id: codex.pid, agentName: "Codex", process: codex,
                    project: scenario == .steering ? nil : web,
                    terminalApp: scenario == .showcase ? "WezTerm" : nil,
                    statusSource: .processOnly,
                    childServerPorts: ports, activityState: .active, activityDetail: "Active CPU / running child command",
                    lastActivityAt: now, sessionID: scenario == .steering ? nil : codexSession,
                    currentTask: scenario == .steering ? nil : "Running: swift test --filter Phase5FeaturesTests"),
                AgentObservation(id: claude.pid, agentName: "Claude Code", process: claude, project: service,
                    terminalApp: "Terminal", statusSource: .processOnly, childServerPorts: [],
                    activityState: .waiting, activityDetail: "Waiting for tool approval",
                    lastActivityAt: now.addingTimeInterval(-25),
                    sessionID: "06eb0a11-b8aa-464e-834b-eb7eced111e4",
                    currentTask: "Pending Bash approval: swift test"),
                AgentObservation(id: openCode.pid, agentName: "OpenCode", process: openCode, project: web,
                    terminalApp: scenario == .showcase ? "kitty" : nil,
                    statusSource: .processOnly, childServerPorts: [],
                    activityState: scenario == .showcase ? .active : .idle,
                    activityDetail: scenario == .showcase ? "Sustained CPU in shared worktree" : "No process activity detected",
                    lastActivityAt: now.addingTimeInterval(-190),
                    currentTask: scenario == .showcase ? "Refactoring customer-dashboard routes" : nil)
            ]
            let group = ServerGroup(id: "fixture-web", rootPID: server.pid, name: "Customer dashboard",
                memberPIDs: [server.pid], memberIdentities: [server.identity], listeners: listeners, project: web,
                cpuPercent: 2.8, residentBytes: server.residentBytes, footprintBytes: nil,
                startedAt: now.addingTimeInterval(-9_500), stoppedByAgentBoundary: true)
            inventory = InventorySnapshot(
                processes: [codex, claude, openCode, server, orphanMCP1, orphanMCP2],
                listeners: listeners,
                warnings: [],
                capturedAt: now,
                agentObservations: agents,
                serverGroups: [group],
                projectsByPath: [web.rootPath: web, service.rootPath: service]
            )
            let codexUsage = TokenUsageSummary(windowMinutes: 300, startedAt: now.addingTimeInterval(-18_000),
                endedAt: now, inputTokens: 23_456, outputTokens: 8_028, cacheReadTokens: 184_000,
                totalTokens: 215_484, status: .complete)
            let claudeUsage = TokenUsageSummary(windowMinutes: 300, startedAt: now.addingTimeInterval(-18_000),
                endedAt: now, inputTokens: 61_200, outputTokens: 19_410, cacheReadTokens: 412_000,
                totalTokens: 492_610, status: .complete)
            quotas = QuotaSnapshot(capturedAt: now, providers: [
                ProviderQuotaStatus(provider: .claude, source: .localTelemetry, observedAt: now,
                    status: .complete, tokenUsage: [claudeUsage]),
                ProviderQuotaStatus(provider: .codex, source: .localTelemetry, observedAt: now,
                    status: .complete, tokenUsage: [codexUsage]),
                ProviderQuotaStatus(provider: .openCode, source: .localTelemetry, observedAt: now, status: .partial,
                    warnings: ["Seven-day usage is unavailable"])
            ])

            let claudeFiveHour = QuotaWindow(kind: .fiveHour, windowMinutes: 300, usedPercent: 56, resetsAt: now.addingTimeInterval(6_900))
            let claudeSevenDay = QuotaWindow(kind: .sevenDay, windowMinutes: 10_080, usedPercent: 48, resetsAt: now.addingTimeInterval(312_000))
            let codexFiveHour = QuotaWindow(kind: .fiveHour, windowMinutes: 300, usedPercent: 17, resetsAt: now.addingTimeInterval(5_400))
            let codexSevenDay = QuotaWindow(kind: .sevenDay, windowMinutes: 10_080, usedPercent: 31, resetsAt: now.addingTimeInterval(274_500))

            liveQuotas = [
                .claude: ProviderQuotaStatus(
                    provider: .claude,
                    source: .liveAPI,
                    observedAt: now,
                    status: scenario == .showcase ? .complete : .unavailable,
                    planType: scenario == .showcase ? "Max 5x" : nil,
                    windows: scenario == .showcase ? [claudeFiveHour, claudeSevenDay] : [],
                    warnings: scenario == .showcase ? [] : ["Local OAuth credential unavailable"]
                ),
                .codex: ProviderQuotaStatus(
                    provider: .codex,
                    source: .liveAPI,
                    observedAt: now,
                    status: .complete,
                    planType: "Pro",
                    windows: [codexFiveHour, codexSevenDay]
                )
            ]

            var tracker = QuotaBurnRateTracker()
            if scenario == .showcase {
                let earlier = now.addingTimeInterval(-1_800)
                tracker.record(
                    windowsByProvider: [
                        .claude: [
                            QuotaWindow(kind: .fiveHour, windowMinutes: 300, usedPercent: 37, resetsAt: claudeFiveHour.resetsAt),
                            claudeSevenDay
                        ],
                        .codex: [
                            QuotaWindow(kind: .fiveHour, windowMinutes: 300, usedPercent: 14, resetsAt: codexFiveHour.resetsAt),
                            codexSevenDay
                        ]
                    ],
                    at: earlier
                )
                tracker.record(
                    windowsByProvider: [
                        .claude: [claudeFiveHour, claudeSevenDay],
                        .codex: [codexFiveHour, codexSevenDay]
                    ],
                    at: now
                )
            }
            burnRateTracker = tracker

            let identity = FileIdentity(device: -1, inode: 0)
            let artifacts = [
                CleanupCandidate(path: service.rootPath + "/.build", category: "Swift build", bytes: 8_800_000_000,
                    partial: false, allocatedBytes: 8_650_000_000, fileIdentity: identity),
                CleanupCandidate(path: web.rootPath + "/node_modules", category: "Dependencies", bytes: 1_800_000_000,
                    partial: false, allocatedBytes: 1_745_000_000, fileIdentity: identity)
            ]
            let blocked = WorktreeRecord(path: root.path + "/customer-dashboard-draft", branch: "refs/heads/feature/archived-reporting",
                headCommit: "e8bc410", isMain: false, isDirty: true, isLocked: false, isMergedToDefault: true, usage: .clear,
                blockedReasons: ["Worktree contains ignored local files"])
            cleanup = CleanupReport(candidates: artifacts, warnings: [], partial: false, worktrees: [blocked], assessments: [
                artifacts[0].id: SafetyAssessment(candidateID: artifacts[0].id, usage: .clear, regenerability: .cacheDirectory,
                    blockedReasons: [], isReviewableForTrash: true),
                artifacts[1].id: SafetyAssessment(candidateID: artifacts[1].id, usage: .inUse, regenerability: .lockfileVerified("pnpm-lock.yaml"),
                    blockedReasons: ["A development server is using this workspace"], isReviewableForTrash: false)
            ], discoveredCount: artifacts.count)
            staleSessionLogs = [
                StaleSessionLogSummary(id: codexSession, agentName: "Codex", path: root.path + "/older-session.jsonl",
                    bytes: 16_000_000, modifiedAt: now.addingTimeInterval(-1_728_000), identity: identity)
            ]
            sessionTargets = scenario == .steering ? [
                .dashboardFixture(sessionID: codexSession, projectPath: web.rootPath, title: "Account usage dashboard",
                    updatedAt: now, rowIdentity: codex.identity),
                .dashboardFixture(sessionID: "e23f271e-13af-457c-af96-8743db93761b", projectPath: service.rootPath,
                    title: "Notification delivery tests", updatedAt: now.addingTimeInterval(-2_700), rowIdentity: codex.identity)
            ] : []
            selectedSteerSessionID = nil
            steeringAgentID = scenario == .showcase ? codex.pid : nil
            instruction = scenario == .steering
                ? "Check the failing browser fixture."
                : (scenario == .showcase ? "/test --filter Phase5FeaturesTests" : "")
            approvals = (scenario == .approval || scenario == .showcase) ? [
                PendingApprovalRequest(
                    id: "fixture-approval",
                    sessionID: "06eb0a11-b8aa-464e-834b-eb7eced111e4",
                    agentName: "Claude Code",
                    pid: claude.pid,
                    projectPath: service.rootPath,
                    toolName: "Bash",
                    summary: "swift test --filter NotificationDeliveryTests",
                    questionOptions: [],
                    requestedAt: now
                )
            ] : []
            turnPreviews = scenario == .steering ? [:] : [
                codex.pid: SessionTurnPreview(
                    sessionID: codexSession,
                    lastUserPromptPreview: "Verify WezTerm steering and slash snippet expansion.",
                    lastAssistantReplyPreview: "Updated AgentSteerer and running Phase5FeaturesTests now.",
                    recentTools: [SessionToolCallSummary(toolName: "swift", targetSummary: "swift test", status: "running")],
                    updatedAt: now
                )
            ]
            surfaceMode = scenario == .showcase ? .notchIsland : .menuBarPopover

            if scenario == .showcase {
                worktreeCollisions = [
                    WorktreeCollisionGroup(
                        projectPath: web.rootPath,
                        projectName: "customer-dashboard",
                        gitBranch: web.gitBranch,
                        agentIDs: [codex.pid, openCode.pid],
                        agentNames: ["Codex", "OpenCode"],
                        activeCount: 2
                    )
                ]
                worktreeDiffs = [
                    web.rootPath: WorktreeDiffSummary(
                        projectPath: web.rootPath,
                        changedFiles: 4,
                        untrackedFiles: 1,
                        addedLines: 142,
                        deletedLines: 38,
                        sampleFiles: [
                            "Sources/SuyoiCore/AgentSteerer.swift",
                            "Sources/SuyoiApp/IslandWindowController.swift",
                            "Tests/SuyoiCoreTests/Phase5FeaturesTests.swift"
                        ]
                    ),
                    service.rootPath: WorktreeDiffSummary(
                        projectPath: service.rootPath,
                        changedFiles: 2,
                        untrackedFiles: 0,
                        addedLines: 49,
                        deletedLines: 11,
                        sampleFiles: ["Sources/NotificationService/Dispatcher.swift"]
                    )
                ]
                orphanToolProcesses = [
                    OrphanToolProcess(process: orphanMCP1, kindLabel: "filesystem-mcp"),
                    OrphanToolProcess(process: orphanMCP2, kindLabel: "playwright-mcp")
                ]
                stuckAgents = [
                    openCode.pid: StuckAgentDiagnostic(
                        agentID: openCode.pid,
                        consecutiveHighCPUSamples: 7,
                        cpuPercent: 92.4,
                        summary: "92% CPU across 7 samples without session progress"
                    )
                ]
                continuationJobs = [
                    NativeContinuationJob(
                        id: UUID(),
                        agentID: codex.pid,
                        agentName: "Codex",
                        sessionID: codexSession,
                        projectPath: web.rootPath,
                        executableName: "codex",
                        pid: 90_412,
                        startedAt: now.addingTimeInterval(-18),
                        state: .running
                    ),
                    NativeContinuationJob(
                        id: UUID(),
                        agentID: codex.pid,
                        agentName: "Codex",
                        sessionID: codexSession,
                        projectPath: web.rootPath,
                        executableName: "codex",
                        pid: 90_388,
                        startedAt: now.addingTimeInterval(-420),
                        endedAt: now.addingTimeInterval(-395),
                        state: .completed
                    )
                ]
                claudeHookStatus = .installed(
                    command: "\"/Applications/Suyoi Next.app/Contents/MacOS/Suyoi\" --hook-bridge",
                    includesPreToolUse: true
                )
                includePreToolUseHook = true
                scopedApprovalPolicy = ScopedApprovalPolicy(
                    autoApproveReadOnlyTools: true,
                    applyToAllVerifiedProjects: false,
                    allowedProjectPaths: [web.rootPath]
                )
                autoApprovedToolHistory = [
                    AutoApprovedToolRecord(
                        agentName: "Codex",
                        toolName: "Read",
                        projectPath: web.rootPath,
                        summary: "Sources/SuyoiCore/AgentSteerer.swift",
                        approvedAt: now.addingTimeInterval(-45)
                    ),
                    AutoApprovedToolRecord(
                        agentName: "Codex",
                        toolName: "Grep",
                        projectPath: web.rootPath,
                        summary: "preferredMode",
                        approvedAt: now.addingTimeInterval(-30)
                    ),
                    AutoApprovedToolRecord(
                        agentName: "Claude Code",
                        toolName: "Bash",
                        projectPath: web.rootPath,
                        summary: "git status --porcelain",
                        approvedAt: now.addingTimeInterval(-12)
                    )
                ]
                customSnippets = [
                    SteeringSnippet(
                        id: "custom-lint",
                        trigger: "/lint",
                        title: "SwiftLint Strict",
                        prompt: "Run SwiftLint and fix all strict warnings without changing public APIs.",
                        isBuiltIn: false
                    )
                ]
            } else {
                worktreeCollisions = []
                worktreeDiffs = [:]
                orphanToolProcesses = []
                stuckAgents = [:]
                continuationJobs = []
                claudeHookStatus = .notInstalled
                includePreToolUseHook = false
                scopedApprovalPolicy = ScopedApprovalPolicy()
                autoApprovedToolHistory = []
                customSnippets = []
            }

            let claudeSessionID = "06eb0a11-b8aa-464e-834b-eb7eced111e4"
            let openCodeSessionID = "ses_8892b41cf0"
            let cursorSessionID = "cursor-composer-4412"
            let geminiSessionID = "gemini-chat-91a8"

            indexedSessions = [
                IndexedAgentSession(
                    id: "codex:\(codexSession)",
                    provider: .codex,
                    agentName: "Codex",
                    sessionID: codexSession,
                    title: "Account usage dashboard & deep storage indexer",
                    projectPath: web.rootPath,
                    projectName: "customer-dashboard",
                    gitBranch: web.gitBranch,
                    updatedAt: now,
                    isLive: true,
                    liveObservation: agents[0],
                    canResumeNatively: true,
                    nativeSteerMode: .codexResume,
                    liveSteerMode: .weztermPane,
                    lastMessageSnippet: "Running Phase6SessionAndStorageTests across monorepo fixtures.",
                    turnCount: 6
                ),
                IndexedAgentSession(
                    id: "claude:\(claudeSessionID)",
                    provider: .claude,
                    agentName: "Claude Code",
                    sessionID: claudeSessionID,
                    title: "Notification delivery retry queue & dead-letter tests",
                    projectPath: service.rootPath,
                    projectName: "notification-service",
                    gitBranch: "main",
                    updatedAt: now.addingTimeInterval(-25),
                    isLive: true,
                    liveObservation: agents[1],
                    canResumeNatively: true,
                    nativeSteerMode: .claudeResume,
                    liveSteerMode: .terminalTTY,
                    lastMessageSnippet: "Waiting for Bash approval: swift test --filter NotificationDeliveryTests",
                    turnCount: 8
                ),
                IndexedAgentSession(
                    id: "opencode:\(openCodeSessionID)",
                    provider: .openCode,
                    agentName: "OpenCode",
                    sessionID: openCodeSessionID,
                    title: "Refactor customer-dashboard server routes",
                    projectPath: web.rootPath,
                    projectName: "customer-dashboard",
                    gitBranch: web.gitBranch,
                    updatedAt: now.addingTimeInterval(-190),
                    isLive: true,
                    liveObservation: agents[2],
                    canResumeNatively: true,
                    nativeSteerMode: .openCodeSession,
                    liveSteerMode: .kittyWindow,
                    lastMessageSnippet: "Inspecting App Router layout middleware and auth headers.",
                    turnCount: 5
                ),
                IndexedAgentSession(
                    id: "claude:hist-storage-v2",
                    provider: .claude,
                    agentName: "Claude Code",
                    sessionID: "91d4a7c2-4312-4091-a211-88910e43fb12",
                    title: "Fix Xcode DerivedData & pnpm store cleanup rules",
                    projectPath: "/Users/yturkkan/Developer/suyoi",
                    projectName: "suyoi",
                    gitBranch: "next",
                    updatedAt: now.addingTimeInterval(-2_100),
                    isLive: false,
                    liveObservation: nil,
                    canResumeNatively: true,
                    nativeSteerMode: .claudeResume,
                    liveSteerMode: nil,
                    lastMessageSnippet: "All 455 core tests passed; ready to resume whenever needed.",
                    turnCount: 14
                ),
                IndexedAgentSession(
                    id: "cursor:\(cursorSessionID)",
                    provider: .cursor,
                    agentName: "Cursor",
                    sessionID: cursorSessionID,
                    title: "Design system token migration for dark glass theme",
                    projectPath: "/Users/yturkkan/Developer/design-tokens",
                    projectName: "design-tokens",
                    gitBranch: "feat/sequoia-glass",
                    updatedAt: now.addingTimeInterval(-9_400),
                    isLive: false,
                    liveObservation: nil,
                    canResumeNatively: false,
                    lastMessageSnippet: "Exported updated SwiftUI color tokens and spacing scale.",
                    turnCount: 9
                ),
                IndexedAgentSession(
                    id: "gemini:\(geminiSessionID)",
                    provider: .gemini,
                    agentName: "Gemini CLI",
                    sessionID: geminiSessionID,
                    title: "Benchmark POSIX openat/fstatat vs FileManager enumerator",
                    projectPath: "/Users/yturkkan/Developer/storage-bench",
                    projectName: "storage-bench",
                    gitBranch: "main",
                    updatedAt: now.addingTimeInterval(-120),
                    isLive: false,
                    liveObservation: nil,
                    canResumeNatively: true,
                    nativeSteerMode: .geminiResume,
                    lastMessageSnippet: "fstatat AT_SYMLINK_NOFOLLOW completed 180k entries in 0.41s.",
                    turnCount: 7
                )
            ]

            turnsBySessionID = [
                "codex:\(codexSession)": [
                    SessionChatTurn(
                        id: "t1",
                        kind: .user,
                        text: "Unify live and historical agent sessions into a single console, and make sure provider names like Codex never truncate in the sidebar.",
                        timestamp: now.addingTimeInterval(-340)
                    ),
                    SessionChatTurn(
                        id: "t2",
                        kind: .toolCall,
                        text: "Sources/SuyoiCore/WorkspaceSessionIndexer.swift",
                        toolName: "Read",
                        toolStatus: "completed",
                        timestamp: now.addingTimeInterval(-310)
                    ),
                    SessionChatTurn(
                        id: "t3",
                        kind: .assistant,
                        text: "I've indexed workspace sessions across Claude Code, Codex, OpenCode, Cursor, and Gemini CLI, correlated live processes by session ID and canonical project root, and expanded the console to 920×660 with a detachable window.",
                        timestamp: now.addingTimeInterval(-240)
                    ),
                    SessionChatTurn(
                        id: "t4",
                        kind: .user,
                        text: "Now verify that monorepo node_modules containing 'history' and 'config' packages are marked Ready for Trash instead of blocked.",
                        timestamp: now.addingTimeInterval(-115)
                    ),
                    SessionChatTurn(
                        id: "t5",
                        kind: .toolCall,
                        text: "swift test --filter Phase6SessionAndStorageTests",
                        toolName: "Bash",
                        toolStatus: "running",
                        timestamp: now.addingTimeInterval(-22)
                    ),
                    SessionChatTurn(
                        id: "t6",
                        kind: .assistant,
                        text: "Replaced the over-broad substring path blocker with root-anchored sensitive path checks in DeepStorageIndexer. Running Phase6SessionAndStorageTests now to confirm Put Back recovery.",
                        timestamp: now.addingTimeInterval(-8)
                    )
                ]
            ]

            let deepItems: [IndexedStorageItem] = [
                IndexedStorageItem(
                    path: "/Users/yturkkan/Library/Developer/Xcode/DerivedData/Suyoi-fbqpmzxlk",
                    displayName: "DerivedData · Suyoi",
                    subtitle: "Xcode DerivedData build intermediates & index store",
                    projectName: "Suyoi",
                    category: .xcodeAndSimulators,
                    ecosystemLabel: "Xcode Build",
                    bytes: 9_420_000_000,
                    allocatedBytes: 9_480_000_000,
                    fileCount: 42_180,
                    lastModifiedAt: now.addingTimeInterval(-86_400 * 9),
                    fileIdentity: identity,
                    safety: .ready
                ),
                IndexedStorageItem(
                    path: "/Users/yturkkan/Developer/search-engine/target",
                    displayName: "search-engine · target",
                    subtitle: "Rust Cargo debug & release artifacts",
                    projectName: "search-engine",
                    projectRootPath: "/Users/yturkkan/Developer/search-engine",
                    category: .buildOutputs,
                    ecosystemLabel: "Rust / Cargo",
                    bytes: 7_850_000_000,
                    allocatedBytes: 7_910_000_000,
                    fileCount: 19_410,
                    lastModifiedAt: now.addingTimeInterval(-86_400 * 18),
                    fileIdentity: identity,
                    safety: .ready
                ),
                IndexedStorageItem(
                    path: "/Users/yturkkan/Developer/monorepo/apps/analytics-web/node_modules",
                    displayName: "analytics-web · node_modules",
                    subtitle: "Node / pnpm workspace dependencies",
                    projectName: "analytics-web",
                    projectRootPath: "/Users/yturkkan/Developer/monorepo/apps/analytics-web",
                    category: .dependencies,
                    ecosystemLabel: "Node / pnpm",
                    bytes: 3_240_000_000,
                    allocatedBytes: 3_390_000_000,
                    fileCount: 68_920,
                    lastModifiedAt: now.addingTimeInterval(-86_400 * 24),
                    fileIdentity: identity,
                    safety: .ready
                ),
                IndexedStorageItem(
                    path: "/Users/yturkkan/Library/pnpm/store/v3",
                    displayName: "pnpm Content-Addressable Store",
                    subtitle: "Global pnpm package store cache",
                    category: .toolchainCaches,
                    ecosystemLabel: "pnpm Store",
                    bytes: 4_120_000_000,
                    allocatedBytes: 4_200_000_000,
                    fileCount: 94_300,
                    lastModifiedAt: now.addingTimeInterval(-86_400 * 14),
                    fileIdentity: identity,
                    safety: .ready
                ),
                IndexedStorageItem(
                    path: "/Users/yturkkan/Developer/ml-pipeline/.venv",
                    displayName: "ml-pipeline · .venv",
                    subtitle: "Python virtual environment (PyTorch / uv)",
                    projectName: "ml-pipeline",
                    projectRootPath: "/Users/yturkkan/Developer/ml-pipeline",
                    category: .pythonAndEnvs,
                    ecosystemLabel: "Python venv",
                    bytes: 3_680_000_000,
                    allocatedBytes: 3_720_000_000,
                    fileCount: 28_150,
                    lastModifiedAt: now.addingTimeInterval(-86_400 * 37),
                    fileIdentity: identity,
                    safety: .highImpactReview(reason: "Virtual environment — recreate via uv sync or pip install -r requirements.txt")
                ),
                IndexedStorageItem(
                    path: "/Users/yturkkan/Library/Caches/claude-cli-nodejs",
                    displayName: "Claude Code · CLI Cache",
                    subtitle: "Regenerable AI agent runtime & update cache",
                    category: .aiAgentStorage,
                    ecosystemLabel: "Claude Code",
                    bytes: 1_490_000_000,
                    allocatedBytes: 1_510_000_000,
                    fileCount: 4_120,
                    lastModifiedAt: now.addingTimeInterval(-86_400 * 11),
                    fileIdentity: identity,
                    safety: .ready
                ),
                IndexedStorageItem(
                    path: web.rootPath + "/node_modules",
                    displayName: "customer-dashboard · node_modules",
                    subtitle: "Active Next.js workspace dependencies",
                    projectName: "customer-dashboard",
                    projectRootPath: web.rootPath,
                    category: .dependencies,
                    ecosystemLabel: "Node / pnpm",
                    bytes: 1_820_000_000,
                    allocatedBytes: 1_860_000_000,
                    fileCount: 41_200,
                    lastModifiedAt: now.addingTimeInterval(-3_600),
                    fileIdentity: identity,
                    safety: .inUse(processSummary: "node (PID 90104)")
                )
            ]

            let report = StorageIndexReport(
                items: deepItems,
                scannedRoots: [
                    "/Users/yturkkan/Developer",
                    "/Users/yturkkan/Projects",
                    "/Users/yturkkan/Code"
                ],
                scannedDirectories: 18_420,
                indexedAt: now
            )
            storageReport = report
            storageProgress = StorageIndexProgress(
                isIndexing: false,
                phase: "Complete",
                currentPath: "",
                scannedDirectories: 18_420,
                discoveredCount: deepItems.count,
                totalBytes: report.totalBytes,
                readyBytes: report.readyBytes,
                fractionCompleted: 1.0
            )
            selectedStorageItemIDs = Set(deepItems.filter { $0.safety.isRecommendedDefault }.map(\.id))
        }
    }
}

struct DashboardFixtureServices: ActionExecuting, QuotaInspecting, LiveQuotaPolling, AgentSteering, AppUpdating {
    func stopProcess(identity: ProcessIdentity, force: Bool, uid: Int) -> ProcessExecutionReport { unavailable() }
    func stopServerGroup(group: ServerGroup, processes: [ObservedProcess], force: Bool, uid: Int) -> ProcessExecutionReport { unavailable() }
    func moveCandidatesToTrash(candidates: [CleanupCandidate],
                               freshAssessment: @Sendable (CleanupCandidate) -> SafetyAssessment?) -> TrashExecutionReport { unavailable() }
    func inspectQuotas(at date: Date) -> QuotaSnapshot { unavailable() }
    func pollQuota(for provider: QuotaProvider, permission: LiveQuotaPermission, at date: Date) async -> ProviderQuotaStatus { unavailable() }
    func steer(agent: AgentObservation, prompt: String, uid: Int) -> AgentSteerOutcome { unavailable() }
    func checkForUpdates(currentVersion: String) async throws -> AppUpdateCheckResult { unavailable() }
    func stageUpdate(_ release: AppReleaseInfo, currentBundleURL: URL) async throws -> StagedAppUpdate { unavailable() }
    func launchReplacementAndRelaunch(_ staged: StagedAppUpdate, currentPID: Int32) throws { unavailable() }

    private func unavailable() -> Never {
        preconditionFailure("Live services are unavailable in the dashboard fixture.")
    }
}
#endif
