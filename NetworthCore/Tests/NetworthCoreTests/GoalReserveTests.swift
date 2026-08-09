import Testing
import Foundation
@testable import Money
@testable import Models

@Suite("Goal reserve pool and ledger math")
struct GoalReserveTests {
    private var utc: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "UTC")!
        return value
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func entry(
        _ id: String,
        goal: String = "g1",
        amount: Int,
        kind: GoalLedgerKind,
        date: Date? = nil
    ) -> GoalLedgerEntry {
        GoalLedgerEntry(
            id: id,
            goalId: goal,
            date: date ?? self.date(2026, 8, 5),
            amount: .dollars(integer: amount),
            kind: kind,
            createdAt: date ?? self.date(2026, 8, 5)
        )
    }

    // MARK: Reserve pool

    @Test func summarySplitsPoolIntoAllocatedAndUnallocated() {
        let summary = ReservePoolMath.summary(
            reserveBalance: .dollars(integer: 10_000),
            activeGoalBalances: [
                .dollars(integer: 4_000), .dollars(integer: 2_500)
            ]
        )
        #expect(summary.pool == .dollars(integer: 10_000))
        #expect(summary.allocated == .dollars(integer: 6_500))
        #expect(summary.unallocated == .dollars(integer: 3_500))
        #expect(summary.shortfall == .zero)
    }

    @Test func balanceDropBelowAllocationsSurfacesShortfall() {
        let summary = ReservePoolMath.summary(
            reserveBalance: .dollars(integer: 5_000),
            activeGoalBalances: [.dollars(integer: 6_000)]
        )
        #expect(summary.shortfall == .dollars(integer: 1_000))
        #expect(summary.unallocated == .zero)
    }

    @Test func negativeGoalBalanceNeverManufacturesUnallocatedMoney() {
        let summary = ReservePoolMath.summary(
            reserveBalance: .dollars(integer: 1_000),
            activeGoalBalances: [
                .dollars(integer: 1_000), .dollars(integer: -200)
            ]
        )
        // Allocated counts only positive balances: the pool is fully claimed.
        #expect(summary.allocated == .dollars(integer: 1_000))
        #expect(summary.unallocated == .zero)
    }

    @Test func negativeReserveBalanceClampsToZero() {
        let summary = ReservePoolMath.summary(
            reserveBalance: .dollars(integer: -50),
            activeGoalBalances: []
        )
        #expect(summary.pool == .zero)
        #expect(summary.shortfall == .zero)
    }

    @Test func allocationBlockedDuringShortfallAndBeyondUnallocated() {
        let short = ReservePoolMath.summary(
            reserveBalance: .dollars(integer: 5_000),
            activeGoalBalances: [.dollars(integer: 6_000)]
        )
        #expect(!ReservePoolMath.canAllocate(.dollars(integer: 1), in: short))

        let healthy = ReservePoolMath.summary(
            reserveBalance: .dollars(integer: 5_000),
            activeGoalBalances: [.dollars(integer: 3_000)]
        )
        #expect(ReservePoolMath.canAllocate(
            .dollars(integer: 2_000), in: healthy
        ))
        #expect(!ReservePoolMath.canAllocate(
            .dollars(integer: 2_001), in: healthy
        ))
        #expect(!ReservePoolMath.canAllocate(.zero, in: healthy))
    }

    // MARK: Ledger balance

    @Test func balanceSumsSignedEntriesAcrossKinds() {
        let balance = GoalMath.balance(entries: [
            entry("1", amount: 500, kind: .contribution),
            entry("2", amount: 100, kind: .manual),
            entry("3", amount: -200, kind: .purchase),
            entry("4", amount: 50, kind: .purchaseRefund),
            entry("5", amount: -100, kind: .withdrawal)
        ])
        #expect(balance == .dollars(integer: 350))
    }

    @Test func reallocationPairIsNetZeroAcrossGoals() {
        let out = entry("1", goal: "a", amount: -300, kind: .reallocationOut)
        let inn = entry("2", goal: "b", amount: 300, kind: .reallocationIn)
        #expect(GoalMath.balance(entries: [out]).milliunits == -300_000)
        #expect(GoalMath.balance(entries: [inn]).milliunits == 300_000)
        #expect((out.amount + inn.amount).isZero)
    }

    // MARK: Month-to-date contributions

    @Test func mtdCountsOnlyPositiveManualAndContributionThisMonth() {
        let asOf = date(2026, 8, 7)
        let mtd = GoalMath.monthToDateContributions(
            entries: [
                entry("1", amount: 500, kind: .contribution),
                entry("2", amount: 100, kind: .manual),
                entry("3", amount: -50, kind: .manual),
                entry("4", amount: 75, kind: .purchaseRefund),
                entry("5", amount: 200, kind: .reallocationIn),
                entry(
                    "6", amount: 400, kind: .contribution,
                    date: date(2026, 7, 30)
                )
            ],
            asOf: asOf,
            calendar: utc
        )
        // Refund credits, reallocations, negative manuals, and last month's
        // contribution are all excluded.
        #expect(mtd == .dollars(integer: 600))
    }

    // MARK: Plan-sufficiency status bridge

    @Test func statusBridgesToFundMathPlanSufficiency() {
        let asOf = date(2026, 8, 1)
        let goal = Goal(
            id: "g1", name: "House", kind: .oneTime,
            target: .dollars(integer: 60_000),
            targetDate: date(2027, 8, 1),
            plannedMonthly: .dollars(integer: 5_000)
        )
        let status = GoalMath.status(
            goal: goal,
            balance: .dollars(integer: 12_000),
            asOf: asOf,
            calendar: utc
        )
        // $48k shortfall over 12 months = $4k/mo required; $5k plan suffices.
        #expect(status == .onTrack(
            requiredMonthly: .dollars(integer: 4_000)
        ))
    }

    @Test func inactiveGoalsAreExcludedFromAllocationByCaller() {
        let archived = Goal(
            id: "g2", name: "Old", kind: .refillable,
            target: .dollars(integer: 1_000), archived: true
        )
        let completed = Goal(
            id: "g3", name: "Done", kind: .oneTime,
            target: .dollars(integer: 1_000),
            completedAt: date(2026, 6, 1)
        )
        #expect(!archived.isActive)
        #expect(!completed.isActive)
    }
}
