import Foundation
import Testing
@testable import Models
@testable import Money
@testable import Projections

@Suite("Paycheck detection")
struct PaycheckDetectionTests {
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
        payee: String?,
        payeeCanonicalId: String? = nil,
        accountId: String = "checking",
        treatment: ForecastTreatment? = .income,
        approved: Bool = true
    ) -> TransactionSummary {
        TransactionSummary(
            id: UUID().uuidString, accountId: accountId, date: date,
            amount: amount, cleared: true, approved: approved,
            payeeName: payee, categoryId: nil, categoryName: nil,
            payeeCanonicalId: payeeCanonicalId,
            forecastTreatment: treatment,
            memo: nil, deleted: false
        )
    }

    private func biweekly(
        from start: Date,
        count: Int,
        payee: String = "Acme Payroll",
        accountId: String = "checking",
        amount: @escaping (Int) -> Money = { _ in .dollars(4_000) }
    ) -> [TransactionSummary] {
        (0..<count).map { step in
            deposit(
                date: utc.date(byAdding: .day, value: step * 14, to: start)!,
                amount: amount(step),
                payee: payee,
                accountId: accountId
            )
        }
    }

    private let analyzer = IncomeAnalyzer()

    private func detect(
        _ transactions: [TransactionSummary],
        selected: Set<String> = ["checking"],
        asOf: Date
    ) -> PaycheckDetection {
        analyzer.detectPaycheck(
            confirmedTransactions: transactions,
            selectedAccountIds: selected,
            asOf: asOf,
            calendar: utc
        )
    }

    private func detected(
        _ detection: PaycheckDetection,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> DetectedPaycheck? {
        guard case .detected(let paycheck) = detection else {
            Issue.record(
                "expected detection, got \(detection)",
                sourceLocation: sourceLocation
            )
            return nil
        }
        return paycheck
    }

    @Test("Biweekly paychecks detect with next date after as-of")
    func biweeklyDetection() throws {
        // 8 biweekly paychecks, 2026-03-06 through 2026-06-12.
        let paycheck = try #require(detected(detect(
            biweekly(from: date(2026, 3, 6), count: 8),
            asOf: date(2026, 6, 20)
        )))
        #expect(paycheck.cadence == .biweekly)
        #expect(paycheck.displayName == "Acme Payroll")
        #expect(paycheck.portions.map(\.accountId) == ["checking"])
        #expect(paycheck.nextAmount == .dollars(4_000))
        #expect(paycheck.nextDate == date(2026, 6, 26))
        #expect(paycheck.confirmedDepositCount == 8)
    }

    @Test("One missed payday is review lag, not a dead pattern")
    func oneMissedPaydayStillProjects() throws {
        // Last deposit 2026-06-12; the 06-26 payday passed unconfirmed.
        let paycheck = try #require(detected(detect(
            biweekly(from: date(2026, 3, 6), count: 8),
            asOf: date(2026, 6, 28)
        )))
        #expect(paycheck.nextDate == date(2026, 7, 10))
    }

    @Test("Two missed paydays stop income projection as stale")
    func staleHistory() {
        // Last deposit 2026-03-13; 03-27 and 04-10 both passed unconfirmed.
        let detection = detect(
            biweekly(from: date(2026, 1, 2), count: 6),
            asOf: date(2026, 4, 12)
        )
        #expect(detection == .staleHistory(
            payeeName: "Acme Payroll", lastDepositDate: date(2026, 3, 13)
        ))
    }

    @Test("Fewer than four confirmed deposits reports insufficient history")
    func insufficientHistory() {
        let detection = detect(
            biweekly(from: date(2026, 5, 1), count: 3),
            asOf: date(2026, 6, 10)
        )
        #expect(detection == .insufficientHistory(
            payeeName: "Acme Payroll", depositCount: 3
        ))
    }

    @Test("No confirmed income reports the empty state")
    func noIncome() {
        let spending = deposit(
            date: date(2026, 6, 1), amount: .dollars(-50),
            payee: "Grocer", treatment: .ordinarySpending
        )
        #expect(detect([spending], asOf: date(2026, 6, 10)) == .noConfirmedIncome)
        #expect(detect([], asOf: date(2026, 6, 10)) == .noConfirmedIncome)
    }

    @Test("Irregular deposit gaps report unstable cadence")
    func unstableCadence() {
        let days = [0, 2, 4, 50]
        let deposits = days.map { offset in
            deposit(
                date: utc.date(
                    byAdding: .day, value: offset, to: date(2026, 3, 1)
                )!,
                amount: .dollars(900),
                payee: "Gig Work"
            )
        }
        #expect(detect(deposits, asOf: date(2026, 5, 1)) == .unstableCadence(
            payeeName: "Gig Work", depositCount: 4
        ))
    }

    @Test("Deposits landing only outside the cash pool report excluded")
    func depositsExcluded() {
        let detection = detect(
            biweekly(
                from: date(2026, 3, 6), count: 8, accountId: "savings"
            ),
            selected: ["checking"],
            asOf: date(2026, 6, 20)
        )
        #expect(detection == .depositsExcluded(payeeName: "Acme Payroll"))
    }

    @Test("Split deposits project only the portion inside the cash pool")
    func splitAcrossAccountsScopesToPool() throws {
        // Every payday: $3,000 to checking (in pool), $1,000 to savings
        // (excluded). Same payer, same day.
        var deposits: [TransactionSummary] = []
        for step in 0..<8 {
            let payday = utc.date(
                byAdding: .day, value: step * 14, to: date(2026, 3, 6)
            )!
            deposits.append(deposit(
                date: payday, amount: .dollars(3_000),
                payee: "Acme Payroll", accountId: "checking"
            ))
            deposits.append(deposit(
                date: payday, amount: .dollars(1_000),
                payee: "Acme Payroll", accountId: "savings"
            ))
        }
        let paycheck = try #require(detected(detect(
            deposits, selected: ["checking"], asOf: date(2026, 6, 20)
        )))
        #expect(paycheck.nextAmount == .dollars(3_000))
        #expect(paycheck.portions.map(\.accountId) == ["checking"])
        #expect(paycheck.confirmedDepositCount == 8)
    }

    @Test("Split paychecks project separate inflows per receiving account")
    func splitAcrossSelectedAccountsProjectsPerAccount() throws {
        // Every payday: $3,000 to checking + $1,000 to savings, BOTH in the
        // pool. Checking must never be credited with the savings portion.
        var deposits: [TransactionSummary] = []
        for step in 0..<8 {
            let payday = utc.date(
                byAdding: .day, value: step * 14, to: date(2026, 3, 6)
            )!
            deposits.append(deposit(
                date: payday, amount: .dollars(3_000),
                payee: "Acme Payroll", accountId: "checking"
            ))
            deposits.append(deposit(
                date: payday, amount: .dollars(1_000),
                payee: "Acme Payroll", accountId: "savings"
            ))
        }
        let paycheck = try #require(detected(detect(
            deposits, selected: ["checking", "savings"],
            asOf: date(2026, 6, 20)
        )))
        #expect(paycheck.portions.map(\.accountId) == ["checking", "savings"])
        #expect(paycheck.nextAmount == .dollars(4_000))
        let events = paycheck.scheduledSummaries(
            asOf: date(2026, 6, 20), horizonDays: 15, calendar: utc
        )
        // One payday (06-26) → two independent inflows.
        #expect(events.count == 2)
        #expect(events.map(\.accountId) == ["checking", "savings"])
        #expect(events.map(\.amount) == [.dollars(3_000), .dollars(1_000)])
        #expect(events.allSatisfy { $0.nextDate == date(2026, 6, 26) })
        #expect(Set(events.map(\.id)).count == 2)
    }

    @Test("A trailing one-off bonus never becomes the recurring amount")
    func trailingBonusIsNotAdopted() throws {
        // Six 4,400 paychecks, then a single 9,000 final deposit.
        let amounts: [Money] = [
            .dollars(4_400), .dollars(4_400), .dollars(4_400),
            .dollars(4_400), .dollars(4_400), .dollars(4_400),
            .dollars(9_000)
        ]
        let paycheck = try #require(detected(detect(
            biweekly(from: date(2026, 2, 6), count: 7) { amounts[$0] },
            asOf: date(2026, 5, 10)
        )))
        #expect(paycheck.nextAmount == .dollars(4_400))
        let events = paycheck.scheduledSummaries(
            asOf: date(2026, 5, 10), horizonDays: 45, calendar: utc
        )
        #expect(!events.isEmpty)
        #expect(events.allSatisfy { $0.amount == .dollars(4_400) })
    }

    @Test("An off-cycle bonus never shifts the payday anchor or amount")
    func offCycleBonusIsDropped() throws {
        // Six biweekly 4,400 paychecks ending 2026-06-12, then a lone
        // 9,000 bonus on 06-17 — off the 14-day grid.
        var deposits = biweekly(from: date(2026, 3, 20), count: 7) { _ in
            .dollars(4_400)
        }
        deposits.append(deposit(
            date: date(2026, 6, 17), amount: .dollars(9_000),
            payee: "Acme Payroll"
        ))
        let paycheck = try #require(detected(
            detect(deposits, asOf: date(2026, 6, 20))
        ))
        // Anchor stays 06-12: next payday is 06-26, not bonus + 14 days.
        #expect(paycheck.nextDate == date(2026, 6, 26))
        #expect(paycheck.nextAmount == .dollars(4_400))
        #expect(paycheck.confirmedDepositCount == 7)
    }

    @Test("A one-time bonus into a new account is not a recurring portion")
    func bonusIntoNewAccountIsDropped() throws {
        // Regular paychecks into checking; the last payday also lands a
        // one-off 9,000 bonus in a bonus-savings account. Both selected.
        var deposits = biweekly(from: date(2026, 3, 6), count: 8) { _ in
            .dollars(3_000)
        }
        deposits.append(deposit(
            date: date(2026, 6, 12), amount: .dollars(9_000),
            payee: "Acme Payroll", accountId: "bonus-savings"
        ))
        let paycheck = try #require(detected(detect(
            deposits, selected: ["checking", "bonus-savings"],
            asOf: date(2026, 6, 20)
        )))
        #expect(paycheck.portions.map(\.accountId) == ["checking"])
        #expect(paycheck.nextAmount == .dollars(3_000))
        let events = paycheck.scheduledSummaries(
            asOf: date(2026, 6, 20), horizonDays: 15, calendar: utc
        )
        #expect(events.map(\.accountId) == ["checking"])
        #expect(events.map(\.amount) == [.dollars(3_000)])
    }

    @Test("Month-end paydays are checked at their clamped dates")
    func monthEndFreshnessDoesNotDrift() throws {
        // Paydays on the 31st (clamped in short months): Jan 31, Feb 28,
        // Mar 31, Apr 30. On May 30 the May payday (05-31) has not been
        // missed — a drifting 30-day step would already count it.
        let deposits = [
            date(2026, 1, 31), date(2026, 2, 28),
            date(2026, 3, 31), date(2026, 4, 30)
        ].map {
            deposit(date: $0, amount: .dollars(5_000), payee: "Acme Payroll")
        }
        let paycheck = try #require(detected(
            detect(deposits, asOf: date(2026, 5, 30))
        ))
        #expect(paycheck.cadence == .monthly)
        #expect(paycheck.nextDate == date(2026, 5, 31))
        let events = paycheck.scheduledSummaries(
            asOf: date(2026, 5, 30), horizonDays: 35, calendar: utc
        )
        #expect(events.map(\.nextDate) == [date(2026, 5, 31), date(2026, 6, 30)])
    }

    @Test("A raise is adopted once two consecutive deposits confirm it")
    func confirmedRaiseIsAdopted() throws {
        let amounts: [Money] = [
            .dollars(4_000), .dollars(4_000), .dollars(4_000),
            .dollars(4_000), .dollars(4_400), .dollars(4_400)
        ]
        let paycheck = try #require(detected(detect(
            biweekly(from: date(2026, 2, 6), count: 6) { amounts[$0] },
            asOf: date(2026, 4, 26)
        )))
        #expect(paycheck.nextAmount == .dollars(4_400))
    }

    @Test("A single lower deposit is adopted immediately")
    func lowerSingletonAdopts() throws {
        // Underestimating income is the safe direction — one reduced
        // deposit (garnishment, unpaid leave) lowers the forecast now.
        let amounts: [Money] = [
            .dollars(4_400), .dollars(4_400), .dollars(4_400),
            .dollars(4_400), .dollars(4_400), .dollars(3_000)
        ]
        let paycheck = try #require(detected(detect(
            biweekly(from: date(2026, 2, 6), count: 6) { amounts[$0] },
            asOf: date(2026, 4, 26)
        )))
        #expect(paycheck.nextAmount == .dollars(3_000))
    }

    @Test("Semimonthly paydays keep their detected days of month")
    func semimonthlyDetection() throws {
        var deposits: [TransactionSummary] = []
        for month in 1...4 {
            deposits.append(deposit(
                date: date(2026, month, 15), amount: .dollars(3_000),
                payee: "Acme Payroll"
            ))
            deposits.append(deposit(
                date: utc.date(
                    byAdding: DateComponents(month: 1, day: -1),
                    to: date(2026, month, 1)
                )!,
                amount: .dollars(3_000),
                payee: "Acme Payroll"
            ))
        }
        let paycheck = try #require(detected(
            detect(deposits, asOf: date(2026, 5, 3))
        ))
        #expect(paycheck.cadence == .semimonthly)
        #expect(paycheck.pattern.daysOfMonth == [15, 31])
        #expect(paycheck.nextDate == date(2026, 5, 15))
        // Exact dated events: paired days clamp to month ends, no drift.
        let events = paycheck.scheduledSummaries(
            asOf: date(2026, 5, 3), horizonDays: 60, calendar: utc
        )
        #expect(events.map(\.nextDate) == [
            date(2026, 5, 15), date(2026, 5, 31),
            date(2026, 6, 15), date(2026, 6, 30)
        ])
        #expect(events.allSatisfy { $0.frequency == .never })
    }

    @Test("Largest qualified payer wins over a small frequent one")
    func primaryPayerSelection() throws {
        let salary = biweekly(from: date(2026, 2, 6), count: 8)
        let side = (0..<10).map { step in
            deposit(
                date: utc.date(
                    byAdding: .day, value: step * 7, to: date(2026, 2, 2)
                )!,
                amount: .dollars(100),
                payee: "Side Gig"
            )
        }
        let paycheck = try #require(detected(
            detect(salary + side, asOf: date(2026, 5, 24))
        ))
        #expect(paycheck.displayName == "Acme Payroll")
    }

    @Test("Same-day double deposits merge into one paycheck")
    func sameDayMerge() throws {
        var deposits = biweekly(from: date(2026, 3, 6), count: 5)
        deposits.append(deposit(
            date: date(2026, 3, 6), amount: .dollars(500),
            payee: "Acme Payroll"
        ))
        let paycheck = try #require(detected(
            detect(deposits, asOf: date(2026, 5, 10))
        ))
        #expect(paycheck.confirmedDepositCount == 5)
        #expect(paycheck.cadence == .biweekly)
    }

    @Test("Next amount uses the current phase, not a one-off bonus")
    func amountUsesCurrentPhase() throws {
        // Post-step-up run of 4400 with a single 9000 bonus earlier in the
        // year — the bonus must not leak into the projection.
        let amounts: [Money] = [
            .dollars(4_000), .dollars(9_000), .dollars(4_000),
            .dollars(4_400), .dollars(4_400), .dollars(4_400), .dollars(4_400)
        ]
        let paycheck = try #require(detected(detect(
            biweekly(from: date(2026, 2, 6), count: 7) { amounts[$0] },
            asOf: date(2026, 5, 10)
        )))
        #expect(paycheck.nextAmount == .dollars(4_400))
        let events = paycheck.scheduledSummaries(
            asOf: date(2026, 5, 10), horizonDays: 45, calendar: utc
        )
        #expect(!events.isEmpty)
        #expect(events.allSatisfy { $0.amount == .dollars(4_400) })
    }

    @Test("Unapproved and non-income deposits never count")
    func filtering() {
        let pending = (0..<6).map { step in
            deposit(
                date: utc.date(
                    byAdding: .day, value: step * 14, to: date(2026, 2, 6)
                )!,
                amount: .dollars(4_000),
                payee: "Acme Payroll",
                approved: false
            )
        }
        #expect(detect(pending, asOf: date(2026, 5, 10)) == .noConfirmedIncome)
    }

    @Test("Dated events cover the horizon with positive one-off inflows")
    func scheduledSummariesShape() throws {
        let paycheck = try #require(detected(detect(
            biweekly(from: date(2026, 3, 6), count: 8),
            asOf: date(2026, 6, 20)
        )))
        let events = paycheck.scheduledSummaries(
            asOf: date(2026, 6, 20), horizonDays: 30, calendar: utc
        )
        #expect(events.map(\.nextDate) == [date(2026, 6, 26), date(2026, 7, 10)])
        #expect(events.map(\.id) == [
            "detected-paycheck:name:acme payroll:2026-06-26:checking",
            "detected-paycheck:name:acme payroll:2026-07-10:checking"
        ])
        for event in events {
            #expect(event.frequency == .never)
            #expect(event.accountId == "checking")
            #expect(event.amount == .dollars(4_000))
            #expect(event.transferAccountId == nil)
        }
    }

    @Test("Manual recurring income for the same payer overrides detection")
    func manualOverride() throws {
        let paycheck = try #require(detected(detect(
            biweekly(from: date(2026, 3, 6), count: 8),
            asOf: date(2026, 6, 20)
        )))
        let samePayer = RecurringExpectation(
            id: "manual-1", accountId: "checking",
            payeeName: "ACME payroll", treatment: .income,
            cadence: .biweekly, nextOccurrence: date(2026, 6, 26),
            amount: .dollars(4_100)
        )
        let otherPayer = RecurringExpectation(
            id: "manual-2", accountId: "checking",
            payeeName: "Rental Income", treatment: .income,
            cadence: .monthly, nextOccurrence: date(2026, 7, 1),
            amount: .dollars(1_500)
        )
        let bill = RecurringExpectation(
            id: "manual-3", accountId: "checking",
            payeeName: "Acme Payroll", treatment: .ordinarySpending,
            cadence: .monthly, nextOccurrence: date(2026, 7, 1),
            amount: .dollars(-80)
        )
        #expect(IncomeAnalyzer.manualIncomeOverride(
            for: paycheck, expectations: [otherPayer, bill, samePayer]
        )?.id == "manual-1")
        #expect(IncomeAnalyzer.manualIncomeOverride(
            for: paycheck, expectations: [otherPayer, bill]
        ) == nil)
    }

    @Test("Direct-deposit account switch retires the old account's portion")
    func accountSwitchRetiresStalePortion() throws {
        // The real-data bug this reproduces: pay went to "old" through
        // January (final partial deposit $576.06), then moved entirely to
        // "new". The payer stays fresh, so without a per-portion freshness
        // rule the old account keeps projecting $576.06 forever.
        var transactions = biweekly(
            from: date(2025, 11, 7), count: 6, accountId: "old",
            amount: { _ in .dollars(8_000) }
        )
        // Transition payday: split across both accounts.
        transactions.append(deposit(
            date: date(2026, 1, 30), amount: .dollars(576),
            payee: "Acme Payroll", accountId: "old"
        ))
        transactions.append(deposit(
            date: date(2026, 1, 30), amount: .dollars(5_184),
            payee: "Acme Payroll", accountId: "new"
        ))
        // Pay continues into the new account only.
        transactions += biweekly(
            from: date(2026, 2, 13), count: 12, accountId: "new",
            amount: { _ in .dollars(8_300) }
        )

        let paycheck = try #require(detected(detect(
            transactions,
            selected: ["old", "new"],
            asOf: date(2026, 8, 7)
        )))
        // Only the live account projects; the stale portion is retired even
        // though its series is recent enough for the 15-month window and
        // has well over two paydays.
        #expect(paycheck.portions.map(\.accountId) == ["new"])

        // Immediately after the switch (one missed payday on the old
        // account) the portion survives — one miss is review lag, matching
        // the payer-level tolerance.
        let earlyPaycheck = try #require(detected(detect(
            transactions,
            selected: ["old", "new"],
            asOf: date(2026, 2, 20)
        )))
        #expect(Set(earlyPaycheck.portions.map(\.accountId))
            == ["old", "new"])
    }
}
