import Foundation

public struct ClaudeFinancialSnapshotDTO: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let primarySource: String
    public let accounts: [ClaudeAccountDTO]
    public let manualAssets: [ClaudeManualAssetDTO]
    public let holdings: [ClaudeHoldingDTO]
    public let transactions: [ClaudeTransactionDTO]
    public let netWorthHistory: [ClaudeNetWorthPointDTO]

    public init(
        schemaVersion: Int = 1,
        generatedAt: Date,
        primarySource: String,
        accounts: [ClaudeAccountDTO],
        manualAssets: [ClaudeManualAssetDTO],
        holdings: [ClaudeHoldingDTO],
        transactions: [ClaudeTransactionDTO],
        netWorthHistory: [ClaudeNetWorthPointDTO]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.primarySource = primarySource
        self.accounts = accounts
        self.manualAssets = manualAssets
        self.holdings = holdings
        self.transactions = transactions
        self.netWorthHistory = netWorthHistory
    }
}

public struct ClaudeAccountDTO: Codable, Sendable, Equatable {
    public let name: String
    public let institutionName: String?
    public let type: String
    public let balanceMilliunits: Int64
    public let availableBalanceMilliunits: Int64?
    public let closed: Bool

    public init(
        name: String,
        institutionName: String?,
        type: String,
        balanceMilliunits: Int64,
        availableBalanceMilliunits: Int64?,
        closed: Bool
    ) {
        self.name = name
        self.institutionName = institutionName
        self.type = type
        self.balanceMilliunits = balanceMilliunits
        self.availableBalanceMilliunits = availableBalanceMilliunits
        self.closed = closed
    }
}

public struct ClaudeManualAssetDTO: Codable, Sendable, Equatable {
    public let name: String
    public let groupName: String?
    public let type: String
    public let currentValueMilliunits: Int64
    public let lastUpdatedAt: Date

    public init(
        name: String,
        groupName: String?,
        type: String,
        currentValueMilliunits: Int64,
        lastUpdatedAt: Date
    ) {
        self.name = name
        self.groupName = groupName
        self.type = type
        self.currentValueMilliunits = currentValueMilliunits
        self.lastUpdatedAt = lastUpdatedAt
    }
}

public struct ClaudeHoldingDTO: Codable, Sendable, Equatable {
    public let accountName: String
    public let institutionName: String?
    public let securityName: String
    public let tickerSymbol: String?
    public let securityType: String?
    public let quantity: String
    public let valueMilliunits: Int64
    public let costBasisMilliunits: Int64?
    public let asOf: Date?

    public init(
        accountName: String,
        institutionName: String?,
        securityName: String,
        tickerSymbol: String?,
        securityType: String?,
        quantity: String,
        valueMilliunits: Int64,
        costBasisMilliunits: Int64?,
        asOf: Date?
    ) {
        self.accountName = accountName
        self.institutionName = institutionName
        self.securityName = securityName
        self.tickerSymbol = tickerSymbol
        self.securityType = securityType
        self.quantity = quantity
        self.valueMilliunits = valueMilliunits
        self.costBasisMilliunits = costBasisMilliunits
        self.asOf = asOf
    }
}

public struct ClaudeTransactionDTO: Codable, Sendable, Equatable {
    public let date: Date
    public let accountName: String
    public let contactName: String
    public let categoryName: String?
    public let treatment: String
    public let amountMilliunits: Int64
    public let splits: [ClaudeTransactionSplitDTO]

    public init(
        date: Date,
        accountName: String,
        contactName: String,
        categoryName: String?,
        treatment: String,
        amountMilliunits: Int64,
        splits: [ClaudeTransactionSplitDTO]
    ) {
        self.date = date
        self.accountName = accountName
        self.contactName = contactName
        self.categoryName = categoryName
        self.treatment = treatment
        self.amountMilliunits = amountMilliunits
        self.splits = splits
    }
}

public struct ClaudeTransactionSplitDTO: Codable, Sendable, Equatable {
    public let categoryName: String?
    public let treatment: String?
    public let amountMilliunits: Int64

    public init(
        categoryName: String?,
        treatment: String?,
        amountMilliunits: Int64
    ) {
        self.categoryName = categoryName
        self.treatment = treatment
        self.amountMilliunits = amountMilliunits
    }
}

public struct ClaudeNetWorthPointDTO: Codable, Sendable, Equatable {
    public let date: Date
    public let assetsMilliunits: Int64
    public let liabilitiesMilliunits: Int64

    public init(
        date: Date,
        assetsMilliunits: Int64,
        liabilitiesMilliunits: Int64
    ) {
        self.date = date
        self.assetsMilliunits = assetsMilliunits
        self.liabilitiesMilliunits = liabilitiesMilliunits
    }
}

public struct ClaudeConnectCodeResponseDTO: Codable, Sendable, Equatable {
    public let code: String
    public let expiresAt: Date

    public init(code: String, expiresAt: Date) {
        self.code = code
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case expiresAt = "expires_at"
    }
}
