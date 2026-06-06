import Foundation
import Money
import Models

/// Reconstructs day-by-day account balances from a "current balance" plus
/// the YNAB transaction history that produced it.
///
/// Algorithm: walk transactions newest-to-oldest, subtracting each amount from
/// the rolling balance to reproduce what the account looked like before that
/// transaction posted. Day-end balances are emitted between transitions.
public struct AccountHistoryReconstructor: Sendable {
    public let calendar: Calendar

    public init(calendar: Calendar = Calendar(identifier: .gregorian)) {
        self.calendar = calendar
    }

    public struct DailyBalance: Sendable, Hashable {
        public let date: Date
        public let balance: Money
        public init(date: Date, balance: Money) {
            self.date = date
            self.balance = balance
        }
    }

    public func reconstruct(
        currentBalance: Money,
        transactions: [TransactionSummary],
        from start: Date,
        to end: Date
    ) -> [DailyBalance] {
        let sorted = transactions
            .filter { !$0.deleted }
            .sorted { $0.date > $1.date }

        var balance = currentBalance
        var idx = 0
        var dailies: [DailyBalance] = []

        var day = calendar.startOfDay(for: end)
        let lowerBound = calendar.startOfDay(for: start)

        while day >= lowerBound {
            // Roll back any transactions that posted *after* end-of-`day` but
            // were already reflected in `balance`. After this loop, `balance`
            // represents end-of-`day`.
            while idx < sorted.count {
                let txn = sorted[idx]
                let txnDay = calendar.startOfDay(for: txn.date)
                if txnDay > day {
                    balance -= txn.amount
                    idx += 1
                } else {
                    break
                }
            }
            dailies.append(DailyBalance(date: day, balance: balance))
            guard let prev = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }

        return dailies.reversed()
    }
}

/// Rolls a per-account daily balance series into a single net-worth daily series.
public struct NetWorthHistoryAggregator: Sendable {
    public init() {}

    /// `dailyBalancesByAccount` keys account ID → daily balances in ascending date order.
    /// `kindsById` keys account ID → kind so we can sign cash vs. liability properly.
    public func aggregate(
        dailyBalancesByAccount: [String: [AccountHistoryReconstructor.DailyBalance]],
        kindsById: [String: AccountKind],
        manualAssetSeries: [Date: Money] = [:]
    ) -> [NetWorthSnapshot] {
        // Collect the union of dates we have data for.
        var allDates = Set<Date>()
        for series in dailyBalancesByAccount.values {
            for entry in series { allDates.insert(entry.date) }
        }
        for date in manualAssetSeries.keys { allDates.insert(date) }

        let dates = allDates.sorted()

        // Build a per-account lookup so we can slice fast.
        var lookup: [String: [Date: Money]] = [:]
        for (id, series) in dailyBalancesByAccount {
            var dict: [Date: Money] = [:]
            for entry in series { dict[entry.date] = entry.balance }
            lookup[id] = dict
        }

        var lastKnown: [String: Money] = [:]
        var snapshots: [NetWorthSnapshot] = []

        for date in dates {
            var assets = Money.zero
            var liabilities = Money.zero

            for (accountId, kind) in kindsById {
                if let balance = lookup[accountId]?[date] {
                    lastKnown[accountId] = balance
                }
                let value = lastKnown[accountId] ?? .zero
                if kind.isLiability {
                    liabilities += value.absolute
                } else {
                    assets += value
                }
            }

            assets += manualAssetSeries[date] ?? .zero
            snapshots.append(NetWorthSnapshot(date: date, assets: assets, liabilities: liabilities))
        }

        return snapshots
    }
}
