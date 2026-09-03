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
        reportingRole: CategoryReportingRole? = nil,
        group: (identity: String, name: String)? = ("g:food", "Food"),
        category: (key: String, name: String) = ("c:dining", "Dining")
    ) -> SpendingHistoryEntry {
        SpendingHistoryEntry(
            transactionId: id,
            date: date,
            amountMilliunits: amount.milliunits,
            treatment: treatment,
            reportingRole: reportingRole,
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

    @Test func excludesNonReportedTreatmentsEverywhere() {
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

    @Test func goalFundedPurchasesStayOutsideMonthlySpending() {
        let months = SpendingHistoryBuilder.build(
            entries: [
                entry(
                    date: day(2026, 8, 1),
                    amount: Money.dollars(-200),
                    treatment: .goalSpend,
                    reportingRole: .spending,
                    group: ("networth:goal-purchases", "Goals"),
                    category: ("c:furniture", "Furniture")
                )
            ],
            monthsBack: 1,
            now: day(2026, 8, 4),
            calendar: calendar
        )

        #expect(months[0].totalMilliunits == 0)
        #expect(months[0].ordinaryTotalMilliunits == 0)
        #expect(months[0].groups.isEmpty)
    }

    @Test func countsOnlyPositiveExplicitIncome() {
        let months = SpendingHistoryBuilder.build(
            entries: [
                entry(
                    date: day(2026, 8, 1),
                    amount: Money.dollars(3_000),
                    treatment: .income
                ),
                entry(
                    date: day(2026, 8, 2),
                    amount: Money.dollars(-200),
                    treatment: .income
                ),
                entry(
                    date: day(2026, 8, 3),
                    amount: Money.dollars(25),
                    treatment: .refund
                )
            ],
            monthsBack: 1,
            now: day(2026, 8, 4),
            calendar: calendar
        )

        #expect(months[0].incomeMilliunits == Money.dollars(3_000).milliunits)
        #expect(months[0].ordinaryTotalMilliunits == 0)
    }

    @Test func includesNetSavingsAndInvestmentAlongsideOrdinarySpending() {
        let now = day(2026, 8, 4)
        let months = SpendingHistoryBuilder.build(
            entries: [
                entry(date: day(2026, 8, 1), amount: Money.dollars(-50)),
                // Savings deposits use the positive savings-account side;
                // withdrawals reduce the month's net savings allocation.
                entry(
                    date: day(2026, 8, 1),
                    amount: Money.dollars(400),
                    treatment: .internalTransfer,
                    reportingRole: .transfer,
                    group: ("networth:savings", "Savings"),
                    category: ("networth:savings-transfer", "Savings Transfers")
                ),
                entry(
                    date: day(2026, 8, 2),
                    amount: Money.dollars(-100),
                    treatment: .internalTransfer,
                    reportingRole: .transfer,
                    group: ("networth:savings", "Savings"),
                    category: ("networth:savings-transfer", "Savings Transfers")
                ),
                // Investment contributions use the negative funding side;
                // positive withdrawals offset net contributions.
                entry(
                    date: day(2026, 8, 2),
                    amount: Money.dollars(-600),
                    treatment: .investmentContribution,
                    reportingRole: .investment,
                    group: ("networth:investment", "Investment"),
                    category: ("networth:investment-contribution", "Contributions")
                ),
                entry(
                    date: day(2026, 8, 3),
                    amount: Money.dollars(75),
                    treatment: .investmentContribution,
                    reportingRole: .investment,
                    group: ("networth:investment", "Investment"),
                    category: ("networth:investment-contribution", "Contributions")
                )
            ],
            monthsBack: 1,
            now: now,
            calendar: calendar
        )

        #expect(months[0].totalMilliunits == Money.dollars(875).milliunits)
        #expect(months[0].groups.first {
            $0.id == "networth:savings"
        }?.spentMilliunits == Money.dollars(300).milliunits)
        #expect(months[0].groups.first {
            $0.id == "networth:investment"
        }?.spentMilliunits == Money.dollars(525).milliunits)
    }

    @Test func zeroActivityGroupDefinitionsKeepColumnsStable() {
        let now = day(2026, 8, 4)
        let months = SpendingHistoryBuilder.build(
            entries: [],
            groups: [
                SpendingHistoryGroupDefinition(id: "fixed", name: "Fixed"),
                SpendingHistoryGroupDefinition(id: "savings", name: "Savings")
            ],
            monthsBack: 2,
            now: now,
            calendar: calendar
        )

        #expect(months.count == 2)
        #expect(months.allSatisfy { month in
            month.totalMilliunits == 0
                && Set(month.groups.map(\.id)) == ["fixed", "savings"]
                && month.groups.allSatisfy { $0.spentMilliunits == 0 }
        })
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
        // The group keeps its honest negative net for inspection, but the
        // month headline clamps it to zero — refund inflow must never erase
        // other groups' spending from the total.
        #expect(months[0].totalMilliunits == 0)
        #expect(months[0].groups.first?.spentMilliunits
            == Money.dollars(-60).milliunits)
    }

    @Test func netNegativeGroupDoesNotEraseOtherGroupsFromTotal() {
        let now = day(2026, 8, 4)
        let months = SpendingHistoryBuilder.build(
            entries: [
                entry(date: day(2026, 8, 1), amount: Money.dollars(-500)),
                entry(
                    date: day(2026, 8, 2),
                    amount: Money.dollars(900),
                    treatment: .refund,
                    group: ("g:reimb", "Reimbursement"),
                    category: ("c:reimb", "Reimbursement")
                )
            ],
            monthsBack: 1,
            now: now,
            calendar: calendar
        )
        #expect(months[0].totalMilliunits == Money.dollars(500).milliunits)
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

    @Test func wholeDollarGroupRowsReconcileUpToRoundedHeadline() {
        let month = SpendingHistoryBuilder.build(
            entries: [
                entry(
                    date: day(2026, 8, 1),
                    amount: Money.dollars(Decimal(string: "-10.49")!),
                    group: ("g:a", "A")
                ),
                entry(
                    date: day(2026, 8, 1),
                    amount: Money.dollars(Decimal(string: "-10.49")!),
                    group: ("g:b", "B")
                )
            ],
            monthsBack: 1,
            now: day(2026, 8, 4),
            calendar: calendar
        )[0]

        let display = month.wholeDollarDisplay
        #expect(display.ordinaryHeadline == Money.dollars(21))
        #expect(display.groupAmountsByID["g:a"] == Money.dollars(11))
        #expect(display.groupAmountsByID["g:b"] == Money.dollars(10))
        #expect(display.groupAmountsByID.values.sum()
            == display.ordinaryHeadline)
    }

    @Test func wholeDollarGroupRowsReconcileDownToRoundedHeadline() {
        let month = SpendingHistoryBuilder.build(
            entries: [
                entry(
                    date: day(2026, 8, 1),
                    amount: Money.dollars(Decimal(string: "-10.51")!),
                    group: ("g:a", "A")
                ),
                entry(
                    date: day(2026, 8, 1),
                    amount: Money.dollars(Decimal(string: "-10.51")!),
                    group: ("g:b", "B")
                )
            ],
            monthsBack: 1,
            now: day(2026, 8, 4),
            calendar: calendar
        )[0]

        let display = month.wholeDollarDisplay
        #expect(display.ordinaryHeadline == Money.dollars(21))
        #expect(display.groupAmountsByID["g:a"] == Money.dollars(11))
        #expect(display.groupAmountsByID["g:b"] == Money.dollars(10))
        #expect(display.groupAmountsByID.values.sum()
            == display.ordinaryHeadline)
    }

    @Test func aggregatesMonthsWithoutLosingDrillDownData() throws {
        let months = SpendingHistoryBuilder.build(
            entries: [
                entry(
                    id: "june-dining",
                    date: day(2026, 6, 2),
                    amount: Money.dollars(-10)
                ),
                entry(
                    id: "july-groceries",
                    date: day(2026, 7, 2),
                    amount: Money.dollars(-20),
                    category: ("c:groceries", "Groceries")
                ),
                entry(
                    id: "august-dining",
                    date: day(2026, 8, 2),
                    amount: Money.dollars(-30)
                ),
                entry(
                    id: "july-investing",
                    date: day(2026, 7, 3),
                    amount: Money.dollars(-40),
                    treatment: .investmentContribution,
                    reportingRole: .investment,
                    group: ("g:investing", "Investing"),
                    category: ("c:contribution", "Contributions")
                ),
                entry(
                    id: "june-income",
                    date: day(2026, 6, 1),
                    amount: Money.dollars(2_000),
                    treatment: .income
                ),
                entry(
                    id: "july-income",
                    date: day(2026, 7, 1),
                    amount: Money.dollars(2_100),
                    treatment: .income
                )
            ],
            monthsBack: 3,
            now: day(2026, 8, 4),
            calendar: calendar
        )

        let aggregate = try #require(
            SpendingHistoryBuilder.aggregate(months: months)
        )
        #expect(aggregate.month == day(2026, 8, 1))
        #expect(aggregate.incomeMilliunits == Money.dollars(4_100).milliunits)
        #expect(aggregate.totalMilliunits == Money.dollars(100).milliunits)
        #expect(
            aggregate.ordinaryTotalMilliunits
                == Money.dollars(60).milliunits
        )

        let food = try #require(aggregate.groups.first { $0.id == "g:food" })
        #expect(food.spentMilliunits == Money.dollars(60).milliunits)
        #expect(food.categories.count == 2)
        let dining = try #require(
            food.categories.first { $0.id == "c:dining" }
        )
        #expect(dining.transactionIds == ["june-dining", "august-dining"])
        #expect(
            dining.lineAmountsByTransactionId["june-dining"]
                == Money.dollars(-10).milliunits
        )

        let investing = try #require(
            aggregate.groups.first { $0.id == "g:investing" }
        )
        #expect(investing.reportingRole == .investment)
        #expect(investing.spentMilliunits == Money.dollars(40).milliunits)
    }

    @Test func aggregatingNoMonthsReturnsNil() {
        #expect(SpendingHistoryBuilder.aggregate(months: []) == nil)
    }

    @Test func aggregateRefundsOffsetEarlierSpendingInTheSameGroup() throws {
        let months = SpendingHistoryBuilder.build(
            entries: [
                entry(
                    date: day(2026, 7, 2),
                    amount: Money.dollars(-100)
                ),
                entry(
                    date: day(2026, 8, 2),
                    amount: Money.dollars(40),
                    treatment: .refund
                )
            ],
            monthsBack: 2,
            now: day(2026, 8, 4),
            calendar: calendar
        )

        let aggregate = try #require(
            SpendingHistoryBuilder.aggregate(months: months)
        )
        #expect(aggregate.ordinaryTotalMilliunits == Money.dollars(60).milliunits)
        #expect(
            aggregate.groups.first?.spentMilliunits
                == Money.dollars(60).milliunits
        )
    }

    @Test func fundingDisplayUsesPrecedingIncomeAndCurrentSpending() {
        let months = SpendingHistoryBuilder.build(
            entries: [
                entry(
                    date: day(2026, 7, 31),
                    amount: Money.dollars(Decimal(string: "100.51")!),
                    treatment: .income
                ),
                entry(
                    date: day(2026, 8, 2),
                    amount: Money.dollars(Decimal(string: "-40.49")!)
                ),
                entry(
                    date: day(2026, 8, 3),
                    amount: Money.dollars(200),
                    treatment: .income
                )
            ],
            monthsBack: 2,
            now: day(2026, 8, 4),
            calendar: calendar
        )
        let month = months[1]

        let display = month.fundingDisplay(
            fundedBy: SpendingHistoryBuilder.fundingIncome(
                for: month,
                within: months,
                calendar: calendar
            )
        )
        #expect(display.fundedHeadline == Money.dollars(101))
        #expect(display.usedHeadline == Money.dollars(40))
        #expect(display.remainingHeadline == Money.dollars(61))
        #expect(
            SpendingHistoryBuilder.fundingIncome(
                for: months[0],
                within: months,
                calendar: calendar
            ) == nil
        )
    }

    @Test func fundingDisplayDoesNotInventMissingIncome() {
        let month = SpendingHistoryBuilder.build(
            entries: [],
            monthsBack: 1,
            now: day(2026, 8, 4),
            calendar: calendar
        )[0]

        let display = month.fundingDisplay(fundedBy: nil)
        #expect(display.fundedHeadline == nil)
        #expect(display.remainingHeadline == nil)
    }

}
