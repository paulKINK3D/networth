import Foundation
import Money

/// Projection of a single credit card's next statement.
public struct StatementProjection: Sendable, Hashable, Codable, Identifiable {
    public var id: String { cardAccountId }
    public let cardAccountId: String
    public let cardName: String
    /// Reference date used to compute the projection.
    public let asOf: Date
    public let lastCloseDate: Date
    public let nextCloseDate: Date
    /// Positive value representing what is owed today.
    public let currentBalanceOwed: Money
    public let scheduledChargesBeforeClose: Money
    public let scheduledPaymentsBeforeClose: Money
    /// Extrapolated charges between today and the next close, derived from
    /// recent historical spend on this card. Zero when no history is provided.
    public let projectedVariableCharges: Money
    /// Average daily charge on this card over the lookback window.
    public let dailyAverageCharge: Money
    public let projectedStatementBalance: Money
    public let minimumPayment: Money

    public init(
        cardAccountId: String,
        cardName: String,
        asOf: Date,
        lastCloseDate: Date,
        nextCloseDate: Date,
        currentBalanceOwed: Money,
        scheduledChargesBeforeClose: Money,
        scheduledPaymentsBeforeClose: Money,
        projectedVariableCharges: Money = .zero,
        dailyAverageCharge: Money = .zero,
        projectedStatementBalance: Money,
        minimumPayment: Money
    ) {
        self.cardAccountId = cardAccountId
        self.cardName = cardName
        self.asOf = asOf
        self.lastCloseDate = lastCloseDate
        self.nextCloseDate = nextCloseDate
        self.currentBalanceOwed = currentBalanceOwed
        self.scheduledChargesBeforeClose = scheduledChargesBeforeClose
        self.scheduledPaymentsBeforeClose = scheduledPaymentsBeforeClose
        self.projectedVariableCharges = projectedVariableCharges
        self.dailyAverageCharge = dailyAverageCharge
        self.projectedStatementBalance = projectedStatementBalance
        self.minimumPayment = minimumPayment
    }
}

public enum PayoffMode: String, Sendable, Hashable, Codable, CaseIterable {
    case full
    case minimum
    case custom
}

public struct PayoffScenario: Sendable, Hashable, Codable {
    public let mode: PayoffMode
    public let paymentAmount: Money
    public let carryover: Money

    public init(mode: PayoffMode, paymentAmount: Money, carryover: Money) {
        self.mode = mode
        self.paymentAmount = paymentAmount
        self.carryover = carryover
    }
}

/// A daily point on a forward cash-position projection (Projections tab).
public struct CashPositionPoint: Sendable, Hashable, Codable, Identifiable {
    public var id: Date { date }
    public let date: Date
    public let balance: Money

    public init(date: Date, balance: Money) {
        self.date = date
        self.balance = balance
    }
}
