import Foundation
import Money
import Models

/// Detects recurring spending candidates from stable payee/category history.
/// Detection is evidence only — candidates are surfaced for review and are
/// never auto-confirmed.
public struct FixedCommitmentDetector: Sendable {
    public init() {}

    public func candidates(
        transactions: [TransactionSummary],
        assignments: BudgetBucketAssignments,
        asOf: Date,
        calendar: Calendar = .current
    ) -> [FixedCommitmentCandidate] {
        var groups: [String: Group] = [:]
        for leg in BudgetLegExtractor.legs(from: transactions) {
            guard !BudgetLegExtractor.isIncome(leg, assignments: assignments),
                  leg.amount.isNegative,
                  let payeeKey = leg.payeeKey else {
                continue
            }
            let categoryKey = leg.categoryKey
            let id = "\(payeeKey)|\(categoryKey ?? "")"
            var group = groups[id] ?? Group(
                id: id,
                payeeKey: payeeKey,
                categoryKey: categoryKey,
                categoryName: leg.categoryName,
                displayName: leg.payeeName ?? "Unknown"
            )
            let day = calendar.startOfDay(for: leg.date)
            group.amountByDay[day, default: .zero] += -leg.amount
            groups[id] = group
        }

        return groups.values
            .compactMap { candidate(from: $0, asOf: asOf, calendar: calendar) }
            .sorted {
                if $0.monthlyImpact != $1.monthlyImpact {
                    return $0.monthlyImpact > $1.monthlyImpact
                }
                return $0.displayName.localizedCaseInsensitiveCompare(
                    $1.displayName
                ) == .orderedAscending
            }
    }

    private struct Group {
        let id: String
        let payeeKey: String
        let categoryKey: String?
        let categoryName: String?
        let displayName: String
        /// Same-day charges collapse into one occurrence.
        var amountByDay: [Date: Money] = [:]
    }

    private func candidate(
        from group: Group,
        asOf: Date,
        calendar: Calendar
    ) -> FixedCommitmentCandidate? {
        // Occurrences must be net outflows after same-day collapsing.
        let occurrences = group.amountByDay
            .filter { $0.value.milliunits > 0 }
            .sorted { $0.key < $1.key }
        guard occurrences.count >= 2,
              let first = occurrences.first,
              let last = occurrences.last else {
            return nil
        }
        let dates = occurrences.map(\.key)
        let gaps = zip(dates.dropFirst(), dates).compactMap {
            calendar.dateComponents([.day], from: $1, to: $0).day
        }
        guard let cadence = classifyCadence(
            gaps: gaps,
            dates: dates,
            occurrenceCount: occurrences.count,
            calendar: calendar
        ) else {
            return nil
        }
        // A candidate whose latest activity is already stale for its cadence
        // is a dead recurrence, not a commitment worth confirming.
        let sinceLast = asOf.timeIntervalSince(last.key)
        guard sinceLast >= 0,
              sinceLast <= TimeInterval(cadence.staleAfterDays) * 86_400 else {
            return nil
        }

        let recent = occurrences.suffix(6).map(\.value)
        let median = BudgetDateMath.median(of: recent)
        // Stability is judged on the last three occurrences so a price change
        // converges onto the new amount instead of dragging old history:
        // stable within 2% (or a dollar) plans with the latest amount,
        // variable amounts plan with the median of recent occurrences.
        let window = recent.suffix(3)
        let spread = (window.map(\.milliunits).max() ?? 0)
            - (window.map(\.milliunits).min() ?? 0)
        let windowMedian = BudgetDateMath.median(of: Array(window))
        let tolerance = max(windowMedian.milliunits * 2 / 100, 1_000)
        let isStable = spread <= tolerance
        return FixedCommitmentCandidate(
            id: group.id,
            displayName: group.displayName,
            payeeKey: group.payeeKey,
            categoryKey: group.categoryKey,
            categoryName: group.categoryName,
            cadence: cadence,
            amountBasis: isStable ? .latestAmount : .recentMedian,
            suggestedAmount: isStable ? last.value : median,
            occurrenceCount: occurrences.count,
            firstDate: first.key,
            lastDate: last.key,
            recentAmounts: Array(recent)
        )
    }

    private func classifyCadence(
        gaps: [Int],
        dates: [Date],
        occurrenceCount: Int,
        calendar: Calendar
    ) -> CommitmentCadence? {
        guard let medianGap = medianInt(gaps) else { return nil }
        switch medianGap {
        case 5...9:
            guard occurrenceCount >= 4 else { return nil }
            return consistency(of: gaps, within: 5...9) >= 0.7 ? .weekly : nil
        case 10...19:
            if occurrenceCount >= 4,
               hasStableDaysOfMonth(dates, calendar: calendar) {
                return .semimonthly
            }
            guard occurrenceCount >= 3 else { return nil }
            return consistency(of: gaps, within: 11...17) >= 0.7
                ? .biweekly : nil
        case 20...45:
            guard occurrenceCount >= 3 else { return nil }
            return consistency(of: gaps, within: 24...38) >= 0.7
                ? .monthly : nil
        case 75...105:
            guard occurrenceCount >= 3 else { return nil }
            return consistency(of: gaps, within: 75...105) >= 0.7
                ? .quarterly : nil
        case 300...430:
            return gaps.allSatisfy { (300...430).contains($0) }
                ? .annual : nil
        default:
            return nil
        }
    }

    private func consistency(
        of gaps: [Int],
        within range: ClosedRange<Int>
    ) -> Double {
        guard !gaps.isEmpty else { return 0 }
        let matching = gaps.filter { range.contains($0) }.count
        return Double(matching) / Double(gaps.count)
    }

    /// Semimonthly bills land on two fixed days of the month (with days ≥ 28
    /// treated as one end-of-month slot).
    private func hasStableDaysOfMonth(
        _ dates: [Date],
        calendar: Calendar
    ) -> Bool {
        let days = dates.map { date -> Int in
            let day = calendar.component(.day, from: date)
            return day >= 28 ? 31 : day
        }
        var counts: [Int: Int] = [:]
        for day in days { counts[day, default: 0] += 1 }
        let topTwo = counts.values.sorted(by: >).prefix(2).reduce(0, +)
        return counts.count <= 3
            && Double(topTwo) >= Double(days.count) * 0.8
    }

    private func medianInt(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

extension FixedCommitmentCandidate {
    /// Approximate monthly reserve, used only to rank candidates by impact.
    var monthlyImpact: Money {
        switch cadence {
        case .weekly: suggestedAmount.scaled(by: Decimal(52) / Decimal(12))
        case .biweekly: suggestedAmount.scaled(by: Decimal(26) / Decimal(12))
        case .semimonthly: Money(milliunits: suggestedAmount.milliunits * 2)
        case .monthly: suggestedAmount
        case .quarterly: suggestedAmount.scaled(by: Decimal(1) / Decimal(3))
        case .annual: suggestedAmount.scaled(by: Decimal(1) / Decimal(12))
        }
    }
}
