import Foundation
import Testing
@testable import Models
@testable import Money
@testable import Projections

@Suite("Monthly budget planner")
struct BudgetPlannerTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func txn(
        id: String = UUID().uuidString,
        date: Date,
        amount: Money,
        payee: String?,
        category: String? = nil,
        treatment: ForecastTreatment? = nil,
        transferAccountId: String? = nil,
        subs: [SubTransactionSummary] = []
    ) -> TransactionSummary {
        TransactionSummary(
            id: id, accountId: "acct", date: date, amount: amount,
            cleared: true, approved: true, payeeName: payee,
            categoryId: nil, categoryName: category,
            forecastTreatment: treatment,
            transferAccountId: transferAccountId,
            memo: nil, deleted: false, subtransactions: subs
        )
    }

    private func leg(
        id: String = UUID().uuidString,
        amount: Money,
        category: String?,
        treatment: ForecastTreatment? = nil,
        transfer: String? = nil
    ) -> SubTransactionSummary {
        SubTransactionSummary(
            id: id, amount: amount, categoryId: nil, categoryName: category,
            forecastTreatment: treatment, transferAccountId: transfer,
            payeeName: nil, memo: nil, deleted: false
        )
    }

    private var assignments: BudgetBucketAssignments {
        var result = BudgetBucketAssignments()
        result.assign(.necessities, categoryName: "Groceries")
        result.assign(.necessities, categoryName: "Medical")
        result.assign(.necessities, categoryName: "Therapy")
        result.assign(.surplus, categoryName: "Fun Money")
        result.assign(.fixed, categoryName: "Rent")
        result.assign(.income, categoryName: "Salary")
        result.assign(.savings, categoryName: "Vacation Fund")
        return result
    }

    private let aggregator = BudgetTransactionAggregator()
    private let planner = MonthlyBudgetPlanner()

    // MARK: - Aggregation rules

    @Test("Refunds reduce their category's spending")
    func refundsReduceCategory() {
        let result = aggregator.aggregate(
            transactions: [
                txn(date: date(2026, 6, 5), amount: .dollars(-100),
                    payee: "Market", category: "Groceries"),
                txn(date: date(2026, 6, 20), amount: .dollars(20),
                    payee: "Market", category: "Groceries",
                    treatment: .refund)
            ],
            assignments: assignments,
            calendar: utc
        )
        let june = BudgetMonth(year: 2026, month: 6)
        #expect(result.actuals(for: june).necessities == .dollars(80))
    }

    @Test("Split legs process individually; transfers and card payments drop")
    func splitAndTransferHandling() {
        let split = txn(
            date: date(2026, 6, 10), amount: .dollars(-80), payee: "Big Box",
            subs: [
                leg(amount: .dollars(-50), category: "Groceries"),
                leg(amount: .dollars(-30), category: "Groceries",
                    transfer: "other-acct")
            ]
        )
        let cardPayment = txn(
            date: date(2026, 6, 11), amount: .dollars(-500),
            payee: "Visa", category: "Groceries", treatment: .cardPayment
        )
        let transfer = txn(
            date: date(2026, 6, 12), amount: .dollars(-200),
            payee: "Savings", category: "Groceries",
            transferAccountId: "savings-acct"
        )
        let excluded = txn(
            date: date(2026, 6, 13), amount: .dollars(-75),
            payee: "Weird", category: "Groceries", treatment: .excluded
        )
        let result = aggregator.aggregate(
            transactions: [split, cardPayment, transfer, excluded],
            assignments: assignments,
            calendar: utc
        )
        let june = BudgetMonth(year: 2026, month: 6)
        #expect(result.actuals(for: june).necessities == .dollars(50))
    }

    @Test("Medical reimbursement legs credit Medical in the receipt month and never count as income")
    func medicalReimbursement() {
        let visit = txn(
            date: date(2026, 6, 3), amount: .dollars(-200),
            payee: "Clinic", category: "Medical"
        )
        let reimbursement = txn(
            date: date(2026, 7, 8), amount: .dollars(500), payee: "Insurer",
            subs: [leg(amount: .dollars(500), category: "Medical")]
        )
        let result = aggregator.aggregate(
            transactions: [visit, reimbursement],
            assignments: assignments,
            calendar: utc
        )
        let june = BudgetMonth(year: 2026, month: 6)
        let july = BudgetMonth(year: 2026, month: 7)
        #expect(result.actuals(for: june).necessities == .dollars(200))
        // Net credit in the receipt month, not income.
        #expect(result.actuals(for: july).necessities == .dollars(-500))
        #expect(result.actuals(for: july).income == .zero)
    }

    @Test("A confirmed commitment overrides its category bucket")
    func commitmentPrecedence() {
        let therapy = FixedCommitment(
            id: "therapy", displayName: "Therapy",
            payeeKey: "name:therapy office", categoryKey: nil,
            cadence: .biweekly, amountBasis: .latestAmount,
            amount: .dollars(150), anchorDate: date(2026, 6, 19)
        )
        let result = aggregator.aggregate(
            transactions: [
                txn(date: date(2026, 6, 5), amount: .dollars(-150),
                    payee: "Therapy Office", category: "Therapy")
            ],
            assignments: assignments,
            commitments: [therapy],
            calendar: utc
        )
        let june = BudgetMonth(year: 2026, month: 6)
        #expect(result.actuals(for: june).fixed == .dollars(150))
        #expect(result.actuals(for: june).necessities == .zero)
        #expect(
            result.commitmentActuals["therapy"]?[june] == .dollars(150)
        )
    }

    @Test("Savings and unassigned spending stay outside Phase 1 buckets")
    func savingsAndUnassignedIgnored() {
        let result = aggregator.aggregate(
            transactions: [
                txn(date: date(2026, 6, 5), amount: .dollars(-300),
                    payee: "Broker", category: "Vacation Fund"),
                txn(date: date(2026, 6, 6), amount: .dollars(-45),
                    payee: "Mystery", category: "Unmapped Category")
            ],
            assignments: assignments,
            calendar: utc
        )
        let june = BudgetMonth(year: 2026, month: 6)
        let actuals = result.actuals(for: june)
        #expect(actuals.reportedSpending == .zero)
        #expect(actuals.income == .zero)
    }

    // MARK: - Necessities envelope

    @Test("Envelope is the median of 12 completed months including zero months")
    func envelopeIncludesZeroMonths() {
        // Spending in Jan–Jun 2026 only; Jul–Dec 2025 are zero months.
        let transactions = (1...6).map { month in
            txn(date: date(2026, month, 10), amount: .dollars(-100),
                payee: "Market", category: "Groceries")
        }
        let aggregation = aggregator.aggregate(
            transactions: transactions,
            assignments: assignments,
            calendar: utc
        )
        let envelope = planner.necessitiesEnvelope(
            aggregation: aggregation,
            latestCompleted: BudgetMonth(year: 2026, month: 6)
        )
        // Sorted window is six zeros + six 100s → median 50.
        #expect(envelope == .dollars(50))
    }

    @Test("The current partial month never enters the envelope")
    func envelopeExcludesCurrentMonth() {
        var transactions = (1...6).map { month in
            txn(date: date(2026, month, 10), amount: .dollars(-100),
                payee: "Market", category: "Groceries")
        }
        // A huge current-month spend must not move the envelope.
        transactions.append(
            txn(date: date(2026, 7, 2), amount: .dollars(-9_000),
                payee: "Market", category: "Groceries")
        )
        let aggregation = aggregator.aggregate(
            transactions: transactions,
            assignments: assignments,
            calendar: utc
        )
        let plan = planner.plan(
            for: BudgetMonth(year: 2026, month: 7),
            aggregation: aggregation,
            commitments: [],
            incomePattern: nil,
            surplusTarget: .dollars(1_000),
            asOf: date(2026, 7, 20),
            calendar: utc
        )
        #expect(plan.necessitiesEnvelope == .dollars(50))
    }

    // MARK: - Composed plan

    @Test("Planned margin composes income − fixed − necessities − surplus")
    func composedPlan() {
        var transactions = (1...6).map { month in
            txn(date: date(2026, month, 10), amount: .dollars(-100),
                payee: "Market", category: "Groceries")
        }
        transactions += [
            txn(date: date(2026, 7, 1), amount: .dollars(-2_000),
                payee: "Rent Co", category: "Rent"),
            txn(date: date(2026, 7, 3), amount: .dollars(-150),
                payee: "Therapy Office", category: "Therapy"),
            txn(date: date(2026, 7, 17), amount: .dollars(-150),
                payee: "Therapy Office", category: "Therapy"),
            txn(date: date(2026, 7, 3), amount: .dollars(-120),
                payee: "Market", category: "Groceries"),
            txn(date: date(2026, 7, 5), amount: .dollars(-40),
                payee: "Cinema", category: "Fun Money"),
            txn(date: date(2026, 7, 2), amount: .dollars(4_000),
                payee: "Acme", category: "Salary"),
            txn(date: date(2026, 7, 16), amount: .dollars(4_000),
                payee: "Acme", category: "Salary")
        ]
        let rent = FixedCommitment(
            id: "rent", displayName: "Rent", payeeKey: "name:rent co",
            categoryKey: nil, cadence: .monthly,
            amountBasis: .latestAmount, amount: .dollars(2_000),
            anchorDate: date(2026, 6, 1)
        )
        let therapy = FixedCommitment(
            id: "therapy", displayName: "Therapy",
            payeeKey: "name:therapy office", categoryKey: nil,
            cadence: .biweekly, amountBasis: .latestAmount,
            amount: .dollars(150), anchorDate: date(2026, 6, 19)
        )
        let pattern = IncomePattern(
            payeeKey: "name:acme", displayName: "Acme",
            cadence: .biweekly, anchorDate: date(2026, 6, 19),
            phases: [IncomePhaseObservation(
                kind: .ficaOnly, year: 2026,
                perPaycheckAmount: .dollars(4_000),
                firstDate: date(2026, 1, 2), lastDate: date(2026, 6, 19),
                paycheckCount: 12
            )]
        )
        let aggregation = aggregator.aggregate(
            transactions: transactions,
            assignments: assignments,
            commitments: [rent, therapy],
            calendar: utc
        )
        let plan = planner.plan(
            for: BudgetMonth(year: 2026, month: 7),
            aggregation: aggregation,
            commitments: [rent, therapy],
            incomePattern: pattern,
            surplusTarget: .dollars(1_000),
            asOf: date(2026, 7, 20),
            calendar: utc
        )
        // Sanitized July case: three biweekly paychecks → three occurrences.
        #expect(plan.expectedPaycheckCount == 3)
        #expect(plan.expectedIncome == .dollars(12_000))
        // Rent 2000 + therapy 3 × 150.
        #expect(plan.plannedFixed == .dollars(2_450))
        #expect(plan.necessitiesEnvelope == .dollars(50))
        #expect(plan.plannedMargin == .dollars(8_500))
        #expect(plan.actualIncome == .dollars(8_000))
        #expect(plan.actualFixed == .dollars(2_300))
        #expect(plan.actualNecessities == .dollars(120))
        #expect(plan.actualSurplus == .dollars(40))
        #expect(plan.actualMargin == .dollars(5_540))
        // Current month headlines the planned margin.
        #expect(!plan.isCompleted)
        #expect(plan.primaryMargin == .dollars(8_500))
        // Lines sort by planned amount.
        #expect(plan.fixedLines.map(\.id) == ["rent", "therapy"])
        #expect(plan.fixedLines[1].expectedOccurrences == 3)
        #expect(plan.fixedLines[1].actual == .dollars(300))
    }

    @Test("Completed months headline the actual margin")
    func completedMonthUsesActualMargin() {
        let aggregation = aggregator.aggregate(
            transactions: [
                txn(date: date(2026, 5, 10), amount: .dollars(-100),
                    payee: "Market", category: "Groceries"),
                txn(date: date(2026, 5, 2), amount: .dollars(4_000),
                    payee: "Acme", category: "Salary")
            ],
            assignments: assignments,
            calendar: utc
        )
        let plan = planner.plan(
            for: BudgetMonth(year: 2026, month: 5),
            aggregation: aggregation,
            commitments: [],
            incomePattern: nil,
            surplusTarget: .dollars(1_000),
            asOf: date(2026, 7, 20),
            calendar: utc
        )
        #expect(plan.isCompleted)
        #expect(plan.actualMargin == .dollars(3_900))
        #expect(plan.primaryMargin == .dollars(3_900))
    }

    @Test("Quarterly and annual commitments reserve evenly by month")
    func nonMonthlyReserves() {
        let quarterly = FixedCommitment(
            id: "insurance", displayName: "Insurance",
            payeeKey: "name:insurer", categoryKey: nil,
            cadence: .quarterly, amountBasis: .latestAmount,
            amount: .dollars(300), anchorDate: date(2026, 5, 1)
        )
        let annual = FixedCommitment(
            id: "membership", displayName: "Membership",
            payeeKey: "name:club", categoryKey: nil,
            cadence: .annual, amountBasis: .latestAmount,
            amount: .dollars(1_200), anchorDate: date(2026, 2, 1)
        )
        let month = BudgetMonth(year: 2026, month: 7)
        #expect(quarterly.plannedAmount(in: month, calendar: utc)
            == .dollars(100))
        #expect(annual.plannedAmount(in: month, calendar: utc)
            == .dollars(100))
    }

    @Test("A stale commitment stays active in the plan with a quiet marker")
    func staleCommitmentRemainsActive() {
        let gym = FixedCommitment(
            id: "gym", displayName: "Gym", payeeKey: "name:gym",
            categoryKey: nil, cadence: .monthly,
            amountBasis: .latestAmount, amount: .dollars(80),
            anchorDate: date(2026, 3, 1)
        )
        let plan = planner.plan(
            for: BudgetMonth(year: 2026, month: 7),
            aggregation: BudgetAggregationResult(),
            commitments: [gym],
            incomePattern: nil,
            surplusTarget: .dollars(1_000),
            asOf: date(2026, 7, 20),
            calendar: utc
        )
        #expect(plan.fixedLines.count == 1)
        #expect(plan.fixedLines[0].isStale)
        #expect(plan.plannedFixed == .dollars(80))
    }

    @Test("A bucket breakdown itemizes exactly what the totals counted")
    func bucketBreakdownMatchesTotals() {
        let therapy = FixedCommitment(
            id: "therapy", displayName: "Therapy",
            payeeKey: "name:therapy office", categoryKey: nil,
            cadence: .biweekly, amountBasis: .latestAmount,
            amount: .dollars(150), anchorDate: date(2026, 6, 19)
        )
        let transactions = [
            txn(date: date(2026, 5, 3), amount: .dollars(-9_000),
                payee: "Travel Co", category: "Fun Money"),
            txn(date: date(2026, 5, 10), amount: .dollars(-400),
                payee: "Cinema", category: "Fun Money"),
            txn(date: date(2026, 5, 12), amount: .dollars(100),
                payee: "Travel Co", category: "Fun Money",
                treatment: .refund),
            txn(date: date(2026, 5, 15), amount: .dollars(-120),
                payee: "Market", category: "Groceries"),
            // Commitment override: counted as Fixed, never Necessities.
            txn(date: date(2026, 5, 8), amount: .dollars(-150),
                payee: "Therapy Office", category: "Therapy"),
            // Different month: excluded from May's breakdown.
            txn(date: date(2026, 4, 20), amount: .dollars(-500),
                payee: "Cinema", category: "Fun Money")
        ]
        let may = BudgetMonth(year: 2026, month: 5)
        let surplus = aggregator.breakdown(
            of: .surplus, in: may,
            transactions: transactions,
            assignments: assignments,
            commitments: [therapy],
            calendar: utc
        )
        #expect(surplus.total == .dollars(9_300))
        #expect(surplus.categories.count == 1)
        #expect(surplus.categories.first?.name == "Fun Money")
        #expect(surplus.categories.first?.amount == .dollars(9_300))
        #expect(surplus.largestItems.first?.payeeName == "Travel Co")
        #expect(surplus.largestItems.first?.amount == .dollars(9_000))
        // The refund appears as a negative item, last.
        #expect(surplus.largestItems.last?.amount == .dollars(-100))

        let necessities = aggregator.breakdown(
            of: .necessities, in: may,
            transactions: transactions,
            assignments: assignments,
            commitments: [therapy],
            calendar: utc
        )
        #expect(necessities.total == .dollars(120))
        #expect(necessities.categories.map(\.name) == ["Groceries"])
    }

    @Test("Reimbursement categories never count as income, even when unassigned")
    func unassignedReimbursementsExcluded() {
        // Category "Reimbursements" got no bucket assignment during setup
        // and the review flow marked the deposit's treatment as income.
        let deposit = txn(
            date: date(2026, 4, 10), amount: .dollars(12_000),
            payee: "Insurer", category: "Reimbursements",
            treatment: .income
        )
        let paycheck = txn(
            date: date(2026, 4, 3), amount: .dollars(6_400),
            payee: "Acme", category: "Salary"
        )
        let result = aggregator.aggregate(
            transactions: [deposit, paycheck],
            assignments: assignments,
            calendar: utc
        )
        let april = BudgetMonth(year: 2026, month: 4)
        #expect(result.actuals(for: april).income == .dollars(6_400))

        let breakdown = aggregator.breakdown(
            of: .income, in: april,
            transactions: [deposit, paycheck],
            assignments: assignments,
            calendar: utc
        )
        #expect(breakdown.total == .dollars(6_400))
        #expect(breakdown.largestItems.map(\.payeeName) == ["Acme"])
        #expect(breakdown.categories.map(\.name) == ["Salary"])
    }

    @Test("With a known paycheck source, windfalls never count as earned income")
    func windfallsExcludedFromEarnedIncome() {
        let paycheck = txn(
            date: date(2026, 4, 3), amount: .dollars(7_600),
            payee: "Gusto", category: "Salary"
        )
        // Tax refund lands in the same income-bucketed category.
        let refund = txn(
            date: date(2026, 4, 18), amount: .dollars(11_651),
            payee: "IRS", category: "Salary"
        )
        let keys: Set<String> = ["name:gusto"]
        let result = aggregator.aggregate(
            transactions: [paycheck, refund],
            assignments: assignments,
            incomePayeeKeys: keys,
            calendar: utc
        )
        let april = BudgetMonth(year: 2026, month: 4)
        #expect(result.actuals(for: april).income == .dollars(7_600))

        let breakdown = aggregator.breakdown(
            of: .income, in: april,
            transactions: [paycheck, refund],
            assignments: assignments,
            incomePayeeKeys: keys,
            calendar: utc
        )
        #expect(breakdown.total == .dollars(7_600))
        #expect(breakdown.largestItems.map(\.payeeName) == ["Gusto"])
        // The refund stays visible as an uncounted deposit.
        #expect(breakdown.uncountedItems.map(\.payeeName) == ["IRS"])
        #expect(breakdown.uncountedItems.first?.amount == .dollars(11_651))
    }

    @Test("History zero-fills months with no activity, ascending")
    func historyZeroFills() {
        let aggregation = aggregator.aggregate(
            transactions: [
                txn(date: date(2026, 3, 10), amount: .dollars(-100),
                    payee: "Market", category: "Groceries")
            ],
            assignments: assignments,
            calendar: utc
        )
        let history = planner.history(
            endingWith: BudgetMonth(year: 2026, month: 6),
            monthCount: 12,
            aggregation: aggregation
        )
        #expect(history.count == 12)
        #expect(history.first?.month == BudgetMonth(year: 2025, month: 7))
        #expect(history.last?.month == BudgetMonth(year: 2026, month: 6))
        #expect(history[8].necessities == .dollars(100))
        #expect(history.filter { $0.necessities == .zero }.count == 11)
    }

    @Test("Month arithmetic normalizes across year boundaries")
    func monthArithmetic() {
        let january = BudgetMonth(year: 2026, month: 1)
        #expect(january.previous == BudgetMonth(year: 2025, month: 12))
        #expect(january.advanced(by: -13) == BudgetMonth(year: 2024, month: 12))
        #expect(january.advanced(by: 12) == BudgetMonth(year: 2027, month: 1))
        #expect(BudgetMonth(year: 2025, month: 12) < january)
    }
}
