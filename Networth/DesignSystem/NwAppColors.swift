import SwiftUI

/// "Deep Slate" palette. Navy primary, teal accent, muted red for liabilities.
public enum NwAppColors {
    // Brand
    public static let primary    = Color(red: 0.118, green: 0.227, blue: 0.541) // #1E3A8A
    public static let primaryDim = Color(red: 0.078, green: 0.149, blue: 0.380)
    public static let accent     = Color(red: 0.063, green: 0.553, blue: 0.620) // teal

    // Semantic
    public static let positive   = Color(red: 0.063, green: 0.620, blue: 0.482) // muted teal-green
    public static let caution    = Color(red: 0.918, green: 0.659, blue: 0.298) // amber
    public static let liability  = Color(red: 0.808, green: 0.318, blue: 0.318) // muted red
    public static let info       = Color(red: 0.298, green: 0.541, blue: 0.918)

    // Surfaces
    public static let background       = Color(.systemGroupedBackground)
    public static let cardSurface      = Color(.secondarySystemGroupedBackground)
    public static let cardSurfaceAlt   = Color(.tertiarySystemGroupedBackground)
    public static let strokeSubtle     = Color(white: 0.5).opacity(0.18)

    // Text
    public static let textPrimary   = Color.primary
    public static let textSecondary = Color.secondary
    public static let textOnPrimary = Color.white

    /// Diff coloring helper.
    public static func deltaColor(positive value: Bool, neutral: Bool = false) -> Color {
        if neutral { return textSecondary }
        return value ? positive : liability
    }
}
