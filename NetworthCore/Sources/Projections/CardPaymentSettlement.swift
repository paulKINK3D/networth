import Foundation
import Money
import Models

/// A durable, user-visible resolution for one overdue statement payment.
/// A settlement retires the projected autopay for that cycle only; it never
/// alters provider data or the statement estimate itself. A nil transaction
/// id means the user marked the statement paid outside the tracked accounts.
public struct CardPaymentSettlement: Sendable, Hashable, Identifiable {
    public let id: String
    public let cardAccountId: String
    public let statementCloseDate: Date
    public let transactionId: String?
    public let updatedAt: Date

    public init(
        id: String,
        cardAccountId: String,
        statementCloseDate: Date,
        transactionId: String?,
        updatedAt: Date
    ) {
        self.id = id
        self.cardAccountId = cardAccountId
        self.statementCloseDate = statementCloseDate
        self.transactionId = transactionId
        self.updatedAt = updatedAt
    }
}

/// Decides which past-due projected card payments have actually left the
/// paying bank account. A payment past its due date stays in the cash
/// projection until it settles here — either through an explicit user
/// settlement or an auto-matched debit on the paying account. The card-side
/// payment credit is deliberately not a settlement signal: it often posts
/// before the bank debit, while the cash curve starts from the bank balance.
public struct CardPaymentSettlementMatcher: Sendable {
    private let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// Auto-match tolerance: interest or late credits can drift the actual
    /// debit a few dollars from the estimate without breaking the match.
    private static let minimumToleranceMilliunits: Int64 = 5_000

    public func settledPaymentIds(
        payments: [UpcomingCardPayment],
        transactions: [TransactionSummary],
        settlements: [CardPaymentSettlement],
        asOf today: Date
    ) -> Set<String> {
        let start = calendar.startOfDay(for: today)
        let due = payments.filter {
            calendar.startOfDay(for: $0.dueDate) <= start
        }
        guard !due.isEmpty else { return [] }

        var settled: Set<String> = []
        var unresolved: [UpcomingCardPayment] = []
        for payment in due {
            let hasSettlement = settlements.contains {
                $0.cardAccountId == payment.cardAccountId
                    && calendar.isDate(
                        $0.statementCloseDate,
                        inSameDayAs: payment.closeDate
                    )
            }
            if hasSettlement {
                settled.insert(payment.id)
            } else {
                unresolved.append(payment)
            }
        }

        // One debit settles at most one payment; closest amounts pair first
        // so two cards paid from one account cannot share a single debit.
        var pairs: [(paymentId: String, transactionId: String, distance: Int64)] = []
        for payment in unresolved {
            for transaction in transactions
            where isAutoMatch(transaction, for: payment, start: start) {
                pairs.append((
                    payment.id,
                    transaction.id,
                    abs(
                        transaction.amount.absolute.milliunits
                            - payment.amount.milliunits
                    )
                ))
            }
        }
        pairs.sort {
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            if $0.paymentId != $1.paymentId { return $0.paymentId < $1.paymentId }
            return $0.transactionId < $1.transactionId
        }
        var usedTransactionIds: Set<String> = []
        for pair in pairs {
            guard !settled.contains(pair.paymentId),
                  !usedTransactionIds.contains(pair.transactionId)
            else { continue }
            settled.insert(pair.paymentId)
            usedTransactionIds.insert(pair.transactionId)
        }
        return settled
    }

    /// Outflows on the paying account the user can pick as the actual debit
    /// when auto-matching failed. Broader than auto-match on purpose: any
    /// post-close outflow qualifies, ranked by amount closeness.
    public func candidateTransactions(
        for payment: UpcomingCardPayment,
        transactions: [TransactionSummary],
        asOf today: Date
    ) -> [TransactionSummary] {
        let start = calendar.startOfDay(for: today)
        let close = calendar.startOfDay(for: payment.closeDate)
        return transactions
            .filter {
                !$0.deleted
                    && $0.accountId == payment.paymentAccountId
                    && $0.amount.isNegative
                    && calendar.startOfDay(for: $0.date) > close
                    && calendar.startOfDay(for: $0.date) <= start
            }
            .sorted {
                let lhs = abs(
                    $0.amount.absolute.milliunits - payment.amount.milliunits
                )
                let rhs = abs(
                    $1.amount.absolute.milliunits - payment.amount.milliunits
                )
                if lhs != rhs { return lhs < rhs }
                if $0.date != $1.date { return $0.date > $1.date }
                return $0.id < $1.id
            }
    }

    private func isAutoMatch(
        _ transaction: TransactionSummary,
        for payment: UpcomingCardPayment,
        start: Date
    ) -> Bool {
        guard !transaction.deleted,
              transaction.accountId == payment.paymentAccountId,
              transaction.amount.isNegative,
              transaction.forecastTreatment == .cardPayment
        else { return false }
        let posted = calendar.startOfDay(for: transaction.date)
        guard posted > calendar.startOfDay(for: payment.closeDate),
              posted <= start
        else { return false }
        let expected = payment.amount.milliunits
        let tolerance = max(
            Self.minimumToleranceMilliunits,
            expected / 100
        )
        return abs(
            transaction.amount.absolute.milliunits - expected
        ) <= tolerance
    }
}
