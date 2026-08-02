import Foundation
import Testing
@testable import Models
@testable import Money
@testable import Projections

@Suite("Spending awareness report")
struct SpendingReportTests {
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
        category: String? = nil,
        treatment: ForecastTreatment? = nil,
        transferAccountId: String? = nil
    ) -> TransactionSummary {
        TransactionSummary(
            id: UUID().uuidString, accountId: "acct", date: date,
            amount: amount, cleared: true, approved: true, payeeName: payee,
            categoryId: nil, categoryName: category,
            forecastTreatment: treatment,
            transferAccountId: transferAccountId,
            memo: nil, deleted: false
        )
    }

    private var assignments: BudgetBucketAssignments {
        var result = BudgetBucketAssignments()
        result.assign(.income, categoryName: "Salary")
        result.assign(.excluded, categoryName: "Amex - Platinum (4)")
        return result
    }

    private let aggregator = BudgetTransactionAggregator()

    @Test("Everything not income and not excluded counts, unassigned included")
    func defaultInclusive() {
        let transactions = [
            txn(date: date(2026, 4, 5), amount: .dollars(-120),
                payee: "Market", category: "Groceries"),
            // Unassigned category still counts — no setup ceremony required.
            txn(date: date(2026, 4, 8), amount: .dollars(-45),
                payee: "Mystery", category: "Random Hobby"),
            // Income never shows as negative spending.
            txn(date: date(2026, 4, 3), amount: .dollars(6_400),
                payee: "Gusto", category: "Salary"),
            // Excluded category stays out.
            txn(date: date(2026, 4, 9), amount: .dollars(-900),
                payee: "Card", category: "Amex - Platinum (4)"),
            // Transfers never count.
            txn(date: date(2026, 4, 10), amount: .dollars(-5_000),
                payee: "Transfer : BofA", category: nil,
                transferAccountId: "bofa"),
            // Reimbursement-named categories are excluded by default.
            txn(date: date(2026, 4, 12), amount: .dollars(500),
                payee: "Work", category: "Reimbursements")
        ]
        let summaries = aggregator.spendingSummaries(
            transactions: transactions,
            assignments: assignments,
            calendar: utc
        )
        let april = summaries[BudgetMonth(year: 2026, month: 4)]
        #expect(april?.total == .dollars(165))
        #expect(april?.categories.map(\.name) == ["Groceries", "Random Hobby"])
    }

    @Test("Refunds net against the category and can go negative")
    func refundsNet() {
        let transactions = [
            txn(date: date(2026, 4, 5), amount: .dollars(-200),
                payee: "Store", category: "Clothing"),
            txn(date: date(2026, 4, 20), amount: .dollars(250),
                payee: "Store", category: "Clothing", treatment: .refund)
        ]
        let summaries = aggregator.spendingSummaries(
            transactions: transactions,
            assignments: assignments,
            calendar: utc
        )
        let april = summaries[BudgetMonth(year: 2026, month: 4)]
        #expect(april?.total == .dollars(-50))
    }

    @Test("Category items list the month's transactions largest first")
    func categoryItemsDetail() {
        let transactions = [
            txn(date: date(2026, 4, 5), amount: .dollars(-120),
                payee: "Market", category: "Groceries"),
            txn(date: date(2026, 4, 12), amount: .dollars(-80),
                payee: "Corner Shop", category: "Groceries"),
            txn(date: date(2026, 3, 5), amount: .dollars(-999),
                payee: "Old", category: "Groceries")
        ]
        let items = aggregator.categoryItems(
            categoryKey: "groceries",
            in: BudgetMonth(year: 2026, month: 4),
            transactions: transactions,
            assignments: assignments,
            calendar: utc
        )
        #expect(items.map(\.payeeName) == ["Market", "Corner Shop"])
    }

    @Test("Linked-category spending drains funds only after their start date")
    func fundDrains() {
        let travel = SinkingFund(
            id: "travel", name: "Travel", target: .dollars(3_000),
            linkedCategoryKeys: ["travel"],
            startDate: date(2026, 3, 1)
        )
        let transactions = [
            // Before the fund existed: not a drain.
            txn(date: date(2026, 2, 10), amount: .dollars(-400),
                payee: "Airline", category: "Travel"),
            txn(date: date(2026, 4, 10), amount: .dollars(-1_200),
                payee: "Hotel", category: "Travel"),
            // A refund flows back into the fund.
            txn(date: date(2026, 4, 20), amount: .dollars(200),
                payee: "Hotel", category: "Travel", treatment: .refund),
            txn(date: date(2026, 4, 11), amount: .dollars(-60),
                payee: "Market", category: "Groceries")
        ]
        let drained = aggregator.linkedSpending(
            for: [travel],
            transactions: transactions,
            assignments: assignments,
            calendar: utc
        )
        #expect(drained["travel"] == .dollars(1_000))

        let snapshot = FundMath.snapshot(
            fund: travel,
            manualEntries: [FundLedgerEntry(
                id: "e1", fundId: "travel", date: date(2026, 3, 1),
                amount: .dollars(3_000)
            )],
            linkedSpending: drained["travel"] ?? .zero,
            asOf: date(2026, 8, 2),
            calendar: utc
        )
        #expect(snapshot.balance == .dollars(2_000))
    }
}
