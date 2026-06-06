import Testing
import Foundation
@testable import Money
@testable import Models
@testable import Projections

@Suite("CC payment forecaster")
struct CCPaymentForecasterTests {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = utc
        c.timeZone = TimeZone(identifier: "UTC")!
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        return c.date(from: comps)!
    }

    private func card(balance: Money) -> AccountSnapshot {
        AccountSnapshot(
            id: "card-1", name: "Visa", kind: .creditCard,
            balance: balance, clearedBalance: balance, unclearedBalance: .zero,
            onBudget: true, closed: false, deleted: false
        )
    }

    @Test func nextCloseDateWithinSameMonth() {
        let f = CCPaymentForecaster(calendar: utc)
        let close = f.nextCloseDate(asOf: date(2026, 3, 5), cycleDay: 15)
        #expect(utc.dateComponents([.year, .month, .day], from: close).day == 15)
        #expect(utc.dateComponents([.year, .month, .day], from: close).month == 3)
    }

    @Test func nextCloseDateRollsIntoNextMonth() {
        let f = CCPaymentForecaster(calendar: utc)
        let close = f.nextCloseDate(asOf: date(2026, 3, 20), cycleDay: 15)
        let comps = utc.dateComponents([.year, .month, .day], from: close)
        #expect(comps.month == 4 && comps.day == 15)
    }

    @Test func projectionWithoutScheduled() {
        let f = CCPaymentForecaster(calendar: utc)
        let visa = card(balance: Money.dollars(-1_000))
        let settings = CardStatementSettings(accountId: "card-1", statementCycleDay: 15)
        let p = f.forecast(card: visa, settings: settings, scheduled: [], asOf: date(2026, 3, 5))
        #expect(p.currentBalanceOwed == Money.dollars(1_000))
        #expect(p.projectedStatementBalance == Money.dollars(1_000))
        // 2% × $1000 = $20, but floor is $25.
        #expect(p.minimumPayment == Money.dollars(25))
    }

    @Test func projectionAppliesUpcomingChargesAndPayments() {
        let f = CCPaymentForecaster(calendar: utc)
        let visa = card(balance: Money.dollars(-1_000))
        let settings = CardStatementSettings(accountId: "card-1", statementCycleDay: 15)
        let charge = ScheduledTransactionSummary(
            id: "sched-1", accountId: "card-1", nextDate: date(2026, 3, 8),
            frequency: .never, amount: Money.dollars(-200)
        )
        let payment = ScheduledTransactionSummary(
            id: "sched-2", accountId: "card-1", nextDate: date(2026, 3, 10),
            frequency: .never, amount: Money.dollars(300)
        )
        let p = f.forecast(card: visa, settings: settings, scheduled: [charge, payment], asOf: date(2026, 3, 5))
        // owed=1000 + scheduled charges 200 − scheduled payments 300 = 900
        #expect(p.scheduledChargesBeforeClose == Money.dollars(200))
        #expect(p.scheduledPaymentsBeforeClose == Money.dollars(300))
        #expect(p.projectedStatementBalance == Money.dollars(900))
    }

    @Test func zeroBalanceProducesZeroMinimum() {
        let f = CCPaymentForecaster(calendar: utc)
        let visa = card(balance: .zero)
        let settings = CardStatementSettings(accountId: "card-1", statementCycleDay: 15)
        let p = f.forecast(card: visa, settings: settings, scheduled: [], asOf: date(2026, 3, 5))
        #expect(p.projectedStatementBalance == .zero)
        #expect(p.minimumPayment == .zero)
    }

    @Test func payoffScenariosCoverFullAndMinimumAndCustom() {
        let f = CCPaymentForecaster(calendar: utc)
        let visa = card(balance: Money.dollars(-5_000))
        let settings = CardStatementSettings(accountId: "card-1", statementCycleDay: 15)
        let projection = f.forecast(card: visa, settings: settings, scheduled: [], asOf: date(2026, 3, 5))
        let scenarios = f.payoffScenarios(for: projection, customAmount: Money.dollars(1_000))
        #expect(scenarios.count == 3)
        #expect(scenarios.first { $0.mode == .full }?.carryover == .zero)
        let custom = scenarios.first { $0.mode == .custom }!
        #expect(custom.paymentAmount == Money.dollars(1_000))
        #expect(custom.carryover == Money.dollars(4_000))
    }
}
