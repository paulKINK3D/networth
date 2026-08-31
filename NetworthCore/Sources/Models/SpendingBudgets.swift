import Foundation
import Money

/// One effective-dated monthly target for a user-owned Spending group.
/// The newest rule at or before a month applies until another rule replaces it.
public struct SpendingGroupBudgetRule: Identifiable, Hashable, Sendable {
    public let id: String
    public let groupIdentity: String
    public let effectiveMonth: BudgetMonth
    public let target: Money
    public let enabled: Bool
    public let updatedAt: Date

    public init(
        id: String,
        groupIdentity: String,
        effectiveMonth: BudgetMonth,
        target: Money,
        enabled: Bool,
        updatedAt: Date
    ) {
        self.id = id
        self.groupIdentity = groupIdentity
        self.effectiveMonth = effectiveMonth
        self.target = target
        self.enabled = enabled
        self.updatedAt = updatedAt
    }
}

/// Factual amounts for one group in one month. Calendar pace is evaluated
/// separately and never extrapolated into a projected finish.
public struct SpendingGroupBudgetSnapshot: Identifiable, Hashable, Sendable {
    public let groupIdentity: String
    public let groupName: String
    public let spent: Money
    /// The repeating target before one-month savings reallocations.
    public let baseTarget: Money
    /// Amount moved into this group from another budget for this month only.
    public let additionalTarget: Money
    /// Amount moved out of this group for this month only.
    public let reallocatedOut: Money
    public let target: Money

    public var id: String { groupIdentity }
    public var remaining: Money { target - spent }
    public var isOver: Bool { remaining.isNegative }
    public var progress: Double {
        guard target.milliunits > 0 else { return 0 }
        return max(0, Double(spent.milliunits) / Double(target.milliunits))
    }

    public init(
        groupIdentity: String,
        groupName: String,
        spent: Money,
        target: Money,
        baseTarget: Money? = nil,
        additionalTarget: Money = .zero,
        reallocatedOut: Money = .zero
    ) {
        self.groupIdentity = groupIdentity
        self.groupName = groupName
        self.spent = spent
        self.baseTarget = baseTarget ?? target
        self.additionalTarget = additionalTarget
        self.reallocatedOut = reallocatedOut
        self.target = target
    }
}

/// One user-recorded decision to move this month's budget from an ordinary
/// group into the designated Savings group. It changes allocation only; no
/// bank balance or transaction is created.
public struct SavingsBudgetChoice: Identifiable, Hashable, Sendable {
    public let id: String
    public let month: BudgetMonth
    public let sourceGroupIdentity: String
    public let savingsGroupIdentity: String
    public let amount: Money
    public let note: String
    public let occurredAt: Date
    public let updatedAt: Date

    public init(
        id: String,
        month: BudgetMonth,
        sourceGroupIdentity: String,
        savingsGroupIdentity: String,
        amount: Money,
        note: String,
        occurredAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.month = month
        self.sourceGroupIdentity = sourceGroupIdentity
        self.savingsGroupIdentity = savingsGroupIdentity
        self.amount = amount
        self.note = note
        self.occurredAt = occurredAt
        self.updatedAt = updatedAt
    }
}

/// A factual comparison between budget used and calendar time elapsed.
/// This never projects a finish or uses historical spending behavior.
public enum SpendingBudgetPaceStatus: String, Hashable, Sendable {
    case onTrack
    case watch
    case atRisk
}

public struct SpendingBudgetPaceEvaluator: Sendable {
    /// Spending more than ten percentage points ahead of the calendar is a
    /// material risk; any smaller lead is worth watching.
    public static let atRiskLead: Double = 0.10

    public init() {}

    public func status(
        progress: Double,
        month: BudgetMonth,
        now: Date,
        calendar: Calendar = .current
    ) -> SpendingBudgetPaceStatus {
        let progress = max(progress, 0)
        if progress > 1 { return .atRisk }

        let currentMonth = BudgetMonth(containing: now, calendar: calendar)
        if month < currentMonth { return .onTrack }
        if month > currentMonth { return .onTrack }

        let interval = month.interval(calendar: calendar)
        let duration = max(interval.duration, 1)
        let elapsed = min(
            max(now.timeIntervalSince(interval.start) / duration, 0),
            1
        )
        let lead = progress - elapsed
        if lead <= 0 { return .onTrack }
        if lead <= Self.atRiskLead { return .watch }
        return .atRisk
    }
}

public struct SpendingBudgetSummary: Hashable, Sendable {
    public let groups: [SpendingGroupBudgetSnapshot]

    public init(groups: [SpendingGroupBudgetSnapshot]) {
        self.groups = groups
    }

    public var spent: Money { groups.map(\.spent).sum() }
    public var target: Money { groups.map(\.target).sum() }
    public var remaining: Money { target - spent }
    public var isOver: Bool { remaining.isNegative }
    public var progress: Double {
        guard target.milliunits > 0 else { return 0 }
        return max(0, Double(spent.milliunits) / Double(target.milliunits))
    }
}

public struct SpendingGroupBudgetResolver: Sendable {
    public init() {}

    /// Resolves CloudKit duplicates deterministically: later effective month,
    /// then later update time, then stable row identity wins.
    public func activeRule(
        for groupIdentity: String,
        month: BudgetMonth,
        rules: [SpendingGroupBudgetRule]
    ) -> SpendingGroupBudgetRule? {
        rules
            .filter {
                $0.groupIdentity == groupIdentity
                    && $0.effectiveMonth <= month
            }
            .max(by: rulePrecedes)
    }

    public func summary(
        for month: BudgetMonth,
        groups: [SpendingHistoryGroupTotal],
        rules: [SpendingGroupBudgetRule],
        savingsChoices: [SavingsBudgetChoice] = [],
        orderIndex: (String) -> Int = { _ in Int.max }
    ) -> SpendingBudgetSummary {
        let choices = savingsChoices.filter {
            $0.month == month && $0.amount > .zero
        }
        let incomingByGroup = Dictionary(grouping: choices) {
            $0.savingsGroupIdentity
        }.mapValues { $0.map(\.amount).sum() }
        let outgoingByGroup = Dictionary(grouping: choices) {
            $0.sourceGroupIdentity
        }.mapValues { $0.map(\.amount).sum() }

        let snapshots: [SpendingGroupBudgetSnapshot] = groups.compactMap { group in
            guard let rule = activeRule(
                for: group.id,
                month: month,
                rules: rules
            ), rule.enabled, rule.target.milliunits > 0 else {
                return nil
            }
            // A net refund restores the full monthly target. It never creates
            // extra budget or offsets another group's spending.
            let spent = Money(milliunits: max(0, group.spentMilliunits))
            let additional = incomingByGroup[group.id] ?? .zero
            let reallocatedOut = outgoingByGroup[group.id] ?? .zero
            let effectiveTarget = rule.target + additional - reallocatedOut
            return SpendingGroupBudgetSnapshot(
                groupIdentity: group.id,
                groupName: group.name,
                spent: spent,
                target: Money(
                    milliunits: max(0, effectiveTarget.milliunits)
                ),
                baseTarget: rule.target,
                additionalTarget: additional,
                reallocatedOut: reallocatedOut
            )
        }
        .sorted {
            let lhs = orderIndex($0.groupIdentity)
            let rhs = orderIndex($1.groupIdentity)
            if lhs != rhs { return lhs < rhs }
            return $0.groupName.localizedCaseInsensitiveCompare($1.groupName)
                == .orderedAscending
        }
        return SpendingBudgetSummary(groups: snapshots)
    }

    /// The amount that can still be reallocated from an ordinary budget into
    /// Savings after this month's actual spending and existing choices.
    public func availableForSavingsChoice(
        from source: SpendingGroupBudgetSnapshot,
        month: BudgetMonth,
        choices: [SavingsBudgetChoice],
        excludingChoiceID: String? = nil
    ) -> Money {
        let alreadyMoved = choices.filter {
            $0.month == month
                && $0.sourceGroupIdentity == source.groupIdentity
                && $0.id != excludingChoiceID
                && $0.amount > .zero
        }.map(\.amount).sum()
        let available = source.baseTarget - source.spent - alreadyMoved
        return available > .zero ? available : .zero
    }

    private func rulePrecedes(
        _ lhs: SpendingGroupBudgetRule,
        _ rhs: SpendingGroupBudgetRule
    ) -> Bool {
        if lhs.effectiveMonth != rhs.effectiveMonth {
            return lhs.effectiveMonth < rhs.effectiveMonth
        }
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt < rhs.updatedAt
        }
        return lhs.id < rhs.id
    }
}
