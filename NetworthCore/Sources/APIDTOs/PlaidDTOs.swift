import Foundation
import Models
import Money

public struct PlaidItemsResponseDTO: Codable, Sendable {
    public let items: [PlaidItemDTO]

    public init(items: [PlaidItemDTO]) {
        self.items = items
    }
}

public struct PlaidHoldingsResponseDTO: Codable, Sendable {
    public let items: [PlaidItemDTO]
    public let accounts: [PlaidAccountDTO]
    public let securities: [PlaidSecurityDTO]
    public let holdings: [PlaidHoldingDTO]

    public init(
        items: [PlaidItemDTO],
        accounts: [PlaidAccountDTO],
        securities: [PlaidSecurityDTO],
        holdings: [PlaidHoldingDTO]
    ) {
        self.items = items
        self.accounts = accounts
        self.securities = securities
        self.holdings = holdings
    }

    public func toSnapshot() -> PlaidInvestmentSnapshot {
        PlaidInvestmentSnapshot(
            items: items.map(\.summary),
            accounts: accounts.map(\.summary),
            securities: securities.map(\.summary),
            holdings: holdings.map(\.summary)
        )
    }
}

public struct PlaidLinkTokenResponseDTO: Codable, Sendable, Equatable {
    public let linkToken: String
    public let expiration: Date?

    public init(linkToken: String, expiration: Date?) {
        self.linkToken = linkToken
        self.expiration = expiration
    }
}

public struct PlaidExchangeResponseDTO: Codable, Sendable, Equatable {
    public let item: PlaidItemDTO

    public init(item: PlaidItemDTO) {
        self.item = item
    }
}

public struct PlaidItemDTO: Codable, Sendable, Equatable {
    public let id: String
    public let institutionName: String
    public let status: String
    public let lastSyncedAt: Date?
    public let products: [String]?

    public init(
        id: String,
        institutionName: String,
        status: String,
        lastSyncedAt: Date?,
        products: [String]? = nil
    ) {
        self.id = id
        self.institutionName = institutionName
        self.status = status
        self.lastSyncedAt = lastSyncedAt
        self.products = products
    }

    public var summary: PlaidInvestmentItem {
        PlaidInvestmentItem(
            id: id,
            institutionName: institutionName,
            status: status,
            lastSyncedAt: lastSyncedAt
        )
    }
}

public struct PlaidAccountDTO: Codable, Sendable, Equatable {
    public let id: String
    public let itemId: String
    public let institutionName: String
    public let name: String
    public let officialName: String?
    public let mask: String?
    public let type: String?
    public let subtype: String?
    public let currentBalance: Decimal?
    public let availableBalance: Decimal?
    public let limit: Decimal?
    public let isoCurrencyCode: String?
    public let unofficialCurrencyCode: String?

    public init(
        id: String,
        itemId: String,
        institutionName: String,
        name: String,
        officialName: String?,
        mask: String?,
        type: String? = nil,
        subtype: String?,
        currentBalance: Decimal?,
        availableBalance: Decimal?,
        limit: Decimal? = nil,
        isoCurrencyCode: String?,
        unofficialCurrencyCode: String?
    ) {
        self.id = id
        self.itemId = itemId
        self.institutionName = institutionName
        self.name = name
        self.officialName = officialName
        self.mask = mask
        self.type = type
        self.subtype = subtype
        self.currentBalance = currentBalance
        self.availableBalance = availableBalance
        self.limit = limit
        self.isoCurrencyCode = isoCurrencyCode
        self.unofficialCurrencyCode = unofficialCurrencyCode
    }

    public var summary: PlaidInvestmentAccount {
        PlaidInvestmentAccount(
            id: id,
            itemId: itemId,
            institutionName: institutionName,
            name: name,
            officialName: officialName,
            mask: mask,
            subtype: subtype,
            currentBalance: currentBalance.map(Money.dollars),
            availableBalance: availableBalance.map(Money.dollars),
            isoCurrencyCode: isoCurrencyCode,
            unofficialCurrencyCode: unofficialCurrencyCode
        )
    }

    public func financialSummary(canonicalAccountId: String) -> FinancialAccountSummary {
        let accountType = Self.accountType(type: type, subtype: subtype)
        let balanceSign: Decimal = accountType == .creditCard || accountType == .loan ? -1 : 1
        return FinancialAccountSummary(
            id: canonicalAccountId,
            externalId: id,
            itemId: itemId,
            source: .plaid,
            institutionName: institutionName,
            name: name,
            officialName: officialName,
            mask: mask,
            type: accountType,
            subtype: subtype,
            currentBalance: currentBalance.map { Money.dollars($0 * balanceSign) },
            availableBalance: availableBalance.map(Money.dollars),
            creditLimit: limit.map(Money.dollars),
            isoCurrencyCode: isoCurrencyCode
        )
    }

    private static func accountType(type: String?, subtype: String?) -> FinancialAccountType {
        let type = type?.lowercased()
        let subtype = subtype?.lowercased()
        if type == "credit" { return .creditCard }
        if type == "depository" && subtype == "checking" { return .checking }
        if type == "depository" && subtype == "savings" { return .savings }
        if type == "investment" { return .investment }
        if type == "loan" { return .loan }
        if type == "depository" { return .cash }
        return .other
    }
}

public struct PlaidSecurityDTO: Codable, Sendable, Equatable {
    public let id: String
    public let name: String?
    public let tickerSymbol: String?
    public let type: String?
    public let closePrice: Decimal?
    public let closePriceAsOf: Date?
    public let isoCurrencyCode: String?
    public let unofficialCurrencyCode: String?

    public init(
        id: String,
        name: String?,
        tickerSymbol: String?,
        type: String?,
        closePrice: Decimal?,
        closePriceAsOf: Date?,
        isoCurrencyCode: String?,
        unofficialCurrencyCode: String?
    ) {
        self.id = id
        self.name = name
        self.tickerSymbol = tickerSymbol
        self.type = type
        self.closePrice = closePrice
        self.closePriceAsOf = closePriceAsOf
        self.isoCurrencyCode = isoCurrencyCode
        self.unofficialCurrencyCode = unofficialCurrencyCode
    }

    public var summary: PlaidSecurity {
        PlaidSecurity(
            id: id,
            name: name,
            tickerSymbol: tickerSymbol,
            type: type,
            closePrice: closePrice.map(Money.dollars),
            closePriceAsOf: closePriceAsOf,
            isoCurrencyCode: isoCurrencyCode,
            unofficialCurrencyCode: unofficialCurrencyCode
        )
    }
}

public struct PlaidHoldingDTO: Codable, Sendable, Equatable {
    public let accountId: String
    public let securityId: String
    public let quantity: Decimal
    public let institutionValue: Decimal
    public let costBasis: Decimal?
    public let asOf: Date?

    public init(
        accountId: String,
        securityId: String,
        quantity: Decimal,
        institutionValue: Decimal,
        costBasis: Decimal?,
        asOf: Date?
    ) {
        self.accountId = accountId
        self.securityId = securityId
        self.quantity = quantity
        self.institutionValue = institutionValue
        self.costBasis = costBasis
        self.asOf = asOf
    }

    public var summary: PlaidHolding {
        PlaidHolding(
            accountId: accountId,
            securityId: securityId,
            quantity: quantity,
            institutionValue: Money.dollars(institutionValue),
            costBasis: costBasis.map(Money.dollars),
            asOf: asOf
        )
    }
}

public struct PlaidTransactionsSyncResponseDTO: Codable, Sendable, Equatable {
    public let item: PlaidItemDTO
    public let accounts: [PlaidAccountDTO]
    public let added: [PlaidTransactionDTO]
    public let modified: [PlaidTransactionDTO]
    public let removed: [String]
    public let nextCursor: String
    public let hasMore: Bool
    public let updateStatus: String?

    public init(
        item: PlaidItemDTO,
        accounts: [PlaidAccountDTO],
        added: [PlaidTransactionDTO],
        modified: [PlaidTransactionDTO],
        removed: [String],
        nextCursor: String,
        hasMore: Bool,
        updateStatus: String? = nil
    ) {
        self.item = item
        self.accounts = accounts
        self.added = added
        self.modified = modified
        self.removed = removed
        self.nextCursor = nextCursor
        self.hasMore = hasMore
        self.updateStatus = updateStatus
    }
}

public struct PlaidTransactionDTO: Codable, Sendable, Equatable {
    public let id: String
    public let accountId: String
    public let date: String
    public let authorizedDate: String?
    public let amount: Decimal
    public let pending: Bool
    public let pendingTransactionId: String?
    public let name: String
    public let originalDescription: String?
    public let merchantName: String?
    public let merchantEntityId: String?
    public let counterpartyName: String?
    public let counterpartyType: String?
    public let counterpartyEntityId: String?
    public let counterpartyConfidence: String?
    public let paymentChannel: String?
    public let categoryPrimary: String?
    public let categoryDetailed: String?
    public let categoryConfidence: String?
    public let transactionCode: String?
    public let isoCurrencyCode: String?
    public let unofficialCurrencyCode: String?

    public init(
        id: String,
        accountId: String,
        date: String,
        authorizedDate: String? = nil,
        amount: Decimal,
        pending: Bool = false,
        pendingTransactionId: String? = nil,
        name: String,
        originalDescription: String? = nil,
        merchantName: String? = nil,
        merchantEntityId: String? = nil,
        counterpartyName: String? = nil,
        counterpartyType: String? = nil,
        counterpartyEntityId: String? = nil,
        counterpartyConfidence: String? = nil,
        paymentChannel: String? = nil,
        categoryPrimary: String? = nil,
        categoryDetailed: String? = nil,
        categoryConfidence: String? = nil,
        transactionCode: String? = nil,
        isoCurrencyCode: String? = "USD",
        unofficialCurrencyCode: String? = nil
    ) {
        self.id = id
        self.accountId = accountId
        self.date = date
        self.authorizedDate = authorizedDate
        self.amount = amount
        self.pending = pending
        self.pendingTransactionId = pendingTransactionId
        self.name = name
        self.originalDescription = originalDescription
        self.merchantName = merchantName
        self.merchantEntityId = merchantEntityId
        self.counterpartyName = counterpartyName
        self.counterpartyType = counterpartyType
        self.counterpartyEntityId = counterpartyEntityId
        self.counterpartyConfidence = counterpartyConfidence
        self.paymentChannel = paymentChannel
        self.categoryPrimary = categoryPrimary
        self.categoryDetailed = categoryDetailed
        self.categoryConfidence = categoryConfidence
        self.transactionCode = transactionCode
        self.isoCurrencyCode = isoCurrencyCode
        self.unofficialCurrencyCode = unofficialCurrencyCode
    }

    public func financialSummary(canonicalAccountId: String) -> FinancialTransactionSummary? {
        guard let postedDate = Self.dateFormatter.date(from: date) else { return nil }
        return FinancialTransactionSummary(
            id: "plaid:\(id)",
            externalId: id,
            source: .plaid,
            accountId: canonicalAccountId,
            postedDate: postedDate,
            authorizedDate: authorizedDate.flatMap(Self.dateFormatter.date(from:)),
            amount: -Money.dollars(amount),
            pending: pending,
            pendingTransactionId: pendingTransactionId,
            rawDescription: name,
            originalDescription: originalDescription,
            providerMerchantName: merchantName,
            merchantEntityId: merchantEntityId,
            counterpartyName: counterpartyName,
            counterpartyType: counterpartyType,
            counterpartyEntityId: counterpartyEntityId,
            counterpartyConfidence: counterpartyConfidence,
            paymentChannel: paymentChannel,
            providerCategoryPrimary: categoryPrimary,
            providerCategoryDetailed: categoryDetailed,
            providerCategoryConfidence: categoryConfidence,
            transactionCode: transactionCode
        )
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // Plaid sends civil dates with no time or zone. Anchor to local
        // midnight so device-calendar bucketing and display keep the day
        // the bank reported (UTC midnight renders as the previous day in
        // any timezone west of UTC).
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

public struct PlaidInferenceRequestDTO: Codable, Sendable, Equatable {
    public let rawDescription: String
    public let merchantName: String?
    public let counterpartyName: String?
    public let counterpartyType: String?
    public let paymentChannel: String?
    public let plaidCategoryPrimary: String?
    public let plaidCategoryDetailed: String?
    public let plaidCategoryConfidence: String?
    public let direction: String

    public init(transaction: FinancialTransactionSummary) {
        rawDescription = transaction.rawDescription
        merchantName = transaction.providerMerchantName
        counterpartyName = transaction.counterpartyName
        counterpartyType = transaction.counterpartyType
        paymentChannel = transaction.paymentChannel
        plaidCategoryPrimary = transaction.providerCategoryPrimary
        plaidCategoryDetailed = transaction.providerCategoryDetailed
        plaidCategoryConfidence = transaction.providerCategoryConfidence
        direction = transaction.amount.isNegative ? "outflow" : "inflow"
    }
}

public struct PlaidInferenceResponseDTO: Codable, Sendable, Equatable {
    public let displayName: String
    public let confidence: String

    public init(displayName: String, confidence: String) {
        self.displayName = displayName
        self.confidence = confidence
    }

    public func suggestion(provenance: ClassificationProvenance) -> ModelClassificationSuggestion? {
        guard let confidence = ClassificationConfidence(
            rawValue: confidence
        ) else {
            return nil
        }
        return ModelClassificationSuggestion(
            displayName: displayName,
            confidence: confidence,
            provenance: provenance
        )
    }
}
