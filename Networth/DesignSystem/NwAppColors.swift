import SwiftUI
import UIKit

/// "Deep Slate" palette. Navy primary, teal accent, muted red for liabilities.
public enum NwAppColors {
    // Brand
    public static let primary = adaptiveColor(
        light: 0x1E3A8A,
        dark: 0x86A8FF
    )
    public static let primaryDim = adaptiveColor(
        light: 0x142661,
        dark: 0x5F7FD6
    )
    public static let accent = adaptiveColor(
        light: 0x108D9E,
        dark: 0x4CC9D8
    )

    // Semantic
    public static let positive   = Color(red: 0.063, green: 0.620, blue: 0.482) // muted teal-green
    public static let caution    = Color(red: 0.918, green: 0.659, blue: 0.298) // amber
    public static let liability  = Color(red: 0.808, green: 0.318, blue: 0.318) // muted red
    public static let info = adaptiveColor(
        light: 0x4C8AEA,
        dark: 0x78A8FF
    )

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
