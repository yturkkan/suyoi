import AppKit
import Foundation
import SuyoiCore

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

    private static let providerOrderKey = "suyoi.quotaProviderOrder"
    private static let hiddenProvidersKey = "suyoi.hiddenQuotaProviders"
    private static let cleanupRootPathKey = "suyoi.cleanupRootPath"
    private static let liveQuotaEnabledKey = "suyoi.isLiveQuotaEnabled"
    private static let scanAllWorkspacesKey = "suyoi.scanAllWorkspaces"

    let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    private let inspector = SystemInspector()
    private let actionExecutor: any ActionExecuting
    private let quotaInspector: any QuotaInspecting
    private let liveQuotaPoller: any LiveQuotaPolling
    private let agentSteerer: any AgentSteering
    private let appUpdater: any AppUpdating
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
        self.actionExecutor = actionExecutor
        self.quotaInspector = quotaInspector
        self.liveQuotaPoller = liveQuotaPoller
        self.agentSteerer = agentSteerer
        self.appUpdater = appUpdater
        let home = FileManager.default.homeDirectoryForCurrentUser
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
    }

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

    var otherListeners: [Listener] {
        guard let snapshot else { return [] }
        let devPorts = Set(developmentServerGroups.flatMap { $0.listeners.map(\.id) })
        return snapshot.listeners.filter { !devPorts.contains($0.id) }
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
        return items.sorted {
            if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            return $0.path < $1.path
        }
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
        guard !isRefreshing else { return }
        isRefreshing = true
        let currentInspector = inspector
        let currentQuotaInspector = quotaInspector
        Task {
            async let invResult = Task.detached(priority: .utility) { currentInspector.snapshot() }.value
            async let quotaResult = Task.detached(priority: .utility) { currentQuotaInspector.inspectQuotas(at: Date()) }.value
            let (newSnapshot, newQuotas) = await (invResult, quotaResult)
            snapshot = newSnapshot
            quotaSnapshot = newQuotas
            isRefreshing = false
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
        let roots = Self.computeWorkspaceRoots(
            primaryRoot: cleanupRoot,
            home: home,
            scanAllWorkspaces: scanAllWorkspaces
        )
        scannedWorkspaceRoots = roots
        cleanupScanTask = Task {
            let result = await Task.detached(priority: .utility) {
                let service = InventoryService(safetyEvaluator: SafetyEvaluator(), worktreeInspector: WorktreeInspector())
                let report = service.scanCleanup(roots: roots, homeDirectory: home, entryLimit: 50_000_000, timeLimit: 300)
                return CleanupReport(
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
            }.value
            guard !Task.isCancelled, self.cleanupScanGeneration == generation else { return }
            self.cleanup = result
            self.cleanupScannedAt = Date()
            self.isScanning = false
        }
    }

    func assessment(for candidate: CleanupCandidate) -> SafetyAssessment? {
        cleanup?.assessments[candidate.id]
    }

    // MARK: - User-Initiated Actions

    func focusTerminalOrIDE(for obs: AgentObservation) {
        if let pid = obs.terminalPID,
           let app = NSRunningApplication(processIdentifier: pid_t(pid)),
           app.activate(options: [.activateAllWindows]) {
            showBanner("Focused \(obs.terminalApp ?? app.localizedName ?? "Terminal")")
            return
        }
        if let hostName = obs.terminalApp?.lowercased() {
            let running = NSWorkspace.shared.runningApplications
            if let match = running.first(where: { app in
                let name = (app.localizedName ?? "").lowercased()
                let bundle = (app.bundleIdentifier ?? "").lowercased()
                return name == hostName || name.contains(hostName) || bundle.contains(hostName)
            }), match.activate(options: [.activateAllWindows]) {
                showBanner("Focused \(match.localizedName ?? obs.terminalApp ?? "window")")
                return
            }
        }
        if let path = obs.project?.rootPath ?? obs.process.cwd {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            showBanner("Revealed \(URL(fileURLWithPath: path).lastPathComponent) in Finder")
        } else {
            showBanner("Could not locate a host window to focus", isError: true)
        }
    }

    func openServerInBrowser(_ group: ServerGroup) {
        guard let port = group.listeners.first?.port,
              let url = URL(string: "http://localhost:\(port)") else {
            showBanner("No valid localhost port to open", isError: true)
            return
        }
        NSWorkspace.shared.open(url)
        showBanner("Opened http://localhost:\(port)")
    }

    func copyServerURL(_ group: ServerGroup) {
        guard let port = group.listeners.first?.port else { return }
        let urlString = "http://localhost:\(port)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urlString, forType: .string)
        showBanner("Copied \(urlString)")
    }

    func steerMode(for obs: AgentObservation) -> AgentSteerMode? {
        AgentSteerer.preferredMode(for: obs)
    }

    func steerModeLabel(for obs: AgentObservation) -> String? {
        guard let mode = steerMode(for: obs) else { return nil }
        switch mode {
        case .terminalTTY:
            return "Terminal (\(obs.process.tty ?? "TTY"))"
        case .openCodeSession:
            return "OpenCode Session"
        case .codexResume:
            return "Codex Session"
        }
    }

    func toggleSteerComposer(for obs: AgentObservation) {
        if steeringAgentID == obs.id {
            steeringAgentID = nil
            steerPromptText = ""
        } else {
            steeringAgentID = obs.id
            steerPromptText = ""
        }
    }

    func sendSteerPrompt(to obs: AgentObservation) {
        let trimmed = steerPromptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSteering else { return }
        isSteering = true
        let steerer = agentSteerer
        let uid = Int(getuid())
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                steerer.steer(agent: obs, prompt: trimmed, uid: uid)
            }.value
            isSteering = false
            if outcome.succeeded {
                steerPromptText = ""
                steeringAgentID = nil
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

    func trashCandidate(_ candidate: CleanupCandidate) {
        guard cleanup != nil else { return }
        trashItems([candidate])
    }

    func trashAllReviewable() {
        let eligible = reviewableCleanupCandidates
        guard !eligible.isEmpty else { return }
        trashItems(eligible)
    }

    private func trashItems(_ candidates: [CleanupCandidate]) {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        let executor = actionExecutor
        let home = homeDirectory
        Task {
            let report = await Task.detached(priority: .userInitiated) {
                let service = InventoryService(safetyEvaluator: SafetyEvaluator(), worktreeInspector: WorktreeInspector())
                return executor.moveCandidatesToTrash(candidates: candidates) {
                    service.assessCandidateForTrash($0, homeDirectory: home)
                }
            }.value
            isPerformingAction = false
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

    var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.8"
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
