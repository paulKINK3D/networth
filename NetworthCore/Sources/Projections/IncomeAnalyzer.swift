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
