import Foundation
import SwiftData
import NetworthCore

/// Local-only SwiftData cache of YNAB data. Disposable; can be re-fetched.
/// Lives in its own ModelContainer so CloudKit sync only touches durable user data.

@Model
public final class CachedBudget {
    @Attribute(.unique) public var id: String
    public var name: String
    public var currencyISO: String
    public var lastModifiedRaw: String?
    public var isDefault: Bool

    public init(id: String, name: String, currencyISO: String = "USD", lastModifiedRaw: String? = nil, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.currencyISO = currencyISO
        self.lastModifiedRaw = lastModifiedRaw
        self.isDefault = isDefault
    }
}

@Model
public final class CachedAccount {
    @Attribute(.unique) public var id: String
    public var budgetId: String
    public var name: String
    public var typeRaw: String
    public var balanceMilliunits: Int64
    public var clearedMilliunits: Int64
    public var unclearedMilliunits: Int64
    public var onBudget: Bool
    public var closed: Bool
    public var deleted: Bool
    public var updatedAt: Date

    public init(
        id: String, budgetId: String, name: String, typeRaw: String,
        balanceMilliunits: Int64, clearedMilliunits: Int64, unclearedMilliunits: Int64,
        onBudget: Bool, closed: Bool, deleted: Bool, updatedAt: Date = .now
    ) {
        self.id = id
        self.budgetId = budgetId
        self.name = name
        self.typeRaw = typeRaw
        self.balanceMilliunits = balanceMilliunits
        self.clearedMilliunits = clearedMilliunits
        self.unclearedMilliunits = unclearedMilliunits
        self.onBudget = onBudget
        self.closed = closed
        self.deleted = deleted
        self.updatedAt = updatedAt
    }

    public var kind: AccountKind { AccountKind.fromYNAB(typeRaw) }
    public var balance: Money { Money(milliunits: balanceMilliunits) }

    public func toSnapshot() -> AccountSnapshot {
        AccountSnapshot(
            id: id, name: name, kind: kind,
            balance: Money(milliunits: balanceMilliunits),
            clearedBalance: Money(milliunits: clearedMilliunits),
            unclearedBalance: Money(milliunits: unclearedMilliunits),
            onBudget: onBudget, closed: closed, deleted: deleted
        )
    }
}

@Model
public final class CachedTransaction {
    @Attribute(.unique) public var id: String
    public var budgetId: String
    public var accountId: String
    public var date: Date
    public var amountMilliunits: Int64
    public var cleared: Bool
    public var approved: Bool
    public var payeeName: String?
    public var categoryName: String?
    public var memo: String?
    public var deleted: Bool

    public init(
        id: String, budgetId: String, accountId: String, date: Date, amountMilliunits: Int64,
        cleared: Bool, approved: Bool, payeeName: String?, categoryName: String?, memo: String?, deleted: Bool
    ) {
        self.id = id
        self.budgetId = budgetId
        self.accountId = accountId
        self.date = date
        self.amountMilliunits = amountMilliunits
        self.cleared = cleared
        self.approved = approved
        self.payeeName = payeeName
        self.categoryName = categoryName
        self.memo = memo
        self.deleted = deleted
    }

    public func toSummary() -> TransactionSummary {
        TransactionSummary(
            id: id, accountId: accountId, date: date,
            amount: Money(milliunits: amountMilliunits),
            cleared: cleared, approved: approved,
            payeeName: payeeName, categoryName: categoryName,
            memo: memo, deleted: deleted
        )
    }
}

@Model
public final class CachedScheduledTransaction {
    @Attribute(.unique) public var id: String
    public var budgetId: String
    public var accountId: String
    public var nextDate: Date
    public var frequencyRaw: String
    public var amountMilliunits: Int64
    public var payeeName: String?
    public var memo: String?
    public var deleted: Bool

    public init(
        id: String, budgetId: String, accountId: String, nextDate: Date,
        frequencyRaw: String, amountMilliunits: Int64,
        payeeName: String?, memo: String?, deleted: Bool
    ) {
        self.id = id
        self.budgetId = budgetId
        self.accountId = accountId
        self.nextDate = nextDate
        self.frequencyRaw = frequencyRaw
        self.amountMilliunits = amountMilliunits
        self.payeeName = payeeName
        self.memo = memo
        self.deleted = deleted
    }

    public func toSummary() -> ScheduledTransactionSummary {
        ScheduledTransactionSummary(
            id: id, accountId: accountId, nextDate: nextDate,
            frequency: ScheduleFrequency.fromYNAB(frequencyRaw),
            amount: Money(milliunits: amountMilliunits),
            payeeName: payeeName, memo: memo, deleted: deleted
        )
    }
}

/// Stores per-endpoint delta cursors so we don't refetch from scratch.
@Model
public final class SyncCursor {
    @Attribute(.unique) public var key: String  // e.g. "accounts:<budgetId>"
    public var serverKnowledge: Int64
    public var updatedAt: Date

    public init(key: String, serverKnowledge: Int64, updatedAt: Date = .now) {
        self.key = key
        self.serverKnowledge = serverKnowledge
        self.updatedAt = updatedAt
    }
}
