import Foundation
import Money
import Models

// MARK: - Leg extraction

/// One countable transaction leg. Split parents contribute nothing directly;
/// each surviving split leg is processed individually.
struct BudgetLeg {
    let date: Date
    /// Signed: inflow positive, outflow negative (Networth convention).
    let amount: Money
    let payeeCanonicalId: String?
    let payeeName: String?
    let categoryCanonicalId: String?
    let categoryId: String?
    let categoryName: String?
    let treatment: ForecastTreatment?

    var payeeKey: String? {
        if let payeeCanonicalId, !payeeCanonicalId.isEmpty {
            return payeeCanonicalId
        }
        guard let payeeName else { return nil }
        let normalized = BudgetBucketAssignments.normalizedName(payeeName)
        return normalized.isEmpty ? nil : "name:\(normalized)"
    }

    var categoryKey: String? {
        if let categoryCanonicalId, !categoryCanonicalId.isEmpty {
            return categoryCanonicalId
        }
        if let categoryId, !categoryId.isEmpty { return categoryId }
        guard let categoryName else { return nil }
        let normalized = BudgetBucketAssignments.normalizedName(categoryName)
        return normalized.isEmpty ? nil : "catname:\(normalized)"
    }

    func bucket(in assignments: BudgetBucketAssignments) -> BudgetBucket? {
        if let assigned = assignments.bucket(
            categoryCanonicalId: categoryCanonicalId,
            categoryId: categoryId,
            categoryName: categoryName
        ) {
            return assigned
        }
        // Name-based safety net for categories the setup review never saw
        // (e.g. Plaid-native "Reimbursements"): a reimbursement deposit must
        // never fall through to its income treatment.
        guard let categoryName else { return nil }
        return BudgetBucketDefaults.bucket(
            forCategoryName: categoryName, groupName: ""
        )
    }
}

enum BudgetLegExtractor {
    /// Treatments that never contribute to the budget in any direction.
    private static let skippedTreatments: Set<ForecastTreatment> = [
        .internalTransfer, .cardPayment, .excluded
    ]

    private static let nonSpendPayees: Set<String> = [
        "manual balance adjustment",
        "reconciliation balance adjustment",
        "starting balance",
        "investment"
    ]

    static func legs(from transactions: [TransactionSummary]) -> [BudgetLeg] {
        var results: [BudgetLeg] = []
        for transaction in transactions where
            transaction.approved && !transaction.deleted {
            if let payeeName = transaction.payeeName,
               nonSpendPayees.contains(
                   BudgetBucketAssignments.normalizedName(payeeName)
               ) {
                continue
            }
            if transaction.isSplit {
                for leg in transaction.subtransactions {
                    guard !leg.deleted, leg.transferAccountId == nil else {
                        continue
                    }
                    let treatment = leg.forecastTreatment
                        ?? transaction.forecastTreatment
                    if let treatment, skippedTreatments.contains(treatment) {
                        continue
                    }
                    results.append(BudgetLeg(
                        date: transaction.date,
                        amount: leg.amount,
                        payeeCanonicalId: transaction.payeeCanonicalId,
                        payeeName: leg.payeeName ?? transaction.payeeName,
                        categoryCanonicalId: leg.categoryCanonicalId,
                        categoryId: leg.categoryId,
                        categoryName: leg.categoryName,
                        treatment: treatment
                    ))
                }
                continue
            }
            guard transaction.transferAccountId == nil else { continue }
            if let treatment = transaction.forecastTreatment,
               skippedTreatments.contains(treatment) {
                continue
            }
            results.append(BudgetLeg(
                date: transaction.date,
                amount: transaction.amount,
                payeeCanonicalId: transaction.payeeCanonicalId,
                payeeName: transaction.payeeName,
                categoryCanonicalId: transaction.categoryCanonicalId,
                categoryId: transaction.categoryId,
                categoryName: transaction.categoryName,
                treatment: transaction.forecastTreatment
            ))
        }
        return results
    }

    /// True when the leg counts toward income: explicit income treatment or an
    /// income-bucket category — unless the category resolves to a spending
    /// bucket, which turns the inflow into a category credit (refunds and
    /// medical reimbursements) that must never inflate expected income.
    static func isIncome(
        _ leg: BudgetLeg,
        assignments: BudgetBucketAssignments
    ) -> Bool {
        if let bucket = leg.bucket(in: assignments) {
            return bucket == .income
        }
        return leg.treatment == .income
    }
}

// MARK: - Aggregation

public struct BudgetAggregationResult: Sendable {
    public let actualsByMonth: [BudgetMonth: BudgetMonthActuals]
    /// Confirmed-commitment actual spending: commitment ID → month → total.
    public let commitmentActuals: [String: [BudgetMonth: Money]]
    /// Most recent outflow date observed per confirmed commitment.
    public let commitmentLastObserved: [String: Date]

    public init(
        actualsByMonth: [BudgetMonth: BudgetMonthActuals] = [:],
        commitmentActuals: [String: [BudgetMonth: Money]] = [:],
        commitmentLastObserved: [String: Date] = [:]
    ) {
        self.actualsByMonth = actualsByMonth
        self.commitmentActuals = commitmentActuals
        self.commitmentLastObserved = commitmentLastObserved
    }

    public func actuals(for month: BudgetMonth) -> BudgetMonthActuals {
        actualsByMonth[month] ?? BudgetMonthActuals(month: month)
    }
}

/// One month's itemization of a spending bucket: which categories produced
/// the total, and the largest individual charges. Explains the number —
/// no coaching.
public struct BudgetCategorySpendLine: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let amount: Money

    public init(id: String, name: String, amount: Money) {
        self.id = id
        self.name = name
        self.amount = amount
    }
}

public struct BudgetSpendItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let date: Date
    public let payeeName: String
    /// Positive spending; negative is a refund/credit.
    public let amount: Money

    public init(id: String, date: Date, payeeName: String, amount: Money) {
        self.id = id
        self.date = date
        self.payeeName = payeeName
        self.amount = amount
    }
}

public struct BudgetBucketBreakdown: Sendable {
    public let month: BudgetMonth
    public let bucket: BudgetBucket
    public let total: Money
    public let categories: [BudgetCategorySpendLine]
    public let largestItems: [BudgetSpendItem]
    /// Income only: deposits classified as income but outside the confirmed
    /// earners (tax refunds, windfalls). Visible, never counted.
    public let uncountedItems: [BudgetSpendItem]

    public init(
        month: BudgetMonth,
        bucket: BudgetBucket,
        total: Money,
        categories: [BudgetCategorySpendLine],
        largestItems: [BudgetSpendItem],
        uncountedItems: [BudgetSpendItem] = []
    ) {
        self.month = month
        self.bucket = bucket
        self.total = total
        self.categories = categories
        self.largestItems = largestItems
        self.uncountedItems = uncountedItems
    }
}

/// Single-pass reduction of reviewed transaction history into per-month bucket
/// totals. Refunds reduce their category; commitment matches override the
/// category bucket into Fixed.
public struct BudgetTransactionAggregator: Sendable {
    public init() {}

    private enum LegClassification {
        case income
        case spending(BudgetBucket, commitment: FixedCommitment?)
        case ignored
    }

    /// The one classification rule shared by totals and breakdowns so a
    /// drill-in always itemizes exactly what the headline counted.
    private func classify(
        _ leg: BudgetLeg,
        assignments: BudgetBucketAssignments,
        commitments: [FixedCommitment]
    ) -> LegClassification {
        let bucket = leg.bucket(in: assignments)
        if bucket == .income || (bucket == nil && leg.treatment == .income) {
            return .income
        }
        if let commitment = match(leg, in: commitments) {
            return .spending(.fixed, commitment: commitment)
        }
        guard let bucket else { return .ignored }
        return .spending(bucket, commitment: nil)
    }

    /// Whether an income-classified leg belongs to a confirmed earner. The
    /// operating budget tracks earned income: with payee keys provided, tax
    /// refunds and other windfalls stay out of the income totals (they remain
    /// visible as uncounted deposits in the Income breakdown).
    private func countsAsEarnedIncome(
        _ leg: BudgetLeg,
        incomePayeeKeys: Set<String>
    ) -> Bool {
        guard !incomePayeeKeys.isEmpty else { return true }
        guard let payeeKey = leg.payeeKey else { return false }
        return incomePayeeKeys.contains(payeeKey)
    }

    public func aggregate(
        transactions: [TransactionSummary],
        assignments: BudgetBucketAssignments,
        commitments: [FixedCommitment] = [],
        incomePayeeKeys: Set<String> = [],
        calendar: Calendar = .current
    ) -> BudgetAggregationResult {
        var income: [BudgetMonth: Money] = [:]
        var fixed: [BudgetMonth: Money] = [:]
        var necessities: [BudgetMonth: Money] = [:]
        var surplus: [BudgetMonth: Money] = [:]
        var commitmentActuals: [String: [BudgetMonth: Money]] = [:]
        var commitmentLastObserved: [String: Date] = [:]
        let activeCommitments = commitments.filter(\.active)

        for leg in BudgetLegExtractor.legs(from: transactions) {
            let month = BudgetMonth(containing: leg.date, calendar: calendar)
            switch classify(
                leg, assignments: assignments, commitments: activeCommitments
            ) {
            case .income:
                if countsAsEarnedIncome(leg, incomePayeeKeys: incomePayeeKeys) {
                    income[month, default: .zero] += leg.amount
                }
            case .spending(let bucket, let commitment):
                let spending = -leg.amount
                if let commitment {
                    fixed[month, default: .zero] += spending
                    commitmentActuals[commitment.id, default: [:]][
                        month, default: .zero
                    ] += spending
                    if spending.milliunits > 0 {
                        let previous = commitmentLastObserved[commitment.id]
                        if previous == nil || leg.date > previous! {
                            commitmentLastObserved[commitment.id] = leg.date
                        }
                    }
                    continue
                }
                switch bucket {
                case .fixed:
                    fixed[month, default: .zero] += spending
                case .necessities:
                    necessities[month, default: .zero] += spending
                case .surplus:
                    surplus[month, default: .zero] += spending
                case .income, .savings, .working, .excluded:
                    // Savings/Working stay outside Phase 1; unassigned
                    // spending waits for the setup review to place it.
                    break
                }
            case .ignored:
                break
            }
        }

        var months = Set(income.keys)
        months.formUnion(fixed.keys)
        months.formUnion(necessities.keys)
        months.formUnion(surplus.keys)
        var actualsByMonth: [BudgetMonth: BudgetMonthActuals] = [:]
        for month in months {
            actualsByMonth[month] = BudgetMonthActuals(
                month: month,
                income: income[month] ?? .zero,
                fixed: fixed[month] ?? .zero,
                necessities: necessities[month] ?? .zero,
                surplus: surplus[month] ?? .zero
            )
        }
        return BudgetAggregationResult(
            actualsByMonth: actualsByMonth,
            commitmentActuals: commitmentActuals,
            commitmentLastObserved: commitmentLastObserved
        )
    }

    /// Itemizes one month of one bucket: net per-category totals and the
    /// largest individual charges, using the same classification as the
    /// monthly totals.
    public func breakdown(
        of bucket: BudgetBucket,
        in month: BudgetMonth,
        transactions: [TransactionSummary],
        assignments: BudgetBucketAssignments,
        commitments: [FixedCommitment] = [],
        incomePayeeKeys: Set<String> = [],
        itemLimit: Int = 12,
        calendar: Calendar = .current
    ) -> BudgetBucketBreakdown {
        let activeCommitments = commitments.filter(\.active)
        var categoryTotals: [String: (name: String, milliunits: Int64)] = [:]
        var items: [BudgetSpendItem] = []
        var uncounted: [BudgetSpendItem] = []
        var total = Money.zero
        var itemIndex = 0
        for leg in BudgetLegExtractor.legs(from: transactions)
        where month.contains(leg.date, calendar: calendar) {
            let spending: Money
            switch classify(
                leg, assignments: assignments, commitments: activeCommitments
            ) {
            case .income where bucket == .income:
                guard countsAsEarnedIncome(
                    leg, incomePayeeKeys: incomePayeeKeys
                ) else {
                    uncounted.append(BudgetSpendItem(
                        id: "\(month.id)|uncounted|\(uncounted.count)",
                        date: leg.date,
                        payeeName: leg.payeeName ?? "Unknown",
                        amount: leg.amount
                    ))
                    continue
                }
                spending = leg.amount
            case .spending(let resolved, _) where resolved == bucket:
                spending = -leg.amount
            default:
                continue
            }
            total += spending
            let trimmedName = leg.categoryName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (trimmedName?.isEmpty == false ? trimmedName : nil)
                ?? "Uncategorized"
            let key = BudgetBucketAssignments.normalizedName(name)
            let existing = categoryTotals[key]
            categoryTotals[key] = (
                name: existing?.name ?? name,
                milliunits: (existing?.milliunits ?? 0) + spending.milliunits
            )
            items.append(BudgetSpendItem(
                id: "\(month.id)|\(itemIndex)",
                date: leg.date,
                payeeName: leg.payeeName ?? "Unknown",
                amount: spending
            ))
            itemIndex += 1
        }
        let categories = categoryTotals
            .map { BudgetCategorySpendLine(
                id: $0.key, name: $0.value.name,
                amount: Money(milliunits: $0.value.milliunits)
            ) }
            .sorted {
                if $0.amount != $1.amount { return $0.amount > $1.amount }
                return $0.name.localizedCaseInsensitiveCompare($1.name)
                    == .orderedAscending
            }
        let largest = items
            .sorted {
                if $0.amount != $1.amount { return $0.amount > $1.amount }
                return $0.date < $1.date
            }
            .prefix(itemLimit)
        return BudgetBucketBreakdown(
            month: month,
            bucket: bucket,
            total: total,
            categories: categories,
            largestItems: Array(largest),
            uncountedItems: uncounted
                .sorted {
                    if $0.amount != $1.amount { return $0.amount > $1.amount }
                    return $0.date < $1.date
                }
        )
    }

    private func match(
        _ leg: BudgetLeg,
        in commitments: [FixedCommitment]
    ) -> FixedCommitment? {
        guard let payeeKey = leg.payeeKey else { return nil }
        let categoryCandidates = Set(
            [leg.categoryCanonicalId, leg.categoryId, leg.categoryKey]
                .compactMap { $0 }
        )
        var payeeOnly: FixedCommitment?
        for commitment in commitments where commitment.payeeKey == payeeKey {
            guard let categoryKey = commitment.categoryKey else {
                payeeOnly = payeeOnly ?? commitment
                continue
            }
            if categoryCandidates.contains(categoryKey) {
                return commitment
            }
        }
        return payeeOnly
    }
}

// MARK: - Spending awareness report

/// One month of judgment-free spending truth: the total and the categories
/// that produced it. Everything that isn't income and isn't excluded counts.
public struct MonthlySpendingSummary: Sendable, Hashable {
    public let month: BudgetMonth
    public let total: Money
    public let categories: [BudgetCategorySpendLine]

    public init(
        month: BudgetMonth,
        total: Money,
        categories: [BudgetCategorySpendLine]
    ) {
        self.month = month
        self.total = total
        self.categories = categories
    }
}

extension BudgetTransactionAggregator {
    /// A leg counts as spending unless it resolves to income or an excluded
    /// category. Unassigned categories are spending by default — awareness
    /// must not depend on setup ceremony.
    private func isSpendingLeg(
        _ leg: BudgetLeg,
        assignments: BudgetBucketAssignments
    ) -> Bool {
        switch leg.bucket(in: assignments) {
        case .income, .excluded:
            return false
        case nil:
            return leg.treatment != .income
        default:
            return true
        }
    }

    private func categoryIdentity(
        for leg: BudgetLeg
    ) -> (key: String, name: String) {
        let trimmed = leg.categoryName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (trimmed?.isEmpty == false ? trimmed : nil)
            ?? "Uncategorized"
        return (BudgetBucketAssignments.normalizedName(name), name)
    }

    /// One pass over the window: net per-category spending for every month.
    public func spendingSummaries(
        transactions: [TransactionSummary],
        assignments: BudgetBucketAssignments,
        calendar: Calendar = .current
    ) -> [BudgetMonth: MonthlySpendingSummary] {
        var perMonth: [BudgetMonth: [String: (name: String, milliunits: Int64)]] = [:]
        for leg in BudgetLegExtractor.legs(from: transactions)
        where isSpendingLeg(leg, assignments: assignments) {
            let month = BudgetMonth(containing: leg.date, calendar: calendar)
            let identity = categoryIdentity(for: leg)
            let existing = perMonth[month]?[identity.key]
            perMonth[month, default: [:]][identity.key] = (
                name: existing?.name ?? identity.name,
                milliunits: (existing?.milliunits ?? 0) - leg.amount.milliunits
            )
        }
        var summaries: [BudgetMonth: MonthlySpendingSummary] = [:]
        for (month, totals) in perMonth {
            let categories = totals
                .map { BudgetCategorySpendLine(
                    id: $0.key, name: $0.value.name,
                    amount: Money(milliunits: $0.value.milliunits)
                ) }
                .sorted {
                    if $0.amount != $1.amount { return $0.amount > $1.amount }
                    return $0.name.localizedCaseInsensitiveCompare($1.name)
                        == .orderedAscending
                }
            summaries[month] = MonthlySpendingSummary(
                month: month,
                total: categories.map(\.amount).sum(),
                categories: categories
            )
        }
        return summaries
    }

    /// The transactions behind one category in one month, largest first.
    public func categoryItems(
        categoryKey: String,
        in month: BudgetMonth,
        transactions: [TransactionSummary],
        assignments: BudgetBucketAssignments,
        calendar: Calendar = .current
    ) -> [BudgetSpendItem] {
        var items: [BudgetSpendItem] = []
        for leg in BudgetLegExtractor.legs(from: transactions)
        where isSpendingLeg(leg, assignments: assignments)
            && month.contains(leg.date, calendar: calendar)
            && categoryIdentity(for: leg).key == categoryKey {
            items.append(BudgetSpendItem(
                id: "\(month.id)|\(categoryKey)|\(items.count)",
                date: leg.date,
                payeeName: leg.payeeName ?? "Unknown",
                amount: -leg.amount
            ))
        }
        return items.sorted {
            if $0.amount != $1.amount { return $0.amount > $1.amount }
            return $0.date < $1.date
        }
    }

    /// One-pass result: display-window summaries plus full-history fund
    /// drains, so an old fund cannot force a second walk over years of legs.
    public struct SpendingAggregation: Sendable {
        public let summariesByMonth: [BudgetMonth: MonthlySpendingSummary]
        public let linkedSpendingByFundId: [String: Money]

        public init(
            summariesByMonth: [BudgetMonth: MonthlySpendingSummary],
            linkedSpendingByFundId: [String: Money]
        ) {
            self.summariesByMonth = summariesByMonth
            self.linkedSpendingByFundId = linkedSpendingByFundId
        }
    }

    /// Single pass over the legs: category summaries are built only for
    /// months at or after `summariesStartingAt` (months the UI can show),
    /// while fund drains accumulate over the full window.
    public func spendingAggregation(
        transactions: [TransactionSummary],
        assignments: BudgetBucketAssignments,
        funds: [SinkingFund] = [],
        summariesStartingAt: BudgetMonth? = nil,
        calendar: Calendar = .current
    ) -> SpendingAggregation {
        let activeFunds = funds.filter { !$0.linkedCategoryKeys.isEmpty }
        var perMonth: [BudgetMonth: [String: (name: String, milliunits: Int64)]] = [:]
        var drained: [String: Int64] = [:]
        for leg in BudgetLegExtractor.legs(from: transactions)
        where isSpendingLeg(leg, assignments: assignments) {
            let identity = categoryIdentity(for: leg)
            if !activeFunds.isEmpty {
                let candidates = Set(
                    [identity.key, leg.categoryCanonicalId, leg.categoryId]
                        .compactMap { $0 }
                )
                for fund in activeFunds
                where leg.date >= fund.startDate
                    && !fund.linkedCategoryKeys.isDisjoint(with: candidates) {
                    drained[fund.id, default: 0] -= leg.amount.milliunits
                }
            }
            let month = BudgetMonth(containing: leg.date, calendar: calendar)
            if let start = summariesStartingAt, month < start { continue }
            let existing = perMonth[month]?[identity.key]
            perMonth[month, default: [:]][identity.key] = (
                name: existing?.name ?? identity.name,
                milliunits: (existing?.milliunits ?? 0) - leg.amount.milliunits
            )
        }
        var summaries: [BudgetMonth: MonthlySpendingSummary] = [:]
        for (month, totals) in perMonth {
            let categories = totals
                .map { BudgetCategorySpendLine(
                    id: $0.key, name: $0.value.name,
                    amount: Money(milliunits: $0.value.milliunits)
                ) }
                .sorted {
                    if $0.amount != $1.amount { return $0.amount > $1.amount }
                    return $0.name.localizedCaseInsensitiveCompare($1.name)
                        == .orderedAscending
                }
            summaries[month] = MonthlySpendingSummary(
                month: month,
                total: categories.map(\.amount).sum(),
                categories: categories
            )
        }
        return SpendingAggregation(
            summariesByMonth: summaries,
            linkedSpendingByFundId: drained.mapValues {
                Money(milliunits: $0)
            }
        )
    }

    /// Net linked-category spending per fund since each fund's start date —
    /// the automatic drain side of fund balances. Refunds flow back in.
    public func linkedSpending(
        for funds: [SinkingFund],
        transactions: [TransactionSummary],
        assignments: BudgetBucketAssignments,
        calendar: Calendar = .current
    ) -> [String: Money] {
        let active = funds.filter { !$0.linkedCategoryKeys.isEmpty }
        guard !active.isEmpty else { return [:] }
        var drained: [String: Int64] = [:]
        for leg in BudgetLegExtractor.legs(from: transactions)
        where isSpendingLeg(leg, assignments: assignments) {
            let identity = categoryIdentity(for: leg)
            let candidates = Set(
                [identity.key, leg.categoryCanonicalId, leg.categoryId]
                    .compactMap { $0 }
            )
            for fund in active
            where leg.date >= fund.startDate
                && !fund.linkedCategoryKeys.isDisjoint(with: candidates) {
                drained[fund.id, default: 0] -= leg.amount.milliunits
            }
        }
        return drained.mapValues { Money(milliunits: $0) }
    }
}

// MARK: - Planner

/// Composes the Phase 1 operating budget:
/// expected income − fixed − typical necessities − surplus target = margin.
public struct MonthlyBudgetPlanner: Sendable {
    public init() {}

    /// Rolling Necessities envelope: median of the latest `monthCount`
    /// completed months (zero-spend months included, current partial month
    /// excluded via `latestCompleted`).
    public func necessitiesEnvelope(
        aggregation: BudgetAggregationResult,
        latestCompleted: BudgetMonth,
        monthCount: Int = 12
    ) -> Money {
        guard monthCount > 0 else { return .zero }
        let values = (0..<monthCount).map { offset in
            aggregation.actuals(for: latestCompleted.advanced(by: -offset))
                .necessities
        }
        return BudgetDateMath.median(of: values)
    }

    public func plan(
        for month: BudgetMonth,
        aggregation: BudgetAggregationResult,
        commitments: [FixedCommitment],
        incomePattern: IncomePattern?,
        surplusTarget: Money,
        asOf: Date,
        calendar: Calendar = .current
    ) -> MonthlyBudgetPlan {
        let currentMonth = BudgetMonth(containing: asOf, calendar: calendar)
        let isCompleted = month < currentMonth
        let actuals = aggregation.actuals(for: month)
        // For past months the envelope reflects the 12 completed months that
        // preceded them; for current/future months, the latest 12 completed.
        let envelopeEnd = min(month.previous, currentMonth.previous)
        let envelope = necessitiesEnvelope(
            aggregation: aggregation,
            latestCompleted: envelopeEnd
        )

        var fixedLines: [FixedCommitmentLine] = []
        var plannedFixed = Money.zero
        for commitment in commitments where commitment.active {
            let planned = commitment.plannedAmount(
                in: month, calendar: calendar
            )
            plannedFixed += planned
            fixedLines.append(FixedCommitmentLine(
                id: commitment.id,
                displayName: commitment.displayName,
                cadence: commitment.cadence,
                planned: planned,
                actual: aggregation.commitmentActuals[commitment.id]?[month]
                    ?? .zero,
                expectedOccurrences: commitment.expectedOccurrenceCount(
                    in: month, calendar: calendar
                ),
                isStale: commitment.isStale(
                    lastObserved: aggregation
                        .commitmentLastObserved[commitment.id],
                    asOf: asOf
                )
            ))
        }
        fixedLines.sort {
            if $0.planned != $1.planned { return $0.planned > $1.planned }
            return $0.displayName.localizedCaseInsensitiveCompare(
                $1.displayName
            ) == .orderedAscending
        }

        return MonthlyBudgetPlan(
            month: month,
            isCompleted: isCompleted,
            expectedIncome: incomePattern?.expectedIncome(
                for: month, calendar: calendar
            ) ?? .zero,
            expectedPaycheckCount: incomePattern?.expectedPaycheckCount(
                in: month, calendar: calendar
            ) ?? 0,
            actualIncome: actuals.income,
            plannedFixed: plannedFixed,
            actualFixed: actuals.fixed,
            fixedLines: fixedLines,
            necessitiesEnvelope: envelope,
            actualNecessities: actuals.necessities,
            surplusTarget: surplusTarget,
            actualSurplus: actuals.surplus
        )
    }

    /// Ascending month series for the 12-month stacked chart, zero-filled so
    /// no-activity months still render.
    public func history(
        endingWith month: BudgetMonth,
        monthCount: Int = 12,
        aggregation: BudgetAggregationResult
    ) -> [BudgetMonthActuals] {
        guard monthCount > 0 else { return [] }
        return (0..<monthCount)
            .map { aggregation.actuals(for: month.advanced(by: $0 - monthCount + 1)) }
    }
}
