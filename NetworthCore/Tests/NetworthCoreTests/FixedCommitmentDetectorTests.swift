import Foundation
import Testing
@testable import Models
@testable import Money
@testable import Projections

@Suite("Fixed commitment detector")
struct FixedCommitmentDetectorTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func txn(
        date: Date,
        amount: Money,
        payee: String,
        category: String? = nil
    ) -> TransactionSummary {
        TransactionSummary(
            id: UUID().uuidString, accountId: "acct", date: date,
            amount: amount, cleared: true, approved: true, payeeName: payee,
            categoryId: nil, categoryName: category,
            memo: nil, deleted: false
        )
    }

    private let detector = FixedCommitmentDetector()
    private let assignments = BudgetBucketAssignments()

    private func detect(
        _ transactions: [TransactionSummary],
        asOf: Date
    ) -> [FixedCommitmentCandidate] {
        detector.candidates(
            transactions: transactions,
            assignments: assignments,
            asOf: asOf,
            calendar: utc
        )
    }

    @Test("A stable monthly subscription suggests the latest amount")
    func stableMonthlySubscription() {
        let transactions = (1...6).map { month in
            txn(date: date(2026, month, 12), amount: .dollars(-15.99),
                payee: "Streamly", category: "Subscriptions")
        }
        let candidates = detect(transactions, asOf: date(2026, 7, 1))
        #expect(candidates.count == 1)
        let candidate = try! #require(candidates.first)
        #expect(candidate.cadence == .monthly)
        #expect(candidate.amountBasis == .latestAmount)
        #expect(candidate.suggestedAmount == .dollars(15.99))
        #expect(candidate.occurrenceCount == 6)
    }

    @Test("A variable monthly bill suggests the recent mean")
    func variableMonthlyBill() {
        let amounts: [Decimal] = [80, 95, 110, 90, 85, 100]
        let transactions = amounts.enumerated().map { index, amount in
            txn(date: date(2026, index + 1, 15), amount: .dollars(-amount),
                payee: "Power Co", category: "Utilities")
        }
        let candidates = detect(transactions, asOf: date(2026, 7, 1))
        let candidate = try! #require(candidates.first)
        #expect(candidate.cadence == .monthly)
        #expect(candidate.amountBasis == .recentMean)
        #expect(candidate.suggestedAmount == Money(milliunits: 93_333))
    }

    @Test("An amount change converges onto the new stable amount")
    func amountChangeConverges() {
        let amounts: [Decimal] = [2_000, 2_000, 2_000, 2_100, 2_100, 2_100]
        let transactions = amounts.enumerated().map { index, amount in
            txn(date: date(2026, index + 1, 1), amount: .dollars(-amount),
                payee: "Landlord", category: "Rent")
        }
        let candidates = detect(transactions, asOf: date(2026, 6, 20))
        let candidate = try! #require(candidates.first)
        #expect(candidate.amountBasis == .latestAmount)
        #expect(candidate.suggestedAmount == .dollars(2_100))
    }

    @Test("Biweekly cadence is detected from 14-day gaps")
    func biweeklyCadence() {
        let start = date(2026, 1, 2)
        let transactions = (0..<6).map { step in
            txn(date: utc.date(byAdding: .day, value: step * 14, to: start)!,
                amount: .dollars(-150), payee: "Therapy Office",
                category: "Therapy")
        }
        let candidates = detect(transactions, asOf: date(2026, 4, 1))
        let candidate = try! #require(candidates.first)
        #expect(candidate.cadence == .biweekly)
    }

    @Test("Quarterly and annual cadences are detected")
    func quarterlyAndAnnual() {
        let quarterly = [date(2026, 1, 15), date(2026, 4, 15),
                         date(2026, 7, 15)].map {
            txn(date: $0, amount: .dollars(-300), payee: "Insurer",
                category: "Insurance")
        }
        let annual = [date(2025, 3, 10), date(2026, 3, 10)].map {
            txn(date: $0, amount: .dollars(-1_200), payee: "Club",
                category: "Memberships")
        }
        let candidates = detect(quarterly + annual, asOf: date(2026, 8, 1))
        #expect(candidates.count == 2)
        #expect(
            candidates.first { $0.displayName == "Insurer" }?.cadence
                == .quarterly
        )
        #expect(
            candidates.first { $0.displayName == "Club" }?.cadence == .annual
        )
    }

    @Test("Irregular spending produces no candidate")
    func irregularSpendingIgnored() {
        let dates = [date(2026, 1, 3), date(2026, 1, 9), date(2026, 2, 27),
                     date(2026, 3, 2), date(2026, 5, 30)]
        let transactions = dates.map {
            txn(date: $0, amount: .dollars(-42), payee: "Random Shop",
                category: "Shopping")
        }
        #expect(detect(transactions, asOf: date(2026, 6, 15)).isEmpty)
    }

    @Test("A dead recurrence with stale activity is not suggested")
    func deadRecurrenceSkipped() {
        let transactions = (1...6).map { month in
            txn(date: date(2025, month, 5), amount: .dollars(-9.99),
                payee: "Old App", category: "Subscriptions")
        }
        #expect(detect(transactions, asOf: date(2026, 7, 1)).isEmpty)
    }

    @Test("Same-day charges collapse into one occurrence")
    func sameDayCollapse() {
        var transactions: [TransactionSummary] = []
        for month in 1...4 {
            transactions.append(
                txn(date: date(2026, month, 20), amount: .dollars(-60),
                    payee: "Water District", category: "Utilities")
            )
            transactions.append(
                txn(date: date(2026, month, 20), amount: .dollars(-15),
                    payee: "Water District", category: "Utilities")
            )
        }
        let candidates = detect(transactions, asOf: date(2026, 5, 5))
        let candidate = try! #require(candidates.first)
        #expect(candidate.occurrenceCount == 4)
        #expect(candidate.cadence == .monthly)
        #expect(candidate.suggestedAmount == .dollars(75))
    }

    @Test("Candidates never arrive pre-confirmed as commitments")
    func candidatesRequireExplicitConfirmation() {
        let transactions = (1...6).map { month in
            txn(date: date(2026, month, 12), amount: .dollars(-15.99),
                payee: "Streamly", category: "Subscriptions")
        }
        let candidate = try! #require(
            detect(transactions, asOf: date(2026, 7, 1)).first
        )
        // Confirmation is an explicit user act producing a commitment.
        let commitment = candidate.toCommitment(id: "confirmed-1")
        #expect(commitment.active)
        #expect(commitment.anchorDate == candidate.lastDate)
    }
}
