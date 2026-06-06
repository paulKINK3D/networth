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
    public let categoryId: String?
    public let categoryName: String?
    public let transferAccountId: String?
    public let memo: String?
    public let deleted: Bool
    public let subtransactions: [SubTransactionSummary]

    public init(
        id: String,
        accountId: String,
        date: Date,
        amount: Money,
        cleared: Bool,
        approved: Bool,
        payeeName: String?,
        categoryId: String? = nil,
        categoryName: String?,
        transferAccountId: String? = nil,
        memo: String?,
        deleted: Bool,
        subtransactions: [SubTransactionSummary] = []
    ) {
        self.id = id
        self.accountId = accountId
        self.date = date
        self.amount = amount
        self.cleared = cleared
        self.approved = approved
        self.payeeName = payeeName
        self.categoryId = categoryId
        self.categoryName = categoryName
        self.transferAccountId = transferAccountId
        self.memo = memo
        self.deleted = deleted
        self.subtransactions = subtransactions
    }

    public var isSplit: Bool { !subtransactions.isEmpty }
}

/// One leg of a YNAB split transaction. Sub-amounts sum to the parent's amount.
public struct SubTransactionSummary: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let amount: Money
    public let categoryId: String?
    public let categoryName: String?
    public let transferAccountId: String?
    public let payeeName: String?
    public let memo: String?
    public let deleted: Bool

    public init(
        id: String,
        amount: Money,
        categoryId: String?,
        categoryName: String?,
        transferAccountId: String? = nil,
        payeeName: String?,
        memo: String?,
        deleted: Bool
    ) {
        self.id = id
        self.amount = amount
        self.categoryId = categoryId
        self.categoryName = categoryName
        self.transferAccountId = transferAccountId
        self.payeeName = payeeName
        self.memo = memo
        self.deleted = deleted
    }
}

/// Master list of YNAB categories grouped by category group. We only need a
/// flat list with stable IDs + display info for the exclusion picker.
public struct CategorySummary: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let name: String
    public let groupId: String
    public let groupName: String
    public let hidden: Bool
    public let deleted: Bool

    public init(id: String, name: String, groupId: String, groupName: String, hidden: Bool = false, deleted: Bool = false) {
        self.id = id
        self.name = name
        self.groupId = groupId
        self.groupName = groupName
        self.hidden = hidden
        self.deleted = deleted
    }
}
