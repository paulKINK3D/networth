import SwiftUI

public struct NwSectionHeader: View {
    public let title: String
    public let subtitle: String?
    public let trailing: AnyView?

    public init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = nil
    }

    public init<Trailing: View>(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = AnyView(trailing())
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: NwSpacing.xs) {
                Text(title)
                    .font(NwTypography.titleSmall)
                    .foregroundStyle(NwAppColors.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(NwTypography.footnote)
                        .foregroundStyle(NwAppColors.textSecondary)
                }
            }
            Spacer()
            if let trailing { trailing }
        }
        .padding(.horizontal, NwSpacing.screenPadding)
    }
}

public struct NwSettingsNavigationRow: View {
    public let title: String
    public let subtitle: String
    public let icon: NwIcon
    public let value: String?

    public init(
        _ title: String,
        subtitle: String,
        icon: NwIcon,
        value: String? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.value = value
    }

    public var body: some View {
        HStack(spacing: NwSpacing.md) {
            icon.image
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(NwAppColors.primary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(NwTypography.bodyEmphasis)
                    .foregroundStyle(NwAppColors.textPrimary)
                Text(subtitle)
                    .font(NwTypography.footnote)
                    .foregroundStyle(NwAppColors.textSecondary)
            }
            Spacer(minLength: NwSpacing.sm)
            if let value {
                Text(value)
                    .font(NwTypography.footnote)
                    .foregroundStyle(NwAppColors.textSecondary)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, NwSpacing.xs)
    }
}

public struct NwSettingsActionRow: View {
    public let title: String
    public let subtitle: String
    public let icon: NwIcon

    public init(
        _ title: String,
        subtitle: String,
        icon: NwIcon
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
    }

    public var body: some View {
        HStack(spacing: NwSpacing.md) {
            icon.image
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(NwAppColors.primary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(NwTypography.bodyEmphasis)
                    .foregroundStyle(NwAppColors.textPrimary)
                Text(subtitle)
                    .font(NwTypography.footnote)
                    .foregroundStyle(NwAppColors.textSecondary)
            }
            Spacer(minLength: NwSpacing.sm)
            NwIcon.chevron.image
                .foregroundStyle(NwAppColors.textSecondary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, NwSpacing.xs)
    }
}
