import Testing
import Foundation
@testable import Money
@testable import Models
@testable import Projections

@Suite("Cash position projector")
struct CashPositionProjectorTests {
    private var utc: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "UTC")!
        return value
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func account(_ id: String, balance: Int, onBudget: Bool = true) -> AccountSnapshot {
        AccountSnapshot(
            id: id, name: id, kind: .checking,
            balance: Money.dollars(integer: balance),
            clearedBalance: Money.dollars(integer: balance),
            unclearedBalance: .zero, onBudget: onBudget,
            closed: false, deleted: false
        )
    }

    @Test func knownEventsIncludeCardPaymentExactlyOnce() {
        let today = date(2026, 1, 1)
        let bill = ScheduledTransactionSummary(
            id: "bill", accountId: "checking", firstDate: date(2026, 1, 3),
            nextDate: date(2026, 1, 3), frequency: .never,
            amount: Money.dollars(-200), payeeName: "Rent"
        )
        let paycheck = ScheduledTransactionSummary(
            id: "pay", accountId: "checking", firstDate: date(2026, 1, 5),
            nextDate: date(2026, 1, 5), frequency: .never,
            amount: Money.dollars(500), payeeName: "Paycheck"
        )
        let payment = UpcomingCardPayment(
            cardAccountId: "visa", paymentAccountId: "checking", cardName: "Visa",
            closeDate: date(2025, 12, 20), dueDate: date(2026, 1, 4),
            amount: Money.dollars(300), basis: .closedStatementEstimate
        )
        let result = CashPositionProjector(calendar: utc).project(
            cashAccounts: [account("checking", balance: 1_000)],
            selectedCashAccountIds: ["checking"],
            cardAccountIds: ["visa"], fundedCardAccountIds: ["visa"],
            cardPayments: [payment], scheduled: [bill, paycheck],
            historicalTransactions: [], spendAccountIds: ["checking", "visa"],
            asOf: today, horizonDays: 10, minimumCashBuffer: Money.dollars(400)
        )
        #expect(result.events.count == 3)
        #expect(result.events.filter { $0.kind == .cardPayment }.count == 1)
        #expect(result.knownLowPoint?.balance == Money.dollars(500))
        #expect(result.status == .covered)
        #expect(result.knownInflows == Money.dollars(500))
        #expect(result.scheduledOutflows == Money.dollars(200))
        #expect(result.cardPaymentOutflows == Money.dollars(300))
        #expect(result.expectedSpendingReserve == .zero)
        #expect(result.projectedEndingBalance == Money.dollars(1_000))
    }

    @Test func transfersCrossingSelectedPoolAreSignedAndInternalTransfersNetOut() {
        let today = date(2026, 1, 1)
        let out = ScheduledTransactionSummary(
            id: "out", accountId: "checking", nextDate: date(2026, 1, 2),
            frequency: .never, amount: Money.dollars(-200), transferAccountId: "reserve"
        )
        let incoming = ScheduledTransactionSummary(
            id: "in", accountId: "reserve", nextDate: date(2026, 1, 3),
            frequency: .never, amount: Money.dollars(-300), transferAccountId: "checking"
        )
        let internalMove = ScheduledTransactionSummary(
            id: "internal", accountId: "checking", nextDate: date(2026, 1, 4),
            frequency: .never, amount: Money.dollars(-50), transferAccountId: "savings"
        )
        let result = CashPositionProjector(calendar: utc).project(
            cashAccounts: [account("checking", balance: 1_000), account("reserve", balance: 500), account("savings", balance: 100)],
            selectedCashAccountIds: ["checking", "savings"],
            cardAccountIds: [], fundedCardAccountIds: [], cardPayments: [],
            scheduled: [out, incoming, internalMove], historicalTransactions: [],
            spendAccountIds: ["checking", "reserve", "savings"],
            asOf: today, horizonDays: 5
        )
        #expect(result.events.map(\.amount) == [Money.dollars(-200), Money.dollars(300)])
        #expect(result.knownPoints.last?.balance == Money.dollars(1_200))
        #expect(result.accountProjections.first { $0.accountId == "checking" }?.lowPoint.balance == Money.dollars(800))
        #expect(result.accountProjections.first { $0.accountId == "savings" }?.lowPoint.balance == Money.dollars(100))
        #expect(result.accountProjections.first { $0.accountId == "savings" }?.points.last?.balance == Money.dollars(150))
    }

    @Test func cardPaymentAccountShortfallIsNotHiddenBySavings() {
        let today = date(2026, 1, 1)
        let payment = UpcomingCardPayment(
            cardAccountId: "visa", paymentAccountId: "checking", cardName: "Visa",
            closeDate: date(2025, 12, 20), dueDate: date(2026, 1, 4),
            amount: Money.dollars(800), basis: .closedStatementEstimate
        )
        let result = CashPositionProjector(calendar: utc).project(
            cashAccounts: [account("checking", balance: 500), account("savings", balance: 5_000)],
            selectedCashAccountIds: ["checking", "savings"],
            cardAccountIds: ["visa"], fundedCardAccountIds: ["visa"],
            cardPayments: [payment], scheduled: [], historicalTransactions: [],
            asOf: today, horizonDays: 5
        )

        #expect(result.status == .covered)
        #expect(result.knownLowPoint?.balance == Money.dollars(4_700))
        #expect(result.accountShortfalls.count == 1)
        #expect(result.accountShortfalls.first?.accountId == "checking")
        #expect(result.accountShortfalls.first?.firstShortfallPoint?.date == date(2026, 1, 4))
        #expect(result.accountShortfalls.first?.lowPoint.balance == Money.dollars(-300))
        #expect(result.accountShortfalls.first?.fundingNeeded == Money.dollars(300))
        #expect(result.accountShortfalls.first?.lowPointEvent?.kind == .cardPayment)
        #expect(result.accountShortfalls.first?.fundsCardPayments == true)
        #expect(result.paymentAccountShortfalls.first?.accountId == "checking")
    }

    @Test func paymentAccountRiskIsIdentifiedSeparatelyFromOtherAccountShortfalls() {
        let today = date(2026, 1, 1)
        let earlyBill = ScheduledTransactionSummary(
            id: "early", accountId: "spending", nextDate: date(2026, 1, 2),
            frequency: .never, amount: Money.dollars(-200), payeeName: "Bill"
        )
        let payment = UpcomingCardPayment(
            cardAccountId: "visa", paymentAccountId: "checking", cardName: "Visa",
            closeDate: date(2025, 12, 20), dueDate: date(2026, 1, 4),
            amount: Money.dollars(800), basis: .closedStatementEstimate
        )
        let result = CashPositionProjector(calendar: utc).project(
            cashAccounts: [
                account("spending", balance: 100),
                account("checking", balance: 500),
                account("savings", balance: 5_000)
            ],
            selectedCashAccountIds: ["spending", "checking", "savings"],
            cardAccountIds: ["visa"], fundedCardAccountIds: ["visa"],
            cardPayments: [payment], scheduled: [earlyBill], historicalTransactions: [],
            asOf: today, horizonDays: 5
        )

        #expect(result.accountShortfalls.first?.accountId == "spending")
        #expect(result.paymentAccountShortfalls.first?.accountId == "checking")
    }

    @Test func untouchedNegativeAccountIsNotAProjectedShortfall() {
        let result = CashPositionProjector(calendar: utc).project(
            cashAccounts: [account("checking", balance: 1_000), account("untouched", balance: -100)],
            selectedCashAccountIds: ["checking", "untouched"],
            cardAccountIds: [], fundedCardAccountIds: [],
            cardPayments: [], scheduled: [], historicalTransactions: [],
            asOf: date(2026, 1, 1), horizonDays: 5
        )

        #expect(result.accountProjections.first { $0.accountId == "untouched" }?.lowPoint.balance == Money.dollars(-100))
        #expect(result.accountShortfalls.isEmpty)
    }

    @Test func fundingNeededUsesFutureDeficitInsteadOfNegativeStartingBalance() {
        let payment = UpcomingCardPayment(
            cardAccountId: "visa", paymentAccountId: "checking", cardName: "Visa",
            closeDate: date(2025, 12, 20), dueDate: date(2026, 1, 4),
            amount: Money.dollars(600), basis: .closedStatementEstimate
        )
        let income = ScheduledTransactionSummary(
            id: "income", accountId: "checking", nextDate: date(2026, 1, 2),
            frequency: .never, amount: Money.dollars(1_000), payeeName: "Income"
        )
        let result = CashPositionProjector(calendar: utc).project(
            cashAccounts: [account("checking", balance: -500)],
            selectedCashAccountIds: ["checking"],
            cardAccountIds: ["visa"], fundedCardAccountIds: ["visa"],
            cardPayments: [payment], scheduled: [income], historicalTransactions: [],
            asOf: date(2026, 1, 1), horizonDays: 5
        )

        #expect(result.paymentAccountShortfalls.first?.firstShortfallPoint?.date == date(2026, 1, 4))
        #expect(result.paymentAccountShortfalls.first?.projectedShortfallLowPoint?.balance == Money.dollars(-100))
        #expect(result.paymentAccountShortfalls.first?.fundingNeeded == Money.dollars(100))
    }

    @Test func internalTransferMustArriveBeforeCardPaymentToResolveAccountRisk() {
        let today = date(2026, 1, 1)
        let payment = UpcomingCardPayment(
            cardAccountId: "visa", paymentAccountId: "checking", cardName: "Visa",
            closeDate: date(2025, 12, 20), dueDate: date(2026, 1, 4),
            amount: Money.dollars(800), basis: .closedStatementEstimate
        )
        func projection(transferDate: Date) -> CashPositionProjector.Result {
            let transfer = ScheduledTransactionSummary(
                id: "fund-checking", accountId: "savings", nextDate: transferDate,
                frequency: .never, amount: Money.dollars(-300),
                transferAccountId: "checking"
            )
            return CashPositionProjector(calendar: utc).project(
                cashAccounts: [account("checking", balance: 500), account("savings", balance: 5_000)],
                selectedCashAccountIds: ["checking", "savings"],
                cardAccountIds: ["visa"], fundedCardAccountIds: ["visa"],
                cardPayments: [payment], scheduled: [transfer], historicalTransactions: [],
                asOf: today, horizonDays: 5
            )
        }

        let fundedBefore = projection(transferDate: date(2026, 1, 3))
        #expect(fundedBefore.accountShortfalls.isEmpty)
        #expect(fundedBefore.events.count == 1)

        let fundedAfter = projection(transferDate: date(2026, 1, 5))
        #expect(fundedAfter.accountShortfalls.first?.accountId == "checking")
        #expect(fundedAfter.accountShortfalls.first?.firstShortfallPoint?.date == date(2026, 1, 4))
    }

    @Test func expectedSpendUsesCashAndFundedCardOutflowsOnly() {
        let today = date(2026, 1, 11)
        let history = [
            transaction("cash", amount: -100, date: date(2026, 1, 1)),
            transaction("visa", amount: -200, date: date(2026, 1, 2)),
            transaction("cash", amount: 900, date: date(2026, 1, 3)),
            transaction("other-card", amount: -700, date: date(2026, 1, 4)),
            transaction("cash", amount: -500, date: date(2026, 1, 5), transfer: "visa")
        ]
        let scheduled = ScheduledTransactionSummary(
            id: "known", accountId: "cash", firstDate: date(2026, 1, 1),
            nextDate: date(2026, 1, 1), frequency: .never,
            amount: Money.dollars(-50)
        )
        let result = CashPositionProjector(calendar: utc).project(
            cashAccounts: [account("cash", balance: 1_000)],
            selectedCashAccountIds: ["cash"],
            cardAccountIds: ["visa", "other-card"], fundedCardAccountIds: ["visa"],
            cardPayments: [], scheduled: [scheduled], historicalTransactions: history,
            spendAccountIds: ["cash", "visa", "other-card"], lookbackDays: 365,
            asOf: today, horizonDays: 2
        )
        #expect(result.expectedSpend.historicalOutflows == Money.dollars(300))
        #expect(result.expectedSpend.scheduledOutflows == Money.dollars(50))
        #expect(result.expectedSpend.historyDays == 10)
        #expect(result.expectedSpend.dailyAmount == Money.dollars(25))
        #expect(result.expectedSpend.sampleMonthCount == 0)
        #expect(result.expectedSpend.estimatedMonthlyAmount == Money(milliunits: 912_500))
        #expect(result.expectedSpend.unscheduledMonthlyAmount == Money(milliunits: 760_416))
        #expect(result.expectedSpend.scheduledMonthlyAmount == Money(milliunits: 152_084))
    }

    @Test func expectedSpendUsesMedianCompleteMonthInsteadOfSpikyAverage() {
        let today = date(2026, 1, 15)
        let history = [
            transaction("cash", amount: -100, date: date(2025, 9, 10)),
            transaction("cash", amount: -100, date: date(2025, 10, 10)),
            transaction("cash", amount: -1_000, date: date(2025, 11, 10)),
            transaction("cash", amount: -100, date: date(2025, 12, 10))
        ]
        let scheduled = ScheduledTransactionSummary(
            id: "monthly-bill", accountId: "cash", firstDate: date(2025, 9, 15),
            nextDate: date(2025, 12, 15), frequency: .monthly,
            amount: Money.dollars(-50), payeeName: "Monthly bill"
        )
        let result = CashPositionProjector(calendar: utc).project(
            cashAccounts: [account("cash", balance: 5_000)],
            selectedCashAccountIds: ["cash"],
            cardAccountIds: [], fundedCardAccountIds: [], cardPayments: [],
            scheduled: [scheduled], historicalTransactions: history,
            spendAccountIds: ["cash"], lookbackDays: 365,
            asOf: today, horizonDays: 2
        )

        #expect(result.expectedSpend.sampleMonthCount == 3)
        #expect(result.expectedSpend.monthlySamples.count == 3)
        #expect(result.expectedSpend.estimatedMonthlyAmount == Money.dollars(100))
        #expect(result.expectedSpend.scheduledMonthlyAmount == Money.dollars(50))
        #expect(result.expectedSpend.unscheduledMonthlyAmount == Money.dollars(50))
        #expect(result.expectedSpend.dailyAmount == Money(milliunits: 1_643))
        #expect(result.expectedSpend.monthlySamples[0].month == date(2025, 10, 1))
        #expect(result.expectedSpend.monthlySamples[0].totalAmount == Money.dollars(100))
        #expect(result.expectedSpend.monthlySamples[0].scheduledAmount == Money.dollars(50))
        #expect(result.expectedSpend.monthlySamples[0].unscheduledAmount == Money.dollars(50))
        #expect(result.expectedSpend.monthlySamples[0].categories.first?.categoryName == "Uncategorized")
        #expect(result.expectedSpend.monthlySamples[0].categories.first?.amount == Money.dollars(100))
    }

    @Test func higherSpendingCaseUsesUpperQuartileWithFourCompleteMonths() {
        let today = date(2026, 2, 15)
        let history = [
            transaction("cash", amount: -100, date: date(2025, 9, 10)),
            transaction("cash", amount: -100, date: date(2025, 10, 10)),
            transaction("cash", amount: -200, date: date(2025, 11, 10)),
            transaction("cash", amount: -300, date: date(2025, 12, 10)),
            transaction("cash", amount: -1_000, date: date(2026, 1, 10))
        ]
        let result = CashPositionProjector(calendar: utc).project(
            cashAccounts: [account("cash", balance: 2_000)],
            selectedCashAccountIds: ["cash"],
            cardAccountIds: [], fundedCardAccountIds: [], cardPayments: [],
            scheduled: [], historicalTransactions: history,
            spendAccountIds: ["cash"], lookbackDays: 365,
            asOf: today, horizonDays: 10, minimumCashBuffer: Money.dollars(500)
        )

        #expect(result.expectedSpend.sampleMonthCount == 4)
        #expect(result.expectedSpend.estimatedMonthlyAmount == Money.dollars(250))
        #expect(result.expectedSpend.higherSpendMonthlyAmount == Money.dollars(300))
        #expect(result.expectedSpend.higherUnscheduledMonthlyAmount == Money.dollars(300))
        #expect(result.expectedSpend.higherDailyAmount == Money(milliunits: 9_863))
        #expect(result.higherSpendPoints.count == result.expectedPoints.count)
        #expect(result.safeToSpend?.amount == Money(milliunits: 1_417_810))
        #expect(result.higherSpendSafeToSpend?.amount == Money(milliunits: 1_401_370))
    }

    @Test func transactionExclusionRemovesOnlySelectedSplitLeg() {
        let today = date(2026, 1, 11)
        let split = TransactionSummary(
            id: "split", accountId: "cash", date: date(2026, 1, 5),
            amount: Money.dollars(-1_000), cleared: true, approved: true,
            payeeName: "Mixed purchase", categoryName: nil, memo: nil, deleted: false,
            subtransactions: [
                SubTransactionSummary(
                    id: "one-time-leg", amount: Money.dollars(-900),
                    categoryId: "one-time", categoryName: "One-time",
                    payeeName: "Large purchase", memo: nil, deleted: false
                ),
                SubTransactionSummary(
                    id: "ordinary-leg", amount: Money.dollars(-100),
                    categoryId: "ordinary", categoryName: "Ordinary",
                    payeeName: "Normal purchase", memo: nil, deleted: false
                )
            ]
        )
        let result = CashPositionProjector(calendar: utc).project(
            cashAccounts: [account("cash", balance: 2_000)],
            selectedCashAccountIds: ["cash"],
            cardAccountIds: [], fundedCardAccountIds: [], cardPayments: [],
            scheduled: [], historicalTransactions: [split],
            excludedTransactionIds: ["one-time-leg"], spendAccountIds: ["cash"],
            asOf: today, horizonDays: 2
        )

        #expect(result.expectedSpend.historicalOutflows == Money.dollars(100))
        #expect(result.expectedSpend.dailyAmount == Money(milliunits: 16_666))
    }

    @Test func statusCoversTightAndShortfall() {
        let projector = CashPositionProjector(calendar: utc)
        let today = date(2026, 1, 1)
        func status(balance: Int, bill: Int = 0) -> CashProjectionStatus {
            let scheduled: [ScheduledTransactionSummary] = bill == 0 ? [] : [
                ScheduledTransactionSummary(
                    id: "bill", accountId: "cash", nextDate: date(2026, 1, 2),
                    frequency: .never, amount: Money.dollars(integer: -bill)
                )
            ]
            return projector.project(
                cashAccounts: [account("cash", balance: balance)],
                selectedCashAccountIds: ["cash"], cardAccountIds: [], fundedCardAccountIds: [],
                cardPayments: [], scheduled: scheduled, historicalTransactions: [],
                asOf: today, horizonDays: 2, minimumCashBuffer: Money.dollars(500)
            ).status
        }
        #expect(status(balance: 1_000) == .covered)
        #expect(status(balance: 400) == .tight)
        #expect(status(balance: 100, bill: 200) == .shortfall)
    }

    @Test func safeToSpendUsesLowestBalanceAcrossFullHorizon() {
        let today = date(2026, 1, 1)
        let bill = ScheduledTransactionSummary(
            id: "bill", accountId: "cash", nextDate: date(2026, 1, 2),
            frequency: .never, amount: Money.dollars(-300), payeeName: "Rent"
        )
        let income = ScheduledTransactionSummary(
            id: "income", accountId: "cash", nextDate: date(2026, 1, 5),
            frequency: .never, amount: Money.dollars(1_000), payeeName: "Paycheck"
        )
        let laterBill = ScheduledTransactionSummary(
            id: "later-bill", accountId: "cash", nextDate: date(2026, 1, 6),
            frequency: .never, amount: Money.dollars(-1_800), payeeName: "Later bill"
        )
        let result = CashPositionProjector(calendar: utc).project(
            cashAccounts: [account("cash", balance: 2_000)],
            selectedCashAccountIds: ["cash"],
            cardAccountIds: [], fundedCardAccountIds: [], cardPayments: [],
            scheduled: [bill, income, laterBill], historicalTransactions: [],
            asOf: today, horizonDays: 10, minimumCashBuffer: Money.dollars(500)
        )

        #expect(result.safeToSpend?.amount == Money.dollars(400))
        #expect(result.safeToSpend?.lowPointDate == date(2026, 1, 6))
        #expect(result.safeToSpend?.projectedLowBalance == Money.dollars(900))
        #expect(result.safeToSpend?.startingBalance == Money.dollars(2_000))
        #expect(result.safeToSpend?.knownInflows == Money.dollars(1_000))
        #expect(result.safeToSpend?.scheduledOutflows == Money.dollars(2_100))
        #expect(result.safeToSpend?.cardPaymentOutflows == .zero)
        #expect(result.safeToSpend?.expectedSpendingReserve == .zero)
        #expect(result.safeToSpend?.contributingEvents.count == 3)
    }

    @Test func safeToSpendFloorsAtZeroAndDoesNotRequireScheduledIncome() {
        let today = date(2026, 1, 1)
        let income = ScheduledTransactionSummary(
            id: "income", accountId: "cash", nextDate: date(2026, 1, 3),
            frequency: .never, amount: Money.dollars(1_000), payeeName: "Paycheck"
        )
        let projector = CashPositionProjector(calendar: utc)
        let tight = projector.project(
            cashAccounts: [account("cash", balance: 400)],
            selectedCashAccountIds: ["cash"],
            cardAccountIds: [], fundedCardAccountIds: [], cardPayments: [],
            scheduled: [income], historicalTransactions: [],
            asOf: today, horizonDays: 5, minimumCashBuffer: Money.dollars(500)
        )
        let missingIncome = projector.project(
            cashAccounts: [account("cash", balance: 2_000)],
            selectedCashAccountIds: ["cash"],
            cardAccountIds: [], fundedCardAccountIds: [], cardPayments: [],
            scheduled: [], historicalTransactions: [],
            asOf: today, horizonDays: 5, minimumCashBuffer: Money.dollars(500)
        )

        #expect(tight.safeToSpend?.amount == .zero)
        #expect(tight.safeToSpend?.bufferGap == Money.dollars(100))
        #expect(missingIncome.safeToSpend?.amount == Money.dollars(1_500))
    }

    @Test func safeToSpendReservesExpectedOrdinarySpending() {
        let today = date(2026, 1, 11)
        let history = [
            transaction("cash", amount: -300, date: date(2026, 1, 1))
        ]
        let result = CashPositionProjector(calendar: utc).project(
            cashAccounts: [account("cash", balance: 2_000)],
            selectedCashAccountIds: ["cash"],
            cardAccountIds: [], fundedCardAccountIds: [], cardPayments: [],
            scheduled: [], historicalTransactions: history,
            spendAccountIds: ["cash"], asOf: today, horizonDays: 3,
            minimumCashBuffer: Money.dollars(500)
        )

        #expect(result.expectedSpend.dailyAmount == Money.dollars(30))
        #expect(result.safeToSpend?.projectedLowBalance == Money.dollars(1_910))
        #expect(result.safeToSpend?.amount == Money.dollars(1_410))
        #expect(result.safeToSpend?.expectedSpendingReserve == Money.dollars(90))
    }

    @Test func firstShortfallIsDistinctFromLowestBalanceAtHorizon() {
        let today = date(2026, 1, 1)
        let firstBill = ScheduledTransactionSummary(
            id: "first", accountId: "cash", nextDate: date(2026, 1, 2),
            frequency: .never, amount: Money.dollars(-150), payeeName: "First bill"
        )
        let laterBill = ScheduledTransactionSummary(
            id: "later", accountId: "cash", nextDate: date(2026, 1, 4),
            frequency: .never, amount: Money.dollars(-100), payeeName: "Later bill"
        )
        let result = CashPositionProjector(calendar: utc).project(
            cashAccounts: [account("cash", balance: 100)],
            selectedCashAccountIds: ["cash"],
            cardAccountIds: [], fundedCardAccountIds: [],
            cardPayments: [], scheduled: [firstBill, laterBill], historicalTransactions: [],
            asOf: today, horizonDays: 5
        )

        #expect(result.expectedFirstShortfallPoint?.date == date(2026, 1, 2))
        #expect(result.expectedFirstShortfallPoint?.balance == Money.dollars(-50))
        #expect(result.expectedFirstShortfallEvent?.title == "First bill")
        #expect(result.expectedLowPoint?.date == date(2026, 1, 4))
        #expect(result.expectedLowPoint?.balance == Money.dollars(-150))
    }

    private func transaction(
        _ accountId: String,
        amount: Int,
        date: Date,
        transfer: String? = nil
    ) -> TransactionSummary {
        TransactionSummary(
            id: "\(accountId)-\(amount)-\(date.timeIntervalSince1970)",
            accountId: accountId, date: date,
            amount: Money.dollars(integer: amount), cleared: true, approved: true,
            payeeName: nil, categoryName: nil, transferAccountId: transfer,
            memo: nil, deleted: false
        )
    }
}
