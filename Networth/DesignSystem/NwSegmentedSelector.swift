import SwiftUI

/// Equal-width pill selector for switching peer views on one screen.
/// Selected segment fills the brand primary; unselected segments stay quiet
/// on the shared alternate surface. Matches the Spending Plan/Future control.
struct NwSegmentedSelector<Option: Hashable & Identifiable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String

    var body: some View {
        HStack(spacing: NwSpacing.xs) {
            ForEach(options) { option in
                let isSelected = selection == option
                Button {
                    selection = option
                } label: {
                    Text(title(option))
                        .font(NwTypography.bodyEmphasis)
                        .foregroundStyle(
                            isSelected
                                ? NwAppColors.textOnPrimary
                                : NwAppColors.textSecondary
                        )
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(
                            RoundedRectangle(
                                cornerRadius: NwCornerRadius.md,
                                style: .continuous
                            )
                            .fill(
                                isSelected
                                    ? NwAppColors.primary
                                    : Color.clear
                            )
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(
                    isSelected ? .isSelected : []
                )
            }
        }
        .padding(NwSpacing.xs)
        .background(
            RoundedRectangle(
                cornerRadius: NwCornerRadius.card,
                style: .continuous
            )
            .fill(NwAppColors.cardSurfaceAlt)
        )
        .accessibilityElement(children: .contain)
    }
}
