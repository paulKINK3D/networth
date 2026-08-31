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
    public let tint: Color?
    public let trackTint: Color?
    public let height: CGFloat
    public let accessibilityLabel: String

    public init(
        progress: Double,
        isOver: Bool,
        tint: Color? = nil,
        trackTint: Color? = nil,
        height: CGFloat = 12,
        accessibilityLabel: String = "Budget progress"
    ) {
        self.progress = progress
        self.isOver = isOver
        self.tint = tint
        self.trackTint = trackTint
        self.height = height
        self.accessibilityLabel = accessibilityLabel
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackTint ?? NwAppColors.strokeSubtle)
                Capsule()
                    .fill(
                        tint
                            ?? (isOver
                                ? NwAppColors.budgetAtRisk
                                : NwAppColors.budgetOnTrack)
                    )
                    .frame(
                        width: geometry.size.width
                            * min(max(progress, 0), 1)
                    )
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(
            "\(Int((max(progress, 0) * 100).rounded())) percent"
        )
    }
}

/// Ordinary budget progress with a distinct second segment for money moved
/// into Savings. Spending and reallocation remain visually separate because
/// a savings choice is not a transaction.
public struct NwReallocatedBudgetProgress: View {
    public let spentShare: Double
    public let reallocatedShare: Double
    public let isOver: Bool
    public let height: CGFloat
    public let accessibilityValue: String

    public init(
        spentShare: Double,
        reallocatedShare: Double,
        isOver: Bool,
        height: CGFloat = 6,
        accessibilityValue: String
    ) {
        self.spentShare = spentShare
        self.reallocatedShare = reallocatedShare
        self.isOver = isOver
        self.height = height
        self.accessibilityValue = accessibilityValue
    }

    public var body: some View {
        GeometryReader { geometry in
            let spent = min(max(spentShare, 0), 1)
            let reallocated = min(
                max(reallocatedShare, 0),
                max(0, 1 - spent)
            )
            ZStack(alignment: .leading) {
                Capsule().fill(NwAppColors.strokeSubtle)
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(
                            isOver
                                ? NwAppColors.budgetOver
                                : NwAppColors.budgetOnTrack
                        )
                        .frame(width: geometry.size.width * spent)
                    Rectangle()
                        .fill(NwAppColors.budgetReallocated)
                        .frame(width: geometry.size.width * reallocated)
                    Spacer(minLength: 0)
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Budget progress")
        .accessibilityValue(accessibilityValue)
    }
}

/// Savings uses the same compact budget bar with a separate green extension
/// for one-month choices moved in from another budget group. The primary bar
/// remains actual transfer progress toward the repeating target.
public struct NwSavingsBudgetProgress: View {
    public let baseProgress: Double
    public let additionalShare: Double
    public let height: CGFloat
    public let accessibilityValue: String

    public init(
        baseProgress: Double,
        additionalShare: Double,
        height: CGFloat = 6,
        accessibilityValue: String
    ) {
        self.baseProgress = baseProgress
        self.additionalShare = additionalShare
        self.height = height
        self.accessibilityValue = accessibilityValue
    }

    public var body: some View {
        GeometryReader { geometry in
            let share = additionalShare > 0
                ? min(max(additionalShare, 0.08), 0.4)
                : 0
            let gap: CGFloat = share > 0 ? 8 : 0
            let availableWidth = max(0, geometry.size.width - gap)
            let additionalWidth = availableWidth * share
            let baseWidth = availableWidth - additionalWidth

            HStack(spacing: gap) {
                ZStack(alignment: .leading) {
                    Capsule().fill(NwAppColors.strokeSubtle)
                    Capsule()
                        .fill(NwAppColors.primary)
                        .frame(
                            width: baseWidth
                                * min(max(baseProgress, 0), 1)
                        )
                }
                .frame(width: baseWidth)

                if share > 0 {
                    Capsule()
                        .fill(NwAppColors.favorableFill)
                        .frame(width: additionalWidth)
                }
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Savings budget progress")
        .accessibilityValue(accessibilityValue)
    }
}
