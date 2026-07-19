import Foundation
import Money
import Models

public enum CardPaymentEstimateBasis: String, Sendable, Hashable, Codable {
    case closedStatementEstimate
    case futureScheduledOnly
}

/// A projected full-statement autopay debit and the inputs used to derive it.
public struct UpcomingCardPayment: Sendable, Hashable, Identifiable {
    public var id: String {
        "\(cardAccountId):\(Int(closeDate.timeIntervalSince1970)):payment"
    }
    public let cardAccountId: String
    public let paymentAccountId: String
    public let cardName: String
    public let closeDate: Date
    public let dueDate: Date
    public let amount: Money
    public let basis: CardPaymentEstimateBasis
    public let startingBalanceOwed: Money
    public let scheduledCharges: Money
    public let scheduledCredits: Money
    public let priorStatementPaymentsApplied: Money

    public init(
        cardAccountId: String,
        paymentAccountId: String,
        cardName: String,
        closeDate: Date,
        dueDate: Date,
        amount: Money,
        basis: CardPaymentEstimateBasis,
        startingBalanceOwed: Money = .zero,
        scheduledCharges: Money = .zero,
        scheduledCredits: Money = .zero,
        priorStatementPaymentsApplied: Money = .zero
    ) {
        self.cardAccountId = cardAccountId
        self.paymentAccountId = paymentAccountId
        self.cardName = cardName
        self.closeDate = closeDate
        self.dueDate = dueDate
        self.amount = amount
        self.basis = basis
        self.startingBalanceOwed = startingBalanceOwed
        self.scheduledCharges = scheduledCharges
        self.scheduledCredits = scheduledCredits
        self.priorStatementPaymentsApplied = priorStatementPaymentsApplied
    }
}

extension CCPaymentForecaster {
    /// Simulates full-statement autopays through the requested horizon. Future
    /// variable purchases are intentionally excluded; the cash projector
    /// reserves for ordinary spending separately on its expected curve.
    public func upcomingPayments(
        card: AccountSnapshot,
        settings: CardStatementSettings,
        scheduled: [ScheduledTransactionSummary],
        historicalTransactions: [TransactionSummary] = [],
        spendAccountIds: Set<String> = [],
        asOf today: Date,
        horizonDays: Int = 60
    ) -> [UpcomingCardPayment] {
        precondition(card.kind.isCreditCardLike, "upcomingPayments requires a credit-card-like account")
        guard settings.paymentDueDay >= 1,
              let paymentAccountId = settings.paymentAccountId,
              !paymentAccountId.isEmpty else { return [] }

        let start = calendar.startOfDay(for: today)
        guard let end = calendar.date(byAdding: .day, value: horizonDays, to: start) else { return [] }
        let cardSchedules = scheduled.filter { item in
            guard !item.deleted, item.accountId == card.id else { return false }
            if let transfer = item.transferAccountId, spendAccountIds.contains(transfer) { return false }
            return true
        }

        let lastClose = previousCloseDate(asOf: start, cycleDay: settings.statementCycleDay)
        let lastDue = paymentDueDate(after: lastClose, dueDay: settings.paymentDueDay)
        let lastStatement = balanceAtPastClose(
            currentOwed: card.balance.absolute,
            cardAccountId: card.id,
            closeDate: lastClose,
            today: start,
            history: historicalTransactions
        )

        var payments: [UpcomingCardPayment] = []
        var pending: [(date: Date, amount: Money)] = []
        if lastDue > start {
            pending.append((lastDue, lastStatement))
            if lastDue <= end, !lastStatement.isZero {
                payments.append(UpcomingCardPayment(
                    cardAccountId: card.id,
                    paymentAccountId: paymentAccountId,
                    cardName: card.name,
                    closeDate: lastClose,
                    dueDate: lastDue,
                    amount: lastStatement,
                    basis: .closedStatementEstimate,
                    startingBalanceOwed: card.balance.absolute
                ))
            }
        }

        var owed = card.balance.absolute
        var periodStart = start
        var close = nextCloseDate(asOf: start, cycleDay: settings.statementCycleDay)

        while close <= end {
            let startingOwed = owed
            var charges = Money.zero
            var credits = Money.zero
            var priorPayments = Money.zero

            for payment in pending where payment.date > periodStart && payment.date <= close {
                owed -= payment.amount
                priorPayments += payment.amount
            }
            pending.removeAll { $0.date <= close }

            for item in cardSchedules {
                for occurrence in item.occurrences(from: dayAfter(periodStart), through: close, calendar: calendar) {
                    _ = occurrence
                    if item.amount.isNegative {
                        charges += item.amount.absolute
                        owed += item.amount.absolute
                    } else if !item.amount.isZero {
                        credits += item.amount
                        owed -= item.amount
                    }
                }
            }
            if owed < .zero { owed = .zero }

            let due = paymentDueDate(after: close, dueDay: settings.paymentDueDay)
            // A prior statement can be due shortly after the next statement
            // closes. It is still paid before this new statement is due, so it
            // must not be included in both full-statement autopays.
            let paymentsBeforeDue = pending
                .filter { $0.date > close && $0.date <= due }
                .map(\.amount)
                .sum()
            let adjustedStatement = owed - paymentsBeforeDue
            let statementAmount = max(adjustedStatement, .zero)
            pending.append((due, statementAmount))
            if due <= end, !statementAmount.isZero {
                payments.append(UpcomingCardPayment(
                    cardAccountId: card.id,
                    paymentAccountId: paymentAccountId,
                    cardName: card.name,
                    closeDate: close,
                    dueDate: due,
                    amount: statementAmount,
                    basis: .futureScheduledOnly,
                    startingBalanceOwed: startingOwed,
                    scheduledCharges: charges,
                    scheduledCredits: credits,
                    priorStatementPaymentsApplied: priorPayments + paymentsBeforeDue
                ))
            }

            periodStart = close
            guard let nextReference = calendar.date(byAdding: .day, value: 1, to: close) else { break }
            close = nextCloseDate(asOf: nextReference, cycleDay: settings.statementCycleDay)
        }

        return payments.sorted { lhs, rhs in
            lhs.dueDate == rhs.dueDate ? lhs.cardName < rhs.cardName : lhs.dueDate < rhs.dueDate
        }
    }

    private func dayAfter(_ date: Date) -> Date {
        calendar.date(byAdding: .day, value: 1, to: date) ?? date
    }

    private func balanceAtPastClose(
        currentOwed: Money,
        cardAccountId: String,
        closeDate: Date,
        today: Date,
        history: [TransactionSummary]
    ) -> Money {
        guard closeDate < today else { return currentOwed }
        let delta = history.lazy
            .filter { !$0.deleted && $0.accountId == cardAccountId && $0.date > closeDate && $0.date <= today }
            .reduce(Int64(0)) { $0 + $1.amount.milliunits }
        let result = Money(milliunits: currentOwed.milliunits + delta)
        return result < .zero ? .zero : result
    }

    private func nextOccurrence(ofDay day: Int, strictlyAfter reference: Date) -> Date {
        let target = max(1, min(31, day))
        let referenceStart = calendar.startOfDay(for: reference)
        let comps = calendar.dateComponents([.year, .month], from: referenceStart)
        let thisMonth = occurrence(
            year: comps.year ?? 1970,
            month: comps.month ?? 1,
            requestedDay: target
        ) ?? referenceStart
        if thisMonth > referenceStart { return thisMonth }
        let nextRef = calendar.date(byAdding: .month, value: 1, to: thisMonth) ?? referenceStart
        let nextComps = calendar.dateComponents([.year, .month], from: nextRef)
        return occurrence(
            year: nextComps.year ?? 1970,
            month: nextComps.month ?? 1,
            requestedDay: target
        ) ?? nextRef
    }

    /// Day-of-month settings do not encode which month owns the due date.
    /// Treat implausibly short gaps as the following month's due date; card
    /// statements normally provide weeks, not one or two days, to pay.
    private func paymentDueDate(after closeDate: Date, dueDay: Int) -> Date {
        let firstCandidate = nextOccurrence(ofDay: dueDay, strictlyAfter: closeDate)
        let leadDays = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: closeDate),
            to: calendar.startOfDay(for: firstCandidate)
        ).day ?? 0
        let actualCloseDay = calendar.component(.day, from: closeDate)
        let requestedDueDay = max(1, min(31, dueDay))
        guard requestedDueDay > actualCloseDay, leadDays < 14 else {
            return firstCandidate
        }
        return nextOccurrence(ofDay: dueDay, strictlyAfter: firstCandidate)
    }

    private func occurrence(year: Int, month: Int, requestedDay: Int) -> Date? {
        guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let range = calendar.range(of: .day, in: .month, for: first) else { return nil }
        return calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: min(requestedDay, range.count)
        ))
    }
}
