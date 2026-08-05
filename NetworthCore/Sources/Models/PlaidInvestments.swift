import Foundation
import Money

public enum PlaidAccountTreatment: String, Codable, Sendable, CaseIterable {
    case pendingReview
    case included
    case duplicateYNAB
    case duplicateManualAsset
    case excluded

    public var contributesToNetWorth: Bool { self == .included }
}

/// Splits retirement accounts out of the general Investments bucket using
/// Plaid's account subtype taxonomy.
public enum PlaidRetirementClassifier {
    private static let retirementSubtypes: Set<String> = [
        "401a", "401k", "403b", "457b", "ira", "roth", "roth 401k",
        "sep ira", "simple ira", "sarsep", "keogh", "pension",
        "profit sharing plan", "retirement", "thrift savings plan",
        "rrsp", "rrif", "lira", "lrsp", "lrif", "lif", "prif", "sipp"
    ]

    public static func isRetirement(subtype: String?) -> Bool {
        guard let subtype else { return false }
        return retirementSubtypes.contains(
            subtype.lowercased().trimmingCharacters(in: .whitespaces)
        )
    }
}

public struct PlaidInvestmentItem: Identifiable, Hashable, Codable, Sendable {
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
}

public struct PlaidInvestmentAccount: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let itemId: String
    public let institutionName: String
    public let name: String
    public let officialName: String?
    public let mask: String?
    public let subtype: String?
    public let currentBalance: Money?
    public let availableBalance: Money?
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
        currentBalance: Money?,
        availableBalance: Money?,
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

    public var usesSupportedCurrency: Bool {
        unofficialCurrencyCode == nil && isoCurrencyCode?.uppercased() == "USD"
    }
}

public struct PlaidSecurity: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String?
    public let tickerSymbol: String?
    public let type: String?
    public let closePrice: Money?
    public let closePriceAsOf: Date?
    public let isoCurrencyCode: String?
    public let unofficialCurrencyCode: String?

    public init(
        id: String,
        name: String?,
        tickerSymbol: String?,
        type: String?,
        closePrice: Money?,
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
}

public struct PlaidHolding: Identifiable, Hashable, Codable, Sendable {
    public let accountId: String
    public let securityId: String
    public let quantity: Decimal
    public let institutionValue: Money
    public let costBasis: Money?
    public let asOf: Date?

    public var id: String { "\(accountId):\(securityId)" }

    public init(
        accountId: String,
        securityId: String,
        quantity: Decimal,
        institutionValue: Money,
        costBasis: Money?,
        asOf: Date?
    ) {
        self.accountId = accountId
        self.securityId = securityId
        self.quantity = quantity
        self.institutionValue = institutionValue
        self.costBasis = costBasis
        self.asOf = asOf
    }
}

public struct PlaidAccountReconciliation: Hashable, Sendable {
    public let accountBalance: Money
    public let holdingsValue: Money
    public let residual: Money

    public init(accountBalance: Money, holdingsValue: Money) {
        self.accountBalance = accountBalance
        self.holdingsValue = holdingsValue
        self.residual = accountBalance - holdingsValue
    }
}

public struct PlaidInvestmentSnapshot: Hashable, Sendable {
    public let items: [PlaidInvestmentItem]
    public let accounts: [PlaidInvestmentAccount]
    public let securities: [PlaidSecurity]
    public let holdings: [PlaidHolding]

    public init(
        items: [PlaidInvestmentItem],
        accounts: [PlaidInvestmentAccount],
        securities: [PlaidSecurity],
        holdings: [PlaidHolding]
    ) {
        self.items = items
        self.accounts = accounts
        self.securities = securities
        self.holdings = holdings
    }

    public func reconciliation(for accountId: String) -> PlaidAccountReconciliation? {
        guard let account = accounts.first(where: { $0.id == accountId }),
              account.usesSupportedCurrency,
              let balance = account.currentBalance else {
            return nil
        }
        let holdingsValue = holdings
            .filter { $0.accountId == accountId }
            .map(\.institutionValue)
            .sum()
        return PlaidAccountReconciliation(
            accountBalance: balance,
            holdingsValue: holdingsValue
        )
    }

    public func netWorthContribution(
        treatments: [String: PlaidAccountTreatment]
    ) -> Money {
        accounts.compactMap { account in
            guard treatments[account.id] == .included,
                  account.usesSupportedCurrency else {
                return nil
            }
            return account.currentBalance
        }.sum()
    }
}
