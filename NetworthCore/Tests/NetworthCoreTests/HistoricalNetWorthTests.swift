import Testing
import Foundation
@testable import Money
@testable import Models
@testable import Projections

@Suite("Historical net-worth reconstruction")
struct HistoricalNetWorthTests {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var comps = DateComponents(); comps.year = y; comps.month = m; comps.day = d
        return utc.date(from: comps)!
    }

    private func txn(
        id: String = UUID().uuidString,
        accountId: String,
        date: Date,
        amount: Money,
        transferAccountId: String? = nil
    ) -> TransactionSummary {
        TransactionSummary(
            id: id,
            accountId: accountId,
            date: date,
            amount: amount,
            cleared: true,
            approved: true,
            payeeName: nil,
            categoryName: nil,
            transferAccountId: transferAccountId,
            memo: nil,
            deleted: false
        )
    }

    @Test func reconstructionRollsBackTransactions() {
        let r = AccountHistoryReconstructor(calendar: utc)
        let txns = [
            txn(accountId: "1", date: day(2026, 3, 5), amount: Money.dollars(-100)),
            txn(accountId: "1", date: day(2026, 3, 3), amount: Money.dollars(50))
        ]
        let series = r.reconstruct(
            currentBalance: Money.dollars(450),
            transactions: txns,
            from: day(2026, 3, 1),
            to: day(2026, 3, 6)
        )
        let byDay = Dictionary(uniqueKeysWithValues: series.map { ($0.date, $0.balance) })
        #expect(byDay[day(2026, 3, 6)] == Money.dollars(450))
        #expect(byDay[day(2026, 3, 5)] == Money.dollars(450))
        #expect(byDay[day(2026, 3, 4)] == Money.dollars(550))
        #expect(byDay[day(2026, 3, 3)] == Money.dollars(550))
        #expect(byDay[day(2026, 3, 2)] == Money.dollars(500))
    }

    @Test func aggregatorSeparatesAssetsFromLiabilities() {
        let agg = NetWorthHistoryAggregator()
        let cashSeries = [
            AccountHistoryReconstructor.DailyBalance(date: day(2026, 3, 1), balance: Money.dollars(1_000)),
            AccountHistoryReconstructor.DailyBalance(date: day(2026, 3, 2), balance: Money.dollars(1_200))
        ]
        let cardSeries = [
            AccountHistoryReconstructor.DailyBalance(date: day(2026, 3, 1), balance: Money.dollars(-400)),
            AccountHistoryReconstructor.DailyBalance(date: day(2026, 3, 2), balance: Money.dollars(-500))
        ]
        let snapshots = agg.aggregate(
            dailyBalancesByAccount: ["a": cashSeries, "b": cardSeries],
            kindsById: ["a": .checking, "b": .creditCard]
        )
        #expect(snapshots.count == 2)
        let last = snapshots.last!
        #expect(last.assets == Money.dollars(1_200))
        #expect(last.liabilities == Money.dollars(500))
        #expect(last.netWorth == Money.dollars(700))
    }

    /// Verifies the Fix 2 design: walking a closed account (today's balance $0)
    /// together with the open account that received the closing transfer keeps
    /// the aggregate flat across the transfer-out date.
    ///
    /// Setup: closed brokerage at $0 today, with one transfer-out of $5,000 on
    /// 3/15 going to open checking. Open checking today $5,000 with the
    /// corresponding transfer-in on 3/15.
    @Test func walkingClosedAccountAlongsideOpenKeepsAggregateFlatAcrossTransferOut() {
        let r = AccountHistoryReconstructor(calendar: utc)
        let checkingId = "CHECKING"
        let brokerageId = "BROKERAGE"

        // Checking transactions: received +$5,000 from brokerage on 3/15.
        let checkingTxns = [
            txn(accountId: checkingId, date: day(2026, 3, 15),
                amount: Money.dollars(5_000), transferAccountId: brokerageId)
        ]
        let checkingSeries = r.reconstruct(
            currentBalance: Money.dollars(5_000),
            transactions: checkingTxns,
            from: day(2026, 3, 10),
            to: day(2026, 3, 20)
        )

        // Brokerage: paid out -$5,000 to checking on 3/15. Today $0 (closed).
        let brokerageTxns = [
            txn(accountId: brokerageId, date: day(2026, 3, 15),
                amount: Money.dollars(-5_000), transferAccountId: checkingId)
        ]
        let brokerageSeries = r.reconstruct(
            currentBalance: Money.zero,
            transactions: brokerageTxns,
            from: day(2026, 3, 10),
            to: day(2026, 3, 20)
        )

        let snapshots = NetWorthHistoryAggregator().aggregate(
            dailyBalancesByAccount: [
                checkingId: checkingSeries,
                brokerageId: brokerageSeries
            ],
            kindsById: [
                checkingId: .checking,
                brokerageId: .investment
            ]
        )
        let byDay = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.date, $0.netWorth) })

        // The aggregate should be $5,000 throughout — the money simply moved
        // from brokerage to checking on 3/15. Crucially, this is what the user
        // wants: no fake decline at the transfer-out date.
        #expect(byDay[day(2026, 3, 14)] == Money.dollars(5_000),
                "Pre-transfer aggregate should reflect brokerage's reconstructed balance.")
        #expect(byDay[day(2026, 3, 15)] == Money.dollars(5_000),
                "Day-of-transfer aggregate stays flat — brokerage drops, checking spikes.")
        #expect(byDay[day(2026, 3, 16)] == Money.dollars(5_000),
                "Post-transfer aggregate matches: checking holds the value, brokerage is $0.")
        #expect(byDay[day(2026, 3, 20)] == Money.dollars(5_000))
    }
}
