import Testing
import Foundation
@testable import Models

@Suite("Transfer counterpart matching")
struct TransferCounterpartMatchingTests {
    private var utc: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "UTC")!
        return value
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func candidate(
        _ id: String,
        account: String,
        dollars: Int,
        date: Date,
        treatment: ForecastTreatment? = .internalTransfer
    ) -> CounterpartCandidate {
        CounterpartCandidate(
            id: id,
            accountId: account,
            amountMilliunits: Int64(dollars) * 1_000,
            postedDate: date,
            providerDefaultTreatment: treatment
        )
    }

    private var matcher: TransferCounterpartMatcher {
        TransferCounterpartMatcher(calendar: utc)
    }

    private let kinds: [String: FinancialAccountType] = [
        "checking": .checking,
        "savings": .savings,
        "visa": .creditCard,
        "amex": .creditCard
    ]

    @Test func bankOutflowAndCardInflowPairAsCardPayment() {
        // The card-side credit posting three days before the bank debit is
        // the measured normal ordering; it must still pair.
        let pairs = matcher.matches(
            candidates: [
                candidate("bank", account: "checking", dollars: -800,
                          date: date(2026, 6, 8), treatment: .cardPayment),
                candidate("card", account: "visa", dollars: 800,
                          date: date(2026, 6, 5), treatment: nil)
            ],
            accountKinds: kinds
        )
        #expect(pairs == [
            CounterpartPair(outflowId: "bank", inflowId: "card",
                            kind: .cardPayment)
        ])
    }

    @Test func cashToCashPairsAsInternalTransferBothDirections() {
        let pairs = matcher.matches(
            candidates: [
                candidate("out1", account: "checking", dollars: -500,
                          date: date(2026, 6, 1)),
                candidate("in1", account: "savings", dollars: 500,
                          date: date(2026, 6, 2)),
                candidate("out2", account: "savings", dollars: -200,
                          date: date(2026, 6, 10)),
                candidate("in2", account: "checking", dollars: 200,
                          date: date(2026, 6, 10))
            ],
            accountKinds: kinds
        )
        #expect(Set(pairs) == [
            CounterpartPair(outflowId: "out1", inflowId: "in1",
                            kind: .internalTransfer),
            CounterpartPair(outflowId: "out2", inflowId: "in2",
                            kind: .internalTransfer)
        ])
    }

    @Test func rejectionsNeverPair() {
        let base = date(2026, 6, 10)
        let cases: [[CounterpartCandidate]] = [
            // Same account.
            [candidate("a", account: "checking", dollars: -100, date: base),
             candidate("b", account: "checking", dollars: 100, date: base)],
            // Amount off by a cent (10 milliunits).
            [candidate("a", account: "checking", dollars: -100, date: base),
             CounterpartCandidate(id: "b", accountId: "savings",
                                  amountMilliunits: 100_010, postedDate: base,
                                  providerDefaultTreatment: .internalTransfer)],
            // Six-day gap.
            [candidate("a", account: "checking", dollars: -100, date: base),
             candidate("b", account: "savings", dollars: 100,
                       date: date(2026, 6, 16))],
            // Neither side transfer-flavored.
            [candidate("a", account: "checking", dollars: -100, date: base,
                       treatment: .ordinarySpending),
             candidate("b", account: "savings", dollars: 100, date: base,
                       treatment: .refund)],
            // Unmonitored account.
            [candidate("a", account: "checking", dollars: -100, date: base),
             candidate("b", account: "unknown", dollars: 100, date: base)],
            // Card to card.
            [candidate("a", account: "visa", dollars: -100, date: base),
             candidate("b", account: "amex", dollars: 100, date: base)],
            // Card outflow to cash inflow (refund direction).
            [candidate("a", account: "visa", dollars: -100, date: base),
             candidate("b", account: "checking", dollars: 100, date: base)]
        ]
        for candidates in cases {
            #expect(matcher.matches(
                candidates: candidates,
                accountKinds: kinds
            ).isEmpty)
        }
    }

    @Test func recurringSameAmountTransfersStayInTheirOwnWeeks() {
        // Two identical $500 moves a week apart: closest-gap greedy pairing
        // keeps each debit with its own week's credit.
        let pairs = matcher.matches(
            candidates: [
                candidate("out-w1", account: "checking", dollars: -500,
                          date: date(2026, 6, 1)),
                candidate("in-w1", account: "savings", dollars: 500,
                          date: date(2026, 6, 2)),
                candidate("out-w2", account: "checking", dollars: -500,
                          date: date(2026, 6, 8)),
                candidate("in-w2", account: "savings", dollars: 500,
                          date: date(2026, 6, 9))
            ],
            accountKinds: kinds
        )
        #expect(Set(pairs) == [
            CounterpartPair(outflowId: "out-w1", inflowId: "in-w1",
                            kind: .internalTransfer),
            CounterpartPair(outflowId: "out-w2", inflowId: "in-w2",
                            kind: .internalTransfer)
        ])
    }

    @Test func oneInflowNeverSettlesTwoOutflows() {
        let pairs = matcher.matches(
            candidates: [
                candidate("out1", account: "checking", dollars: -300,
                          date: date(2026, 6, 1)),
                candidate("out2", account: "checking", dollars: -300,
                          date: date(2026, 6, 3)),
                candidate("in1", account: "savings", dollars: 300,
                          date: date(2026, 6, 3))
            ],
            accountKinds: kinds
        )
        #expect(pairs == [
            CounterpartPair(outflowId: "out2", inflowId: "in1",
                            kind: .internalTransfer)
        ])
    }
}
