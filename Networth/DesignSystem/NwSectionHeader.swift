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
