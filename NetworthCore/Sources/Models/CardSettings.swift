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
    /// Autopay debit day-of-month (1...31). `0` means the user hasn't set
    /// it yet; callers should treat that as "no scheduled payment to project."
    public let paymentDueDay: Int
    /// Cash account that funds this card's full-statement autopay. Nil means
    /// card setup is incomplete and its payments cannot affect cash outlook.
    public let paymentAccountId: String?
    /// Decimal rate, e.g. 0.02 = 2%.
    public let minimumPaymentPercent: Decimal
    public let minimumPaymentFloor: Money

    public init(
        accountId: String,
        statementCycleDay: Int,
        paymentDueDay: Int = 0,
        paymentAccountId: String? = nil,
        minimumPaymentPercent: Decimal = Decimal(string: "0.02") ?? 0,
        minimumPaymentFloor: Money = Money.dollars(Decimal(25))
    ) {
        self.accountId = accountId
        self.statementCycleDay = max(1, min(31, statementCycleDay))
        self.paymentDueDay = max(0, min(31, paymentDueDay))
        self.paymentAccountId = paymentAccountId
        self.minimumPaymentPercent = minimumPaymentPercent
        self.minimumPaymentFloor = minimumPaymentFloor
    }
}
