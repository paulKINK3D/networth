import Foundation
import Testing
@testable import Models
@testable import Money

@Suite("Spending group budgets")
struct SpendingBudgetsTests {
    private let resolver = SpendingGroupBudgetResolver()
    private let paceEvaluator = SpendingBudgetPaceEvaluator()

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        utc.date(
            from: DateComponents(year: year, month: month, day: day)
        )!
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        hour: Int
    ) -> Date {
        utc.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour
        ))!
    }

    private func rule(
        id: String,
        group: String,
        year: Int,
        month: Int,
        target: Int,
        enabled: Bool = true,
        updatedDay: Int = 1
    ) -> SpendingGroupBudgetRule {
        SpendingGroupBudgetRule(
            id: id,
            groupIdentity: group,
            effectiveMonth: BudgetMonth(year: year, month: month),
            target: Money.dollars(integer: target),
            enabled: enabled,
            updatedAt: date(year, month, updatedDay)
        )
    }

    private func group(
        id: String,
        name: String,
        spent: Int64,
        role: CategoryReportingRole? = .spending
    ) -> SpendingHistoryGroupTotal {
        SpendingHistoryGroupTotal(
            id: id,
            name: name,
            spentMilliunits: spent,
            categories: [],
            reportingRole: role
        )
    }

    @Test("A target repeats until a later effective month replaces it")
    func targetRepeatsAndPreservesHistory() {
        let rules = [
            rule(id: "aug", group: "surplus", year: 2026, month: 8,
                 target: 1_500),
            rule(id: "oct", group: "surplus", year: 2026, month: 10,
                 target: 1_200),
        ]

        #expect(resolver.activeRule(
            for: "surplus", month: BudgetMonth(year: 2026, month: 9),
            rules: rules
        )?.target == Money.dollars(integer: 1_500))
        #expect(resolver.activeRule(
            for: "surplus", month: BudgetMonth(year: 2026, month: 10),
            rules: rules
        )?.target == Money.dollars(integer: 1_200))
    }

    @Test("A disabled month stops the repeating budget")
    func disablingStopsBudget() {
        let rules = [
            rule(id: "on", group: "surplus", year: 2026, month: 8,
                 target: 1_500),
            rule(id: "off", group: "surplus", year: 2026, month: 9,
                 target: 1_500, enabled: false),
        ]
        let summary = resolver.summary(
            for: BudgetMonth(year: 2026, month: 9),
            groups: [group(id: "surplus", name: "Surplus", spent: 500_000)],
            rules: rules
        )
        #expect(summary.groups.isEmpty)
    }

    @Test("Newest duplicate wins deterministically")
    func newestDuplicateWins() {
        let rules = [
            rule(id: "older", group: "surplus", year: 2026, month: 8,
                 target: 1_500, updatedDay: 2),
            rule(id: "newer", group: "surplus", year: 2026, month: 8,
                 target: 1_250, updatedDay: 3),
        ]
        #expect(resolver.activeRule(
            for: "surplus", month: BudgetMonth(year: 2026, month: 8),
            rules: rules
        )?.target == Money.dollars(integer: 1_250))
    }

    @Test("Only enabled groups contribute to the total")
    func summaryIncludesOnlyEnabledGroups() {
        let rules = [
            rule(id: "surplus", group: "surplus", year: 2026, month: 8,
                 target: 1_500),
            rule(id: "fixed", group: "fixed", year: 2026, month: 8,
                 target: 2_000),
        ]
        let summary = resolver.summary(
            for: BudgetMonth(year: 2026, month: 8),
            groups: [
                group(id: "surplus", name: "Surplus", spent: 900_000),
                group(id: "fixed", name: "Fixed", spent: 1_800_000),
                group(id: "other", name: "Other", spent: 500_000),
            ],
            rules: rules
        )
        #expect(summary.spent == Money.dollars(integer: 2_700))
        #expect(summary.target == Money.dollars(integer: 3_500))
        #expect(summary.remaining == Money.dollars(integer: 800))
    }

    @Test("Net refunds restore but never expand a group budget")
    func refundsFloorAtZero() {
        let rules = [
            rule(id: "surplus", group: "surplus", year: 2026, month: 8,
                 target: 1_500),
        ]
        let summary = resolver.summary(
            for: BudgetMonth(year: 2026, month: 8),
            groups: [
                group(id: "surplus", name: "Surplus", spent: -100_000),
            ],
            rules: rules
        )
        #expect(summary.spent == .zero)
        #expect(summary.remaining == Money.dollars(integer: 1_500))
    }

    @Test("A Savings transfer group can be budgeted without changing its role")
    func transferGroupCanBeBudgeted() {
        let rules = [
            rule(id: "savings", group: "savings", year: 2026, month: 8,
                 target: 500),
        ]
        let summary = resolver.summary(
            for: BudgetMonth(year: 2026, month: 8),
            groups: [
                group(
                    id: "savings", name: "Savings", spent: 400_000,
                    role: .transfer
                ),
            ],
            rules: rules
        )
        #expect(summary.groups.first?.spent == Money.dollars(integer: 400))
        #expect(summary.remaining == Money.dollars(integer: 100))
    }

    @Test("Budget pace compares usage with elapsed calendar time")
    func currentMonthPaceBands() {
        let month = BudgetMonth(year: 2026, month: 8)
        let now = date(2026, 8, 21, hour: 12)

        #expect(paceEvaluator.status(
            progress: 0.66,
            month: month,
            now: now,
            calendar: utc
        ) == .onTrack)
        #expect(paceEvaluator.status(
            progress: 0.70,
            month: month,
            now: now,
            calendar: utc
        ) == .watch)
        #expect(paceEvaluator.status(
            progress: 0.80,
            month: month,
            now: now,
            calendar: utc
        ) == .atRisk)
    }

    @Test("Over budget is always at risk")
    func overBudgetIsAtRisk() {
        #expect(paceEvaluator.status(
            progress: 1.01,
            month: BudgetMonth(year: 2026, month: 7),
            now: date(2026, 8, 21),
            calendar: utc
        ) == .atRisk)
    }

    @Test("Completed months are factual under or over budget")
    func completedMonthStatus() {
        let month = BudgetMonth(year: 2026, month: 7)
        let now = date(2026, 8, 21)

        #expect(paceEvaluator.status(
            progress: 0.99,
            month: month,
            now: now,
            calendar: utc
        ) == .onTrack)
        #expect(paceEvaluator.status(
            progress: 1.01,
            month: month,
            now: now,
            calendar: utc
        ) == .atRisk)
    }
}
