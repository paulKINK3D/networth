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
    public var categoryId: String?
    public var categoryName: String?
    public var transferAccountId: String?
    public var memo: String?
    public var deleted: Bool
    /// JSON-encoded `[SubTransactionSummary]`. Nil/empty when not a split.
    public var subtransactionsData: Data?

    public init(
        id: String, budgetId: String, accountId: String, date: Date, amountMilliunits: Int64,
        cleared: Bool, approved: Bool, payeeName: String?,
        categoryId: String? = nil, categoryName: String?,
        transferAccountId: String? = nil, memo: String?, deleted: Bool,
        subtransactionsData: Data? = nil
    ) {
        self.id = id
        self.budgetId = budgetId
        self.accountId = accountId
        self.date = date
        self.amountMilliunits = amountMilliunits
        self.cleared = cleared
        self.approved = approved
        self.payeeName = payeeName
        self.categoryId = categoryId
        self.categoryName = categoryName
        self.transferAccountId = transferAccountId
        self.memo = memo
        self.deleted = deleted
        self.subtransactionsData = subtransactionsData
    }

    public var subtransactions: [SubTransactionSummary] {
        guard let subtransactionsData, !subtransactionsData.isEmpty else { return [] }
        return (try? JSONDecoder().decode([SubTransactionSummary].self, from: subtransactionsData)) ?? []
    }

    public func toSummary() -> TransactionSummary {
        TransactionSummary(
            id: id, accountId: accountId, date: date,
            amount: Money(milliunits: amountMilliunits),
            cleared: cleared, approved: approved,
            payeeName: payeeName,
            categoryId: categoryId, categoryName: categoryName,
            transferAccountId: transferAccountId,
            memo: memo, deleted: deleted,
            subtransactions: subtransactions
        )
    }
}

@Model
public final class CachedCategory {
    @Attribute(.unique) public var id: String
    public var budgetId: String
    public var groupId: String
    public var groupName: String
    public var name: String
    public var hidden: Bool
    public var deleted: Bool

    public init(
        id: String, budgetId: String, groupId: String, groupName: String,
        name: String, hidden: Bool = false, deleted: Bool = false
    ) {
        self.id = id
        self.budgetId = budgetId
        self.groupId = groupId
        self.groupName = groupName
        self.name = name
        self.hidden = hidden
        self.deleted = deleted
    }

    public func toSummary() -> CategorySummary {
        CategorySummary(id: id, name: name, groupId: groupId, groupName: groupName, hidden: hidden, deleted: deleted)
    }
}

@Model
public final class CachedScheduledTransaction {
    @Attribute(.unique) public var id: String
    public var budgetId: String
    public var accountId: String
    public var firstDate: Date? = nil
    public var nextDate: Date
    public var frequencyRaw: String
    public var amountMilliunits: Int64
    public var payeeName: String?
    public var categoryId: String?
    public var transferAccountId: String?
    public var memo: String?
    public var deleted: Bool

    public init(
        id: String, budgetId: String, accountId: String, firstDate: Date? = nil, nextDate: Date,
        frequencyRaw: String, amountMilliunits: Int64,
        payeeName: String?, categoryId: String? = nil,
        transferAccountId: String? = nil, memo: String?, deleted: Bool
    ) {
        self.id = id
        self.budgetId = budgetId
        self.accountId = accountId
        self.firstDate = firstDate
        self.nextDate = nextDate
        self.frequencyRaw = frequencyRaw
        self.amountMilliunits = amountMilliunits
        self.payeeName = payeeName
        self.categoryId = categoryId
        self.transferAccountId = transferAccountId
        self.memo = memo
        self.deleted = deleted
    }

    public func toSummary() -> ScheduledTransactionSummary {
        ScheduledTransactionSummary(
            id: id, accountId: accountId, firstDate: firstDate, nextDate: nextDate,
            frequency: ScheduleFrequency.fromYNAB(frequencyRaw),
            amount: Money(milliunits: amountMilliunits),
            payeeName: payeeName,
            categoryId: categoryId,
            transferAccountId: transferAccountId,
            memo: memo, deleted: deleted
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

// MARK: - Plaid investment cache

/// Disposable Plaid rows. The private backend remains authoritative and no
/// Item access token is ever persisted in the app.
@Model
public final class CachedPlaidItem {
    @Attribute(.unique) public var id: String
    public var institutionName: String
    public var status: String
    public var lastSyncedAt: Date?

    public init(
        id: String,
        institutionName: String,
        status: String,
        lastSyncedAt: Date? = nil
    ) {
        self.id = id
        self.institutionName = institutionName
        self.status = status
        self.lastSyncedAt = lastSyncedAt
    }
}

@Model
public final class CachedPlaidAccount {
    @Attribute(.unique) public var id: String
    public var itemId: String
    public var institutionName: String
    public var name: String
    public var officialName: String?
    public var mask: String?
    public var subtype: String?
    public var currentBalanceMilliunits: Int64?
    public var availableBalanceMilliunits: Int64?
    public var isoCurrencyCode: String?
    public var unofficialCurrencyCode: String?

    public init(
        id: String,
        itemId: String,
        institutionName: String,
        name: String,
        officialName: String? = nil,
        mask: String? = nil,
        subtype: String? = nil,
        currentBalanceMilliunits: Int64? = nil,
        availableBalanceMilliunits: Int64? = nil,
        isoCurrencyCode: String? = nil,
        unofficialCurrencyCode: String? = nil
    ) {
        self.id = id
        self.itemId = itemId
        self.institutionName = institutionName
        self.name = name
        self.officialName = officialName
        self.mask = mask
        self.subtype = subtype
        self.currentBalanceMilliunits = currentBalanceMilliunits
        self.availableBalanceMilliunits = availableBalanceMilliunits
        self.isoCurrencyCode = isoCurrencyCode
        self.unofficialCurrencyCode = unofficialCurrencyCode
    }

    public var currentBalance: Money? {
        currentBalanceMilliunits.map(Money.init(milliunits:))
    }
}

@Model
public final class CachedPlaidSecurity {
    @Attribute(.unique) public var id: String
    public var name: String?
    public var tickerSymbol: String?
    public var typeRaw: String?
    public var closePriceMilliunits: Int64?
    public var closePriceAsOf: Date?
    public var isoCurrencyCode: String?
    public var unofficialCurrencyCode: String?

    public init(
        id: String,
        name: String? = nil,
        tickerSymbol: String? = nil,
        typeRaw: String? = nil,
        closePriceMilliunits: Int64? = nil,
        closePriceAsOf: Date? = nil,
        isoCurrencyCode: String? = nil,
        unofficialCurrencyCode: String? = nil
    ) {
        self.id = id
        self.name = name
        self.tickerSymbol = tickerSymbol
        self.typeRaw = typeRaw
        self.closePriceMilliunits = closePriceMilliunits
        self.closePriceAsOf = closePriceAsOf
        self.isoCurrencyCode = isoCurrencyCode
        self.unofficialCurrencyCode = unofficialCurrencyCode
    }
}

@Model
public final class CachedPlaidHolding {
    @Attribute(.unique) public var id: String
    public var accountId: String
    public var securityId: String
    /// Decimal is serialized as text to preserve quantity precision across
    /// SwiftData implementations without converting through Double.
    public var quantityDecimalString: String
    public var institutionValueMilliunits: Int64
    public var costBasisMilliunits: Int64?
    public var asOf: Date?

    public init(
        id: String,
        accountId: String,
        securityId: String,
        quantityDecimalString: String,
        institutionValueMilliunits: Int64,
        costBasisMilliunits: Int64? = nil,
        asOf: Date? = nil
    ) {
        self.id = id
        self.accountId = accountId
        self.securityId = securityId
        self.quantityDecimalString = quantityDecimalString
        self.institutionValueMilliunits = institutionValueMilliunits
        self.costBasisMilliunits = costBasisMilliunits
        self.asOf = asOf
    }

    public var quantity: Decimal? { Decimal(string: quantityDecimalString) }
    public var institutionValue: Money { Money(milliunits: institutionValueMilliunits) }
}
