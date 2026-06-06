import Foundation
import Money

public struct TransactionSummary: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let accountId: String
    public let date: Date
    public let amount: Money
    public let cleared: Bool
    public let approved: Bool
    public let payeeName: String?
    public let categoryName: String?
    public let memo: String?
    public let deleted: Bool

    public init(
        id: String,
        accountId: String,
        date: Date,
        amount: Money,
        cleared: Bool,
        approved: Bool,
        payeeName: String?,
        categoryName: String?,
        memo: String?,
        deleted: Bool
    ) {
        self.id = id
        self.accountId = accountId
        self.date = date
        self.amount = amount
        self.cleared = cleared
        self.approved = approved
        self.payeeName = payeeName
        self.categoryName = categoryName
        self.memo = memo
        self.deleted = deleted
    }
}
