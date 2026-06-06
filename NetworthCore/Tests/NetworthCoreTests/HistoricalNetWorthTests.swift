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

    @Test func reconstructionRollsBackTransactions() {
        let r = AccountHistoryReconstructor(calendar: utc)
        let txns = [
            TransactionSummary(id: "a", accountId: "1", date: day(2026, 3, 5), amount: Money.dollars(-100),
                cleared: true, approved: true, payeeName: nil, categoryName: nil, memo: nil, deleted: false),
            TransactionSummary(id: "b", accountId: "1", date: day(2026, 3, 3), amount: Money.dollars(50),
                cleared: true, approved: true, payeeName: nil, categoryName: nil, memo: nil, deleted: false)
        ]
        let series = r.reconstruct(
            currentBalance: Money.dollars(450),
            transactions: txns,
            from: day(2026, 3, 1),
            to: day(2026, 3, 6)
        )
        // 3/6 (after both txns) = 450
        // 3/5 (before -100, after +50) — actually the -100 posts on 3/5, so end-of-3/5 includes it
        // End-of-3/4: before -100, after +50 = 550
        // End-of-3/3: includes +50 = 550
        // End-of-3/2: before +50 = 500
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
}
