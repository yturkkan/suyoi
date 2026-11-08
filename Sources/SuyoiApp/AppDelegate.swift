import AppKit
import Combine
import SwiftUI
import SuyoiCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let model = DashboardModel()
    private lazy var islandController = IslandWindowController(
        onOpenDashboard: { [weak self] in
            self?.showPopoverIfNeeded()
        },
        onFocusPrimaryAgent: { [weak self] in
            self?.model.focusPrimaryAgent()
        }
    )
    private var refreshTimer: Timer?
    private var globalClickMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: "Suyoi, local developer companion")
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
            button.target = self
            button.action = #selector(togglePopover)
            button.toolTip = "Suyoi · local developer companion"
        }
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 450, height: 600)
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

    private func showPopoverIfNeeded() {
        guard let button = statusItem.button, !popover.isShown else { return }
        popover.behavior = model.isPopoverPinned ? .applicationDefined : .transient
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
    }

    private func updateStatusItemBadge() {
        guard let button = statusItem.button else { return }
        let agents = model.agentRows
        let servers = model.developmentServerGroups
        let waitingCount = agents.filter { $0.activityState == .waiting }.count
        let activeCount = agents.filter { $0.activityState == .active }.count

        if agents.isEmpty && servers.isEmpty {
            button.title = ""
            button.toolTip = "Suyoi · No active agents or dev servers"
            return
        }

        var parts: [String] = []
        if !agents.isEmpty {
            if waitingCount > 0 {
                parts.append("\(agents.count)A·\(waitingCount)⏳")
            } else {
                parts.append("\(agents.count)A")
            }
        }
        if !servers.isEmpty {
            parts.append("\(servers.count)S")
        }
        button.title = " " + parts.joined(separator: " ")
        button.toolTip = "Suyoi · \(agents.count) agents (\(activeCount) active, \(waitingCount) waiting) · \(servers.count) dev servers"
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
            && model.selectedAgent == nil
            && model.selectedServer == nil
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
        scheduleRefreshTimer(interval: 10)
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeGlobalClickMonitor()
        refreshTimer?.invalidate()
    }
}
