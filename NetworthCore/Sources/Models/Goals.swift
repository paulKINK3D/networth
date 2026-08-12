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
    /// Derived: months × average monthly ordinary spend × reduction percent.
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

    /// Resolves one optional catch-all goal from the live reserve balance.
    /// Explicit goal balances keep their stored values; the residual goal
    /// receives whatever remains, so account growth automatically flows to
    /// it without creating allocation events.
    public static func effectiveBalances(
        reserveBalance: Money,
        activeGoalIds: [String],
        residualGoalId: String?,
        rawBalances: [String: Money]
    ) -> [String: Money] {
        var result = Dictionary(uniqueKeysWithValues: activeGoalIds.map {
            ($0, rawBalances[$0] ?? .zero)
        })
        guard let residualGoalId,
              activeGoalIds.contains(residualGoalId) else { return result }
        let explicitTotal = activeGoalIds.reduce(Int64(0)) { total, id in
            guard id != residualGoalId else { return total }
            return total + max(0, result[id]?.milliunits ?? 0)
        }
        result[residualGoalId] = Money(
            milliunits: max(0, reserveBalance.milliunits - explicitTotal)
        )
        return result
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
    /// Fewer complete months than this ⇒ no derived mean (manual fallback).
    public static let minimumSampleMonths = 2

    /// Arithmetic mean of complete-month ordinary totals. Nil below the
    /// sample floor. Lumpy purchases and timing shifts remain represented.
    public static func meanOfCompleteMonths(_ totals: [Money]) -> Money? {
        guard totals.count >= minimumSampleMonths else { return nil }
        return BudgetDateMath.mean(of: totals)
    }

    /// months × mean × reductionPercent/100, then rounded to the nearest
    /// $100 so adopted targets read as intentional numbers.
    public static func target(
        averageMonthly: Money,
        months: Int,
        reductionPercent: Int
    ) -> Money {
        guard months > 0, reductionPercent > 0,
              averageMonthly.milliunits > 0 else { return .zero }
        let raw = averageMonthly.scaled(
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
