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

/// Builds a combined investment balance history from reconstructed YNAB
/// accounts and point-in-time manual valuations.
public struct InvestmentHistoryBuilder: Sendable {
    public struct Account: Sendable, Hashable {
        public let id: String
        public let currentBalance: Money
        public let transactions: [TransactionSummary]

        public init(id: String, currentBalance: Money, transactions: [TransactionSummary]) {
            self.id = id
            self.currentBalance = currentBalance
            self.transactions = transactions
        }
    }

    public struct Point: Sendable, Hashable, Identifiable {
        public var id: Date { date }
        public let date: Date
        public let value: Money

        public init(date: Date, value: Money) {
            self.date = date
            self.value = value
        }
    }

    public let calendar: Calendar

    public init(calendar: Calendar = Calendar(identifier: .gregorian)) {
        self.calendar = calendar
    }

    public func build(
        accounts: [Account],
        manualAssets: [ManualAssetSnapshot],
        from start: Date,
        to end: Date
    ) -> [Point] {
        let firstDay = calendar.startOfDay(for: start)
        let lastDay = calendar.startOfDay(for: end)
        guard firstDay <= lastDay else { return [] }

        let reconstructor = AccountHistoryReconstructor(calendar: calendar)
        let accountSeries = accounts.map { account in
            reconstructor.reconstruct(
                currentBalance: account.currentBalance,
                transactions: account.transactions,
                from: firstDay,
                to: lastDay
            )
        }
        let manualSeries = manualAssets.map { asset in
            asset.history.sorted { $0.recordedAt < $1.recordedAt }
        }

        var points: [Point] = []
        var day = firstDay
        var accountIndexes = Array(repeating: 0, count: accountSeries.count)
        var accountValues = Array(repeating: Money.zero, count: accountSeries.count)
        var manualIndexes = Array(repeating: 0, count: manualSeries.count)
        var manualValues = Array(repeating: Money.zero, count: manualSeries.count)

        while day <= lastDay {
            for index in accountSeries.indices {
                let series = accountSeries[index]
                while accountIndexes[index] < series.count,
                      calendar.startOfDay(for: series[accountIndexes[index]].date) <= day {
                    accountValues[index] = series[accountIndexes[index]].balance
                    accountIndexes[index] += 1
                }
            }

            for index in manualSeries.indices {
                let series = manualSeries[index]
                while manualIndexes[index] < series.count,
                      calendar.startOfDay(for: series[manualIndexes[index]].recordedAt) <= day {
                    manualValues[index] = series[manualIndexes[index]].value
                    manualIndexes[index] += 1
                }
            }

            let accountTotal = accountValues.reduce(Money.zero, +)
            let manualTotal = manualValues.reduce(Money.zero, +)
            points.append(Point(date: day, value: accountTotal + manualTotal))

            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = nextDay
        }

        return points
    }
}
