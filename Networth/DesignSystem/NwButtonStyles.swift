import SwiftUI

public struct NwPrimaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(NwTypography.bodyEmphasis)
            .foregroundStyle(NwAppColors.textOnPrimary)
            .padding(.vertical, NwSpacing.md)
            .padding(.horizontal, NwSpacing.xl)
            .frame(maxWidth: .infinity)
            .background(NwAppColors.primary)
            .clipShape(RoundedRectangle(cornerRadius: NwCornerRadius.md, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

public struct NwSecondaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(NwTypography.bodyEmphasis)
            .foregroundStyle(NwAppColors.primary)
            .padding(.vertical, NwSpacing.md)
            .padding(.horizontal, NwSpacing.xl)
            .frame(maxWidth: .infinity)
            .background(NwAppColors.primary.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: NwCornerRadius.md, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

public struct NwTintedButtonStyle: ButtonStyle {
    public var tint: Color = NwAppColors.accent
    public init(tint: Color = NwAppColors.accent) { self.tint = tint }
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(NwTypography.footnoteEm)
            .foregroundStyle(tint)
            .padding(.vertical, NwSpacing.sm)
            .padding(.horizontal, NwSpacing.md)
            .background(tint.opacity(0.14))
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

public struct NwDestructiveButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(NwTypography.bodyEmphasis)
            .foregroundStyle(Color.white)
            .padding(.vertical, NwSpacing.md)
            .padding(.horizontal, NwSpacing.xl)
            .frame(maxWidth: .infinity)
            .background(NwAppColors.liability)
            .clipShape(RoundedRectangle(cornerRadius: NwCornerRadius.md, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}
