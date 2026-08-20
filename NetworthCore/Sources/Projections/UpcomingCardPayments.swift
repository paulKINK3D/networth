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

/// A user-confirmed payment for one statement cycle. Confirmations are
/// authoritative for cash timing but never alter provider data or later
/// statement estimates.
public struct CardPaymentConfirmation: Sendable, Hashable, Identifiable {
    public let id: String
    public let cardAccountId: String
    public let statementCloseDate: Date
    public let amount: Money
    public let paymentDate: Date
    public let updatedAt: Date

    public init(
        id: String,
        cardAccountId: String,
        statementCloseDate: Date,
        amount: Money,
        paymentDate: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.cardAccountId = cardAccountId
        self.statementCloseDate = statementCloseDate
        self.amount = amount
        self.paymentDate = paymentDate
        self.updatedAt = updatedAt
    }
}

public struct ResolvedUpcomingCardPayment: Sendable, Hashable, Identifiable {
    public let estimate: UpcomingCardPayment
    public let confirmation: CardPaymentConfirmation?

    public var id: String { estimate.id }
    public var amount: Money { confirmation?.amount ?? estimate.amount }
    public var paymentDate: Date {
        confirmation?.paymentDate ?? estimate.dueDate
    }
    public var isConfirmed: Bool { confirmation != nil }

    public init(
        estimate: UpcomingCardPayment,
        confirmation: CardPaymentConfirmation?
    ) {
        self.estimate = estimate
        self.confirmation = confirmation
    }

    public var projectedPayment: UpcomingCardPayment {
        UpcomingCardPayment(
            cardAccountId: estimate.cardAccountId,
            paymentAccountId: estimate.paymentAccountId,
            cardName: estimate.cardName,
            closeDate: estimate.closeDate,
            dueDate: paymentDate,
            amount: amount,
            basis: estimate.basis,
            startingBalanceOwed: estimate.startingBalanceOwed,
            scheduledCharges: estimate.scheduledCharges,
            scheduledCredits: estimate.scheduledCredits,
            priorStatementPaymentsApplied:
                estimate.priorStatementPaymentsApplied
        )
    }
}

public struct CardPaymentConfirmationResolver: Sendable {
    private let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public func resolve(
        _ payment: UpcomingCardPayment,
        confirmations: [CardPaymentConfirmation]
    ) -> ResolvedUpcomingCardPayment {
        let confirmation = confirmations
            .filter {
                $0.cardAccountId == payment.cardAccountId
                    && $0.amount > .zero
                    && calendar.isDate(
                        $0.statementCloseDate,
                        inSameDayAs: payment.closeDate
                    )
            }
            .max {
                if $0.updatedAt != $1.updatedAt {
                    return $0.updatedAt < $1.updatedAt
                }
                return $0.id < $1.id
            }
        return ResolvedUpcomingCardPayment(
            estimate: payment,
            confirmation: confirmation
        )
    }
}

public enum CardPaymentActivityEffect: Sendable, Hashable {
    case nextStatement
    case reducesPayment
    case increasesPayment
    case currentBalanceOnly
}

public struct CardPaymentReconciliationActivity: Sendable, Hashable,
    Identifiable {
    public let transaction: TransactionSummary
    public let effect: CardPaymentActivityEffect

    public var id: String { transaction.id }

    public init(
        transaction: TransactionSummary,
        effect: CardPaymentActivityEffect
    ) {
        self.transaction = transaction
        self.effect = effect
    }
}

public struct CardPaymentReconciliation: Sendable, Hashable {
    public let activity: [CardPaymentReconciliationActivity]
    public let newPurchases: Money
    public let currentBalanceCredits: Money

    public init(
        activity: [CardPaymentReconciliationActivity],
        newPurchases: Money,
        currentBalanceCredits: Money
    ) {
        self.activity = activity
        self.newPurchases = newPurchases
        self.currentBalanceCredits = currentBalanceCredits
    }
}

extension CCPaymentForecaster {
    /// Activity after a closed statement explains why today's card balance
    /// differs from the remaining statement autopay. Purchases belong to the
    /// next statement, actual payments reduce the prior statement, and other
    /// credits affect only the current balance unless the issuer says otherwise.
    public func reconciliation(
        for payment: UpcomingCardPayment,
        transactions: [TransactionSummary],
        asOf today: Date
    ) -> CardPaymentReconciliation {
        let end = calendar.startOfDay(for: today)
        let transactions = transactions
            .filter {
                !$0.deleted
                    && $0.accountId == payment.cardAccountId
                    && $0.date > payment.closeDate
                    && $0.date <= end
            }
            .sorted {
                if $0.date != $1.date { return $0.date > $1.date }
                return $0.id < $1.id
            }
        let activity = transactions.map {
            CardPaymentReconciliationActivity(
                transaction: $0,
                effect: activityEffect(for: $0)
            )
        }
        let newPurchases = activity
            .filter { $0.effect == .nextStatement }
            .map { $0.transaction.amount.absolute }
            .sum()
        let currentBalanceCredits = activity
            .filter { $0.effect == .currentBalanceOnly }
            .map { $0.transaction.amount }
            .sum()
        return CardPaymentReconciliation(
            activity: activity,
            newPurchases: newPurchases,
            currentBalanceCredits: currentBalanceCredits
        )
    }

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
        let lastStatement = remainingBalanceForPastStatement(
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

    private func remainingBalanceForPastStatement(
        currentOwed: Money,
        cardAccountId: String,
        closeDate: Date,
        today: Date,
        history: [TransactionSummary]
    ) -> Money {
        guard closeDate < today else { return currentOwed }
        // Current owed already reflects every post-close transaction. Remove
        // newer purchases, preserve actual card payments, and add back other
        // credits that reduce today's balance without reducing the prior
        // statement's scheduled payment.
        let postCloseActivity = history.lazy
            .filter {
                !$0.deleted &&
                    $0.accountId == cardAccountId &&
                    $0.date > closeDate &&
                    $0.date <= today
            }
        let postCloseCharges = postCloseActivity
            .filter { activityEffect(for: $0) == .nextStatement }
            .reduce(Int64(0)) { $0 + $1.amount.absolute.milliunits }
        let currentBalanceCredits = postCloseActivity
            .filter { activityEffect(for: $0) == .currentBalanceOnly }
            .reduce(Int64(0)) { $0 + $1.amount.milliunits }
        let result = Money(
            milliunits: currentOwed.milliunits
                - postCloseCharges
                + currentBalanceCredits
        )
        return result < .zero ? .zero : result
    }

    private func activityEffect(
        for transaction: TransactionSummary
    ) -> CardPaymentActivityEffect {
        if transaction.forecastTreatment == .cardPayment {
            return transaction.amount > .zero
                ? .reducesPayment
                : .increasesPayment
        }
        if transaction.amount.isNegative { return .nextStatement }
        if transaction.transferAccountId != nil {
            return .reducesPayment
        }
        return .currentBalanceOnly
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
