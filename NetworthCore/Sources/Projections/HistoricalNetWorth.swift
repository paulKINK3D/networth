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

    /// One durable daily balance observation for a Plaid investment account.
    /// `matchedManualAssetID == nil` means the account was counted as a
    /// standalone investment on that day. Inactive observations end a Plaid
    /// contribution so the history can return to the preserved manual value.
    public struct PlaidBalanceSnapshot: Sendable, Hashable {
        public let accountID: String
        public let matchedManualAssetID: UUID?
        public let date: Date
        public let balance: Money
        public let isActive: Bool
        public let recordedAt: Date

        public init(
            accountID: String,
            matchedManualAssetID: UUID? = nil,
            date: Date,
            balance: Money,
            isActive: Bool = true,
            recordedAt: Date? = nil
        ) {
            self.accountID = accountID
            self.matchedManualAssetID = matchedManualAssetID
            self.date = date
            self.balance = balance
            self.isActive = isActive
            self.recordedAt = recordedAt ?? date
        }
    }

    public let calendar: Calendar

    public init(calendar: Calendar = Calendar(identifier: .gregorian)) {
        self.calendar = calendar
    }

    public func build(
        accounts: [Account],
        manualAssets: [ManualAssetSnapshot],
        plaidSnapshots: [PlaidBalanceSnapshot] = [],
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
        let sortedPlaidSnapshots = plaidSnapshots.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            if lhs.recordedAt != rhs.recordedAt { return lhs.recordedAt < rhs.recordedAt }
            return lhs.accountID < rhs.accountID
        }
        let manualAssetIDs = manualAssets.map(\.id)

        var points: [Point] = []
        var day = firstDay
        var accountIndexes = Array(repeating: 0, count: accountSeries.count)
        var accountValues = Array(repeating: Money.zero, count: accountSeries.count)
        var manualIndexes = Array(repeating: 0, count: manualSeries.count)
        var manualValues = Array(repeating: Money.zero, count: manualSeries.count)
        var plaidIndex = 0
        var currentPlaidByAccountID: [String: PlaidBalanceSnapshot] = [:]

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

            while plaidIndex < sortedPlaidSnapshots.count,
                  calendar.startOfDay(for: sortedPlaidSnapshots[plaidIndex].date) <= day {
                let snapshot = sortedPlaidSnapshots[plaidIndex]
                currentPlaidByAccountID[snapshot.accountID] = snapshot
                plaidIndex += 1
            }

            var matchedPlaidTotals: [UUID: Money] = [:]
            var standalonePlaidTotal = Money.zero
            for snapshot in currentPlaidByAccountID.values where snapshot.isActive {
                if let manualAssetID = snapshot.matchedManualAssetID {
                    matchedPlaidTotals[manualAssetID, default: .zero] += snapshot.balance
                } else {
                    standalonePlaidTotal += snapshot.balance
                }
            }

            var effectiveManualTotal = Money.zero
            for index in manualValues.indices {
                effectiveManualTotal += matchedPlaidTotals[manualAssetIDs[index]]
                    ?? manualValues[index]
            }

            let accountTotal = accountValues.reduce(Money.zero, +)
            points.append(Point(
                date: day,
                value: accountTotal + effectiveManualTotal + standalonePlaidTotal
            ))

            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = nextDay
        }

        return points
    }
}

/// Builds the event list shown for one manual asset by combining its original
/// valuations with durable Plaid observations. Unlike the daily chart builder,
/// this preserves multiple manual entries on the same day and emits Plaid rows
/// only on days that were actually observed.
public struct ManualAssetHistoryBuilder: Sendable {
    public enum Source: Sendable, Hashable {
        case manual
        case plaid
        case manualFallback
    }

    public struct Point: Sendable, Hashable {
        public let date: Date
        public let value: Money
        public let note: String?
        public let source: Source

        public init(date: Date, value: Money, note: String?, source: Source) {
            self.date = date
            self.value = value
            self.note = note
            self.source = source
        }
    }

    public let calendar: Calendar

    public init(calendar: Calendar = Calendar(identifier: .gregorian)) {
        self.calendar = calendar
    }

    public func build(
        manualAsset: ManualAssetSnapshot,
        plaidSnapshots: [InvestmentHistoryBuilder.PlaidBalanceSnapshot]
    ) -> [Point] {
        var points = manualAsset.history.map {
            Point(date: $0.recordedAt, value: $0.value, note: $0.note, source: .manual)
        }

        let snapshotsByDay = Dictionary(grouping: plaidSnapshots) {
            calendar.startOfDay(for: $0.date)
        }
        var currentByAccountID: [String: InvestmentHistoryBuilder.PlaidBalanceSnapshot] = [:]
        var previouslyActiveAccountIDs: Set<String> = []

        for day in snapshotsByDay.keys.sorted() {
            let observations = (snapshotsByDay[day] ?? []).sorted { lhs, rhs in
                if lhs.recordedAt != rhs.recordedAt { return lhs.recordedAt < rhs.recordedAt }
                return lhs.accountID < rhs.accountID
            }
            let touchedAccountIDs = Set(observations.map(\.accountID))
            for observation in observations {
                currentByAccountID[observation.accountID] = observation
            }

            let activeForAsset = currentByAccountID.values.filter {
                $0.isActive && $0.matchedManualAssetID == manualAsset.id
            }
            let directlyReferencesAsset = observations.contains {
                $0.matchedManualAssetID == manualAsset.id
            }
            let endsPreviousContribution = !previouslyActiveAccountIDs.isDisjoint(
                with: touchedAccountIDs
            )

            if !activeForAsset.isEmpty {
                points.append(Point(
                    date: day,
                    value: activeForAsset.map(\.balance).reduce(.zero, +),
                    note: "Plaid balance",
                    source: .plaid
                ))
            } else if directlyReferencesAsset || endsPreviousContribution {
                points.append(Point(
                    date: day,
                    value: manualValue(for: manualAsset, on: day),
                    note: "Manual value resumed",
                    source: .manualFallback
                ))
            }

            previouslyActiveAccountIDs = Set(activeForAsset.map(\.accountID))
        }

        return points.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            return sourceOrder(lhs.source) < sourceOrder(rhs.source)
        }
    }

    private func manualValue(for asset: ManualAssetSnapshot, on date: Date) -> Money {
        let day = calendar.startOfDay(for: date)
        return asset.history
            .filter { calendar.startOfDay(for: $0.recordedAt) <= day }
            .max { $0.recordedAt < $1.recordedAt }?
            .value ?? .zero
    }

    private func sourceOrder(_ source: Source) -> Int {
        switch source {
        case .manual: return 0
        case .manualFallback: return 1
        case .plaid: return 2
        }
    }
}
