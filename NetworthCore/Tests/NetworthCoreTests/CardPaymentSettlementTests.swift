import Testing
import Foundation
@testable import Money
@testable import Models
@testable import Projections

@Suite("Card payment settlement matching")
struct CardPaymentSettlementTests {
    private var utc: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "UTC")!
        return value
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func payment(
        card: String = "card-1",
        payingAccount: String = "checking",
        closeDate: Date,
        dueDate: Date,
        amount: Money
    ) -> UpcomingCardPayment {
        UpcomingCardPayment(
            cardAccountId: card, paymentAccountId: payingAccount,
            cardName: card, closeDate: closeDate, dueDate: dueDate,
            amount: amount, basis: .closedStatementEstimate
        )
    }

    private func debit(
        id: String,
        account: String = "checking",
        date: Date,
        dollars: Int,
        treatment: ForecastTreatment? = .cardPayment
    ) -> TransactionSummary {
        TransactionSummary(
            id: id, accountId: account, date: date,
            amount: Money.dollars(integer: -dollars), cleared: true,
            approved: true, payeeName: nil, categoryName: nil,
            forecastTreatment: treatment, memo: nil, deleted: false
        )
    }

    private var matcher: CardPaymentSettlementMatcher {
        CardPaymentSettlementMatcher(calendar: utc)
    }

    @Test func bankDebitWithinToleranceSettlesOverduePayment() {
        // $803 actual vs $800 estimate is inside max($5, 1%) tolerance.
        let overdue = payment(
            closeDate: date(2026, 5, 21), dueDate: date(2026, 6, 5),
            amount: Money.dollars(800)
        )
        let settled = matcher.settledPaymentIds(
            payments: [overdue],
            transactions: [debit(id: "d1", date: date(2026, 6, 6), dollars: 803)],
            settlements: [],
            asOf: date(2026, 6, 8)
        )
        #expect(settled == [overdue.id])
    }

    @Test func amountOutsideToleranceDoesNotSettle() {
        let overdue = payment(
            closeDate: date(2026, 5, 21), dueDate: date(2026, 6, 5),
            amount: Money.dollars(800)
        )
        let settled = matcher.settledPaymentIds(
            payments: [overdue],
            transactions: [debit(id: "d1", date: date(2026, 6, 6), dollars: 730)],
            settlements: [],
            asOf: date(2026, 6, 8)
        )
        #expect(settled.isEmpty)
    }

    @Test func wrongAccountOrTreatmentDoesNotSettle() {
        let overdue = payment(
            closeDate: date(2026, 5, 21), dueDate: date(2026, 6, 5),
            amount: Money.dollars(800)
        )
        let settled = matcher.settledPaymentIds(
            payments: [overdue],
            transactions: [
                debit(id: "other-account", account: "savings",
                      date: date(2026, 6, 6), dollars: 800),
                debit(id: "untyped", date: date(2026, 6, 6), dollars: 800,
                      treatment: nil)
            ],
            settlements: [],
            asOf: date(2026, 6, 8)
        )
        #expect(settled.isEmpty)
    }

    @Test func paymentNotYetDueIsNeverSettled() {
        let future = payment(
            closeDate: date(2026, 5, 21), dueDate: date(2026, 6, 20),
            amount: Money.dollars(800)
        )
        let settled = matcher.settledPaymentIds(
            payments: [future],
            transactions: [debit(id: "d1", date: date(2026, 6, 6), dollars: 800)],
            settlements: [],
            asOf: date(2026, 6, 8)
        )
        #expect(settled.isEmpty)
    }

    @Test func explicitSettlementSettlesRegardlessOfAmount() {
        // The refund-skewed cycle: no debit matches the estimate, but the
        // user resolved it — with or without pointing at a transaction.
        let overdue = payment(
            closeDate: date(2026, 5, 21), dueDate: date(2026, 6, 5),
            amount: Money.dollars(800)
        )
        let byTransaction = CardPaymentSettlement(
            id: "s1", cardAccountId: "card-1",
            statementCloseDate: date(2026, 5, 21),
            transactionId: "d1", updatedAt: date(2026, 6, 8)
        )
        let paidElsewhere = CardPaymentSettlement(
            id: "s2", cardAccountId: "card-1",
            statementCloseDate: date(2026, 5, 21),
            transactionId: nil, updatedAt: date(2026, 6, 8)
        )
        for settlement in [byTransaction, paidElsewhere] {
            let settled = matcher.settledPaymentIds(
                payments: [overdue],
                transactions: [],
                settlements: [settlement],
                asOf: date(2026, 6, 8)
            )
            #expect(settled == [overdue.id])
        }
    }

    @Test func oneDebitSettlesOnlyTheClosestPayment() {
        // Two cards paid from one account: the single $795 debit settles the
        // $795 payment, and the $800 payment stays projected.
        let first = payment(
            card: "card-1",
            closeDate: date(2026, 5, 21), dueDate: date(2026, 6, 5),
            amount: Money.dollars(800)
        )
        let second = payment(
            card: "card-2",
            closeDate: date(2026, 5, 18), dueDate: date(2026, 6, 4),
            amount: Money.dollars(795)
        )
        let settled = matcher.settledPaymentIds(
            payments: [first, second],
            transactions: [debit(id: "d1", date: date(2026, 6, 5), dollars: 795)],
            settlements: [],
            asOf: date(2026, 6, 8)
        )
        #expect(settled == [second.id])
    }

    @Test func candidateTransactionsRankByAmountCloseness() {
        let overdue = payment(
            closeDate: date(2026, 5, 21), dueDate: date(2026, 6, 5),
            amount: Money.dollars(800)
        )
        let candidates = matcher.candidateTransactions(
            for: overdue,
            transactions: [
                debit(id: "groceries", date: date(2026, 6, 2), dollars: 120,
                      treatment: nil),
                debit(id: "likely-payment", date: date(2026, 6, 6), dollars: 785,
                      treatment: nil),
                debit(id: "pre-close", date: date(2026, 5, 20), dollars: 800,
                      treatment: nil),
                debit(id: "other-account", account: "savings",
                      date: date(2026, 6, 6), dollars: 800, treatment: nil)
            ],
            asOf: date(2026, 6, 8)
        )
        #expect(candidates.map(\.id) == ["likely-payment", "groceries"])
    }
}
