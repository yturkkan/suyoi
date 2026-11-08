import CoreGraphics
import Foundation
import Testing
import SuyoiCore

@Suite("Island surface calculator")
struct IslandSurfaceCalculatorTests {
    @Test(arguments: [
        (CGFloat(-1), false), (0, false), (27.999, false), (28, true), (38, true)
    ])
    func notchDetectionUsesInclusiveInsetThreshold(inset: CGFloat, expected: Bool) {
        #expect(screen(inset: inset).hasPhysicalNotch == expected)
    }

    @Test(arguments: [
        (CGFloat(0), CGFloat(0), false), (100, 0, false), (0, 100, false),
        (-1, 100, false), (100, -1, false), (0.5, 0.5, true), (650, 650, true)
    ])
    func auxiliaryNotchDetectionRequiresBothPositiveWidths(left: CGFloat, right: CGFloat, expected: Bool) {
        #expect(screen(inset: 0, left: left, right: right).hasPhysicalNotch == expected)
    }

    @Test func snapshotPreservesGeometryAndDefaults() {
        let snapshot = screen(inset: 38)
        #expect(snapshot.frame == CGRect(x: 0, y: 0, width: 1512, height: 982))
        #expect(snapshot.visibleFrame == CGRect(x: 0, y: 40, width: 1512, height: 904))
        #expect(snapshot.safeAreaTopInset == 38)
        #expect(snapshot.auxiliaryTopLeftWidth == 0)
        #expect(snapshot.auxiliaryTopRightWidth == 0)
        #expect(snapshot == screen(inset: 38))
        #expect(snapshot != screen(inset: 32))
    }

    @Test(arguments: [false, true], [false, true])
    func expansionTakesPriorityOverAttention(userExpanded: Bool, hovered: Bool) {
        let expected: IslandExpansionState = userExpanded || hovered ? .expandedDashboard : .attentionBanner
        #expect(IslandSurfaceCalculator.targetExpansionState(
            isUserExpanded: userExpanded, isHovered: hovered,
            pendingApprovalCount: 2, waitingAgentCount: 3
        ) == expected)
    }

    @Test(arguments: [-1, 0, 1], [-1, 0, 1])
    func attentionRequiresPositiveCounts(approvals: Int, waiting: Int) {
        let expected: IslandExpansionState = approvals > 0 || waiting > 0 ? .attentionBanner : .compactPill
        #expect(IslandSurfaceCalculator.targetExpansionState(
            isUserExpanded: false, isHovered: false,
            pendingApprovalCount: approvals, waitingAgentCount: waiting
        ) == expected)
    }

    @Test func expansionStateRespondsToHoverAndAttentionEnding() {
        let states = [
            (false, false, 0, 0), (false, false, 1, 0), (false, true, 1, 0),
            (false, false, 1, 0), (true, false, 0, 0), (false, false, 0, 0)
        ].map { expanded, hovered, approvals, waiting in
            IslandSurfaceCalculator.targetExpansionState(
                isUserExpanded: expanded, isHovered: hovered,
                pendingApprovalCount: approvals, waitingAgentCount: waiting
            )
        }
        #expect(states == [.compactPill, .attentionBanner, .expandedDashboard,
                           .attentionBanner, .expandedDashboard, .compactPill])
    }

    @Test(arguments: [
        IslandExpansionState.compactPill, .attentionBanner, .expandedDashboard
    ])
    func expansionStateCodableRoundTrip(state: IslandExpansionState) throws {
        let encoded = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(IslandExpansionState.self, from: encoded) == state)
        #expect(String(data: encoded, encoding: .utf8) == "\"\(state.rawValue)\"")
    }

    @Test(arguments: [
        (IslandExpansionState.compactPill, CGFloat(220), CGFloat(38)),
        (.attentionBanner, 390, 96), (.expandedDashboard, 440, 580)
    ])
    func notchedPanelUsesFullScreenTop(state: IslandExpansionState, width: CGFloat, height: CGFloat) {
        let frame = IslandSurfaceCalculator.notchPanelFrame(for: screen(inset: 38), state: state)
        #expect(frame == CGRect(x: (1512 - width) / 2, y: 982 - height, width: width, height: height))
        #expect(frame.midX == 756)
        #expect(frame.maxY == 982)
    }

    @Test(arguments: [
        (IslandExpansionState.compactPill, CGFloat(220), CGFloat(32)),
        (.attentionBanner, 390, 96), (.expandedDashboard, 440, 580)
    ])
    func nonNotchedPanelUsesVisibleTop(state: IslandExpansionState, width: CGFloat, height: CGFloat) {
        let frame = IslandSurfaceCalculator.notchPanelFrame(for: screen(inset: 0), state: state)
        #expect(frame == CGRect(x: (1512 - width) / 2, y: 944 - height, width: width, height: height))
        #expect(frame.maxY == 944)
    }

    @Test(arguments: [
        (CGFloat(-1), CGFloat(32)), (0, 32), (20, 32), (28, 32), (32, 32), (45, 45)
    ])
    func compactHeightRespectsMinimumAndSafeInset(inset: CGFloat, expected: CGFloat) {
        let frame = IslandSurfaceCalculator.notchPanelFrame(for: screen(inset: inset), state: .compactPill)
        #expect(frame.height == expected)
    }

    @Test func auxiliaryWidthsAnchorToPhysicalTopWithoutInset() {
        let frame = IslandSurfaceCalculator.notchPanelFrame(
            for: screen(inset: 0, left: 650, right: 650), state: .compactPill
        )
        #expect(frame == CGRect(x: 646, y: 950, width: 220, height: 32))
    }

    @Test(arguments: [false, true])
    func panelUsesGlobalCoordinatesAndFullFrameHorizontalCenter(notched: Bool) {
        let snapshot = ScreenGeometrySnapshot(
            frame: CGRect(x: -1920, y: -200, width: 1920, height: 1080),
            visibleFrame: CGRect(x: -1840, y: -180, width: 1840, height: 1036),
            safeAreaTopInset: notched ? 38 : 0
        )
        let frame = IslandSurfaceCalculator.notchPanelFrame(for: snapshot, state: .attentionBanner)
        #expect(frame.midX == -960)
        #expect(frame.maxY == (notched ? 880 : 856))
        #expect(frame.size == CGSize(width: 390, height: 96))
    }

    @Test func floatingInteriorOriginIsUnchanged() {
        #expect(floating(CGPoint(x: 400, y: 300)) == CGPoint(x: 400, y: 300))
    }

    @Test(arguments: [
        (CGPoint(x: -100, y: -100), CGPoint(x: 12, y: 12)),
        (CGPoint(x: 2000, y: -100), CGPoint(x: 788, y: 12)),
        (CGPoint(x: -100, y: 2000), CGPoint(x: 12, y: 688)),
        (CGPoint(x: 2000, y: 2000), CGPoint(x: 788, y: 688))
    ])
    func floatingClampsAllCorners(proposed: CGPoint, expected: CGPoint) {
        #expect(floating(proposed) == expected)
    }

    @Test(arguments: [
        (CGFloat(12), CGFloat(12)), (35, 12), (36, 12), (36.5, 36.5),
        (763.5, 763.5), (764, 788), (765, 788), (788, 788)
    ])
    func horizontalSnappingIncludesThreshold(x: CGFloat, expectedX: CGFloat) {
        #expect(floating(CGPoint(x: x, y: 300)) == CGPoint(x: expectedX, y: 300))
    }

    @Test(arguments: [CGFloat(20), 680])
    func floatingDoesNotSnapVertically(y: CGFloat) {
        #expect(floating(CGPoint(x: 400, y: y)) == CGPoint(x: 400, y: y))
    }

    @Test func floatingRespectsCustomMarginAndThreshold() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = CGSize(width: 200, height: 100)
        #expect(IslandSurfaceCalculator.clampedFloatingOrigin(
            proposed: CGPoint(x: 60, y: 0), panelSize: size, visibleFrame: frame,
            margin: 40, snapThreshold: 20
        ) == CGPoint(x: 40, y: 40))
        #expect(IslandSurfaceCalculator.clampedFloatingOrigin(
            proposed: CGPoint(x: 740, y: 800), panelSize: size, visibleFrame: frame,
            margin: 40, snapThreshold: 20
        ) == CGPoint(x: 760, y: 660))
        #expect(IslandSurfaceCalculator.clampedFloatingOrigin(
            proposed: CGPoint(x: 61, y: 300), panelSize: size, visibleFrame: frame,
            margin: 40, snapThreshold: 20
        ) == CGPoint(x: 61, y: 300))
    }

    @Test func zeroMarginAndThresholdAllowExactEdgePlacement() {
        #expect(IslandSurfaceCalculator.clampedFloatingOrigin(
            proposed: CGPoint(x: 1, y: 900), panelSize: CGSize(width: 200, height: 100),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            margin: 0, snapThreshold: 0
        ) == CGPoint(x: 1, y: 700))
    }

    @Test func floatingUsesOffsetDisplayCoordinates() {
        #expect(IslandSurfaceCalculator.clampedFloatingOrigin(
            proposed: CGPoint(x: 0, y: 2000), panelSize: CGSize(width: 200, height: 100),
            visibleFrame: CGRect(x: -1920, y: 200, width: 1920, height: 1080)
        ) == CGPoint(x: -212, y: 1168))
    }

    @Test(arguments: [
        (CGFloat(20), CGFloat(12)), (27, 12), (28, 12), (28.5, 44), (35, 44)
    ])
    func overlappingSnapRangesChooseNearestEdge(x: CGFloat, expected: CGFloat) {
        #expect(IslandSurfaceCalculator.clampedFloatingOrigin(
            proposed: CGPoint(x: x, y: 50), panelSize: CGSize(width: 200, height: 100),
            visibleFrame: CGRect(x: 0, y: 0, width: 256, height: 300)
        ) == CGPoint(x: expected, y: 50))
    }

    @Test(arguments: [
        CGSize(width: 976, height: 776), CGSize(width: 1200, height: 900)
    ])
    func exactFitAndOversizedPanelsUseInsetOrigin(size: CGSize) {
        #expect(IslandSurfaceCalculator.clampedFloatingOrigin(
            proposed: CGPoint(x: 500, y: 500), panelSize: size,
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)
        ) == CGPoint(x: 12, y: 12))
    }

    private func screen(inset: CGFloat, left: CGFloat = 0, right: CGFloat = 0) -> ScreenGeometrySnapshot {
        ScreenGeometrySnapshot(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 40, width: 1512, height: 904),
            safeAreaTopInset: inset, auxiliaryTopLeftWidth: left, auxiliaryTopRightWidth: right
        )
    }

    private func floating(_ proposed: CGPoint) -> CGPoint {
        IslandSurfaceCalculator.clampedFloatingOrigin(
            proposed: proposed, panelSize: CGSize(width: 200, height: 100),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )
    }
}
