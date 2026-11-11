import AppKit
import Foundation
import ServiceManagement
import SuyoiCore
import UserNotifications

public enum DashboardTab: String, CaseIterable, Sendable {
    case agents = "Agents"
    case ports = "Servers"
    case quotas = "Quotas"
    case cleanup = "Storage"

    var symbol: String {
        switch self {
        case .agents: return "terminal.fill"
        case .ports: return "network"
        case .quotas: return "chart.bar.fill"
        case .cleanup: return "externaldrive.fill"
        }
    }
}

public enum CleanupScopeFilter: String, CaseIterable, Sendable {
    case all = "All"
    case projectBuilds = "Builds"
    case agentCaches = "Caches"
}

public enum SettingsTab: String, CaseIterable, Sendable {
    case general = "General"
    case about = "About"
}

public enum LiveQuotaTrigger: Sendable {
    case automatic
    case userInitiated
}

public struct ActionBanner: Equatable, Sendable {
    public let message: String
    public let isError: Bool

    public init(message: String, isError: Bool = false) {
        self.message = message
        self.isError = isError
    }
}

@MainActor
final class DashboardModel: ObservableObject {
    @Published var tab: DashboardTab = .agents
    @Published var cleanupFilter: CleanupScopeFilter = .all
    @Published var showOtherListeners = false
    @Published var isShowingNotesPopover = false
    @Published var snapshot: InventorySnapshot?
    @Published var quotaSnapshot: QuotaSnapshot?
    @Published var liveQuotas: [QuotaProvider: ProviderQuotaStatus] = [:]
    @Published var isLiveQuotaEnabled: Bool
    @Published var isPollingLiveQuotas = false
    @Published var cleanup: CleanupReport?
    @Published var isRefreshing = false
    @Published var isScanning = false
    @Published var isPerformingAction = false
    @Published var cleanupScannedAt: Date?
    @Published var selectedAgent: AgentObservation?
    @Published var selectedServer: ServerGroup?
    @Published var steeringAgentID: Int?
    @Published var steerPromptText: String = ""
    @Published private(set) var steerSessionTargets: [NativeSessionTarget] = []
    @Published var selectedSteerSessionID: String?
    @Published private(set) var isLoadingSteerSessions = false
    @Published var isSteering = false
    @Published var isShowingCleanupPreview = false
    @Published var isShowingSettings = false
    @Published var isPopoverPinned = false
    @Published var settingsTab: SettingsTab = .general
    @Published var providerOrder: [QuotaProvider]
    @Published var hiddenProviders: Set<QuotaProvider>
    @Published var cleanupRoot: URL
    @Published var scanAllWorkspaces: Bool
    @Published var scannedWorkspaceRoots: [URL] = []
    @Published var hoveredRowID: String?
    @Published var actionBanner: ActionBanner?
    @Published var availableUpdate: AppReleaseInfo?
    @Published var isCheckingForUpdates = false
    @Published var isInstallingUpdate = false
    @Published var areNotificationsEnabled: Bool
    @Published var isLaunchAtLoginEnabled: Bool
    @Published var recheckingCandidateIDs: Set<String> = []
    @Published var trashedHistory: [TrashedItemRecord] = []
    @Published var surfaceMode: SuyoiSurfaceMode
    @Published var experienceTheme: SuyoiExperienceTheme
    @Published var soundMode: SuyoiSoundMode
    @Published var availableSoundPacks: [OpenPeonSoundPack] = []
    @Published var selectedSoundPackID: String?
    @Published var pendingApprovals: [PendingApprovalRequest] = []
    @Published private(set) var autoApprovedSessions: [PendingApprovalRequest] = []
    @Published var agentTurnPreviews: [Int: SessionTurnPreview] = [:]
    @Published var searchQuery: String = ""
    @Published var statusBarStyle: StatusBarDisplayStyle
    @Published var selectedCleanupCandidateIDs: Set<String> = []
    @Published var staleSessionLogs: [StaleSessionLogSummary] = []
    @Published var sessionLogRetentionDays: Int = 14

    private static let providerOrderKey = "suyoi.quotaProviderOrder"
    private static let hiddenProvidersKey = "suyoi.hiddenQuotaProviders"
    private static let cleanupRootPathKey = "suyoi.cleanupRootPath"
    private static let liveQuotaEnabledKey = "suyoi.isLiveQuotaEnabled"
    private static let scanAllWorkspacesKey = "suyoi.scanAllWorkspaces"
    private static let notificationsEnabledKey = "suyoi.areNotificationsEnabled"
    private static let surfaceModeKey = "suyoi.surfaceMode"
    private static let experienceThemeKey = "suyoi.experienceTheme"
    private static let soundModeKey = "suyoi.soundMode"
    private static let selectedSoundPackIDKey = "suyoi.selectedSoundPackID"
    private static let statusBarStyleKey = "suyoi.statusBarStyle"

    let homeDirectory: URL
    private let inspector: SystemInspector?
    private let actionExecutor: any ActionExecuting
    private let quotaInspector: any QuotaInspecting
    private let liveQuotaPoller: any LiveQuotaPolling
    private let agentSteerer: any AgentSteering
    private var steerSessionGeneration = UUID()
    private var steerContext: ProcessIdentity?
    private let appUpdater: any AppUpdating
    private let trashRecoveryStore = TrashRecoveryStore()
    private let worktreeCleanupExecutor = WorktreeCleanupExecutor()
    private let sessionJumpRouter = SessionJumpRouter()
    private let turnPreviewInspector = SessionTurnPreviewInspector()
    private let approvalController = AgentApprovalController()
    private let soundPlayer = SoundEffectPlayer()
    private var approvalInboxWatcher: ApprovalInboxWatcher?
    private var previousAgentStates: [Int: AgentActivityState] = [:]
    private var hasCompletedInitialRefresh = false
    private var alertTracker = AlertStateTracker()
    private var livePollTask: Task<Void, Never>?
    private var livePollGeneration: UInt64 = 0
    private var cleanupScanTask: Task<Void, Never>?
    private var cleanupScanGeneration: UInt64 = 0

    init(
        actionExecutor: any ActionExecuting = ActionExecutor(),
        quotaInspector: any QuotaInspecting = LocalQuotaInspector(),
        liveQuotaPoller: any LiveQuotaPolling = LiveQuotaPoller(),
        agentSteerer: any AgentSteering = AgentSteerer(),
        appUpdater: any AppUpdating = AppUpdater()
    ) {
        self.inspector = SystemInspector()
        self.actionExecutor = actionExecutor
        self.quotaInspector = quotaInspector
        self.liveQuotaPoller = liveQuotaPoller
        self.agentSteerer = agentSteerer
        self.appUpdater = appUpdater
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.homeDirectory = home
        let resolvedRoot: URL
        if let savedRoot = UserDefaults.standard.string(forKey: Self.cleanupRootPathKey),
           savedRoot.hasPrefix("/"),
           FileManager.default.fileExists(atPath: savedRoot) {
            resolvedRoot = URL(fileURLWithPath: savedRoot).standardizedFileURL
        } else {
            resolvedRoot = Self.defaultCleanupRoot(home: home)
        }
        self.cleanupRoot = resolvedRoot
        if UserDefaults.standard.object(forKey: Self.liveQuotaEnabledKey) != nil {
            self.isLiveQuotaEnabled = UserDefaults.standard.bool(forKey: Self.liveQuotaEnabledKey)
        } else {
            self.isLiveQuotaEnabled = true
        }
        let resolvedScanAll: Bool
        if UserDefaults.standard.object(forKey: Self.scanAllWorkspacesKey) != nil {
            resolvedScanAll = UserDefaults.standard.bool(forKey: Self.scanAllWorkspacesKey)
        } else {
            resolvedScanAll = true
        }
        self.scanAllWorkspaces = resolvedScanAll
        self.scannedWorkspaceRoots = Self.computeWorkspaceRoots(
            primaryRoot: resolvedRoot,
            home: home,
            scanAllWorkspaces: resolvedScanAll
        )
        if let savedRaw = UserDefaults.standard.stringArray(forKey: Self.providerOrderKey) {
            var restored = savedRaw.compactMap(QuotaProvider.init(rawValue:))
            for p in QuotaProvider.allCases where !restored.contains(p) {
                restored.append(p)
            }
            self.providerOrder = restored
        } else {
            self.providerOrder = QuotaProvider.allCases
        }
        if let savedHidden = UserDefaults.standard.stringArray(forKey: Self.hiddenProvidersKey) {
            self.hiddenProviders = Set(savedHidden.compactMap(QuotaProvider.init(rawValue:)))
        } else {
            self.hiddenProviders = []
        }
        self.areNotificationsEnabled = UserDefaults.standard.bool(forKey: Self.notificationsEnabledKey)
        self.isLaunchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
        if let rawSurface = UserDefaults.standard.string(forKey: Self.surfaceModeKey),
           let mode = SuyoiSurfaceMode(rawValue: rawSurface) {
            self.surfaceMode = mode
        } else {
            self.surfaceMode = .menuBarPopover
        }
        if let rawTheme = UserDefaults.standard.string(forKey: Self.experienceThemeKey),
           let theme = SuyoiExperienceTheme(rawValue: rawTheme) {
            self.experienceTheme = theme
        } else {
            self.experienceTheme = .nativeGlass
        }
        if let rawSound = UserDefaults.standard.string(forKey: Self.soundModeKey),
           let mode = SuyoiSoundMode(rawValue: rawSound) {
            self.soundMode = mode
        } else {
            self.soundMode = .muted
        }
        let discoveredPacks = ExperienceThemeCatalog.discoverSoundPacks(homeDirectory: home)
        self.availableSoundPacks = discoveredPacks
        let savedPackID = UserDefaults.standard.string(forKey: Self.selectedSoundPackIDKey)
        if let savedPackID, discoveredPacks.contains(where: { $0.id == savedPackID }) {
            self.selectedSoundPackID = savedPackID
        } else {
            self.selectedSoundPackID = discoveredPacks.first?.id
        }
        if let rawStatusBarStyle = UserDefaults.standard.string(forKey: Self.statusBarStyleKey),
           let style = StatusBarDisplayStyle(rawValue: rawStatusBarStyle) {
            self.statusBarStyle = style
        } else {
            self.statusBarStyle = .agentsAndServers
        }
        let watcher = ApprovalInboxWatcher(
            inboxDirectory: HookBridgeClient.defaultInboxDirectory(homeDirectory: home)
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.pollApprovalInboxSpool()
            }
        }
        self.approvalInboxWatcher = watcher
        watcher.start()
    }

#if DEBUG
    init(fixture: DashboardFixture.Sample, tab: DashboardTab, theme: SuyoiExperienceTheme) {
        let services = DashboardFixtureServices()
        homeDirectory = fixture.root
        inspector = nil
        actionExecutor = services
        quotaInspector = services
        liveQuotaPoller = services
        agentSteerer = services
        appUpdater = services
        cleanupRoot = fixture.root
        isLiveQuotaEnabled = true
        scanAllWorkspaces = false
        providerOrder = QuotaProvider.allCases
        hiddenProviders = []
        areNotificationsEnabled = false
        isLaunchAtLoginEnabled = false
        surfaceMode = .menuBarPopover
        experienceTheme = theme
        soundMode = .muted
        statusBarStyle = .agentsAndServers

        self.tab = tab
        snapshot = fixture.inventory
        quotaSnapshot = fixture.quotas
        liveQuotas = fixture.liveQuotas
        cleanup = fixture.cleanup
        cleanupScannedAt = fixture.inventory.capturedAt
        scannedWorkspaceRoots = [fixture.root]
        staleSessionLogs = fixture.staleSessionLogs
        selectedAgent = fixture.inventory.agentObservations.first
        steerContext = selectedAgent?.process.identity
        steerSessionTargets = fixture.sessionTargets
        steerPromptText = fixture.instruction
        pendingApprovals = fixture.approvals
        agentTurnPreviews = fixture.turnPreviews
    }
#endif

    var agentRows: [AgentObservation] {
        guard let snapshot else { return [] }
        if !snapshot.agentObservations.isEmpty {
            return snapshot.agentObservations
        }
        return snapshot.agents.map { proc in
            AgentObservation(
                id: proc.pid,
                agentName: proc.agentName ?? proc.name,
                process: proc,
                project: proc.cwd.flatMap { snapshot.projectsByPath[$0] },
                terminalApp: nil,
                statusSource: .processOnly,
                childServerPorts: []
            )
        }
    }

    var filteredAgentRows: [AgentObservation] {
        DashboardFilterAndBadgeFormatter.filterAgents(agentRows, query: searchQuery)
    }

    var developmentServerGroups: [ServerGroup] {
        guard let snapshot else { return [] }
        if !snapshot.serverGroups.isEmpty {
            return snapshot.serverGroups.filter { group in
                let hasUserProject = group.project.map { $0.rootPath.hasPrefix(homeDirectory.path) } ?? false
                return hasUserProject || group.listeners.contains(where: { $0.isDevelopmentRuntime })
            }
        }
        return snapshot.listeners.filter(\.isDevelopmentRuntime).map { listener in
            ServerGroup(
                id: listener.id,
                rootPID: listener.pid,
                name: listener.processName,
                memberPIDs: [listener.pid],
                listeners: [listener],
                project: nil,
                cpuPercent: nil,
                residentBytes: 0,
                footprintBytes: nil,
                startedAt: nil,
                stoppedByAgentBoundary: false
            )
        }
    }

    var filteredDevelopmentServerGroups: [ServerGroup] {
        DashboardFilterAndBadgeFormatter.filterServers(developmentServerGroups, query: searchQuery)
    }

    var otherListeners: [Listener] {
        guard let snapshot else { return [] }
        let devPorts = Set(developmentServerGroups.flatMap { $0.listeners.map(\.id) })
        return snapshot.listeners.filter { !devPorts.contains($0.id) }
    }

    var filteredOtherListeners: [Listener] {
        DashboardFilterAndBadgeFormatter.filterListeners(otherListeners, query: searchQuery)
    }

    var allCleanupCandidates: [CleanupCandidate] {
        guard let cleanup else { return [] }
        return (cleanup.candidates + cleanup.agentCacheCandidates).sorted {
            if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            return $0.path < $1.path
        }
    }

    var filteredCleanupCandidates: [CleanupCandidate] {
        guard let cleanup else { return [] }
        let items: [CleanupCandidate]
        switch cleanupFilter {
        case .all:
            items = cleanup.candidates + cleanup.agentCacheCandidates
        case .projectBuilds:
            items = cleanup.candidates
        case .agentCaches:
            items = cleanup.agentCacheCandidates
        }
        let sorted = items.sorted {
            if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            return $0.path < $1.path
        }
        return DashboardFilterAndBadgeFormatter.filterCleanupCandidates(sorted, query: searchQuery)
    }

    func isHighImpactCandidate(_ candidate: CleanupCandidate) -> Bool {
        AgentCacheCatalog.isHighImpactCachePath(candidate.path, homeDirectory: homeDirectory)
    }

    var reviewableCleanupCandidates: [CleanupCandidate] {
        filteredCleanupCandidates.filter { candidate in
            assessment(for: candidate)?.isReviewableForTrash == true
                && !isHighImpactCandidate(candidate)
        }
    }

    var totalReviewableBytes: Int64 {
        reviewableCleanupCandidates.reduce(0) { $0 + $1.bytes }
    }

    var totalCleanupBytes: Int64 {
        allCleanupCandidates.reduce(0) { $0 + $1.bytes }
    }

    var activeWarnings: [String] {
        var list: [String] = []
        if tab != .cleanup && tab != .quotas, let snapshot {
            list.append(contentsOf: snapshot.warnings)
        }
        if tab == .quotas, let quotaSnapshot {
            for item in displayQuotaItems(from: quotaSnapshot) {
                list.append(contentsOf: item.combinedWarnings)
            }
        }
        if tab == .cleanup, let cleanup {
            if cleanup.partial {
                list.append("Partial scan: measurement stopped at its entry or time budget.")
            }
            list.append(contentsOf: cleanup.warnings)
        }
        var seen = Set<String>()
        return list.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    var activeQuotaProvidersCount: Int {
        guard let quotaSnapshot else { return 0 }
        return displayQuotaItems(from: quotaSnapshot).filter(\.hasAnyData).count
    }

    func togglePopoverPinned() {
        isPopoverPinned.toggle()
    }

    var visibleProvidersCount: Int {
        providerOrder.filter { !hiddenProviders.contains($0) }.count
    }

    func isProviderVisible(_ provider: QuotaProvider) -> Bool {
        !hiddenProviders.contains(provider)
    }

    func toggleProviderVisibility(_ provider: QuotaProvider) {
        if hiddenProviders.contains(provider) {
            hiddenProviders.remove(provider)
        } else {
            hiddenProviders.insert(provider)
        }
        saveQuotaPreferences()
    }

    func moveProvider(_ provider: QuotaProvider, direction: Int) {
        guard let idx = providerOrder.firstIndex(of: provider) else { return }
        let target = idx + direction
        guard target >= 0 && target < providerOrder.count else { return }
        providerOrder.swapAt(idx, target)
        saveQuotaPreferences()
    }

    func resetQuotaPreferences() {
        providerOrder = QuotaProvider.allCases
        hiddenProviders = []
        saveQuotaPreferences()
    }

    var cleanupRootDisplayPath: String {
        let path = cleanupRoot.path
        let home = homeDirectory.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    static func defaultCleanupRoot(home: URL) -> URL {
        let candidates = ["Developer", "Projects", "Code", "repos", "workspace"]
        for name in candidates {
            let url = home.appendingPathComponent(name)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return url
            }
        }
        return home.appendingPathComponent("Developer")
    }

    private static func computeWorkspaceRoots(primaryRoot: URL, home: URL, scanAllWorkspaces: Bool) -> [URL] {
        let primary = primaryRoot.standardizedFileURL
        var roots: [URL] = [primary]
        var seen: Set<String> = [primary.path]
        if scanAllWorkspaces {
            let extraFolderNames = ["Developer", "Projects", "Code", "repos", "workspace", "Desktop"]
            for folder in extraFolderNames {
                let url = home.appendingPathComponent(folder).standardizedFileURL
                guard seen.insert(url.path).inserted else { continue }
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    roots.append(url)
                }
            }
        }
        return roots
    }

    func setScanAllWorkspaces(_ enabled: Bool) {
        scanAllWorkspaces = enabled
        UserDefaults.standard.set(enabled, forKey: Self.scanAllWorkspacesKey)
        scannedWorkspaceRoots = Self.computeWorkspaceRoots(
            primaryRoot: cleanupRoot,
            home: homeDirectory,
            scanAllWorkspaces: enabled
        )
        scanCleanup(forceRestart: true)
    }

    func chooseCleanupRoot() {
        chooseCleanupRootFolder()
    }

    func chooseCleanupRootFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select Project Scan Folder"
        panel.message = "Choose the root folder where Suyoi scans for project build artifacts (node_modules, .build, target, dist, etc.)."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = cleanupRoot
        if panel.runModal() == .OK, let selected = panel.url?.standardizedFileURL {
            cleanupRoot = selected
            UserDefaults.standard.set(selected.path, forKey: Self.cleanupRootPathKey)
            scannedWorkspaceRoots = Self.computeWorkspaceRoots(
                primaryRoot: selected,
                home: homeDirectory,
                scanAllWorkspaces: scanAllWorkspaces
            )
            showBanner("Updated scan folder to \(cleanupRootDisplayPath)")
            scanCleanup(forceRestart: true)
        }
    }

    func resetCleanupRootFolder() {
        UserDefaults.standard.removeObject(forKey: Self.cleanupRootPathKey)
        cleanupRoot = Self.defaultCleanupRoot(home: homeDirectory)
        scannedWorkspaceRoots = Self.computeWorkspaceRoots(
            primaryRoot: cleanupRoot,
            home: homeDirectory,
            scanAllWorkspaces: scanAllWorkspaces
        )
        showBanner("Reset scan folder to \(cleanupRootDisplayPath)")
        scanCleanup(forceRestart: true)
    }

    private func saveQuotaPreferences() {
        UserDefaults.standard.set(providerOrder.map(\.rawValue), forKey: Self.providerOrderKey)
        UserDefaults.standard.set(Array(hiddenProviders).map(\.rawValue), forKey: Self.hiddenProvidersKey)
    }

    func displayQuotaItems(from snapshot: QuotaSnapshot) -> [CombinedProviderQuotaItem] {
        providerOrder
            .filter { !hiddenProviders.contains($0) }
            .map { provider in
                let local = snapshot.providers.first(where: { $0.provider == provider && $0.source == .localTelemetry })
                let live = isLiveQuotaEnabled ? liveQuotas[provider] : nil
                return CombinedProviderQuotaItem(provider: provider, local: local, live: live)
            }
    }

    func combinedQuotaItem(forAgentName agentName: String) -> CombinedProviderQuotaItem? {
        guard let quotaSnapshot else { return nil }
        let provider: QuotaProvider
        switch agentName {
        case "Codex": provider = .codex
        case "Claude Code": provider = .claude
        case "Gemini CLI": provider = .gemini
        case "OpenCode": provider = .openCode
        case "Cursor", "Cursor Agent": provider = .cursor
        default: return nil
        }
        guard !hiddenProviders.contains(provider) else { return nil }
        let local = quotaSnapshot.quotaSummary(for: agentName, source: .localTelemetry)
        let live = isLiveQuotaEnabled ? liveQuotas[provider] : nil
        let combined = CombinedProviderQuotaItem(provider: provider, local: local, live: live)
        return combined.hasAnyData ? combined : nil
    }

    var isSnapshotStale: Bool {
        guard let capturedAt = snapshot?.capturedAt else { return false }
        return Date().timeIntervalSince(capturedAt) > 30
    }

    func refresh() {
        guard !isRefreshing, let currentInspector = inspector else { return }
        isRefreshing = true
        let currentQuotaInspector = quotaInspector
        let previewInspector = turnPreviewInspector
        Task {
            async let invResult = Task.detached(priority: .utility) { () -> (InventorySnapshot, [Int: SessionTurnPreview]) in
                let snap = currentInspector.snapshot()
                var previews: [Int: SessionTurnPreview] = [:]
                for obs in snap.agentObservations {
                    if let preview = previewInspector.inspectPreview(for: obs, allProcesses: snap.processes) {
                        previews[obs.id] = preview
                    }
                }
                return (snap, previews)
            }.value
            async let quotaResult = Task.detached(priority: .utility) { currentQuotaInspector.inspectQuotas(at: Date()) }.value
            let ((newSnapshot, newPreviews), newQuotas) = await (invResult, quotaResult)
            snapshot = newSnapshot
            agentTurnPreviews = newPreviews
            quotaSnapshot = newQuotas
            isRefreshing = false
            pollApprovalInboxSpool()
            evaluateAgentStateAudioTransitions(currentAgents: agentRows)
            evaluateAndDeliverAlerts()
            if isLiveQuotaEnabled {
                pollLiveQuotas(trigger: .automatic)
            }
        }
    }

    func setLiveQuotaEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.liveQuotaEnabledKey)
        livePollGeneration &+= 1
        livePollTask?.cancel()
        livePollTask = nil
        isLiveQuotaEnabled = enabled
        if enabled {
            pollLiveQuotas(trigger: .userInitiated)
        } else {
            isPollingLiveQuotas = false
            liveQuotas.removeAll()
            showBanner("Live quota polling disabled (offline local mode)")
        }
    }

    func refreshLiveQuotas() {
        pollLiveQuotas(trigger: .userInitiated)
    }

    func pollLiveQuotas(trigger: LiveQuotaTrigger = .userInitiated) {
        guard isLiveQuotaEnabled else { return }
        if trigger == .automatic && isPollingLiveQuotas {
            return
        }
        livePollGeneration &+= 1
        let gen = livePollGeneration
        livePollTask?.cancel()
        isPollingLiveQuotas = true
        let poller = liveQuotaPoller
        livePollTask = Task {
            let now = Date()
            async let codexLive = poller.pollQuota(for: .codex, permission: .userInitiated, at: now)
            async let claudeLive = poller.pollQuota(for: .claude, permission: .userInitiated, at: now)
            async let geminiLive = poller.pollQuota(for: .gemini, permission: .userInitiated, at: now)
            let (codexStatus, claudeStatus, geminiStatus) = await (codexLive, claudeLive, geminiLive)
            guard !Task.isCancelled, isLiveQuotaEnabled, livePollGeneration == gen else { return }
            liveQuotas[.codex] = codexStatus
            liveQuotas[.claude] = claudeStatus
            liveQuotas[.gemini] = geminiStatus
            isPollingLiveQuotas = false
            evaluateAndDeliverAlerts()
        }
    }

    func refreshSingleLiveQuota(for provider: QuotaProvider) {
        guard isLiveQuotaEnabled else { return }
        livePollGeneration &+= 1
        let gen = livePollGeneration
        livePollTask?.cancel()
        isPollingLiveQuotas = true
        let poller = liveQuotaPoller
        livePollTask = Task {
            let status = await poller.pollQuota(for: provider, permission: .userInitiated, at: Date())
            guard !Task.isCancelled, isLiveQuotaEnabled, livePollGeneration == gen else { return }
            liveQuotas[provider] = status
            isPollingLiveQuotas = false
            evaluateAndDeliverAlerts()
        }
    }

    func scanCleanup(forceRestart: Bool = false) {
        if isScanning && !forceRestart {
            return
        }
        cleanupScanTask?.cancel()
        cleanupScanGeneration &+= 1
        let generation = cleanupScanGeneration
        isScanning = true
        let home = homeDirectory
        let retentionDays = sessionLogRetentionDays
        let currentAgents = agentRows
        let roots = Self.computeWorkspaceRoots(
            primaryRoot: cleanupRoot,
            home: home,
            scanAllWorkspaces: scanAllWorkspaces
        )
        scannedWorkspaceRoots = roots
        cleanupScanTask = Task {
            let (result, staleLogs) = await Task.detached(priority: .utility) { () -> (CleanupReport, [StaleSessionLogSummary]) in
                let service = InventoryService(safetyEvaluator: SafetyEvaluator(), worktreeInspector: WorktreeInspector())
                let report = service.scanCleanup(roots: roots, homeDirectory: home, entryLimit: 50_000_000, timeLimit: 300)
                let logScanner = SessionLogRetentionScanner(homeDirectory: home)
                let logs = logScanner.scanStaleSessionLogs(olderThanDays: retentionDays, activeAgents: currentAgents)
                let sortedReport = CleanupReport(
                    candidates: report.candidates.sorted {
                        if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
                        return $0.path < $1.path
                    },
                    warnings: report.warnings,
                    partial: report.partial,
                    agentCacheCandidates: report.agentCacheCandidates.sorted {
                        if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
                        return $0.path < $1.path
                    },
                    worktrees: report.worktrees,
                    assessments: report.assessments,
                    discoveredCount: report.discoveredCount
                )
                return (sortedReport, logs)
            }.value
            guard !Task.isCancelled, self.cleanupScanGeneration == generation else { return }
            self.cleanup = result
            self.staleSessionLogs = staleLogs
            let validIDs = Set((result.candidates + result.agentCacheCandidates).map(\.id))
            self.selectedCleanupCandidateIDs = self.selectedCleanupCandidateIDs.intersection(validIDs)
            self.cleanupScannedAt = Date()
            self.isScanning = false
        }
    }

    func assessment(for candidate: CleanupCandidate) -> SafetyAssessment? {
        cleanup?.assessments[candidate.id]
    }

    func diagnosticDetail(for candidate: CleanupCandidate) -> SafetyDiagnosticDetail? {
        guard let currentAssessment = assessment(for: candidate) else { return nil }
        return SafetyDiagnostics.explain(assessment: currentAssessment, candidate: candidate)
    }

    func recheckCandidate(_ candidate: CleanupCandidate) {
        guard cleanup != nil, !recheckingCandidateIDs.contains(candidate.id) else { return }
        recheckingCandidateIDs.insert(candidate.id)
        let home = homeDirectory
        Task {
            let updatedAssessment = await Task.detached(priority: .userInitiated) {
                let service = InventoryService(safetyEvaluator: SafetyEvaluator(), worktreeInspector: WorktreeInspector())
                return service.assessCandidateForTrash(candidate, homeDirectory: home)
            }.value
            recheckingCandidateIDs.remove(candidate.id)
            guard let currentReport = cleanup else { return }
            var updatedAssessments = currentReport.assessments
            updatedAssessments[candidate.id] = updatedAssessment
            cleanup = CleanupReport(
                candidates: currentReport.candidates,
                warnings: currentReport.warnings,
                partial: currentReport.partial,
                agentCacheCandidates: currentReport.agentCacheCandidates,
                worktrees: currentReport.worktrees,
                assessments: updatedAssessments,
                discoveredCount: currentReport.discoveredCount
            )
            let detail = SafetyDiagnostics.explain(assessment: updatedAssessment, candidate: candidate)
            showBanner(
                updatedAssessment.isReviewableForTrash
                    ? "\(URL(fileURLWithPath: candidate.path).lastPathComponent) is now ready for Trash"
                    : detail.headline,
                isError: !updatedAssessment.isReviewableForTrash
            )
        }
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        areNotificationsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.notificationsEnabledKey)
        if enabled {
            guard Bundle.main.bundleURL.pathExtension == "app" else {
                showBanner("Alert notifications enabled")
                return
            }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if granted {
                        self.showBanner("Agent waiting & quota notifications enabled")
                        self.evaluateAndDeliverAlerts()
                    } else {
                        self.showBanner("Enable Suyoi notifications in macOS System Settings", isError: true)
                    }
                }
            }
        } else {
            showBanner("Notifications disabled")
        }
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            isLaunchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
            showBanner(isLaunchAtLoginEnabled ? "Launch at Login enabled" : "Launch at Login disabled")
        } catch {
            isLaunchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
            showBanner("Move Suyoi.app to /Applications to enable Launch at Login", isError: true)
        }
    }

    private func evaluateAndDeliverAlerts() {
        var combinedQuotaMap: [QuotaProvider: ProviderQuotaStatus] = [:]
        for provider in QuotaProvider.allCases where !hiddenProviders.contains(provider) {
            if let live = liveQuotas[provider], live.status != .unavailable {
                combinedQuotaMap[provider] = live
            } else if let local = quotaSnapshot?.providers.first(where: { $0.provider == provider }),
                      local.status != .unavailable {
                combinedQuotaMap[provider] = local
            }
        }
        let events = alertTracker.evaluate(agents: agentRows, quotas: combinedQuotaMap)
        for event in events {
            switch event.kind {
            case .agentWaiting:
                soundPlayer.play(.attentionRequired, mode: soundMode, theme: experienceTheme, selectedPack: selectedSoundPack)
            case .quotaWarning, .quotaCritical:
                soundPlayer.play(.quotaWarning, mode: soundMode, theme: experienceTheme, selectedPack: selectedSoundPack)
            case .quotaReset:
                soundPlayer.play(.taskCompleted, mode: soundMode, theme: experienceTheme, selectedPack: selectedSoundPack)
            }
        }
        guard areNotificationsEnabled, !events.isEmpty else { return }
        for event in events {
            showBanner("\(event.title): \(event.body)", isError: event.kind == .quotaCritical)
            guard Bundle.main.bundleURL.pathExtension == "app" else { continue }
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = event.body
            content.sound = .default
            let request = UNNotificationRequest(identifier: event.id, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }

    // MARK: - Surface Mode, Themes, Audio & Approvals

    var selectedSoundPack: OpenPeonSoundPack? {
        if let selectedSoundPackID,
           let matched = availableSoundPacks.first(where: { $0.id == selectedSoundPackID }) {
            return matched
        }
        return availableSoundPacks.first
    }

    var themeTokens: ThemeVisualTokens {
        ExperienceThemeCatalog.tokens(for: experienceTheme)
    }

    var highestObservedQuotaPercent: Double? {
        var highest: Double?
        for provider in providerOrder where !hiddenProviders.contains(provider) {
            let status: ProviderQuotaStatus?
            if isLiveQuotaEnabled, let live = liveQuotas[provider], live.status != .unavailable {
                status = live
            } else {
                status = quotaSnapshot?.providers.first(where: { $0.provider == provider && $0.status != .unavailable })
            }
            for pct in (status?.windows ?? []).compactMap(\.usedPercent) where pct.isFinite {
                highest = max(highest ?? pct, pct)
            }
        }
        return highest
    }

    var islandSurfaceSnapshot: IslandSurfaceSnapshot {
        let agents = agentRows
        let activeCount = agents.filter { $0.activityState == .active }.count
        let waitingCount = agents.filter { $0.activityState == .waiting }.count
        let primaryAgent = agents.first(where: { $0.activityState == .waiting })
            ?? agents.first(where: { $0.activityState == .active })
            ?? agents.first
        let primaryTask = primaryAgent.flatMap { obs in
            obs.currentTask ?? agentTurnPreviews[obs.id]?.lastAssistantReplyPreview ?? obs.sessionTitle
        }
        let firstApproval = pendingApprovals.first
        return IslandSurfaceSnapshot(
            activeAgentCount: activeCount,
            waitingAgentCount: waitingCount,
            pendingApprovalCount: pendingApprovals.count,
            serverCount: developmentServerGroups.count,
            primaryAgentName: primaryAgent?.agentName,
            primaryAgentTask: primaryTask,
            isWaitingForInput: waitingCount > 0 || !pendingApprovals.isEmpty,
            firstApprovalID: firstApproval?.id,
            firstApprovalToolName: firstApproval.map { "\($0.agentName) · \($0.toolName)" },
            firstApprovalSummary: firstApproval?.summary,
            firstApprovalIsQuestion: !(firstApproval?.questionOptions.isEmpty ?? true),
            theme: experienceTheme
        )
    }

    func approvePendingRequest(id: String) {
        guard let request = pendingApprovals.first(where: { $0.id == id }),
              request.questionOptions.isEmpty else { return }
        submitApprovalDecision(.allowOnce, for: request)
    }

    func denyPendingRequest(id: String) {
        guard let request = pendingApprovals.first(where: { $0.id == id }) else { return }
        submitApprovalDecision(.deny(reason: "Denied from Notch Dynamic Island"), for: request)
    }

    func setStatusBarStyle(_ style: StatusBarDisplayStyle) {
        statusBarStyle = style
        UserDefaults.standard.set(style.rawValue, forKey: Self.statusBarStyleKey)
        showBanner("Menu bar badge set to \(style.rawValue)")
    }

    func installBuiltInRetroSoundPack() {
        do {
            let pack = try ChiptuneWaveformGenerator.installBuiltInRetroPack(homeDirectory: homeDirectory)
            reloadSoundPacks()
            setSelectedSoundPackID(pack.id)
            soundMode = .soundPack
            UserDefaults.standard.set(SuyoiSoundMode.soundPack.rawValue, forKey: Self.soundModeKey)
            soundPlayer.play(.taskCompleted, mode: .soundPack, theme: experienceTheme, selectedPack: pack)
            showBanner("Installed & activated \(pack.displayName)")
        } catch {
            showBanner("Could not install 8-bit sound pack: \(error.localizedDescription)", isError: true)
        }
    }

    func simulateApprovalRequest(isQuestion: Bool = false) {
        let sessionID = "sim-\(UUID().uuidString.prefix(8))"
        let payload: Data
        if isQuestion {
            payload = HookBridgeClient.simulatedApprovalPayload(
                sessionID: String(sessionID),
                agentName: "Claude Code",
                toolName: "AskUserQuestion",
                command: "Deploy target selection",
                question: "Which test target should run before packaging?",
                options: ["Run SuyoiCoreTests", "Full Suite + App Bundle", "Skip Tests"]
            )
        } else {
            payload = HookBridgeClient.simulatedApprovalPayload(
                sessionID: String(sessionID),
                agentName: "Claude Code",
                toolName: "Bash",
                command: "./scripts/swift-local.sh test && ./scripts/build-app.sh"
            )
        }
        if let created = approvalController.ingestHookEvent(payload) {
            pendingApprovals = approvalController.pendingRequests()
            let effectiveMode = soundMode == .muted ? .systemSounds : soundMode
            soundPlayer.play(.attentionRequired, mode: effectiveMode, theme: experienceTheme, selectedPack: selectedSoundPack)
            showBanner("Simulated \(created.toolName) request — switch to Agents tab or Notch Island")
        }
    }

    func focusPrimaryAgent() {
        let agents = agentRows
        guard let primary = agents.first(where: { $0.activityState == .waiting })
                ?? agents.first(where: { $0.activityState == .active })
                ?? agents.first else {
            return
        }
        focusTerminalOrIDE(for: primary)
    }

    func setSurfaceMode(_ mode: SuyoiSurfaceMode) {
        surfaceMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.surfaceModeKey)
        showBanner("Display surface set to \(mode.rawValue)")
    }

    func setExperienceTheme(_ theme: SuyoiExperienceTheme) {
        experienceTheme = theme
        UserDefaults.standard.set(theme.rawValue, forKey: Self.experienceThemeKey)
        showBanner("Theme changed to \(theme.rawValue)")
    }

    func setSoundMode(_ mode: SuyoiSoundMode) {
        soundMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.soundModeKey)
        if mode == .soundPack {
            reloadSoundPacks()
        }
        showBanner("Audio cues set to \(mode.rawValue)")
    }

    func setSelectedSoundPackID(_ id: String?) {
        selectedSoundPackID = id
        if let id {
            UserDefaults.standard.set(id, forKey: Self.selectedSoundPackIDKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.selectedSoundPackIDKey)
        }
    }

    func reloadSoundPacks() {
        let packs = ExperienceThemeCatalog.discoverSoundPacks(homeDirectory: homeDirectory)
        availableSoundPacks = packs
        if let selectedSoundPackID, packs.contains(where: { $0.id == selectedSoundPackID }) {
            return
        }
        selectedSoundPackID = packs.first?.id
    }

    func playTestSound(_ event: SuyoiAudioEvent = .taskCompleted) {
        let effectiveMode = soundMode == .muted ? .systemSounds : soundMode
        soundPlayer.play(event, mode: effectiveMode, theme: experienceTheme, selectedPack: selectedSoundPack)
        showBanner("Played \(event.rawValue) audio cue")
    }

    func visualProfile(for agentName: String) -> AgentClientVisualProfile {
        SessionJumpRouter.visualProfile(for: agentName)
    }

    func mascotState(for obs: AgentObservation) -> MascotAnimationState {
        let hasPending = pendingApprovals.contains { approvalController.matchesAgent($0, agent: obs) }
        return ExperienceThemeCatalog.mascotState(for: obs, hasPendingApproval: hasPending)
    }

    func turnPreview(for obs: AgentObservation) -> SessionTurnPreview? {
        agentTurnPreviews[obs.id]
    }

    func isSessionAutoApproved(for obs: AgentObservation) -> Bool {
        let matches = autoApprovedSessions.filter { request in
            approvalController.matchesAgent(request, agent: obs, verifiedSessionID: turnPreview(for: obs)?.sessionID)
        }
        return matches.count == 1
    }

    func canAutoApprove(_ request: PendingApprovalRequest) -> Bool {
        approvalController.canAutoApprove(request: request)
    }

    func revokeAutoApproval(_ request: PendingApprovalRequest) {
        approvalController.setSessionAutoApprove(false, for: request)
        autoApprovedSessions = approvalController.activeAutoApproveRequests()
    }

    func submitApprovalDecision(_ decision: ApprovalDecision, for request: PendingApprovalRequest) {
        let resolved = approvalController.submitDecision(decision, forRequestID: request.id)
        pendingApprovals = approvalController.pendingRequests()
        autoApprovedSessions = approvalController.activeAutoApproveRequests()
        guard resolved else {
            showBanner("Approval request is no longer available", isError: true)
            return
        }
        switch decision {
        case .allowOnce:
            showBanner("Approved \(request.toolName) for \(request.agentName)")
        case .allowForSession:
            showBanner("Auto-approved session for \(request.agentName)")
        case .deny:
            showBanner("Denied \(request.toolName) for \(request.agentName)")
        case .answerQuestion(let option):
            showBanner("Answered \(request.agentName): \(option)")
        }
    }

    func copyHookSnippet(for agentName: String = "Claude Code") {
        let bridgePath = Bundle.main.executableURL?.path ?? "/Applications/Suyoi.app/Contents/MacOS/Suyoi"
        let snippet = AgentApprovalController.hookSnippet(for: agentName, bridgeExecutablePath: bridgePath) + " --hook-bridge"
            + "\n# Use as a synchronous Claude Code command hook for SessionStart, SessionEnd, and one approval event."
            + "\n# Choose PreToolUse to review tool calls or PermissionRequest to review native permission prompts."
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet, forType: .string)
        showBanner("Copied \(agentName) hook integration snippet")
    }

    private func pollApprovalInboxSpool() {
        let client = HookBridgeClient(
            inboxDirectory: HookBridgeClient.defaultInboxDirectory(homeDirectory: homeDirectory),
            outboxDirectory: HookBridgeClient.defaultOutboxDirectory(homeDirectory: homeDirectory)
        )
        let addedCount = client.drainInbox(into: approvalController)
        pendingApprovals = approvalController.pendingRequests()
        autoApprovedSessions = approvalController.activeAutoApproveRequests()
        if addedCount > 0 {
            soundPlayer.play(.attentionRequired, mode: soundMode, theme: experienceTheme, selectedPack: selectedSoundPack)
        }
    }

    private func evaluateAgentStateAudioTransitions(currentAgents: [AgentObservation]) {
        var nextStates: [Int: AgentActivityState] = [:]
        var playedEvent: SuyoiAudioEvent?
        for obs in currentAgents {
            let state = obs.activityState ?? .idle
            nextStates[obs.id] = state
            guard hasCompletedInitialRefresh else { continue }
            if let previous = previousAgentStates[obs.id] {
                if previous == .active && state == .idle {
                    playedEvent = .taskCompleted
                }
            } else {
                playedEvent = .sessionStarted
            }
        }
        previousAgentStates = nextStates
        hasCompletedInitialRefresh = true
        if let playedEvent {
            soundPlayer.play(playedEvent, mode: soundMode, theme: experienceTheme, selectedPack: selectedSoundPack)
        }
    }

    // MARK: - User-Initiated Actions

    func focusTerminalOrIDE(for obs: AgentObservation) {
        let router = sessionJumpRouter
        let outcome = router.executeJump(
            for: obs,
            activatePID: { pid in
                guard let app = NSRunningApplication(processIdentifier: pid_t(pid)) else { return false }
                return app.activate(options: [.activateAllWindows])
            },
            openURL: { url in
                NSWorkspace.shared.open(url)
            }
        )
        if outcome.succeeded {
            showBanner(outcome.summary)
            return
        }
        showBanner(outcome.error ?? "Could not locate a verified session target", isError: true)
    }

    func serverHealthBadge(for group: ServerGroup) -> ServerHealthBadge? {
        ServerPresentation.healthBadge(for: group)
    }

    func namedServerURL(for group: ServerGroup) -> URL? {
        ServerPresentation.namedLocalhostURL(for: group)
    }

    func openServerInBrowser(_ group: ServerGroup) {
        guard let url = ServerPresentation.standardLocalhostURL(for: group) else {
            showBanner("No valid localhost port to open", isError: true)
            return
        }
        NSWorkspace.shared.open(url)
        showBanner("Opened \(url.absoluteString)")
    }

    func openServerNamedLocalhost(_ group: ServerGroup) {
        guard let url = ServerPresentation.namedLocalhostURL(for: group)
                ?? ServerPresentation.standardLocalhostURL(for: group) else {
            showBanner("No valid localhost URL to open", isError: true)
            return
        }
        NSWorkspace.shared.open(url)
        showBanner("Opened \(url.absoluteString)")
    }

    func copyServerURL(_ group: ServerGroup) {
        guard let url = ServerPresentation.standardLocalhostURL(for: group) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        showBanner("Copied \(url.absoluteString)")
    }

    func copyServerNamedLocalhostURL(_ group: ServerGroup) {
        guard let url = ServerPresentation.namedLocalhostURL(for: group)
                ?? ServerPresentation.standardLocalhostURL(for: group) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        showBanner("Copied \(url.absoluteString)")
    }

    var isParallelBuild: Bool { SuyoiAppIdentity.isParallelNextBuild }
    var appDisplayName: String { SuyoiAppIdentity.displayName }

    func steerMode(for obs: AgentObservation) -> AgentSteerMode? {
        AgentSteerer.preferredMode(for: obs) ?? AgentSteerer.nativeMode(for: obs)
    }

    func steerModeLabel(for obs: AgentObservation) -> String? {
        guard let mode = steerMode(for: obs) else { return nil }
        switch mode {
        case .terminalTTY:
            return "\(obs.terminalApp ?? "Terminal") (\(obs.process.tty ?? "TTY"))"
        case .tmuxPane:
            return "tmux (\(obs.process.tty ?? "TTY"))"
        case .openCodeSession:
            return "Continue an OpenCode session"
        case .codexResume:
            return "Continue a Codex session"
        case .claudeResume:
            return "Continue a Claude Code session"
        }
    }

    func toggleSteerComposer(for obs: AgentObservation) {
        if steeringAgentID == obs.id && steerContext == obs.process.identity {
            resetSteerComposer()
        } else {
            resetSteerComposer()
            steeringAgentID = obs.id
            prepareSteerSessions(for: obs)
        }
    }

    func prepareSteerSessions(for obs: AgentObservation) {
        guard steerContext != obs.process.identity else { return }
        steerContext = obs.process.identity
        steerSessionTargets = []
        selectedSteerSessionID = nil
        steerPromptText = ""
        reloadSteerSessions(for: obs)
    }

    func reloadSteerSessions(for obs: AgentObservation) {
        steerContext = obs.process.identity
        selectedSteerSessionID = nil
        let generation = UUID()
        steerSessionGeneration = generation
        guard let mode = steerMode(for: obs), !mode.isLiveTerminalDelivery else {
            steerSessionTargets = []
            isLoadingSteerSessions = false
            return
        }
        let homeDirectory = homeDirectory
        isLoadingSteerSessions = true
        Task {
            let targets = await Task.detached(priority: .userInitiated) {
                AgentTaskInspector(homeDirectory: homeDirectory).nativeSessionTargets(for: obs)
            }.value
            guard steerSessionGeneration == generation else { return }
            steerSessionTargets = targets
            isLoadingSteerSessions = false
        }
    }

    func resetSteerComposer() {
        steerSessionGeneration = UUID()
        steerContext = nil
        steeringAgentID = nil
        steerPromptText = ""
        steerSessionTargets = []
        selectedSteerSessionID = nil
        isLoadingSteerSessions = false
    }

    func canSendSteerPrompt(to obs: AgentObservation) -> Bool {
        guard !isSteering, let mode = steerMode(for: obs),
              !steerPromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return mode.isLiveTerminalDelivery || (steerContext == obs.process.identity &&
            steerSessionTargets.contains { $0.sessionID == selectedSteerSessionID })
    }

    func sendSteerPrompt(to obs: AgentObservation) {
        guard canSendSteerPrompt(to: obs), let mode = steerMode(for: obs) else { return }
        let trimmed = steerPromptText.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = steerSessionTargets.first { $0.sessionID == selectedSteerSessionID }
        isSteering = true
        let steerer = agentSteerer
        let uid = Int(getuid())
        let generation = steerSessionGeneration
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                if !mode.isLiveTerminalDelivery, let target {
                    return steerer.steer(agent: obs, target: target, prompt: trimmed, uid: uid)
                }
                return steerer.steer(agent: obs, prompt: trimmed, uid: uid)
            }.value
            isSteering = false
            if outcome.succeeded {
                if steerSessionGeneration == generation {
                    steerPromptText = ""
                    selectedSteerSessionID = nil
                    steeringAgentID = nil
                }
                showBanner(outcome.detail ?? "Sent instruction to \(obs.agentName)")
                try? await Task.sleep(nanoseconds: 350_000_000)
                refresh()
            } else {
                showBanner(outcome.error ?? "Could not steer \(obs.agentName)", isError: true)
            }
        }
    }

    func stopAgent(_ obs: AgentObservation, force: Bool = false) {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        let identity = obs.process.identity
        let executor = actionExecutor
        let uid = Int(getuid())
        let label = obs.agentName
        Task {
            let report = await Task.detached(priority: .userInitiated) {
                executor.stopProcess(identity: identity, force: force, uid: uid)
            }.value
            isPerformingAction = false
            if report.succeededCount > 0 {
                showBanner("\(force ? "Force stopped" : "Stopped") \(label) (PID \(identity.pid))")
            } else {
                let err = report.outcomes.first?.error ?? report.warnings.first ?? "Could not stop process"
                showBanner(err, isError: true)
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
            refresh()
        }
    }

    func stopServer(_ group: ServerGroup, force: Bool = false) {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        let processes = snapshot?.processes ?? []
        let executor = actionExecutor
        let uid = Int(getuid())
        let label = group.project?.name ?? group.name
        Task {
            let report = await Task.detached(priority: .userInitiated) {
                executor.stopServerGroup(group: group, processes: processes, force: force, uid: uid)
            }.value
            isPerformingAction = false
            if report.succeededCount > 0 {
                showBanner("\(force ? "Force stopped" : "Stopped") \(label) (\(report.succeededCount) proc\(report.succeededCount == 1 ? "" : "s"))")
            } else {
                let err = report.outcomes.first?.error ?? report.warnings.first ?? "Could not stop server group"
                showBanner(err, isError: true)
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
            refresh()
        }
    }

    func stopListener(_ listener: Listener) {
        guard let proc = snapshot?.processes.first(where: { $0.pid == listener.pid }) else {
            showBanner("Process \(listener.pid) is no longer running", isError: true)
            return
        }
        let singleGroup = ServerGroup(
            id: listener.id,
            rootPID: listener.pid,
            name: listener.processName,
            memberPIDs: [listener.pid],
            listeners: [listener],
            project: nil,
            cpuPercent: proc.cpuPercent,
            residentBytes: proc.residentBytes,
            footprintBytes: proc.footprintBytes,
            startedAt: nil,
            stoppedByAgentBoundary: false
        )
        stopServer(singleGroup, force: false)
    }

    func isCandidateSelected(_ candidate: CleanupCandidate) -> Bool {
        selectedCleanupCandidateIDs.contains(candidate.id)
    }

    func toggleCandidateSelection(_ candidate: CleanupCandidate) {
        guard assessment(for: candidate)?.isReviewableForTrash == true else { return }
        if selectedCleanupCandidateIDs.contains(candidate.id) {
            selectedCleanupCandidateIDs.remove(candidate.id)
        } else {
            selectedCleanupCandidateIDs.insert(candidate.id)
        }
    }

    func selectAllReviewableCandidates() {
        let ids = reviewableCleanupCandidates.map(\.id)
        if !ids.isEmpty && ids.allSatisfy({ selectedCleanupCandidateIDs.contains($0) }) {
            selectedCleanupCandidateIDs.subtract(ids)
        } else {
            selectedCleanupCandidateIDs.formUnion(ids)
        }
    }

    var selectedReviewableCandidates: [CleanupCandidate] {
        filteredCleanupCandidates.filter { candidate in
            selectedCleanupCandidateIDs.contains(candidate.id)
                && assessment(for: candidate)?.isReviewableForTrash == true
        }
    }

    var selectedReviewableBytes: Int64 {
        selectedReviewableCandidates.reduce(0) { $0 + $1.bytes }
    }

    func trashSelectedCandidates() {
        let selected = selectedReviewableCandidates
        guard !selected.isEmpty else { return }
        selectedCleanupCandidateIDs.subtract(selected.map(\.id))
        trashItems(selected)
    }

    var totalStaleSessionLogBytes: Int64 {
        staleSessionLogs.reduce(0) { $0 + $1.bytes }
    }

    func trashAllStaleSessionLogs() {
        guard !isPerformingAction, !staleSessionLogs.isEmpty else { return }
        isPerformingAction = true
        let logsToTrash = staleSessionLogs
        let home = homeDirectory
        let retentionDays = sessionLogRetentionDays
        let currentAgents = agentRows
        Task {
            let report = await Task.detached(priority: .userInitiated) {
                let scanner = SessionLogRetentionScanner(homeDirectory: home)
                let processInspector = NativeProcessInspector()
                return scanner.trashStaleLogs(
                    logsToTrash,
                    olderThanDays: retentionDays,
                    activeAgents: currentAgents,
                    liveProcesses: { processInspector.inspectProcesses(uid: Int(getuid())) }
                )
            }.value
            isPerformingAction = false
            for outcome in report.outcomes where outcome.succeeded {
                if let trashedPath = outcome.trashedURL {
                    trashRecoveryStore.record(
                        originalPath: outcome.path,
                        trashedURL: URL(fileURLWithPath: trashedPath),
                        category: "Stale Session Log (>\(retentionDays)d)",
                        bytes: outcome.bytes,
                        recovery: outcome.recovery
                    )
                }
            }
            trashedHistory = trashRecoveryStore.records()
            if report.trashedCount > 0 {
                let sizeText = ByteCountFormatter.string(fromByteCount: report.reclaimedBytes, countStyle: .file)
                showBanner("Moved \(report.trashedCount) stale session log\(report.trashedCount == 1 ? "" : "s") (\(sizeText)) to Trash")
                scanCleanup(forceRestart: true)
            } else {
                let err = report.outcomes.first?.error ?? "No stale session logs could be moved to Trash"
                showBanner(err, isError: true)
            }
        }
    }

    func trashCandidate(_ candidate: CleanupCandidate) {
        guard cleanup != nil else { return }
        selectedCleanupCandidateIDs.remove(candidate.id)
        trashItems([candidate])
    }

    func trashAllReviewable() {
        let eligible = reviewableCleanupCandidates
        guard !eligible.isEmpty else { return }
        selectedCleanupCandidateIDs.subtract(eligible.map(\.id))
        trashItems(eligible)
    }

    private func trashItems(_ candidates: [CleanupCandidate]) {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        let executor = actionExecutor
        let home = homeDirectory
        let candidatesByID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        Task {
            let report = await Task.detached(priority: .userInitiated) {
                let service = InventoryService(safetyEvaluator: SafetyEvaluator(), worktreeInspector: WorktreeInspector())
                return executor.moveCandidatesToTrash(candidates: candidates) {
                    service.assessCandidateForTrash($0, homeDirectory: home)
                }
            }.value
            isPerformingAction = false
            for outcome in report.outcomes where outcome.succeeded {
                if let trashedPath = outcome.trashedURL {
                    let candidate = candidatesByID[outcome.candidateID]
                    let category = candidate?.agentName.map { "\($0) · \(candidate?.category ?? "Cache")" }
                        ?? candidate?.category
                        ?? "Cleanup Item"
                    trashRecoveryStore.record(
                        originalPath: outcome.path,
                        trashedURL: URL(fileURLWithPath: trashedPath),
                        category: category,
                        bytes: outcome.bytes,
                        recovery: outcome.recovery
                    )
                }
            }
            trashedHistory = trashRecoveryStore.records()
            if report.trashedCount > 0 {
                let sizeText = ByteCountFormatter.string(fromByteCount: report.reclaimedBytes, countStyle: .file)
                showBanner("Moved \(report.trashedCount) item\(report.trashedCount == 1 ? "" : "s") (\(sizeText)) to Trash")
                scanCleanup(forceRestart: true)
            } else {
                let err = report.outcomes.first?.error ?? report.warnings.first ?? "No items could be moved to Trash"
                showBanner(err, isError: true)
            }
        }
    }

    func trashWorktree(_ wt: WorktreeRecord) {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        let executor = worktreeCleanupExecutor
        let worktreeURL = URL(fileURLWithPath: wt.path)
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                executor.moveToTrash(worktree: wt, parentRoot: worktreeURL)
            }.value
            isPerformingAction = false
            if outcome.trashed {
                if let trashedURL = outcome.trashedURL {
                    let branchLabel = wt.branch?.replacingOccurrences(of: "refs/heads/", with: "") ?? "merged"
                    trashRecoveryStore.record(
                        originalPath: outcome.path,
                        trashedURL: trashedURL,
                        category: "Git Worktree (\(branchLabel))",
                        bytes: 0,
                        recovery: outcome.recovery
                    )
                    trashedHistory = trashRecoveryStore.records()
                }
                showBanner("Moved worktree \(worktreeURL.lastPathComponent) to Trash")
                scanCleanup(forceRestart: true)
            } else {
                showBanner(outcome.error ?? "Could not move worktree to Trash", isError: true)
            }
        }
    }

    func canRestoreTrashedItem(_ item: TrashedItemRecord) -> Bool {
        item.fileIdentity != nil
    }

    func restoreTrashedItem(_ item: TrashedItemRecord) {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        let store = trashRecoveryStore
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                store.restore(item)
            }.value
            isPerformingAction = false
            trashedHistory = store.records()
            if outcome.restored {
                let name = URL(fileURLWithPath: item.originalPath).lastPathComponent
                showBanner("Restored \(name) to \(shortenPathForBanner(item.originalPath))")
                scanCleanup(forceRestart: true)
            } else {
                showBanner(outcome.error ?? "Could not restore item from Trash", isError: true)
            }
        }
    }

    private func shortenPathForBanner(_ path: String) -> String {
        let home = homeDirectory.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3.6"
    }

    func checkForUpdates() {
        guard !isCheckingForUpdates, !isInstallingUpdate else { return }
        isCheckingForUpdates = true
        let updater = appUpdater
        let currentVersion = currentAppVersion
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try await updater.checkForUpdates(currentVersion: currentVersion)
                }.value
                isCheckingForUpdates = false
                switch result {
                case .upToDate(let version):
                    availableUpdate = nil
                    showBanner("Suyoi v\(version) is up to date")
                case .updateAvailable(let release):
                    availableUpdate = release
                    showBanner("Suyoi v\(release.version) is ready to install")
                }
            } catch {
                isCheckingForUpdates = false
                showBanner(error.localizedDescription, isError: true)
            }
        }
    }

    func installAvailableUpdate() {
        guard let release = availableUpdate, !isInstallingUpdate else { return }
        isInstallingUpdate = true
        let updater = appUpdater
        let bundleURL = Bundle.main.bundleURL
        let pid = getpid()
        Task {
            do {
                let staged = try await Task.detached(priority: .userInitiated) {
                    try await updater.stageUpdate(release, currentBundleURL: bundleURL)
                }.value
                try updater.launchReplacementAndRelaunch(staged, currentPID: pid)
                NSApplication.shared.terminate(nil)
            } catch {
                isInstallingUpdate = false
                showBanner(error.localizedDescription, isError: true)
            }
        }
    }

    private func showBanner(_ message: String, isError: Bool = false) {
        let banner = ActionBanner(message: message, isError: isError)
        actionBanner = banner
        Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if actionBanner == banner {
                actionBanner = nil
            }
        }
    }
}
