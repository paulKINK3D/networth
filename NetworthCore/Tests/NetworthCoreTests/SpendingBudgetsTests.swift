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

    @Test("A savings choice reallocates one month without changing total budget")
    func savingsChoiceReallocatesSelectedMonth() {
        let rules = [
            rule(id: "surplus", group: "surplus", year: 2026, month: 8,
                 target: 3_000),
            rule(id: "savings", group: "savings", year: 2026, month: 8,
                 target: 1_000),
        ]
        let choice = SavingsBudgetChoice(
            id: "takeout",
            month: BudgetMonth(year: 2026, month: 8),
            sourceGroupIdentity: "surplus",
            savingsGroupIdentity: "savings",
            amount: Money.dollars(integer: 200),
            note: "Skipped takeout",
            occurredAt: date(2026, 8, 20),
            updatedAt: date(2026, 8, 20)
        )
        let august = resolver.summary(
            for: BudgetMonth(year: 2026, month: 8),
            groups: [
                group(id: "surplus", name: "Surplus", spent: 2_000_000),
                group(
                    id: "savings", name: "Savings", spent: 750_000,
                    role: .transfer
                ),
            ],
            rules: rules,
            savingsChoices: [choice]
        )

        #expect(august.target == Money.dollars(integer: 4_000))
        #expect(
            august.groups.first { $0.groupIdentity == "surplus" }?.target
                == Money.dollars(integer: 2_800)
        )
        let savings = august.groups.first { $0.groupIdentity == "savings" }
        #expect(savings?.baseTarget == Money.dollars(integer: 1_000))
        #expect(savings?.additionalTarget == Money.dollars(integer: 200))
        #expect(savings?.target == Money.dollars(integer: 1_200))
        #expect(savings?.spent == Money.dollars(integer: 750))

        let september = resolver.summary(
            for: BudgetMonth(year: 2026, month: 9),
            groups: [
                group(id: "surplus", name: "Surplus", spent: 0),
                group(id: "savings", name: "Savings", spent: 0),
            ],
            rules: rules,
            savingsChoices: [choice]
        )
        #expect(
            september.groups.first { $0.groupIdentity == "surplus" }?.target
                == Money.dollars(integer: 3_000)
        )
        #expect(
            september.groups.first { $0.groupIdentity == "savings" }?.target
                == Money.dollars(integer: 1_000)
        )
    }

    @Test("Savings choices use the source budget's unspent balance")
    func savingsChoiceAvailabilityUsesRemainingBudget() {
        let month = BudgetMonth(year: 2026, month: 8)
        let source = SpendingGroupBudgetSnapshot(
            groupIdentity: "surplus",
            groupName: "Surplus",
            spent: Money.dollars(integer: 2_665),
            target: Money.dollars(integer: 2_940),
            baseTarget: Money.dollars(integer: 3_000),
            reallocatedToSavings: Money.dollars(integer: 60)
        )
        let choice = SavingsBudgetChoice(
            id: "coffee",
            month: month,
            sourceGroupIdentity: "surplus",
            savingsGroupIdentity: "savings",
            amount: Money.dollars(integer: 60),
            note: "Made coffee",
            occurredAt: date(2026, 8, 20),
            updatedAt: date(2026, 8, 20)
        )

        #expect(resolver.availableForSavingsChoice(
            from: source,
            month: month,
            choices: [choice]
        ) == Money.dollars(integer: 275))
        #expect(resolver.availableForSavingsChoice(
            from: source,
            month: month,
            choices: [choice],
            excludingChoiceID: choice.id
        ) == Money.dollars(integer: 335))
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

    @Test("Due-date reserves calculate an inclusive monthly plan")
    func sinkingFundDueDatePlan() {
        let plan = SpendingSinkingFundMath
            .calculatedMonthlyPlan(
                target: Money.dollars(integer: 1_200),
                balance: Money.dollars(integer: 200),
                targetDate: date(2027, 5, 20),
                asOf: date(2026, 8, 2),
                calendar: utc
            )

        #expect(
            SpendingSinkingFundMath.contributionMonths(
                from: date(2026, 8, 2),
                through: date(2027, 5, 20),
                calendar: utc
            ) == 10
        )
        #expect(plan == Money.dollars(integer: 100))
    }

    @Test("Target funds stop contributing when fully reserved")
    func sinkingFundTargetCapsContribution() {
        let fund = SpendingSinkingFund(
            id: "insurance",
            name: "Insurance",
            mode: .buildToAmount,
            target: Money.dollars(integer: 1_000),
            plannedMonthly: Money.dollars(integer: 200),
            startMonth: BudgetMonth(year: 2026, month: 8)
        )

        #expect(SpendingSinkingFundMath.monthlyPlan(
            for: fund,
            balance: Money.dollars(integer: 900),
            asOf: date(2026, 8, 2),
            calendar: utc
        ) == Money.dollars(integer: 100))
        #expect(SpendingSinkingFundMath.monthlyPlan(
            for: fund,
            balance: Money.dollars(integer: 1_000),
            asOf: date(2026, 8, 2),
            calendar: utc
        ) == .zero)
    }

    @Test("Sinking fund balances carry contributions and confirmed expenses")
    func sinkingFundSnapshotCarriesBalance() {
        let fund = SpendingSinkingFund(
            id: "home",
            name: "Home repair",
            mode: .ongoingReserve,
            plannedMonthly: Money.dollars(integer: 100),
            openingBalance: Money.dollars(integer: 300),
            startMonth: BudgetMonth(year: 2026, month: 7)
        )
        let contributions = [
            SpendingSinkingFundContribution(
                id: "july",
                fundID: fund.id,
                month: BudgetMonth(year: 2026, month: 7),
                amount: Money.dollars(integer: 100),
                updatedAt: date(2026, 7, 1)
            ),
            SpendingSinkingFundContribution(
                id: "august",
                fundID: fund.id,
                month: BudgetMonth(year: 2026, month: 8),
                amount: Money.dollars(integer: 100),
                updatedAt: date(2026, 8, 1)
            ),
        ]
        let expenses = [
            SpendingSinkingFundExpense(
                id: "repair",
                fundID: fund.id,
                transactionID: "trx",
                date: date(2026, 8, 15),
                amount: Money.dollars(integer: 175),
                updatedAt: date(2026, 8, 15)
            )
        ]

        let snapshot = SpendingSinkingFundMath.snapshot(
            fund: fund,
            contributions: contributions,
            expenses: expenses,
            through: BudgetMonth(year: 2026, month: 8),
            calendar: utc
        )

        #expect(snapshot.contributed == Money.dollars(integer: 200))
        #expect(snapshot.spent == Money.dollars(integer: 175))
        #expect(snapshot.balance == Money.dollars(integer: 325))
    }

    @Test("Projection protects active reserves and excludes their purchases")
    func reserveProjectionAdjustment() {
        let month = BudgetMonth(year: 2026, month: 8)
        let activeFund = SpendingSinkingFund(
            id: "home",
            name: "Home",
            mode: .ongoingReserve,
            openingBalance: Money.dollars(integer: 300),
            startMonth: month
        )
        let archivedFund = SpendingSinkingFund(
            id: "old",
            name: "Old reserve",
            mode: .ongoingReserve,
            openingBalance: Money.dollars(integer: 500),
            startMonth: month,
            archived: true
        )
        let contributions = [
            SpendingSinkingFundContribution(
                id: "assignment",
                fundID: activeFund.id,
                month: month,
                amount: Money.dollars(integer: 200),
                updatedAt: date(2026, 8, 1)
            )
        ]
        let expenses = [
            SpendingSinkingFundExpense(
                id: "whole",
                fundID: activeFund.id,
                transactionID: "whole-transaction",
                date: date(2026, 8, 10),
                amount: Money.dollars(integer: 100),
                updatedAt: date(2026, 8, 10)
            ),
            SpendingSinkingFundExpense(
                id: "split-old",
                fundID: activeFund.id,
                transactionID: "split-transaction",
                subtransactionID: "split-line",
                date: date(2026, 8, 11),
                amount: Money.dollars(integer: 50),
                active: true,
                updatedAt: date(2026, 8, 11)
            ),
            SpendingSinkingFundExpense(
                id: "split-new",
                fundID: activeFund.id,
                transactionID: "split-transaction",
                subtransactionID: "split-line",
                date: date(2026, 8, 11),
                amount: Money.dollars(integer: 50),
                active: false,
                updatedAt: date(2026, 8, 12)
            ),
            SpendingSinkingFundExpense(
                id: "archived",
                fundID: archivedFund.id,
                transactionID: "archived-transaction",
                date: date(2026, 8, 9),
                amount: Money.dollars(integer: 25),
                updatedAt: date(2026, 8, 9)
            ),
        ]

        let adjustment = SpendingReserveProjectionResolver.resolve(
            funds: [activeFund, archivedFund],
            contributions: contributions,
            expenses: expenses,
            through: month,
            calendar: utc
        )

        #expect(adjustment.balance == Money.dollars(integer: 400))
        #expect(adjustment.excludedHistoricalLineIDs == [
            "whole-transaction",
            "archived-transaction",
        ])
    }

    @Test("Remainder selection is effective dated")
    func remainderSelectionPreservesHistory() {
        let rules = [
            SpendingRemainderRule(
                id: "august",
                groupIdentity: "surplus",
                effectiveMonth: BudgetMonth(year: 2026, month: 8),
                enabled: true,
                updatedAt: date(2026, 8, 1)
            ),
            SpendingRemainderRule(
                id: "october",
                groupIdentity: "flexible",
                effectiveMonth: BudgetMonth(year: 2026, month: 10),
                enabled: true,
                updatedAt: date(2026, 10, 1)
            ),
        ]

        #expect(resolver.activeRemainderGroupIdentity(
            for: BudgetMonth(year: 2026, month: 9),
            rules: rules
        ) == "surplus")
        #expect(resolver.activeRemainderGroupIdentity(
            for: BudgetMonth(year: 2026, month: 10),
            rules: rules
        ) == "flexible")
    }

    @Test("Automatic remainder assigns every funded dollar and stays signed")
    func automaticRemainderCanBeNegative() {
        let rules = [
            rule(id: "fixed", group: "fixed", year: 2026, month: 9,
                 target: 1_100),
            rule(id: "surplus", group: "surplus", year: 2026, month: 9,
                 target: 1),
        ]
        let summary = resolver.summary(
            for: BudgetMonth(year: 2026, month: 9),
            groups: [
                group(id: "fixed", name: "Fixed", spent: 0),
                group(id: "surplus", name: "Surplus", spent: 0),
            ],
            rules: rules,
            funded: Money.dollars(integer: 1_000),
            remainderGroupIdentity: "surplus"
        )

        #expect(summary.target == Money.dollars(integer: 1_000))
        #expect(summary.groups.first {
            $0.groupIdentity == "surplus"
        }?.target == Money.dollars(integer: -100))
    }

    @Test("A Reserve assignment comes from its selected budget")
    func reserveAssignmentReallocatesSelectedBudget() {
        let month = BudgetMonth(year: 2026, month: 9)
        let assignment = SpendingSinkingFundContribution(
            id: "insurance-september",
            fundID: "insurance",
            month: month,
            sourceGroupIdentity: "necessities",
            amount: Money.dollars(integer: 100),
            updatedAt: date(2026, 9, 1)
        )
        let summary = resolver.summary(
            for: month,
            groups: [
                group(id: "necessities", name: "Necessities", spent: 200_000),
                group(id: "surplus", name: "Surplus", spent: 0),
            ],
            rules: [
                rule(id: "needs", group: "necessities", year: 2026,
                     month: 9, target: 600),
                rule(id: "surplus", group: "surplus", year: 2026,
                     month: 9, target: 1),
            ],
            reserveAssignments: [assignment],
            funded: Money.dollars(integer: 1_000),
            remainderGroupIdentity: "surplus"
        )

        let necessities = summary.groups.first {
            $0.groupIdentity == "necessities"
        }
        #expect(necessities?.target == Money.dollars(integer: 500))
        #expect(
            necessities?.reallocatedToReserves
                == Money.dollars(integer: 100)
        )
        #expect(summary.target + assignment.amount
            == Money.dollars(integer: 1_000))
        #expect(summary.remaining == Money.dollars(integer: 700))
        let display = summary.fundingDisplay(
            fundedBy: Money.dollars(integer: 1_000)
        )
        #expect(display.usedHeadline == Money.dollars(integer: 300))
        #expect(display.remainingHeadline == Money.dollars(integer: 700))
    }

    @Test("Reserve availability restores the assignment being edited")
    func reserveAvailabilityUsesSourceBudget() {
        let month = BudgetMonth(year: 2026, month: 9)
        let source = SpendingGroupBudgetSnapshot(
            groupIdentity: "necessities",
            groupName: "Necessities",
            spent: Money.dollars(integer: 400),
            target: Money.dollars(integer: 500),
            baseTarget: Money.dollars(integer: 600),
            reallocatedToReserves: Money.dollars(integer: 100)
        )
        let assignment = SpendingSinkingFundContribution(
            id: "insurance",
            fundID: "insurance",
            month: month,
            sourceGroupIdentity: "necessities",
            amount: Money.dollars(integer: 100),
            updatedAt: date(2026, 9, 1)
        )

        #expect(resolver.availableForReserveAssignment(
            from: source,
            month: month,
            assignments: [assignment],
            excludingAssignmentID: "insurance"
        ) == Money.dollars(integer: 200))
    }

    @Test("A Reserve can receive multiple assignments in one month")
    func reserveAssignmentsAccumulate() {
        let month = BudgetMonth(year: 2026, month: 9)
        let assignments = [
            SpendingSinkingFundContribution(
                id: "first",
                fundID: "insurance",
                month: month,
                sourceGroupIdentity: "necessities",
                amount: Money.dollars(integer: 100),
                updatedAt: date(2026, 9, 1)
            ),
            SpendingSinkingFundContribution(
                id: "second",
                fundID: "insurance",
                month: month,
                sourceGroupIdentity: "surplus",
                amount: Money.dollars(integer: 50),
                updatedAt: date(2026, 9, 2)
            ),
        ]
        let summary = resolver.summary(
            for: month,
            groups: [
                group(id: "necessities", name: "Necessities", spent: 0),
                group(id: "surplus", name: "Surplus", spent: 0),
            ],
            rules: [
                rule(id: "needs", group: "necessities", year: 2026,
                     month: 9, target: 600),
                rule(id: "surplus", group: "surplus", year: 2026,
                     month: 9, target: 400),
            ],
            reserveAssignments: assignments
        )

        #expect(summary.groups.first {
            $0.groupIdentity == "necessities"
        }?.target == Money.dollars(integer: 500))
        #expect(summary.groups.first {
            $0.groupIdentity == "surplus"
        }?.target == Money.dollars(integer: 350))
        let fund = SpendingSinkingFund(
            id: "insurance",
            name: "Insurance",
            mode: .ongoingReserve,
            startMonth: month
        )
        #expect(SpendingSinkingFundMath.snapshot(
            fund: fund,
            contributions: assignments,
            expenses: [],
            through: month
        ).balance == Money.dollars(integer: 150))
    }

    @Test("Closed Savings months remain independent until fulfilled")
    func savingsMonthStatusesDoNotRollForward() {
        let august = BudgetMonth(year: 2026, month: 8)
        let september = august.next
        let choice = SavingsBudgetChoice(
            id: "extra",
            month: august,
            sourceGroupIdentity: "surplus",
            savingsGroupIdentity: "savings",
            amount: Money.dollars(integer: 200),
            note: "Forgone spending",
            occurredAt: date(2026, 8, 20),
            updatedAt: date(2026, 8, 20)
        )

        let statuses = SavingsMonthStatusResolver().statuses(
            groupIdentity: "savings",
            rules: [
                rule(id: "base", group: "savings", year: 2026,
                     month: 8, target: 1_000)
            ],
            choices: [choice],
            savedByMonth: [
                august: Money.dollars(integer: 600),
                september: Money.dollars(integer: 1_000),
            ],
            through: september
        )

        #expect(statuses.map(\.outstanding) == [
            Money.dollars(integer: 600),
            .zero,
        ])
    }
}
