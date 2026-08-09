import Foundation
import Money

// MARK: - Goals

/// Lifecycle shape of a goal. One-time goals complete explicitly; refillable
/// goals stay active after spending; floor goals (emergency fund) are
/// maintained rather than finished.
public enum GoalKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case oneTime
    case refillable
    case floor

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .oneTime: "One-Time"
        case .refillable: "Refillable"
        case .floor: "Floor"
        }
    }
}

/// How a goal's target is determined.
public enum GoalTargetMode: String, Codable, Sendable, CaseIterable {
    /// User-entered fixed amount.
    case fixed
    /// Derived: months × median monthly ordinary spend × reduction percent.
    case emergencyMonths
}

/// A long-term savings goal backed by the shared reserve pool.
public struct Goal: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let kind: GoalKind
    public let targetMode: GoalTargetMode
    /// For `.fixed`, the user-entered target; for `.emergencyMonths`, the
    /// adopted (hysteresis-smoothed) derived target. Zero means open-ended.
    public let target: Money
    public let targetDate: Date?
    /// Used only for plan-sufficiency math; never auto-contributes.
    public let plannedMonthly: Money
    public let emergencyMonths: Int
    public let emergencyReductionPercent: Int
    public let archived: Bool
    public let completedAt: Date?

    public init(
        id: String,
        name: String,
        kind: GoalKind,
        targetMode: GoalTargetMode = .fixed,
        target: Money,
        targetDate: Date? = nil,
        plannedMonthly: Money = .zero,
        emergencyMonths: Int = 0,
        emergencyReductionPercent: Int = 100,
        archived: Bool = false,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.targetMode = targetMode
        self.target = target
        self.targetDate = targetDate
        self.plannedMonthly = plannedMonthly
        self.emergencyMonths = emergencyMonths
        self.emergencyReductionPercent = emergencyReductionPercent
        self.archived = archived
        self.completedAt = completedAt
    }

    /// Only active goals claim reserve allocation and receive suggestions.
    public var isActive: Bool { !archived && completedAt == nil }
}

// MARK: - Ledger

/// Every way money moves on a goal. The sign convention is intrinsic to the
/// kind; `GoalMath.balance` simply sums signed amounts.
public enum GoalLedgerKind: String, Codable, Sendable, CaseIterable {
    /// User adjustment; positive or negative. Positive counts toward MTD.
    case manual
    /// Transfer-linked deposit into the reserve, confirmed to this goal.
    /// Always positive. Counts toward MTD.
    case contribution
    /// Explicit spend from the goal, linked to a posted transaction.
    /// Always negative. Excluded from ordinary Spending via the adjuster.
    case purchase
    /// Refund confirmed back into the goal. Always positive. Never counts
    /// as a contribution.
    case purchaseRefund
    /// Money released from the goal back to unallocated. Always negative.
    case withdrawal
    /// Paired atomic goal-to-goal transfer legs. Net-zero across the pool,
    /// excluded from MTD, never touch Spending.
    case reallocationOut
    case reallocationIn

    /// Whether a positive entry of this kind counts as a month-to-date
    /// contribution.
    public var countsTowardMonthlyContributions: Bool {
        switch self {
        case .manual, .contribution: true
        case .purchase, .purchaseRefund, .withdrawal,
             .reallocationOut, .reallocationIn: false
        }
    }
}

/// One explicit goal movement. `linkedTransactionId` carries the provider
/// external id for transfer-linked contributions and purchase/refund links.
public struct GoalLedgerEntry: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let goalId: String
    public let date: Date
    public let amount: Money
    public let kind: GoalLedgerKind
    public let linkedTransactionId: String?
    public let note: String?
    public let createdAt: Date

    public init(
        id: String,
        goalId: String,
        date: Date,
        amount: Money,
        kind: GoalLedgerKind,
        linkedTransactionId: String? = nil,
        note: String? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.goalId = goalId
        self.date = date
        self.amount = amount
        self.kind = kind
        self.linkedTransactionId = linkedTransactionId
        self.note = note
        self.createdAt = createdAt
    }
}

// MARK: - Goal math

public enum GoalMath {
    public static func balance(entries: [GoalLedgerEntry]) -> Money {
        entries.map(\.amount).sum()
    }

    /// Plan-sufficiency status, reusing the shipped fund math. This compares
    /// the configured monthly plan with the required monthly amount — it is
    /// not a measurement of recent contributions.
    public static func status(
        goal: Goal,
        balance: Money,
        asOf: Date,
        calendar: Calendar = .current
    ) -> FundStatus {
        FundMath.status(
            fund: SinkingFund(
                id: goal.id,
                name: goal.name,
                target: goal.target,
                targetDate: goal.targetDate,
                plannedMonthly: goal.plannedMonthly,
                startDate: asOf
            ),
            balance: balance,
            asOf: asOf,
            calendar: calendar
        )
    }

    public static func progressFraction(
        balance: Money,
        target: Money
    ) -> Double? {
        FundMath.progressFraction(balance: balance, target: target)
    }

    /// This month's contributions: positive `.manual` and `.contribution`
    /// entries dated in `asOf`'s calendar month. Refund credits and
    /// reallocations never count.
    public static func monthToDateContributions(
        entries: [GoalLedgerEntry],
        asOf: Date,
        calendar: Calendar = .current
    ) -> Money {
        guard let month = calendar.dateInterval(of: .month, for: asOf) else {
            return .zero
        }
        return entries
            .filter {
                $0.kind.countsTowardMonthlyContributions
                    && $0.amount.milliunits > 0
                    && $0.date >= month.start && $0.date < month.end
            }
            .map(\.amount)
            .sum()
    }
}

// MARK: - Reserve pool

/// Computed truth for the shared reserve pool at a point in time.
public struct ReservePoolSummary: Hashable, Sendable {
    public let pool: Money
    public let allocated: Money
    public let unallocated: Money
    public let shortfall: Money

    public init(
        pool: Money, allocated: Money, unallocated: Money, shortfall: Money
    ) {
        self.pool = pool
        self.allocated = allocated
        self.unallocated = unallocated
        self.shortfall = shortfall
    }
}

public enum ReservePoolMath {
    /// `activeGoalBalances` must contain only active goals; negative balances
    /// never manufacture pool capacity.
    public static func summary(
        reserveBalance: Money,
        activeGoalBalances: [Money]
    ) -> ReservePoolSummary {
        let pool = max(reserveBalance, .zero)
        let allocated = Money(
            milliunits: activeGoalBalances
                .reduce(Int64(0)) { $0 + max(0, $1.milliunits) }
        )
        return ReservePoolSummary(
            pool: pool,
            allocated: allocated,
            unallocated: max(pool - allocated, .zero),
            shortfall: max(allocated - pool, .zero)
        )
    }

    /// New allocations are blocked while the pool is short, and can never
    /// exceed the unallocated remainder.
    public static func canAllocate(
        _ amount: Money,
        in summary: ReservePoolSummary
    ) -> Bool {
        amount.milliunits > 0
            && summary.shortfall.isZero
            && amount <= summary.unallocated
    }
}

// MARK: - Emergency fund math

public enum EmergencyFundMath {
    /// Milliunits in the rounding unit for adopted targets (nearest $100).
    public static let roundingUnitMilliunits: Int64 = 100_000
    /// Adoption threshold: the derived target must move at least this much…
    public static let adoptionFloorMilliunits: Int64 = 250_000
    /// …or at least this fraction of the current target.
    public static let adoptionFraction: Decimal = 0.05
    /// Fewer complete months than this ⇒ no derived median (manual fallback).
    public static let minimumSampleMonths = 2

    /// Median of complete-month ordinary totals. Nil below the sample floor.
    public static func medianOfCompleteMonths(_ totals: [Money]) -> Money? {
        guard totals.count >= minimumSampleMonths else { return nil }
        let sorted = totals.map(\.milliunits).sorted()
        let mid = sorted.count / 2
        let median: Int64 = sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
        return Money(milliunits: median)
    }

    /// months × median × reductionPercent/100, then rounded to the nearest
    /// $100 so adopted targets read as intentional numbers.
    public static func target(
        medianMonthly: Money,
        months: Int,
        reductionPercent: Int
    ) -> Money {
        guard months > 0, reductionPercent > 0,
              medianMonthly.milliunits > 0 else { return .zero }
        let raw = medianMonthly.scaled(
            by: Decimal(months) * Decimal(reductionPercent) / 100
        )
        return rounded(raw)
    }

    public static func rounded(_ amount: Money) -> Money {
        let unit = roundingUnitMilliunits
        let half = unit / 2
        let sign: Int64 = amount.milliunits < 0 ? -1 : 1
        let magnitude = abs(amount.milliunits)
        return Money(milliunits: sign * ((magnitude + half) / unit) * unit)
    }

    /// Hysteresis: adopt a newly derived (already rounded) target only when
    /// it moved at least $250 or 5% from the current adopted value. A zero
    /// current target always adopts (first derivation).
    public static func shouldAdopt(
        current: Money,
        derived: Money
    ) -> Bool {
        guard derived.milliunits > 0 else { return false }
        guard current.milliunits > 0 else { return true }
        let delta = abs(derived.milliunits - current.milliunits)
        guard delta > 0 else { return false }
        let fractionThreshold = current.scaled(by: adoptionFraction).milliunits
        return delta >= adoptionFloorMilliunits || delta >= fractionThreshold
    }
}

// MARK: - Goal purchase adjustment

/// Confirmed goal spending and refunds, keyed by the cached transaction row
/// id (already resolved from ledger external ids). Amounts are positive
/// milliunit magnitudes.
public struct GoalPurchaseAssignments: Sendable, Hashable {
    public let purchasesByTransactionId: [String: Int64]
    public let refundsByTransactionId: [String: Int64]

    public init(
        purchasesByTransactionId: [String: Int64] = [:],
        refundsByTransactionId: [String: Int64] = [:]
    ) {
        self.purchasesByTransactionId = purchasesByTransactionId
        self.refundsByTransactionId = refundsByTransactionId
    }

    public var isEmpty: Bool {
        purchasesByTransactionId.isEmpty && refundsByTransactionId.isEmpty
    }
}

/// Moves confirmed goal-funded portions of transactions out of their ordinary
/// categories and into the synthetic Goal Purchases group, before the builder
/// runs. The builder's sign matrix is untouched: adjusted entries are still
/// ordinary spending; the synthetic entries ride the same rules.
public enum GoalPurchaseAdjuster {
    public static let groupIdentity = "networth:goal-purchases"
    public static let groupName = "Goal Purchases"
    public static let categoryKey = "networth:goal-purchases:category"

    /// The assignable ceiling for one transaction: the sum of its negative
    /// ordinary-spending entries. Mixed-treatment splits have a smaller
    /// ceiling than the parent amount; nil-treatment incoming legs and
    /// transfer legs never count.
    public static func adjustableAmount(
        entries: [SpendingHistoryEntry],
        transactionId: String
    ) -> Money {
        Money(milliunits: entries.reduce(Int64(0)) { sum, entry in
            guard entry.transactionId == transactionId,
                  isConsumablePurchaseEntry(entry) else { return sum }
            return sum - entry.amountMilliunits
        })
    }

    /// Applies assignments and returns the adjusted entry list. Consumption
    /// is largest-magnitude-first with a stable tie-breaker (original array
    /// index, then category key). Fully consumed entries are dropped; the
    /// consumed portion re-emerges as Goal Purchases entries. Assignments
    /// exceeding the adjustable amount consume what exists and no more.
    public static func apply(
        entries: [SpendingHistoryEntry],
        assignments: GoalPurchaseAssignments
    ) -> [SpendingHistoryEntry] {
        guard !assignments.isEmpty else { return entries }

        // index -> consumed milliunits (positive magnitude)
        var consumedByIndex: [Int: Int64] = [:]
        // transactionId -> (date, purchaseConsumed, refundConsumed)
        var syntheticByTransaction:
            [String: (date: Date, purchase: Int64, refund: Int64)] = [:]

        func consume(
            transactionId: String,
            amount: Int64,
            candidates: [(index: Int, entry: SpendingHistoryEntry)],
            isRefund: Bool
        ) {
            guard amount > 0, !candidates.isEmpty else { return }
            var remaining = amount
            let ordered = candidates.sorted {
                let lhs = abs($0.entry.amountMilliunits)
                let rhs = abs($1.entry.amountMilliunits)
                if lhs != rhs { return lhs > rhs }
                if $0.index != $1.index { return $0.index < $1.index }
                return $0.entry.categoryKey < $1.entry.categoryKey
            }
            for candidate in ordered where remaining > 0 {
                let available = abs(candidate.entry.amountMilliunits)
                    - (consumedByIndex[candidate.index] ?? 0)
                guard available > 0 else { continue }
                let take = min(available, remaining)
                consumedByIndex[candidate.index, default: 0] += take
                remaining -= take
                var record = syntheticByTransaction[transactionId]
                    ?? (candidate.entry.date, 0, 0)
                if isRefund { record.refund += take }
                else { record.purchase += take }
                syntheticByTransaction[transactionId] = record
            }
        }

        for (transactionId, amount) in assignments.purchasesByTransactionId {
            let candidates = entries.enumerated().compactMap {
                index, entry -> (Int, SpendingHistoryEntry)? in
                guard entry.transactionId == transactionId,
                      isConsumablePurchaseEntry(entry) else { return nil }
                return (index, entry)
            }
            consume(
                transactionId: transactionId, amount: amount,
                candidates: candidates.map { (index: $0.0, entry: $0.1) },
                isRefund: false
            )
        }
        for (transactionId, amount) in assignments.refundsByTransactionId {
            let candidates = entries.enumerated().compactMap {
                index, entry -> (Int, SpendingHistoryEntry)? in
                guard entry.transactionId == transactionId,
                      isConsumableRefundEntry(entry) else { return nil }
                return (index, entry)
            }
            consume(
                transactionId: transactionId, amount: amount,
                candidates: candidates.map { (index: $0.0, entry: $0.1) },
                isRefund: true
            )
        }

        var adjusted: [SpendingHistoryEntry] = []
        adjusted.reserveCapacity(entries.count + syntheticByTransaction.count)
        for (index, entry) in entries.enumerated() {
            guard let consumed = consumedByIndex[index] else {
                adjusted.append(entry)
                continue
            }
            let magnitude = abs(entry.amountMilliunits) - consumed
            guard magnitude > 0 else { continue }
            let sign: Int64 = entry.amountMilliunits < 0 ? -1 : 1
            adjusted.append(SpendingHistoryEntry(
                transactionId: entry.transactionId,
                date: entry.date,
                amountMilliunits: sign * magnitude,
                treatment: entry.treatment,
                reportingRole: entry.reportingRole,
                groupIdentity: entry.groupIdentity,
                groupName: entry.groupName,
                categoryKey: entry.categoryKey,
                categoryName: entry.categoryName
            ))
        }
        for (transactionId, record) in syntheticByTransaction
            .sorted(by: { $0.key < $1.key }) {
            if record.purchase > 0 {
                adjusted.append(SpendingHistoryEntry(
                    transactionId: transactionId,
                    date: record.date,
                    amountMilliunits: -record.purchase,
                    treatment: .ordinarySpending,
                    reportingRole: .spending,
                    groupIdentity: groupIdentity,
                    groupName: groupName,
                    categoryKey: categoryKey,
                    categoryName: groupName
                ))
            }
            if record.refund > 0 {
                adjusted.append(SpendingHistoryEntry(
                    transactionId: transactionId,
                    date: record.date,
                    amountMilliunits: record.refund,
                    treatment: .refund,
                    reportingRole: .spending,
                    groupIdentity: groupIdentity,
                    groupName: groupName,
                    categoryKey: categoryKey,
                    categoryName: groupName
                ))
            }
        }
        return adjusted
    }

    private static func isConsumablePurchaseEntry(
        _ entry: SpendingHistoryEntry
    ) -> Bool {
        guard entry.amountMilliunits < 0,
              entry.groupIdentity != groupIdentity else { return false }
        switch entry.treatment {
        case .ordinarySpending, nil:
            return entry.reportingRole == nil
                || entry.reportingRole == .spending
        default:
            return false
        }
    }

    private static func isConsumableRefundEntry(
        _ entry: SpendingHistoryEntry
    ) -> Bool {
        entry.amountMilliunits > 0
            && entry.treatment == .refund
            && entry.groupIdentity != groupIdentity
            && (entry.reportingRole == nil
                || entry.reportingRole == .spending)
    }
}
