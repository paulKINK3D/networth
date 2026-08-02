import Foundation
import Money

// MARK: - Sinking funds

/// How spending from a fund's linked categories reads.
public enum FundSpendMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// The fund exists to be spent: drawdowns are the plan succeeding
    /// (travel, furniture). Spending drains the balance without judgment.
    case saveToSpend
    /// The fund is a floor to maintain (emergency fund): spending drains the
    /// balance and the fund quietly reads as needing a refill.
    case keepFilled

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .saveToSpend: "Save to Spend"
        case .keepFilled: "Keep Filled"
        }
    }
}

/// An opt-in earmark for a specific future purpose. Money stays wherever it
/// physically lives; the fund records intent. Nothing outside a fund is ever
/// asked to justify itself.
public struct SinkingFund: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    /// Zero means open-ended (no target).
    public let target: Money
    public let targetDate: Date?
    /// Used only for on-track math; never auto-contributes. Zero = no plan.
    public let plannedMonthly: Money
    public let spendMode: FundSpendMode
    /// Normalized category-name keys whose spending drains this fund.
    public let linkedCategoryKeys: Set<String>
    /// Linked-category spending before this date never drains the fund.
    public let startDate: Date
    public let archived: Bool

    public init(
        id: String,
        name: String,
        target: Money,
        targetDate: Date? = nil,
        plannedMonthly: Money = .zero,
        spendMode: FundSpendMode = .saveToSpend,
        linkedCategoryKeys: Set<String> = [],
        startDate: Date,
        archived: Bool = false
    ) {
        self.id = id
        self.name = name
        self.target = target
        self.targetDate = targetDate
        self.plannedMonthly = plannedMonthly
        self.spendMode = spendMode
        self.linkedCategoryKeys = linkedCategoryKeys
        self.startDate = startDate
        self.archived = archived
    }
}

/// One explicit fund movement: positive = contribution, negative = withdrawal.
public struct FundLedgerEntry: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let fundId: String
    public let date: Date
    public let amount: Money
    public let note: String?

    public init(
        id: String,
        fundId: String,
        date: Date,
        amount: Money,
        note: String? = nil
    ) {
        self.id = id
        self.fundId = fundId
        self.date = date
        self.amount = amount
        self.note = note
    }
}

/// Computed truth for one fund at a point in time.
public struct FundSnapshot: Identifiable, Hashable, Sendable {
    public let fund: SinkingFund
    /// Manual contributions/withdrawals + automatic linked-category drains.
    public let balance: Money
    /// Total drained by linked-category spending since the fund started.
    public let linkedSpending: Money
    public let status: FundStatus

    public var id: String { fund.id }

    public init(
        fund: SinkingFund,
        balance: Money,
        linkedSpending: Money,
        status: FundStatus
    ) {
        self.fund = fund
        self.balance = balance
        self.linkedSpending = linkedSpending
        self.status = status
    }

    /// 0…1 progress toward target; funds without targets report nil.
    public var progressFraction: Double? {
        FundMath.progressFraction(balance: balance, target: fund.target)
    }
}

/// Plain statement of where a fund stands. Reporting, never coaching.
public enum FundStatus: Hashable, Sendable {
    /// No target set: the balance is the whole story.
    case openEnded
    /// Target reached.
    case funded
    /// Target + date set and the planned monthly keeps pace.
    case onTrack(requiredMonthly: Money)
    /// Target + date set and the planned monthly falls short.
    case behind(requiredMonthly: Money)
    /// Target set with no date: progress only.
    case saving
}

// MARK: - Fund math

public enum FundMath {
    public static func balance(
        manualEntries: [FundLedgerEntry],
        linkedSpending: Money
    ) -> Money {
        manualEntries.map(\.amount).sum() - linkedSpending
    }

    public static func progressFraction(
        balance: Money,
        target: Money
    ) -> Double? {
        guard target.milliunits > 0 else { return nil }
        return min(
            1,
            max(0, Double(balance.milliunits) / Double(target.milliunits))
        )
    }

    /// Whole months from `asOf` to the target date, minimum 1 while the date
    /// is in the future.
    public static func monthsRemaining(
        from asOf: Date,
        to targetDate: Date,
        calendar: Calendar = .current
    ) -> Int {
        guard targetDate > asOf else { return 0 }
        let components = calendar.dateComponents(
            [.month], from: asOf, to: targetDate
        )
        return max(1, components.month ?? 1)
    }

    /// Even monthly amount that reaches the target by its date from the
    /// current balance. Nil without both a positive target and a future date.
    public static func requiredMonthly(
        balance: Money,
        target: Money,
        targetDate: Date?,
        asOf: Date,
        calendar: Calendar = .current
    ) -> Money? {
        guard target.milliunits > 0, let targetDate else { return nil }
        let shortfall = target - balance
        guard shortfall.milliunits > 0 else { return .zero }
        let months = monthsRemaining(
            from: asOf, to: targetDate, calendar: calendar
        )
        guard months > 0 else { return shortfall }
        return shortfall.scaled(by: Decimal(1) / Decimal(months))
    }

    public static func status(
        fund: SinkingFund,
        balance: Money,
        asOf: Date,
        calendar: Calendar = .current
    ) -> FundStatus {
        guard fund.target.milliunits > 0 else { return .openEnded }
        if balance >= fund.target { return .funded }
        guard let required = requiredMonthly(
            balance: balance,
            target: fund.target,
            targetDate: fund.targetDate,
            asOf: asOf,
            calendar: calendar
        ) else {
            return .saving
        }
        return fund.plannedMonthly >= required
            ? .onTrack(requiredMonthly: required)
            : .behind(requiredMonthly: required)
    }

    public static func snapshot(
        fund: SinkingFund,
        manualEntries: [FundLedgerEntry],
        linkedSpending: Money,
        asOf: Date,
        calendar: Calendar = .current
    ) -> FundSnapshot {
        let balance = balance(
            manualEntries: manualEntries, linkedSpending: linkedSpending
        )
        return FundSnapshot(
            fund: fund,
            balance: balance,
            linkedSpending: linkedSpending,
            status: status(
                fund: fund, balance: balance, asOf: asOf, calendar: calendar
            )
        )
    }
}
