import Testing
import Foundation
@testable import Money
@testable import Models
@testable import Projections

@Suite("Recurring expectations")
struct RecurringExpectationsTests {
    private var utc: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "UTC")!
        return value
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func account(_ id: String, balance: Int) -> AccountSnapshot {
        AccountSnapshot(
            id: id, name: id, kind: .checking,
            balance: Money.dollars(integer: balance),
            clearedBalance: Money.dollars(integer: balance),
            unclearedBalance: .zero, onBudget: true,
            closed: false, deleted: false
        )
    }

    private func expectation(
        id: String = "rent",
        treatment: ForecastTreatment = .ordinarySpending,
        amount: Money = Money.dollars(-1_500),
        next: Date,
        cadence: CommitmentCadence = .monthly,
        payee: String = "Landlord",
        destination: String? = nil
    ) -> RecurringExpectation {
        RecurringExpectation(
            id: id,
            accountId: "checking",
            destinationAccountId: destination,
            payeeName: payee,
            treatment: treatment,
            cadence: cadence,
            nextOccurrence: next,
            amount: amount
        )
    }

    private func historical(
        id: String,
        date: Date,
        amount: Money,
        payee: String,
        accountId: String = "checking",
        treatment: ForecastTreatment? = .ordinarySpending
    ) -> TransactionSummary {
        TransactionSummary(
            id: id,
            accountId: accountId,
            date: date,
            amount: amount,
            cleared: true,
            approved: true,
            payeeName: payee,
            categoryName: nil,
            forecastTreatment: treatment,
            memo: nil,
            deleted: false
        )
    }

    // MARK: - Occurrence math

    @Test func advanceCoversEveryCadence() {
        let anchor = date(2026, 1, 31)
        #expect(RecurringExpectations.advance(anchor, cadence: .weekly, calendar: utc)
            == date(2026, 2, 7))
        #expect(RecurringExpectations.advance(anchor, cadence: .biweekly, calendar: utc)
            == date(2026, 2, 14))
        // Semimonthly pairs days of month (day-15/day pairs), never a
        // drifting 15-day interval.
        #expect(RecurringExpectations.advance(anchor, cadence: .semimonthly, calendar: utc)
            == date(2026, 2, 16))
        // Month-end anchors clamp instead of overflowing.
        #expect(RecurringExpectations.advance(anchor, cadence: .monthly, calendar: utc)
            == date(2026, 2, 28))
        #expect(RecurringExpectations.advance(anchor, cadence: .quarterly, calendar: utc)
            == date(2026, 4, 30))
        #expect(RecurringExpectations.advance(anchor, cadence: .annual, calendar: utc)
            == date(2027, 1, 31))
    }

    @Test func semimonthlyNeverDriftsAcrossAYear() {
        // A 1st/16th schedule advanced 24 times lands exactly one year out.
        var cursor = date(2026, 1, 1)
        for _ in 0..<24 {
            cursor = RecurringExpectations.advance(
                cursor, cadence: .semimonthly, calendar: utc
            )
        }
        #expect(cursor == date(2027, 1, 1))
    }

    // MARK: - Matching

    @Test func occurrenceMatchRequiresIdentityAndBoundedWindow() {
        let rent = expectation(next: date(2026, 8, 1))
        // Inside the window, same payee/direction/account.
        #expect(RecurringExpectations.matchesNextOccurrence(
            historical(id: "a", date: date(2026, 8, 3),
                       amount: Money.dollars(-1_500), payee: "landlord"),
            expectation: rent, calendar: utc
        ))
        // Outside the bounded date window.
        #expect(!RecurringExpectations.matchesNextOccurrence(
            historical(id: "b", date: date(2026, 8, 16),
                       amount: Money.dollars(-1_500), payee: "Landlord"),
            expectation: rent, calendar: utc
        ))
        // Wrong direction.
        #expect(!RecurringExpectations.matchesNextOccurrence(
            historical(id: "c", date: date(2026, 8, 1),
                       amount: Money.dollars(1_500), payee: "Landlord"),
            expectation: rent, calendar: utc
        ))
        // Wrong payee.
        #expect(!RecurringExpectations.matchesNextOccurrence(
            historical(id: "d", date: date(2026, 8, 1),
                       amount: Money.dollars(-1_500), payee: "Grocer"),
            expectation: rent, calendar: utc
        ))
        // Wrong treatment.
        #expect(!RecurringExpectations.matchesNextOccurrence(
            historical(id: "e", date: date(2026, 8, 1),
                       amount: Money.dollars(-1_500), payee: "Landlord",
                       treatment: .internalTransfer),
            expectation: rent, calendar: utc
        ))
    }

    @Test func matchedHistoricalIdsUsePayeeIdentityNotCategory() {
        let rent = expectation(next: date(2026, 9, 1))
        let matched = RecurringExpectations.matchedHistoricalIds(
            transactions: [
                historical(id: "july", date: date(2026, 7, 1),
                           amount: Money.dollars(-1_500), payee: "Landlord"),
                historical(id: "other", date: date(2026, 7, 8),
                           amount: Money.dollars(-90), payee: "Grocer")
            ],
            expectations: [rent],
            calendar: utc
        )
        #expect(matched == ["july"])
    }

    @Test func occurrenceMatchAllowsPaymentAccountToChange() {
        let rent = expectation(next: date(2026, 8, 1))
        let paidFromSavings = historical(
            id: "rent",
            date: date(2026, 8, 2),
            amount: Money.dollars(-1_500),
            payee: "Landlord",
            accountId: "savings"
        )

        #expect(RecurringExpectations.matchesNextOccurrence(
            paidFromSavings,
            expectation: rent,
            calendar: utc
        ))
    }

    @Test func historicalMatchingClaimsOneActualPerExpectedDate() {
        let rent = expectation(next: date(2026, 9, 1))
        let matched = RecurringExpectations.matchedHistoricalIds(
            transactions: [
                historical(
                    id: "july-rent",
                    date: date(2026, 7, 2),
                    amount: Money.dollars(-1_500),
                    payee: "Landlord",
                    accountId: "savings"
                ),
                historical(
                    id: "july-other",
                    date: date(2026, 7, 2),
                    amount: Money.dollars(-250),
                    payee: "Landlord",
                    accountId: "checking"
                ),
                historical(
                    id: "august-rent",
                    date: date(2026, 8, 1),
                    amount: Money.dollars(-1_500),
                    payee: "Landlord",
                    accountId: "credit-card"
                )
            ],
            expectations: [rent],
            calendar: utc
        )

        #expect(matched == ["july-rent", "august-rent"])
    }

    @Test func shiftedMonthlyPaymentsWinOverTinySamePayeeFees() {
        let bill = expectation(
            id: "loan",
            amount: Money.dollars(-2_040),
            next: date(2026, 8, 19),
            payee: "Loan Servicer"
        )
        let realDates = [
            date(2025, 8, 29), date(2025, 10, 1),
            date(2025, 10, 31), date(2025, 12, 1),
            date(2025, 12, 31), date(2026, 1, 30),
            date(2026, 2, 27), date(2026, 4, 1),
            date(2026, 5, 1), date(2026, 5, 18),
            date(2026, 6, 18), date(2026, 7, 20)
        ]
        var history = realDates.enumerated().map { index, paymentDate in
            historical(
                id: "payment-\(index)", date: paymentDate,
                amount: Money.dollars(-1_995), payee: "Loan Servicer"
            )
        }
        history.append(historical(
            id: "fee", date: date(2025, 11, 25),
            amount: Money.dollars(-5), payee: "Loan Servicer"
        ))

        let matched = RecurringExpectations.matchedHistoricalIds(
            transactions: history,
            expectations: [bill],
            calendar: utc
        )

        #expect(matched.count == 12)
        #expect(!matched.contains("fee"))
        #expect(matched == Set(realDates.indices.map { "payment-\($0)" }))
    }

    @Test func occurrenceMatchAllowsVariableBillsButRejectsTinyFees() {
        let bill = expectation(
            amount: Money.dollars(-4_000),
            next: date(2026, 8, 1)
        )
        #expect(RecurringExpectations.matchesNextOccurrence(
            historical(
                id: "variable", date: date(2026, 8, 1),
                amount: Money.dollars(-2_700), payee: "Landlord"
            ),
            expectation: bill,
            calendar: utc
        ))
        #expect(!RecurringExpectations.matchesNextOccurrence(
            historical(
                id: "fee", date: date(2026, 8, 1),
                amount: Money.dollars(-5), payee: "Landlord"
            ),
            expectation: bill,
            calendar: utc
        ))
    }

    // MARK: - Exactly-once through the projector

    /// Mirrors the app's integration: every expectation summary is
    /// estimate-exempt, and matched historical actuals are excluded by id.
    private func project(
        history: [TransactionSummary],
        expectations: [RecurringExpectation],
        today: Date,
        horizonDays: Int = 40
    ) -> CashPositionProjector.Result {
        let summaries = expectations.map { $0.toScheduledSummary() }
        let matched = RecurringExpectations.matchedHistoricalIds(
            transactions: history,
            expectations: expectations,
            calendar: utc
        )
        return CashPositionProjector(calendar: utc).project(
            cashAccounts: [account("checking", balance: 10_000)],
            selectedCashAccountIds: ["checking"],
            cardAccountIds: [], fundedCardAccountIds: [],
            cardPayments: [],
            scheduled: summaries,
            estimateExemptScheduledIds: Set(summaries.map(\.id)),
            historicalTransactions: history,
            excludedTransactionIds: matched,
            recurringMatchedTransactionIds: matched,
            spendAccountIds: ["checking"],
            lookbackDays: 200,
            asOf: today, horizonDays: horizonDays
        )
    }

    /// A dated rent expectation must appear exactly once as a scheduled
    /// event AND remove the matched actuals — at their REAL amounts — from
    /// the ordinary-spending estimate. Unmatched spending is untouched.
    @Test func cashBillIsCountedExactlyOnce() {
        let today = date(2026, 8, 1)
        var history: [TransactionSummary] = []
        for month in 2...7 {
            // Actual rent differs from the expected amount: replacement
            // semantics remove the full $1,600 actuals, not $1,500.
            history.append(historical(
                id: "rent-\(month)", date: date(2026, month, 1),
                amount: Money.dollars(-1_600), payee: "Landlord"
            ))
            history.append(historical(
                id: "misc-\(month)", date: date(2026, month, 10),
                amount: Money.dollars(-300), payee: "Grocer"
            ))
        }
        let rent = expectation(next: date(2026, 8, 5))
        let baseline = project(
            history: history, expectations: [], today: today,
            horizonDays: 20
        )
        let withRent = project(
            history: history, expectations: [rent], today: today,
            horizonDays: 20
        )

        // The dated occurrence appears exactly once, on its date.
        let rentEvents = withRent.events.filter {
            $0.title == "Landlord" && $0.kind == .scheduledExpense
        }
        #expect(rentEvents.count == 1)
        #expect(rentEvents.first?.date == date(2026, 8, 5))
        #expect(rentEvents.first?.amount == Money.dollars(-1_500))
        // The estimate reserves ONLY the unmatched $300/month groceries.
        #expect(withRent.expectedSpend.dailyAmount
            < baseline.expectedSpend.dailyAmount)
        #expect(withRent.expectedSpend.unscheduledMonthlyAmount
            == Money.dollars(300))
        #expect(withRent.expectedSpend.estimatedMonthlyAmount
            == Money.dollars(1_900))
        #expect(withRent.expectedSpend.scheduledMonthlyAmount
            == Money.dollars(1_600))
        #expect(withRent.expectedSpend.scheduledOutflows
            == Money.dollars(9_600))
        #expect(withRent.expectedSpend.monthlySamples.allSatisfy {
            $0.totalAmount == Money.dollars(1_900)
                && $0.scheduledAmount == Money.dollars(1_600)
                && $0.unscheduledAmount == Money.dollars(300)
        })
        #expect(withRent.expectedSpend.monthlySamples
            .flatMap(\.categories)
            .flatMap(\.transactions)
            .filter(\.recurring)
            .count == 5)
    }

    /// A brand-new expectation with no matching history must not reduce the
    /// estimate at all: theoretical past occurrences are never invented.
    @Test func newExpectationWithoutHistoryLeavesEstimateUntouched() {
        let today = date(2026, 8, 1)
        let history = (2...7).map { month in
            historical(
                id: "groceries-\(month)", date: date(2026, month, 10),
                amount: Money.dollars(-500), payee: "Grocer"
            )
        }
        let newBill = expectation(
            id: "new-bill",
            amount: Money.dollars(-1_000),
            next: date(2026, 8, 15),
            payee: "New Gym"
        )
        let baseline = project(
            history: history, expectations: [], today: today
        )
        let withBill = project(
            history: history, expectations: [newBill], today: today
        )

        #expect(withBill.events.contains {
            $0.title == "New Gym" && $0.amount == Money.dollars(-1_000)
        })
        // Groceries reserve is fully preserved.
        #expect(withBill.expectedSpend.dailyAmount
            == baseline.expectedSpend.dailyAmount)
    }

    @Test func incomeExpectationAppearsAsDatedInflowWithoutTouchingEstimate() {
        let today = date(2026, 8, 1)
        let history = (2...7).map { month in
            historical(
                id: "misc-\(month)", date: date(2026, month, 10),
                amount: Money.dollars(-400), payee: "Grocer"
            )
        }
        let paycheck = expectation(
            id: "paycheck",
            treatment: .income,
            amount: Money.dollars(3_000),
            next: date(2026, 8, 15),
            cadence: .biweekly,
            payee: "Employer"
        )
        let baseline = project(
            history: history, expectations: [], today: today
        )
        let withIncome = project(
            history: history, expectations: [paycheck], today: today
        )
        #expect(withIncome.events.contains {
            $0.kind == .scheduledIncome
                && $0.amount == Money.dollars(3_000)
                && $0.date == date(2026, 8, 15)
        })
        #expect(withIncome.expectedSpend.dailyAmount
            == baseline.expectedSpend.dailyAmount)
    }

    /// Investment contributions and transfers exist as dated events only —
    /// their actuals never enter projection history, so the estimate must
    /// be identical with or without them.
    @Test func exemptExpectationsNeverReduceTheSpendEstimate() {
        let today = date(2026, 8, 1)
        let history = (2...7).map { month in
            historical(
                id: "misc-\(month)", date: date(2026, month, 10),
                amount: Money.dollars(-300), payee: "Grocer"
            )
        }
        let contribution = expectation(
            id: "vanguard",
            treatment: .investmentContribution,
            amount: Money.dollars(-1_000),
            next: date(2026, 8, 15),
            payee: "Vanguard"
        )
        let summary = contribution.toScheduledSummary()
        let projector = CashPositionProjector(calendar: utc)

        func project(
            scheduled: [ScheduledTransactionSummary],
            exempt: Set<String>
        ) -> CashPositionProjector.Result {
            projector.project(
                cashAccounts: [account("checking", balance: 10_000)],
                selectedCashAccountIds: ["checking"],
                cardAccountIds: [], fundedCardAccountIds: [],
                cardPayments: [],
                scheduled: scheduled,
                estimateExemptScheduledIds: exempt,
                historicalTransactions: history,
                spendAccountIds: ["checking"],
                lookbackDays: 200,
                asOf: today, horizonDays: 40
            )
        }

        let baseline = project(scheduled: [], exempt: [])
        let withContribution = project(
            scheduled: [summary], exempt: [summary.id]
        )

        #expect(withContribution.events.contains {
            $0.title == "Vanguard" && $0.amount == Money.dollars(-1_000)
        })
        #expect(withContribution.expectedSpend.dailyAmount
            == baseline.expectedSpend.dailyAmount)
    }

    /// Transfers between two included cash accounts move money without
    /// changing aggregate cash: no pool event.
    @Test func poolInternalTransfersNetOut() {
        let today = date(2026, 8, 1)
        let transfer = expectation(
            id: "topup",
            treatment: .internalTransfer,
            amount: Money.dollars(-500),
            next: date(2026, 8, 10),
            payee: "Savings top-up",
            destination: "savings"
        )
        let result = CashPositionProjector(calendar: utc).project(
            cashAccounts: [
                account("checking", balance: 5_000),
                account("savings", balance: 2_000)
            ],
            selectedCashAccountIds: ["checking", "savings"],
            cardAccountIds: [], fundedCardAccountIds: [],
            cardPayments: [],
            scheduled: [transfer.toScheduledSummary()],
            estimateExemptScheduledIds: ["expectation:topup"],
            historicalTransactions: [],
            spendAccountIds: ["checking", "savings"],
            asOf: today, horizonDays: 30
        )
        #expect(result.events.isEmpty)
        #expect(result.projectedEndingBalance == Money.dollars(7_000))
    }
}
