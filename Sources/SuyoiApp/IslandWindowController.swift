import AppKit
import SwiftUI
import SuyoiCore

struct IslandSurfaceSnapshot: Equatable {
    let activeAgentCount: Int
    let waitingAgentCount: Int
    let pendingApprovalCount: Int
    let serverCount: Int
    let primaryAgentName: String?
    let primaryAgentTask: String?
    let isWaitingForInput: Bool

    fileprivate var needsAttention: Bool {
        waitingAgentCount > 0 || pendingApprovalCount > 0 || isWaitingForInput
    }

    fileprivate var agentName: String {
        primaryAgentName.flatMap(Self.displayText) ?? "Suyoi"
    }

    fileprivate var canFocusAgent: Bool {
        primaryAgentName.flatMap(Self.displayText) != nil
    }

    fileprivate var taskSummary: String {
        if isWaitingForInput { return "Waiting for input" }
        if let task = primaryAgentTask.flatMap(Self.displayText) { return task }
        if activeAgentCount > 0 { return "Working" }
        return needsAttention ? attentionSummary : "No active agents"
    }

    fileprivate var attentionSummary: String {
        if pendingApprovalCount > 0 {
            return "\(pendingApprovalCount) approval\(pendingApprovalCount == 1 ? "" : "s") pending"
        }
        if waitingAgentCount > 0 {
            return "\(waitingAgentCount) agent\(waitingAgentCount == 1 ? "" : "s") waiting for input"
        }
        return "Waiting for input"
    }

    private static func displayText(_ text: String) -> String? {
        let bounded = String(text.prefix(256))
        let clean = String(bounded.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }).trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}

@MainActor
final class IslandWindowController: NSObject {
    var onOpenDashboard: () -> Void
    var onFocusPrimaryAgent: () -> Void

    private let state = IslandSurfaceState()
    private var mode: SuyoiSurfaceMode = .menuBarPopover
    private var notchPanel: IslandPanel?
    private var buddyPanel: IslandPanel?

    init(
        onOpenDashboard: @escaping () -> Void = {},
        onFocusPrimaryAgent: @escaping () -> Void = {}
    ) {
        self.onOpenDashboard = onOpenDashboard
        self.onFocusPrimaryAgent = onFocusPrimaryAgent
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        let panels = [notchPanel, buddyPanel]
        Task { @MainActor in
            for panel in panels { panel?.close() }
        }
    }

    func setMode(_ mode: SuyoiSurfaceMode, snapshot: IslandSurfaceSnapshot) {
        self.mode = mode
        let animate = notchPanel?.isVisible == true
            && mode == .notchIsland
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(animate ? .easeInOut(duration: 0.24) : nil) {
            if state.snapshot != snapshot { state.snapshot = snapshot }
            state.showsNotch = mode == .notchIsland
            state.showsBuddy = mode == .floatingBuddy
        }

        switch mode {
        case .menuBarPopover:
            hidePanels()
        case .notchIsland:
            buddyPanel?.orderOut(nil)
            guard let screen = NSScreen.main ?? NSScreen.screens.first else {
                hidePanels()
                return
            }
            let panel = makeNotchPanelIfNeeded()
            positionNotch(panel, on: screen, animated: animate)
            if !panel.isVisible { panel.orderFrontRegardless() }
        case .floatingBuddy:
            notchPanel?.orderOut(nil)
            guard let screen = NSScreen.main ?? NSScreen.screens.first else {
                hidePanels()
                return
            }
            let panel = makeBuddyPanelIfNeeded(on: screen)
            keepBuddyOnScreen(panel, fallback: screen)
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
    }

    /// Hide both surfaces until the next explicit mode update.
    func hide() {
        mode = .menuBarPopover
        hidePanels()
    }

    private func hidePanels() {
        state.showsNotch = false
        state.showsBuddy = false
        notchPanel?.orderOut(nil)
        buddyPanel?.orderOut(nil)
    }

    private func makeNotchPanelIfNeeded() -> IslandPanel {
        if let notchPanel { return notchPanel }
        let panel = IslandPanel(size: NSSize(width: 220, height: 32))
        let host = IslandHostingView(rootView: NotchIslandView(state: state) { [weak self] in
            self?.onOpenDashboard()
        })
        host.sizingOptions = []
        panel.contentView = host
        panel.setAccessibilityLabel("Suyoi status island")
        notchPanel = panel
        return panel
    }

    private func makeBuddyPanelIfNeeded(on screen: NSScreen) -> IslandPanel {
        if let buddyPanel { return buddyPanel }
        let panel = IslandPanel(size: NSSize(width: 190, height: 56))
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        let host = IslandHostingView(rootView: FloatingBuddyView(
            state: state,
            onFocus: { [weak self] in self?.onFocusPrimaryAgent() },
            onOpen: { [weak self] in self?.onOpenDashboard() }
        ))
        host.sizingOptions = []
        panel.contentView = host
        panel.setAccessibilityLabel("Suyoi floating companion")
        panel.setFrameOrigin(NSPoint(
            x: screen.visibleFrame.maxX - 190 - 16,
            y: screen.visibleFrame.maxY - 56 - 16
        ))
        buddyPanel = panel
        return panel
    }

    private func positionNotch(_ panel: NSPanel, on screen: NSScreen, animated: Bool) {
        let size = state.snapshot.needsAttention
            ? NSSize(width: 390, height: 92) : NSSize(width: 220, height: 32)
        // Keep the content below the physical camera cutout on built-in displays.
        let top = screen.frame.maxY - screen.safeAreaInsets.top
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2, y: top - size.height,
            width: size.width, height: size.height
        )
        guard panel.frame != frame else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func keepBuddyOnScreen(_ panel: NSPanel, fallback: NSScreen) {
        let screen = NSScreen.screens.max {
            intersectionArea(panel.frame, $0.visibleFrame)
                < intersectionArea(panel.frame, $1.visibleFrame)
        }.flatMap { intersectionArea(panel.frame, $0.visibleFrame) > 0 ? $0 : nil }
            ?? fallback
        let bounds = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        panel.setFrameOrigin(NSPoint(
            x: min(max(panel.frame.minX, bounds.minX), max(bounds.minX, bounds.maxX - panel.frame.width)),
            y: min(max(panel.frame.minY, bounds.minY), max(bounds.minY, bounds.maxY - panel.frame.height))
        ))
    }

    private func intersectionArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    @objc private func screenParametersChanged(_ notification: Notification) {
        setMode(mode, snapshot: state.snapshot)
    }
}

@MainActor
private final class IslandSurfaceState: ObservableObject {
    @Published var snapshot = IslandSurfaceSnapshot(
        activeAgentCount: 0, waitingAgentCount: 0, pendingApprovalCount: 0,
        serverCount: 0, primaryAgentName: nil, primaryAgentTask: nil,
        isWaitingForInput: false
    )
    @Published var showsNotch = false
    @Published var showsBuddy = false
}

@MainActor
private final class IslandPanel: NSPanel {
    init(size: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private struct NotchIslandView: View {
    @ObservedObject var state: IslandSurfaceState
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    IslandActivityGlyph(
                        attention: state.snapshot.needsAttention,
                        animating: state.showsNotch && (state.snapshot.activeAgentCount > 0 || state.snapshot.needsAttention)
                    )
                    Text("\(max(0, state.snapshot.activeAgentCount)) active")
                    Text("· \(max(0, state.snapshot.waitingAgentCount)) waiting")
                        .foregroundStyle(.white.opacity(0.65))
                    Spacer(minLength: 4)
                    Image(systemName: "server.rack")
                    Text("\(max(0, state.snapshot.serverCount))")
                }
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .frame(height: 16)

                if state.snapshot.needsAttention {
                    HStack(spacing: 10) {
                        Image(systemName: "hand.raised.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(state.snapshot.agentName)
                                .font(.system(size: 12, weight: .semibold))
                            Text(state.snapshot.attentionSummary)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .transition(.opacity)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(.black, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .preferredColorScheme(.dark)
        .help("Open Suyoi dashboard")
        .accessibilityLabel("Open Suyoi dashboard")
        .accessibilityValue("\(max(0, state.snapshot.activeAgentCount)) active agents, \(max(0, state.snapshot.waitingAgentCount)) waiting, \(max(0, state.snapshot.pendingApprovalCount)) pending approvals, \(max(0, state.snapshot.serverCount)) servers")
    }
}

@MainActor
private struct FloatingBuddyView: View {
    @ObservedObject var state: IslandSurfaceState
    let onFocus: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            IslandActivityGlyph(
                attention: state.snapshot.needsAttention,
                animating: state.showsBuddy && (state.snapshot.activeAgentCount > 0 || state.snapshot.needsAttention),
                mascot: true
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(state.snapshot.agentName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                Text(state.snapshot.taskSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(state.snapshot.needsAttention ? Color.orange : Color.white.opacity(0.65))
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 3) {
                Button(action: onFocus) {
                    Image(systemName: "scope").frame(width: 20, height: 28)
                }
                .disabled(!state.snapshot.canFocusAgent)
                .help("Focus primary agent")
                .accessibilityLabel("Focus primary agent")
                Button(action: onOpen) {
                    Image(systemName: "menubar.rectangle").frame(width: 20, height: 28)
                }
                .help("Open Suyoi popover")
                .accessibilityLabel("Open Suyoi popover")
            }
            .font(.system(size: 12, weight: .medium))
            .buttonStyle(.borderless)
            .tint(.white)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .preferredColorScheme(.dark)
    }
}

@MainActor
private struct IslandActivityGlyph: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let attention: Bool
    let animating: Bool
    var mascot = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: !animating || reduceMotion)) { context in
            let phase = animating && !reduceMotion
                ? sin(context.date.timeIntervalSinceReferenceDate * 3) : 0
            Group {
                if mascot {
                    Image(systemName: attention ? "face.dashed" : "face.smiling")
                        .font(.system(size: 25, weight: .medium))
                        .offset(y: phase * 1.5)
                        .frame(width: 28, height: 30)
                } else {
                    Circle()
                        .frame(width: 6, height: 6)
                        .scaleEffect(1 + phase * 0.15)
                        .opacity(0.8 + phase * 0.2)
                        .frame(width: 8, height: 12)
                }
            }
            .foregroundStyle(attention ? Color.orange : (animating ? Color.green : Color.gray))
        }
        .accessibilityHidden(true)
    }
}
