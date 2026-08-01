import Testing
import Foundation
@testable import Money
@testable import Models
@testable import Projections

@Suite("Upcoming card payments")
struct UpcomingCardPaymentsTests {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        let c = utc
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

    @Test func returnsEmptyWhenPaymentDueDayUnset() {
        let f = CCPaymentForecaster(calendar: utc)
        let visa = card(balance: Money.dollars(-500))
        let settings = CardStatementSettings(
            accountId: "card-1",
            statementCycleDay: 15,
            paymentDueDay: 0,
            paymentAccountId: "checking-1"
        )
        let payments = f.upcomingPayments(
            card: visa,
            settings: settings,
            scheduled: [],
            asOf: date(2026, 3, 5),
            horizonDays: 60
        )
        #expect(payments.isEmpty)
    }

    @Test func imminentDueAfterRecentClosePullsApproximateBalance() {
        // Close = 15th, today = 20th (5 days post-close), due = 11th of next month.
        // No post-close txns yet → close-date balance == current owed.
        let f = CCPaymentForecaster(calendar: utc)
        let visa = card(balance: Money.dollars(-800))
        let settings = CardStatementSettings(
            accountId: "card-1",
            statementCycleDay: 15,
            paymentDueDay: 11,
            paymentAccountId: "checking-1"
        )
        let payments = f.upcomingPayments(
            card: visa,
            settings: settings,
            scheduled: [],
            asOf: date(2026, 3, 20),
            horizonDays: 30
        )
        #expect(payments.count == 1)
        let first = payments[0]
        #expect(first.amount == Money.dollars(800))
        #expect(first.basis == .closedStatementEstimate)
        let comps = utc.dateComponents([.year, .month, .day], from: first.dueDate)
        #expect(comps.year == 2026 && comps.month == 4 && comps.day == 11)
    }

    @Test func postCloseChargesAreUndoneWhenApproximating() {
        // Close = 15th, today = 20th. $200 of new charges since close.
        // Current owed = $1000; close-date balance should be $800.
        let f = CCPaymentForecaster(calendar: utc)
        let visa = card(balance: Money.dollars(-1_000))
        let settings = CardStatementSettings(
            accountId: "card-1",
            statementCycleDay: 15,
            paymentDueDay: 11,
            paymentAccountId: "checking-1"
        )
        let postCloseCharge = TransactionSummary(
            id: "t1", accountId: "card-1", date: date(2026, 3, 18),
            amount: Money.dollars(-200), cleared: true, approved: true,
            payeeName: nil, categoryId: nil, categoryName: nil,
            transferAccountId: nil, memo: nil, deleted: false
        )
        let payments = f.upcomingPayments(
            card: visa,
            settings: settings,
            scheduled: [],
            historicalTransactions: [postCloseCharge],
            asOf: date(2026, 3, 20),
            horizonDays: 30
        )
        #expect(payments.count == 1)
        #expect(payments[0].amount == Money.dollars(800))
        #expect(payments[0].basis == .closedStatementEstimate)
    }

    @Test func postClosePaymentReducesRemainingStatementAutopay() {
        let f = CCPaymentForecaster(calendar: utc)
        let ihg = card(balance: Money(milliunits: -59_990))
        let settings = CardStatementSettings(
            accountId: "card-1",
            statementCycleDay: 1,
            paymentDueDay: 8,
            paymentAccountId: "checking-1"
        )
        let partialPayment = TransactionSummary(
            id: "partial-payment",
            accountId: "card-1",
            date: date(2026, 7, 9),
            amount: Money(milliunits: 105_200),
            cleared: true,
            approved: true,
            payeeName: "Payment",
            categoryId: nil,
            categoryName: nil,
            transferAccountId: "checking-1",
            memo: nil,
            deleted: false
        )

        let payments = f.upcomingPayments(
            card: ihg,
            settings: settings,
            scheduled: [],
            historicalTransactions: [partialPayment],
            spendAccountIds: ["card-1", "checking-1"],
            asOf: date(2026, 7, 30),
            horizonDays: 30
        )

        #expect(payments.count == 1)
        #expect(payments[0].amount == Money(milliunits: 59_990))
        #expect(payments[0].basis == .closedStatementEstimate)
    }

    @Test func nextCloseAndDuePickedUpInsideHorizon() {
        // Today = 5th, close = 15th (10 days away), due = 11th of next month.
        // Current owed $500, no scheduled or post-close charges.
        let f = CCPaymentForecaster(calendar: utc)
        let visa = card(balance: Money.dollars(-500))
        let settings = CardStatementSettings(
            accountId: "card-1",
            statementCycleDay: 15,
            paymentDueDay: 11,
            paymentAccountId: "checking-1"
        )
        let payments = f.upcomingPayments(
            card: visa,
            settings: settings,
            scheduled: [],
            asOf: date(2026, 3, 5),
            horizonDays: 60
        )
        // Should have just the next close (since "previous close" was Feb 15 with
        // a due of March 11 — but today is March 5, so that one's still upcoming).
        #expect(payments.count >= 1)
        // First payment should be the Feb-15 close with due 2026-03-11.
        let first = payments[0]
        let dueComps = utc.dateComponents([.year, .month, .day], from: first.dueDate)
        #expect(dueComps.year == 2026 && dueComps.month == 3 && dueComps.day == 11)
        // Second payment is the March-15 close with due 2026-04-11.
        if payments.count >= 2 {
            let second = payments[1]
            let comps = utc.dateComponents([.year, .month, .day], from: second.dueDate)
            #expect(comps.year == 2026 && comps.month == 4 && comps.day == 11)
            #expect(second.basis == .futureScheduledOnly)
        }
    }

    @Test func upcomingPaymentsIgnoresVariableSpendHistory() {
        // Even with a busy 60-day history of charges, upcomingPayments
        // projects scheduled-only — daily-average extrapolation is off
        // because lumpy real-world spending (furniture, tax bills) makes
        // the average misleading. With no scheduled txns in the window,
        // projection == current owed.
        let f = CCPaymentForecaster(calendar: utc)
        let visa = card(balance: Money.dollars(-1_260))
        let settings = CardStatementSettings(
            accountId: "card-1",
            statementCycleDay: 21,
            paymentDueDay: 5,
            paymentAccountId: "checking-1"
        )

        var history: [TransactionSummary] = []
        var day = date(2026, 5, 1)
        var counter = 0
        while day <= date(2026, 6, 11) {
            history.append(TransactionSummary(
                id: "c-\(counter)", accountId: "card-1", date: day,
                amount: Money.dollars(-30), cleared: true, approved: true,
                payeeName: nil, categoryName: nil, memo: nil, deleted: false
            ))
            day = utc.date(byAdding: .day, value: 1, to: day)!
            counter += 1
        }

        let payments = f.upcomingPayments(
            card: visa,
            settings: settings,
            scheduled: [],
            historicalTransactions: history,
            spendAccountIds: [visa.id, "checking-1"],
            asOf: date(2026, 6, 12),
            horizonDays: 60
        )
        let futureRow = payments.first(where: { $0.basis == .futureScheduledOnly })
        #expect(futureRow != nil)
        // Daily-average extrapolation would add ~$30 × 9 days = $270 over
        // owed. We expect it disabled, so projection stays at exactly owed.
        #expect(futureRow?.amount == Money.dollars(1_260))
    }

    @Test func scheduledTransferInsideCloseWindowIsSkipped() {
        // Today is Jun 12, close is Jun 21. A scheduled monthly autopay
        // transfer FROM checking with an occurrence on Jun 15 would
        // (without filtering) subtract from the projection. With internal
        // accounts passed, it's skipped and projection stays at owed.
        let f = CCPaymentForecaster(calendar: utc)
        let visa = card(balance: Money.dollars(-1_000))
        let checkingId = "checking-1"
        let settings = CardStatementSettings(
            accountId: "card-1",
            statementCycleDay: 21,
            paymentDueDay: 5,
            paymentAccountId: checkingId
        )
        let scheduled = ScheduledTransactionSummary(
            id: "sched-autopay", accountId: "card-1", nextDate: date(2026, 6, 15),
            frequency: .monthly, amount: Money.dollars(500),
            transferAccountId: checkingId
        )
        let withFilter = f.upcomingPayments(
            card: visa,
            settings: settings,
            scheduled: [scheduled],
            historicalTransactions: [],
            spendAccountIds: [visa.id, checkingId],
            asOf: date(2026, 6, 12),
            horizonDays: 60
        )
        let futureRow = withFilter.first(where: { $0.basis == .futureScheduledOnly })
        #expect(futureRow != nil)
        #expect(futureRow?.amount == Money.dollars(1_000))
    }

    @Test func scheduledRealChargeAddsToProjection() {
        // A real (non-transfer) scheduled charge in the close window IS
        // added — that's the whole reason we still consult scheduled txns.
        let f = CCPaymentForecaster(calendar: utc)
        let visa = card(balance: Money.dollars(-1_000))
        let settings = CardStatementSettings(
            accountId: "card-1",
            statementCycleDay: 21,
            paymentDueDay: 5,
            paymentAccountId: "checking-1"
        )
        let scheduledCharge = ScheduledTransactionSummary(
            id: "sched-netflix", accountId: "card-1", nextDate: date(2026, 6, 15),
            frequency: .monthly, amount: Money.dollars(-25)
        )
        let payments = f.upcomingPayments(
            card: visa,
            settings: settings,
            scheduled: [scheduledCharge],
            historicalTransactions: [],
            spendAccountIds: [visa.id, "checking-1"],
            asOf: date(2026, 6, 12),
            horizonDays: 60
        )
        let futureRow = payments.first(where: { $0.basis == .futureScheduledOnly })
        #expect(futureRow != nil)
        // owed $1000 + scheduled charge $25 = $1025.
        #expect(futureRow?.amount == Money.dollars(1_025))
    }

    @Test func dueDaysShorterThanCloseDayHandled() {
        // Close on the 28th, due on the 5th. After a close on the 28th, the
        // matching due date is the 5th of the next month.
        let f = CCPaymentForecaster(calendar: utc)
        let visa = card(balance: Money.dollars(-300))
        let settings = CardStatementSettings(
            accountId: "card-1",
            statementCycleDay: 28,
            paymentDueDay: 5,
            paymentAccountId: "checking-1"
        )
        let payments = f.upcomingPayments(
            card: visa,
            settings: settings,
            scheduled: [],
            asOf: date(2026, 3, 1),
            horizonDays: 60
        )
        // First payment: Feb-28 close → due 2026-03-05.
        let first = payments[0]
        let comps = utc.dateComponents([.year, .month, .day], from: first.dueDate)
        #expect(comps.year == 2026 && comps.month == 3 && comps.day == 5)
    }

    @Test func adjacentCloseAndDueDaysDoNotCreateDuplicateAutopays() {
        let f = CCPaymentForecaster(calendar: utc)
        let appleCard = card(balance: Money.dollars(96.91))
        let settings = CardStatementSettings(
            accountId: "card-1",
            statementCycleDay: 30,
            paymentDueDay: 31,
            paymentAccountId: "checking-1"
        )
        let postCloseCharge = TransactionSummary(
            id: "post-close", accountId: "card-1", date: date(2026, 7, 10),
            amount: Money.dollars(-35.94), cleared: true, approved: true,
            payeeName: nil, categoryId: nil, categoryName: nil,
            transferAccountId: nil, memo: nil, deleted: false
        )

        let payments = f.upcomingPayments(
            card: appleCard,
            settings: settings,
            scheduled: [],
            historicalTransactions: [postCloseCharge],
            asOf: date(2026, 7, 19),
            horizonDays: 60
        )

        #expect(payments.count == 2)
        #expect(payments[0].dueDate == date(2026, 7, 31))
        #expect(payments[0].amount == Money.dollars(60.97))
        #expect(payments[1].dueDate == date(2026, 8, 31))
        #expect(payments[1].amount == Money.dollars(35.94))
        #expect(Set(payments.map(\.dueDate)).count == payments.count)
    }

    @Test func fullAutopayRemovesPriorStatementBeforeNextClose() {
        // Current owed includes the $800 closed statement plus $200 of new-cycle
        // charges. The $800 due before the next close must not carry forward.
        let f = CCPaymentForecaster(calendar: utc)
        let visa = card(balance: Money.dollars(-1_000))
        let settings = CardStatementSettings(
            accountId: "card-1", statementCycleDay: 15,
            paymentDueDay: 11, paymentAccountId: "checking-1"
        )
        let postCloseCharge = TransactionSummary(
            id: "new-cycle", accountId: "card-1", date: date(2026, 3, 18),
            amount: Money.dollars(-200), cleared: true, approved: true,
            payeeName: nil, categoryName: nil, memo: nil, deleted: false
        )
        let payments = f.upcomingPayments(
            card: visa, settings: settings, scheduled: [],
            historicalTransactions: [postCloseCharge],
            asOf: date(2026, 3, 20), horizonDays: 60
        )
        #expect(payments.count == 2)
        #expect(payments[0].amount == Money.dollars(800))
        #expect(payments[1].amount == Money.dollars(200))
        #expect(payments[1].priorStatementPaymentsApplied == Money.dollars(800))
    }

    @Test func longHorizonProducesMultipleCyclesWithStableIds() {
        let f = CCPaymentForecaster(calendar: utc)
        let visa = card(balance: Money.dollars(-300))
        let settings = CardStatementSettings(
            accountId: "card-1", statementCycleDay: 10,
            paymentDueDay: 5, paymentAccountId: "checking-1"
        )
        let monthlyCharge = ScheduledTransactionSummary(
            id: "monthly", accountId: "card-1", firstDate: date(2026, 1, 2),
            nextDate: date(2026, 1, 2), frequency: .monthly,
            amount: Money.dollars(-100)
        )
        let first = f.upcomingPayments(
            card: visa, settings: settings, scheduled: [monthlyCharge],
            asOf: date(2026, 1, 1), horizonDays: 180
        )
        let second = f.upcomingPayments(
            card: visa, settings: settings, scheduled: [monthlyCharge],
            asOf: date(2026, 1, 1), horizonDays: 180
        )
        #expect(first.count >= 2)
        #expect(first.map(\.id) == second.map(\.id))
        #expect(first.allSatisfy { $0.paymentAccountId == "checking-1" })
    }
}
