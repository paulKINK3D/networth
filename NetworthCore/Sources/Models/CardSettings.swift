import Foundation
import Money

/// User-entered statement settings for a credit-card account. Stored per-card
/// because YNAB does not expose statement-cycle metadata.
public struct CardStatementSettings: Sendable, Hashable, Codable, Identifiable {
    public var id: String { accountId }
    public let accountId: String
    /// Statement closing day-of-month (1...31). Values 29-31 clamp to the last
    /// day of months that are too short (e.g. day 31 → Feb 28/29).
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
        self.statementCycleDay = max(1, min(31, statementCycleDay))
        self.minimumPaymentPercent = minimumPaymentPercent
        self.minimumPaymentFloor = minimumPaymentFloor
    }
}
