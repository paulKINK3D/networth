import SwiftUI

/// A row value that opens another screen. Pairs the current value with the
/// standard trailing disclosure chevron so pushed pickers stay visually
/// distinct from inline menu pickers, whose up/down chevrons mean the choice
/// happens in place.
public struct NwDisclosureValue: View {
    private let text: String
    private let color: Color

    public init(_ text: String, color: Color = NwAppColors.textSecondary) {
        self.text = text
        self.color = color
    }

    public var body: some View {
        HStack(spacing: NwSpacing.xs) {
            Text(text)
                .foregroundStyle(color)
                .lineLimit(1)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(NwAppColors.textSecondary)
        }
    }
}
