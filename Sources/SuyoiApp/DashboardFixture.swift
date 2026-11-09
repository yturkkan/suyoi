#if DEBUG
import AppKit
import SwiftUI
import SuyoiCore

enum DashboardFixture {
    static let bundleIdentifier = "local.suyoi.fixture"

    fileprivate enum Scenario: String {
        case overview, approval, steering
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
        let instruction: String
        let approvals: [PendingApprovalRequest]
        let turnPreviews: [Int: SessionTurnPreview]

        fileprivate init(scenario: Scenario) {
            let now = Date()
            let web = ProjectContext(rootPath: root.path + "/customer-dashboard",
                name: "Customer dashboard and reporting workspace", framework: "Next.js",
                gitBranch: "feature/account-usage-and-reset-windows", gitCommit: "e8bc410", isWorktree: true)
            let service = ProjectContext(rootPath: root.path + "/notification-service",
                name: "Notification service", framework: "SwiftPM", gitBranch: "main", gitCommit: "c7ab391", isWorktree: false)
            let codex = ObservedProcess(pid: 90_101, parentPID: 1, uid: 501, cpuPercent: 8.6,
                residentBytes: 436_000_000, executable: "/fixture/bin/codex", startTimeMicroseconds: 101,
                cwd: scenario == .steering ? "/" : web.rootPath)
            let claude = ObservedProcess(pid: 90_102, parentPID: 1, uid: 501, cpuPercent: 0,
                residentBytes: 324_000_000, executable: "/fixture/bin/claude", startTimeMicroseconds: 102,
                cwd: service.rootPath, tty: "ttys007")
            let openCode = ObservedProcess(pid: 90_103, parentPID: 1, uid: 501, cpuPercent: 0,
                residentBytes: 170_000_000, executable: "/fixture/bin/opencode", startTimeMicroseconds: 103,
                cwd: web.rootPath)
            let server = ObservedProcess(pid: 90_104, parentPID: codex.pid, uid: 501, cpuPercent: 2.8,
                residentBytes: 592_000_000, executable: "/fixture/bin/node", startTimeMicroseconds: 104, cwd: web.rootPath)
            let ports = [3000, 3001, 3002, 3003, 4000, 4173, 5173, 8080]
            let listeners = ports.map { Listener(pid: server.pid, processName: "node", address: "127.0.0.1", port: $0) }
            let codexSession = "205926f6-c738-4b6a-8204-e032447c1303"
            let agents = [
                AgentObservation(id: codex.pid, agentName: "Codex", process: codex,
                    project: scenario == .steering ? nil : web, terminalApp: nil, statusSource: .processOnly,
                    childServerPorts: ports, activityState: .active, activityDetail: "Active CPU / running child command",
                    lastActivityAt: now, sessionID: scenario == .steering ? nil : codexSession,
                    currentTask: scenario == .steering ? nil : "Running: swift test"),
                AgentObservation(id: claude.pid, agentName: "Claude Code", process: claude, project: service,
                    terminalApp: "Terminal", statusSource: .processOnly, childServerPorts: [],
                    activityState: .idle, activityDetail: "No process activity detected"),
                AgentObservation(id: openCode.pid, agentName: "OpenCode", process: openCode, project: web,
                    terminalApp: nil, statusSource: .processOnly, childServerPorts: [],
                    activityState: .idle, activityDetail: "No process activity detected")
            ]
            let group = ServerGroup(id: "fixture-web", rootPID: server.pid, name: "Customer dashboard",
                memberPIDs: [server.pid], memberIdentities: [server.identity], listeners: listeners, project: web,
                cpuPercent: 2.8, residentBytes: server.residentBytes, footprintBytes: nil,
                startedAt: now.addingTimeInterval(-9_500), stoppedByAgentBoundary: true)
            inventory = InventorySnapshot(processes: [codex, claude, openCode, server], listeners: listeners,
                warnings: [], capturedAt: now, agentObservations: agents, serverGroups: [group],
                projectsByPath: [web.rootPath: web, service.rootPath: service])
            let usage = TokenUsageSummary(windowMinutes: 300, startedAt: now.addingTimeInterval(-18_000),
                endedAt: now, inputTokens: 23_456, outputTokens: 8_028, cacheReadTokens: 184_000,
                totalTokens: 215_484, status: .complete)
            quotas = QuotaSnapshot(capturedAt: now, providers: [
                ProviderQuotaStatus(provider: .codex, source: .localTelemetry, observedAt: now,
                    status: .complete, tokenUsage: [usage]),
                ProviderQuotaStatus(provider: .openCode, source: .localTelemetry, observedAt: now, status: .partial,
                    warnings: ["Seven-day usage is unavailable"])
            ])
            liveQuotas = [
                .codex: ProviderQuotaStatus(provider: .codex, source: .liveAPI, observedAt: now,
                    status: .complete, planType: "Pro", windows: [
                        QuotaWindow(kind: .fiveHour, windowMinutes: 300, usedPercent: 17, resetsAt: now.addingTimeInterval(5_400)),
                        QuotaWindow(kind: .sevenDay, windowMinutes: 10_080, usedPercent: 64, resetsAt: now.addingTimeInterval(274_500))
                    ]),
                .claude: ProviderQuotaStatus(provider: .claude, source: .liveAPI, observedAt: now,
                    status: .unavailable, warnings: ["Local OAuth credential unavailable"])
            ]
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
            instruction = scenario == .steering ? "Check the failing browser fixture." : ""
            approvals = scenario == .approval ? [
                PendingApprovalRequest(id: "fixture-approval", sessionID: "06eb0a11-b8aa-464e-834b-eb7eced111e4",
                    agentName: "Claude Code", pid: claude.pid, projectPath: service.rootPath, toolName: "Bash",
                    summary: "swift test --filter NotificationDeliveryTests", questionOptions: [], requestedAt: now)
            ] : []
            turnPreviews = scenario == .steering ? [:] : [
                codex.pid: SessionTurnPreview(sessionID: codexSession, lastUserPromptPreview: "Check the account reset labels.",
                    lastAssistantReplyPreview: "I found the quota source and am running the dashboard checks.",
                    recentTools: [SessionToolCallSummary(toolName: "swift", targetSummary: "swift test", status: "running")], updatedAt: now)
            ]
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
