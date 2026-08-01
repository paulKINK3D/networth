import Foundation
import Money

public struct TransactionSummary: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let accountId: String
    public let date: Date
    public let amount: Money
    public let cleared: Bool
    public let approved: Bool
    public let payeeName: String?
    public let categoryId: String?
    public let categoryName: String?
    public let forecastTreatment: ForecastTreatment?
    public let transferAccountId: String?
    public let memo: String?
    public let deleted: Bool
    public let subtransactions: [SubTransactionSummary]

    public init(
        id: String,
        accountId: String,
        date: Date,
        amount: Money,
        cleared: Bool,
        approved: Bool,
        payeeName: String?,
        categoryId: String? = nil,
        categoryName: String?,
        forecastTreatment: ForecastTreatment? = nil,
        transferAccountId: String? = nil,
        memo: String?,
        deleted: Bool,
        subtransactions: [SubTransactionSummary] = []
    ) {
        self.id = id
        self.accountId = accountId
        self.date = date
        self.amount = amount
        self.cleared = cleared
        self.approved = approved
        self.payeeName = payeeName
        self.categoryId = categoryId
        self.categoryName = categoryName
        self.forecastTreatment = forecastTreatment
        self.transferAccountId = transferAccountId
        self.memo = memo
        self.deleted = deleted
        self.subtransactions = subtransactions
    }

    public var isSplit: Bool { !subtransactions.isEmpty }
}

/// One leg of a YNAB split transaction. Sub-amounts sum to the parent's amount.
public struct SubTransactionSummary: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let amount: Money
    public let categoryId: String?
    public let categoryName: String?
    /// Local Plaid reviews can classify each incoming split leg separately.
    /// Nil keeps YNAB-sourced and older persisted split payloads compatible.
    public let forecastTreatment: ForecastTreatment?
    public let transferAccountId: String?
    public let payeeName: String?
    public let memo: String?
    public let deleted: Bool

    public init(
        id: String,
        amount: Money,
        categoryId: String?,
        categoryName: String?,
        forecastTreatment: ForecastTreatment? = nil,
        transferAccountId: String? = nil,
        payeeName: String?,
        memo: String?,
        deleted: Bool
    ) {
        self.id = id
        self.amount = amount
        self.categoryId = categoryId
        self.categoryName = categoryName
        self.forecastTreatment = forecastTreatment
        self.transferAccountId = transferAccountId
        self.payeeName = payeeName
        self.memo = memo
        self.deleted = deleted
    }
}

/// Master list of YNAB categories grouped by category group. We only need a
/// flat list with stable IDs + display info for the exclusion picker.
public struct CategorySummary: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let name: String
    public let groupId: String
    public let groupName: String
    public let hidden: Bool
    public let deleted: Bool

    public init(id: String, name: String, groupId: String, groupName: String, hidden: Bool = false, deleted: Bool = false) {
        self.id = id
        self.name = name
        self.groupId = groupId
        self.groupName = groupName
        self.hidden = hidden
        self.deleted = deleted
    }
}

/// Current-month status for the single discretionary spending envelope.
public struct DiscretionaryBudgetSnapshot: Sendable, Hashable {
    public let spent: Money
    public let target: Money
    public let remaining: Money
    public let paceTarget: Money
    /// Positive means spending is ahead of (over) today's time-weighted pace.
    public let paceDifference: Money
    public let daysElapsed: Int
    public let daysInMonth: Int

    public init(
        spent: Money,
        target: Money,
        remaining: Money,
        paceTarget: Money,
        paceDifference: Money,
        daysElapsed: Int,
        daysInMonth: Int
    ) {
        self.spent = spent
        self.target = target
        self.remaining = remaining
        self.paceTarget = paceTarget
        self.paceDifference = paceDifference
        self.daysElapsed = daysElapsed
        self.daysInMonth = daysInMonth
    }

    public var isOverTarget: Bool { remaining.isNegative }
    public var isOverPace: Bool { paceDifference.milliunits > 0 }
}

public struct DiscretionaryCategorySpend: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let amount: Money

    public init(id: String, name: String, amount: Money) {
        self.id = id
        self.name = name
        self.amount = amount
    }
}

public struct DiscretionaryBudgetReport: Sendable, Hashable {
    public let snapshot: DiscretionaryBudgetSnapshot
    public let categories: [DiscretionaryCategorySpend]
    public let historicalMonthlyAverage: Money
    public let historicalMonthCount: Int
    public let historicalCategoryTotals: [DiscretionaryCategorySpend]

    public init(
        snapshot: DiscretionaryBudgetSnapshot,
        categories: [DiscretionaryCategorySpend],
        historicalMonthlyAverage: Money,
        historicalMonthCount: Int,
        historicalCategoryTotals: [DiscretionaryCategorySpend]
    ) {
        self.snapshot = snapshot
        self.categories = categories
        self.historicalMonthlyAverage = historicalMonthlyAverage
        self.historicalMonthCount = historicalMonthCount
        self.historicalCategoryTotals = historicalCategoryTotals
    }
}

/// Pure monthly calculator shared by YNAB- and Plaid-backed views.
public struct DiscretionaryBudgetCalculator: Sendable {
    public init() {}

    public func snapshot(
        transactions: [TransactionSummary],
        discretionaryCategoryIds: Set<String>,
        discretionaryCategoryNames: Set<String> = [],
        target: Money,
        asOf: Date = .now,
        calendar: Calendar = .current
    ) -> DiscretionaryBudgetSnapshot {
        report(
            transactions: transactions,
            discretionaryCategoryIds: discretionaryCategoryIds,
            discretionaryCategoryNames: discretionaryCategoryNames,
            target: target,
            asOf: asOf,
            calendar: calendar
        ).snapshot
    }

    public func report(
        transactions: [TransactionSummary],
        discretionaryCategoryIds: Set<String>,
        discretionaryCategoryNames: Set<String> = [],
        target: Money,
        historicalMonthCount: Int = 3,
        asOf: Date = .now,
        calendar: Calendar = .current
    ) -> DiscretionaryBudgetReport {
        let categories = breakdown(
            transactions: transactions,
            discretionaryCategoryIds: discretionaryCategoryIds,
            discretionaryCategoryNames: discretionaryCategoryNames,
            asOf: asOf,
            calendar: calendar
        )
        let snapshot = makeSnapshot(
            spent: categories.map(\.amount).sum(),
            target: target,
            asOf: asOf,
            calendar: calendar
        )
        let normalizedHistoricalMonthCount = max(0, historicalMonthCount)
        let historicalCategoryTotals = historicalCategoryTotals(
            transactions: transactions,
            discretionaryCategoryIds: discretionaryCategoryIds,
            discretionaryCategoryNames: discretionaryCategoryNames,
            completedMonthCount: normalizedHistoricalMonthCount,
            asOf: asOf,
            calendar: calendar
        )
        let historicalTotal = historicalCategoryTotals.map(\.amount).sum()
        return DiscretionaryBudgetReport(
            snapshot: snapshot,
            categories: categories,
            historicalMonthlyAverage: normalizedHistoricalMonthCount > 0
                ? historicalTotal.scaled(
                    by: Decimal(1)
                        / Decimal(normalizedHistoricalMonthCount)
                )
                : .zero,
            historicalMonthCount: normalizedHistoricalMonthCount,
            historicalCategoryTotals: historicalCategoryTotals
        )
    }

    private func makeSnapshot(
        spent: Money,
        target: Money,
        asOf: Date,
        calendar: Calendar
    ) -> DiscretionaryBudgetSnapshot {
        let normalizedTarget = Money(milliunits: max(0, target.milliunits))
        let daysInMonth = calendar.range(
            of: .day,
            in: .month,
            for: asOf
        )?.count ?? 1
        let daysElapsed = min(
            daysInMonth,
            max(1, calendar.component(.day, from: asOf))
        )
        let paceTarget = normalizedTarget.scaled(
            by: Decimal(daysElapsed) / Decimal(daysInMonth)
        )
        return DiscretionaryBudgetSnapshot(
            spent: spent,
            target: normalizedTarget,
            remaining: normalizedTarget - spent,
            paceTarget: paceTarget,
            paceDifference: spent - paceTarget,
            daysElapsed: daysElapsed,
            daysInMonth: daysInMonth
        )
    }

    public func breakdown(
        transactions: [TransactionSummary],
        discretionaryCategoryIds: Set<String>,
        discretionaryCategoryNames: Set<String> = [],
        asOf: Date = .now,
        calendar: Calendar = .current
    ) -> [DiscretionaryCategorySpend] {
        guard let month = calendar.dateInterval(of: .month, for: asOf) else {
            return []
        }
        let acceptedNames = Set(discretionaryCategoryNames.map(Self.normalized))
        var totals: [String: (name: String, milliunits: Int64)] = [:]
        for transaction in transactions where
            transaction.approved
                && !transaction.deleted
                && month.contains(transaction.date) {
            for contribution in contributions(
                from: transaction,
                acceptedIds: discretionaryCategoryIds,
                acceptedNames: acceptedNames
            ) {
                let existing = totals[contribution.key]
                totals[contribution.key] = (
                    name: existing?.name ?? contribution.name,
                    milliunits: (existing?.milliunits ?? 0)
                        + contribution.milliunits
                )
            }
        }
        return totals.map {
            DiscretionaryCategorySpend(
                id: $0.key,
                name: $0.value.name,
                amount: Money(milliunits: max(0, $0.value.milliunits))
            )
        }
        .filter { !$0.amount.isZero }
        .sorted {
            if $0.amount != $1.amount { return $0.amount > $1.amount }
            return $0.name.localizedCaseInsensitiveCompare($1.name)
                == .orderedAscending
        }
    }

    /// Average discretionary spend across the most recent completed calendar
    /// months. The current partial month is never included.
    public func historicalMonthlyAverage(
        transactions: [TransactionSummary],
        discretionaryCategoryIds: Set<String>,
        discretionaryCategoryNames: Set<String> = [],
        completedMonthCount: Int = 3,
        asOf: Date = .now,
        calendar: Calendar = .current
    ) -> Money {
        guard completedMonthCount > 0 else {
            return .zero
        }
        return historicalCategoryTotals(
            transactions: transactions,
            discretionaryCategoryIds: discretionaryCategoryIds,
            discretionaryCategoryNames: discretionaryCategoryNames,
            completedMonthCount: completedMonthCount,
            asOf: asOf,
            calendar: calendar
        )
        .map(\.amount)
        .sum()
        .scaled(by: Decimal(1) / Decimal(completedMonthCount))
    }

    /// Category totals across the most recent completed calendar months.
    public func historicalCategoryTotals(
        transactions: [TransactionSummary],
        discretionaryCategoryIds: Set<String>,
        discretionaryCategoryNames: Set<String> = [],
        completedMonthCount: Int = 3,
        asOf: Date = .now,
        calendar: Calendar = .current
    ) -> [DiscretionaryCategorySpend] {
        guard completedMonthCount > 0,
              let currentMonth = calendar.dateInterval(
                of: .month,
                for: asOf
              ) else {
            return []
        }

        var totals: [String: (name: String, amount: Money)] = [:]
        for offset in 1...completedMonthCount {
            guard let month = calendar.date(
                byAdding: .month,
                value: -offset,
                to: currentMonth.start
            ) else {
                continue
            }
            let categories = breakdown(
                transactions: transactions,
                discretionaryCategoryIds: discretionaryCategoryIds,
                discretionaryCategoryNames: discretionaryCategoryNames,
                asOf: month,
                calendar: calendar
            )
            for category in categories {
                let existing = totals[category.id]
                totals[category.id] = (
                    name: existing?.name ?? category.name,
                    amount: (existing?.amount ?? .zero) + category.amount
                )
            }
        }
        return totals.map {
            DiscretionaryCategorySpend(
                id: $0.key,
                name: $0.value.name,
                amount: $0.value.amount
            )
        }
        .filter { !$0.amount.isZero }
        .sorted {
            if $0.amount != $1.amount { return $0.amount > $1.amount }
            return $0.name.localizedCaseInsensitiveCompare($1.name)
                == .orderedAscending
        }
    }

    private struct CategoryContribution {
        let key: String
        let name: String
        let milliunits: Int64
    }

    private func contributions(
        from transaction: TransactionSummary,
        acceptedIds: Set<String>,
        acceptedNames: Set<String>
    ) -> [CategoryContribution] {
        guard !Self.isKnownNonSpendPayee(transaction.payeeName) else {
            return []
        }
        if transaction.isSplit {
            return transaction.subtransactions.compactMap { leg in
                guard !leg.deleted,
                      leg.transferAccountId == nil,
                      Self.countsAsSpending(leg.forecastTreatment),
                      Self.matches(
                          categoryId: leg.categoryId,
                          categoryName: leg.categoryName,
                          acceptedIds: acceptedIds,
                          acceptedNames: acceptedNames
                      ) else {
                    return nil
                }
                return categoryContribution(
                    categoryId: leg.categoryId,
                    categoryName: leg.categoryName,
                    milliunits: -leg.amount.milliunits
                )
            }
        }

        guard transaction.transferAccountId == nil,
              Self.countsAsSpending(transaction.forecastTreatment),
              Self.matches(
                  categoryId: transaction.categoryId,
                  categoryName: transaction.categoryName,
                  acceptedIds: acceptedIds,
                  acceptedNames: acceptedNames
              ) else {
            return []
        }
        return [categoryContribution(
            categoryId: transaction.categoryId,
            categoryName: transaction.categoryName,
            milliunits: -transaction.amount.milliunits
        )]
    }

    private func categoryContribution(
        categoryId: String?,
        categoryName: String?,
        milliunits: Int64
    ) -> CategoryContribution {
        let trimmedName = categoryName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName.flatMap { $0.isEmpty ? nil : $0 }
            ?? categoryId
            ?? "Uncategorized"
        return CategoryContribution(
            key: Self.normalized(name),
            name: name,
            milliunits: milliunits
        )
    }

    private static func countsAsSpending(
        _ treatment: ForecastTreatment?
    ) -> Bool {
        switch treatment {
        case .income, .internalTransfer, .cardPayment, .excluded:
            return false
        case .ordinarySpending, .refund, nil:
            return true
        }
    }

    private static func isKnownNonSpendPayee(_ payeeName: String?) -> Bool {
        guard let payeeName else { return false }
        let normalized = payeeName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return [
            "manual balance adjustment",
            "reconciliation balance adjustment",
            "starting balance",
            "investment"
        ].contains(normalized)
    }

    private static func matches(
        categoryId: String?,
        categoryName: String?,
        acceptedIds: Set<String>,
        acceptedNames: Set<String>
    ) -> Bool {
        if let categoryId, acceptedIds.contains(categoryId) {
            return true
        }
        guard let categoryName else { return false }
        return acceptedNames.contains(normalized(categoryName))
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// User-confirmed initial selection. Once saved, stable category IDs replace
/// this name/group seed so future renames do not change membership.
public enum DiscretionaryBudgetDefaults {
    public static func includesCategory(
        name: String,
        groupName: String
    ) -> Bool {
        if groupName.caseInsensitiveCompare("Surplus") == .orderedSame {
            return true
        }
        let names: Set<String> = [
            "gym/biking/exercise",
            "subscriptions",
            "coffee",
            "eating out",
            "clothing",
            "investing",
            "uncategorized"
        ]
        return names.contains(
            name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }
}
