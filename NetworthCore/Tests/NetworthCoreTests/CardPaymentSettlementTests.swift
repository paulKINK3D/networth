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
        cleared: Bool = true,
        treatment: ForecastTreatment? = .cardPayment
    ) -> TransactionSummary {
        TransactionSummary(
            id: id, accountId: account, date: date,
            amount: Money.dollars(integer: -dollars), cleared: cleared,
            approved: true, payeeName: nil, categoryName: nil,
            forecastTreatment: treatment, memo: nil, deleted: false
        )
    }

    private var matcher: CardPaymentSettlementMatcher {
        CardPaymentSettlementMatcher(calendar: utc)
    }

    @Test func pairedBankDebitWithinToleranceSettlesOverduePayment() {
        // $803 actual vs $800 estimate is inside max($5, 1%) tolerance, and
        // the debit's counterpart twin lives on the paying card.
        let overdue = payment(
            closeDate: date(2026, 5, 21), dueDate: date(2026, 6, 5),
            amount: Money.dollars(800)
        )
        let settled = matcher.settledPaymentIds(
            payments: [overdue],
            transactions: [debit(id: "d1", date: date(2026, 6, 6), dollars: 803)],
            counterpartAccountIds: ["d1": "card-1"],
            settlements: [],
            asOf: date(2026, 6, 8)
        )
        #expect(settled == [overdue.id])
    }

    @Test func uniqueUnpairedDebitSettles() {
        let overdue = payment(
            closeDate: date(2026, 5, 21), dueDate: date(2026, 6, 5),
            amount: Money.dollars(800)
        )
        let settled = matcher.settledPaymentIds(
            payments: [overdue],
            transactions: [debit(id: "d1", date: date(2026, 6, 6), dollars: 800)],
            settlements: [],
            asOf: date(2026, 6, 8)
        )
        #expect(settled == [overdue.id])
    }

    @Test func ambiguousUnpairedDebitDoesNotSettleEitherCard() {
        let payments = ["card-1", "card-2"].map { card in
            payment(card: card, closeDate: date(2026, 5, 21),
                    dueDate: date(2026, 6, 5), amount: Money.dollars(800))
        }
        let settled = matcher.settledPaymentIds(
            payments: payments,
            transactions: [debit(id: "debit", date: date(2026, 6, 6), dollars: 800)],
            settlements: [], asOf: date(2026, 6, 8)
        )
        #expect(settled.isEmpty)
    }

    @Test func cardCreditAloneDoesNotSettle() {
        let overdue = payment(closeDate: date(2026, 5, 21),
                              dueDate: date(2026, 6, 5), amount: Money.dollars(800))
        let settled = matcher.settledPaymentIds(
            payments: [overdue],
            transactions: [debit(id: "credit", account: "card-1",
                                 date: date(2026, 6, 6), dollars: -800)],
            settlements: [], asOf: date(2026, 6, 8)
        )
        #expect(settled.isEmpty)
    }

    @Test func pendingDebitDoesNotSettle() {
        let overdue = payment(closeDate: date(2026, 5, 21),
                              dueDate: date(2026, 6, 5), amount: Money.dollars(800))
        #expect(matcher.settledPaymentIds(
            payments: [overdue],
            transactions: [debit(id: "pending", date: date(2026, 6, 6),
                                 dollars: 800, cleared: false)],
            settlements: [], asOf: date(2026, 6, 8)
        ).isEmpty)
    }

    @Test func explicitSettlementDebitCannotSettleAnotherCard() {
        let overdue = payment(closeDate: date(2026, 5, 21),
                              dueDate: date(2026, 6, 5), amount: Money.dollars(800))
        let existing = CardPaymentSettlement(
            id: "existing", cardAccountId: "other-card",
            statementCloseDate: date(2026, 5, 21), transactionId: "debit",
            updatedAt: date(2026, 6, 8)
        )
        #expect(matcher.settledPaymentIds(
            payments: [overdue],
            transactions: [debit(id: "debit", date: date(2026, 6, 6), dollars: 800)],
            settlements: [existing], asOf: date(2026, 6, 8)
        ).isEmpty)
    }

    @Test func debitPairedToAnotherCardDoesNotSettle() {
        let overdue = payment(
            closeDate: date(2026, 5, 21), dueDate: date(2026, 6, 5),
            amount: Money.dollars(800)
        )
        let settled = matcher.settledPaymentIds(
            payments: [overdue],
            transactions: [debit(id: "d1", date: date(2026, 6, 6), dollars: 800)],
            counterpartAccountIds: ["d1": "card-2"],
            settlements: [],
            asOf: date(2026, 6, 8)
        )
        #expect(settled.isEmpty)
    }

    @Test func amountOutsideToleranceDoesNotSettle() {
        // Pairing alone is not enough either: an off-estimate paired debit
        // (an extra principal payment, say) must not retire the statement.
        let overdue = payment(
            closeDate: date(2026, 5, 21), dueDate: date(2026, 6, 5),
            amount: Money.dollars(800)
        )
        let settled = matcher.settledPaymentIds(
            payments: [overdue],
            transactions: [debit(id: "d1", date: date(2026, 6, 6), dollars: 730)],
            counterpartAccountIds: ["d1": "card-1"],
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
            counterpartAccountIds: [
                "other-account": "card-1",
                "untyped": "card-1"
            ],
            settlements: [],
            asOf: date(2026, 6, 8)
        )
        #expect(settled.isEmpty)
    }

    @Test func postedDebitSettlesBeforeDueDate() {
        let future = payment(
            closeDate: date(2026, 5, 21), dueDate: date(2026, 6, 20),
            amount: Money.dollars(800)
        )
        let settled = matcher.settledPaymentIds(
            payments: [future],
            transactions: [debit(id: "d1", date: date(2026, 6, 6), dollars: 800)],
            counterpartAccountIds: ["d1": "card-1"],
            settlements: [],
            asOf: date(2026, 6, 8)
        )
        #expect(settled == [future.id])
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

    @Test func pairedDebitSettlesItsOwnCardNotTheClosestAmount() {
        // Two cards paid from one account with near-identical statements:
        // the twin relationship decides which payment settles, so the $795
        // debit paired to card-1 settles card-1 even though card-2's
        // estimate is the exact amount.
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
            counterpartAccountIds: ["d1": "card-1"],
            settlements: [],
            asOf: date(2026, 6, 8)
        )
        #expect(settled == [first.id])
    }

    @Test func uniqueProjectedPaymentMatchNamesTheCard() {
        // $5,907.17-style case: the debit is within tolerance of exactly
        // one card's projected payment from this paying account.
        let hilton = payment(
            card: "hilton",
            closeDate: date(2026, 9, 25), dueDate: date(2026, 10, 9),
            amount: Money.dollars(836)
        )
        let gold = payment(
            card: "gold",
            closeDate: date(2026, 9, 25), dueDate: date(2026, 10, 9),
            amount: Money.dollars(5_910)
        )
        let match = CardPaymentIdentityResolver(calendar: utc)
            .uniqueCardMatch(
                debitAccountId: "checking",
                amount: Money.dollars(integer: -5907),
                postedDate: date(2026, 10, 5),
                payments: [hilton, gold]
            )
        #expect(match?.cardAccountId == "gold")
    }

    @Test func ambiguousProjectedPaymentMatchResolvesNothing() {
        // Two different cards expect near-identical payments: no guess.
        let first = payment(
            card: "card-1",
            closeDate: date(2026, 9, 25), dueDate: date(2026, 10, 9),
            amount: Money.dollars(800)
        )
        let second = payment(
            card: "card-2",
            closeDate: date(2026, 9, 25), dueDate: date(2026, 10, 9),
            amount: Money.dollars(801)
        )
        let match = CardPaymentIdentityResolver(calendar: utc)
            .uniqueCardMatch(
                debitAccountId: "checking",
                amount: Money.dollars(integer: -800),
                postedDate: date(2026, 10, 5),
                payments: [first, second]
            )
        #expect(match == nil)
    }

    @Test func projectedPaymentMatchRequiresPayingAccountAndWindow() {
        let overdue = payment(
            closeDate: date(2026, 9, 25), dueDate: date(2026, 10, 9),
            amount: Money.dollars(800)
        )
        let resolver = CardPaymentIdentityResolver(calendar: utc)
        // Debit from a different account than the card's configured payer.
        #expect(resolver.uniqueCardMatch(
            debitAccountId: "savings",
            amount: Money.dollars(integer: -800),
            postedDate: date(2026, 10, 5),
            payments: [overdue]
        ) == nil)
        // Debit posted before the statement even closed.
        #expect(resolver.uniqueCardMatch(
            debitAccountId: "checking",
            amount: Money.dollars(integer: -800),
            postedDate: date(2026, 9, 20),
            payments: [overdue]
        ) == nil)
        // Amount outside max($5, 1%) tolerance.
        #expect(resolver.uniqueCardMatch(
            debitAccountId: "checking",
            amount: Money.dollars(integer: -730),
            postedDate: date(2026, 10, 5),
            payments: [overdue]
        ) == nil)
        // Inflows never resolve.
        #expect(resolver.uniqueCardMatch(
            debitAccountId: "checking",
            amount: Money.dollars(integer: 800),
            postedDate: date(2026, 10, 5),
            payments: [overdue]
        ) == nil)
    }

    @Test func twoCyclesOfOneCardStillResolveThatCard() {
        // Ambiguity across cycles of the same card is not ambiguity about
        // the card: identity resolution only names the card for review.
        let older = payment(
            closeDate: date(2026, 8, 25), dueDate: date(2026, 9, 9),
            amount: Money.dollars(800)
        )
        let newer = payment(
            closeDate: date(2026, 9, 25), dueDate: date(2026, 10, 9),
            amount: Money.dollars(802)
        )
        let match = CardPaymentIdentityResolver(calendar: utc)
            .uniqueCardMatch(
                debitAccountId: "checking",
                amount: Money.dollars(integer: -800),
                postedDate: date(2026, 10, 5),
                payments: [older, newer]
            )
        #expect(match?.cardAccountId == "card-1")
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
    @Test func matchedStatementSurvivesRolloverUntilClearedWithoutAnotherCashEvent() {
        let paid = payment(closeDate: date(2026, 5, 21), dueDate: date(2026, 6, 5), amount: .dollars(800))
        let next = payment(closeDate: date(2026, 6, 21), dueDate: date(2026, 7, 5), amount: .dollars(200))
        let transactions = [debit(id: "paid", date: date(2026, 6, 5), dollars: 800)]
        let matches = matcher.paymentMatches(payments: [paid], transactions: transactions,
                                             settlements: [], asOf: date(2026, 6, 6))
        #expect(matches[paid.id] == "paid")
        let all = CardPaymentReviewQueue.matchingPayments(current: [next], retained: [paid])
        let settled = matcher.settledPaymentIds(payments: all, transactions: transactions,
                                                settlements: [], asOf: date(2026, 6, 22))
        #expect(CardPaymentReviewQueue.readyToClear(payments: all, settledIDs: settled,
                                                    clearedIDs: []).map(\.id) == [paid.id])
        #expect(CardPaymentReviewQueue.readyToClear(payments: all, settledIDs: settled,
                                                    clearedIDs: [paid.id]).isEmpty)
        // Only current unpaid payments reach the cash projector, before and after Clear.
        #expect([next].filter { !settled.contains($0.id) }.map(\.id) == [next.id])
    }

    @Test func editingStatementAfterMatchingPreservesEvidenceButRemovedDebitDoesNot() throws {
        let paid = payment(closeDate: date(2026, 5, 21), dueDate: date(2026, 6, 5), amount: .dollars(800))
        let revised = payment(closeDate: paid.closeDate, dueDate: paid.dueDate, amount: .dollars(600))
        let transaction = debit(id: "paid", date: date(2026, 6, 5), dollars: 800)
        let evidence = try #require(CardPaymentReviewQueue.retainedSettlement(
            payment: paid, transactionID: "paid", transactions: [transaction],
            counterpartAccountIds: [:], capturedAt: date(2026, 6, 6)
        ))
        let all = CardPaymentReviewQueue.matchingPayments(current: [revised], retained: [paid])
        #expect(all.count == 1)
        #expect(all.first?.amount == .dollars(800))
        #expect(matcher.settledPaymentIds(payments: [revised], transactions: [transaction],
                                          settlements: [evidence], asOf: date(2026, 6, 8)) == [paid.id])
        #expect(CardPaymentReviewQueue.retainedSettlement(
            payment: paid, transactionID: "paid", transactions: [],
            counterpartAccountIds: [:], capturedAt: date(2026, 6, 6)
        ) == nil)
        #expect(CardPaymentReviewQueue.retainedSettlement(
            payment: paid, transactionID: "paid", transactions: [transaction],
            counterpartAccountIds: ["paid": "another-card"], capturedAt: date(2026, 6, 6)
        ) == nil)
        #expect(CardPaymentReviewQueue.retainedSettlement(
            payment: paid, transactionID: "paid",
            transactions: [debit(id: "paid", date: date(2026, 6, 5), dollars: 800, treatment: .ordinarySpending)],
            counterpartAccountIds: [:], capturedAt: date(2026, 6, 6)
        ) == nil)
    }

}
