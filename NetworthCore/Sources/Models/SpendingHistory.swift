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
    /// Internal reporting classification for this entry's destination group.
    /// Ordinary categories use `.spending`; savings-account transfer activity
    /// uses `.transfer`; investment contributions use `.investment`.
    public let reportingRole: CategoryReportingRole?
    public let groupIdentity: String?
    public let groupName: String?
    public let categoryKey: String
    public let categoryName: String

    public init(
        transactionId: String,
        date: Date,
        amountMilliunits: Int64,
        treatment: ForecastTreatment?,
        reportingRole: CategoryReportingRole? = nil,
        groupIdentity: String?,
        groupName: String?,
        categoryKey: String,
        categoryName: String
    ) {
        self.transactionId = transactionId
        self.date = date
        self.amountMilliunits = amountMilliunits
        self.treatment = treatment
        self.reportingRole = reportingRole
        self.groupIdentity = groupIdentity
        self.groupName = groupName
        self.categoryKey = categoryKey
        self.categoryName = categoryName
    }
}

/// A user-visible group that should remain present even in zero-activity
/// months. This keeps the Spending columns stable while preserving zero-fill
/// across the 24-month chart window.
public struct SpendingHistoryGroupDefinition: Sendable, Hashable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct SpendingHistoryCategoryTotal: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let spentMilliunits: Int64
    public let transactionIds: [String]
    /// Adjusted entry-amount sum per transaction in this category, in the
    /// raw sign convention (outflow negative). Drill-down rows display these
    /// instead of recomputing from cached rows, so goal-purchase adjustments
    /// carry through to every level.
    public let lineAmountsByTransactionId: [String: Int64]

    public init(
        id: String,
        name: String,
        spentMilliunits: Int64,
        transactionIds: [String],
        lineAmountsByTransactionId: [String: Int64] = [:]
    ) {
        self.id = id
        self.name = name
        self.spentMilliunits = spentMilliunits
        self.transactionIds = transactionIds
        self.lineAmountsByTransactionId = lineAmountsByTransactionId
    }

    public var spent: Money { Money(milliunits: spentMilliunits) }
}

public struct SpendingHistoryGroupTotal: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let spentMilliunits: Int64
    public let categories: [SpendingHistoryCategoryTotal]
    /// Dominant reporting role of the entries that built this group; nil is
    /// ordinary spending. Transfer/investment groups are excluded from the
    /// ordinary total.
    public let reportingRole: CategoryReportingRole?

    public init(
        id: String,
        name: String,
        spentMilliunits: Int64,
        categories: [SpendingHistoryCategoryTotal],
        reportingRole: CategoryReportingRole? = nil
    ) {
        self.id = id
        self.name = name
        self.spentMilliunits = spentMilliunits
        self.categories = categories
        self.reportingRole = reportingRole
    }

    public var spent: Money { Money(milliunits: spentMilliunits) }

    /// Ordinary out-of-pocket spending: not a transfer/investment group.
    public var isOrdinarySpending: Bool {
        reportingRole == nil || reportingRole == .spending
    }
}

public struct SpendingHistoryMonth: Sendable, Hashable, Identifiable {
    /// Start of month in the builder's calendar.
    public let month: Date
    /// The Spent headline: every visible group.
    public let totalMilliunits: Int64
    /// Ordinary out-of-pocket spending only — excludes transfer and
    /// investment groups.
    public let ordinaryTotalMilliunits: Int64
    /// Sorted by spent descending.
    public let groups: [SpendingHistoryGroupTotal]

    public var id: Date { month }
    public var total: Money { Money(milliunits: totalMilliunits) }
    public var ordinaryTotal: Money {
        Money(milliunits: ordinaryTotalMilliunits)
    }

    /// Whole-dollar amounts for the compact Spending summary. Positive
    /// ordinary groups use largest-remainder allocation so their displayed
    /// dollars add exactly to the displayed ordinary headline. Exact
    /// milliunit totals remain unchanged for charts and detail views.
    public var wholeDollarDisplay: SpendingHistoryWholeDollarDisplay {
        var groupAmounts = Dictionary(uniqueKeysWithValues: groups.map {
            ($0.id, Money(milliunits: Self.roundedWholeDollar($0.spentMilliunits)))
        })
        let ordinaryGroups = groups.filter {
            $0.isOrdinarySpending && $0.spentMilliunits > 0
        }
        let headlineMilliunits = Self.roundedWholeDollar(
            ordinaryTotalMilliunits
        )
        let baseMilliunits = ordinaryGroups.reduce(Int64(0)) {
            $0 + ($1.spentMilliunits / 1_000) * 1_000
        }
        let awardCount = max(
            0,
            min(
                ordinaryGroups.count,
                Int((headlineMilliunits - baseMilliunits) / 1_000)
            )
        )
        let awardIDs = Set(ordinaryGroups.sorted {
            let lhsRemainder = $0.spentMilliunits % 1_000
            let rhsRemainder = $1.spentMilliunits % 1_000
            if lhsRemainder != rhsRemainder {
                return lhsRemainder > rhsRemainder
            }
            return $0.id < $1.id
        }.prefix(awardCount).map(\.id))

        for group in ordinaryGroups {
            let base = (group.spentMilliunits / 1_000) * 1_000
            groupAmounts[group.id] = Money(
                milliunits: base + (awardIDs.contains(group.id) ? 1_000 : 0)
            )
        }
        return SpendingHistoryWholeDollarDisplay(
            ordinaryHeadline: Money(milliunits: headlineMilliunits),
            groupAmountsByID: groupAmounts
        )
    }

    private static func roundedWholeDollar(_ milliunits: Int64) -> Int64 {
        let whole = milliunits / 1_000
        let remainder = milliunits % 1_000
        if remainder >= 500 { return (whole + 1) * 1_000 }
        if remainder <= -500 { return (whole - 1) * 1_000 }
        return whole * 1_000
    }
}

public struct SpendingHistoryWholeDollarDisplay: Sendable, Hashable {
    public let ordinaryHeadline: Money
    public let groupAmountsByID: [String: Money]
}

/// Builds the Spending History months from approved activity.
///
/// Counting rules (the product contract):
/// - Negative ordinary transactions count as spending; positive refunds are
///   offsets within the same category.
/// - Net savings-account transfers and net investment contributions appear
///   alongside ordinary spending so the report answers where money went.
/// - Income, card payments, other internal transfers, and explicit exclusions
///   never enter a spending total.
/// - The current month is month-to-date; completed months are final.
/// - Month bucketing uses the supplied calendar, so grouping is
///   timezone-safe: a transaction's civil day decides its month.
public enum SpendingHistoryBuilder {
    public static let ungroupedIdentity = "networth:ungrouped"
    public static let ungroupedName = "Other"

    public static func contributesToSpending(
        _ treatment: ForecastTreatment?,
        reportingRole: CategoryReportingRole? = nil
    ) -> Bool {
        switch treatment {
        case .ordinarySpending, .refund, nil: true
        case .internalTransfer: reportingRole == .transfer
        case .investmentContribution: reportingRole == .investment
        case .income, .cardPayment, .reimbursement, .goalSpend, .goalRefund,
             .excluded, .unknown: false
        }
    }

    /// Returns exactly `monthsBack` months ending at `now`'s month, oldest
    /// first, including zero months so charts keep continuity.
    public static func build(
        entries: [SpendingHistoryEntry],
        groups groupDefinitions: [SpendingHistoryGroupDefinition] = [],
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
            var lineAmounts: [String: Int64] = [:]
        }
        struct GroupBucket {
            var name: String
            var categories: [String: CategoryBucket] = [:]
            var reportingRole: CategoryReportingRole?
        }
        // month -> groupIdentity -> buckets
        var months: [Date: [String: GroupBucket]] = [:]

        for entry in entries {
            guard contributesToSpending(
                entry.treatment,
                reportingRole: entry.reportingRole
            ) else { continue }
            // The sign matrix is strict: NEGATIVE ordinary transactions are
            // spending and POSITIVE refunds are offsets. A positive amount
            // classified as ordinary spending or a negative refund is a
            // mismatched classification and must not distort totals.
            let reportedAmount: Int64
            switch entry.treatment {
            case .ordinarySpending, nil:
                guard entry.amountMilliunits < 0 else { continue }
                reportedAmount = -entry.amountMilliunits
            case .refund:
                guard entry.amountMilliunits > 0 else { continue }
                reportedAmount = -entry.amountMilliunits
            case .investmentContribution:
                guard entry.reportingRole == .investment,
                      entry.amountMilliunits != 0 else { continue }
                // A negative contribution adds to Investment; a positive
                // withdrawal offsets that month's net contribution.
                reportedAmount = -entry.amountMilliunits
            case .internalTransfer:
                guard entry.reportingRole == .transfer,
                      entry.amountMilliunits != 0 else { continue }
                // The app supplies only the savings-account side: deposits
                // are positive and withdrawals are negative.
                reportedAmount = entry.amountMilliunits
            case .income, .cardPayment, .reimbursement, .goalSpend,
                 .goalRefund, .excluded, .unknown:
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
            if group.reportingRole == nil {
                group.reportingRole = entry.reportingRole
            }
            var category = group.categories[entry.categoryKey]
                ?? CategoryBucket(name: entry.categoryName)
            category.spent += reportedAmount
            // Split legs share the parent id; list each transaction once.
            if !category.transactionIds.contains(entry.transactionId) {
                category.transactionIds.append(entry.transactionId)
            }
            category.lineAmounts[entry.transactionId, default: 0]
                += entry.amountMilliunits
            group.categories[entry.categoryKey] = category
            groups[groupID] = group
            months[month] = groups
        }

        return monthStarts.map { month in
            var monthGroups = months[month] ?? [:]
            for definition in groupDefinitions
            where monthGroups[definition.id] == nil {
                monthGroups[definition.id] = GroupBucket(name: definition.name)
            }
            let groups = monthGroups.map { groupID, bucket in
                let categories = bucket.categories
                    .map { key, category in
                        SpendingHistoryCategoryTotal(
                            id: key,
                            name: category.name,
                            spentMilliunits: category.spent,
                            transactionIds: category.transactionIds,
                            lineAmountsByTransactionId: category.lineAmounts
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
                    categories: categories,
                    reportingRole: bucket.reportingRole
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
                // A net-negative group is refund inflow exceeding spending
                // (usually misclassified income/reimbursements) — it must not
                // erase other groups' real spending from the headline. Clamp
                // to zero so the total matches the visible group columns.
                totalMilliunits: groups.reduce(0) {
                    $0 + max(0, $1.spentMilliunits)
                },
                ordinaryTotalMilliunits: groups.reduce(0) {
                    $1.isOrdinarySpending
                        ? $0 + max(0, $1.spentMilliunits) : $0
                },
                groups: groups
            )
        }
    }
}
