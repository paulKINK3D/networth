import Foundation
import Testing
import Money
@testable import NetworthCore

@Suite("Spending history builder")
struct SpendingHistoryTests {
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
        treatment: ForecastTreatment? = .ordinarySpending,
        group: (identity: String, name: String)? = ("g:food", "Food"),
        category: (key: String, name: String) = ("c:dining", "Dining")
    ) -> SpendingHistoryEntry {
        SpendingHistoryEntry(
            transactionId: id,
            date: date,
            amountMilliunits: amount.milliunits,
            treatment: treatment,
            groupIdentity: group?.identity,
            groupName: group?.name,
            categoryKey: category.key,
            categoryName: category.name
        )
    }

    @Test func groupsSpendingAndOffsetsRefundsWithinCategory() {
        let now = day(2026, 8, 4)
        let months = SpendingHistoryBuilder.build(
            entries: [
                entry(date: day(2026, 8, 1), amount: Money.dollars(-60)),
                entry(date: day(2026, 8, 2), amount: Money.dollars(-40)),
                entry(
                    date: day(2026, 8, 3),
                    amount: Money.dollars(25),
                    treatment: .refund
                ),
                entry(
                    date: day(2026, 8, 3),
                    amount: Money.dollars(-10),
                    group: ("g:home", "Home"),
                    category: ("c:util", "Utilities")
                )
            ],
            monthsBack: 2,
            now: now,
            calendar: calendar
        )
        #expect(months.count == 2)
        let august = months[1]
        #expect(august.totalMilliunits == Money.dollars(-85).milliunits * -1)
        let food = august.groups.first { $0.id == "g:food" }
        #expect(food?.spentMilliunits == Money.dollars(75).milliunits)
        #expect(food?.categories.first?.transactionIds.count == 3)
        let home = august.groups.first { $0.id == "g:home" }
        #expect(home?.spentMilliunits == Money.dollars(10).milliunits)
    }

    @Test func excludesNonSpendingTreatmentsEverywhere() {
        let now = day(2026, 8, 4)
        let months = SpendingHistoryBuilder.build(
            entries: [
                entry(date: day(2026, 8, 1), amount: Money.dollars(-50)),
                entry(
                    date: day(2026, 8, 1),
                    amount: Money.dollars(2_000),
                    treatment: .income
                ),
                entry(
                    date: day(2026, 8, 1),
                    amount: Money.dollars(-500),
                    treatment: .cardPayment
                ),
                entry(
                    date: day(2026, 8, 1),
                    amount: Money.dollars(-300),
                    treatment: .internalTransfer
                ),
                entry(
                    date: day(2026, 8, 1),
                    amount: Money.dollars(-1_000),
                    treatment: .investmentContribution
                ),
                entry(
                    date: day(2026, 8, 1),
                    amount: Money.dollars(-75),
                    treatment: .excluded
                )
            ],
            monthsBack: 1,
            now: now,
            calendar: calendar
        )
        #expect(months.count == 1)
        #expect(months[0].totalMilliunits == Money.dollars(50).milliunits)
    }

    @Test func monthBoundariesBucketByCivilDayInSuppliedCalendar() {
        let now = day(2026, 8, 4)
        // 23:59 July 31 UTC stays July in a UTC calendar even though it is
        // already August in UTC+2.
        let lateJuly = calendar.date(
            byAdding: .minute, value: 24 * 60 - 1, to: day(2026, 7, 31)
        )!
        let months = SpendingHistoryBuilder.build(
            entries: [
                entry(date: lateJuly, amount: Money.dollars(-20)),
                entry(date: day(2026, 8, 1), amount: Money.dollars(-5))
            ],
            monthsBack: 2,
            now: now,
            calendar: calendar
        )
        #expect(months[0].totalMilliunits == Money.dollars(20).milliunits)
        #expect(months[1].totalMilliunits == Money.dollars(5).milliunits)
    }

    @Test func windowCoversExactly24MonthsOldestFirstWithZeroFill() {
        let now = day(2026, 8, 4)
        let months = SpendingHistoryBuilder.build(
            entries: [
                // Outside the window: 25 months back.
                entry(date: day(2024, 7, 15), amount: Money.dollars(-99)),
                // Oldest in-window month.
                entry(date: day(2024, 9, 3), amount: Money.dollars(-30)),
                // Future-dated rows never count toward MTD.
                entry(date: day(2026, 8, 20), amount: Money.dollars(-40))
            ],
            monthsBack: 24,
            now: now,
            calendar: calendar
        )
        #expect(months.count == 24)
        #expect(months.first?.month == day(2024, 9, 1))
        #expect(months.last?.month == day(2026, 8, 1))
        #expect(months.first?.totalMilliunits == Money.dollars(30).milliunits)
        #expect(months.last?.totalMilliunits == 0)
        #expect(months.dropFirst().dropLast()
            .allSatisfy { $0.totalMilliunits == 0 })
    }

    @Test func signMatrixRejectsMismatchedClassifications() {
        let now = day(2026, 8, 4)
        let months = SpendingHistoryBuilder.build(
            entries: [
                // Counted: negative ordinary, positive refund.
                entry(date: day(2026, 8, 1), amount: Money.dollars(-100)),
                entry(
                    date: day(2026, 8, 1),
                    amount: Money.dollars(30),
                    treatment: .refund
                ),
                // Ignored: positive ordinary, negative refund.
                entry(date: day(2026, 8, 2), amount: Money.dollars(50)),
                entry(
                    date: day(2026, 8, 2),
                    amount: Money.dollars(-40),
                    treatment: .refund
                )
            ],
            monthsBack: 1,
            now: now,
            calendar: calendar
        )
        #expect(months[0].totalMilliunits == Money.dollars(70).milliunits)
    }

    @Test func refundsExceedingSpendingKeepNegativeCategoryTotals() {
        let now = day(2026, 8, 4)
        let months = SpendingHistoryBuilder.build(
            entries: [
                entry(date: day(2026, 8, 1), amount: Money.dollars(-20)),
                entry(
                    date: day(2026, 8, 2),
                    amount: Money.dollars(80),
                    treatment: .refund
                )
            ],
            monthsBack: 1,
            now: now,
            calendar: calendar
        )
        #expect(months[0].totalMilliunits == Money.dollars(-60).milliunits)
        #expect(months[0].groups.first?.spentMilliunits
            == Money.dollars(-60).milliunits)
    }

    @Test func windowBoundariesAreInclusive() {
        let now = day(2026, 8, 4)
        let windowStart = day(2026, 7, 1)
        let months = SpendingHistoryBuilder.build(
            entries: [
                // Exactly at the window start and exactly at `now`.
                entry(date: windowStart, amount: Money.dollars(-10)),
                entry(date: now, amount: Money.dollars(-5))
            ],
            monthsBack: 2,
            now: now,
            calendar: calendar
        )
        #expect(months[0].totalMilliunits == Money.dollars(10).milliunits)
        #expect(months[1].totalMilliunits == Money.dollars(5).milliunits)
    }

    @Test func splitLegsSharingATransactionListItOncePerCategory() {
        let now = day(2026, 8, 4)
        let months = SpendingHistoryBuilder.build(
            entries: [
                entry(
                    id: "parent",
                    date: day(2026, 8, 1),
                    amount: Money.dollars(-60)
                ),
                entry(
                    id: "parent",
                    date: day(2026, 8, 1),
                    amount: Money.dollars(-40)
                )
            ],
            monthsBack: 1,
            now: now,
            calendar: calendar
        )
        let category = months[0].groups.first?.categories.first
        #expect(category?.spentMilliunits == Money.dollars(100).milliunits)
        #expect(category?.transactionIds == ["parent"])
    }

    @Test func ungroupedEntriesFoldIntoOtherBucket() {
        let now = day(2026, 8, 4)
        let months = SpendingHistoryBuilder.build(
            entries: [
                entry(
                    date: day(2026, 8, 1),
                    amount: Money.dollars(-15),
                    group: nil,
                    category: ("c:misc", "Misc")
                )
            ],
            monthsBack: 1,
            now: now,
            calendar: calendar
        )
        let group = months[0].groups.first
        #expect(group?.id == SpendingHistoryBuilder.ungroupedIdentity)
        #expect(group?.name == SpendingHistoryBuilder.ungroupedName)
        #expect(group?.spentMilliunits == Money.dollars(15).milliunits)
    }
}
