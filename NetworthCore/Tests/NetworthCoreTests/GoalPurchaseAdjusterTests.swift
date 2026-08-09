import Testing
import Foundation
@testable import Money
@testable import Models

@Suite("Goal purchase adjustment")
struct GoalPurchaseAdjusterTests {
    private var utc: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "UTC")!
        return value
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func spend(
        _ transactionId: String,
        amount: Int64,
        treatment: ForecastTreatment? = .ordinarySpending,
        role: CategoryReportingRole? = .spending,
        group: String = "travel",
        category: String = "cat:travel",
        day: Int = 5
    ) -> SpendingHistoryEntry {
        SpendingHistoryEntry(
            transactionId: transactionId,
            date: date(2026, 8, day),
            amountMilliunits: amount,
            treatment: treatment,
            reportingRole: role,
            groupIdentity: group,
            groupName: group.capitalized,
            categoryKey: category,
            categoryName: category
        )
    }

    // MARK: Adjustable ceiling

    @Test func adjustableAmountExcludesNonOrdinaryLegs() {
        let entries = [
            spend("t1", amount: -60_000),
            spend("t1", amount: -25_000, treatment: .internalTransfer,
                  role: .transfer, group: "savings"),
            spend("t1", amount: -15_000, treatment: nil, role: nil),
            spend("t2", amount: -99_000)
        ]
        // t1's ceiling: $60 ordinary + $15 nil-treatment = $75, NOT the
        // $100 parent total — the transfer leg never counts.
        #expect(GoalPurchaseAdjuster.adjustableAmount(
            entries: entries, transactionId: "t1"
        ) == Money(milliunits: 75_000))
    }

    // MARK: Full and partial assignment

    @Test func fullAssignmentDropsEntryAndEmitsSynthetic() {
        let entries = [spend("t1", amount: -4_000_000)]
        let adjusted = GoalPurchaseAdjuster.apply(
            entries: entries,
            assignments: GoalPurchaseAssignments(
                purchasesByTransactionId: ["t1": 4_000_000]
            )
        )
        #expect(adjusted.count == 1)
        let synthetic = adjusted[0]
        #expect(synthetic.groupIdentity == GoalPurchaseAdjuster.groupIdentity)
        #expect(synthetic.amountMilliunits == -4_000_000)
        #expect(synthetic.treatment == .ordinarySpending)
    }

    @Test func partialAssignmentLeavesRemainderInOriginalCategory() {
        let entries = [spend("t1", amount: -5_000_000)]
        let adjusted = GoalPurchaseAdjuster.apply(
            entries: entries,
            assignments: GoalPurchaseAssignments(
                purchasesByTransactionId: ["t1": 4_000_000]
            )
        )
        #expect(adjusted.count == 2)
        let remainder = adjusted.first { $0.groupIdentity == "travel" }
        let funded = adjusted.first {
            $0.groupIdentity == GoalPurchaseAdjuster.groupIdentity
        }
        #expect(remainder?.amountMilliunits == -1_000_000)
        #expect(funded?.amountMilliunits == -4_000_000)
    }

    @Test func overAssignmentConsumesOnlyTheAdjustableAmount() {
        let entries = [
            spend("t1", amount: -60_000),
            spend("t1", amount: -40_000, treatment: .internalTransfer,
                  role: .transfer, group: "savings")
        ]
        let adjusted = GoalPurchaseAdjuster.apply(
            entries: entries,
            assignments: GoalPurchaseAssignments(
                purchasesByTransactionId: ["t1": 100_000]
            )
        )
        let funded = adjusted.first {
            $0.groupIdentity == GoalPurchaseAdjuster.groupIdentity
        }
        let transfer = adjusted.first { $0.groupIdentity == "savings" }
        // Only the $60 ordinary leg is consumable; the transfer leg is
        // untouched and the synthetic entry never exceeds what existed.
        #expect(funded?.amountMilliunits == -60_000)
        #expect(transfer?.amountMilliunits == -40_000)
    }

    // MARK: Split consumption order

    @Test func splitsConsumeLargestLegFirstWithStableTieBreak() {
        let entries = [
            spend("t1", amount: -30_000, category: "cat:a"),
            spend("t1", amount: -70_000, category: "cat:b"),
            spend("t1", amount: -30_000, category: "cat:c")
        ]
        let adjusted = GoalPurchaseAdjuster.apply(
            entries: entries,
            assignments: GoalPurchaseAssignments(
                purchasesByTransactionId: ["t1": 80_000]
            )
        )
        // Largest ($70 cat:b) fully consumed, then the tie between the two
        // $30 legs breaks by original index: cat:a loses $10, cat:c intact.
        #expect(!adjusted.contains { $0.categoryKey == "cat:b" })
        #expect(adjusted.first {
            $0.categoryKey == "cat:a"
        }?.amountMilliunits == -20_000)
        #expect(adjusted.first {
            $0.categoryKey == "cat:c"
        }?.amountMilliunits == -30_000)
    }

    // MARK: Refunds

    @Test func refundAssignmentMovesOffsetOutOfOrdinaryCategory() {
        let entries = [
            spend("t1", amount: -5_000_000),
            spend("t2", amount: 1_000_000, treatment: .refund)
        ]
        let adjusted = GoalPurchaseAdjuster.apply(
            entries: entries,
            assignments: GoalPurchaseAssignments(
                purchasesByTransactionId: ["t1": 5_000_000],
                refundsByTransactionId: ["t2": 1_000_000]
            )
        )
        let syntheticEntries = adjusted.filter {
            $0.groupIdentity == GoalPurchaseAdjuster.groupIdentity
        }
        #expect(syntheticEntries.count == 2)
        #expect(syntheticEntries.contains {
            $0.amountMilliunits == -5_000_000
                && $0.treatment == .ordinarySpending
        })
        #expect(syntheticEntries.contains {
            $0.amountMilliunits == 1_000_000 && $0.treatment == .refund
        })
        // The ordinary category retains neither the spend nor the offset.
        #expect(!adjusted.contains { $0.groupIdentity == "travel" })
    }

    // MARK: Builder integration

    @Test func headlineExcludesGoalPurchasesButColumnRemains() {
        let now = date(2026, 8, 15)
        let entries = GoalPurchaseAdjuster.apply(
            entries: [
                spend("t1", amount: -5_000_000),
                spend("t2", amount: -1_500_000, group: "groceries",
                      category: "cat:groceries"),
                spend("t3", amount: 2_000_000,
                      treatment: .internalTransfer, role: .transfer,
                      group: "savings", category: "cat:savings")
            ],
            assignments: GoalPurchaseAssignments(
                purchasesByTransactionId: ["t1": 4_000_000]
            )
        )
        let months = SpendingHistoryBuilder.build(
            entries: entries, monthsBack: 1, now: now, calendar: utc
        )
        let month = try! #require(months.last)

        // Headline: $1 travel remainder + $1.5 groceries + $2 savings
        // transfer — the $4 goal-funded portion is out.
        #expect(month.totalMilliunits == 4_500_000)
        // Ordinary total additionally excludes the savings transfer.
        #expect(month.ordinaryTotalMilliunits == 2_500_000)
        // But the column exists and is visible.
        let goalGroup = month.groups.first {
            $0.id == GoalPurchaseAdjuster.groupIdentity
        }
        #expect(goalGroup?.spentMilliunits == 4_000_000)
        #expect(goalGroup?.countsTowardHeadline == false)
    }

    @Test func lineAmountsCarryAdjustedFiguresForDrillDown() {
        let now = date(2026, 8, 15)
        let entries = GoalPurchaseAdjuster.apply(
            entries: [spend("t1", amount: -5_000_000)],
            assignments: GoalPurchaseAssignments(
                purchasesByTransactionId: ["t1": 4_000_000]
            )
        )
        let months = SpendingHistoryBuilder.build(
            entries: entries, monthsBack: 1, now: now, calendar: utc
        )
        let month = try! #require(months.last)
        let travel = month.groups
            .first { $0.id == "travel" }?
            .categories.first
        let funded = month.groups
            .first { $0.id == GoalPurchaseAdjuster.groupIdentity }?
            .categories.first
        #expect(travel?.lineAmountsByTransactionId["t1"] == -1_000_000)
        #expect(funded?.lineAmountsByTransactionId["t1"] == -4_000_000)
    }

    @Test func noAssignmentsIsIdentity() {
        let entries = [spend("t1", amount: -5_000_000)]
        #expect(GoalPurchaseAdjuster.apply(
            entries: entries, assignments: GoalPurchaseAssignments()
        ) == entries)
    }
}
