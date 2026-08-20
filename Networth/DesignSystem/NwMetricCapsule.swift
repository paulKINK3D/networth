import SwiftUI

public struct NwMetricCapsule: View {
    public let label: String
    public let value: String
    public let valueColor: Color
    public let symbol: NwIcon?

    public init(label: String, value: String, valueColor: Color = NwAppColors.textPrimary, symbol: NwIcon? = nil) {
        self.label = label
        self.value = value
        self.valueColor = valueColor
        self.symbol = symbol
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: NwSpacing.xs) {
            HStack(spacing: NwSpacing.xs) {
                if let symbol {
                    symbol.image
                        .font(NwTypography.footnoteEm)
                        .foregroundStyle(NwAppColors.textSecondary)
                }
                Text(label)
                    .font(NwTypography.caption)
                    .foregroundStyle(NwAppColors.textSecondary)
                    .textCase(.uppercase)
            }
            Text(value)
                .font(NwTypography.bodyEmphasis)
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shared factual budget progress. The visible fill caps at the target while
/// accessibility retains the uncapped percentage when spending is over.
public struct NwBudgetProgress: View {
    public let progress: Double
    public let isOver: Bool
    public let accessibilityLabel: String

    public init(
        progress: Double,
        isOver: Bool,
        accessibilityLabel: String = "Budget progress"
    ) {
        self.progress = progress
        self.isOver = isOver
        self.accessibilityLabel = accessibilityLabel
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(NwAppColors.strokeSubtle)
                Capsule()
                    .fill(isOver ? NwAppColors.liability : NwAppColors.primary)
                    .frame(
                        width: geometry.size.width
                            * min(max(progress, 0), 1)
                    )
            }
        }
        .frame(height: 8)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(
            "\(Int((max(progress, 0) * 100).rounded())) percent"
        )
    }
}
