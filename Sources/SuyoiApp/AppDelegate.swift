import AppKit
import Combine
import SwiftUI
import SuyoiCore
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var detachedWindow: NSWindow?
    private let model = DashboardModel()
    private lazy var islandController: IslandWindowController = {
        let controller = IslandWindowController(
            onOpenDashboard: { [weak self] in
                self?.showPopoverIfNeeded()
            },
            onFocusPrimaryAgent: { [weak self] in
                self?.model.focusPrimaryAgent()
            }
        )
        controller.onApprovePending = { [weak self] id in
            self?.model.approvePendingRequest(id: id)
        }
        controller.onDenyPending = { [weak self] id in
            self?.model.denyPendingRequest(id: id)
        }
        controller.onAnswerQuestion = { [weak self] id, option in
            self?.model.answerPendingQuestion(id: id, option: option)
        }
        controller.onQuickSteerPrimary = { [weak self] prompt in
            self?.model.quickSteerPrimaryAgent(prompt)
        }
        return controller
    }()
    private var refreshTimer: Timer?
    private var globalClickMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    static let popoverSize = NSSize(width: 920, height: 660)
    static let detachedWindowDefaultSize = NSSize(width: 980, height: 720)
    static let detachedWindowMinSize = NSSize(width: 860, height: 600)

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleURL.pathExtension == "app" {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            model.registerNotificationCategories()
        }

        model.onToggleDetachedWindow = { [weak self] in
            self?.toggleDetachedWindow()
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let symbolName = model.isParallelBuild ? "leaf.circle.fill" : "leaf.fill"
        let appName = model.appDisplayName
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "\(appName), local developer companion")
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
            button.target = self
            button.action = #selector(togglePopover)
            button.toolTip = "\(appName) · local developer companion"
        }
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = Self.popoverSize
        popover.contentViewController = NSHostingController(rootView: DashboardView(model: model))

        model.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItemBadge()
                self?.updateIslandSurface()
            }
            .store(in: &cancellables)

        model.$pendingApprovals
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItemBadge()
                self?.updateIslandSurface()
            }
            .store(in: &cancellables)

        model.$surfaceMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateIslandSurface()
            }
            .store(in: &cancellables)

        model.$experienceTheme
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateIslandSurface()
            }
            .store(in: &cancellables)

        model.$statusBarStyle
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItemBadge()
            }
            .store(in: &cancellables)

        model.$quotaSnapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItemBadge()
            }
            .store(in: &cancellables)

        model.$liveQuotas
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItemBadge()
            }
            .store(in: &cancellables)

        model.$isPopoverPinned
            .receive(on: RunLoop.main)
            .sink { [weak self] isPinned in
                guard let self else { return }
                self.popover.behavior = isPinned ? .applicationDefined : .transient
            }
            .store(in: &cancellables)

        model.refresh()
        updateIslandSurface()
        scheduleRefreshTimer(interval: 10)
    }

    private func updateIslandSurface() {
        islandController.setMode(model.surfaceMode, snapshot: model.islandSurfaceSnapshot)
    }

    func showPopoverIfNeeded() {
        if let win = detachedWindow, win.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            return
        }
        guard let button = statusItem.button, !popover.isShown else { return }
        popover.behavior = model.isPopoverPinned ? .applicationDefined : .transient
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
    }

    func toggleDetachedWindow() {
        if let existing = detachedWindow, existing.isVisible {
            existing.close()
            detachedWindow = nil
            model.isDetachedWindowOpen = false
            return
        }

        if popover.isShown {
            popover.close()
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.detachedWindowDefaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(model.appDisplayName) — Command Center"
        window.minSize = Self.detachedWindowMinSize
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: DashboardView(model: model))
        window.center()
        detachedWindow = window
        model.isDetachedWindowOpen = true
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        scheduleRefreshTimer(interval: 5)
    }

    func windowWillClose(_ notification: Notification) {
        if let closed = notification.object as? NSWindow, closed === detachedWindow {
            detachedWindow = nil
            model.isDetachedWindowOpen = false
            if !popover.isShown {
                scheduleRefreshTimer(interval: 10)
            }
        }
    }

    private func updateStatusItemBadge() {
        guard let button = statusItem.button else { return }
        let agents = model.agentRows
        let servers = model.developmentServerGroups
        let waitingCount = agents.filter { $0.activityState == .waiting }.count
        let activeCount = agents.filter { $0.activityState == .active }.count

        button.title = DashboardFilterAndBadgeFormatter.formatStatusBarTitle(
            style: model.statusBarStyle,
            agents: agents,
            servers: servers,
            pendingApprovalsCount: model.pendingApprovals.count,
            highestQuotaPercent: model.highestObservedQuotaPercent
        )

        let appName = model.appDisplayName
        if agents.isEmpty && servers.isEmpty && model.pendingApprovals.isEmpty {
            button.toolTip = "\(appName) · No active agents or dev servers"
        } else {
            button.toolTip = "\(appName) · \(agents.count) agents (\(activeCount) active, \(waitingCount) waiting) · \(servers.count) dev servers"
        }
    }

    private func scheduleRefreshTimer(interval: TimeInterval) {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.model.refresh()
            }
        }
    }

    @objc private func togglePopover() {
        if let win = detachedWindow, win.isVisible {
            if win.isKeyWindow && NSApp.isActive {
                win.orderOut(nil)
                detachedWindow = nil
                model.isDetachedWindowOpen = false
            } else {
                NSApp.activate(ignoringOtherApps: true)
                win.makeKeyAndOrderFront(nil)
            }
            return
        }
        guard let button = statusItem.button else { return }
        if popover.isShown {
            forceClosePopover()
        } else {
            popover.behavior = model.isPopoverPinned ? .applicationDefined : .transient
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
        }
    }

    private var canAutoClosePopover: Bool {
        popover.isShown
            && !model.isPopoverPinned
            && NSApp.modalWindow == nil
            && popover.contentViewController?.view.window?.attachedSheet == nil
            && !model.isShowingSettings
            && model.steeringAgentID == nil
            && !model.isSteering
            && !model.isPerformingAction
            && !model.isLoadingSteerSessions
            && model.steerPromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.consoleComposerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.selectedSteerSessionID == nil
            && !model.isShowingCleanupPreview
            && !model.isShowingNotesPopover
    }

    func applicationDidResignActive(_ notification: Notification) {
        guard canAutoClosePopover else { return }
        popover.performClose(nil)
    }

    private func forceClosePopover() {
        popover.close()
    }

    private func installGlobalClickMonitor() {
        removeGlobalClickMonitor()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.canAutoClosePopover else {
                    return
                }
                self.popover.performClose(nil)
            }
        }
    }

    private func removeGlobalClickMonitor() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
    }

    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        canAutoClosePopover
    }

    func popoverDidShow(_ notification: Notification) {
        installGlobalClickMonitor()
        model.refresh()
        scheduleRefreshTimer(interval: 5)
    }

    func popoverDidClose(_ notification: Notification) {
        removeGlobalClickMonitor()
        if detachedWindow?.isVisible != true {
            scheduleRefreshTimer(interval: 10)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeGlobalClickMonitor()
        refreshTimer?.invalidate()
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionID = response.actionIdentifier
        let userText = (response as? UNTextInputNotificationResponse)?.userText
        let userInfo = response.notification.request.content.userInfo
        let requestID = userInfo["requestID"] as? String
        let agentPID = userInfo["agentPID"] as? Int
        Task { @MainActor [weak self] in
            guard let self else { return }
            if actionID == UNNotificationDefaultActionIdentifier {
                self.showPopoverIfNeeded()
            } else {
                self.model.handleNotificationAction(
                    actionIdentifier: actionID,
                    requestID: requestID,
                    agentPID: agentPID,
                    userText: userText
                )
            }
        }
        completionHandler()
    }
}
