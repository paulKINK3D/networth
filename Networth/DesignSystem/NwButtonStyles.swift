import SwiftUI

public struct NwPrimaryButtonStyle: ButtonStyle {
    public var tint: Color

    public init(tint: Color = NwAppColors.primary) {
        self.tint = tint
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(NwTypography.bodyEmphasis)
            .foregroundStyle(NwAppColors.textOnPrimary)
            .padding(.vertical, NwSpacing.md)
            .padding(.horizontal, NwSpacing.xl)
            .frame(maxWidth: .infinity)
            .background(tint)
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

/// Shared management menu for every top-level tab. Account management and
/// Settings are stable destinations; manual refresh is the fallback action
/// now that normal refresh happens automatically when the app opens.
struct NwTopLevelMenu: View {
    let canRefresh: Bool
    let onAccounts: () -> Void
    let onRefresh: () -> Void
    let onSettings: () -> Void

    init(
        canRefresh: Bool,
        onAccounts: @escaping () -> Void,
        onRefresh: @escaping () -> Void,
        onSettings: @escaping () -> Void
    ) {
        self.canRefresh = canRefresh
        self.onAccounts = onAccounts
        self.onRefresh = onRefresh
        self.onSettings = onSettings
    }

    var body: some View {
        Menu {
            Button(action: onAccounts) {
                Label("Accounts", systemImage: NwIcon.accounts.rawValue)
            }

            Button(action: onSettings) {
                Label("Settings", systemImage: NwIcon.settings.rawValue)
            }

            Divider()

            Button(action: onRefresh) {
                Label("Refresh Data", systemImage: NwIcon.sync.rawValue)
            }
            .disabled(!canRefresh)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("More")
    }
}
