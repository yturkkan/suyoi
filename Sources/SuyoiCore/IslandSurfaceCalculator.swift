import CoreGraphics
import Foundation

public enum IslandExpansionState: String, Codable, Equatable, Sendable {
    case compactPill
    case attentionBanner
    case expandedDashboard
}

public struct ScreenGeometrySnapshot: Equatable, Sendable {
    public let frame: CGRect
    public let visibleFrame: CGRect
    public let safeAreaTopInset: CGFloat
    public let auxiliaryTopLeftWidth: CGFloat
    public let auxiliaryTopRightWidth: CGFloat

    public init(
        frame: CGRect,
        visibleFrame: CGRect,
        safeAreaTopInset: CGFloat,
        auxiliaryTopLeftWidth: CGFloat = 0,
        auxiliaryTopRightWidth: CGFloat = 0
    ) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaTopInset = safeAreaTopInset
        self.auxiliaryTopLeftWidth = auxiliaryTopLeftWidth
        self.auxiliaryTopRightWidth = auxiliaryTopRightWidth
    }

    public var hasPhysicalNotch: Bool {
        safeAreaTopInset >= 28 || (auxiliaryTopLeftWidth > 0 && auxiliaryTopRightWidth > 0)
    }
}

public enum IslandSurfaceCalculator {
    public static func targetExpansionState(
        isUserExpanded: Bool,
        isHovered: Bool,
        pendingApprovalCount: Int,
        waitingAgentCount: Int
    ) -> IslandExpansionState {
        if isUserExpanded || isHovered { return .expandedDashboard }
        if pendingApprovalCount > 0 || waitingAgentCount > 0 { return .attentionBanner }
        return .compactPill
    }

    public static func notchPanelFrame(
        for screen: ScreenGeometrySnapshot,
        state: IslandExpansionState
    ) -> CGRect {
        let size: CGSize
        switch state {
        case .compactPill:
            size = CGSize(width: 220, height: max(32, screen.safeAreaTopInset))
        case .attentionBanner:
            size = CGSize(width: 390, height: 96)
        case .expandedDashboard:
            size = CGSize(width: 440, height: 580)
        }
        let top = screen.hasPhysicalNotch ? screen.frame.maxY : screen.visibleFrame.maxY
        return CGRect(
            x: screen.frame.midX - size.width / 2,
            y: top - size.height,
            width: size.width,
            height: size.height
        )
    }

    public static func clampedFloatingOrigin(
        proposed: CGPoint,
        panelSize: CGSize,
        visibleFrame: CGRect,
        margin: CGFloat = 12,
        snapThreshold: CGFloat = 24
    ) -> CGPoint {
        let bounds = visibleFrame.insetBy(dx: margin, dy: margin)
        // If the panel cannot fit, keep its origin at the inset lower-left edge.
        let maxX = max(bounds.minX, bounds.maxX - panelSize.width)
        let maxY = max(bounds.minY, bounds.maxY - panelSize.height)
        var x = min(max(proposed.x, bounds.minX), maxX)
        let y = min(max(proposed.y, bounds.minY), maxY)
        let leftDistance = x - bounds.minX
        let rightDistance = maxX - x
        if leftDistance <= snapThreshold && leftDistance <= rightDistance {
            x = bounds.minX
        } else if rightDistance <= snapThreshold {
            x = maxX
        }
        return CGPoint(x: x, y: y)
    }
}
