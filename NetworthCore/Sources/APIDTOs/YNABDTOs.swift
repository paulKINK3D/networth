import Foundation
import Money
import Models

// MARK: - Envelope

public struct YNABEnvelope<T: Decodable & Sendable>: Decodable, Sendable {
    public let data: T
}

public struct YNABErrorPayload: Decodable, Sendable, Error {
    public let id: String
    public let name: String
    public let detail: String
}

public struct YNABErrorEnvelope: Decodable, Sendable {
    public let error: YNABErrorPayload
}

// MARK: - Budgets

public struct YNABBudgetsResponse: Decodable, Sendable {
    public let budgets: [YNABBudgetSummary]
    public let default_budget: YNABBudgetSummary?
}

public struct YNABBudgetSummary: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let last_modified_on: String?
    public let currency_format: YNABCurrencyFormat?
}

public struct YNABCurrencyFormat: Decodable, Sendable, Hashable {
    public let iso_code: String
    public let decimal_digits: Int
    public let decimal_separator: String
    public let group_separator: String
    public let currency_symbol: String
    public let symbol_first: Bool
}

// MARK: - Accounts

public struct YNABAccountsResponse: Decodable, Sendable {
    public let accounts: [YNABAccountDTO]
    public let server_knowledge: Int64?
    public init(accounts: [YNABAccountDTO] = [], server_knowledge: Int64? = nil) {
        self.accounts = accounts
        self.server_knowledge = server_knowledge
    }
}

public struct YNABAccountDTO: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let type: String
    public let on_budget: Bool
    public let closed: Bool
    public let note: String?
    public let balance: Int64
    public let cleared_balance: Int64
    public let uncleared_balance: Int64
    public let deleted: Bool

    public func toSnapshot() -> AccountSnapshot {
        AccountSnapshot(
            id: id,
            name: name,
            kind: AccountKind.fromYNAB(type),
            balance: Money(milliunits: balance),
            clearedBalance: Money(milliunits: cleared_balance),
            unclearedBalance: Money(milliunits: uncleared_balance),
            onBudget: on_budget,
            closed: closed,
            deleted: deleted
        )
    }
}

extension AccountKind {
    public static func fromYNAB(_ raw: String) -> AccountKind {
        switch raw {
        case "checking":             return .checking
        case "savings":              return .savings
        case "cash":                 return .cash
        case "creditCard":           return .creditCard
        case "lineOfCredit":         return .lineOfCredit
        case "otherAsset":           return .otherAsset
        case "otherLiability":       return .otherLiability
        case "mortgage":             return .mortgage
        case "autoLoan":             return .autoLoan
        case "studentLoan":          return .studentLoan
        case "personalLoan":         return .personalLoan
        case "medicalDebt":          return .medicalDebt
        case "otherDebt":            return .otherDebt
        default:                     return .unknown
        }
    }
}

// MARK: - Transactions

public struct YNABTransactionsResponse: Decodable, Sendable {
    public let transactions: [YNABTransactionDTO]
    public let server_knowledge: Int64?
    public init(transactions: [YNABTransactionDTO] = [], server_knowledge: Int64? = nil) {
        self.transactions = transactions
        self.server_knowledge = server_knowledge
    }
}

public struct YNABTransactionDTO: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let date: String
    public let amount: Int64
    public let cleared: String
    public let approved: Bool
    public let account_id: String
    public let payee_name: String?
    public let category_id: String?
    public let category_name: String?
    public let transfer_account_id: String?
    public let memo: String?
    public let deleted: Bool
    public let subtransactions: [YNABSubTransactionDTO]?

    public func toSummary() -> TransactionSummary? {
        guard let parsed = Self.dateParser.date(from: date) else { return nil }
        let subs = (subtransactions ?? []).map { $0.toSummary() }
        return TransactionSummary(
            id: id,
            accountId: account_id,
            date: parsed,
            amount: Money(milliunits: amount),
            cleared: cleared == "cleared" || cleared == "reconciled",
            approved: approved,
            payeeName: payee_name,
            categoryId: category_id,
            categoryName: category_name,
            transferAccountId: transfer_account_id,
            memo: memo,
            deleted: deleted,
            subtransactions: subs
        )
    }

    public static let dateParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

public struct YNABSubTransactionDTO: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let transaction_id: String
    public let amount: Int64
    public let category_id: String?
    public let category_name: String?
    public let transfer_account_id: String?
    public let payee_name: String?
    public let memo: String?
    public let deleted: Bool

    public func toSummary() -> SubTransactionSummary {
        SubTransactionSummary(
            id: id,
            amount: Money(milliunits: amount),
            categoryId: category_id,
            categoryName: category_name,
            transferAccountId: transfer_account_id,
            payeeName: payee_name,
            memo: memo,
            deleted: deleted
        )
    }
}

// MARK: - Categories

public struct YNABCategoriesResponse: Decodable, Sendable {
    public let category_groups: [YNABCategoryGroupDTO]
    public let server_knowledge: Int64?
    public init(category_groups: [YNABCategoryGroupDTO] = [], server_knowledge: Int64? = nil) {
        self.category_groups = category_groups
        self.server_knowledge = server_knowledge
    }
}

public struct YNABCategoryGroupDTO: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let hidden: Bool
    public let deleted: Bool
    public let categories: [YNABCategoryDTO]
}

public struct YNABCategoryDTO: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let category_group_id: String
    public let name: String
    public let hidden: Bool
    public let deleted: Bool
}

// MARK: - Scheduled transactions

public struct YNABScheduledTransactionsResponse: Decodable, Sendable {
    public let scheduled_transactions: [YNABScheduledTransactionDTO]
    public let server_knowledge: Int64?
    public init(scheduled_transactions: [YNABScheduledTransactionDTO] = [], server_knowledge: Int64? = nil) {
        self.scheduled_transactions = scheduled_transactions
        self.server_knowledge = server_knowledge
    }
}

public struct YNABScheduledTransactionDTO: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let date_first: String
    public let date_next: String
    public let frequency: String
    public let amount: Int64
    public let account_id: String
    public let payee_name: String?
    public let category_id: String?
    public let transfer_account_id: String?
    public let memo: String?
    public let deleted: Bool

    public func toSummary() -> ScheduledTransactionSummary? {
        guard let parsed = YNABTransactionDTO.dateParser.date(from: date_next) else { return nil }
        return ScheduledTransactionSummary(
            id: id,
            accountId: account_id,
            nextDate: parsed,
            frequency: ScheduleFrequency.fromYNAB(frequency),
            amount: Money(milliunits: amount),
            payeeName: payee_name,
            categoryId: category_id,
            transferAccountId: transfer_account_id,
            memo: memo,
            deleted: deleted
        )
    }
}

extension ScheduleFrequency {
    public static func fromYNAB(_ raw: String) -> ScheduleFrequency {
        switch raw {
        case "never":           return .never
        case "daily":           return .daily
        case "weekly":          return .weekly
        case "everyOtherWeek":  return .everyOtherWeek
        case "twiceAMonth":     return .twiceAMonth
        case "every4Weeks":     return .every4Weeks
        case "monthly":         return .monthly
        case "everyOtherMonth": return .everyOtherMonth
        case "every3Months":    return .every3Months
        case "every4Months":    return .every4Months
        case "twiceAYear":      return .twiceAYear
        case "yearly":          return .yearly
        case "everyOtherYear":  return .everyOtherYear
        default:                return .never
        }
    }
}
