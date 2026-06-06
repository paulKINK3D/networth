import Foundation
import os
import NetworthCore

public enum YNABClientError: Error, Sendable {
    case missingToken
    case invalidResponse(statusCode: Int, body: String)
    case rateLimited
    case unauthorized
    case decoding(Error)
    case transport(Error)
    case cancelled
}

public struct YNABRateLimitInfo: Sendable, Equatable {
    public let used: Int
    public let limit: Int
    public init(used: Int, limit: Int) { self.used = used; self.limit = limit }
}

/// Read-only YNAB v1 client. **Do not add write endpoints in v1.**
/// Actor-isolated so the token and rate-limit counters are safe to read concurrently.
public protocol YNABClient: Actor {
    func setToken(_ token: String?)
    func budgets() async throws -> [YNABBudgetSummary]
    func accounts(budgetId: String, lastKnowledge: Int64?) async throws -> YNABAccountsResponse
    func transactions(budgetId: String, accountId: String?, sinceDate: Date?, lastKnowledge: Int64?) async throws -> YNABTransactionsResponse
    func scheduledTransactions(budgetId: String, lastKnowledge: Int64?) async throws -> YNABScheduledTransactionsResponse
    func rateLimit() -> YNABRateLimitInfo?
}

public actor LiveYNABClient: YNABClient {
    private let baseURL = URL(string: "https://api.ynab.com/v1")!
    private let session: URLSession
    private var token: String?
    private var lastRate: YNABRateLimitInfo?
    private let logger = Logger(subsystem: "com.bluelava.me.networth", category: "ynab-client")
    private let decoder: JSONDecoder = JSONDecoder()

    public init(session: URLSession = .shared, token: String? = nil) {
        self.session = session
        self.token = token
    }

    public func setToken(_ token: String?) { self.token = token }
    public func rateLimit() -> YNABRateLimitInfo? { lastRate }

    public func budgets() async throws -> [YNABBudgetSummary] {
        let env: YNABEnvelope<YNABBudgetsResponse> = try await get("/budgets")
        return env.data.budgets
    }

    public func accounts(budgetId: String, lastKnowledge: Int64?) async throws -> YNABAccountsResponse {
        var path = "/budgets/\(budgetId)/accounts"
        if let k = lastKnowledge { path += "?last_knowledge_of_server=\(k)" }
        let env: YNABEnvelope<YNABAccountsResponse> = try await get(path)
        return env.data
    }

    public func transactions(budgetId: String, accountId: String?, sinceDate: Date?, lastKnowledge: Int64?) async throws -> YNABTransactionsResponse {
        var components = URLComponents()
        if let accountId {
            components.path = "/budgets/\(budgetId)/accounts/\(accountId)/transactions"
        } else {
            components.path = "/budgets/\(budgetId)/transactions"
        }
        var items: [URLQueryItem] = []
        if let sinceDate {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = TimeZone(identifier: "UTC")
            items.append(URLQueryItem(name: "since_date", value: f.string(from: sinceDate)))
        }
        if let k = lastKnowledge {
            items.append(URLQueryItem(name: "last_knowledge_of_server", value: String(k)))
        }
        components.queryItems = items.isEmpty ? nil : items
        let path = components.url?.absoluteString ?? components.path
        let env: YNABEnvelope<YNABTransactionsResponse> = try await get(path)
        return env.data
    }

    public func scheduledTransactions(budgetId: String, lastKnowledge: Int64?) async throws -> YNABScheduledTransactionsResponse {
        var path = "/budgets/\(budgetId)/scheduled_transactions"
        if let k = lastKnowledge { path += "?last_knowledge_of_server=\(k)" }
        let env: YNABEnvelope<YNABScheduledTransactionsResponse> = try await get(path)
        return env.data
    }

    private func get<T: Decodable & Sendable>(_ path: String) async throws -> T {
        guard let token, !token.isEmpty else { throw YNABClientError.missingToken }
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw YNABClientError.invalidResponse(statusCode: 0, body: "bad URL: \(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw YNABClientError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw YNABClientError.invalidResponse(statusCode: 0, body: "non-HTTP response")
        }

        if let rateHeader = http.value(forHTTPHeaderField: "X-Rate-Limit") {
            let parts = rateHeader.split(separator: "/")
            if parts.count == 2, let used = Int(parts[0]), let limit = Int(parts[1]) {
                lastRate = YNABRateLimitInfo(used: used, limit: limit)
            }
        }

        switch http.statusCode {
        case 200..<300:
            do { return try decoder.decode(T.self, from: data) }
            catch { throw YNABClientError.decoding(error) }
        case 401:
            throw YNABClientError.unauthorized
        case 429:
            throw YNABClientError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw YNABClientError.invalidResponse(statusCode: http.statusCode, body: body)
        }
    }
}

/// Fake client for previews and tests — returns canned responses.
public actor RecordedYNABClient: YNABClient {
    public var budgetsResult: [YNABBudgetSummary]
    public var accountsResult: YNABAccountsResponse
    public var transactionsResult: YNABTransactionsResponse
    public var scheduledResult: YNABScheduledTransactionsResponse
    private var token: String?

    public init(
        budgets: [YNABBudgetSummary] = [],
        accounts: YNABAccountsResponse = .init(accounts: [], server_knowledge: 0),
        transactions: YNABTransactionsResponse = .init(transactions: [], server_knowledge: 0),
        scheduled: YNABScheduledTransactionsResponse = .init(scheduled_transactions: [], server_knowledge: 0)
    ) {
        self.budgetsResult = budgets
        self.accountsResult = accounts
        self.transactionsResult = transactions
        self.scheduledResult = scheduled
    }

    public func setToken(_ token: String?) { self.token = token }
    public func rateLimit() -> YNABRateLimitInfo? { YNABRateLimitInfo(used: 0, limit: 200) }
    public func budgets() async throws -> [YNABBudgetSummary] { budgetsResult }
    public func accounts(budgetId: String, lastKnowledge: Int64?) async throws -> YNABAccountsResponse { accountsResult }
    public func transactions(budgetId: String, accountId: String?, sinceDate: Date?, lastKnowledge: Int64?) async throws -> YNABTransactionsResponse { transactionsResult }
    public func scheduledTransactions(budgetId: String, lastKnowledge: Int64?) async throws -> YNABScheduledTransactionsResponse { scheduledResult }
}
