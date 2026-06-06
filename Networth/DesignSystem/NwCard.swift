import SwiftUI

public enum NwCardStyle {
    case primary
    case secondary
    case glass
    case inset
}

public struct NwCardModifier: ViewModifier {
    public let style: NwCardStyle
    public let padding: CGFloat

    public init(style: NwCardStyle, padding: CGFloat) {
        self.style = style
        self.padding = padding
    }

    public func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(background)
            .overlay(border)
            .clipShape(RoundedRectangle(cornerRadius: NwCornerRadius.card, style: .continuous))
            .nwShadow(shadow)
    }

    @ViewBuilder private var background: some View {
        switch style {
        case .primary:
            RoundedRectangle(cornerRadius: NwCornerRadius.card, style: .continuous)
                .fill(NwAppColors.cardSurface)
        case .secondary:
            RoundedRectangle(cornerRadius: NwCornerRadius.card, style: .continuous)
                .fill(NwAppColors.cardSurfaceAlt)
        case .glass:
            RoundedRectangle(cornerRadius: NwCornerRadius.card, style: .continuous)
                .fill(NwAppColors.primary.opacity(NwOpacity.glassFill))
                .background(.ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: NwCornerRadius.card, style: .continuous))
        case .inset:
            RoundedRectangle(cornerRadius: NwCornerRadius.card, style: .continuous)
                .fill(Color.clear)
        }
    }

    @ViewBuilder private var border: some View {
        switch style {
        case .inset, .glass:
            RoundedRectangle(cornerRadius: NwCornerRadius.card, style: .continuous)
                .stroke(NwAppColors.strokeSubtle, lineWidth: NwStrokeWidth.thin)
        case .primary, .secondary:
            EmptyView()
        }
    }

    private var shadow: NwShadow.Spec {
        switch style {
        case .primary:   return NwShadow.card
        case .secondary: return NwShadow.card
        case .glass, .inset: return NwShadow.none
        }
    }
}

extension View {
    public func nwCardStyle(_ style: NwCardStyle, padding: CGFloat = NwSpacing.cardPadding) -> some View {
        modifier(NwCardModifier(style: style, padding: padding))
    }
}

public struct NwCard<Content: View>: View {
    public let style: NwCardStyle
    public let padding: CGFloat
    @ViewBuilder public var content: () -> Content

    public init(style: NwCardStyle = .primary, padding: CGFloat = NwSpacing.cardPadding, @ViewBuilder content: @escaping () -> Content) {
        self.style = style
        self.padding = padding
        self.content = content
    }

    public var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .nwCardStyle(style, padding: padding)
    }
}
