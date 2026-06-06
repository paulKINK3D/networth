import Foundation
import Money
import Models

/// Computes a per-card statement projection from the current balance, the user's
/// statement-cycle settings, and the scheduled charges/payments YNAB knows about.
///
/// All math runs in milliunits. The forecaster takes a `Calendar` so tests pin
/// behavior to UTC; the production caller passes the user's current calendar.
public struct CCPaymentForecaster: Sendable {
    public let calendar: Calendar

    public init(calendar: Calendar = Calendar(identifier: .gregorian)) {
        self.calendar = calendar
    }

    public func forecast(
        card: AccountSnapshot,
        settings: CardStatementSettings,
        scheduled: [ScheduledTransactionSummary],
        historicalTransactions: [TransactionSummary] = [],
        excludedCategoryIds: Set<String> = [],
        outflowOnlyExcludedCategoryIds: Set<String> = [],
        spendAccountIds: Set<String> = [],
        lookbackDays: Int = 60,
        asOf today: Date
    ) -> StatementProjection {
        precondition(card.kind.isCreditCardLike, "CCPaymentForecaster requires a credit-card-like account")

        let lastClose = previousCloseDate(asOf: today, cycleDay: settings.statementCycleDay)
        let nextClose = nextCloseDate(asOf: today, cycleDay: settings.statementCycleDay)

        // YNAB reports CC balances as negatives (a liability). Normalize to a
        // positive "owed" amount for the rest of the calc.
        let owed = card.balance.absolute

        var chargesTotal = Money.zero
        var paymentsTotal = Money.zero

        for sched in scheduled where !sched.deleted && sched.accountId == card.id {
            let occurrences = sched.occurrences(from: max(today, lastClose), through: nextClose, calendar: calendar)
            for _ in occurrences {
                if sched.amount.isNegative {
                    // Outflow on a CC account == new charge that increases what is owed.
                    chargesTotal += sched.amount.absolute
                } else if !sched.amount.isZero {
                    // Inflow == a payment toward the card balance.
                    paymentsTotal += sched.amount
                }
            }
        }

        let dailyAverage = dailyAverageCharge(
            cardAccountId: card.id,
            historicalTransactions: historicalTransactions,
            excludedCategoryIds: excludedCategoryIds,
            outflowOnlyExcludedCategoryIds: outflowOnlyExcludedCategoryIds,
            spendAccountIds: spendAccountIds,
            lookbackDays: lookbackDays,
            asOf: today
        )
        let daysUntilClose = max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: today), to: nextClose).day ?? 0)
        let projectedVariableCharges = Money(milliunits: dailyAverage.milliunits * Int64(daysUntilClose))

        let projectedStatement = owed + chargesTotal + projectedVariableCharges - paymentsTotal
        let nonNegativeStatement = projectedStatement < .zero ? .zero : projectedStatement

        let percentBased = nonNegativeStatement.scaled(by: settings.minimumPaymentPercent)
        let minimum: Money = {
            if nonNegativeStatement.isZero { return .zero }
            return max(percentBased, settings.minimumPaymentFloor)
        }()

        return StatementProjection(
            cardAccountId: card.id,
            cardName: card.name,
            asOf: today,
            lastCloseDate: lastClose,
            nextCloseDate: nextClose,
            currentBalanceOwed: owed,
            scheduledChargesBeforeClose: chargesTotal,
            scheduledPaymentsBeforeClose: paymentsTotal,
            projectedVariableCharges: projectedVariableCharges,
            dailyAverageCharge: dailyAverage,
            projectedStatementBalance: nonNegativeStatement,
            minimumPayment: minimum
        )
    }

    /// Daily **net** charge on a single CC over the lookback window. Signed in
    /// the "owed-increase" convention: positive = net new charges (owed up),
    /// negative = net payments (owed down). Skips internal transfers (CC
    /// payments from checking, balance transfers between cards), deleted, and
    /// excluded categories. Categorized transfers to off-budget tracking
    /// accounts ARE counted (e.g. therapy on CC tracked off-budget).
    public func dailyAverageCharge(
        cardAccountId: String,
        historicalTransactions: [TransactionSummary],
        excludedCategoryIds: Set<String>,
        outflowOnlyExcludedCategoryIds: Set<String> = [],
        spendAccountIds: Set<String> = [],
        lookbackDays: Int,
        asOf today: Date
    ) -> Money {
        let lookback = max(1, lookbackDays)
        let startOfDay = calendar.startOfDay(for: today)
        guard let windowStart = calendar.date(byAdding: .day, value: -lookback, to: startOfDay) else {
            return .zero
        }
        let internalAccounts = spendAccountIds.isEmpty ? [cardAccountId] : spendAccountIds

        // Outflow-only exclusion: on a CC, "outflow" = a new charge (negative
        // amount). Hidden categories apply to charges but not to payments,
        // which keeps refund/credit-style inflows intact.
        func isExcluded(categoryId: String?, amountMU: Int64) -> Bool {
            guard let cid = categoryId else { return false }
            if excludedCategoryIds.contains(cid) { return true }
            if amountMU < 0 && outflowOnlyExcludedCategoryIds.contains(cid) { return true }
            return false
        }

        // Sum signed amounts on this CC. YNAB convention: negative = new charge,
        // positive = payment. We'll flip the final sign so positive = net charge.
        var signedTotalMU: Int64 = 0
        for txn in historicalTransactions where !txn.deleted && txn.accountId == cardAccountId {
            guard txn.date >= windowStart, txn.date < startOfDay else { continue }
            if txn.isSplit {
                for sub in txn.subtransactions where !sub.deleted {
                    if let xfer = sub.transferAccountId, internalAccounts.contains(xfer) { continue }
                    if isExcluded(categoryId: sub.categoryId, amountMU: sub.amount.milliunits) { continue }
                    signedTotalMU += sub.amount.milliunits
                }
            } else {
                if let xfer = txn.transferAccountId, internalAccounts.contains(xfer) { continue }
                if isExcluded(categoryId: txn.categoryId, amountMU: txn.amount.milliunits) { continue }
                signedTotalMU += txn.amount.milliunits
            }
        }
        let netOwedIncreaseMU = -signedTotalMU
        guard netOwedIncreaseMU != 0 else { return .zero }
        return Money(milliunits: netOwedIncreaseMU / Int64(lookback))
    }

    public func payoffScenarios(for projection: StatementProjection, customAmount: Money? = nil) -> [PayoffScenario] {
        var scenarios: [PayoffScenario] = []
        scenarios.append(PayoffScenario(
            mode: .full,
            paymentAmount: projection.projectedStatementBalance,
            carryover: .zero
        ))
        let minCarryover = projection.projectedStatementBalance - projection.minimumPayment
        scenarios.append(PayoffScenario(
            mode: .minimum,
            paymentAmount: projection.minimumPayment,
            carryover: minCarryover < .zero ? .zero : minCarryover
        ))
        if let custom = customAmount {
            let clamped = custom < .zero ? .zero : custom
            let carry = projection.projectedStatementBalance - clamped
            scenarios.append(PayoffScenario(
                mode: .custom,
                paymentAmount: clamped,
                carryover: carry < .zero ? .zero : carry
            ))
        }
        return scenarios
    }

    // MARK: - Cycle math

    /// The next statement-close date at-or-after `today`. Cycle days 29-31
    /// fall back to the last day of months that are too short.
    public func nextCloseDate(asOf today: Date, cycleDay: Int) -> Date {
        let requested = max(1, min(31, cycleDay))
        let startOfDay = calendar.startOfDay(for: today)
        let comps = calendar.dateComponents([.year, .month], from: startOfDay)
        let thisMonth = closeDate(year: comps.year ?? 1970,
                                  month: comps.month ?? 1,
                                  requestedDay: requested) ?? startOfDay
        if thisMonth >= startOfDay {
            return thisMonth
        }
        let nextRef = calendar.date(byAdding: .month, value: 1, to: thisMonth) ?? startOfDay
        let nextComps = calendar.dateComponents([.year, .month], from: nextRef)
        return closeDate(year: nextComps.year ?? 1970,
                         month: nextComps.month ?? 1,
                         requestedDay: requested) ?? nextRef
    }

    /// The most-recent statement-close date strictly before `today`. Cycle
    /// days 29-31 fall back to the last day of months that are too short.
    public func previousCloseDate(asOf today: Date, cycleDay: Int) -> Date {
        let requested = max(1, min(31, cycleDay))
        let startOfDay = calendar.startOfDay(for: today)
        let comps = calendar.dateComponents([.year, .month], from: startOfDay)
        let thisMonth = closeDate(year: comps.year ?? 1970,
                                  month: comps.month ?? 1,
                                  requestedDay: requested) ?? startOfDay
        if thisMonth < startOfDay {
            return thisMonth
        }
        let prevRef = calendar.date(byAdding: .month, value: -1, to: thisMonth) ?? startOfDay
        let prevComps = calendar.dateComponents([.year, .month], from: prevRef)
        return closeDate(year: prevComps.year ?? 1970,
                         month: prevComps.month ?? 1,
                         requestedDay: requested) ?? prevRef
    }

    private func closeDate(year: Int, month: Int, requestedDay: Int) -> Date? {
        var firstOfMonth = DateComponents()
        firstOfMonth.year = year
        firstOfMonth.month = month
        firstOfMonth.day = 1
        guard let firstDate = calendar.date(from: firstOfMonth),
              let range = calendar.range(of: .day, in: .month, for: firstDate) else {
            return nil
        }
        let actualDay = min(requestedDay, range.count)
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = actualDay
        return calendar.date(from: comps)
    }
}
