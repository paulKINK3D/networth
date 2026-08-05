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
    // Date-window fetches (Spending report, Projections lookback) must not
    // table-scan a multi-year transaction cache.
    #Index<CachedTransaction>([\.date], [\.accountId, \.date])

    @Attribute(.unique) public var id: String
    public var budgetId: String
    public var accountId: String
    public var date: Date
    public var amountMilliunits: Int64
    public var cleared: Bool
    public var approved: Bool
    public var payeeId: String? = nil
    public var payeeName: String?
    public var categoryId: String?
    public var categoryName: String?
    public var transferAccountId: String?
    public var transferTransactionId: String? = nil
    public var importId: String? = nil
    public var memo: String?
    public var deleted: Bool
    /// JSON-encoded `[SubTransactionSummary]`. Nil/empty when not a split.
    public var subtransactionsData: Data?

    public init(
        id: String, budgetId: String, accountId: String, date: Date, amountMilliunits: Int64,
        cleared: Bool, approved: Bool, payeeName: String?,
        categoryId: String? = nil, categoryName: String?,
        payeeId: String? = nil,
        transferAccountId: String? = nil,
        transferTransactionId: String? = nil,
        importId: String? = nil,
        memo: String?, deleted: Bool,
        subtransactionsData: Data? = nil
    ) {
        self.id = id
        self.budgetId = budgetId
        self.accountId = accountId
        self.date = date
        self.amountMilliunits = amountMilliunits
        self.cleared = cleared
        self.approved = approved
        self.payeeId = payeeId
        self.payeeName = payeeName
        self.categoryId = categoryId
        self.categoryName = categoryName
        self.transferAccountId = transferAccountId
        self.transferTransactionId = transferTransactionId
        self.importId = importId
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

    /// Summary carrying stable canonical identities resolved from the durable
    /// payee/category directories. The Budget engine keys recurrence and
    /// bucket logic on these so YNAB renames cannot fragment history.
    public func toSummary(
        payeeCanonicalIdByYnabId: [String: String],
        categoryCanonicalIdByYnabId: [String: String]
    ) -> TransactionSummary {
        TransactionSummary(
            id: id, accountId: accountId, date: date,
            amount: Money(milliunits: amountMilliunits),
            cleared: cleared, approved: approved,
            payeeName: payeeName,
            categoryId: categoryId, categoryName: categoryName,
            payeeCanonicalId: payeeId.flatMap {
                payeeCanonicalIdByYnabId[$0]
            },
            categoryCanonicalId: categoryId.flatMap {
                categoryCanonicalIdByYnabId[$0]
            },
            transferAccountId: transferAccountId,
            memo: memo, deleted: deleted,
            subtransactions: subtransactions.map { leg in
                SubTransactionSummary(
                    id: leg.id, amount: leg.amount,
                    categoryId: leg.categoryId,
                    categoryName: leg.categoryName,
                    categoryCanonicalId: leg.categoryId.flatMap {
                        categoryCanonicalIdByYnabId[$0]
                    },
                    forecastTreatment: leg.forecastTreatment,
                    transferAccountId: leg.transferAccountId,
                    payeeName: leg.payeeName,
                    memo: leg.memo, deleted: leg.deleted
                )
            }
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

/// Per-month category envelope numbers from YNAB (budgeted/activity/balance).
/// Read-only import powering the Spending report's Budgeted column and group
/// summaries. Disposable cache — refetched on demand.
@Model
public final class CachedCategoryMonth {
    /// "\(budgetId)|\(month)|\(categoryId)"
    @Attribute(.unique) public var id: String
    public var budgetId: String
    /// First-of-month date string, e.g. "2026-08-01".
    public var month: String
    public var categoryId: String
    public var budgetedMilliunits: Int64
    public var activityMilliunits: Int64
    public var balanceMilliunits: Int64
    public var updatedAt: Date

    public init(
        budgetId: String,
        month: String,
        categoryId: String,
        budgetedMilliunits: Int64,
        activityMilliunits: Int64,
        balanceMilliunits: Int64,
        updatedAt: Date = .now
    ) {
        self.id = "\(budgetId)|\(month)|\(categoryId)"
        self.budgetId = budgetId
        self.month = month
        self.categoryId = categoryId
        self.budgetedMilliunits = budgetedMilliunits
        self.activityMilliunits = activityMilliunits
        self.balanceMilliunits = balanceMilliunits
        self.updatedAt = updatedAt
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
    public var productsRaw: String = "investments"

    public init(
        id: String,
        institutionName: String,
        status: String,
        lastSyncedAt: Date? = nil,
        products: [String] = ["investments"]
    ) {
        self.id = id
        self.institutionName = institutionName
        self.status = status
        self.lastSyncedAt = lastSyncedAt
        self.productsRaw = products.sorted().joined(separator: ",")
    }

    public var products: Set<String> {
        Set(productsRaw.split(separator: ",").map(String.init))
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
    public var typeRaw: String? = nil
    public var subtype: String?
    public var currentBalanceMilliunits: Int64?
    public var availableBalanceMilliunits: Int64?
    public var limitMilliunits: Int64? = nil
    public var isoCurrencyCode: String?
    public var unofficialCurrencyCode: String?

    public init(
        id: String,
        itemId: String,
        institutionName: String,
        name: String,
        officialName: String? = nil,
        mask: String? = nil,
        typeRaw: String? = nil,
        subtype: String? = nil,
        currentBalanceMilliunits: Int64? = nil,
        availableBalanceMilliunits: Int64? = nil,
        limitMilliunits: Int64? = nil,
        isoCurrencyCode: String? = nil,
        unofficialCurrencyCode: String? = nil
    ) {
        self.id = id
        self.itemId = itemId
        self.institutionName = institutionName
        self.name = name
        self.officialName = officialName
        self.mask = mask
        self.typeRaw = typeRaw
        self.subtype = subtype
        self.currentBalanceMilliunits = currentBalanceMilliunits
        self.availableBalanceMilliunits = availableBalanceMilliunits
        self.limitMilliunits = limitMilliunits
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

// MARK: - Source-neutral financial cache

/// Disposable normalized account data. `canonicalAccountId` is app-owned and
/// remains stable while provider-specific IDs are stored separately.
@Model
public final class CachedFinancialAccount {
    @Attribute(.unique) public var canonicalAccountId: String
    public var externalId: String
    public var itemId: String?
    public var sourceRaw: String
    public var institutionName: String?
    public var name: String
    public var officialName: String?
    public var mask: String?
    public var typeRaw: String
    public var subtype: String?
    public var currentBalanceMilliunits: Int64?
    public var availableBalanceMilliunits: Int64?
    public var creditLimitMilliunits: Int64?
    public var isoCurrencyCode: String?
    public var deleted: Bool
    public var updatedAt: Date

    public init(
        canonicalAccountId: String,
        externalId: String,
        itemId: String?,
        source: FinancialDataSource,
        institutionName: String?,
        name: String,
        officialName: String?,
        mask: String?,
        type: FinancialAccountType,
        subtype: String?,
        currentBalanceMilliunits: Int64?,
        availableBalanceMilliunits: Int64?,
        creditLimitMilliunits: Int64?,
        isoCurrencyCode: String?,
        deleted: Bool = false,
        updatedAt: Date = .now
    ) {
        self.canonicalAccountId = canonicalAccountId
        self.externalId = externalId
        self.itemId = itemId
        self.sourceRaw = source.rawValue
        self.institutionName = institutionName
        self.name = name
        self.officialName = officialName
        self.mask = mask
        self.typeRaw = type.rawValue
        self.subtype = subtype
        self.currentBalanceMilliunits = currentBalanceMilliunits
        self.availableBalanceMilliunits = availableBalanceMilliunits
        self.creditLimitMilliunits = creditLimitMilliunits
        self.isoCurrencyCode = isoCurrencyCode
        self.deleted = deleted
        self.updatedAt = updatedAt
    }

    public var source: FinancialDataSource {
        FinancialDataSource(rawValue: sourceRaw) ?? .plaid
    }

    public var type: FinancialAccountType {
        FinancialAccountType(rawValue: typeRaw) ?? .other
    }

    public var kind: AccountKind {
        switch type {
        case .checking: .checking
        case .savings: .savings
        case .creditCard: .creditCard
        case .cash: .cash
        case .investment: .investment
        case .loan: .otherDebt
        case .other: .unknown
        }
    }

    public var balance: Money {
        Money(milliunits: currentBalanceMilliunits ?? 0)
    }

    public func toAccountSnapshot() -> AccountSnapshot {
        AccountSnapshot(
            id: canonicalAccountId,
            name: name,
            kind: kind,
            balance: balance,
            clearedBalance: balance,
            unclearedBalance: .zero,
            onBudget: type.isCashLike || type == .creditCard,
            closed: false,
            deleted: deleted
        )
    }

    public func toSummary() -> FinancialAccountSummary {
        FinancialAccountSummary(
            id: canonicalAccountId,
            externalId: externalId,
            itemId: itemId,
            source: source,
            institutionName: institutionName,
            name: name,
            officialName: officialName,
            mask: mask,
            type: type,
            subtype: subtype,
            currentBalance: currentBalanceMilliunits.map(Money.init(milliunits:)),
            availableBalance: availableBalanceMilliunits.map(Money.init(milliunits:)),
            creditLimit: creditLimitMilliunits.map(Money.init(milliunits:)),
            isoCurrencyCode: isoCurrencyCode
        )
    }
}

@Model
public final class CachedFinancialTransaction {
    #Index<CachedFinancialTransaction>(
        [\.canonicalAccountId, \.deleted, \.pending, \.postedDate],
        [\.postedDate]
    )

    @Attribute(.unique) public var id: String
    public var externalId: String
    public var sourceRaw: String
    public var canonicalAccountId: String
    public var postedDate: Date
    public var authorizedDate: Date?
    public var amountMilliunits: Int64
    public var pending: Bool
    public var pendingTransactionId: String?
    public var rawDescription: String
    public var originalDescription: String?
    public var providerMerchantName: String?
    public var merchantEntityId: String?
    public var counterpartyName: String?
    public var counterpartyType: String?
    public var counterpartyEntityId: String?
    public var counterpartyConfidence: String?
    public var paymentChannel: String?
    public var providerCategoryPrimary: String?
    public var providerCategoryDetailed: String?
    public var providerCategoryConfidence: String?
    public var transactionCode: String?
    public var displayName: String
    public var payeeCanonicalId: String? = nil
    public var nativeCategoryRaw: String
    public var categoryCanonicalId: String? = nil
    public var categoryName: String? = nil
    public var forecastTreatmentRaw: String
    public var subtransactionsData: Data? = nil
    public var classificationConfidenceRaw: String
    public var classificationProvenanceRaw: String
    public var requiresReview: Bool
    /// Name review is independent from transaction/category review. The
    /// default keeps already-imported rows from reopening during migration.
    public var requiresNameReview: Bool = false
    /// `historical` for the initial Plaid import; `new` thereafter.
    public var reviewOriginRaw: String = "historical"
    public var deleted: Bool
    public var updatedAt: Date

    public init(
        summary: FinancialTransactionSummary,
        classification: TransactionClassification,
        subtransactionsData: Data? = nil,
        requiresNameReview: Bool? = nil,
        reviewOriginRaw: String = "historical",
        deleted: Bool = false,
        updatedAt: Date = .now
    ) {
        id = summary.id
        externalId = summary.externalId
        sourceRaw = summary.source.rawValue
        canonicalAccountId = summary.accountId
        postedDate = summary.postedDate
        authorizedDate = summary.authorizedDate
        amountMilliunits = summary.amount.milliunits
        pending = summary.pending
        pendingTransactionId = summary.pendingTransactionId
        rawDescription = summary.rawDescription
        originalDescription = summary.originalDescription
        providerMerchantName = summary.providerMerchantName
        merchantEntityId = summary.merchantEntityId
        counterpartyName = summary.counterpartyName
        counterpartyType = summary.counterpartyType
        counterpartyEntityId = summary.counterpartyEntityId
        counterpartyConfidence = summary.counterpartyConfidence
        paymentChannel = summary.paymentChannel
        providerCategoryPrimary = summary.providerCategoryPrimary
        providerCategoryDetailed = summary.providerCategoryDetailed
        providerCategoryConfidence = summary.providerCategoryConfidence
        transactionCode = summary.transactionCode
        displayName = classification.displayName
        nativeCategoryRaw = classification.category.rawValue
        categoryName = classification.categoryName
        forecastTreatmentRaw = classification.treatment.rawValue
        self.subtransactionsData = subtransactionsData
        classificationConfidenceRaw = classification.confidence.rawValue
        classificationProvenanceRaw = classification.provenance.rawValue
        requiresReview = classification.requiresReview
        self.requiresNameReview = requiresNameReview
            ?? (!summary.pending && classification.requiresReview)
        self.reviewOriginRaw = reviewOriginRaw
        self.deleted = deleted
        self.updatedAt = updatedAt
    }

    public var category: NativeTransactionCategory {
        NativeTransactionCategory(rawValue: nativeCategoryRaw) ?? .other
    }

    public var categoryDisplayName: String {
        if isSplit { return "Split" }
        let trimmed = categoryName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? category.displayName : trimmed
    }

    /// Name review follows the user-facing local name once it is specific
    /// enough to identify a contact. Plaid fingerprints remain the fallback
    /// for generic labels so unrelated "Payment" or "Transfer" rows do not
    /// collapse into one decision.
    public var nameReviewGroupKey: String {
        let normalizedName =
            FinancialTransactionSummary.normalizedDescription(displayName)
        let genericNames: Set<String> = [
            "", "unknown", "transaction", "payment", "transfer",
            "purchase", "debit", "credit"
        ]
        if !genericNames.contains(normalizedName) {
            return "local-name:\(normalizedName)"
        }
        return toSummary().merchantFingerprint
    }

    public var forecastTreatment: ForecastTreatment {
        ForecastTreatment(rawValue: forecastTreatmentRaw) ?? .ordinarySpending
    }

    public var subtransactions: [SubTransactionSummary] {
        guard let subtransactionsData, !subtransactionsData.isEmpty else {
            return []
        }
        return (try? JSONDecoder().decode(
            [SubTransactionSummary].self,
            from: subtransactionsData
        )) ?? []
    }

    public var isSplit: Bool { !subtransactions.isEmpty }

    public var classificationDecisionKey: String {
        if isSplit {
            let legs = subtransactions.map {
                "\(($0.categoryName ?? "").lowercased()):"
                    + "\($0.forecastTreatment?.rawValue ?? ""):"
                    + "\($0.amount.milliunits)"
            }.joined(separator: ",")
            return "split|\(legs)"
        }
        return "\(categoryDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(forecastTreatment.rawValue)"
    }

    public var reviewDecisionKey: String {
        "\(toSummary().merchantFingerprint)|\(classificationDecisionKey)"
    }

    public func toSummary() -> FinancialTransactionSummary {
        FinancialTransactionSummary(
            id: id,
            externalId: externalId,
            source: FinancialDataSource(rawValue: sourceRaw) ?? .plaid,
            accountId: canonicalAccountId,
            postedDate: postedDate,
            authorizedDate: authorizedDate,
            amount: Money(milliunits: amountMilliunits),
            pending: pending,
            pendingTransactionId: pendingTransactionId,
            rawDescription: rawDescription,
            originalDescription: originalDescription,
            providerMerchantName: providerMerchantName,
            merchantEntityId: merchantEntityId,
            counterpartyName: counterpartyName,
            counterpartyType: counterpartyType,
            counterpartyEntityId: counterpartyEntityId,
            counterpartyConfidence: counterpartyConfidence,
            paymentChannel: paymentChannel,
            providerCategoryPrimary: providerCategoryPrimary,
            providerCategoryDetailed: providerCategoryDetailed,
            providerCategoryConfidence: providerCategoryConfidence,
            transactionCode: transactionCode
        )
    }

    public func toProjectionSummary() -> TransactionSummary? {
        // Investment contributions stay out of the historical ordinary-spend
        // estimate; their dated cash-outflow modeling arrives with recurring
        // expectations (Phase 1 step 4).
        guard !deleted, !pending, !requiresReview,
              forecastTreatment != .excluded,
              forecastTreatment != .internalTransfer,
              forecastTreatment != .investmentContribution,
              forecastTreatment != .cardPayment else {
            return nil
        }
        return TransactionSummary(
            id: id,
            accountId: canonicalAccountId,
            date: postedDate,
            amount: Money(milliunits: amountMilliunits),
            cleared: true,
            approved: !requiresReview,
            payeeName: displayName,
            categoryId: isSplit
                ? nil
                : "local:\(Self.categoryKey(categoryDisplayName))",
            categoryName: isSplit ? nil : categoryDisplayName,
            payeeCanonicalId: payeeCanonicalId,
            categoryCanonicalId: isSplit ? nil : categoryCanonicalId,
            forecastTreatment: forecastTreatment,
            transferAccountId: nil,
            memo: nil,
            deleted: deleted,
            subtransactions: subtransactions
        )
    }

    private static func categoryKey(_ value: String) -> String {
        FinancialTransactionSummary.normalizedDescription(value)
            .replacingOccurrences(of: " ", with: "-")
    }
}

@Model
public final class PlaidTransactionCursor {
    @Attribute(.unique) public var itemId: String
    public var cursor: String?
    public var updateStatus: String? = nil
    /// Local migration marker. Once the completed historical import and
    /// reviewed account map have seeded legacy matches, ordinary delta syncs
    /// must not rebuild the entire two-year reconciliation.
    public var historicalReconciliationVersion: Int = 0
    public var updatedAt: Date

    public init(
        itemId: String,
        cursor: String? = nil,
        updateStatus: String? = nil,
        historicalReconciliationVersion: Int = 0,
        updatedAt: Date = .now
    ) {
        self.itemId = itemId
        self.cursor = cursor
        self.updateStatus = updateStatus
        self.historicalReconciliationVersion = historicalReconciliationVersion
        self.updatedAt = updatedAt
    }

    public var historicalImportComplete: Bool {
        updateStatus == "HISTORICAL_UPDATE_COMPLETE"
    }
}

/// Per-account record of the Plaid transaction history actually imported:
/// the earliest and latest applied transaction dates plus any known coverage
/// gaps. Coverage is account-specific — never substitute one global history
/// window. Lives in the re-fetchable cache tier; a full resync rebuilds it.
@Model
public final class PlaidAccountCoverage {
    @Attribute(.unique) public var plaidAccountId: String
    public var itemId: String
    public var earliestImportedDate: Date?
    public var latestImportedDate: Date?
    /// JSON-encoded `[start, end]` day pairs for known gaps in coverage.
    public var gapsData: Data? = nil
    public var updatedAt: Date

    public init(
        plaidAccountId: String,
        itemId: String,
        earliestImportedDate: Date? = nil,
        latestImportedDate: Date? = nil,
        gapsData: Data? = nil,
        updatedAt: Date = .now
    ) {
        self.plaidAccountId = plaidAccountId
        self.itemId = itemId
        self.earliestImportedDate = earliestImportedDate
        self.latestImportedDate = latestImportedDate
        self.gapsData = gapsData
        self.updatedAt = updatedAt
    }
}

/// One row of the rebuildable YNAB reference table: the matched Plaid and
/// YNAB transaction identities plus the suggested classification (payee,
/// category, treatment, split), confidence, and score needed to explain and
/// reproduce the suggestion. Suggestions prefill review — they are never
/// reviewed decisions, and only new user decisions are authoritative. Lives
/// in the local re-fetchable tier, never CloudKit; a reference re-import
/// deletes and rebuilds every row.
@Model
public final class YNABReferenceSuggestion {
    @Attribute(.unique) public var plaidTransactionId: String
    public var ynabTransactionId: String
    public var payeeCanonicalId: String?
    public var payeeNameSnapshot: String
    public var categoryCanonicalId: String?
    public var categoryNameSnapshot: String?
    public var forecastTreatmentRaw: String
    /// JSON `[SubTransactionSummary]` when the YNAB side was a split.
    public var subtransactionsData: Data?
    public var confidenceRaw: String
    public var score: Int
    /// Mirrors the matcher's `isAutomatic`: unique/high-quality evidence.
    /// Nothing auto-applies either way; this exists to explain the match.
    public var strong: Bool
    public var createdAt: Date

    public init(
        plaidTransactionId: String,
        ynabTransactionId: String,
        payeeCanonicalId: String? = nil,
        payeeNameSnapshot: String = "",
        categoryCanonicalId: String? = nil,
        categoryNameSnapshot: String? = nil,
        forecastTreatment: ForecastTreatment = .ordinarySpending,
        subtransactionsData: Data? = nil,
        confidence: ClassificationConfidence = .low,
        score: Int = 0,
        strong: Bool = false,
        createdAt: Date = .now
    ) {
        self.plaidTransactionId = plaidTransactionId
        self.ynabTransactionId = ynabTransactionId
        self.payeeCanonicalId = payeeCanonicalId
        self.payeeNameSnapshot = payeeNameSnapshot
        self.categoryCanonicalId = categoryCanonicalId
        self.categoryNameSnapshot = categoryNameSnapshot
        self.forecastTreatmentRaw = forecastTreatment.rawValue
        self.subtransactionsData = subtransactionsData
        self.confidenceRaw = confidence.rawValue
        self.score = score
        self.strong = strong
        self.createdAt = createdAt
    }

    public var forecastTreatment: ForecastTreatment {
        ForecastTreatment(rawValue: forecastTreatmentRaw) ?? .ordinarySpending
    }

    public var confidence: ClassificationConfidence {
        ClassificationConfidence(rawValue: confidenceRaw) ?? .low
    }

    public var subtransactions: [SubTransactionSummary] {
        guard let subtransactionsData, !subtransactionsData.isEmpty else {
            return []
        }
        return (try? JSONDecoder().decode(
            [SubTransactionSummary].self, from: subtransactionsData
        )) ?? []
    }
}

@Model
public final class LegacyTransactionMatchRow {
    @Attribute(.unique) public var plaidTransactionId: String
    public var ynabTransactionId: String
    public var confidenceRaw: String
    public var score: Int
    public var automatic: Bool
    public var reviewed: Bool
    public var createdAt: Date

    public init(
        plaidTransactionId: String,
        ynabTransactionId: String,
        confidence: ClassificationConfidence,
        score: Int,
        automatic: Bool,
        reviewed: Bool = false,
        createdAt: Date = .now
    ) {
        self.plaidTransactionId = plaidTransactionId
        self.ynabTransactionId = ynabTransactionId
        self.confidenceRaw = confidence.rawValue
        self.score = score
        self.automatic = automatic
        self.reviewed = reviewed
        self.createdAt = createdAt
    }
}
