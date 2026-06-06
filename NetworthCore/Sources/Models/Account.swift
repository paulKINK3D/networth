import Foundation
import Money

/// YNAB-defined account categories. We map all YNAB string types into this enum
/// so the rest of the app never deals with raw strings.
public enum AccountKind: String, Sendable, Hashable, Codable, CaseIterable {
    case checking
    case savings
    case cash
    case creditCard
    case lineOfCredit
    case otherAsset
    case otherLiability
    case mortgage
    case autoLoan
    case studentLoan
    case personalLoan
    case medicalDebt
    case otherDebt
    case investment           // brokerage / 401k / IRA (YNAB has limited support)
    case unknown

    public var isLiability: Bool {
        switch self {
        case .creditCard, .lineOfCredit, .otherLiability, .mortgage,
             .autoLoan, .studentLoan, .personalLoan, .medicalDebt, .otherDebt:
            return true
        case .checking, .savings, .cash, .otherAsset, .investment, .unknown:
            return false
        }
    }

    public var isCreditCardLike: Bool {
        self == .creditCard || self == .lineOfCredit
    }

    public var isCashLike: Bool {
        self == .checking || self == .savings || self == .cash
    }
}

/// A snapshot view of a single YNAB account — pure value type, suitable for
/// passing into the projection engine and unit tests.
public struct AccountSnapshot: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let name: String
    public let kind: AccountKind
    public let balance: Money
    public let clearedBalance: Money
    public let unclearedBalance: Money
    public let onBudget: Bool
    public let closed: Bool
    public let deleted: Bool

    public init(
        id: String,
        name: String,
        kind: AccountKind,
        balance: Money,
        clearedBalance: Money,
        unclearedBalance: Money,
        onBudget: Bool,
        closed: Bool,
        deleted: Bool
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.balance = balance
        self.clearedBalance = clearedBalance
        self.unclearedBalance = unclearedBalance
        self.onBudget = onBudget
        self.closed = closed
        self.deleted = deleted
    }
}
