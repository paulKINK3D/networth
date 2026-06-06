import Foundation
import Money

/// User-entered statement settings for a credit-card account. Stored per-card
/// because YNAB does not expose statement-cycle metadata.
public struct CardStatementSettings: Sendable, Hashable, Codable, Identifiable {
    public var id: String { accountId }
    public let accountId: String
    /// Statement closing day-of-month (1...28).
    public let statementCycleDay: Int
    /// Decimal rate, e.g. 0.02 = 2%.
    public let minimumPaymentPercent: Decimal
    public let minimumPaymentFloor: Money

    public init(
        accountId: String,
        statementCycleDay: Int,
        minimumPaymentPercent: Decimal = Decimal(string: "0.02") ?? 0,
        minimumPaymentFloor: Money = Money.dollars(Decimal(25))
    ) {
        self.accountId = accountId
        self.statementCycleDay = max(1, min(28, statementCycleDay))
        self.minimumPaymentPercent = minimumPaymentPercent
        self.minimumPaymentFloor = minimumPaymentFloor
    }
}
