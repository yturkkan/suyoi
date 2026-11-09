import AppKit
import SwiftUI
import SuyoiCore

enum ThemeStyling {
    static func accentColor(for theme: SuyoiExperienceTheme) -> Color {
        if theme == .macOSSystem {
            return Color.accentColor
        }
        let tokens = ExperienceThemeCatalog.tokens(for: theme)
        return Color(
            red: tokens.accentRed,
            green: tokens.accentGreen,
            blue: tokens.accentBlue
        )
    }

    static func cardCornerRadius(for theme: SuyoiExperienceTheme) -> CGFloat {
        let rawRadius = CGFloat(ExperienceThemeCatalog.tokens(for: theme).cornerRadius)
        let clamped = min(max(rawRadius, 2), 12)
        switch theme {
        case .pixelOlive:
            return min(clamped, 2)
        case .pixelArcade:
            return min(clamped, 4)
        case .nativeGlass, .macOSSystem:
            return 9
        }
    }
}

struct PixelMascotBadgeView: View {
    let state: MascotAnimationState
    var theme: SuyoiExperienceTheme = .nativeGlass

    private var isAnimated: Bool {
        state == .working || state == .waitingForApproval
    }

    private var stateLabel: String {
        switch state {
        case .working:
            return "Working"
        case .waitingForApproval:
            return "Needs Input"
        case .idle:
            return "Idle"
        case .completed:
            return "Done"
        case .sleeping:
            return "Sleeping"
        }
    }

    private var spriteTint: Color {
        if theme == .pixelOlive {
            switch state {
            case .working, .completed:
                return Color(red: 0.61, green: 0.73, blue: 0.06)
            case .waitingForApproval:
                return Color(red: 0.78, green: 0.82, blue: 0.12)
            case .idle:
                return Color(red: 0.48, green: 0.60, blue: 0.10)
            case .sleeping:
                return Color(red: 0.40, green: 0.50, blue: 0.14)
            }
        }
        switch state {
        case .working:
            return ThemeStyling.accentColor(for: theme)
        case .waitingForApproval:
            return Color(nsColor: .systemOrange)
        case .completed:
            return Color(nsColor: .systemGreen)
        case .idle:
            return ThemeStyling.accentColor(for: theme).opacity(0.85)
        case .sleeping:
            return .secondary
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: isAnimated ? 0.45 : 60.0)) { context in
            let phaseIndex = isAnimated ? Int(floor(context.date.timeIntervalSinceReferenceDate / 0.45)) : 0
            let alternateFrame = (phaseIndex % 2) != 0
            let verticalOffset: CGFloat = isAnimated ? (alternateFrame ? -1.0 : 0.5) : 0.0

            HStack(spacing: 5) {
                Canvas { graphicsContext, size in
                    let grid = Self.pixelGrid(for: state, alternateFrame: alternateFrame)
                    let cellWidth = size.width / 8.0
                    let cellHeight = size.height / 8.0
                    for row in 0..<8 {
                        for col in 0..<8 where grid[row][col] != 0 {
                            let rect = CGRect(
                                x: CGFloat(col) * cellWidth,
                                y: CGFloat(row) * cellHeight,
                                width: ceil(cellWidth),
                                height: ceil(cellHeight)
                            )
                            let pixelColor = grid[row][col] == 2 ? Color.primary.opacity(0.9) : spriteTint
                            graphicsContext.fill(Path(rect), with: .color(pixelColor))
                        }
                    }
                }
                .frame(width: 14, height: 14)
                .offset(y: verticalOffset)

                Text(stateLabel)
                    .font(
                        .system(
                            size: 9.5,
                            weight: .semibold,
                            design: (theme == .pixelArcade || theme == .pixelOlive) ? .monospaced : .rounded
                        )
                    )
                    .foregroundStyle(spriteTint)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6.5)
            .padding(.vertical, 2.5)
            .background(
                spriteTint.opacity(theme == .pixelOlive ? 0.16 : 0.12),
                in: RoundedRectangle(
                    cornerRadius: (theme == .pixelArcade || theme == .pixelOlive) ? 3 : 99,
                    style: (theme == .pixelArcade || theme == .pixelOlive) ? .circular : .continuous
                )
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: (theme == .pixelArcade || theme == .pixelOlive) ? 3 : 99,
                    style: (theme == .pixelArcade || theme == .pixelOlive) ? .circular : .continuous
                )
                .strokeBorder(spriteTint.opacity(0.35), lineWidth: 0.75)
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Agent mascot \(stateLabel)")
    }

    private static func pixelGrid(for state: MascotAnimationState, alternateFrame: Bool) -> [[UInt8]] {
        switch state {
        case .working:
            if alternateFrame {
                return [
                    [0, 0, 1, 0, 0, 1, 0, 0],
                    [0, 1, 1, 1, 1, 1, 1, 0],
                    [1, 1, 2, 1, 1, 2, 1, 1],
                    [1, 1, 1, 1, 1, 1, 1, 1],
                    [0, 1, 1, 2, 2, 1, 1, 0],
                    [1, 0, 1, 1, 1, 1, 0, 1],
                    [0, 0, 1, 0, 0, 1, 0, 0],
                    [0, 1, 0, 0, 0, 0, 1, 0]
                ]
            }
            return [
                [0, 1, 0, 0, 0, 0, 1, 0],
                [0, 1, 1, 1, 1, 1, 1, 0],
                [1, 1, 2, 1, 1, 2, 1, 1],
                [1, 1, 1, 1, 1, 1, 1, 1],
                [1, 0, 1, 2, 2, 1, 0, 1],
                [0, 0, 1, 1, 1, 1, 0, 0],
                [0, 1, 0, 1, 1, 0, 1, 0],
                [0, 0, 1, 0, 0, 1, 0, 0]
            ]

        case .waitingForApproval:
            if alternateFrame {
                return [
                    [0, 0, 0, 2, 2, 0, 0, 0],
                    [0, 1, 1, 2, 2, 1, 1, 0],
                    [1, 1, 0, 1, 1, 0, 1, 1],
                    [1, 1, 1, 1, 1, 1, 1, 1],
                    [0, 1, 1, 2, 2, 1, 1, 1],
                    [0, 0, 1, 1, 1, 1, 0, 0],
                    [0, 0, 1, 0, 0, 1, 0, 0],
                    [0, 1, 1, 0, 0, 1, 1, 0]
                ]
            }
            return [
                [0, 0, 0, 2, 2, 0, 0, 1],
                [0, 1, 1, 1, 1, 1, 1, 1],
                [1, 1, 2, 1, 1, 2, 1, 0],
                [1, 1, 1, 1, 1, 1, 1, 0],
                [0, 1, 1, 2, 2, 1, 1, 0],
                [0, 0, 1, 1, 1, 1, 0, 0],
                [0, 0, 1, 0, 0, 1, 0, 0],
                [0, 1, 1, 0, 0, 1, 1, 0]
            ]

        case .completed:
            return [
                [0, 1, 0, 0, 0, 0, 1, 0],
                [1, 0, 1, 1, 1, 1, 0, 1],
                [1, 1, 2, 1, 1, 2, 1, 1],
                [0, 1, 1, 1, 1, 1, 1, 0],
                [0, 1, 2, 1, 1, 2, 1, 0],
                [0, 0, 1, 2, 2, 1, 0, 0],
                [0, 0, 1, 1, 1, 1, 0, 0],
                [0, 1, 0, 0, 0, 0, 1, 0]
            ]

        case .idle:
            return [
                [0, 0, 1, 1, 1, 1, 0, 0],
                [0, 1, 1, 1, 1, 1, 1, 0],
                [1, 1, 2, 1, 1, 2, 1, 1],
                [1, 1, 1, 1, 1, 1, 1, 1],
                [0, 1, 1, 1, 1, 1, 1, 0],
                [0, 0, 1, 1, 1, 1, 0, 0],
                [0, 0, 1, 0, 0, 1, 0, 0],
                [0, 0, 1, 0, 0, 1, 0, 0]
            ]

        case .sleeping:
            return [
                [0, 0, 0, 0, 0, 2, 2, 0],
                [0, 0, 1, 1, 1, 1, 0, 0],
                [0, 1, 1, 1, 1, 1, 1, 0],
                [1, 1, 2, 2, 1, 2, 2, 1],
                [1, 1, 1, 1, 1, 1, 1, 1],
                [0, 1, 1, 1, 1, 1, 1, 0],
                [0, 0, 1, 1, 1, 1, 0, 0],
                [0, 0, 0, 0, 0, 0, 0, 0]
            ]
        }
    }
}

struct ThemedSurfaceCardModifier: ViewModifier {
    let theme: SuyoiExperienceTheme
    var isHovered: Bool = false

    func body(content: Content) -> some View {
        switch theme {
        case .pixelOlive:
            let oliveTint = Color(red: 0.55, green: 0.67, blue: 0.06)
            content
                .background(
                    oliveTint.opacity(isHovered ? 0.15 : 0.10),
                    in: RoundedRectangle(cornerRadius: 3, style: .circular)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .circular)
                        .strokeBorder(
                            oliveTint.opacity(isHovered ? 0.85 : 0.50),
                            lineWidth: 1
                        )
                )

        case .pixelArcade:
            let arcadeTint = Color(red: 0.62, green: 0.45, blue: 1.0)
            content
                .background(
                    arcadeTint.opacity(isHovered ? 0.14 : 0.09),
                    in: RoundedRectangle(cornerRadius: 4, style: .circular)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .circular)
                        .strokeBorder(
                            arcadeTint.opacity(isHovered ? 0.90 : 0.52),
                            lineWidth: 1
                        )
                )

        case .macOSSystem:
            content
                .background(
                    Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            Color(nsColor: .separatorColor).opacity(isHovered ? 0.95 : 0.60),
                            lineWidth: 0.75
                        )
                )

        case .nativeGlass:
            content
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(
                            Color(nsColor: .separatorColor).opacity(isHovered ? 0.95 : 0.45),
                            lineWidth: 0.5
                        )
                )
        }
    }
}

extension View {
    func themedSurfaceCard(theme: SuyoiExperienceTheme, isHovered: Bool = false) -> some View {
        modifier(ThemedSurfaceCardModifier(theme: theme, isHovered: isHovered))
    }
}
