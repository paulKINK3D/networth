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

    public init(id: String, institutionName: String, status: String, lastSyncedAt: Date?) {
        self.id = id
        self.institutionName = institutionName
        self.status = status
        self.lastSyncedAt = lastSyncedAt
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
    public let subtype: String?
    public let currentBalance: Decimal?
    public let availableBalance: Decimal?
    public let isoCurrencyCode: String?
    public let unofficialCurrencyCode: String?

    public init(
        id: String,
        itemId: String,
        institutionName: String,
        name: String,
        officialName: String?,
        mask: String?,
        subtype: String?,
        currentBalance: Decimal?,
        availableBalance: Decimal?,
        isoCurrencyCode: String?,
        unofficialCurrencyCode: String?
    ) {
        self.id = id
        self.itemId = itemId
        self.institutionName = institutionName
        self.name = name
        self.officialName = officialName
        self.mask = mask
        self.subtype = subtype
        self.currentBalance = currentBalance
        self.availableBalance = availableBalance
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
