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

    @Test func investmentHistoryCombinesAccountsAndCarriesManualValuesForward() {
        let account = InvestmentHistoryBuilder.Account(
            id: "BROKERAGE",
            currentBalance: Money.dollars(1_200),
            transactions: [
                txn(
                    accountId: "BROKERAGE",
                    date: day(2026, 3, 3),
                    amount: Money.dollars(200)
                )
            ]
        )
        let manual = ManualAssetSnapshot(
            id: UUID(),
            name: "401k",
            kind: .retirement,
            currentValue: Money.dollars(2_500),
            lastUpdatedAt: day(2026, 3, 4),
            history: [
                ManualAssetValueEntry(recordedAt: day(2026, 3, 2), value: Money.dollars(2_000)),
                ManualAssetValueEntry(recordedAt: day(2026, 3, 4), value: Money.dollars(2_500))
            ]
        )

        let points = InvestmentHistoryBuilder(calendar: utc).build(
            accounts: [account],
            manualAssets: [manual],
            from: day(2026, 3, 1),
            to: day(2026, 3, 5)
        )
        let byDay = Dictionary(uniqueKeysWithValues: points.map { ($0.date, $0.value) })

        #expect(byDay[day(2026, 3, 1)] == Money.dollars(1_000))
        #expect(byDay[day(2026, 3, 2)] == Money.dollars(3_000))
        #expect(byDay[day(2026, 3, 3)] == Money.dollars(3_200))
        #expect(byDay[day(2026, 3, 4)] == Money.dollars(3_700))
        #expect(byDay[day(2026, 3, 5)] == Money.dollars(3_700))
    }

    @Test func investmentHistoryReturnsNoPointsForAnInvalidRange() {
        let points = InvestmentHistoryBuilder(calendar: utc).build(
            accounts: [],
            manualAssets: [],
            from: day(2026, 3, 2),
            to: day(2026, 3, 1)
        )

        #expect(points.isEmpty)
    }

    @Test func investmentHistoryUsesPlaidOnlyWhileMatchIsActive() {
        let manualID = UUID()
        let manual = ManualAssetSnapshot(
            id: manualID,
            name: "401k",
            kind: .retirement,
            currentValue: Money.dollars(2_500),
            lastUpdatedAt: day(2026, 3, 1),
            history: [
                ManualAssetValueEntry(
                    recordedAt: day(2026, 3, 1),
                    value: Money.dollars(2_500)
                )
            ]
        )
        let plaid = [
            InvestmentHistoryBuilder.PlaidBalanceSnapshot(
                accountID: "ROBINHOOD-IRA",
                matchedManualAssetID: manualID,
                date: day(2026, 3, 3),
                balance: Money.dollars(2_700)
            ),
            InvestmentHistoryBuilder.PlaidBalanceSnapshot(
                accountID: "ROBINHOOD-BROKERAGE",
                matchedManualAssetID: manualID,
                date: day(2026, 3, 3),
                balance: Money.dollars(300)
            ),
            InvestmentHistoryBuilder.PlaidBalanceSnapshot(
                accountID: "ROBINHOOD-IRA",
                matchedManualAssetID: manualID,
                date: day(2026, 3, 4),
                balance: Money.dollars(2_800)
            ),
            InvestmentHistoryBuilder.PlaidBalanceSnapshot(
                accountID: "ROBINHOOD-IRA",
                matchedManualAssetID: manualID,
                date: day(2026, 3, 5),
                balance: Money.dollars(2_800),
                isActive: false
            ),
            InvestmentHistoryBuilder.PlaidBalanceSnapshot(
                accountID: "ROBINHOOD-BROKERAGE",
                matchedManualAssetID: manualID,
                date: day(2026, 3, 5),
                balance: Money.dollars(300),
                isActive: false
            )
        ]

        let points = InvestmentHistoryBuilder(calendar: utc).build(
            accounts: [],
            manualAssets: [manual],
            plaidSnapshots: plaid,
            from: day(2026, 3, 1),
            to: day(2026, 3, 6)
        )
        let byDay = Dictionary(uniqueKeysWithValues: points.map { ($0.date, $0.value) })

        #expect(byDay[day(2026, 3, 2)] == Money.dollars(2_500))
        #expect(byDay[day(2026, 3, 3)] == Money.dollars(3_000))
        #expect(byDay[day(2026, 3, 4)] == Money.dollars(3_100))
        #expect(byDay[day(2026, 3, 5)] == Money.dollars(2_500))
        #expect(byDay[day(2026, 3, 6)] == Money.dollars(2_500))
    }

    @Test func investmentHistoryStopsStandalonePlaidAfterInactiveSnapshot() {
        let plaid = [
            InvestmentHistoryBuilder.PlaidBalanceSnapshot(
                accountID: "STANDALONE",
                date: day(2026, 3, 2),
                balance: Money.dollars(900)
            ),
            InvestmentHistoryBuilder.PlaidBalanceSnapshot(
                accountID: "STANDALONE",
                date: day(2026, 3, 4),
                balance: Money.dollars(900),
                isActive: false
            )
        ]

        let points = InvestmentHistoryBuilder(calendar: utc).build(
            accounts: [],
            manualAssets: [],
            plaidSnapshots: plaid,
            from: day(2026, 3, 1),
            to: day(2026, 3, 5)
        )
        let byDay = Dictionary(uniqueKeysWithValues: points.map { ($0.date, $0.value) })

        #expect(byDay[day(2026, 3, 1)] == .zero)
        #expect(byDay[day(2026, 3, 2)] == Money.dollars(900))
        #expect(byDay[day(2026, 3, 3)] == Money.dollars(900))
        #expect(byDay[day(2026, 3, 4)] == .zero)
        #expect(byDay[day(2026, 3, 5)] == .zero)
    }

    @Test func manualAssetDetailHistoryCombinesManualPlaidAndFallbackEvents() {
        let manualID = UUID()
        let manual = ManualAssetSnapshot(
            id: manualID,
            name: "Vanguard",
            kind: .other,
            currentValue: Money.dollars(10_000),
            lastUpdatedAt: day(2026, 3, 2),
            history: [
                ManualAssetValueEntry(
                    recordedAt: day(2026, 3, 1),
                    value: Money.dollars(9_000),
                    note: "Original"
                ),
                ManualAssetValueEntry(
                    recordedAt: day(2026, 3, 2),
                    value: Money.dollars(10_000)
                )
            ]
        )
        let plaid = [
            InvestmentHistoryBuilder.PlaidBalanceSnapshot(
                accountID: "one",
                matchedManualAssetID: manualID,
                date: day(2026, 3, 3),
                balance: Money.dollars(6_000)
            ),
            InvestmentHistoryBuilder.PlaidBalanceSnapshot(
                accountID: "two",
                matchedManualAssetID: manualID,
                date: day(2026, 3, 3),
                balance: Money.dollars(5_000)
            ),
            InvestmentHistoryBuilder.PlaidBalanceSnapshot(
                accountID: "one",
                matchedManualAssetID: manualID,
                date: day(2026, 3, 4),
                balance: Money.dollars(6_500)
            ),
            InvestmentHistoryBuilder.PlaidBalanceSnapshot(
                accountID: "two",
                matchedManualAssetID: manualID,
                date: day(2026, 3, 4),
                balance: Money.dollars(5_000),
                isActive: false
            ),
            InvestmentHistoryBuilder.PlaidBalanceSnapshot(
                accountID: "one",
                matchedManualAssetID: manualID,
                date: day(2026, 3, 5),
                balance: Money.dollars(6_500),
                isActive: false
            )
        ]

        let points = ManualAssetHistoryBuilder(calendar: utc).build(
            manualAsset: manual,
            plaidSnapshots: plaid
        )

        #expect(points.map(\.source) == [
            .manual, .manual, .plaid, .plaid, .manualFallback
        ])
        #expect(points.map(\.value) == [
            Money.dollars(9_000),
            Money.dollars(10_000),
            Money.dollars(11_000),
            Money.dollars(6_500),
            Money.dollars(10_000)
        ])
    }

    @Test func investmentHistoryKeepsTransfersBetweenOpenAndClosedAccountsFlat() {
        let oldId = "OLD_BROKERAGE"
        let newId = "NEW_BROKERAGE"
        let transferDate = day(2026, 3, 3)
        let accounts = [
            InvestmentHistoryBuilder.Account(
                id: oldId,
                currentBalance: .zero,
                transactions: [
                    txn(
                        accountId: oldId,
                        date: transferDate,
                        amount: Money.dollars(-5_000),
                        transferAccountId: newId
                    )
                ]
            ),
            InvestmentHistoryBuilder.Account(
                id: newId,
                currentBalance: Money.dollars(5_000),
                transactions: [
                    txn(
                        accountId: newId,
                        date: transferDate,
                        amount: Money.dollars(5_000),
                        transferAccountId: oldId
                    )
                ]
            )
        ]

        let points = InvestmentHistoryBuilder(calendar: utc).build(
            accounts: accounts,
            manualAssets: [],
            from: day(2026, 3, 1),
            to: day(2026, 3, 5)
        )

        #expect(points.allSatisfy { $0.value == Money.dollars(5_000) })
    }
}
