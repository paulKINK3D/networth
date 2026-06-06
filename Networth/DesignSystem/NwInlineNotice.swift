import SwiftUI

public struct NwInlineNotice: View {
    public enum Tone { case info, caution, warning, success }

    public let tone: Tone
    public let title: String
    public let message: String?

    public init(_ title: String, message: String? = nil, tone: Tone = .info) {
        self.title = title
        self.message = message
        self.tone = tone
    }

    public var body: some View {
        HStack(alignment: .top, spacing: NwSpacing.md) {
            icon.image
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: NwSpacing.xs) {
                Text(title)
                    .font(NwTypography.bodyEmphasis)
                if let message {
                    Text(message)
                        .font(NwTypography.callout)
                        .foregroundStyle(NwAppColors.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(NwSpacing.cardPadding)
        .background(color.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: NwCornerRadius.md, style: .continuous)
                .stroke(color.opacity(0.25), lineWidth: NwStrokeWidth.thin)
        )
        .clipShape(RoundedRectangle(cornerRadius: NwCornerRadius.md, style: .continuous))
    }

    private var color: Color {
        switch tone {
        case .info:    return NwAppColors.info
        case .caution: return NwAppColors.caution
        case .warning: return NwAppColors.liability
        case .success: return NwAppColors.positive
        }
    }

    private var icon: NwIcon {
        switch tone {
        case .info:    return .info
        case .caution: return .warning
        case .warning: return .error
        case .success: return .success
        }
    }
}
