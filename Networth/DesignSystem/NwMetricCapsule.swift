import SwiftUI
import NetworthCore

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

/// Compact, card-backed money metric used beneath a detail-screen hero value.
public struct NwCompactMoneyMetricCard: View {
    public let amount: Money
    public let label: String
    public let detail: String?
    public let color: Color

    public init(
        amount: Money,
        label: String,
        detail: String? = nil,
        color: Color = NwAppColors.primary
    ) {
        self.amount = amount
        self.label = label
        self.detail = detail
        self.color = color
    }

    public var body: some View {
        VStack(spacing: 2) {
            NwAmountText(
                amount,
                variant: .metricSmall,
                showCents: false,
                color: color
            )
            Text(label)
                .font(NwTypography.footnoteEm)
                .foregroundStyle(NwAppColors.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 58)
        .padding(.horizontal, NwSpacing.md)
        .padding(.vertical, NwSpacing.sm)
        .background(
            RoundedRectangle(
                cornerRadius: NwCornerRadius.card,
                style: .continuous
            )
            .fill(NwAppColors.cardSurface)
        )
        .nwShadow(NwShadow.card)
        .overlay(alignment: .topTrailing) {
            if let detail {
                Text(detail)
                    .font(NwTypography.caption)
                    .foregroundStyle(NwAppColors.textOnPrimary)
                    .padding(.horizontal, NwSpacing.sm)
                    .padding(.vertical, 3)
                    .background(NwAppColors.caution)
                    .clipShape(Capsule())
                    .offset(x: 4, y: -8)
            }
        }
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

/// A compact draining-budget indicator. Remaining money is anchored at the
/// bottom so its level falls as spending occurs. Money explicitly moved to
/// Savings or Reserves remains a separate lighter segment.
public struct NwDrainingBudgetColumn: View {
    public let remainingShare: Double
    public let reallocatedShare: Double
    public let isOver: Bool
    public let width: CGFloat
    public let height: CGFloat
    public let accessibilityValue: String

    public init(
        remainingShare: Double,
        reallocatedShare: Double,
        isOver: Bool,
        width: CGFloat = 16,
        height: CGFloat = 56,
        accessibilityValue: String
    ) {
        self.remainingShare = remainingShare
        self.reallocatedShare = reallocatedShare
        self.isOver = isOver
        self.width = width
        self.height = height
        self.accessibilityValue = accessibilityValue
    }

    public var body: some View {
        GeometryReader { geometry in
            let remaining = min(max(remainingShare, 0), 1)
            let reallocated = min(
                max(reallocatedShare, 0),
                max(0, 1 - remaining)
            )
            ZStack(alignment: .bottom) {
                Capsule().fill(
                    isOver
                        ? NwAppColors.budgetOver.opacity(0.18)
                        : NwAppColors.strokeSubtle
                )
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Rectangle()
                        .fill(NwAppColors.budgetReallocated)
                        .frame(height: geometry.size.height * reallocated)
                    Rectangle()
                        .fill(NwAppColors.budgetRemaining)
                        .frame(height: geometry.size.height * remaining)
                }
                .clipShape(Capsule())
            }
        }
        .frame(width: width, height: height)
        .accessibilityElement()
        .accessibilityLabel("Budget remaining")
        .accessibilityValue(accessibilityValue)
    }
}

/// A compact Reserve balance column. Saved balance and any optional target use
/// the same caller-provided scale, so open-ended Reserves need no invented goal.
public struct NwReserveBalanceColumn: View {
    public let balanceShare: Double
    public let targetShare: Double?
    public let width: CGFloat
    public let height: CGFloat
    public let tint: Color

    public init(
        balanceShare: Double,
        targetShare: Double? = nil,
        width: CGFloat = 18,
        height: CGFloat = 56,
        tint: Color = NwAppColors.budgetReallocated
    ) {
        self.balanceShare = balanceShare
        self.targetShare = targetShare
        self.width = width
        self.height = height
        self.tint = tint
    }

    public var body: some View {
        GeometryReader { geometry in
            let balance = min(max(balanceShare, 0), 1)
            ZStack(alignment: .bottom) {
                if let targetShare {
                    Capsule()
                        .strokeBorder(
                            NwAppColors.strokeSubtle,
                            lineWidth: 1
                        )
                        .frame(
                            height: geometry.size.height
                                * min(max(targetShare, 0), 1)
                        )
                }
                if balance > 0 {
                    Capsule()
                        .fill(tint)
                        .frame(
                            height: max(4, geometry.size.height * balance)
                        )
                }
            }
            .frame(
                width: geometry.size.width,
                height: geometry.size.height,
                alignment: .bottom
            )
        }
        .frame(width: width, height: height)
    }
}
