import Foundation
import Money
import Models

/// Review retention never supplies future cash events. Keep the original
/// matched amount as matching evidence when a user edits statement membership.
public enum CardPaymentReviewQueue {
    /// A previously observed match stays valid through assignment edits, but
    /// removing/reclassifying its bank debit must restore the cash obligation.
    public static func retainedSettlement(
        payment: UpcomingCardPayment, transactionID: String,
        transactions: [TransactionSummary], counterpartAccountIds: [String: String],
        capturedAt: Date
    ) -> CardPaymentSettlement? {
        guard !transactionID.isEmpty,
              let debit = transactions.first(where: { $0.id == transactionID }),
              !debit.deleted, debit.cleared, debit.amount.isNegative,
              debit.accountId == payment.paymentAccountId,
              debit.forecastTreatment == .cardPayment,
              counterpartAccountIds[debit.id].map({ $0 == payment.cardAccountId }) ?? true,
              CardPaymentSettlementMatcher.isWithinPaymentTolerance(
                actualMilliunits: debit.amount.absolute.milliunits,
                expectedMilliunits: payment.amount.milliunits
              )
        else { return nil }
        return CardPaymentSettlement(
            id: payment.id, cardAccountId: payment.cardAccountId,
            statementCloseDate: payment.closeDate, transactionId: transactionID,
            updatedAt: capturedAt
        )
    }

    public static func matchingPayments(
        current: [UpcomingCardPayment], retained: [UpcomingCardPayment]
    ) -> [UpcomingCardPayment] {
        var byID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for payment in retained { byID[payment.id] = payment }
        return byID.values.sorted { $0.id < $1.id }
    }

    public static func readyToClear(
        payments: [UpcomingCardPayment], settledIDs: Set<String>, clearedIDs: Set<String>
    ) -> [UpcomingCardPayment] {
        payments.filter {
            $0.basis == .closedStatementEstimate
                && settledIDs.contains($0.id) && !clearedIDs.contains($0.id)
        }.sorted {
            if $0.dueDate != $1.dueDate { return $0.dueDate < $1.dueDate }
            return $0.id < $1.id
        }
    }
}

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

public struct CardPaymentSettlementMatcher: Sendable {
    private let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// Auto-match tolerance: interest or late credits can drift the actual
    /// debit a few dollars from the estimate without breaking the match.
    private static let minimumToleranceMilliunits: Int64 = 5_000

    /// Shared tolerance for treating a bank debit as one card's statement
    /// payment: within max($5, 1%) of the expected amount.
    public static func isWithinPaymentTolerance(
        actualMilliunits: Int64,
        expectedMilliunits: Int64
    ) -> Bool {
        let tolerance = max(
            minimumToleranceMilliunits,
            expectedMilliunits / 100
        )
        return abs(actualMilliunits - expectedMilliunits) <= tolerance
    }

    public func settledPaymentIds(
        payments: [UpcomingCardPayment],
        transactions: [TransactionSummary],
        counterpartAccountIds: [String: String] = [:],
        settlements: [CardPaymentSettlement],
        asOf today: Date
    ) -> Set<String> {
        Set(paymentMatches(
            payments: payments, transactions: transactions,
            counterpartAccountIds: counterpartAccountIds,
            settlements: settlements, asOf: today
        ).keys)
    }

    /// Empty transaction ID represents an explicit payment outside tracked accounts.
    public func paymentMatches(
        payments: [UpcomingCardPayment],
        transactions: [TransactionSummary],
        counterpartAccountIds: [String: String] = [:],
        settlements: [CardPaymentSettlement],
        asOf today: Date
    ) -> [String: String] {
        let start = calendar.startOfDay(for: today)
        let due = payments.filter {
            calendar.startOfDay(for: $0.closeDate) < start
        }
        guard !due.isEmpty else { return [:] }

        var settled: [String: String] = [:]
        var unresolved: [UpcomingCardPayment] = []
        for payment in due {
            let settlement = settlements.filter {
                $0.cardAccountId == payment.cardAccountId
                    && calendar.isDate(
                        $0.statementCloseDate,
                        inSameDayAs: payment.closeDate
                    )
            }.max { $0.updatedAt < $1.updatedAt }
            if let settlement {
                settled[payment.id] = settlement.transactionId ?? ""
            } else {
                unresolved.append(payment)
            }
        }

        // One debit settles at most one payment; closest amounts pair first
        // so two cards paid from one account cannot share a single debit.
        var pairs: [(paymentId: String, transactionId: String, distance: Int64)] = []
        for payment in unresolved {
            for transaction in transactions
            where isAutoMatch(
                transaction,
                for: payment,
                counterpartAccountIds: counterpartAccountIds,
                payments: payments,
                start: start
            ) {
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
        var usedTransactionIds = Set(settlements.compactMap(\.transactionId))
        for pair in pairs {
            guard settled[pair.paymentId] == nil,
                  !usedTransactionIds.contains(pair.transactionId)
            else { continue }
            settled[pair.paymentId] = pair.transactionId
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
        counterpartAccountIds: [String: String],
        payments: [UpcomingCardPayment],
        start: Date
    ) -> Bool {
        guard !transaction.deleted,
              transaction.cleared,
              transaction.accountId == payment.paymentAccountId,
              transaction.amount.isNegative,
              transaction.forecastTreatment == .cardPayment
        else { return false }
        let posted = calendar.startOfDay(for: transaction.date)
        guard posted > calendar.startOfDay(for: payment.closeDate),
              posted <= start
        else { return false }
        let identifiedCard = counterpartAccountIds[transaction.id]
            ?? CardPaymentIdentityResolver(calendar: calendar).uniqueCardMatch(
                debitAccountId: transaction.accountId,
                amount: transaction.amount,
                postedDate: transaction.date,
                payments: payments
            )?.cardAccountId
        guard identifiedCard == payment.cardAccountId else { return false }
        return Self.isWithinPaymentTolerance(
            actualMilliunits: transaction.amount.absolute.milliunits,
            expectedMilliunits: payment.amount.milliunits
        )
    }
}

/// Resolves which card an unpaired bank payment debit pays by matching it
/// against the projected per-card payments. The forecast knows each card's
/// expected amount and configured paying account — real identity evidence,
/// unlike bank descriptors, which are shared by every card paid from the
/// same account. Only a unique card match within the shared payment
/// tolerance resolves; no match or an ambiguous one returns nil so review
/// asks the user instead of guessing.
public struct CardPaymentIdentityResolver: Sendable {
    private let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public func uniqueCardMatch(
        debitAccountId: String,
        amount: Money,
        postedDate: Date,
        payments: [UpcomingCardPayment]
    ) -> UpcomingCardPayment? {
        guard amount.isNegative else { return nil }
        let posted = calendar.startOfDay(for: postedDate)
        let matches = payments.filter { payment in
            payment.paymentAccountId == debitAccountId
                && posted > calendar.startOfDay(for: payment.closeDate)
                && CardPaymentSettlementMatcher.isWithinPaymentTolerance(
                    actualMilliunits: amount.absolute.milliunits,
                    expectedMilliunits: payment.amount.milliunits
                )
        }
        guard Set(matches.map(\.cardAccountId)).count == 1 else {
            return nil
        }
        return matches.first
    }
}
