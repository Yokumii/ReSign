import AppKit
import SwiftUI

extension AppAppearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

struct ThemePalette {
    let colorScheme: ColorScheme

    var isDark: Bool { colorScheme == .dark }

    var cardBorder: Color { Color.primary.opacity(isDark ? 0.13 : 0.07) }
    var cardHighlight: Color { isDark ? Color.white.opacity(0.03) : .clear }
    var iconBorder: Color { Color.primary.opacity(isDark ? 0.14 : 0.08) }
    var iconPlaceholder: Color { Color.primary.opacity(isDark ? 0.09 : 0.05) }
    var pillBackground: Color { Color.primary.opacity(isDark ? 0.12 : 0.07) }
    var offlineIndicator: Color { Color.secondary.opacity(isDark ? 0.45 : 0.30) }
    var subtlePrimaryText: Color { Color.primary.opacity(isDark ? 0.88 : 0.80) }
    var glassTintOpacity: Double { isDark ? 0.24 : 0.16 }

    func bannerBackground(_ tint: Color) -> Color { tint.opacity(isDark ? 0.16 : 0.10) }
    func bannerBorder(_ tint: Color) -> Color { tint.opacity(isDark ? 0.32 : 0.22) }
    func warningBackground() -> Color { Color.orange.opacity(isDark ? 0.14 : 0.08) }
    func warningBorder() -> Color { Color.orange.opacity(isDark ? 0.28 : 0.18) }
    func badgeBackground(_ tint: Color) -> Color { tint.opacity(isDark ? 0.18 : 0.12) }
}

extension View {
    func themedCardSurface(cornerRadius: CGFloat, palette: ThemePalette) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(palette.cardHighlight, in: shape)
            .background(.background.secondary, in: shape)
            .overlay(shape.strokeBorder(palette.cardBorder, lineWidth: 0.5))
    }

    func themedWarningSurface(cornerRadius: CGFloat, palette: ThemePalette) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(palette.warningBackground(), in: shape)
            .overlay(shape.strokeBorder(palette.warningBorder(), lineWidth: 0.5))
    }
}
