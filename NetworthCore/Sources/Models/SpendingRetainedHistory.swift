import Foundation
import Money

/// One month's funded-vs-used reconciliation for history surfaces. Amounts
/// are the same whole-dollar headlines the Spending hero shows.
public struct SpendingRetainedMonthSummary: Sendable, Hashable, Identifiable {
    public let month: Date
    public let funded: Money
    public let used: Money
    public let retained: Money

    public var id: Date { month }

    public init(month: Date, funded: Money, used: Money, retained: Money) {
        self.month = month
        self.funded = funded
        self.used = used
        self.retained = retained
    }
}

/// Derives Retained history from the same reconciliation the Spending hero
/// uses, so a history chart and the selected month's card can never disagree.
public enum SpendingRetainedHistoryBuilder {
    /// The hero's funding reconciliation for one month: budget-reconciled
    /// when the month has budget groups, otherwise funded minus ordinary
    /// spending.
    public static func fundingDisplay(
        for month: SpendingHistoryMonth,
        within months: [SpendingHistoryMonth],
        budgetSummary: SpendingBudgetSummary,
        calendar: Calendar = .current
    ) -> SpendingHistoryFundingDisplay {
        let funded = SpendingHistoryBuilder.fundingIncome(
            for: month,
            within: months,
            calendar: calendar
        )
        return budgetSummary.groups.isEmpty
            ? month.fundingDisplay(fundedBy: funded)
            : budgetSummary.fundingDisplay(fundedBy: funded)
    }

    /// Months with a known funding amount, oldest first. Months before the
    /// preceding month exists, and leading months funded by zero income,
    /// are omitted: before income history begins, a Retained bar would
    /// present data absence as overspending.
    public static func retainedSeries(
        months: [SpendingHistoryMonth],
        budgetSummary: (SpendingHistoryMonth) -> SpendingBudgetSummary,
        calendar: Calendar = .current
    ) -> [SpendingRetainedMonthSummary] {
        var series: [SpendingRetainedMonthSummary] = []
        for month in months {
            let display = fundingDisplay(
                for: month,
                within: months,
                budgetSummary: budgetSummary(month),
                calendar: calendar
            )
            guard let funded = display.fundedHeadline,
                  let retained = display.remainingHeadline else { continue }
            if series.isEmpty, funded == .zero { continue }
            series.append(SpendingRetainedMonthSummary(
                month: month.month,
                funded: funded,
                used: display.usedHeadline,
                retained: retained
            ))
        }
        return series
    }
}
