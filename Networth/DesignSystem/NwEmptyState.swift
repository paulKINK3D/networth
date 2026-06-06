import SwiftUI

public struct NwEmptyState: View {
    public let title: String
    public let message: String
    public let icon: NwIcon
    public let actionTitle: String?
    public let action: (() -> Void)?

    public init(
        title: String,
        message: String,
        icon: NwIcon = .empty,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.icon = icon
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: NwSpacing.lg) {
            icon.image
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(NwAppColors.textSecondary)
            VStack(spacing: NwSpacing.xs) {
                Text(title)
                    .font(NwTypography.titleSmall)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(NwTypography.callout)
                    .foregroundStyle(NwAppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, NwSpacing.lg)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(NwPrimaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(NwSpacing.xl)
    }
}
