import Foundation
import FoundationModels
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
    func payees(budgetId: String, lastKnowledge: Int64?) async throws -> YNABPayeesResponse
    func categories(budgetId: String, lastKnowledge: Int64?) async throws -> YNABCategoriesResponse
    func transactions(budgetId: String, accountId: String?, sinceDate: Date?, lastKnowledge: Int64?) async throws -> YNABTransactionsResponse
    func scheduledTransactions(budgetId: String, lastKnowledge: Int64?) async throws -> YNABScheduledTransactionsResponse
    /// Per-category budgeted/activity/balance for one month. `month` is a
    /// first-of-month date string ("2026-08-01") or "current". Read-only.
    func monthDetail(budgetId: String, month: String) async throws -> YNABMonthDetailDTO
    func rateLimit() -> YNABRateLimitInfo?
}

public actor LiveYNABClient: YNABClient {
    private let baseURL = URL(string: "https://api.ynab.com/v1")!
    private let session: URLSession
    private var token: String?
    private var lastRate: YNABRateLimitInfo?
    private var lastRateObservedAt: Date?
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

    public func payees(
        budgetId: String,
        lastKnowledge: Int64?
    ) async throws -> YNABPayeesResponse {
        var path = "/budgets/\(budgetId)/payees"
        if let lastKnowledge {
            path += "?last_knowledge_of_server=\(lastKnowledge)"
        }
        let envelope: YNABEnvelope<YNABPayeesResponse> = try await get(path)
        return envelope.data
    }

    public func categories(budgetId: String, lastKnowledge: Int64?) async throws -> YNABCategoriesResponse {
        var path = "/budgets/\(budgetId)/categories"
        if let k = lastKnowledge { path += "?last_knowledge_of_server=\(k)" }
        let env: YNABEnvelope<YNABCategoriesResponse> = try await get(path)
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
            // Match the local-midnight anchoring used when parsing YNAB
            // civil dates so the inclusive lower bound covers the same day.
            f.timeZone = .current
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

    public func monthDetail(budgetId: String, month: String) async throws -> YNABMonthDetailDTO {
        let env: YNABEnvelope<YNABMonthDetailResponse> = try await get(
            "/budgets/\(budgetId)/months/\(month)"
        )
        return env.data.month
    }

    /// How close we let the rolling counter get to YNAB's stated limit before
    /// proactively refusing requests. YNAB allows 200/hour; we stop at 195 so
    /// a runaway burst (e.g. repeated force-resyncs) can't fully exhaust the
    /// quota and lock the user out of legitimate syncs.
    private static let rateLimitSafetyMargin: Int = 5

    /// How long the throttle stays engaged before we let a probe request
    /// through to refresh `lastRate`. YNAB's window is rolling-hour, so 60s
    /// is enough for several slots to fall off and prevents us from getting
    /// stuck refusing forever based on a single old observation.
    private static let rateLimitCooldownSeconds: TimeInterval = 60

    private func get<T: Decodable & Sendable>(_ path: String) async throws -> T {
        guard let token, !token.isEmpty else { throw YNABClientError.missingToken }

        // Proactive throttle: if the last response showed us near the limit
        // AND that observation is still fresh, refuse before issuing another
        // request. After the cooldown, a probe is allowed through so the
        // rolling-hour window can naturally recover without an app restart.
        if let rate = lastRate, let observed = lastRateObservedAt,
           rate.used >= rate.limit - Self.rateLimitSafetyMargin,
           Date.now.timeIntervalSince(observed) < Self.rateLimitCooldownSeconds {
            throw YNABClientError.rateLimited
        }

        // Concatenate explicitly: URL(string:relativeTo:) drops baseURL's path
        // segment when the relative ref starts with "/", which routes calls to
        // api.ynab.com/budgets instead of api.ynab.com/v1/budgets.
        guard let url = URL(string: baseURL.absoluteString + path) else {
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
                lastRateObservedAt = Date.now
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
    public var payeesResult: YNABPayeesResponse
    public var categoriesResult: YNABCategoriesResponse
    public var transactionsResult: YNABTransactionsResponse
    public var scheduledResult: YNABScheduledTransactionsResponse
    private var token: String?
    public private(set) var budgetsCallCount: Int = 0

    public init(
        budgets: [YNABBudgetSummary] = [],
        accounts: YNABAccountsResponse = .init(accounts: [], server_knowledge: 0),
        payees: YNABPayeesResponse = .init(payees: [], server_knowledge: 0),
        categories: YNABCategoriesResponse = .init(category_groups: [], server_knowledge: 0),
        transactions: YNABTransactionsResponse = .init(transactions: [], server_knowledge: 0),
        scheduled: YNABScheduledTransactionsResponse = .init(scheduled_transactions: [], server_knowledge: 0)
    ) {
        self.budgetsResult = budgets
        self.accountsResult = accounts
        self.payeesResult = payees
        self.categoriesResult = categories
        self.transactionsResult = transactions
        self.scheduledResult = scheduled
    }

    public func setToken(_ token: String?) { self.token = token }
    public func rateLimit() -> YNABRateLimitInfo? { YNABRateLimitInfo(used: 0, limit: 200) }
    public func budgets() async throws -> [YNABBudgetSummary] {
        budgetsCallCount += 1
        return budgetsResult
    }
    public func accounts(budgetId: String, lastKnowledge: Int64?) async throws -> YNABAccountsResponse { accountsResult }
    public func payees(budgetId: String, lastKnowledge: Int64?) async throws -> YNABPayeesResponse { payeesResult }
    public func categories(budgetId: String, lastKnowledge: Int64?) async throws -> YNABCategoriesResponse { categoriesResult }
    public func transactions(budgetId: String, accountId: String?, sinceDate: Date?, lastKnowledge: Int64?) async throws -> YNABTransactionsResponse { transactionsResult }
    public func scheduledTransactions(budgetId: String, lastKnowledge: Int64?) async throws -> YNABScheduledTransactionsResponse { scheduledResult }
    public func monthDetail(budgetId: String, month: String) async throws -> YNABMonthDetailDTO {
        YNABMonthDetailDTO(month: month, categories: [])
    }
}

// MARK: - Plaid backend client

public enum PlaidClientError: Error, Sendable, Equatable {
    case missingConfiguration
    case unauthorized
    case invalidResponse(statusCode: Int)
    case decoding
    case transport
    case cancelled
}

public enum PlaidLinkMode: String, Codable, Sendable {
    case investments
    case transactions
    case updateTransactions
}

/// Talks only to Networth's private backend. Plaid credentials and Item access
/// tokens are intentionally absent from this interface.
public protocol PlaidClient: Actor {
    func configure(baseURL: URL?, bearerToken: String?)
    func createLinkToken(
        mode: PlaidLinkMode,
        itemId: String?
    ) async throws -> PlaidLinkTokenResponseDTO
    func exchangePublicToken(
        _ publicToken: String,
        products: [String]
    ) async throws -> PlaidExchangeResponseDTO
    func items() async throws -> PlaidItemsResponseDTO
    func holdings() async throws -> PlaidHoldingsResponseDTO
    func transactions(
        itemId: String,
        cursor: String?,
        count: Int
    ) async throws -> PlaidTransactionsSyncResponseDTO
    func enableTransactions(itemId: String) async throws -> PlaidExchangeResponseDTO
    func inferTransaction(
        _ input: PlaidInferenceRequestDTO
    ) async throws -> PlaidInferenceResponseDTO
    func uploadClaudeSnapshot(
        _ snapshot: ClaudeFinancialSnapshotDTO
    ) async throws
    func generateClaudeConnectCode() async throws
        -> ClaudeConnectCodeResponseDTO
    func revokeClaudeAccess() async throws
    func removeItem(id: String) async throws
}

public actor LivePlaidClient: PlaidClient {
    private let session: URLSession
    private var baseURL: URL?
    private var bearerToken: String?
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(session: URLSession = .shared) {
        self.session = session
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
    }

    public func configure(baseURL: URL?, bearerToken: String?) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func createLinkToken(
        mode: PlaidLinkMode,
        itemId: String?
    ) async throws -> PlaidLinkTokenResponseDTO {
        struct Body: Encodable {
            let mode: PlaidLinkMode
            let itemId: String?
        }
        return try await request(
            path: "v1/plaid/link-token",
            method: "POST",
            body: encoder.encode(Body(mode: mode, itemId: itemId))
        )
    }

    public func exchangePublicToken(
        _ publicToken: String,
        products: [String]
    ) async throws -> PlaidExchangeResponseDTO {
        struct Body: Encodable {
            let publicToken: String
            let products: [String]
        }
        return try await request(
            path: "v1/plaid/exchange",
            method: "POST",
            body: encoder.encode(Body(publicToken: publicToken, products: products))
        )
    }

    public func items() async throws -> PlaidItemsResponseDTO {
        try await request(path: "v1/plaid/items", method: "GET")
    }

    public func holdings() async throws -> PlaidHoldingsResponseDTO {
        try await request(path: "v1/plaid/investments/holdings", method: "GET")
    }

    public func transactions(
        itemId: String,
        cursor: String?,
        count: Int = 500
    ) async throws -> PlaidTransactionsSyncResponseDTO {
        struct Body: Encodable {
            let itemId: String
            let cursor: String?
            let count: Int
        }
        return try await request(
            path: "v1/plaid/transactions/sync",
            method: "POST",
            body: encoder.encode(Body(itemId: itemId, cursor: cursor, count: count))
        )
    }

    public func enableTransactions(itemId: String) async throws -> PlaidExchangeResponseDTO {
        try await request(
            path: "v1/plaid/items/\(itemId)/enable-transactions",
            method: "POST"
        )
    }

    public func inferTransaction(
        _ input: PlaidInferenceRequestDTO
    ) async throws -> PlaidInferenceResponseDTO {
        try await request(
            path: "v1/plaid/inference/transaction",
            method: "POST",
            body: encoder.encode(input)
        )
    }

    public func uploadClaudeSnapshot(
        _ snapshot: ClaudeFinancialSnapshotDTO
    ) async throws {
        _ = try await send(
            path: "v1/claude/snapshot",
            method: "PUT",
            body: encoder.encode(snapshot)
        )
    }

    public func generateClaudeConnectCode() async throws
        -> ClaudeConnectCodeResponseDTO {
        try await request(
            path: "v1/claude/connect-code",
            method: "POST"
        )
    }

    public func revokeClaudeAccess() async throws {
        _ = try await send(
            path: "v1/claude/access",
            method: "DELETE"
        )
    }

    public func removeItem(id: String) async throws {
        _ = try await send(
            path: "v1/plaid/items/\(id)",
            method: "DELETE"
        )
    }

    private func request<T: Decodable & Sendable>(
        path: String,
        method: String,
        body: Data? = nil
    ) async throws -> T {
        let data = try await send(path: path, method: method, body: body)
        do { return try decoder.decode(T.self, from: data) }
        catch { throw PlaidClientError.decoding }
    }

    private func send(
        path: String,
        method: String,
        body: Data? = nil
    ) async throws -> Data {
        guard let baseURL,
              let bearerToken,
              !bearerToken.isEmpty else {
            throw PlaidClientError.missingConfiguration
        }
        let url = path.split(separator: "/").reduce(baseURL) {
            $0.appendingPathComponent(String($1))
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 20
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw PlaidClientError.cancelled
        } catch {
            if (error as NSError).code == NSURLErrorCancelled {
                throw PlaidClientError.cancelled
            }
            throw PlaidClientError.transport
        }

        guard let http = response as? HTTPURLResponse else {
            throw PlaidClientError.invalidResponse(statusCode: 0)
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            throw PlaidClientError.unauthorized
        default:
            throw PlaidClientError.invalidResponse(statusCode: http.statusCode)
        }
    }
}

public actor RecordedPlaidClient: PlaidClient {
    public var linkTokenResult: PlaidLinkTokenResponseDTO
    public var exchangeResult: PlaidExchangeResponseDTO
    public var itemsResult: PlaidItemsResponseDTO
    public var holdingsResult: PlaidHoldingsResponseDTO
    public var transactionsResult: PlaidTransactionsSyncResponseDTO?
    public var inferenceResult: PlaidInferenceResponseDTO
    public private(set) var exchangedPublicTokens: [String] = []
    public private(set) var requestedLinkModes: [PlaidLinkMode] = []
    public private(set) var transactionRequests: [(itemId: String, cursor: String?)] = []
    public private(set) var enabledTransactionItemIDs: [String] = []
    public private(set) var removedItemIDs: [String] = []
    public private(set) var uploadedClaudeSnapshots:
        [ClaudeFinancialSnapshotDTO] = []
    public private(set) var claudeAccessRevoked = false
    public private(set) var configuredBaseURL: URL?
    public private(set) var configuredBearerToken: String?
    public var claudeConnectCodeResult: ClaudeConnectCodeResponseDTO

    public init(
        linkToken: PlaidLinkTokenResponseDTO = .init(linkToken: "recorded-link-token", expiration: nil),
        exchange: PlaidExchangeResponseDTO = .init(item: .init(
            id: "recorded-item", institutionName: "Recorded Brokerage",
            status: "healthy", lastSyncedAt: nil
        )),
        items: PlaidItemsResponseDTO = .init(items: []),
        holdings: PlaidHoldingsResponseDTO = .init(
            items: [], accounts: [], securities: [], holdings: []
        ),
        transactions: PlaidTransactionsSyncResponseDTO? = nil,
        inference: PlaidInferenceResponseDTO = .init(
            displayName: "Recorded Merchant",
            categoryCode: NativeTransactionCategory.other.rawValue,
            confidence: ClassificationConfidence.medium.rawValue
        ),
        claudeConnectCode: ClaudeConnectCodeResponseDTO = .init(
            code: "ABC234",
            expiresAt: .now.addingTimeInterval(600)
        )
    ) {
        self.linkTokenResult = linkToken
        self.exchangeResult = exchange
        self.itemsResult = items
        self.holdingsResult = holdings
        self.transactionsResult = transactions
        self.inferenceResult = inference
        self.claudeConnectCodeResult = claudeConnectCode
    }

    public func configure(baseURL: URL?, bearerToken: String?) {
        configuredBaseURL = baseURL
        configuredBearerToken = bearerToken
    }

    public func createLinkToken(
        mode: PlaidLinkMode,
        itemId: String?
    ) async throws -> PlaidLinkTokenResponseDTO {
        requestedLinkModes.append(mode)
        return linkTokenResult
    }
    public func exchangePublicToken(
        _ publicToken: String,
        products: [String]
    ) async throws -> PlaidExchangeResponseDTO {
        exchangedPublicTokens.append(publicToken)
        return exchangeResult
    }
    public func items() async throws -> PlaidItemsResponseDTO { itemsResult }
    public func holdings() async throws -> PlaidHoldingsResponseDTO { holdingsResult }
    public func transactions(
        itemId: String,
        cursor: String?,
        count: Int
    ) async throws -> PlaidTransactionsSyncResponseDTO {
        transactionRequests.append((itemId, cursor))
        if let transactionsResult { return transactionsResult }
        return PlaidTransactionsSyncResponseDTO(
            item: PlaidItemDTO(
                id: itemId,
                institutionName: "Recorded Bank",
                status: "healthy",
                lastSyncedAt: .now,
                products: ["transactions"]
            ),
            accounts: [],
            added: [],
            modified: [],
            removed: [],
            nextCursor: cursor ?? "recorded-cursor",
            hasMore: false
        )
    }
    public func enableTransactions(itemId: String) async throws -> PlaidExchangeResponseDTO {
        enabledTransactionItemIDs.append(itemId)
        return exchangeResult
    }
    public func inferTransaction(
        _ input: PlaidInferenceRequestDTO
    ) async throws -> PlaidInferenceResponseDTO {
        inferenceResult
    }
    public func uploadClaudeSnapshot(
        _ snapshot: ClaudeFinancialSnapshotDTO
    ) async throws {
        uploadedClaudeSnapshots.append(snapshot)
    }
    public func generateClaudeConnectCode() async throws
        -> ClaudeConnectCodeResponseDTO {
        claudeConnectCodeResult
    }
    public func revokeClaudeAccess() async throws {
        claudeAccessRevoked = true
    }
    public func removeItem(id: String) async throws { removedItemIDs.append(id) }
}

// MARK: - On-device transaction inference

public protocol OnDeviceTransactionInferring: Sendable {
    func suggestion(
        for transaction: FinancialTransactionSummary
    ) async -> ModelClassificationSuggestion?
}

public struct AppleTransactionInferenceProvider: OnDeviceTransactionInferring {
    public init() {}

    public func suggestion(
        for transaction: FinancialTransactionSummary
    ) async -> ModelClassificationSuggestion? {
        let model = SystemLanguageModel(useCase: .contentTagging)
        guard model.availability == .available else { return nil }
        let session = LanguageModelSession(
            model: model,
            instructions: """
            Classify one personal-finance transaction. Return a short defensible
            merchant/counterparty display name and exactly one allowed category.
            Do not infer identity, account ownership, location, or other facts.
            """
        )
        let prompt = """
        Raw description: \(transaction.rawDescription)
        Plaid merchant: \(transaction.providerMerchantName ?? "unknown")
        Counterparty: \(transaction.counterpartyName ?? "unknown")
        Payment channel: \(transaction.paymentChannel ?? "unknown")
        Plaid category: \(transaction.providerCategoryPrimary ?? "unknown") / \(transaction.providerCategoryDetailed ?? "unknown")
        Plaid confidence: \(transaction.providerCategoryConfidence ?? "unknown")
        Direction: \(transaction.amount.isNegative ? "outflow" : "inflow")
        """
        do {
            let response = try await session.respond(
                to: prompt,
                generating: AppleTransactionInferenceOutput.self
            )
            guard let category = NativeTransactionCategory(
                rawValue: response.content.categoryCode
            ), let confidence = ClassificationConfidence(
                rawValue: response.content.confidence
            ) else {
                return nil
            }
            let name = response.content.displayName
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return ModelClassificationSuggestion(
                displayName: String(name.prefix(120)),
                category: category,
                confidence: confidence,
                provenance: .appleModel
            )
        } catch {
            return nil
        }
    }
}

public struct RecordedTransactionInferenceProvider: OnDeviceTransactionInferring {
    public var result: ModelClassificationSuggestion?

    public init(result: ModelClassificationSuggestion? = nil) {
        self.result = result
    }

    public func suggestion(
        for transaction: FinancialTransactionSummary
    ) async -> ModelClassificationSuggestion? {
        result
    }
}

@Generable
private struct AppleTransactionInferenceOutput {
    @Guide(description: "Short human-readable merchant or counterparty name.")
    var displayName: String

    @Guide(
        description: "Exactly one allowed Networth category code.",
        .anyOf([
            "income", "reimbursements", "housing", "utilities", "groceries",
            "dining", "transportation", "health", "insurance", "shopping",
            "personalCare", "entertainment", "subscriptions", "travel",
            "education", "familyAndPets", "taxes", "feesAndInterest",
            "giftsAndDonations", "other"
        ])
    )
    var categoryCode: String

    @Guide(
        description: "Confidence in the name and category.",
        .anyOf(["high", "medium", "low"])
    )
    var confidence: String
}
