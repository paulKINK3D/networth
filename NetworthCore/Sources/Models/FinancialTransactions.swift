import Foundation
import Money

public enum FinancialDataSource: String, Codable, Sendable, CaseIterable {
    case ynab
    case plaid
}

/// How a category group participates in reports. Spending groups feed
/// Spending History totals; income, investment, and transfer groups keep
/// their activity out of spending while remaining visible in history.
public enum CategoryReportingRole: String, Codable, Sendable, CaseIterable, Identifiable {
    case spending
    case income
    case investment
    case transfer

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .spending: "Spending"
        case .income: "Income"
        case .investment: "Investment"
        case .transfer: "Transfer"
        }
    }
}

public enum FinancialAccountType: String, Codable, Sendable, CaseIterable {
    case checking
    case savings
    case creditCard
    case cash
    case investment
    case loan
    case other

    public var isCashLike: Bool {
        self == .checking || self == .savings || self == .cash
    }
}

public enum NativeTransactionCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case income
    case reimbursements
    case housing
    case utilities
    case groceries
    case dining
    case transportation
    case health
    case insurance
    case shopping
    case personalCare
    case entertainment
    case subscriptions
    case travel
    case education
    case familyAndPets
    case taxes
    case feesAndInterest
    case giftsAndDonations
    case other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .income: "Income"
        case .reimbursements: "Reimbursements"
        case .housing: "Housing"
        case .utilities: "Utilities"
        case .groceries: "Groceries"
        case .dining: "Dining"
        case .transportation: "Transportation"
        case .health: "Health"
        case .insurance: "Insurance"
        case .shopping: "Shopping"
        case .personalCare: "Personal Care"
        case .entertainment: "Entertainment"
        case .subscriptions: "Subscriptions"
        case .travel: "Travel"
        case .education: "Education"
        case .familyAndPets: "Family & Pets"
        case .taxes: "Taxes"
        case .feesAndInterest: "Fees & Interest"
        case .giftsAndDonations: "Gifts & Donations"
        case .other: "Other"
        }
    }
}

public enum ForecastTreatment: String, Codable, Sendable, CaseIterable {
    case income
    case ordinarySpending
    case internalTransfer
    case cardPayment
    case refund
    case excluded
}

public enum ClassificationConfidence: String, Codable, Sendable, Comparable {
    case low
    case medium
    case high

    private var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }
}

public enum ClassificationProvenance: String, Codable, Sendable {
    case user
    case confirmedRule
    case historicalMatch
    case plaidEnrichment
    case appleModel
    case claude
}

public struct FinancialAccountSummary: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let externalId: String
    public let itemId: String?
    public let source: FinancialDataSource
    public let institutionName: String?
    public let name: String
    public let officialName: String?
    public let mask: String?
    public let type: FinancialAccountType
    public let subtype: String?
    public let currentBalance: Money?
    public let availableBalance: Money?
    public let creditLimit: Money?
    public let isoCurrencyCode: String?

    public init(
        id: String,
        externalId: String,
        itemId: String?,
        source: FinancialDataSource,
        institutionName: String?,
        name: String,
        officialName: String?,
        mask: String?,
        type: FinancialAccountType,
        subtype: String?,
        currentBalance: Money?,
        availableBalance: Money?,
        creditLimit: Money?,
        isoCurrencyCode: String?
    ) {
        self.id = id
        self.externalId = externalId
        self.itemId = itemId
        self.source = source
        self.institutionName = institutionName
        self.name = name
        self.officialName = officialName
        self.mask = mask
        self.type = type
        self.subtype = subtype
        self.currentBalance = currentBalance
        self.availableBalance = availableBalance
        self.creditLimit = creditLimit
        self.isoCurrencyCode = isoCurrencyCode
    }
}

public struct FinancialTransactionSummary: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let externalId: String
    public let source: FinancialDataSource
    public let accountId: String
    public let postedDate: Date
    public let authorizedDate: Date?
    /// Networth convention: inflow is positive, outflow is negative.
    public let amount: Money
    public let pending: Bool
    public let pendingTransactionId: String?
    public let rawDescription: String
    public let originalDescription: String?
    public let providerMerchantName: String?
    public let merchantEntityId: String?
    public let counterpartyName: String?
    public let counterpartyType: String?
    public let counterpartyEntityId: String?
    public let counterpartyConfidence: String?
    public let paymentChannel: String?
    public let providerCategoryPrimary: String?
    public let providerCategoryDetailed: String?
    public let providerCategoryConfidence: String?
    public let transactionCode: String?

    public init(
        id: String,
        externalId: String,
        source: FinancialDataSource,
        accountId: String,
        postedDate: Date,
        authorizedDate: Date?,
        amount: Money,
        pending: Bool,
        pendingTransactionId: String?,
        rawDescription: String,
        originalDescription: String?,
        providerMerchantName: String?,
        merchantEntityId: String?,
        counterpartyName: String?,
        counterpartyType: String?,
        counterpartyEntityId: String?,
        counterpartyConfidence: String?,
        paymentChannel: String?,
        providerCategoryPrimary: String?,
        providerCategoryDetailed: String?,
        providerCategoryConfidence: String?,
        transactionCode: String?
    ) {
        self.id = id
        self.externalId = externalId
        self.source = source
        self.accountId = accountId
        self.postedDate = postedDate
        self.authorizedDate = authorizedDate
        self.amount = amount
        self.pending = pending
        self.pendingTransactionId = pendingTransactionId
        self.rawDescription = rawDescription
        self.originalDescription = originalDescription
        self.providerMerchantName = providerMerchantName
        self.merchantEntityId = merchantEntityId
        self.counterpartyName = counterpartyName
        self.counterpartyType = counterpartyType
        self.counterpartyEntityId = counterpartyEntityId
        self.counterpartyConfidence = counterpartyConfidence
        self.paymentChannel = paymentChannel
        self.providerCategoryPrimary = providerCategoryPrimary
        self.providerCategoryDetailed = providerCategoryDetailed
        self.providerCategoryConfidence = providerCategoryConfidence
        self.transactionCode = transactionCode
    }

    public var fallbackDisplayName: String {
        providerMerchantName?.nonemptyTrimmed
            ?? counterpartyName?.nonemptyTrimmed
            ?? rawDescription.nonemptyTrimmed
            ?? "Unknown"
    }

    public var merchantFingerprint: String {
        if let merchantEntityId = merchantEntityId?.nonemptyTrimmed {
            return "merchant:\(merchantEntityId.lowercased())"
        }
        if let counterpartyEntityId = counterpartyEntityId?.nonemptyTrimmed {
            return "counterparty:\(counterpartyEntityId.lowercased())"
        }
        return "description:\(Self.normalizedDescription(originalDescription ?? rawDescription))"
    }

    /// Independent pieces of identity evidence. These keys may resolve to one
    /// canonical payee, but no individual key is itself the payee record.
    public var payeeIdentityEvidence: [PayeeIdentityEvidence] {
        var result: [PayeeIdentityEvidence] = []
        if let merchantEntityId = merchantEntityId?.nonemptyTrimmed {
            result.append(PayeeIdentityEvidence(
                key: "plaid-merchant:\(merchantEntityId.lowercased())",
                kind: "merchantEntity",
                displayValue: providerMerchantName?.nonemptyTrimmed
                    ?? fallbackDisplayName
            ))
        }
        if let counterpartyEntityId = counterpartyEntityId?.nonemptyTrimmed {
            result.append(PayeeIdentityEvidence(
                key: "plaid-counterparty:\(counterpartyEntityId.lowercased())",
                kind: "counterpartyEntity",
                displayValue: counterpartyName?.nonemptyTrimmed
                    ?? fallbackDisplayName
            ))
        }
        appendNameEvidence(
            providerMerchantName,
            kind: "merchantName",
            prefix: "plaid-merchant-name",
            to: &result
        )
        appendNameEvidence(
            counterpartyName,
            kind: "counterpartyName",
            prefix: "plaid-counterparty-name:\(counterpartyType?.lowercased() ?? "unknown")",
            to: &result
        )
        let description = Self.normalizedDescription(
            originalDescription ?? rawDescription
        )
        if Self.isSpecificIdentityText(description) {
            result.append(PayeeIdentityEvidence(
                key: "plaid-description:\(description)",
                kind: "description",
                displayValue: originalDescription?.nonemptyTrimmed
                    ?? rawDescription
            ))
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.key).inserted }
    }

    public static func normalizedDescription(_ value: String) -> String {
        let normalized = String(
            value
                .lowercased()
                .unicodeScalars
                .map { CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : " " }
        )
            .split(whereSeparator: \.isWhitespace)
            .filter { !isVolatileReferenceToken($0) }
            .joined(separator: " ")
        return normalized
    }

    /// Conservative contact lookup for institution variants such as
    /// "Gusto" and "Gusto Payroll". Matching is symmetric, requires a full
    /// token boundary, and is safe only when the caller finds one canonical
    /// contact across the complete directory.
    public static func namesReferToSamePayee(
        _ lhs: String,
        _ rhs: String
    ) -> Bool {
        let left = normalizedDescription(lhs)
        let right = normalizedDescription(rhs)
        guard isSpecificIdentityText(left),
              isSpecificIdentityText(right) else {
            return false
        }
        if left == right { return true }
        let shorter = left.count <= right.count ? left : right
        let longer = left.count <= right.count ? right : left
        return shorter.count >= 5
            && longer.hasPrefix("\(shorter) ")
    }

    private static func isVolatileReferenceToken(
        _ token: Substring
    ) -> Bool {
        var consecutiveDigits = 0
        var digitCount = 0
        var maskedCharacterCount = 0

        for character in token {
            if character.isNumber {
                digitCount += 1
                consecutiveDigits += 1
                if consecutiveDigits >= 5 {
                    return true
                }
            } else {
                consecutiveDigits = 0
                if character == "x" {
                    maskedCharacterCount += 1
                }
            }
        }

        // Banks commonly embed masked account/reference values such as
        // XXXXX36151. The value changes while the merchant does not.
        return maskedCharacterCount >= 3 && digitCount >= 4
    }

    private func appendNameEvidence(
        _ value: String?,
        kind: String,
        prefix: String,
        to result: inout [PayeeIdentityEvidence]
    ) {
        guard let value = value?.nonemptyTrimmed else { return }
        let normalized = Self.normalizedDescription(value)
        guard Self.isSpecificIdentityText(normalized) else { return }
        result.append(PayeeIdentityEvidence(
            key: "\(prefix):\(normalized)",
            kind: kind,
            displayValue: value
        ))
    }

    public static func isSpecificIdentityText(_ value: String) -> Bool {
        let generic: Set<String> = [
            "", "unknown", "transaction", "payment", "transfer",
            "purchase", "debit", "credit", "deposit", "withdrawal",
            "check", "ach"
        ]
        return !generic.contains(value)
    }
}

public struct PayeeIdentityEvidence: Hashable, Codable, Sendable {
    public let key: String
    public let kind: String
    public let displayValue: String

    public init(key: String, kind: String, displayValue: String) {
        self.key = key
        self.kind = kind
        self.displayValue = displayValue
    }
}

public struct TransactionClassification: Hashable, Codable, Sendable {
    public let displayName: String
    public let category: NativeTransactionCategory
    /// User-facing category name. This may preserve a detailed legacy or
    /// user-created category while `category` remains the broad internal type.
    public let categoryName: String?
    public let treatment: ForecastTreatment
    public let confidence: ClassificationConfidence
    public let provenance: ClassificationProvenance
    public let requiresReview: Bool

    public init(
        displayName: String,
        category: NativeTransactionCategory,
        categoryName: String? = nil,
        treatment: ForecastTreatment,
        confidence: ClassificationConfidence,
        provenance: ClassificationProvenance,
        requiresReview: Bool
    ) {
        self.displayName = displayName
        self.category = category
        self.categoryName = categoryName
        self.treatment = treatment
        self.confidence = confidence
        self.provenance = provenance
        self.requiresReview = requiresReview
    }
}

public struct MerchantClassificationRule: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let fingerprint: String
    public let preferredName: String
    public let category: NativeTransactionCategory
    public let categoryName: String?
    public let treatment: ForecastTreatment
    public let categoryReusable: Bool
    public let provenance: ClassificationProvenance
    public let confirmed: Bool

    public init(
        id: UUID = UUID(),
        fingerprint: String,
        preferredName: String,
        category: NativeTransactionCategory,
        categoryName: String? = nil,
        treatment: ForecastTreatment,
        categoryReusable: Bool = true,
        provenance: ClassificationProvenance,
        confirmed: Bool
    ) {
        self.id = id
        self.fingerprint = fingerprint
        self.preferredName = preferredName
        self.category = category
        self.categoryName = categoryName
        self.treatment = treatment
        self.categoryReusable = categoryReusable
        self.provenance = provenance
        self.confirmed = confirmed
    }
}

public struct ModelClassificationSuggestion: Hashable, Codable, Sendable {
    public let displayName: String
    public let category: NativeTransactionCategory
    public let confidence: ClassificationConfidence
    public let provenance: ClassificationProvenance

    public init(
        displayName: String,
        category: NativeTransactionCategory,
        confidence: ClassificationConfidence,
        provenance: ClassificationProvenance
    ) {
        self.displayName = displayName
        self.category = category
        self.confidence = confidence
        self.provenance = provenance
    }
}

private extension String {
    var nonemptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
