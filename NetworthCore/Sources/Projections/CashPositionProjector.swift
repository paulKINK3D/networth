import Foundation
import Money
import Models

/// Forecasts a daily cash-position curve for the union of cash-like accounts
/// over a horizon (default 90 days). Produces two curves:
///   - `scheduledPoints`: balance after applying expanded scheduled transactions only.
///   - `pointsWithVariable`: scheduled points minus a flat daily variable-spend drain
///     derived from recent historical debits (cash-account outflows minus scheduled
///     outflows in the same window, minus excluded categories).
///
/// Alerts fire against the more conservative `pointsWithVariable` curve when a
/// variable drain is supplied; otherwise they fall back to scheduled-only.
public struct CashPositionProjector: Sendable {
    public let calendar: Calendar

    public init(calendar: Calendar = Calendar(identifier: .gregorian)) {
        self.calendar = calendar
    }

    public struct AlertPoint: Sendable, Hashable, Identifiable {
        public var id: Date { date }
        public let date: Date
        public let balance: Money
        public let kind: Kind
        public enum Kind: String, Sendable, Hashable { case dip; case overdraft }
    }

    public struct Result: Sendable, Hashable {
        public let scheduledPoints: [CashPositionPoint]
        public let pointsWithVariable: [CashPositionPoint]
        public let alerts: [AlertPoint]
        /// Per-day variable cash flow (signed). Positive = net inflow exceeds
        /// outflow over the lookback window; negative = net drain. Applied
        /// daily to `pointsWithVariable`.
        public let dailyVariableNet: Money
        /// Whether `pointsWithVariable` differs from `scheduledPoints`.
        public var hasVariableProjection: Bool { !dailyVariableNet.isZero }

        /// Compatibility shim — positive magnitude of the net for legacy
        /// callers that display "drain". Use `dailyVariableNet` for sign.
        public var dailyVariableDrain: Money { dailyVariableNet.absolute }

        /// Back-compat alias — callers that only need a single curve get the
        /// scheduled + variable one.
        public var points: [CashPositionPoint] { pointsWithVariable }
    }

    public func project(
        cashAccounts: [AccountSnapshot],
        scheduled: [ScheduledTransactionSummary],
        historicalTransactions: [TransactionSummary] = [],
        excludedCategoryIds: Set<String> = [],
        outflowOnlyExcludedCategoryIds: Set<String> = [],
        spendAccountIds: Set<String> = [],
        lookbackDays: Int = 60,
        asOf today: Date,
        horizonDays: Int = 90,
        dipThreshold: Money = Money.dollars(500)
    ) -> Result {
        let start = calendar.startOfDay(for: today)
        guard let end = calendar.date(byAdding: .day, value: horizonDays, to: start) else {
            return Result(scheduledPoints: [], pointsWithVariable: [], alerts: [],
                          dailyVariableNet: .zero)
        }

        let cashIds = Set(cashAccounts.map(\.id))
        // Spend accounts are cash-like + CC-like. Default to cashIds when the
        // caller doesn't supply a wider set — preserves old behavior.
        let internalAccounts = spendAccountIds.isEmpty ? cashIds : spendAccountIds
        let startingBalance = cashAccounts.map(\.balance).sum()

        var scheduledByDay: [Date: Money] = [:]
        for sched in scheduled where !sched.deleted && cashIds.contains(sched.accountId) {
            // Skip scheduled transfers between two internal spend accounts —
            // they net to zero in cash position. (One side is enough; YNAB
            // typically records both sides.)
            if let xfer = sched.transferAccountId, internalAccounts.contains(xfer) {
                continue
            }
            for occ in sched.occurrences(from: start, through: end, calendar: calendar) {
                let day = calendar.startOfDay(for: occ)
                scheduledByDay[day, default: .zero] += sched.amount
            }
        }

        let dailyNet = computeDailyVariableNet(
            cashAccountIds: cashIds,
            scheduled: scheduled,
            historicalTransactions: historicalTransactions,
            excludedCategoryIds: excludedCategoryIds,
            outflowOnlyExcludedCategoryIds: outflowOnlyExcludedCategoryIds,
            spendAccountIds: internalAccounts,
            lookbackDays: lookbackDays,
            asOf: start
        )

        var scheduledPoints: [CashPositionPoint] = []
        var combinedPoints: [CashPositionPoint] = []
        var alerts: [AlertPoint] = []

        var scheduledBalance = startingBalance
        var combinedBalance = startingBalance
        var cursor = start
        while cursor <= end {
            if let delta = scheduledByDay[cursor] {
                scheduledBalance += delta
                combinedBalance += delta
            }
            // Apply variable net after the start day so today's snapshot is unmodified.
            // Signed: positive = adds to balance, negative = drains.
            if cursor > start {
                combinedBalance += dailyNet
            }
            scheduledPoints.append(CashPositionPoint(date: cursor, balance: scheduledBalance))
            combinedPoints.append(CashPositionPoint(date: cursor, balance: combinedBalance))

            if combinedBalance < .zero {
                alerts.append(AlertPoint(date: cursor, balance: combinedBalance, kind: .overdraft))
            } else if combinedBalance < dipThreshold {
                alerts.append(AlertPoint(date: cursor, balance: combinedBalance, kind: .dip))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        return Result(
            scheduledPoints: scheduledPoints,
            pointsWithVariable: combinedPoints,
            alerts: alerts,
            dailyVariableNet: dailyNet
        )
    }

    /// Estimate the per-day **net** variable cash flow on the cash-account union.
    /// Signed: positive = net inflow (refunds, side gigs, etc. outweigh
    /// outflows), negative = net drain. Built from historical signed amounts
    /// minus the scheduled portion already counted, then divided by lookback.
    ///
    /// A transfer is "internal" only when its `transferAccountId` points to
    /// another on-budget spend account (cash or CC). Categorized transfers to
    /// off-budget tracking accounts ARE counted — they're real flows.
    public func computeDailyVariableNet(
        cashAccountIds: Set<String>,
        scheduled: [ScheduledTransactionSummary],
        historicalTransactions: [TransactionSummary],
        excludedCategoryIds: Set<String>,
        outflowOnlyExcludedCategoryIds: Set<String> = [],
        spendAccountIds: Set<String> = [],
        lookbackDays: Int,
        asOf today: Date
    ) -> Money {
        let lookback = max(1, lookbackDays)
        let startOfDay = calendar.startOfDay(for: today)
        guard let windowStart = calendar.date(byAdding: .day, value: -lookback, to: startOfDay) else {
            return .zero
        }
        let internalAccounts = spendAccountIds.isEmpty ? cashAccountIds : spendAccountIds

        // Returns true if a leg with this category + sign should be skipped.
        // `excludedCategoryIds` applies to both directions (user-explicit).
        // `outflowOnlyExcludedCategoryIds` applies only when amount < 0 — used
        // for YNAB-hidden categories so "Inflow: Ready to Assign" (hidden)
        // still counts toward inflows.
        func isExcluded(categoryId: String?, amountMU: Int64) -> Bool {
            guard let cid = categoryId else { return false }
            if excludedCategoryIds.contains(cid) { return true }
            if amountMU < 0 && outflowOnlyExcludedCategoryIds.contains(cid) { return true }
            return false
        }

        // 1. Sum signed flows across the cash-account union (positive = inflow,
        // negative = outflow). Splits decompose into their subs so per-leg
        // categories and transfer destinations apply.
        //
        // Only transfers between two on-budget *spend* accounts (cash↔cash,
        // cash↔CC) are skipped — those don't change overall spending or cash
        // capacity. Transfers to/from off-budget accounts (brokerage, etc.)
        // are real cash leaving/entering the user's cash universe and need to
        // be counted. If a one-off off-budget transfer pollutes the smoothed
        // rate, the user can exclude its category via Settings → Excluded
        // Categories.
        var totalSignedMU: Int64 = 0
        for txn in historicalTransactions where !txn.deleted && cashAccountIds.contains(txn.accountId) {
            guard txn.date >= windowStart, txn.date < startOfDay else { continue }
            if txn.isSplit {
                for sub in txn.subtransactions where !sub.deleted {
                    if let xfer = sub.transferAccountId, internalAccounts.contains(xfer) { continue }
                    if isExcluded(categoryId: sub.categoryId, amountMU: sub.amount.milliunits) { continue }
                    totalSignedMU += sub.amount.milliunits
                }
            } else {
                if let xfer = txn.transferAccountId, internalAccounts.contains(xfer) { continue }
                if isExcluded(categoryId: txn.categoryId, amountMU: txn.amount.milliunits) { continue }
                totalSignedMU += txn.amount.milliunits
            }
        }

        // 2. Sum signed scheduled occurrences over the same window so we don't
        // double-count the scheduled-only curve.
        var scheduledSignedMU: Int64 = 0
        for sched in scheduled where !sched.deleted && cashAccountIds.contains(sched.accountId) {
            if let xfer = sched.transferAccountId, internalAccounts.contains(xfer) { continue }
            for occ in sched.occurrences(from: windowStart, through: startOfDay, calendar: calendar) {
                guard occ < startOfDay else { continue }
                scheduledSignedMU += sched.amount.milliunits
            }
        }

        let netMU = totalSignedMU - scheduledSignedMU
        guard netMU != 0 else { return .zero }
        return Money(milliunits: netMU / Int64(lookback))
    }
}
