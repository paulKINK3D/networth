import Foundation
import Money

// MARK: - Buckets

/// Phase 1 operating-budget buckets. Income, Fixed, Necessities, and Surplus
/// drive the monthly report; Savings and Working are assignable during setup
/// but stay outside the Phase 1 plan. Excluded removes a category entirely.
public enum BudgetBucket: String, Codable, Sendable, CaseIterable, Identifiable {
    case income
    case fixed
    case necessities
    case surplus
    case savings
    case working
    case excluded

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .income: "Income"
        case .fixed: "Fixed"
        case .necessities: "Necessities"
        case .surplus: "Surplus"
        case .savings: "Savings"
        case .working: "Working"
        case .excluded: "Excluded"
        }
    }

    /// Buckets whose actual spending appears in the Phase 1 monthly report.
    public var isReportedSpending: Bool {
        switch self {
        case .fixed, .necessities, .surplus: true
        case .income, .savings, .working, .excluded: false
        }
    }
}

/// Name/group seeding for the initial bucket review. Once the user confirms,
/// stable category identities replace these so renames do not move categories.
public enum BudgetBucketDefaults {
    public static func bucket(
        forCategoryName name: String,
        groupName: String
    ) -> BudgetBucket? {
        let normalizedName = normalized(name)
        if normalizedName.hasPrefix("inflow") { return .income }
        if normalizedName.contains("deferred income") { return .income }
        if normalizedName == "reimbursements" || normalizedName == "reimbursement" {
            // Reimbursements never count as expected income; medical
            // reimbursement split legs reduce Medical via their category.
            return .excluded
        }
        if normalizedName == "uncategorized" {
            // YNAB's internal master category group also holds Uncategorized;
            // unlabeled activity must never default into Income.
            return .excluded
        }
        switch normalized(groupName) {
        case "necessities", "food/beverage", "food & beverage", "food beverage",
             "transportation":
            return .necessities
        case "surplus":
            return .surplus
        case "savings":
            return .savings
        case "working":
            return .working
        case "income":
            return .income
        default:
            return nil
        }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Resolves a transaction leg's category to a confirmed bucket. Keys accept
/// canonical category IDs, source category IDs, and normalized display names
/// so YNAB- and Plaid-sourced summaries land in the same bucket.
public struct BudgetBucketAssignments: Sendable, Hashable {
    public var bucketByCategoryKey: [String: BudgetBucket]
    public var bucketByNormalizedName: [String: BudgetBucket]

    public init(
        bucketByCategoryKey: [String: BudgetBucket] = [:],
        bucketByNormalizedName: [String: BudgetBucket] = [:]
    ) {
        self.bucketByCategoryKey = bucketByCategoryKey
        self.bucketByNormalizedName = bucketByNormalizedName
    }

    public func bucket(
        categoryCanonicalId: String?,
        categoryId: String?,
        categoryName: String?
    ) -> BudgetBucket? {
        if let categoryCanonicalId,
           let bucket = bucketByCategoryKey[categoryCanonicalId] {
            return bucket
        }
        if let categoryId, let bucket = bucketByCategoryKey[categoryId] {
            return bucket
        }
        guard let categoryName else { return nil }
        return bucketByNormalizedName[Self.normalizedName(categoryName)]
    }

    public mutating func assign(_ bucket: BudgetBucket, categoryKey: String) {
        bucketByCategoryKey[categoryKey] = bucket
    }

    public mutating func assign(_ bucket: BudgetBucket, categoryName: String) {
        bucketByNormalizedName[Self.normalizedName(categoryName)] = bucket
    }

    public static func normalizedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - Month

/// A calendar month with pure-arithmetic navigation so month math never
/// depends on a wall-clock `Date` until rendering needs one.
public struct BudgetMonth: Hashable, Codable, Sendable, Comparable, Identifiable {
    public let year: Int
    /// 1-based calendar month.
    public let month: Int

    public init(year: Int, month: Int) {
        // Normalize out-of-range months (e.g. month 13 → January next year).
        let zeroBased = month - 1
        let yearShift = Int(floor(Double(zeroBased) / 12.0))
        self.year = year + yearShift
        self.month = zeroBased - yearShift * 12 + 1
    }

    public init(containing date: Date, calendar: Calendar = .current) {
        let components = calendar.dateComponents([.year, .month], from: date)
        self.init(year: components.year ?? 2000, month: components.month ?? 1)
    }

    public var id: String { String(format: "%04d-%02d", year, month) }

    public func advanced(by months: Int) -> BudgetMonth {
        BudgetMonth(year: year, month: month + months)
    }

    public var next: BudgetMonth { advanced(by: 1) }
    public var previous: BudgetMonth { advanced(by: -1) }

    public func startDate(calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: 1))
            ?? .distantPast
    }

    public func interval(calendar: Calendar = .current) -> DateInterval {
        let start = startDate(calendar: calendar)
        let end = next.startDate(calendar: calendar)
        return DateInterval(start: start, end: max(start, end))
    }

    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let components = calendar.dateComponents([.year, .month], from: date)
        return components.year == year && components.month == month
    }

    public func dayCount(calendar: Calendar = .current) -> Int {
        calendar.range(of: .day, in: .month, for: startDate(calendar: calendar))?
            .count ?? 30
    }

    public static func < (lhs: BudgetMonth, rhs: BudgetMonth) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }
}

// MARK: - Fixed commitments

public enum CommitmentCadence: String, Codable, Sendable, CaseIterable, Identifiable {
    case weekly
    case biweekly
    case semimonthly
    case monthly
    case quarterly
    case annual

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .weekly: "Weekly"
        case .biweekly: "Every 2 Weeks"
        case .semimonthly: "Twice a Month"
        case .monthly: "Monthly"
        case .quarterly: "Quarterly"
        case .annual: "Annual"
        }
    }

    /// Interval stepping in days for date-anchored cadences. Month-shaped
    /// cadences return nil and use calendar month arithmetic instead.
    public var stepDays: Int? {
        switch self {
        case .weekly: 7
        case .biweekly: 14
        case .semimonthly, .monthly, .quarterly, .annual: nil
        }
    }

    /// A commitment quietly reads as stale once no activity has appeared for
    /// roughly two cadence periods plus grace. Stale never deactivates it.
    public var staleAfterDays: Int {
        switch self {
        case .weekly: 21
        case .biweekly: 35
        case .semimonthly: 40
        case .monthly: 75
        case .quarterly: 200
        case .annual: 430
        }
    }
}

/// How a commitment's planned per-occurrence amount is derived from history.
public enum CommitmentAmountBasis: String, Codable, Sendable, CaseIterable {
    /// Stable amounts (subscriptions, rent): plan with the latest amount.
    case latestAmount
    /// Variable amounts (utilities): plan with the arithmetic mean of recent
    /// occurrences so every observed charge contributes to the reserve.
    case recentMean
    /// Legacy persisted value. New detections use `recentMean`; existing
    /// confirmed commitments retain their already-saved suggested amount.
    case recentMedian

    public static let allCases: [CommitmentAmountBasis] = [
        .latestAmount, .recentMean
    ]
}

/// A user-confirmed recurring obligation. Confirmed commitments stay active
/// until explicitly disabled and override their category's bucket assignment.
public struct FixedCommitment: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let displayName: String
    /// Canonical payee ID when known, otherwise a normalized payee-name key.
    public let payeeKey: String
    /// Optional category scoping. Nil matches any category from the payee.
    public let categoryKey: String?
    public let cadence: CommitmentCadence
    public let amountBasis: CommitmentAmountBasis
    /// Planned per-occurrence amount (positive spending).
    public let amount: Money
    /// Most recent confirmed occurrence; anchors weekly/biweekly stepping.
    public let anchorDate: Date
    public let active: Bool

    public init(
        id: String,
        displayName: String,
        payeeKey: String,
        categoryKey: String?,
        cadence: CommitmentCadence,
        amountBasis: CommitmentAmountBasis,
        amount: Money,
        anchorDate: Date,
        active: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.payeeKey = payeeKey
        self.categoryKey = categoryKey
        self.cadence = cadence
        self.amountBasis = amountBasis
        self.amount = amount
        self.anchorDate = anchorDate
        self.active = active
    }

    /// Exact expected occurrence count for the selected month. Weekly and
    /// biweekly step from the anchor date; semimonthly is always 2; monthly 1.
    /// Quarterly/annual reserve fractionally, so their count is reported as 1.
    public func expectedOccurrenceCount(
        in month: BudgetMonth,
        calendar: Calendar = .current
    ) -> Int {
        switch cadence {
        case .weekly, .biweekly:
            return occurrenceDates(in: month, calendar: calendar).count
        case .semimonthly:
            return 2
        case .monthly, .quarterly, .annual:
            return 1
        }
    }

    /// Dates the commitment is expected to occur inside the month, stepped
    /// from the anchor for day-interval cadences. Empty for month-shaped ones.
    public func occurrenceDates(
        in month: BudgetMonth,
        calendar: Calendar = .current
    ) -> [Date] {
        guard let stepDays = cadence.stepDays else { return [] }
        return BudgetDateMath.steppedDates(
            anchor: anchorDate,
            stepDays: stepDays,
            in: month,
            calendar: calendar
        )
    }

    /// Planned reserve for one month. Quarterly and annual amounts reserve
    /// evenly across their period so every month carries its share.
    public func plannedAmount(
        in month: BudgetMonth,
        calendar: Calendar = .current
    ) -> Money {
        switch cadence {
        case .weekly, .biweekly:
            let count = expectedOccurrenceCount(in: month, calendar: calendar)
            return Money(milliunits: amount.milliunits * Int64(count))
        case .semimonthly:
            return Money(milliunits: amount.milliunits * 2)
        case .monthly:
            return amount
        case .quarterly:
            return amount.scaled(by: Decimal(1) / Decimal(3))
        case .annual:
            return amount.scaled(by: Decimal(1) / Decimal(12))
        }
    }

    public func isStale(lastObserved: Date?, asOf: Date) -> Bool {
        let reference = lastObserved ?? anchorDate
        let elapsed = asOf.timeIntervalSince(reference)
        return elapsed > TimeInterval(cadence.staleAfterDays) * 86_400
    }
}

/// A detected recurring candidate awaiting user confirmation. Candidates are
/// never auto-confirmed.
public struct FixedCommitmentCandidate: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let displayName: String
    public let payeeKey: String
    public let categoryKey: String?
    public let categoryName: String?
    public let cadence: CommitmentCadence
    public let amountBasis: CommitmentAmountBasis
    /// Positive per-occurrence planned amount.
    public let suggestedAmount: Money
    public let occurrenceCount: Int
    public let firstDate: Date
    public let lastDate: Date
    /// Recent per-occurrence amounts (positive), oldest first.
    public let recentAmounts: [Money]

    public init(
        id: String,
        displayName: String,
        payeeKey: String,
        categoryKey: String?,
        categoryName: String?,
        cadence: CommitmentCadence,
        amountBasis: CommitmentAmountBasis,
        suggestedAmount: Money,
        occurrenceCount: Int,
        firstDate: Date,
        lastDate: Date,
        recentAmounts: [Money]
    ) {
        self.id = id
        self.displayName = displayName
        self.payeeKey = payeeKey
        self.categoryKey = categoryKey
        self.categoryName = categoryName
        self.cadence = cadence
        self.amountBasis = amountBasis
        self.suggestedAmount = suggestedAmount
        self.occurrenceCount = occurrenceCount
        self.firstDate = firstDate
        self.lastDate = lastDate
        self.recentAmounts = recentAmounts
    }

    public func toCommitment(id: String) -> FixedCommitment {
        FixedCommitment(
            id: id,
            displayName: displayName,
            payeeKey: payeeKey,
            categoryKey: categoryKey,
            cadence: cadence,
            amountBasis: amountBasis,
            amount: suggestedAmount,
            anchorDate: lastDate
        )
    }
}

// MARK: - Income

/// The three annual take-home phases of a salaried paycheck: 401(k) + FICA
/// withheld early in the year, FICA-only once the 401(k) maxes out, and
/// post-FICA once the Social Security wage base is reached.
public enum IncomePhaseKind: String, Codable, Sendable, CaseIterable {
    case preTaxHeavy
    case ficaOnly
    case postFica

    public var displayName: String {
        switch self {
        case .preTaxHeavy: "Early Year"
        case .ficaOnly: "Mid Year"
        case .postFica: "Late Year"
        }
    }
}

/// One observed amount cluster of the primary paycheck inside one year.
public struct IncomePhaseObservation: Hashable, Codable, Sendable {
    public let kind: IncomePhaseKind
    public let year: Int
    /// Median per-paycheck take-home inside the phase.
    public let perPaycheckAmount: Money
    public let firstDate: Date
    public let lastDate: Date
    public let paycheckCount: Int

    public init(
        kind: IncomePhaseKind,
        year: Int,
        perPaycheckAmount: Money,
        firstDate: Date,
        lastDate: Date,
        paycheckCount: Int
    ) {
        self.kind = kind
        self.year = year
        self.perPaycheckAmount = perPaycheckAmount
        self.firstDate = firstDate
        self.lastDate = lastDate
        self.paycheckCount = paycheckCount
    }
}

/// Detected primary-paycheck pattern: cadence, anchor, and phase history.
public struct IncomePattern: Hashable, Codable, Sendable {
    public let payeeKey: String
    public let displayName: String
    public let cadence: CommitmentCadence
    /// Most recent observed paycheck date; anchors day-interval stepping.
    public let anchorDate: Date
    /// Paydays-of-month for semimonthly/monthly cadences. Values ≥ 29 clamp
    /// to the last day of shorter months.
    public let daysOfMonth: [Int]
    /// Every observed paycheck date of the primary payer, oldest first.
    /// Ground truth for months that already happened — posted-date drift
    /// makes backward cadence projection invent phantom paydays.
    public let observedPaycheckDates: [Date]
    /// Observed phases, oldest first.
    public let phases: [IncomePhaseObservation]

    public init(
        payeeKey: String,
        displayName: String,
        cadence: CommitmentCadence,
        anchorDate: Date,
        daysOfMonth: [Int] = [],
        observedPaycheckDates: [Date] = [],
        phases: [IncomePhaseObservation]
    ) {
        self.payeeKey = payeeKey
        self.displayName = displayName
        self.cadence = cadence
        self.anchorDate = anchorDate
        self.daysOfMonth = daysOfMonth
        self.observedPaycheckDates = observedPaycheckDates
        self.phases = phases
    }

    /// Exact expected paydays in the month — the source of three-paycheck
    /// months for biweekly earners. Paychecks that actually posted are the
    /// record for everything up to the anchor; cadence stepping projects only
    /// dates after it, so a completed month can never gain a phantom payday.
    public func expectedPaycheckDates(
        in month: BudgetMonth,
        calendar: Calendar = .current
    ) -> [Date] {
        let interval = month.interval(calendar: calendar)
        let anchorDay = calendar.startOfDay(for: anchorDate)
        let observed = observedPaycheckDates
            .map { calendar.startOfDay(for: $0) }
            .filter { $0 >= interval.start && $0 < interval.end }
        let projected: [Date]
        if let stepDays = cadence.stepDays {
            projected = BudgetDateMath.steppedDates(
                anchor: anchorDate,
                stepDays: stepDays,
                in: month,
                calendar: calendar
            ).filter { $0 > anchorDay }
        } else {
            let days = daysOfMonth.isEmpty
                ? [calendar.component(.day, from: anchorDate)]
                : daysOfMonth
            let lastDay = month.dayCount(calendar: calendar)
            projected = days
                .map { min($0, lastDay) }
                .compactMap {
                    calendar.date(from: DateComponents(
                        year: month.year, month: month.month, day: $0
                    ))
                }
                .filter { $0 > anchorDay }
        }
        var seen = Set<Date>()
        return (observed + projected)
            .filter { seen.insert($0).inserted }
            .sorted()
    }

    public func expectedPaycheckCount(
        in month: BudgetMonth,
        calendar: Calendar = .current
    ) -> Int {
        expectedPaycheckDates(in: month, calendar: calendar).count
    }

    /// Conservative per-paycheck estimate for planning the month. Current-year
    /// observations win; without them, the prior year's phase covering the
    /// same part of the year is used, never assuming an unobserved step-up.
    public func expectedPerPaycheckAmount(
        for month: BudgetMonth,
        calendar: Calendar = .current
    ) -> Money {
        let sameYear = phases
            .filter { $0.year == month.year }
            .sorted { $0.lastDate < $1.lastDate }
        if !sameYear.isEmpty {
            // The phase in effect during the requested month — a completed
            // May must never be priced at August's post-step-up take-home.
            // For current/future months this resolves to the latest observed
            // phase, so no unobserved step-up is ever assumed.
            let covering = sameYear.last {
                calendar.component(.month, from: $0.firstDate) <= month.month
            }
            return (covering ?? sameYear.first)?.perPaycheckAmount ?? .zero
        }
        let priorYears = phases
            .filter { $0.year < month.year }
            .sorted { ($0.year, $0.lastDate.timeIntervalSince1970)
                < ($1.year, $1.lastDate.timeIntervalSince1970) }
        guard let referenceYear = priorYears.last?.year else { return .zero }
        let reference = priorYears.filter { $0.year == referenceYear }
        // The phase that covered this month in the reference year; when the
        // month precedes every observed phase, fall back to the earliest
        // (lowest) phase rather than assuming a later step-up.
        let covering = reference.last {
            calendar.component(.month, from: $0.firstDate) <= month.month
        }
        return (covering ?? reference.first)?.perPaycheckAmount ?? .zero
    }

    public func expectedIncome(
        for month: BudgetMonth,
        calendar: Calendar = .current
    ) -> Money {
        let count = expectedPaycheckCount(in: month, calendar: calendar)
        let perPaycheck = expectedPerPaycheckAmount(
            for: month, calendar: calendar
        )
        return Money(milliunits: perPaycheck.milliunits * Int64(count))
    }
}

// MARK: - Monthly plan

public struct FixedCommitmentLine: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let cadence: CommitmentCadence
    public let planned: Money
    public let actual: Money
    public let expectedOccurrences: Int
    public let isStale: Bool

    public init(
        id: String,
        displayName: String,
        cadence: CommitmentCadence,
        planned: Money,
        actual: Money,
        expectedOccurrences: Int,
        isStale: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.cadence = cadence
        self.planned = planned
        self.actual = actual
        self.expectedOccurrences = expectedOccurrences
        self.isStale = isStale
    }
}

/// Actual per-bucket totals for one month. Spending values are positive;
/// refunds subtract, so a heavy-reimbursement month can go negative.
public struct BudgetMonthActuals: Hashable, Sendable, Identifiable {
    public let month: BudgetMonth
    public let income: Money
    public let fixed: Money
    public let necessities: Money
    public let surplus: Money

    public init(
        month: BudgetMonth,
        income: Money = .zero,
        fixed: Money = .zero,
        necessities: Money = .zero,
        surplus: Money = .zero
    ) {
        self.month = month
        self.income = income
        self.fixed = fixed
        self.necessities = necessities
        self.surplus = surplus
    }

    public var id: String { month.id }
    public var reportedSpending: Money { fixed + necessities + surplus }
    public var margin: Money { income - reportedSpending }
}

/// The composed Phase 1 operating budget for one month:
/// expected income − fixed − typical necessities − surplus target = margin.
public struct MonthlyBudgetPlan: Hashable, Sendable {
    public let month: BudgetMonth
    /// True once the month has fully completed as of the report date.
    public let isCompleted: Bool
    public let expectedIncome: Money
    public let expectedPaycheckCount: Int
    public let actualIncome: Money
    public let plannedFixed: Money
    public let actualFixed: Money
    public let fixedLines: [FixedCommitmentLine]
    /// Rolling mean of the latest 12 completed months of Necessities.
    public let necessitiesEnvelope: Money
    public let actualNecessities: Money
    public let surplusTarget: Money
    public let actualSurplus: Money

    public init(
        month: BudgetMonth,
        isCompleted: Bool,
        expectedIncome: Money,
        expectedPaycheckCount: Int,
        actualIncome: Money,
        plannedFixed: Money,
        actualFixed: Money,
        fixedLines: [FixedCommitmentLine],
        necessitiesEnvelope: Money,
        actualNecessities: Money,
        surplusTarget: Money,
        actualSurplus: Money
    ) {
        self.month = month
        self.isCompleted = isCompleted
        self.expectedIncome = expectedIncome
        self.expectedPaycheckCount = expectedPaycheckCount
        self.actualIncome = actualIncome
        self.plannedFixed = plannedFixed
        self.actualFixed = actualFixed
        self.fixedLines = fixedLines
        self.necessitiesEnvelope = necessitiesEnvelope
        self.actualNecessities = actualNecessities
        self.surplusTarget = surplusTarget
        self.actualSurplus = actualSurplus
    }

    public var plannedMargin: Money {
        expectedIncome - plannedFixed - necessitiesEnvelope - surplusTarget
    }

    public var actualMargin: Money {
        actualIncome - actualFixed - actualNecessities - actualSurplus
    }

    /// Headline value: planned margin for current/future months, actual
    /// margin once the month has completed.
    public var primaryMargin: Money {
        isCompleted ? actualMargin : plannedMargin
    }
}

// MARK: - Date math

/// Shared day-interval stepping used by commitments and paychecks.
public enum BudgetDateMath {
    /// All dates inside the month reachable from `anchor` by whole steps of
    /// `stepDays`, in ascending order. Steps use calendar day arithmetic so
    /// DST transitions cannot drift the schedule.
    public static func steppedDates(
        anchor: Date,
        stepDays: Int,
        in month: BudgetMonth,
        calendar: Calendar = .current
    ) -> [Date] {
        guard stepDays > 0 else { return [] }
        let interval = month.interval(calendar: calendar)
        let anchorDay = calendar.startOfDay(for: anchor)
        // Jump near the interval start in one multiplication, then walk.
        let daysToStart = calendar.dateComponents(
            [.day],
            from: anchorDay,
            to: interval.start
        ).day ?? 0
        let stepsToStart = Int(floor(Double(daysToStart) / Double(stepDays)))
        guard var cursor = calendar.date(
            byAdding: .day,
            value: stepsToStart * stepDays,
            to: anchorDay
        ) else { return [] }
        var results: [Date] = []
        var guardRail = 0
        while cursor < interval.end && guardRail < 64 {
            if cursor >= interval.start {
                results.append(cursor)
            }
            guard let nextDate = calendar.date(
                byAdding: .day, value: stepDays, to: cursor
            ) else { break }
            cursor = nextDate
            guardRail += 1
        }
        return results
    }

    /// Median of milliunit values; even counts average the middle pair.
    public static func median(of values: [Money]) -> Money {
        guard !values.isEmpty else { return .zero }
        let sorted = values.map(\.milliunits).sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return Money(milliunits: (sorted[mid - 1] + sorted[mid]) / 2)
        }
        return Money(milliunits: sorted[mid])
    }

    /// Arithmetic mean of milliunit values. Every observation contributes,
    /// which is appropriate for amortizing lumpy spending over time.
    public static func mean(of values: [Money]) -> Money {
        guard !values.isEmpty else { return .zero }
        let total = values.reduce(Int64(0)) { $0 + $1.milliunits }
        return Money(milliunits: total / Int64(values.count))
    }
}
