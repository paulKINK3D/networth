import Foundation
import Money
import Models

/// Detects the primary paycheck: payee, cadence with exact expected paycheck
/// counts (including three-paycheck biweekly months), and the three annual
/// take-home phases. Reimbursements and category credits never participate.
public struct IncomeAnalyzer: Sendable {
    public init() {}

    public func detectPattern(
        transactions: [TransactionSummary],
        assignments: BudgetBucketAssignments,
        asOf: Date,
        calendar: Calendar = .current
    ) -> IncomePattern? {
        let deposits = incomeDeposits(
            transactions: transactions,
            assignments: assignments,
            calendar: calendar
        )
        guard let primary = primaryGroup(
            from: deposits, asOf: asOf, calendar: calendar
        ) else {
            return nil
        }
        let occurrences = primary.occurrences.sorted { $0.date < $1.date }
        guard let anchor = occurrences.last,
              let cadenceResult = classifyCadence(
                  occurrences.map(\.date), calendar: calendar
              ) else {
            return nil
        }
        return IncomePattern(
            payeeKey: primary.payeeKey,
            displayName: primary.displayName,
            cadence: cadenceResult.cadence,
            anchorDate: anchor.date,
            daysOfMonth: cadenceResult.daysOfMonth,
            observedPaycheckDates: occurrences.map(\.date),
            phases: detectPhases(occurrences, calendar: calendar)
        )
    }

    // MARK: - Deposits

    private struct Occurrence {
        let date: Date
        let amount: Money
    }

    private struct Group {
        let payeeKey: String
        let displayName: String
        var occurrences: [Occurrence]
    }

    private func incomeDeposits(
        transactions: [TransactionSummary],
        assignments: BudgetBucketAssignments,
        calendar: Calendar
    ) -> [String: Group] {
        var groups: [String: Group] = [:]
        for leg in BudgetLegExtractor.legs(from: transactions) {
            guard BudgetLegExtractor.isIncome(leg, assignments: assignments),
                  leg.amount.milliunits > 0,
                  let payeeKey = leg.payeeKey else {
                continue
            }
            var group = groups[payeeKey] ?? Group(
                payeeKey: payeeKey,
                displayName: leg.payeeName ?? "Income",
                occurrences: []
            )
            // Same-day deposits from one payer merge into one paycheck.
            let day = calendar.startOfDay(for: leg.date)
            if let index = group.occurrences.firstIndex(
                where: { $0.date == day }
            ) {
                group.occurrences[index] = Occurrence(
                    date: day,
                    amount: group.occurrences[index].amount + leg.amount
                )
            } else {
                group.occurrences.append(
                    Occurrence(date: day, amount: leg.amount)
                )
            }
            groups[payeeKey] = group
        }
        return groups
    }

    private func primaryGroup(
        from groups: [String: Group],
        asOf: Date,
        calendar: Calendar
    ) -> Group? {
        // Judge on the trailing 15 months so an old employer cannot win, but
        // keep every occurrence for phase history once a payer is chosen.
        guard let windowStart = calendar.date(
            byAdding: .month, value: -15, to: asOf
        ) else { return nil }
        return groups.values
            .map { group -> (Group, Money, Int) in
                let recent = group.occurrences.filter {
                    $0.date >= windowStart && $0.date <= asOf
                }
                return (group, recent.map(\.amount).sum(), recent.count)
            }
            .filter { $0.2 >= 4 }
            .max { $0.1 < $1.1 }?
            .0
    }

    // MARK: - Cadence

    private func classifyCadence(
        _ dates: [Date],
        calendar: Calendar
    ) -> (cadence: CommitmentCadence, daysOfMonth: [Int])? {
        guard dates.count >= 4 else { return nil }
        let gaps = zip(dates.dropFirst(), dates).compactMap {
            calendar.dateComponents([.day], from: $1, to: $0).day
        }
        guard !gaps.isEmpty else { return nil }
        let medianGap = gaps.sorted()[gaps.count / 2]
        switch medianGap {
        case 5...9:
            return (.weekly, [])
        case 10...19:
            // Semimonthly pays land on two fixed days of the month; biweekly
            // pays land on one fixed weekday and drift through the month.
            if let days = stableDaysOfMonth(dates, calendar: calendar) {
                return (.semimonthly, days)
            }
            return (.biweekly, [])
        case 20...45:
            let day = mostCommonDay(dates, calendar: calendar)
            return (.monthly, [day])
        default:
            return nil
        }
    }

    private func stableDaysOfMonth(
        _ dates: [Date],
        calendar: Calendar
    ) -> [Int]? {
        let days = dates.map { date -> Int in
            let day = calendar.component(.day, from: date)
            return day >= 28 ? 31 : day
        }
        var counts: [Int: Int] = [:]
        for day in days { counts[day, default: 0] += 1 }
        let ranked = counts.sorted { $0.value > $1.value }
        let topTwo = ranked.prefix(2)
        let covered = topTwo.reduce(0) { $0 + $1.value }
        guard counts.count <= 3,
              Double(covered) >= Double(days.count) * 0.8,
              topTwo.count == 2 else {
            return nil
        }
        return topTwo.map(\.key).sorted()
    }

    private func mostCommonDay(_ dates: [Date], calendar: Calendar) -> Int {
        var counts: [Int: Int] = [:]
        for date in dates {
            counts[calendar.component(.day, from: date), default: 0] += 1
        }
        return counts.max { $0.value < $1.value }?.key ?? 1
    }

    // MARK: - Phases

    /// Clusters each year's paychecks into consecutive amount runs, merging
    /// noise, and maps up to three chronological clusters onto the annual
    /// 401(k)+FICA → FICA-only → post-FICA arc.
    private func detectPhases(
        _ occurrences: [Occurrence],
        calendar: Calendar
    ) -> [IncomePhaseObservation] {
        let byYear = Dictionary(grouping: occurrences) {
            calendar.component(.year, from: $0.date)
        }
        var results: [IncomePhaseObservation] = []
        for (year, paychecks) in byYear.sorted(by: { $0.key < $1.key }) {
            let sorted = paychecks.sorted { $0.date < $1.date }
            var clusters: [[Occurrence]] = []
            for paycheck in sorted {
                if var current = clusters.last,
                   let reference = current.last,
                   isSameAmountCluster(reference.amount, paycheck.amount) {
                    current.append(paycheck)
                    clusters[clusters.count - 1] = current
                } else {
                    clusters.append([paycheck])
                }
            }
            // Merge adjacent clusters whose medians re-converged (one-off
            // bonuses or corrections should not create phantom phases).
            var merged: [[Occurrence]] = []
            for cluster in clusters {
                if let previous = merged.last,
                   isSameAmountCluster(
                       BudgetDateMath.median(of: previous.map(\.amount)),
                       BudgetDateMath.median(of: cluster.map(\.amount))
                   ) {
                    merged[merged.count - 1] = previous + cluster
                } else {
                    merged.append(cluster)
                }
            }
            // Single-paycheck blips are corrections, not phases — fold them
            // forward so at most three meaningful clusters remain.
            let meaningful = merged.filter {
                $0.count >= 2 || merged.count <= 3
            }
            let kinds: [IncomePhaseKind] = [.preTaxHeavy, .ficaOnly, .postFica]
            for (index, cluster) in meaningful.prefix(3).enumerated() {
                guard let firstDate = cluster.first?.date,
                      let lastDate = cluster.last?.date else { continue }
                results.append(IncomePhaseObservation(
                    kind: kinds[index],
                    year: year,
                    perPaycheckAmount: BudgetDateMath.median(
                        of: cluster.map(\.amount)
                    ),
                    firstDate: firstDate,
                    lastDate: lastDate,
                    paycheckCount: cluster.count
                ))
            }
        }
        return results
    }

    private func isSameAmountCluster(_ lhs: Money, _ rhs: Money) -> Bool {
        let reference = max(abs(lhs.milliunits), 1)
        let difference = abs(lhs.milliunits - rhs.milliunits)
        return Double(difference) / Double(reference) <= 0.025
    }
}

// MARK: - Plaid-first paycheck detection

/// One receiving account's share of the detected paycheck, projected
/// independently so a checking/savings split can never overstate the
/// account that pays the bills.
public struct PaycheckPortion: Sendable, Hashable {
    public let accountId: String
    /// The latest CONFIRMED recurring amount for this account: the newest
    /// run of ≥2 matching deposits — or a lower singleton, adopted
    /// immediately because underestimating income is the safe direction. A
    /// single higher deposit is a bonus until it repeats; it never raises
    /// this.
    public let recurringAmount: Money
    /// Phase observations from this account's own deposit series, for
    /// seasonal (year-boundary) pricing.
    public let phases: [IncomePhaseObservation]

    public init(
        accountId: String,
        recurringAmount: Money,
        phases: [IncomePhaseObservation]
    ) {
        self.accountId = accountId
        self.recurringAmount = recurringAmount
        self.phases = phases
    }
}

/// The primary paycheck detected from confirmed Plaid income history,
/// compiled into exact dated inflows through the phase-aware
/// `IncomePattern` machinery (payday-of-month clamping, no unobserved
/// step-ups). A manual recurring-income expectation for the same payer
/// always overrides it.
public struct DetectedPaycheck: Sendable, Hashable {
    /// Cadence, paydays-of-month, and observed dates shared by every
    /// portion; phases here are pool-scoped totals kept for reference.
    public let pattern: IncomePattern
    public let payeeCanonicalId: String?
    /// Per-account shares inside the selected cash pool, largest first.
    /// Each projects its own historically observed portion.
    public let portions: [PaycheckPortion]
    /// First projected payday strictly after the as-of day.
    public let nextDate: Date
    /// Total expected take-home of the next paycheck across portions.
    public let nextAmount: Money
    public let confirmedDepositCount: Int

    public var payeeKey: String { pattern.payeeKey }
    public var displayName: String { pattern.displayName }
    public var cadence: CommitmentCadence { pattern.cadence }

    public init(
        pattern: IncomePattern,
        payeeCanonicalId: String?,
        portions: [PaycheckPortion],
        nextDate: Date,
        nextAmount: Money,
        confirmedDepositCount: Int
    ) {
        self.pattern = pattern
        self.payeeCanonicalId = payeeCanonicalId
        self.portions = portions
        self.nextDate = nextDate
        self.nextAmount = nextAmount
        self.confirmedDepositCount = confirmedDepositCount
    }

    /// A portion's projected amount for one month: the phase price for
    /// that month, capped by the confirmed recurring amount so an isolated
    /// upward spike (bonus) can never enter the forecast, while a
    /// year-boundary phase drop still lowers it.
    public static func portionAmount(
        pattern: IncomePattern,
        portion: PaycheckPortion,
        month: BudgetMonth,
        calendar: Calendar
    ) -> Money {
        let phasePattern = IncomePattern(
            payeeKey: pattern.payeeKey,
            displayName: pattern.displayName,
            cadence: pattern.cadence,
            anchorDate: pattern.anchorDate,
            daysOfMonth: pattern.daysOfMonth,
            observedPaycheckDates: pattern.observedPaycheckDates,
            phases: portion.phases
        )
        let phasePriced = phasePattern.expectedPerPaycheckAmount(
            for: month, calendar: calendar
        )
        guard phasePriced.milliunits > 0 else {
            return portion.recurringAmount
        }
        return min(phasePriced, portion.recurringAmount)
    }

    public func amount(
        for portion: PaycheckPortion,
        in month: BudgetMonth,
        calendar: Calendar = .current
    ) -> Money {
        Self.portionAmount(
            pattern: pattern, portion: portion, month: month,
            calendar: calendar
        )
    }

    /// Exact dated inflows for the projection horizon: one single-occurrence
    /// summary per expected payday PER RECEIVING ACCOUNT, each priced by
    /// its month's phase under the confirmed-amount cap. Dated events
    /// cannot drift the way frequency stepping can, and semimonthly or
    /// monthly paydays keep their detected days of month.
    public func scheduledSummaries(
        asOf: Date,
        horizonDays: Int,
        calendar: Calendar = .current
    ) -> [ScheduledTransactionSummary] {
        guard let end = calendar.date(
            byAdding: .day, value: max(1, horizonDays), to: asOf
        ) else { return [] }
        let todayStart = calendar.startOfDay(for: asOf)
        var summaries: [ScheduledTransactionSummary] = []
        var month = BudgetMonth(containing: asOf, calendar: calendar)
        let lastMonth = BudgetMonth(containing: end, calendar: calendar)
        while month <= lastMonth {
            let amounts = portions.map {
                (portion: $0, amount: amount(for: $0, in: month, calendar: calendar))
            }
            for payday in pattern.expectedPaycheckDates(
                in: month, calendar: calendar
            ) where payday > todayStart && payday <= end {
                let day = calendar.dateComponents(
                    [.year, .month, .day], from: payday
                )
                for entry in amounts where entry.amount.milliunits > 0 {
                    summaries.append(ScheduledTransactionSummary(
                        id: String(
                            format: "detected-paycheck:%@:%04d-%02d-%02d:%@",
                            payeeKey, day.year ?? 0, day.month ?? 0,
                            day.day ?? 0, entry.portion.accountId
                        ),
                        accountId: entry.portion.accountId,
                        nextDate: payday,
                        frequency: .never,
                        amount: entry.amount,
                        payeeName: displayName
                    ))
                }
            }
            month = month.next
        }
        return summaries
    }
}

/// Detection outcome, including the reasons a paycheck could NOT be
/// projected so the UI can explain the gap instead of silently omitting
/// income.
public enum PaycheckDetection: Sendable, Hashable {
    case detected(DetectedPaycheck)
    /// Two or more expected paydays have passed since the last confirmed
    /// deposit — projecting further income would be dangerously optimistic.
    case staleHistory(payeeName: String, lastDepositDate: Date)
    /// The paycheck pattern is real, but its deposits land only in accounts
    /// outside the selected cash pool — the projection would silently drop
    /// the inflows.
    case depositsExcluded(payeeName: String)
    /// The largest income payer has fewer than four confirmed deposits in
    /// the trailing window — not enough evidence to project a schedule.
    case insufficientHistory(payeeName: String?, depositCount: Int)
    /// Enough deposits, but their gaps fit no supported cadence.
    case unstableCadence(payeeName: String, depositCount: Int)
    case noConfirmedIncome
}

extension IncomeAnalyzer {
    /// One payday: same-day deposits from one payer merge, but the amount
    /// stays broken down per receiving account so pool scoping is exact.
    private struct PaycheckOccurrence {
        let date: Date
        var amountByAccount: [String: Money]

        var totalAmount: Money { amountByAccount.values.sum() }

        func selectedAmount(in selectedAccountIds: Set<String>) -> Money {
            amountByAccount
                .filter { selectedAccountIds.contains($0.key) }
                .values.sum()
        }
    }

    private struct PaycheckGroup {
        let payeeKey: String
        let payeeCanonicalId: String?
        let displayName: String
        var occurrences: [PaycheckOccurrence]
    }

    /// How many expected paydays may pass without a confirmed deposit
    /// before the pattern is considered dead. One missed occurrence is
    /// routine review lag; two is a stopped paycheck.
    private static var maxMissedPaydays: Int { 1 }

    /// Detects the primary paycheck from confirmed transactions whose
    /// forecast treatment is `.income` (split legs included). No budget
    /// assignments are involved — this is the Plaid-first path.
    ///
    /// `selectedAccountIds` is the projection's cash pool: payer choice and
    /// cadence use every deposit, but projected amounts count only the
    /// portion landing in the pool, and a paycheck depositing entirely
    /// outside it is reported as excluded rather than silently dropped.
    public func detectPaycheck(
        confirmedTransactions: [TransactionSummary],
        selectedAccountIds: Set<String>,
        asOf: Date,
        calendar: Calendar = .current
    ) -> PaycheckDetection {
        var groups: [String: PaycheckGroup] = [:]

        func add(
            amount: Money,
            date: Date,
            accountId: String,
            payeeName: String?,
            payeeCanonicalId: String?
        ) {
            let key: String
            if let payeeCanonicalId {
                key = payeeCanonicalId
            } else if let payeeName {
                key = "name:" + payeeName
                    .folding(options: .diacriticInsensitive, locale: nil)
                    .lowercased()
            } else {
                return
            }
            var group = groups[key] ?? PaycheckGroup(
                payeeKey: key,
                payeeCanonicalId: payeeCanonicalId,
                displayName: payeeName ?? "Income",
                occurrences: []
            )
            // Same-day deposits from one payer merge into one paycheck.
            let day = calendar.startOfDay(for: date)
            if let index = group.occurrences.firstIndex(
                where: { $0.date == day }
            ) {
                group.occurrences[index]
                    .amountByAccount[accountId, default: .zero] += amount
            } else {
                group.occurrences.append(PaycheckOccurrence(
                    date: day, amountByAccount: [accountId: amount]
                ))
            }
            groups[key] = group
        }

        for transaction in confirmedTransactions
        where !transaction.deleted && transaction.approved {
            if transaction.isSplit {
                for leg in transaction.subtransactions
                where !leg.deleted
                    && leg.forecastTreatment == .income
                    && leg.amount.milliunits > 0 {
                    add(
                        amount: leg.amount,
                        date: transaction.date,
                        accountId: transaction.accountId,
                        payeeName: leg.payeeName ?? transaction.payeeName,
                        payeeCanonicalId: transaction.payeeCanonicalId
                    )
                }
            } else if transaction.forecastTreatment == .income,
                      transaction.amount.milliunits > 0 {
                add(
                    amount: transaction.amount,
                    date: transaction.date,
                    accountId: transaction.accountId,
                    payeeName: transaction.payeeName,
                    payeeCanonicalId: transaction.payeeCanonicalId
                )
            }
        }
        guard !groups.isEmpty,
              let windowStart = calendar.date(
                  byAdding: .month, value: -15, to: asOf
              ) else {
            return .noConfirmedIncome
        }

        // Judge payers on the trailing 15 months so an old employer cannot
        // win on lifetime volume. Payer identity uses total deposits —
        // which account they land in is a separate question.
        let ranked = groups.values.compactMap {
            group -> (group: PaycheckGroup, recent: [PaycheckOccurrence], total: Money)? in
            let recent = group.occurrences
                .filter { $0.date >= windowStart && $0.date <= asOf }
                .sorted { $0.date < $1.date }
            guard !recent.isEmpty else { return nil }
            return (group, recent, recent.map(\.totalAmount).sum())
        }
        guard let best = ranked.max(by: { $0.total < $1.total }) else {
            return .noConfirmedIncome
        }
        let qualified = ranked.filter { $0.recent.count >= 4 }
        guard let primary = qualified.max(by: { $0.total < $1.total }) else {
            return .insufficientHistory(
                payeeName: best.group.displayName,
                depositCount: best.recent.count
            )
        }
        guard let coarse = classifyCadence(
            primary.recent.map(\.date), calendar: calendar
        ) else {
            return .unstableCadence(
                payeeName: primary.group.displayName,
                depositCount: primary.recent.count
            )
        }

        // Off-cycle hygiene: a bonus paid on its own date must not shift
        // the payday anchor, distort observed dates, or masquerade as a
        // recurring deposit. Keep only occurrences that sit on the payday
        // grid, then re-classify from the cleaned series.
        let onCycle = onCycleOccurrences(
            primary.recent,
            cadence: coarse.cadence,
            daysOfMonth: coarse.daysOfMonth,
            calendar: calendar
        )
        guard onCycle.count >= 4 else {
            return .insufficientHistory(
                payeeName: primary.group.displayName,
                depositCount: onCycle.count
            )
        }
        let dates = onCycle.map(\.date)
        guard let cadenceResult = classifyCadence(dates, calendar: calendar),
              let anchor = dates.last else {
            return .unstableCadence(
                payeeName: primary.group.displayName,
                depositCount: onCycle.count
            )
        }

        let datesOnlyPattern = IncomePattern(
            payeeKey: primary.group.payeeKey,
            displayName: primary.group.displayName,
            cadence: cadenceResult.cadence,
            anchorDate: anchor,
            daysOfMonth: cadenceResult.daysOfMonth,
            observedPaycheckDates: dates,
            phases: []
        )

        // Freshness: a pattern whose expected paydays keep passing without
        // deposits must stop projecting income, not extrapolate forever.
        // Missed paydays come from the same clamped enumeration that
        // generates the events, so a 31st payday checked in a 30-day month
        // can never miscount.
        let todayStart = calendar.startOfDay(for: asOf)
        var missed = 0
        var missedMonth = BudgetMonth(containing: anchor, calendar: calendar)
        let todayMonth = BudgetMonth(containing: asOf, calendar: calendar)
        while missedMonth <= todayMonth {
            missed += datesOnlyPattern.expectedPaycheckDates(
                in: missedMonth, calendar: calendar
            ).filter { $0 > anchor && $0 <= todayStart }.count
            missedMonth = missedMonth.next
        }
        guard missed <= Self.maxMissedPaydays else {
            return .staleHistory(
                payeeName: primary.group.displayName,
                lastDepositDate: anchor
            )
        }

        // Pool scoping: each selected account's share projects
        // independently from its own deposit series, so a checking/savings
        // split can never overstate the account that pays the bills. A
        // paycheck landing entirely outside the pool is excluded, not
        // silently projected.
        let scoped = onCycle.compactMap {
            occurrence -> Occurrence? in
            let amount = occurrence.selectedAmount(in: selectedAccountIds)
            guard amount.milliunits > 0 else { return nil }
            return Occurrence(date: occurrence.date, amount: amount)
        }
        guard !scoped.isEmpty else {
            return .depositsExcluded(payeeName: primary.group.displayName)
        }

        var seriesByAccount: [String: [Occurrence]] = [:]
        for occurrence in onCycle {
            for (account, amount) in occurrence.amountByAccount
            where selectedAccountIds.contains(account)
                && amount.milliunits > 0 {
                seriesByAccount[account, default: []].append(
                    Occurrence(date: occurrence.date, amount: amount)
                )
            }
        }
        // A recurring portion needs deposits on at least two paydays — the
        // same confirmation bar amounts use. A one-time deposit into a new
        // account (an on-payday bonus) never becomes a projected inflow.
        //
        // Each portion also has its own lifetime: after a direct-deposit
        // account switch the payer stays fresh (deposits continue into the
        // new account), but the old account's series must stop projecting
        // by the same missed-payday rule the payer-level check uses.
        func portionIsFresh(_ series: [Occurrence]) -> Bool {
            guard let last = series.map(\.date).max() else { return false }
            var missed = 0
            var month = BudgetMonth(containing: last, calendar: calendar)
            while month <= todayMonth {
                missed += datesOnlyPattern.expectedPaycheckDates(
                    in: month, calendar: calendar
                ).filter { $0 > last && $0 <= todayStart }.count
                month = month.next
            }
            return missed <= Self.maxMissedPaydays
        }
        let portions = seriesByAccount
            .filter { $0.value.count >= 2 && portionIsFresh($0.value) }
            .map { accountId, series -> (portion: PaycheckPortion, total: Money) in
                let sorted = series.sorted { $0.date < $1.date }
                return (
                    PaycheckPortion(
                        accountId: accountId,
                        recurringAmount: confirmedRecurringAmount(
                            sorted.map(\.amount)
                        ),
                        phases: detectPhases(sorted, calendar: calendar)
                    ),
                    sorted.map(\.amount).sum()
                )
            }
            .sorted {
                if $0.total != $1.total { return $0.total > $1.total }
                return $0.portion.accountId < $1.portion.accountId
            }
            .map(\.portion)
        guard !portions.isEmpty else {
            return .insufficientHistory(
                payeeName: primary.group.displayName,
                depositCount: seriesByAccount.values
                    .map(\.count).max() ?? 0
            )
        }

        let pattern = IncomePattern(
            payeeKey: primary.group.payeeKey,
            displayName: primary.group.displayName,
            cadence: cadenceResult.cadence,
            anchorDate: anchor,
            daysOfMonth: cadenceResult.daysOfMonth,
            observedPaycheckDates: dates,
            phases: detectPhases(scoped, calendar: calendar)
        )
        // The advertised next payday must be the first event the projection
        // will actually contain, so derive it from the same enumeration
        // that generates the dated inflows.
        var firstPayday = anchor
        var month = BudgetMonth(containing: asOf, calendar: calendar)
        search: for _ in 0..<3 {
            for payday in pattern.expectedPaycheckDates(
                in: month, calendar: calendar
            ) where payday > todayStart {
                firstPayday = payday
                break search
            }
            month = month.next
        }
        guard firstPayday > todayStart else {
            return .unstableCadence(
                payeeName: primary.group.displayName,
                depositCount: onCycle.count
            )
        }
        let nextMonth = BudgetMonth(containing: firstPayday, calendar: calendar)
        let nextAmount = portions.map {
            DetectedPaycheck.portionAmount(
                pattern: pattern, portion: $0, month: nextMonth,
                calendar: calendar
            )
        }.sum()
        guard nextAmount.milliunits > 0 else {
            return .unstableCadence(
                payeeName: primary.group.displayName,
                depositCount: onCycle.count
            )
        }
        return .detected(DetectedPaycheck(
            pattern: pattern,
            payeeCanonicalId: primary.group.payeeCanonicalId,
            portions: portions,
            nextDate: firstPayday,
            nextAmount: nextAmount,
            confirmedDepositCount: onCycle.count
        ))
    }

    /// Occurrences that sit on the payday grid. Interval cadences drop any
    /// deposit whose day gaps to BOTH neighbors are off a whole multiple of
    /// the step (±2 days absorbs holiday-shifted paydays); day-of-month
    /// cadences drop deposits more than 3 days from every detected payday
    /// of month. Off-cycle bonuses are removed entirely — they never enter
    /// anchors, observed dates, phases, or portions.
    private func onCycleOccurrences(
        _ occurrences: [PaycheckOccurrence],
        cadence: CommitmentCadence,
        daysOfMonth: [Int],
        calendar: Calendar
    ) -> [PaycheckOccurrence] {
        switch cadence {
        case .weekly, .biweekly:
            let stepDays = cadence == .weekly ? 7 : 14
            func fitsGrid(_ from: Date, _ to: Date) -> Bool {
                guard let gap = calendar.dateComponents(
                    [.day], from: from, to: to
                ).day, gap > 0 else { return false }
                let remainder = gap % stepDays
                return min(remainder, stepDays - remainder) <= 2
            }
            return occurrences.indices.filter { index in
                let previousFits = index > 0
                    ? fitsGrid(occurrences[index - 1].date, occurrences[index].date)
                    : nil
                let nextFits = index < occurrences.count - 1
                    ? fitsGrid(occurrences[index].date, occurrences[index + 1].date)
                    : nil
                switch (previousFits, nextFits) {
                case (nil, nil):
                    return true
                case (let onlyPrevious?, nil):
                    return onlyPrevious
                case (nil, let onlyNext?):
                    return onlyNext
                case (let previous?, let next?):
                    return previous || next
                }
            }.map { occurrences[$0] }
        case .semimonthly, .monthly:
            guard !daysOfMonth.isEmpty else { return occurrences }
            return occurrences.filter { occurrence in
                let day = calendar.component(.day, from: occurrence.date)
                let clamped = day >= 28 ? 31 : day
                return daysOfMonth.contains { abs($0 - clamped) <= 3 }
            }
        default:
            return occurrences
        }
    }

    /// The amount the forecast is allowed to project for one account's
    /// deposit series: cluster consecutive matching amounts (2.5%
    /// tolerance) into runs, then take the newest run's median when it has
    /// ≥2 deposits. A newest-run SINGLETON adopts immediately when lower
    /// (underestimating income is safe) but falls back to the previous
    /// run's median when higher — an isolated upward spike is a bonus
    /// until it repeats.
    func confirmedRecurringAmount(_ amounts: [Money]) -> Money {
        var runs: [[Money]] = []
        for amount in amounts {
            if let last = runs.last?.last,
               isSameAmountCluster(last, amount) {
                runs[runs.count - 1].append(amount)
            } else {
                runs.append([amount])
            }
        }
        guard let newest = runs.last else { return .zero }
        if newest.count >= 2 {
            return BudgetDateMath.median(of: newest)
        }
        guard runs.count >= 2, let single = newest.first else {
            return newest.first ?? .zero
        }
        let previous = BudgetDateMath.median(of: runs[runs.count - 2])
        return single > previous ? previous : single
    }

    /// The manual recurring-income expectation that overrides a detected
    /// paycheck: same payer (canonical id when both sides have one, else
    /// name equality). Manual income for a different payer coexists with
    /// the detected pattern.
    public static func manualIncomeOverride(
        for detected: DetectedPaycheck,
        expectations: [RecurringExpectation]
    ) -> RecurringExpectation? {
        expectations.first { expectation in
            guard expectation.treatment == .income,
                  expectation.amount.milliunits > 0 else { return false }
            if let lhs = expectation.payeeCanonicalId,
               let rhs = detected.payeeCanonicalId {
                return lhs == rhs
            }
            return expectation.payeeName.compare(
                detected.displayName,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
        }
    }
}
