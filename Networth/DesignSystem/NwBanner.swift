import SwiftUI

public struct NwBanner: View {
    public let title: String
    public let message: String?
    public let tone: NwInlineNotice.Tone
    public let action: (() -> Void)?
    public let actionTitle: String?

    public init(
        _ title: String,
        message: String? = nil,
        tone: NwInlineNotice.Tone = .info,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.tone = tone
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        HStack(alignment: .center, spacing: NwSpacing.md) {
            VStack(alignment: .leading, spacing: NwSpacing.xs) {
                Text(title).font(NwTypography.bodyEmphasis)
                if let message {
                    Text(message)
                        .font(NwTypography.footnote)
                        .foregroundStyle(NwAppColors.textSecondary)
                }
            }
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(NwTintedButtonStyle())
            }
        }
        .padding(NwSpacing.cardPadding)
        .background(tint.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: NwCornerRadius.md, style: .continuous)
                .stroke(tint.opacity(0.30), lineWidth: NwStrokeWidth.thin)
        )
        .clipShape(RoundedRectangle(cornerRadius: NwCornerRadius.md, style: .continuous))
    }

    private var tint: Color {
        switch tone {
        case .info:    return NwAppColors.info
        case .caution: return NwAppColors.caution
        case .warning: return NwAppColors.liability
        case .success: return NwAppColors.positive
        }
    }
}
