import Foundation
import Money
import Models

/// A user-authored recurring expectation: the only authoritative source of
/// dated future events after the Plaid-first clean start (YNAB schedules
/// never enter projections). Created manually or from an approved
/// transaction; automatic recurring detection is deferred.
public struct RecurringExpectation: Sendable, Hashable, Identifiable {
    public let id: String
    /// Canonical account the activity posts to (cash account or card).
    public let accountId: String
    /// Transfer destination; nil for non-transfers.
    public let destinationAccountId: String?
    public let payeeName: String
    public let payeeCanonicalId: String?
    public let categoryCanonicalId: String?
    public let categoryName: String?
    /// Card payments are never modeled here — the statement/autopay
    /// forecaster owns them.
    public let treatment: ForecastTreatment
    public let cadence: CommitmentCadence
    public let nextOccurrence: Date
    /// User-entered, signed: negative outflow, positive income. The sign is
    /// the expectation's direction.
    public let amount: Money

    public init(
        id: String,
        accountId: String,
        destinationAccountId: String? = nil,
        payeeName: String,
        payeeCanonicalId: String? = nil,
        categoryCanonicalId: String? = nil,
        categoryName: String? = nil,
        treatment: ForecastTreatment,
        cadence: CommitmentCadence,
        nextOccurrence: Date,
        amount: Money
    ) {
        self.id = id
        self.accountId = accountId
        self.destinationAccountId = destinationAccountId
        self.payeeName = payeeName
        self.payeeCanonicalId = payeeCanonicalId
        self.categoryCanonicalId = categoryCanonicalId
        self.categoryName = categoryName
        self.treatment = treatment
        self.cadence = cadence
        self.nextOccurrence = nextOccurrence
        self.amount = amount
    }

    /// The projector/forecaster integration: an expectation compiles into
    /// the same scheduled-summary shape the projection pipeline already
    /// expands, subtracts from the historical ordinary-spending estimate
    /// (exactly-once), and feeds into card statement projections.
    ///
    /// Cash behavior by type:
    /// - Cash-account bills → dated cash outflows; income → dated inflows.
    /// - Expected card purchases (ordinary spending on a card account) raise
    ///   that card's projected statement; only the generated autopay becomes
    ///   a cash outflow.
    /// - Internal transfers carry `transferAccountId` so pool math nets them
    ///   out when both sides are included.
    /// - Investment contributions are cash outflows here while staying
    ///   outside every spending total.
    public func toScheduledSummary() -> ScheduledTransactionSummary {
        let projectedAmount = RecurringExpectations.allowedTreatments.contains(
            treatment
        ) ? amount : Money.zero
        return ScheduledTransactionSummary(
            id: "expectation:\(id)",
            accountId: accountId,
            nextDate: nextOccurrence,
            frequency: cadence.scheduleFrequency,
            amount: projectedAmount,
            payeeName: payeeName,
            categoryId: categoryCanonicalId,
            transferAccountId: treatment == .internalTransfer
                ? destinationAccountId
                : nil
        )
    }
}

extension CommitmentCadence {
    public var scheduleFrequency: ScheduleFrequency {
        switch self {
        case .weekly: .weekly
        case .biweekly: .everyOtherWeek
        case .semimonthly: .twiceAMonth
        case .monthly: .monthly
        case .quarterly: .every3Months
        case .annual: .yearly
        }
    }
}

public enum RecurringExpectations {
    /// Treatments an expectation may carry. Card payments stay with the
    /// statement/autopay forecaster.
    public static let allowedTreatments: [ForecastTreatment] = [
        .ordinarySpending, .income, .internalTransfer, .investmentContribution
    ]

    /// The bounded window for matching an approved posted transaction to an
    /// expected occurrence. Short cadences stay below half their period;
    /// monthly bills get up to two weeks because statement dates commonly
    /// shift around weekends and month boundaries.
    public static func occurrenceWindowDays(
        for cadence: CommitmentCadence
    ) -> Int {
        switch cadence {
        case .weekly: 3
        case .biweekly: 6
        case .semimonthly: 6
        case .monthly: 14
        case .quarterly, .annual: 7
        }
    }

    /// Recurring amounts may vary, but a tiny same-payee adjustment or fee
    /// must not stand in for the actual occurrence. Higher amounts remain
    /// uncapped so variable bills and legitimate one-time adjustments match.
    private static func hasPlausibleAmount(
        _ transaction: TransactionSummary,
        expectation: RecurringExpectation
    ) -> Bool {
        let expected = expectation.amount.absolute.milliunits
        guard expected > 0 else { return transaction.amount.isZero }
        return transaction.amount.absolute.milliunits >= expected / 2
    }

    /// The next occurrence after `date` for a cadence, anchored to `date`.
    /// Semimonthly uses paired days of month (1st/16th style) so a year of
    /// advancement never drifts.
    public static func advance(
        _ date: Date,
        cadence: CommitmentCadence,
        calendar: Calendar
    ) -> Date {
        switch cadence {
        case .weekly:
            calendar.date(byAdding: .day, value: 7, to: date) ?? date
        case .biweekly:
            calendar.date(byAdding: .day, value: 14, to: date) ?? date
        case .semimonthly:
            SemimonthlyMath.step(date, calendar: calendar) ?? date
        case .monthly:
            calendar.date(byAdding: .month, value: 1, to: date) ?? date
        case .quarterly:
            calendar.date(byAdding: .month, value: 3, to: date) ?? date
        case .annual:
            calendar.date(byAdding: .year, value: 1, to: date) ?? date
        }
    }

    /// Whether an approved transaction is this expectation's identity: same
    /// direction and payee evidence (canonical id when both sides have one,
    /// else name equality). The configured account is where the NEXT payment
    /// is expected, not part of a bill's identity — historical payments may
    /// legitimately move between cash accounts and cards. Category is
    /// corroborating, never sufficient on its own — a whole category must not
    /// collapse into one bill.
    public static func matchesIdentity(
        _ transaction: TransactionSummary,
        expectation: RecurringExpectation
    ) -> Bool {
        guard allowedTreatments.contains(expectation.treatment),
              !transaction.deleted,
              transaction.amount.milliunits.signum()
                == expectation.amount.milliunits.signum() else {
            return false
        }
        if let treatment = transaction.forecastTreatment,
           treatment != expectation.treatment {
            return false
        }
        // Category disambiguates when both sides carry one: two same-payee
        // expectations (e.g. Apple entertainment vs Apple shopping) must not
        // both claim one actual.
        if let transactionCategory = transaction.categoryCanonicalId,
           let expectationCategory = expectation.categoryCanonicalId,
           transactionCategory != expectationCategory {
            return false
        }
        if let transactionPayee = transaction.payeeCanonicalId,
           let expectationPayee = expectation.payeeCanonicalId {
            return transactionPayee == expectationPayee
        }
        guard let name = transaction.payeeName else { return false }
        let options: String.CompareOptions = [
            .caseInsensitive, .diacriticInsensitive
        ]
        return name.compare(
            expectation.payeeName, options: options
        ) == .orderedSame
    }

    /// Whether the transaction lands on the expectation's next occurrence
    /// (identity + bounded date window). A match replaces that occurrence
    /// and the expectation advances.
    public static func matchesNextOccurrence(
        _ transaction: TransactionSummary,
        expectation: RecurringExpectation,
        calendar: Calendar
    ) -> Bool {
        guard matchesIdentity(transaction, expectation: expectation),
              hasPlausibleAmount(transaction, expectation: expectation) else {
            return false
        }
        let days = abs(
            calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: expectation.nextOccurrence),
                to: calendar.startOfDay(for: transaction.date)
            ).day ?? .max
        )
        return days <= occurrenceWindowDays(for: expectation.cadence)
    }

    /// One approved transaction advances at most one expectation: the best
    /// occurrence match by date proximity. The configured account and amount
    /// only break ties; neither is a hard identity requirement.
    public static func bestOccurrenceMatch(
        for transaction: TransactionSummary,
        among expectations: [RecurringExpectation],
        calendar: Calendar
    ) -> RecurringExpectation? {
        expectations
            .filter {
                matchesNextOccurrence(
                    transaction, expectation: $0, calendar: calendar
                )
            }
            .min { lhs, rhs in
                func dayDistance(_ expectation: RecurringExpectation) -> Int {
                    abs(calendar.dateComponents(
                        [.day],
                        from: calendar.startOfDay(
                            for: expectation.nextOccurrence
                        ),
                        to: calendar.startOfDay(for: transaction.date)
                    ).day ?? .max)
                }
                func amountDistance(
                    _ expectation: RecurringExpectation
                ) -> Int64 {
                    abs(transaction.amount.milliunits
                        - expectation.amount.milliunits)
                }
                if dayDistance(lhs) != dayDistance(rhs) {
                    return dayDistance(lhs) < dayDistance(rhs)
                }
                if amountDistance(lhs) != amountDistance(rhs) {
                    return amountDistance(lhs) < amountDistance(rhs)
                }
                let lhsAccountMismatch = lhs.accountId != transaction.accountId
                let rhsAccountMismatch = rhs.accountId != transaction.accountId
                if lhsAccountMismatch != rhsAccountMismatch {
                    return !lhsAccountMismatch
                }
                return lhs.id < rhs.id
            }
    }

    /// Transaction ids of historical activity matched to active
    /// expectations. This is the AUTHORITATIVE exactly-once mechanism: the
    /// caller excludes these ids from the ordinary-spending estimate (and
    /// from card variable-charge history) and marks every expectation
    /// summary estimate-exempt, so the matched actuals — at their real
    /// amounts — are removed while dated events are added exactly once. A
    /// brand-new expectation with no matching history removes nothing.
    public static func matchedHistoricalIds(
        transactions: [TransactionSummary],
        expectations: [RecurringExpectation],
        calendar: Calendar = .current
    ) -> Set<String> {
        guard !expectations.isEmpty, !transactions.isEmpty else { return [] }

        struct OccurrenceKey: Hashable {
            let expectationIndex: Int
            let date: Date
        }
        struct Candidate {
            let transactionIndex: Int
            let occurrence: OccurrenceKey
            let dayDistance: Int
            let accountMismatch: Bool
            let amountDistance: Int64
        }

        let transactionDays = transactions.map {
            calendar.startOfDay(for: $0.date)
        }
        guard let earliestTransaction = transactionDays.min(),
              let latestTransaction = transactionDays.max() else { return [] }

        var candidates: [Candidate] = []
        for (expectationIndex, expectation) in expectations.enumerated() {
            let window = occurrenceWindowDays(for: expectation.cadence)
            let eligibleTransactionIndexes = transactions.indices.filter {
                matchesIdentity(
                    transactions[$0], expectation: expectation
                )
                && hasPlausibleAmount(
                    transactions[$0], expectation: expectation
                )
            }
            guard !eligibleTransactionIndexes.isEmpty else { continue }

            for occurrenceDate in historicalOccurrenceDates(
                for: expectation,
                earliestTransaction: earliestTransaction,
                latestTransaction: latestTransaction,
                calendar: calendar
            ) {
                let occurrence = OccurrenceKey(
                    expectationIndex: expectationIndex,
                    date: occurrenceDate
                )
                for transactionIndex in eligibleTransactionIndexes {
                    let dayDistance = abs(calendar.dateComponents(
                        [.day],
                        from: occurrenceDate,
                        to: transactionDays[transactionIndex]
                    ).day ?? .max)
                    guard dayDistance <= window else { continue }
                    candidates.append(Candidate(
                        transactionIndex: transactionIndex,
                        occurrence: occurrence,
                        dayDistance: dayDistance,
                        accountMismatch:
                            transactions[transactionIndex].accountId
                                != expectation.accountId,
                        amountDistance: abs(
                            transactions[transactionIndex].amount.milliunits
                                - expectation.amount.milliunits
                        )
                    ))
                }
            }
        }

        // Greedy assignment is deterministic and intentionally conservative:
        // one actual can satisfy only one expectation, and one expected date
        // can remove only one actual from the spending estimate.
        candidates.sort { lhs, rhs in
            if lhs.amountDistance != rhs.amountDistance {
                return lhs.amountDistance < rhs.amountDistance
            }
            if lhs.dayDistance != rhs.dayDistance {
                return lhs.dayDistance < rhs.dayDistance
            }
            if lhs.accountMismatch != rhs.accountMismatch {
                return !lhs.accountMismatch
            }
            if lhs.occurrence.date != rhs.occurrence.date {
                return lhs.occurrence.date < rhs.occurrence.date
            }
            if lhs.occurrence.expectationIndex
                != rhs.occurrence.expectationIndex {
                return lhs.occurrence.expectationIndex
                    < rhs.occurrence.expectationIndex
            }
            return transactions[lhs.transactionIndex].id
                < transactions[rhs.transactionIndex].id
        }

        var claimedTransactions: Set<Int> = []
        var claimedOccurrences: Set<OccurrenceKey> = []
        var matched: Set<String> = []
        for candidate in candidates {
            guard !claimedTransactions.contains(candidate.transactionIndex),
                  !claimedOccurrences.contains(candidate.occurrence) else {
                continue
            }
            claimedTransactions.insert(candidate.transactionIndex)
            claimedOccurrences.insert(candidate.occurrence)
            let transaction = transactions[candidate.transactionIndex]
            matched.insert(transaction.id)
            // The estimate walks split legs by leg id.
            for leg in transaction.subtransactions {
                matched.insert(leg.id)
            }
        }
        return matched
    }

    private static func historicalOccurrenceDates(
        for expectation: RecurringExpectation,
        earliestTransaction: Date,
        latestTransaction: Date,
        calendar: Calendar
    ) -> [Date] {
        let window = occurrenceWindowDays(for: expectation.cadence)
        let lowerBound = calendar.date(
            byAdding: .day, value: -window, to: earliestTransaction
        ) ?? earliestTransaction
        let upperBound = calendar.date(
            byAdding: .day, value: window, to: latestTransaction
        ) ?? latestTransaction
        var cursor = calendar.startOfDay(for: expectation.nextOccurrence)
        var dates: [Date] = []

        // A generous bound prevents malformed dates from creating an
        // unbounded loop while covering decades of even weekly history.
        for _ in 0..<2_000 {
            if cursor <= upperBound {
                dates.append(cursor)
            }
            if cursor < lowerBound { break }
            guard let previous = retreat(
                cursor, cadence: expectation.cadence, calendar: calendar
            ), previous < cursor else { break }
            cursor = calendar.startOfDay(for: previous)
        }
        return dates
    }

    private static func retreat(
        _ date: Date,
        cadence: CommitmentCadence,
        calendar: Calendar
    ) -> Date? {
        switch cadence {
        case .weekly:
            calendar.date(byAdding: .day, value: -7, to: date)
        case .biweekly:
            calendar.date(byAdding: .day, value: -14, to: date)
        case .semimonthly:
            SemimonthlyMath.step(date, calendar: calendar, direction: -1)
        case .monthly:
            calendar.date(byAdding: .month, value: -1, to: date)
        case .quarterly:
            calendar.date(byAdding: .month, value: -3, to: date)
        case .annual:
            calendar.date(byAdding: .year, value: -1, to: date)
        }
    }
}
