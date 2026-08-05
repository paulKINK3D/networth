import Foundation
import Money

/// One spending-relevant leg of an approved transaction, already resolved to
/// its Networth-owned category group. The app maps split transactions to one
/// entry per leg before building.
public struct SpendingHistoryEntry: Sendable, Hashable {
    public let transactionId: String
    public let date: Date
    /// Networth convention: outflow negative, inflow positive.
    public let amountMilliunits: Int64
    public let treatment: ForecastTreatment?
    public let groupIdentity: String?
    public let groupName: String?
    public let categoryKey: String
    public let categoryName: String

    public init(
        transactionId: String,
        date: Date,
        amountMilliunits: Int64,
        treatment: ForecastTreatment?,
        groupIdentity: String?,
        groupName: String?,
        categoryKey: String,
        categoryName: String
    ) {
        self.transactionId = transactionId
        self.date = date
        self.amountMilliunits = amountMilliunits
        self.treatment = treatment
        self.groupIdentity = groupIdentity
        self.groupName = groupName
        self.categoryKey = categoryKey
        self.categoryName = categoryName
    }
}

public struct SpendingHistoryCategoryTotal: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let spentMilliunits: Int64
    public let transactionIds: [String]

    public init(
        id: String,
        name: String,
        spentMilliunits: Int64,
        transactionIds: [String]
    ) {
        self.id = id
        self.name = name
        self.spentMilliunits = spentMilliunits
        self.transactionIds = transactionIds
    }

    public var spent: Money { Money(milliunits: spentMilliunits) }
}

public struct SpendingHistoryGroupTotal: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let spentMilliunits: Int64
    public let categories: [SpendingHistoryCategoryTotal]

    public init(
        id: String,
        name: String,
        spentMilliunits: Int64,
        categories: [SpendingHistoryCategoryTotal]
    ) {
        self.id = id
        self.name = name
        self.spentMilliunits = spentMilliunits
        self.categories = categories
    }

    public var spent: Money { Money(milliunits: spentMilliunits) }
}

public struct SpendingHistoryMonth: Sendable, Hashable, Identifiable {
    /// Start of month in the builder's calendar.
    public let month: Date
    public let totalMilliunits: Int64
    /// Sorted by spent descending.
    public let groups: [SpendingHistoryGroupTotal]

    public var id: Date { month }
    public var total: Money { Money(milliunits: totalMilliunits) }
}

/// Builds the Spending History months from approved activity.
///
/// Counting rules (the product contract):
/// - Negative ordinary transactions count as spending; positive refunds are
///   offsets within the same category.
/// - Income, investment contributions, transfers, card payments, and
///   explicit exclusions never enter a spending total.
/// - The current month is month-to-date; completed months are final.
/// - Month bucketing uses the supplied calendar, so grouping is
///   timezone-safe: a transaction's civil day decides its month.
public enum SpendingHistoryBuilder {
    public static let ungroupedIdentity = "networth:ungrouped"
    public static let ungroupedName = "Other"

    public static func contributesToSpending(
        _ treatment: ForecastTreatment?
    ) -> Bool {
        switch treatment {
        case .ordinarySpending, .refund, nil: true
        case .income, .internalTransfer, .cardPayment,
             .investmentContribution, .excluded: false
        }
    }

    /// Returns exactly `monthsBack` months ending at `now`'s month, oldest
    /// first, including zero months so charts keep continuity.
    public static func build(
        entries: [SpendingHistoryEntry],
        monthsBack: Int = 24,
        now: Date,
        calendar: Calendar
    ) -> [SpendingHistoryMonth] {
        guard monthsBack > 0,
              let currentMonth = calendar.dateInterval(
                of: .month, for: now
              )?.start else {
            return []
        }
        var monthStarts: [Date] = []
        for offset in stride(from: monthsBack - 1, through: 0, by: -1) {
            if let start = calendar.date(
                byAdding: .month, value: -offset, to: currentMonth
            ) {
                monthStarts.append(start)
            }
        }
        guard let windowStart = monthStarts.first else { return [] }

        struct CategoryBucket {
            var name: String
            var spent: Int64 = 0
            var transactionIds: [String] = []
        }
        struct GroupBucket {
            var name: String
            var categories: [String: CategoryBucket] = [:]
        }
        // month -> groupIdentity -> buckets
        var months: [Date: [String: GroupBucket]] = [:]

        for entry in entries {
            guard contributesToSpending(entry.treatment) else { continue }
            // The sign matrix is strict: NEGATIVE ordinary transactions are
            // spending and POSITIVE refunds are offsets. A positive amount
            // classified as ordinary spending or a negative refund is a
            // mismatched classification and must not distort totals.
            switch entry.treatment {
            case .ordinarySpending, nil:
                guard entry.amountMilliunits < 0 else { continue }
            case .refund:
                guard entry.amountMilliunits > 0 else { continue }
            default:
                continue
            }
            guard entry.date >= windowStart, entry.date <= now,
                  let month = calendar.dateInterval(
                    of: .month, for: entry.date
                  )?.start else {
                continue
            }
            let groupID = entry.groupIdentity ?? ungroupedIdentity
            let groupName = entry.groupName ?? ungroupedName
            var groups = months[month] ?? [:]
            var group = groups[groupID] ?? GroupBucket(name: groupName)
            var category = group.categories[entry.categoryKey]
                ?? CategoryBucket(name: entry.categoryName)
            // Spending is positive; outflows are negative amounts, refunds
            // offset by their (positive) amount within the category.
            category.spent -= entry.amountMilliunits
            // Split legs share the parent id; list each transaction once.
            if !category.transactionIds.contains(entry.transactionId) {
                category.transactionIds.append(entry.transactionId)
            }
            group.categories[entry.categoryKey] = category
            groups[groupID] = group
            months[month] = groups
        }

        return monthStarts.map { month in
            let groups = (months[month] ?? [:]).map { groupID, bucket in
                let categories = bucket.categories
                    .map { key, category in
                        SpendingHistoryCategoryTotal(
                            id: key,
                            name: category.name,
                            spentMilliunits: category.spent,
                            transactionIds: category.transactionIds
                        )
                    }
                    .sorted {
                        if $0.spentMilliunits != $1.spentMilliunits {
                            return $0.spentMilliunits > $1.spentMilliunits
                        }
                        return $0.name.localizedCaseInsensitiveCompare($1.name)
                            == .orderedAscending
                    }
                return SpendingHistoryGroupTotal(
                    id: groupID,
                    name: bucket.name,
                    spentMilliunits: categories.reduce(0) {
                        $0 + $1.spentMilliunits
                    },
                    categories: categories
                )
            }
            .sorted {
                if $0.spentMilliunits != $1.spentMilliunits {
                    return $0.spentMilliunits > $1.spentMilliunits
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name)
                    == .orderedAscending
            }
            return SpendingHistoryMonth(
                month: month,
                totalMilliunits: groups.reduce(0) { $0 + $1.spentMilliunits },
                groups: groups
            )
        }
    }
}
