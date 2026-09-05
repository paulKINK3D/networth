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

struct NwTopLevelMenuAction: Identifiable {
    let title: String
    let systemImage: String
    let action: () -> Void

    var id: String { title }
}

/// Shared management menu for every top-level tab. Settings and Refresh stay
/// in the same position; each tab may append its own management actions.
struct NwTopLevelMenu: View {
    let canRefresh: Bool
    let contextualActions: [NwTopLevelMenuAction]
    let onRefresh: () -> Void
    let onSettings: () -> Void

    init(
        canRefresh: Bool,
        contextualActions: [NwTopLevelMenuAction] = [],
        onRefresh: @escaping () -> Void,
        onSettings: @escaping () -> Void
    ) {
        self.canRefresh = canRefresh
        self.contextualActions = contextualActions
        self.onRefresh = onRefresh
        self.onSettings = onSettings
    }

    var body: some View {
        Menu {
            Button(action: onSettings) {
                Label("Settings", systemImage: NwIcon.settings.rawValue)
            }

            Button(action: onRefresh) {
                Label("Refresh", systemImage: NwIcon.sync.rawValue)
            }
            .disabled(!canRefresh)

            if !contextualActions.isEmpty {
                Divider()
                ForEach(contextualActions) { item in
                    Button(action: item.action) {
                        Label(item.title, systemImage: item.systemImage)
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("More")
    }
}
