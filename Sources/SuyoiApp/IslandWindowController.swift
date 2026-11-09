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
    var firstApprovalID: String? = nil
    var firstApprovalToolName: String? = nil
    var firstApprovalSummary: String? = nil
    var firstApprovalIsQuestion: Bool = false
    var theme: SuyoiExperienceTheme = .nativeGlass

    fileprivate var needsAttention: Bool {
        firstApprovalID != nil || waitingAgentCount > 0 || pendingApprovalCount > 0 || isWaitingForInput
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

    fileprivate var approvalToolName: String {
        firstApprovalToolName.flatMap(Self.displayText) ?? "Approval required"
    }

    fileprivate var approvalSummary: String {
        firstApprovalSummary.flatMap(Self.displayText) ?? "Review the pending action"
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
    var onApprovePending: ((String) -> Void)?
    var onDenyPending: ((String) -> Void)?

    private let state = IslandSurfaceState()
    private var mode: SuyoiSurfaceMode = .menuBarPopover
    private var notchPanel: IslandPanel?
    private var buddyPanel: IslandPanel?
    private var isAdjustingBuddyPosition = false
    private static let buddyOriginXKey = "suyoi.floatingBuddyOriginX"
    private static let buddyOriginYKey = "suyoi.floatingBuddyOriginY"

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
            if mode != .notchIsland { state.isNotchHovered = false }
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
        state.isNotchHovered = false
        notchPanel?.orderOut(nil)
        buddyPanel?.orderOut(nil)
    }

    private func makeNotchPanelIfNeeded() -> IslandPanel {
        if let notchPanel { return notchPanel }
        let panel = IslandPanel(size: NSSize(width: 220, height: 32))
        let host = IslandHostingView(rootView: NotchIslandView(
            state: state,
            onOpen: { [weak self] in self?.onOpenDashboard() },
            onHover: { [weak self] in self?.setNotchHovered($0) },
            onApprove: { [weak self] id in
                guard let self, self.state.snapshot.firstApprovalID == id else { return }
                self.onApprovePending?(id)
            },
            onDeny: { [weak self] id in
                guard let self, self.state.snapshot.firstApprovalID == id else { return }
                self.onDenyPending?(id)
            }
        ))
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
        var origin = NSPoint(
            x: screen.visibleFrame.maxX - 190 - 16,
            y: screen.visibleFrame.maxY - 56 - 16
        )
        let defaults = UserDefaults.standard
        if let x = defaults.object(forKey: Self.buddyOriginXKey) as? NSNumber,
           let y = defaults.object(forKey: Self.buddyOriginYKey) as? NSNumber,
           x.doubleValue.isFinite, y.doubleValue.isFinite {
            origin = NSPoint(x: x.doubleValue, y: y.doubleValue)
        }
        panel.setFrameOrigin(origin)
        keepBuddyOnScreen(panel, fallback: screen)
        buddyPanel = panel
        NotificationCenter.default.addObserver(
            self, selector: #selector(buddyPanelDidMove),
            name: NSWindow.didMoveNotification, object: panel
        )
        return panel
    }

    private func setNotchHovered(_ hovered: Bool) {
        guard mode == .notchIsland, state.isNotchHovered != hovered else { return }
        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(animate ? .easeInOut(duration: 0.24) : nil) {
            state.isNotchHovered = hovered
        }
        guard let panel = notchPanel,
              let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        positionNotch(panel, on: screen, animated: animate)
    }

    private func positionNotch(_ panel: NSPanel, on screen: NSScreen, animated: Bool) {
        let screenSnapshot = ScreenGeometrySnapshot(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTopInset: screen.safeAreaInsets.top,
            auxiliaryTopLeftWidth: screen.auxiliaryTopLeftArea?.width ?? 0,
            auxiliaryTopRightWidth: screen.auxiliaryTopRightArea?.width ?? 0
        )
        let baseFrame = IslandSurfaceCalculator.notchPanelFrame(
            for: screenSnapshot,
            state: state.isNotchExpanded ? .attentionBanner : .compactPill
        )
        let size: NSSize
        if state.snapshot.firstApprovalID != nil {
            size = NSSize(width: 420, height: 112)
        } else if state.isNotchExpanded {
            size = NSSize(width: baseFrame.width, height: max(baseFrame.height, 96))
        } else {
            size = baseFrame.size
        }
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
        guard !isAdjustingBuddyPosition else { return }
        isAdjustingBuddyPosition = true
        defer { isAdjustingBuddyPosition = false }
        let screen = NSScreen.screens.max {
            intersectionArea(panel.frame, $0.visibleFrame)
                < intersectionArea(panel.frame, $1.visibleFrame)
        }.flatMap { intersectionArea(panel.frame, $0.visibleFrame) > 0 ? $0 : nil }
            ?? fallback
        let origin = IslandSurfaceCalculator.clampedFloatingOrigin(
            proposed: panel.frame.origin,
            panelSize: panel.frame.size,
            visibleFrame: screen.visibleFrame
        )
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        UserDefaults.standard.set(Double(origin.x), forKey: Self.buddyOriginXKey)
        UserDefaults.standard.set(Double(origin.y), forKey: Self.buddyOriginYKey)
    }

    private func intersectionArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    @objc private func screenParametersChanged(_ notification: Notification) {
        setMode(mode, snapshot: state.snapshot)
    }

    @objc private func buddyPanelDidMove(_ notification: Notification) {
        guard let panel = buddyPanel, notification.object as? NSWindow === panel,
              let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        keepBuddyOnScreen(panel, fallback: screen)
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
    @Published var isNotchHovered = false

    var isNotchExpanded: Bool { isNotchHovered || snapshot.needsAttention }

    var accentColor: Color {
        let tokens = ExperienceThemeCatalog.tokens(for: snapshot.theme)
        return Color(red: tokens.accentRed, green: tokens.accentGreen, blue: tokens.accentBlue)
    }
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
    let onHover: (Bool) -> Void
    let onApprove: (String) -> Void
    let onDeny: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        IslandActivityGlyph(
                            attention: state.snapshot.needsAttention,
                            animating: state.showsNotch && (state.snapshot.activeAgentCount > 0 || state.snapshot.needsAttention),
                            accent: state.accentColor
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

                    if state.isNotchExpanded {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: state.snapshot.needsAttention ? "hand.raised.fill" : "sparkles")
                                .foregroundStyle(state.accentColor)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(state.snapshot.firstApprovalID != nil
                                     ? state.snapshot.approvalToolName : state.snapshot.agentName)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .lineLimit(1)
                                Text(state.snapshot.firstApprovalID != nil
                                     ? state.snapshot.approvalSummary
                                     : (state.snapshot.needsAttention
                                        ? state.snapshot.attentionSummary : state.snapshot.taskSummary))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.75))
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.6))
                                .padding(.top, 4)
                        }
                        .frame(minHeight: 34)
                        .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open Suyoi dashboard")
            .accessibilityLabel("Open Suyoi dashboard")
            .accessibilityValue("\(max(0, state.snapshot.activeAgentCount)) active agents, \(max(0, state.snapshot.waitingAgentCount)) waiting, \(max(0, state.snapshot.pendingApprovalCount)) pending approvals, \(max(0, state.snapshot.serverCount)) servers")

            if let approvalID = state.snapshot.firstApprovalID {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button { onDeny(approvalID) } label: {
                        Label("Deny", systemImage: "xmark")
                            .padding(.horizontal, 12)
                            .frame(height: 24)
                            .background(Color.red.opacity(0.22), in: Capsule())
                    }
                    .foregroundStyle(Color.red)
                    .accessibilityLabel("Deny pending approval")
                    if state.snapshot.firstApprovalIsQuestion {
                        Button(action: onOpen) {
                            Label("Choose Option…", systemImage: "list.bullet")
                                .padding(.horizontal, 12)
                                .frame(height: 24)
                                .background(state.accentColor, in: Capsule())
                        }
                        .foregroundStyle(Color.black)
                        .accessibilityLabel("Choose question option in dashboard")
                    } else {
                        Button { onApprove(approvalID) } label: {
                            Label("Approve", systemImage: "checkmark")
                                .padding(.horizontal, 12)
                                .frame(height: 24)
                                .background(Color.green, in: Capsule())
                        }
                        .foregroundStyle(Color.black)
                        .accessibilityLabel("Approve pending approval")
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onHover(perform: onHover)
        .foregroundStyle(.white)
        .background(.black, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(state.accentColor.opacity(state.isNotchHovered ? 0.6 : 0.2), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .preferredColorScheme(.dark)
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
                accent: state.accentColor,
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
            .tint(state.accentColor)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(state.accentColor.opacity(0.3), lineWidth: 1)
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
    let accent: Color
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
            .foregroundStyle(attention ? Color.orange : (animating ? accent : Color.gray))
        }
        .accessibilityHidden(true)
    }
}
