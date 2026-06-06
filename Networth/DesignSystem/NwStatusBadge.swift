import SwiftUI

public enum NwStatusBadgeStyle {
    case positive
    case caution
    case liability
    case neutral
    case info

    fileprivate var foreground: Color {
        switch self {
        case .positive:  return NwAppColors.positive
        case .caution:   return NwAppColors.caution
        case .liability: return NwAppColors.liability
        case .info:      return NwAppColors.info
        case .neutral:   return NwAppColors.textSecondary
        }
    }
}

public struct NwStatusBadge: View {
    public let text: String
    public let style: NwStatusBadgeStyle
    public let icon: NwIcon?

    public init(_ text: String, style: NwStatusBadgeStyle = .neutral, icon: NwIcon? = nil) {
        self.text = text
        self.style = style
        self.icon = icon
    }

    public var body: some View {
        HStack(spacing: NwSpacing.xs) {
            if let icon { icon.image.font(.system(size: 11, weight: .semibold)) }
            Text(text)
                .font(NwTypography.footnoteEm)
        }
        .foregroundStyle(style.foreground)
        .padding(.horizontal, NwSpacing.sm)
        .padding(.vertical, NwSpacing.xs)
        .background(
            Capsule().fill(style.foreground.opacity(0.12))
        )
    }
}
