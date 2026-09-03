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

/// Effective-dated selection of the one budget group that receives the
/// signed remainder after every other repeating target is assigned.
public struct SpendingRemainderRule: Identifiable, Hashable, Sendable {
    public let id: String
    public let groupIdentity: String
    public let effectiveMonth: BudgetMonth
    public let enabled: Bool
    public let updatedAt: Date

    public init(
        id: String,
        groupIdentity: String,
        effectiveMonth: BudgetMonth,
        enabled: Bool,
        updatedAt: Date
    ) {
        self.id = id
        self.groupIdentity = groupIdentity
        self.effectiveMonth = effectiveMonth
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
    /// Amount moved from this group into Savings for this month only.
    public let reallocatedToSavings: Money
    /// Amount moved from this group into Reserves for this month only.
    public let reallocatedToReserves: Money
    public let target: Money

    public var reallocatedOut: Money {
        reallocatedToSavings + reallocatedToReserves
    }

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
        reallocatedToSavings: Money = .zero,
        reallocatedToReserves: Money = .zero
    ) {
        self.groupIdentity = groupIdentity
        self.groupName = groupName
        self.spent = spent
        self.baseTarget = baseTarget ?? target
        self.additionalTarget = additionalTarget
        self.reallocatedToSavings = reallocatedToSavings
        self.reallocatedToReserves = reallocatedToReserves
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

public struct SavingsMonthStatus: Identifiable, Hashable, Sendable {
    public let month: BudgetMonth
    public let target: Money
    public let saved: Money

    public var id: String { month.id }
    public var outstanding: Money {
        let value = target - saved
        return value > .zero ? value : .zero
    }
}

/// Resolves the closed Savings obligations without rolling one month into the
/// next. Callers supply only explicitly recognized Savings activity.
public struct SavingsMonthStatusResolver: Sendable {
    public init() {}

    public func statuses(
        groupIdentity: String,
        rules: [SpendingGroupBudgetRule],
        choices: [SavingsBudgetChoice],
        savedByMonth: [BudgetMonth: Money],
        through endMonth: BudgetMonth
    ) -> [SavingsMonthStatus] {
        let relevantRules = rules.filter {
            $0.groupIdentity == groupIdentity
                && $0.effectiveMonth <= endMonth
        }
        let relevantChoices = choices.filter {
            $0.savingsGroupIdentity == groupIdentity
                && $0.month <= endMonth
                && $0.amount > .zero
        }
        let starts = relevantRules.map(\.effectiveMonth)
            + relevantChoices.map(\.month)
            + savedByMonth.keys.filter { $0 <= endMonth }
        guard var month = starts.min() else { return [] }
        let budgetResolver = SpendingGroupBudgetResolver()
        var result: [SavingsMonthStatus] = []
        while month <= endMonth {
            let rule = budgetResolver.activeRule(
                for: groupIdentity,
                month: month,
                rules: relevantRules
            )
            let baseTarget = rule?.enabled == true ? rule?.target ?? .zero : .zero
            let additional = relevantChoices.filter { $0.month == month }
                .map(\.amount).sum()
            let saved = savedByMonth[month] ?? .zero
            let target = baseTarget + additional
            if target > .zero || saved > .zero {
                result.append(SavingsMonthStatus(
                    month: month,
                    target: target,
                    saved: saved
                ))
            }
            month = month.next
        }
        return result
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

    /// Reconciles the funding strip from the same remaining budget balances
    /// shown on screen. Reserve assignments are already reflected in group
    /// targets, so they reduce Retained exactly once; later Reserve-funded
    /// purchases remain outside this summary.
    public func fundingDisplay(
        fundedBy income: Money?
    ) -> SpendingHistoryFundingDisplay {
        let funded = income.map {
            Money(milliunits: SpendingHistoryMonth.roundedWholeDollar(
                $0.milliunits
            ))
        }
        guard let funded else {
            return SpendingHistoryFundingDisplay(
                fundedHeadline: nil,
                usedHeadline: spent,
                remainingHeadline: nil
            )
        }
        let retained = Money(
            milliunits: SpendingHistoryMonth.roundedWholeDollar(
                remaining.milliunits
            )
        )
        return SpendingHistoryFundingDisplay(
            fundedHeadline: funded,
            usedHeadline: funded - retained,
            remainingHeadline: retained
        )
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

    public func activeRemainderGroupIdentity(
        for month: BudgetMonth,
        rules: [SpendingRemainderRule]
    ) -> String? {
        rules.filter { $0.effectiveMonth <= month }
            .max(by: remainderRulePrecedes)
            .flatMap { $0.enabled ? $0.groupIdentity : nil }
    }

    public func summary(
        for month: BudgetMonth,
        groups: [SpendingHistoryGroupTotal],
        rules: [SpendingGroupBudgetRule],
        savingsChoices: [SavingsBudgetChoice] = [],
        reserveAssignments: [SpendingSinkingFundContribution] = [],
        funded: Money? = nil,
        remainderGroupIdentity: String? = nil,
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
        let assignments = latestReserveAssignments(
            reserveAssignments.filter {
                $0.month == month && $0.active && $0.amount > .zero
                    && !$0.sourceGroupIdentity.isEmpty
            }
        )
        let reserveOutgoingByGroup = Dictionary(grouping: assignments) {
            $0.sourceGroupIdentity
        }.mapValues { $0.map(\.amount).sum() }

        let activeTargets = Dictionary(uniqueKeysWithValues: groups.compactMap {
            group -> (String, Money)? in
            guard let rule = activeRule(
                for: group.id,
                month: month,
                rules: rules
            ), rule.enabled, rule.target > .zero else { return nil }
            return (group.id, rule.target)
        })
        let fixedTargetTotal = activeTargets.reduce(Money.zero) {
            partial, pair in
            pair.key == remainderGroupIdentity
                ? partial : partial + pair.value
        }
        let remainderTarget = funded.map { $0 - fixedTargetTotal }

        let snapshots: [SpendingGroupBudgetSnapshot] = groups.compactMap { group in
            guard let rule = activeRule(
                for: group.id,
                month: month,
                rules: rules
            ), rule.enabled,
              rule.target > .zero else {
                return nil
            }
            // A net refund restores the full monthly target. It never creates
            // extra budget or offsets another group's spending.
            let spent = Money(milliunits: max(0, group.spentMilliunits))
            let baseTarget = group.id == remainderGroupIdentity
                ? remainderTarget ?? rule.target : rule.target
            let additional = incomingByGroup[group.id] ?? .zero
            let savingsOut = outgoingByGroup[group.id] ?? .zero
            let reserveOut = reserveOutgoingByGroup[group.id] ?? .zero
            let effectiveTarget = baseTarget + additional
                - savingsOut - reserveOut
            return SpendingGroupBudgetSnapshot(
                groupIdentity: group.id,
                groupName: group.name,
                spent: spent,
                target: effectiveTarget,
                baseTarget: baseTarget,
                additionalTarget: additional,
                reallocatedToSavings: savingsOut,
                reallocatedToReserves: reserveOut
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

    /// Amount that can be moved into one reserve without making the selected
    /// source budget overspent. The current reserve's assignment is added back
    /// while editing so reducing or preserving it always remains possible.
    public func availableForReserveAssignment(
        from source: SpendingGroupBudgetSnapshot,
        month: BudgetMonth,
        assignments: [SpendingSinkingFundContribution],
        excludingAssignmentID: String? = nil
    ) -> Money {
        let current = latestReserveAssignments(assignments.filter {
            $0.month == month
                && $0.sourceGroupIdentity == source.groupIdentity
                && $0.id == excludingAssignmentID
        }).filter(\.active).map(\.amount).sum()
        let available = source.remaining + current
        return available > .zero ? available : .zero
    }

    /// The amount that can still be reallocated from an ordinary budget into
    /// Savings after this month's actual spending and existing choices.
    public func availableForSavingsChoice(
        from source: SpendingGroupBudgetSnapshot,
        month: BudgetMonth,
        choices: [SavingsBudgetChoice],
        excludingChoiceID: String? = nil
    ) -> Money {
        let current = choices.filter {
            $0.month == month
                && $0.sourceGroupIdentity == source.groupIdentity
                && $0.id == excludingChoiceID
                && $0.amount > .zero
        }.map(\.amount).sum()
        let available = source.remaining + current
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

    private func remainderRulePrecedes(
        _ lhs: SpendingRemainderRule,
        _ rhs: SpendingRemainderRule
    ) -> Bool {
        if lhs.effectiveMonth != rhs.effectiveMonth {
            return lhs.effectiveMonth < rhs.effectiveMonth
        }
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt < rhs.updatedAt
        }
        return lhs.id < rhs.id
    }

    private func latestReserveAssignments(
        _ assignments: [SpendingSinkingFundContribution]
    ) -> [SpendingSinkingFundContribution] {
        Dictionary(
            grouping: assignments,
            by: \.id
        ).compactMapValues { rows in
            rows.max {
                if $0.updatedAt != $1.updatedAt {
                    return $0.updatedAt < $1.updatedAt
                }
                return $0.id < $1.id
            }
        }.values.map { $0 }
    }
}

// MARK: - Spending reserves

/// The three optional planning shapes a reserve can use.
public enum SpendingSinkingFundMode: String, Codable, CaseIterable, Sendable {
    /// A positive target and date produce a calculated monthly plan.
    case dueByDate
    /// A positive target may use a user-selected monthly plan.
    case buildToAmount
    /// An open-ended reserve may use a user-selected monthly plan.
    case ongoingReserve
}

/// A carried reserve that participates in the monthly Spending allocation
/// without pretending that its eventual purchase is ordinary monthly usage.
public struct SpendingSinkingFund: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let mode: SpendingSinkingFundMode
    public let target: Money
    public let targetDate: Date?
    /// A manual plan, or an optional override for a due-date calculation.
    /// Zero means no manual plan; due-date reserves calculate a suggestion.
    public let plannedMonthly: Money
    public let openingBalance: Money
    public let startMonth: BudgetMonth
    public let archived: Bool

    public init(
        id: String,
        name: String,
        mode: SpendingSinkingFundMode,
        target: Money = .zero,
        targetDate: Date? = nil,
        plannedMonthly: Money = .zero,
        openingBalance: Money = .zero,
        startMonth: BudgetMonth,
        archived: Bool = false
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.target = target
        self.targetDate = targetDate
        self.plannedMonthly = plannedMonthly
        self.openingBalance = openingBalance
        self.startMonth = startMonth
        self.archived = archived
    }
}

/// One explicit assignment into a reserve. A reserve can receive multiple
/// independently editable assignments in one month, including from different
/// source budgets.
public struct SpendingSinkingFundContribution: Identifiable, Hashable, Sendable {
    public let id: String
    public let fundID: String
    public let month: BudgetMonth
    public let sourceGroupIdentity: String
    public let amount: Money
    public let active: Bool
    public let updatedAt: Date

    public init(
        id: String,
        fundID: String,
        month: BudgetMonth,
        sourceGroupIdentity: String = "",
        amount: Money,
        active: Bool = true,
        updatedAt: Date
    ) {
        self.id = id
        self.fundID = fundID
        self.month = month
        self.sourceGroupIdentity = sourceGroupIdentity
        self.amount = amount
        self.active = active
        self.updatedAt = updatedAt
    }
}

/// A confirmed transaction or split line that draws from a reserve.
/// Amount is always a positive draw against the carried reserve.
public struct SpendingSinkingFundExpense: Identifiable, Hashable, Sendable {
    public let id: String
    public let fundID: String
    public let transactionID: String
    public let subtransactionID: String?
    public let date: Date
    public let amount: Money
    public let active: Bool
    public let updatedAt: Date

    public init(
        id: String,
        fundID: String,
        transactionID: String,
        subtransactionID: String? = nil,
        date: Date,
        amount: Money,
        active: Bool = true,
        updatedAt: Date
    ) {
        self.id = id
        self.fundID = fundID
        self.transactionID = transactionID
        self.subtransactionID = subtransactionID
        self.date = date
        self.amount = amount
        self.active = active
        self.updatedAt = updatedAt
    }
}

public struct SpendingSinkingFundSnapshot: Identifiable, Hashable, Sendable {
    public let fund: SpendingSinkingFund
    public let balance: Money
    public let contributed: Money
    public let spent: Money

    public var id: String { fund.id }

    public init(
        fund: SpendingSinkingFund,
        balance: Money,
        contributed: Money,
        spent: Money
    ) {
        self.fund = fund
        self.balance = balance
        self.contributed = contributed
        self.spent = spent
    }
}

public enum SpendingSinkingFundMath {
    /// Number of plan months from `asOf` through the target month, inclusive.
    public static func contributionMonths(
        from asOf: Date,
        through targetDate: Date,
        calendar: Calendar = .current
    ) -> Int {
        guard let start = calendar.dateInterval(of: .month, for: asOf)?.start,
              let end = calendar.dateInterval(
                of: .month,
                for: targetDate
              )?.start else { return 1 }
        let distance = calendar.dateComponents(
            [.month], from: start, to: end
        ).month ?? 0
        return max(1, distance + 1)
    }

    /// Calculates a suggested plan that cannot underfund the target because
    /// of milliunit rounding. Returns zero once the target is already met.
    public static func calculatedMonthlyPlan(
        target: Money,
        balance: Money,
        targetDate: Date,
        asOf: Date,
        calendar: Calendar = .current
    ) -> Money {
        let shortfall = target - balance
        guard shortfall > .zero else { return .zero }
        let months = Int64(contributionMonths(
            from: asOf,
            through: targetDate,
            calendar: calendar
        ))
        return Money(
            milliunits: (shortfall.milliunits + months - 1) / months
        )
    }

    public static func monthlyPlan(
        for fund: SpendingSinkingFund,
        balance: Money,
        asOf: Date,
        calendar: Calendar = .current
    ) -> Money {
        let proposed: Money
        switch fund.mode {
        case .dueByDate:
            if fund.plannedMonthly > .zero {
                proposed = fund.plannedMonthly
            } else if let targetDate = fund.targetDate {
                proposed = calculatedMonthlyPlan(
                    target: fund.target,
                    balance: balance,
                    targetDate: targetDate,
                    asOf: asOf,
                    calendar: calendar
                )
            } else {
                proposed = .zero
            }
        case .buildToAmount, .ongoingReserve:
            proposed = fund.plannedMonthly
        }

        guard fund.mode != .ongoingReserve, fund.target > .zero else {
            return proposed > .zero ? proposed : .zero
        }
        let shortfall = fund.target - balance
        guard shortfall > .zero else { return .zero }
        return proposed < shortfall ? proposed : shortfall
    }

    public static func snapshot(
        fund: SpendingSinkingFund,
        contributions: [SpendingSinkingFundContribution],
        expenses: [SpendingSinkingFundExpense],
        through month: BudgetMonth? = nil,
        calendar: Calendar = .current
    ) -> SpendingSinkingFundSnapshot {
        let latestContributions = Dictionary(
            grouping: contributions.filter { $0.fundID == fund.id },
            by: \.id
        ).compactMapValues { rows in
            rows.max {
                if $0.updatedAt != $1.updatedAt {
                    return $0.updatedAt < $1.updatedAt
                }
                return $0.id < $1.id
            }
        }.values
        let contributionTotal = latestContributions.filter {
            $0.active && (month == nil || $0.month <= month!)
        }.map(\.amount).sum()

        let latestExpenses = Dictionary(
            grouping: expenses.filter { $0.fundID == fund.id },
            by: { "\($0.transactionID)|\($0.subtransactionID ?? "whole")" }
        ).compactMapValues { rows in
            rows.max {
                if $0.updatedAt != $1.updatedAt {
                    return $0.updatedAt < $1.updatedAt
                }
                return $0.id < $1.id
            }
        }.values
        let expenseTotal = latestExpenses.filter {
            guard $0.active else { return false }
            guard let month else { return true }
            return BudgetMonth(containing: $0.date, calendar: calendar) <= month
        }.map(\.amount).sum()

        return SpendingSinkingFundSnapshot(
            fund: fund,
            balance: fund.openingBalance + contributionTotal - expenseTotal,
            contributed: contributionTotal,
            spent: expenseTotal
        )
    }
}
