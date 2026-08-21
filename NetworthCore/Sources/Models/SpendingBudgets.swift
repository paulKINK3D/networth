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
        target: Money
    ) {
        self.groupIdentity = groupIdentity
        self.groupName = groupName
        self.spent = spent
        self.target = target
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
        orderIndex: (String) -> Int = { _ in Int.max }
    ) -> SpendingBudgetSummary {
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
            return SpendingGroupBudgetSnapshot(
                groupIdentity: group.id,
                groupName: group.name,
                spent: spent,
                target: rule.target
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
