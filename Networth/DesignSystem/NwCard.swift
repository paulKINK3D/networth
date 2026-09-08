import SwiftUI

public enum NwCardStyle {
    case primary
    case secondary
    case planning
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
        case .planning:
            RoundedRectangle(cornerRadius: NwCornerRadius.card, style: .continuous)
                .fill(NwAppColors.planningSurface)
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
        case .inset:
            RoundedRectangle(cornerRadius: NwCornerRadius.card, style: .continuous)
                .stroke(NwAppColors.strokeSubtle, lineWidth: NwStrokeWidth.thin)
        case .glass:
            EmptyView()
        case .planning:
            RoundedRectangle(cornerRadius: NwCornerRadius.card, style: .continuous)
                .stroke(
                    NwAppColors.planningStroke,
                    lineWidth: NwStrokeWidth.thin
                )
        case .primary, .secondary:
            RoundedRectangle(cornerRadius: NwCornerRadius.card, style: .continuous)
                .stroke(
                    NwAppColors.surfaceHighlight,
                    lineWidth: NwStrokeWidth.hairline
                )
        }
    }

    private var shadow: NwShadow.Spec {
        switch style {
        case .primary:   return NwShadow.card
        case .secondary, .planning: return NwShadow.card
        case .glass, .inset: return NwShadow.none
        }
    }
}

extension View {
    public func nwCardStyle(_ style: NwCardStyle, padding: CGFloat = NwSpacing.cardPadding) -> some View {
        modifier(NwCardModifier(style: style, padding: padding))
    }

    /// Places scrollable content (List, Form) on the warm theme field instead
    /// of the cool system grouped background. When a field photo is set, the
    /// screen gets its frosted echo rather than the crisp tab treatment.
    public func nwScreenBackground() -> some View {
        self
            .scrollContentBackground(.hidden)
            .nwFrostedFieldBackground()
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

/// Shared high-contrast summary surface for the app's daily-use dashboards.
/// Screen-specific graphics stay with their owning feature while the surface,
/// spacing, and adaptive foreground treatment remain consistent.
public struct NwDashboardHero<Content: View>: View {
    @ViewBuilder public var content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(NwSpacing.cardPadding)
            .background(
                RoundedRectangle(
                    cornerRadius: NwCornerRadius.card,
                    style: .continuous
                )
                .fill(
                    LinearGradient(
                        colors: [
                            NwAppColors.dashboardHeroSurfaceTop,
                            NwAppColors.dashboardHeroSurfaceBottom
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .stroke(Color.white.opacity(0.05), lineWidth: 44)
                        .frame(width: 300, height: 300)
                        .offset(x: 90, y: -90)
                }
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: NwCornerRadius.card,
                        style: .continuous
                    )
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: NwCornerRadius.card,
                    style: .continuous
                )
                .stroke(
                    Color.white.opacity(0.16),
                    lineWidth: NwStrokeWidth.hairline
                )
            }
            .clipShape(
                RoundedRectangle(
                    cornerRadius: NwCornerRadius.card,
                    style: .continuous
                )
            )
            .nwShadow(NwShadow.heroContact)
            .nwShadow(NwShadow.elevated)
    }
}
