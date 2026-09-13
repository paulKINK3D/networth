import Testing
import Foundation
@testable import Money
@testable import Models
@testable import Projections

@Suite("Spending Room breakdown")
struct SpendingRoomBreakdownTests {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        let c = utc
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        return c.date(from: comps)!
    }

    private func estimate(
        amount: Money = Money.dollars(6971),
        low: Money = Money.dollars(10621),
        buffer: Money = Money.dollars(2500),
        reserve: Money = Money.dollars(1150),
        starting: Money = Money.dollars(23026),
        inflows: Money = Money.dollars(8322),
        scheduled: Money = Money.dollars(5645),
        cards: Money = Money.dollars(8615),
        everyday: Money = Money.dollars(6467)
    ) -> SafeToSpendEstimate {
        SafeToSpendEstimate(
            amount: amount,
            lowPointDate: date(2026, 10, 8),
            projectedLowBalance: low,
            minimumCashBuffer: buffer,
            spendingReserve: reserve,
            startingBalance: starting,
            knownInflows: inflows,
            scheduledOutflows: scheduled,
            cardPaymentOutflows: cards,
            expectedSpendingReserve: everyday,
            contributingEvents: []
        )
    }

    // MARK: Ledger

    @Test func ledgerEntriesWalkFromStartToLow() {
        let entries = SpendingRoomLedger.cashFlowEntries(from: estimate())
        #expect(entries.map(\.kind) == [
            .startingCash, .inflows, .bills, .cardAutopays,
            .everydaySpending, .projectedLow
        ])
        let inflow = entries[1]
        #expect(inflow.amount == Money.dollars(8322))
        #expect(inflow.barStart == Money.dollars(23026))
        #expect(inflow.barEnd == Money.dollars(31348))
        let bills = entries[2]
        #expect(bills.amount == Money.dollars(-5645))
        #expect(bills.barStart == Money.dollars(25703))
        #expect(bills.barEnd == Money.dollars(31348))
        let everyday = entries[4]
        #expect(everyday.amount == Money.dollars(-6467))
        #expect(everyday.barStart == Money.dollars(10621))
        #expect(everyday.barEnd == Money.dollars(17088))
        let low = entries[5]
        #expect(low.isLevel)
        #expect(low.barStart == .zero)
        #expect(low.barEnd == Money.dollars(10621))
    }

    @Test func ledgerOmitsZeroMovements() {
        let entries = SpendingRoomLedger.cashFlowEntries(
            from: estimate(inflows: .zero, cards: .zero)
        )
        #expect(entries.map(\.kind) == [
            .startingCash, .bills, .everydaySpending, .projectedLow
        ])
    }

    @Test func spendableMapsProtectionAndRoom() {
        let spendable = SpendingRoomLedger.spendable(from: estimate())
        #expect(spendable.cashBuffer == Money.dollars(2500))
        #expect(spendable.reserves == Money.dollars(1150))
        #expect(spendable.room == Money.dollars(6971))
        #expect(spendable.isCovered)
    }

    @Test func spendableReportsGapWhenLowFallsShort() {
        let spendable = SpendingRoomLedger.spendable(from: estimate(
            amount: .zero,
            low: Money.dollars(2000),
            buffer: Money.dollars(2500),
            reserve: Money.dollars(1150)
        ))
        #expect(!spendable.isCovered)
        #expect(spendable.protectedCashGap == Money.dollars(1650))
        #expect(spendable.room == .zero)
    }

    // MARK: Drivers

    private func sample(
        month: Date,
        categories: [MonthlySpendCategory]
    ) -> MonthlySpendSample {
        MonthlySpendSample(
            month: month,
            totalAmount: categories.map(\.amount).sum(),
            scheduledAmount: .zero,
            unscheduledAmount: categories.map(\.amount).sum(),
            categories: categories
        )
    }

    private func line(
        _ id: String,
        _ amount: Money,
        excluded: Bool = false,
        recurring: Bool = false
    ) -> MonthlySpendTransaction {
        MonthlySpendTransaction(
            id: id,
            date: date(2026, 6, 15),
            payeeName: "Payee \(id)",
            amount: amount,
            excluded: excluded,
            recurring: recurring
        )
    }

    @Test func groupAveragesSumAcrossMonthsAndRankDescending() {
        let june = sample(month: date(2026, 6, 1), categories: [
            MonthlySpendCategory(
                categoryId: "groceries",
                categoryName: "Groceries",
                amount: Money.dollars(900),
                transactions: [line("g1", Money.dollars(900))]
            ),
            MonthlySpendCategory(
                categoryId: "dining",
                categoryName: "Dining",
                amount: Money.dollars(300),
                transactions: [line("d1", Money.dollars(300))]
            )
        ])
        let july = sample(month: date(2026, 7, 1), categories: [
            MonthlySpendCategory(
                categoryId: "groceries",
                categoryName: "Groceries",
                amount: Money.dollars(700),
                transactions: [line("g2", Money.dollars(700))]
            ),
            MonthlySpendCategory(
                categoryId: "toys",
                categoryName: "Toys",
                amount: Money.dollars(100),
                transactions: [line("t1", Money.dollars(100))]
            )
        ])
        let groups = SpendingRoomDrivers.groupAverages(
            samples: [june, july],
            groupIdForCategory: { id in
                ["groceries": "food", "dining": "food"][id]
            },
            nameForGroup: { _ in "Food" }
        )
        #expect(groups.count == 2)
        #expect(groups[0].name == "Food")
        // (900 + 300 + 700) / 2 months
        #expect(groups[0].monthlyAverage == Money.dollars(950))
        #expect(groups[1].name == "Everything else")
        #expect(groups[1].monthlyAverage == Money.dollars(50))
    }

    @Test func groupAveragesIgnoreRecurringAndExcludedAndNetRefunds() {
        let june = sample(month: date(2026, 6, 1), categories: [
            MonthlySpendCategory(
                categoryId: "groceries",
                categoryName: "Groceries",
                amount: Money.dollars(900),
                transactions: [
                    line("keep", Money.dollars(500)),
                    line("skip-recurring", Money.dollars(300), recurring: true),
                    line("skip-excluded", Money.dollars(200), excluded: true),
                    line("refund", Money.dollars(-100))
                ]
            )
        ])
        let groups = SpendingRoomDrivers.groupAverages(
            samples: [june],
            groupIdForCategory: { _ in "food" },
            nameForGroup: { _ in "Food" }
        )
        #expect(groups.count == 1)
        #expect(groups[0].monthlyAverage == Money.dollars(400))
    }

    @Test func categoryAveragesRankWithinOneGroup() {
        let june = sample(month: date(2026, 6, 1), categories: [
            MonthlySpendCategory(
                categoryId: "groceries",
                categoryName: "Groceries",
                amount: Money.dollars(900),
                transactions: [
                    line("keep", Money.dollars(500)),
                    line("skip-recurring", Money.dollars(300), recurring: true),
                    line("excluded", Money.dollars(200), excluded: true)
                ]
            ),
            MonthlySpendCategory(
                categoryId: "dining",
                categoryName: "Dining",
                amount: Money.dollars(150),
                transactions: [line("d1", Money.dollars(150))]
            ),
            MonthlySpendCategory(
                categoryId: "toys",
                categoryName: "Toys",
                amount: Money.dollars(80),
                transactions: [line("t1", Money.dollars(80))]
            )
        ])
        let july = sample(month: date(2026, 7, 1), categories: [
            MonthlySpendCategory(
                categoryId: "groceries",
                categoryName: "Groceries",
                amount: Money.dollars(300),
                transactions: [line("g2", Money.dollars(300))]
            )
        ])
        let categories = SpendingRoomDrivers.categoryAverages(
            groupId: "food",
            samples: [june, july],
            groupIdForCategory: { id in
                ["groceries": "food", "dining": "food"][id]
            }
        )
        #expect(categories.map(\.name) == ["Groceries", "Dining"])
        // (500 + 300) / 2 months; recurring and excluded lines stay out.
        #expect(categories[0].monthlyAverage == Money.dollars(400))
        #expect(categories[1].monthlyAverage == Money.dollars(75))
    }

    @Test func payeeSummariesSumOneLinePerPayee() {
        let june = sample(month: date(2026, 6, 1), categories: [
            MonthlySpendCategory(
                categoryId: "groceries",
                categoryName: "Groceries",
                amount: Money.dollars(700),
                transactions: [
                    line("a1", Money.dollars(400)),
                    line("b1", Money.dollars(300))
                ]
            )
        ])
        let july = sample(month: date(2026, 7, 1), categories: [
            MonthlySpendCategory(
                categoryId: "groceries",
                categoryName: "Groceries",
                amount: Money.dollars(500),
                transactions: [
                    MonthlySpendTransaction(
                        id: "a2",
                        date: date(2026, 7, 10),
                        payeeName: "Payee a1",
                        amount: Money.dollars(200),
                        excluded: false
                    ),
                    MonthlySpendTransaction(
                        id: "a3",
                        date: date(2026, 7, 20),
                        payeeName: "Payee a1",
                        amount: Money.dollars(100),
                        excluded: true
                    ),
                    line("skip", Money.dollars(50), recurring: true)
                ]
            )
        ])
        let payees = SpendingRoomDrivers.payeeSummaries(
            categoryId: "groceries",
            samples: [june, july]
        )
        #expect(payees.map(\.name) == ["Payee a1", "Payee b1"])
        // (400 + 200) / 2 months; the excluded line stays out of the average
        // but remains listed, newest first.
        #expect(payees[0].monthlyAverage == Money.dollars(300))
        #expect(payees[0].purchaseCount == 2)
        #expect(payees[0].transactions.map(\.id) == ["a3", "a2", "a1"])
        #expect(payees[1].monthlyAverage == Money.dollars(150))
    }

    @Test func currentMonthTotalSumsPartialMonthLines() {
        let september = sample(month: date(2026, 9, 1), categories: [
            MonthlySpendCategory(
                categoryId: "groceries",
                categoryName: "Groceries",
                amount: Money.dollars(220),
                transactions: [
                    line("m1", Money.dollars(150)),
                    line("m2", Money.dollars(70)),
                    line("skip", Money.dollars(40), recurring: true),
                    line("out", Money.dollars(30), excluded: true)
                ]
            )
        ])
        #expect(SpendingRoomDrivers.currentMonthTotal(
            categoryId: "groceries",
            currentMonth: september
        ) == Money.dollars(220))
        #expect(SpendingRoomDrivers.currentMonthTotal(
            categoryId: "dining",
            currentMonth: september
        ) == .zero)
        #expect(SpendingRoomDrivers.currentMonthTotal(
            categoryId: "groceries",
            currentMonth: nil
        ) == .zero)
    }

    @Test func projectorExposesPartialCurrentMonthOutsideAverages() {
        func spend(_ id: String, _ day: (Int, Int), _ dollars: Int) -> TransactionSummary {
            TransactionSummary(
                id: id,
                accountId: "checking",
                date: date(2026, day.0, day.1),
                amount: Money.dollars(integer: -dollars),
                cleared: true,
                approved: true,
                payeeName: "Payee \(id)",
                categoryId: "groceries",
                categoryName: "Groceries",
                memo: nil,
                deleted: false
            )
        }
        let checking = AccountSnapshot(
            id: "checking", name: "Checking", kind: .checking,
            balance: Money.dollars(5000),
            clearedBalance: Money.dollars(5000),
            unclearedBalance: .zero,
            onBudget: true, closed: false, deleted: false
        )
        let result = CashPositionProjector(calendar: utc).project(
            cashAccounts: [checking],
            selectedCashAccountIds: ["checking"],
            cardAccountIds: [],
            fundedCardAccountIds: [],
            cardPayments: [],
            scheduled: [],
            historicalTransactions: [
                spend("jun", (6, 5), 500),
                spend("jul", (7, 10), 400),
                spend("aug", (8, 12), 600),
                spend("sep", (9, 5), 250)
            ],
            asOf: date(2026, 9, 12)
        )
        // July and August are the complete sampled months; September stays
        // out of the averages but surfaces as the partial current month.
        #expect(result.expectedSpend.sampleMonthCount == 2)
        #expect(
            result.expectedSpend.monthlySamples.map(\.month)
                == [date(2026, 7, 1), date(2026, 8, 1)]
        )
        let current = try! #require(result.expectedSpend.currentMonth)
        #expect(current.month == date(2026, 9, 1))
        #expect(SpendingRoomDrivers.currentMonthTotal(
            categoryId: "groceries",
            currentMonth: current
        ) == Money.dollars(250))
    }

    // MARK: Card cycle

    private func payment(
        card: String,
        close: Date,
        due: Date,
        amount: Money,
        basis: CardPaymentEstimateBasis
    ) -> UpcomingCardPayment {
        UpcomingCardPayment(
            cardAccountId: card,
            paymentAccountId: "checking",
            cardName: card,
            closeDate: close,
            dueDate: due,
            amount: amount,
            basis: basis
        )
    }

    @Test func cycleSummarizesClosedOpenAndNextPayments() {
        let payments = [
            payment(
                card: "visa",
                close: date(2026, 8, 28),
                due: date(2026, 10, 4),
                amount: Money.dollars(5907),
                basis: .closedStatementEstimate
            ),
            payment(
                card: "amex",
                close: date(2026, 9, 5),
                due: date(2026, 9, 23),
                amount: Money.dollars(1044),
                basis: .closedStatementEstimate
            ),
            payment(
                card: "visa",
                close: date(2026, 9, 28),
                due: date(2026, 11, 4),
                amount: Money.dollars(2100),
                basis: .futureScheduledOnly
            ),
            // A second simulated cycle for the same card must not count.
            payment(
                card: "visa",
                close: date(2026, 10, 28),
                due: date(2026, 12, 4),
                amount: Money.dollars(900),
                basis: .futureScheduledOnly
            ),
            payment(
                card: "amex",
                close: date(2026, 10, 5),
                due: date(2026, 10, 23),
                amount: Money.dollars(400),
                basis: .futureScheduledOnly
            )
        ]
        let summary = SpendingRoomCardCycle.summarize(
            payments: payments,
            openChargesByCardId: [
                "visa": Money.dollars(1800),
                "amex": Money.dollars(600)
            ],
            asOf: date(2026, 9, 12),
            calendar: utc
        )
        let s = try! #require(summary)
        #expect(s.closedTotal == Money.dollars(6951))
        #expect(s.closedCount == 2)
        #expect(s.closedLatestDueDate == date(2026, 10, 4))
        #expect(s.openChargesSoFar == Money.dollars(2400))
        #expect(s.openEarliestCloseDate == date(2026, 9, 28))
        #expect(s.openLatestCloseDate == date(2026, 10, 5))
        #expect(s.nextPaymentsTotal == Money.dollars(2500))
        #expect(s.nextPaymentsCount == 2)
        #expect(s.nextPaymentsLatestDueDate == date(2026, 11, 4))
        // visa: 15 elapsed of 31; amex: 7 elapsed of 30.
        let fraction = try! #require(s.cycleElapsedFraction)
        #expect(abs(fraction - ((15.0 / 31.0) + (7.0 / 30.0)) / 2) < 0.001)
    }

    @Test func cycleReturnsNilWithoutPayments() {
        #expect(SpendingRoomCardCycle.summarize(
            payments: [],
            openChargesByCardId: [:],
            asOf: date(2026, 9, 12),
            calendar: utc
        ) == nil)
    }
}
