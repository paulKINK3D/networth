import Foundation
import Testing
@testable import Models
@testable import Money
@testable import Projections

@Suite("Income analyzer")
struct IncomeAnalyzerTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func deposit(
        date: Date,
        amount: Money,
        payee: String,
        category: String? = "Salary",
        treatment: ForecastTreatment? = .income
    ) -> TransactionSummary {
        TransactionSummary(
            id: UUID().uuidString, accountId: "checking", date: date,
            amount: amount, cleared: true, approved: true, payeeName: payee,
            categoryId: nil, categoryName: category,
            forecastTreatment: treatment,
            memo: nil, deleted: false
        )
    }

    /// Biweekly Friday paychecks starting at `start`.
    private func paychecks(
        from start: Date,
        count: Int,
        amount: @escaping (Int) -> Money
    ) -> [TransactionSummary] {
        (0..<count).map { step in
            deposit(
                date: utc.date(byAdding: .day, value: step * 14, to: start)!,
                amount: amount(step),
                payee: "Acme Payroll"
            )
        }
    }

    private var assignments: BudgetBucketAssignments {
        var result = BudgetBucketAssignments()
        result.assign(.income, categoryName: "Salary")
        result.assign(.necessities, categoryName: "Medical")
        return result
    }

    private let analyzer = IncomeAnalyzer()

    private func detect(
        _ transactions: [TransactionSummary],
        asOf: Date
    ) -> IncomePattern? {
        analyzer.detectPattern(
            transactions: transactions,
            assignments: assignments,
            asOf: asOf,
            calendar: utc
        )
    }

    @Test("Sanitized July case: biweekly cadence plans three July paychecks")
    func threePaycheckJuly() throws {
        // 12 biweekly Friday paychecks, 2026-01-02 through 2026-06-19.
        let transactions = paychecks(
            from: date(2026, 1, 2), count: 13
        ) { _ in .dollars(4_000) }
        let pattern = try #require(detect(transactions, asOf: date(2026, 6, 30)))
        #expect(pattern.cadence == .biweekly)
        #expect(pattern.anchorDate == date(2026, 6, 19))
        let july = BudgetMonth(year: 2026, month: 7)
        let dates = pattern.expectedPaycheckDates(in: july, calendar: utc)
        #expect(dates == [date(2026, 7, 3), date(2026, 7, 17),
                          date(2026, 7, 31)])
        #expect(pattern.expectedIncome(for: july, calendar: utc)
            == .dollars(12_000))
        // The following month falls back to two.
        #expect(pattern.expectedPaycheckCount(
            in: BudgetMonth(year: 2026, month: 8), calendar: utc
        ) == 2)
    }

    @Test("Completed months count observed paychecks, never back-projected phantoms")
    func completedMonthsUseObservedPaychecks() {
        // Actual biweekly Fridays Jan 2 – Jul 31 2026: May pays on the 8th
        // and 22nd (two), July on the 3rd, 17th, and 31st (three). The
        // anchor is deliberately misaligned (as if the latest deposit
        // posted off-cycle) — naive back-stepping from Jul 24 would invent
        // paydays on May 1/15/29.
        let observed = (0..<16).map {
            utc.date(byAdding: .day, value: $0 * 14, to: date(2026, 1, 2))!
        }
        let pattern = IncomePattern(
            payeeKey: "name:acme payroll",
            displayName: "Acme Payroll",
            cadence: .biweekly,
            anchorDate: date(2026, 7, 24),
            observedPaycheckDates: observed,
            phases: []
        )
        let may = BudgetMonth(year: 2026, month: 5)
        #expect(pattern.expectedPaycheckDates(in: may, calendar: utc)
            == [date(2026, 5, 8), date(2026, 5, 22)])
        let july = BudgetMonth(year: 2026, month: 7)
        #expect(pattern.expectedPaycheckDates(in: july, calendar: utc)
            == [date(2026, 7, 3), date(2026, 7, 17), date(2026, 7, 31)])
        // Fully future months still project from cadence.
        #expect(pattern.expectedPaycheckCount(
            in: BudgetMonth(year: 2026, month: 9), calendar: utc
        ) == 2)
    }

    @Test("Detection records every observed paycheck date")
    func observedDatesPopulated() throws {
        let transactions = paychecks(
            from: date(2026, 1, 2), count: 13
        ) { _ in .dollars(4_000) }
        let pattern = try #require(detect(transactions, asOf: date(2026, 6, 30)))
        #expect(pattern.observedPaycheckDates.count == 13)
        // Completed May shows its two real paydays.
        #expect(pattern.expectedPaycheckDates(
            in: BudgetMonth(year: 2026, month: 5), calendar: utc
        ) == [date(2026, 5, 8), date(2026, 5, 22)])
    }

    @Test("Semimonthly pay lands on its two fixed days, clamped to short months")
    func semimonthlyCadence() throws {
        var transactions: [TransactionSummary] = []
        for month in 1...6 {
            transactions.append(deposit(
                date: date(2026, month, 15), amount: .dollars(3_000),
                payee: "Acme Payroll"
            ))
            let lastDay = utc.range(
                of: .day, in: .month,
                for: date(2026, month, 1)
            )!.count
            transactions.append(deposit(
                date: date(2026, month, lastDay), amount: .dollars(3_000),
                payee: "Acme Payroll"
            ))
        }
        let pattern = try #require(detect(transactions, asOf: date(2026, 7, 1)))
        #expect(pattern.cadence == .semimonthly)
        #expect(pattern.daysOfMonth == [15, 31])
        // February clamps the end-of-month payday.
        let february = BudgetMonth(year: 2027, month: 2)
        #expect(pattern.expectedPaycheckDates(in: february, calendar: utc)
            == [date(2027, 2, 15), date(2027, 2, 28)])
    }

    @Test("Three annual take-home phases are learned in order")
    func threePhases() throws {
        // 26 biweekly paychecks in 2025: 8 low, 9 middle, 9 high.
        let transactions = paychecks(
            from: date(2025, 1, 3), count: 26
        ) { step in
            if step < 8 { return .dollars(4_200) }
            if step < 17 { return .dollars(4_800) }
            return .dollars(5_300)
        }
        let pattern = try #require(detect(transactions, asOf: date(2026, 1, 5)))
        #expect(pattern.phases.count == 3)
        #expect(pattern.phases.map(\.kind)
            == [.preTaxHeavy, .ficaOnly, .postFica])
        #expect(pattern.phases.map(\.perPaycheckAmount)
            == [.dollars(4_200), .dollars(4_800), .dollars(5_300)])
        #expect(pattern.phases.map(\.paycheckCount) == [8, 9, 9])
    }

    @Test("Without current-year deposits, planning falls back to the prior year's matching phase")
    func conservativeFallback() throws {
        let transactions = paychecks(
            from: date(2025, 1, 3), count: 26
        ) { step in
            if step < 8 { return .dollars(4_200) }
            if step < 17 { return .dollars(4_800) }
            return .dollars(5_300)
        }
        let pattern = try #require(detect(transactions, asOf: date(2026, 1, 5)))
        // January restarts 401(k) + FICA withholding: use the early-year
        // amount, never the late-year step-up.
        #expect(pattern.expectedPerPaycheckAmount(
            for: BudgetMonth(year: 2026, month: 1), calendar: utc
        ) == .dollars(4_200))
        // Mid-year months match the prior year's middle phase.
        #expect(pattern.expectedPerPaycheckAmount(
            for: BudgetMonth(year: 2026, month: 6), calendar: utc
        ) == .dollars(4_800))
    }

    @Test("A completed month is priced at its own phase, not the latest one")
    func pastMonthUsesCoveringPhase() throws {
        // 2026: early-year checks 6,400 (Jan–Jun), step up to 8,300 in July.
        var transactions = paychecks(
            from: date(2026, 1, 2), count: 13
        ) { _ in .dollars(6_400) }
        transactions += paychecks(
            from: date(2026, 7, 3), count: 3
        ) { _ in .dollars(8_300) }
        let pattern = try #require(detect(transactions, asOf: date(2026, 8, 2)))
        let may = BudgetMonth(year: 2026, month: 5)
        #expect(pattern.expectedPerPaycheckAmount(for: may, calendar: utc)
            == .dollars(6_400))
        // Two real May paydays priced at May's phase.
        #expect(pattern.expectedIncome(for: may, calendar: utc)
            == .dollars(12_800))
        // Current/future months use the latest observed amount.
        #expect(pattern.expectedPerPaycheckAmount(
            for: BudgetMonth(year: 2026, month: 8), calendar: utc
        ) == .dollars(8_300))
    }

    @Test("Current-year observed deposits win over historical phases")
    func currentYearWins() throws {
        var transactions = paychecks(
            from: date(2025, 1, 3), count: 26
        ) { step in
            if step < 8 { return .dollars(4_200) }
            if step < 17 { return .dollars(4_800) }
            return .dollars(5_300)
        }
        // 2026 raise observed: paychecks now 4,400.
        transactions += paychecks(
            from: date(2026, 1, 2), count: 6
        ) { _ in .dollars(4_400) }
        let pattern = try #require(detect(transactions, asOf: date(2026, 3, 25)))
        #expect(pattern.expectedPerPaycheckAmount(
            for: BudgetMonth(year: 2026, month: 4), calendar: utc
        ) == .dollars(4_400))
    }

    @Test("Reimbursements never enter phase detection or expected income")
    func reimbursementsExcluded() throws {
        var transactions = paychecks(
            from: date(2026, 1, 2), count: 10
        ) { _ in .dollars(4_000) }
        // Large insurer inflows categorized Medical are category credits.
        transactions.append(deposit(
            date: date(2026, 2, 10), amount: .dollars(6_000),
            payee: "Insurer", category: "Medical", treatment: nil
        ))
        transactions.append(deposit(
            date: date(2026, 3, 10), amount: .dollars(6_000),
            payee: "Insurer", category: "Medical", treatment: nil
        ))
        let pattern = try #require(detect(transactions, asOf: date(2026, 5, 25)))
        #expect(pattern.payeeKey == "name:acme payroll")
        #expect(pattern.phases.allSatisfy {
            $0.perPaycheckAmount == .dollars(4_000)
        })
    }

    @Test("The primary paycheck is the dominant regular payer")
    func primaryPayerSelection() throws {
        var transactions = paychecks(
            from: date(2026, 1, 2), count: 10
        ) { _ in .dollars(4_000) }
        // Occasional side income must not win.
        for month in [1, 3, 5] {
            transactions.append(deposit(
                date: date(2026, month, 20), amount: .dollars(900),
                payee: "Side Gig"
            ))
        }
        let pattern = try #require(detect(transactions, asOf: date(2026, 5, 25)))
        #expect(pattern.displayName == "Acme Payroll")
    }

    @Test("Too few deposits produce no pattern")
    func insufficientHistory() {
        let transactions = paychecks(
            from: date(2026, 1, 2), count: 3
        ) { _ in .dollars(4_000) }
        #expect(detect(transactions, asOf: date(2026, 2, 20)) == nil)
    }
}
