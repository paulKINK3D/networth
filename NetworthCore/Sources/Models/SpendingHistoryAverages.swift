import Foundation
import Money

/// Historical monthly averages for Spending drill-downs, computed in the
/// Spending tab's own dialect: the same group and category totals the report
/// shows, recurring bills included. Complements — never replaces — the
/// projection estimate's recurring-stripped everyday averages.
public enum SpendingHistoryAverages {
    /// The trailing complete months to average over, newest first. The month
    /// containing `now` is excluded because it is still in progress.
    public static func averageWindow(
        months: [SpendingHistoryMonth],
        asOf now: Date,
        monthsBack: Int = 12,
        calendar: Calendar = .current
    ) -> [SpendingHistoryMonth] {
        let components = calendar.dateComponents([.year, .month], from: now)
        guard let currentStart = calendar.date(from: components) else {
            return []
        }
        return Array(
            months
                .filter { $0.month < currentStart }
                .sorted { $0.month > $1.month }
                .prefix(max(0, monthsBack))
        )
    }

    public struct CategoryAverage: Sendable, Hashable, Identifiable {
        public let id: String
        public let name: String
        public let monthlyAverage: Money

        public init(id: String, name: String, monthlyAverage: Money) {
            self.id = id
            self.name = name
            self.monthlyAverage = monthlyAverage
        }
    }

    /// Average monthly spend per category inside one group across the window,
    /// largest first. Categories that netted nothing are omitted.
    public static func categoryAverages(
        groupId: String,
        window: [SpendingHistoryMonth]
    ) -> [CategoryAverage] {
        guard !window.isEmpty else { return [] }
        var totals: [String: Int64] = [:]
        var names: [String: String] = [:]
        for month in window {
            for group in month.groups where group.id == groupId {
                for category in group.categories {
                    totals[category.id, default: 0]
                        += category.spentMilliunits
                    names[category.id] = category.name
                }
            }
        }
        let monthCount = Int64(window.count)
        return totals
            .map { categoryId, total in
                CategoryAverage(
                    id: categoryId,
                    name: names[categoryId] ?? "Uncategorized",
                    monthlyAverage: Money(milliunits: total / monthCount)
                )
            }
            .filter { $0.monthlyAverage > .zero }
            .sorted { lhs, rhs in
                if lhs.monthlyAverage != rhs.monthlyAverage {
                    return lhs.monthlyAverage > rhs.monthlyAverage
                }
                return lhs.name
                    .localizedCaseInsensitiveCompare(rhs.name)
                    == .orderedAscending
            }
    }

    public struct PayeeRollup: Sendable, Hashable, Identifiable {
        public let name: String
        /// Spend at this payee in the viewed month or period.
        public let selectedTotal: Money
        /// Average monthly spend across the window.
        public let monthlyAverage: Money
        /// Line count across the window; falls back to the selected period
        /// for payees with no window history.
        public let purchaseCount: Int
        public let selectedCount: Int
        /// Every contributing line id, window and selected, deduplicated.
        public let transactionIds: [String]
        /// Adjusted line amounts in the raw sign convention.
        public let lineAmountsByTransactionId: [String: Int64]

        public var id: String { name }

        public init(
            name: String,
            selectedTotal: Money,
            monthlyAverage: Money,
            purchaseCount: Int,
            selectedCount: Int,
            transactionIds: [String],
            lineAmountsByTransactionId: [String: Int64]
        ) {
            self.name = name
            self.selectedTotal = selectedTotal
            self.monthlyAverage = monthlyAverage
            self.purchaseCount = purchaseCount
            self.selectedCount = selectedCount
            self.transactionIds = transactionIds
            self.lineAmountsByTransactionId = lineAmountsByTransactionId
        }
    }

    /// One category's payees: the viewed period's spend against the window's
    /// monthly average, one entry per payee, largest average first. Lines the
    /// resolver cannot name fall into one "Transaction" bucket.
    public static func payeeRollups(
        groupId: String,
        categoryId: String,
        window: [SpendingHistoryMonth],
        selected: SpendingHistoryCategoryTotal?,
        payeeName: (String) -> String?
    ) -> [PayeeRollup] {
        struct Accumulator {
            var windowMilliunits: Int64 = 0
            var selectedMilliunits: Int64 = 0
            var windowCount = 0
            var selectedCount = 0
            var ids: [String] = []
            var amounts: [String: Int64] = [:]
        }
        var byPayee: [String: Accumulator] = [:]
        var seenIds = Set<String>()

        func record(
            id: String,
            amount: Int64,
            inWindow: Bool,
            inSelected: Bool
        ) {
            let name = payeeName(id) ?? "Transaction"
            var accumulator = byPayee[name] ?? Accumulator()
            if inWindow {
                accumulator.windowMilliunits -= amount
                accumulator.windowCount += 1
            }
            if inSelected {
                accumulator.selectedMilliunits -= amount
                accumulator.selectedCount += 1
            }
            if seenIds.insert(id).inserted {
                accumulator.ids.append(id)
                accumulator.amounts[id] = amount
            }
            byPayee[name] = accumulator
        }

        let selectedIds = Set(selected?.transactionIds ?? [])
        for month in window {
            for group in month.groups where group.id == groupId {
                for category in group.categories
                where category.id == categoryId {
                    for id in category.transactionIds {
                        record(
                            id: id,
                            amount: category
                                .lineAmountsByTransactionId[id] ?? 0,
                            inWindow: true,
                            inSelected: selectedIds.contains(id)
                        )
                    }
                }
            }
        }
        if let selected {
            for id in selected.transactionIds where !seenIds.contains(id) {
                record(
                    id: id,
                    amount: selected.lineAmountsByTransactionId[id] ?? 0,
                    inWindow: false,
                    inSelected: true
                )
            }
        }

        let monthCount = Int64(max(window.count, 1))
        return byPayee
            .map { name, accumulator in
                PayeeRollup(
                    name: name,
                    selectedTotal: Money(
                        milliunits: accumulator.selectedMilliunits
                    ),
                    monthlyAverage: Money(
                        milliunits: accumulator.windowMilliunits / monthCount
                    ),
                    purchaseCount: accumulator.windowCount > 0
                        ? accumulator.windowCount
                        : accumulator.selectedCount,
                    selectedCount: accumulator.selectedCount,
                    transactionIds: accumulator.ids,
                    lineAmountsByTransactionId: accumulator.amounts
                )
            }
            .sorted { lhs, rhs in
                if lhs.monthlyAverage != rhs.monthlyAverage {
                    return lhs.monthlyAverage > rhs.monthlyAverage
                }
                if lhs.selectedTotal != rhs.selectedTotal {
                    return lhs.selectedTotal > rhs.selectedTotal
                }
                return lhs.name
                    .localizedCaseInsensitiveCompare(rhs.name)
                    == .orderedAscending
            }
    }
}
