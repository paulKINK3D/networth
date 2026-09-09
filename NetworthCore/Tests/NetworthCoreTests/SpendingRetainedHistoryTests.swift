import Foundation
import Testing
import Money
@testable import NetworthCore

@Suite("Spending retained history")
struct SpendingRetainedHistoryTests {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: year, month: month, day: day
        ))!
    }

    private func entry(
        id: String = UUID().uuidString,
        date: Date,
        amount: Money,
        treatment: ForecastTreatment? = .ordinarySpending
    ) -> SpendingHistoryEntry {
        SpendingHistoryEntry(
            transactionId: id,
            date: date,
            amountMilliunits: amount.milliunits,
            treatment: treatment,
            groupIdentity: "g:food",
            groupName: "Food",
            categoryKey: "c:dining",
            categoryName: "Dining"
        )
    }

    /// Income lands in month 2 and spending in month 3, so month 1 has no
    /// preceding month at all and month 2 is funded by zero income.
    private func threeMonths() -> [SpendingHistoryMonth] {
        SpendingHistoryBuilder.build(
            entries: [
                entry(
                    date: day(2026, 7, 15),
                    amount: Money.dollars(3000),
                    treatment: .income
                ),
                entry(date: day(2026, 8, 10), amount: Money.dollars(-1000))
            ],
            monthsBack: 3,
            now: day(2026, 8, 20),
            calendar: calendar
        )
    }

    @Test func dropsUnfundedLeadingMonths() {
        let series = SpendingRetainedHistoryBuilder.retainedSeries(
            months: threeMonths(),
            budgetSummary: { _ in SpendingBudgetSummary(groups: []) },
            calendar: calendar
        )
        #expect(series.count == 1)
        #expect(series.first?.month == day(2026, 8, 1))
    }

    @Test func withoutBudgetsRetainedIsFundedMinusOrdinarySpending() {
        let series = SpendingRetainedHistoryBuilder.retainedSeries(
            months: threeMonths(),
            budgetSummary: { _ in SpendingBudgetSummary(groups: []) },
            calendar: calendar
        )
        let month = try! #require(series.first)
        #expect(month.funded == Money.dollars(3000))
        #expect(month.used == Money.dollars(1000))
        #expect(month.retained == Money.dollars(2000))
    }

    @Test func withBudgetsRetainedIsReconciledBudgetRemaining() {
        let budget = SpendingBudgetSummary(groups: [
            SpendingGroupBudgetSnapshot(
                groupIdentity: "g:food",
                groupName: "Food",
                spent: Money.dollars(500),
                target: Money.dollars(2000)
            )
        ])
        let series = SpendingRetainedHistoryBuilder.retainedSeries(
            months: threeMonths(),
            budgetSummary: { month in
                calendar.component(.month, from: month.month) == 8
                    ? budget : SpendingBudgetSummary(groups: [])
            },
            calendar: calendar
        )
        let month = try! #require(series.first)
        #expect(month.funded == Money.dollars(3000))
        #expect(month.retained == Money.dollars(1500))
        #expect(month.used == Money.dollars(1500))
    }

    @Test func zeroFundedMonthAfterHistoryBeginsStaysInSeries() {
        // Income in month 1 only: month 2 is funded, month 3's funding is a
        // real zero-income month and must remain visible.
        let months = SpendingHistoryBuilder.build(
            entries: [
                entry(
                    date: day(2026, 6, 15),
                    amount: Money.dollars(3000),
                    treatment: .income
                ),
                entry(date: day(2026, 8, 10), amount: Money.dollars(-400))
            ],
            monthsBack: 3,
            now: day(2026, 8, 20),
            calendar: calendar
        )
        let series = SpendingRetainedHistoryBuilder.retainedSeries(
            months: months,
            budgetSummary: { _ in SpendingBudgetSummary(groups: []) },
            calendar: calendar
        )
        #expect(series.map(\.month) == [day(2026, 7, 1), day(2026, 8, 1)])
        #expect(series.last?.retained == Money.dollars(-400))
    }
}
