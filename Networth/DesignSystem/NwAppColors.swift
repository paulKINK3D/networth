import SwiftUI
import UIKit

/// Sanzo Wada-inspired palette. Deep blue primary and positive, parchment
/// highlight, amber caution, and rust for liabilities.
public enum NwAppColors {
    // Brand
    public static let primary = adaptiveColor(
        light: 0x003E83,
        dark: 0x8DBAFF
    )
    public static let primaryDim = adaptiveColor(
        light: 0x002B5C,
        dark: 0x6695D1
    )
    public static let accent = primary

    // Semantic
    public static let positive = primary
    public static let gold = adaptiveColor(
        light: 0xEBD999,
        dark: 0xD6C27F
    )
    public static let caution = adaptiveColor(
        light: 0x9A5700,
        dark: 0xE2AE55
    )
    public static let liability = adaptiveColor(
        light: 0xA93400,
        dark: 0xFF9271
    )
    public static let info = adaptiveColor(
        light: 0x4C8AEA,
        dark: 0x78A8FF
    )

    // Budget pace
    public static let budgetOnTrack = positive
    public static let budgetWatch = caution
    public static let budgetAtRisk = liability
    public static let featuredSurface = adaptiveColor(
        light: 0xEBD999,
        dark: 0x453D21
    )
    public static let featuredText = primary
    public static let featuredTrack = primary.opacity(0.20)

    // Surfaces
    public static let background       = Color(.systemGroupedBackground)
    public static let cardSurface      = Color(.secondarySystemGroupedBackground)
    public static let cardSurfaceAlt   = Color(.tertiarySystemGroupedBackground)
    public static let strokeSubtle     = Color(white: 0.5).opacity(0.18)

    // Text
    public static let textPrimary   = Color.primary
    public static let textSecondary = Color.secondary
    public static let textOnPrimary = adaptiveColor(
        light: 0xFFFFFF,
        dark: 0x0B1638
    )

    /// Diff coloring helper.
    public static func deltaColor(positive value: Bool, neutral: Bool = false) -> Color {
        if neutral { return textSecondary }
        return value ? positive : liability
    }

    // Charts

    /// Fixed categorical order for category-group charts, derived from the
    /// Deep Slate family. Hues are assigned to groups by display order and
    /// follow the entity — never re-cycled and never repainted when other
    /// groups filter away; a 9th group folds into `chartOther`. Light and
    /// dark steps validated separately (adjacent-pair CVD ΔE ≈ 28+,
    /// contrast ≥ 3:1 on the dark surface; light-mode contrast relief comes
    /// from the labeled group rows below every chart).
    public static let chartCategorical: [Color] = [
        adaptiveColor(light: 0x4B6FD0, dark: 0x4B6FD0),
        adaptiveColor(light: 0x0E9BB0, dark: 0x0E9BB0),
        adaptiveColor(light: 0xD18A2B, dark: 0xC07C1A),
        adaptiveColor(light: 0xCE5151, dark: 0xCE5151),
        adaptiveColor(light: 0x7FA6EE, dark: 0x5E8BE4),
        adaptiveColor(light: 0x1FA97F, dark: 0x1FA97F),
        adaptiveColor(light: 0x9A6DF2, dark: 0x9A6DF2),
        adaptiveColor(light: 0xC55E93, dark: 0xC55E93)
    ]

    /// The fold bucket for groups beyond the fixed categorical order and for
    /// uncategorized activity.
    public static let chartOther = Color(white: 0.55)

    private static func adaptiveColor(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}
