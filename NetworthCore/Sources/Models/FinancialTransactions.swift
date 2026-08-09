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

public enum TransactionType: String, Codable, Sendable, CaseIterable {
    case income
    case ordinarySpending
    case internalTransfer
    case cardPayment
    case refund
    /// Money paid on someone else's behalf and expected back. Both the
    /// outflow and its eventual repayment stay outside ordinary Spending.
    case reimbursement
    /// A purchase paid from one explicitly selected goal.
    case goalSpend
    /// Money returned to one explicitly selected goal.
    case goalRefund
    /// Money moved into an investment account. Stays outside every spending
    /// total while remaining distinguishable from generic exclusions.
    /// Additive raw value; persisted fields default elsewhere, so this case
    /// is CloudKit-safe.
    case investmentContribution
    case excluded
    /// An unreadable future/legacy raw value. Unknown values never inherit
    /// ordinary-spending behavior and must be reviewed before use.
    case unknown

    public static let allCases: [TransactionType] = [
        .ordinarySpending,
        .income,
        .refund,
        .reimbursement,
        .goalSpend,
        .goalRefund,
        .internalTransfer,
        .cardPayment,
        .investmentContribution,
        .excluded,
    ]
}

/// Source compatibility while call sites move to the product term. Persisted
/// field names intentionally remain `forecastTreatmentRaw` for CloudKit.
public typealias ForecastTreatment = TransactionType

/// The type-first review contract: which category roles are valid for each
/// transaction type, and which types take no ordinary category at all.
/// Incompatible type/category combinations must never be saved.
public enum TransactionTypeRules {
    /// Nil means the type takes no ordinary category: income and investment
    /// contributions are fully described by the type itself, and transfers/
    /// card payments use an account relationship. Only spending and refunds
    /// need a category.
    public static func allowedCategoryRoles(
        for treatment: ForecastTreatment
    ) -> Set<CategoryReportingRole>? {
        switch treatment {
        case .ordinarySpending, .refund: [.spending]
        case .income, .investmentContribution,
             .internalTransfer, .cardPayment, .reimbursement,
             .goalSpend, .goalRefund, .excluded, .unknown: nil
        }
    }

    public static func requiresCategory(_ treatment: ForecastTreatment) -> Bool {
        allowedCategoryRoles(for: treatment) != nil
    }

    public static func requiresGoal(_ treatment: TransactionType) -> Bool {
        treatment == .goalSpend || treatment == .goalRefund
    }

    public static func isValidAmountSign(
        _ treatment: TransactionType,
        amountMilliunits: Int64
    ) -> Bool {
        switch treatment {
        case .ordinarySpending, .goalSpend:
            amountMilliunits < 0
        case .income, .refund, .goalRefund:
            amountMilliunits > 0
        case .reimbursement, .internalTransfer, .cardPayment,
             .investmentContribution, .excluded:
            amountMilliunits != 0
        case .unknown:
            false
        }
    }

    /// A nil role (category not yet assigned to a Networth-owned group) is
    /// accepted for any category-taking type so review never dead-ends
    /// before groups exist; a known role must match the type.
    public static func isValidCombination(
        treatment: ForecastTreatment,
        categoryRole: CategoryReportingRole?
    ) -> Bool {
        guard let allowed = allowedCategoryRoles(for: treatment) else {
            return categoryRole == nil
        }
        guard let categoryRole else { return true }
        return allowed.contains(categoryRole)
    }
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
    /// User-facing category name from the canonical user directory.
    public let categoryName: String?
    public let treatment: ForecastTreatment
    public let confidence: ClassificationConfidence
    public let provenance: ClassificationProvenance
    public let requiresReview: Bool

    public init(
        displayName: String,
        categoryName: String? = nil,
        treatment: ForecastTreatment,
        confidence: ClassificationConfidence,
        provenance: ClassificationProvenance,
        requiresReview: Bool
    ) {
        self.displayName = displayName
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
    public let categoryName: String?
    public let treatment: ForecastTreatment
    public let categoryReusable: Bool
    public let provenance: ClassificationProvenance
    public let confirmed: Bool

    public init(
        id: UUID = UUID(),
        fingerprint: String,
        preferredName: String,
        categoryName: String? = nil,
        treatment: ForecastTreatment,
        categoryReusable: Bool = true,
        provenance: ClassificationProvenance,
        confirmed: Bool
    ) {
        self.id = id
        self.fingerprint = fingerprint
        self.preferredName = preferredName
        self.categoryName = categoryName
        self.treatment = treatment
        self.categoryReusable = categoryReusable
        self.provenance = provenance
        self.confirmed = confirmed
    }
}

public struct ModelClassificationSuggestion: Hashable, Codable, Sendable {
    public let displayName: String
    public let confidence: ClassificationConfidence
    public let provenance: ClassificationProvenance

    public init(
        displayName: String,
        confidence: ClassificationConfidence,
        provenance: ClassificationProvenance
    ) {
        self.displayName = displayName
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
