import Foundation
import SwiftData
import os
import NetworthCore

/// Pulls data from YNAB and writes it into the local SwiftData cache.
/// Honors delta sync via `last_knowledge_of_server` to stay well under the 200 req/hr limit.
@MainActor
@Observable
public final class SyncCoordinator {
    public enum Phase: Sendable, Equatable {
        case idle
        case syncing(label: String)
        case error(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var lastSyncedAt: Date?

    private let client: any YNABClient
    private let cacheContext: ModelContext
    private let durableContext: ModelContext
    private let logger = Logger(subsystem: "com.bluelava.me.networth", category: "sync")

    public init(client: any YNABClient, cacheContext: ModelContext, durableContext: ModelContext) {
        self.client = client
        self.cacheContext = cacheContext
        self.durableContext = durableContext
    }

    public func syncAll(budgetId: String?) async {
        do {
            phase = .syncing(label: "Budgets")
            let budgets = try await client.budgets()
            upsertBudgets(budgets)
            let useBudget: String
            if let budgetId, budgets.contains(where: { $0.id == budgetId }) {
                useBudget = budgetId
            } else if let first = budgets.first?.id {
                useBudget = first
            } else {
                phase = .idle
                return
            }

            phase = .syncing(label: "Accounts")
            let accountsCursor = cursor(key: "accounts:\(useBudget)")
            let accountsResp = try await client.accounts(budgetId: useBudget, lastKnowledge: accountsCursor)
            upsertAccounts(accountsResp.accounts, budgetId: useBudget)
            saveCursor(key: "accounts:\(useBudget)", value: accountsResp.server_knowledge)

            phase = .syncing(label: "Scheduled")
            let schedCursor = cursor(key: "scheduled:\(useBudget)")
            let scheduledResp = try await client.scheduledTransactions(budgetId: useBudget, lastKnowledge: schedCursor)
            upsertScheduled(scheduledResp.scheduled_transactions, budgetId: useBudget)
            saveCursor(key: "scheduled:\(useBudget)", value: scheduledResp.server_knowledge)

            phase = .syncing(label: "Transactions")
            let txnCursor = cursor(key: "transactions:\(useBudget)")
            let sinceDate: Date? = txnCursor == nil ? Calendar(identifier: .gregorian)
                .date(byAdding: .month, value: -24, to: Date.now) : nil
            let txnResp = try await client.transactions(budgetId: useBudget, accountId: nil, sinceDate: sinceDate, lastKnowledge: txnCursor)
            upsertTransactions(txnResp.transactions, budgetId: useBudget)
            saveCursor(key: "transactions:\(useBudget)", value: txnResp.server_knowledge)

            cacheContext.safeSave(source: "sync.cache")
            updateUserLastSynced(date: .now, budgetId: useBudget)
            durableContext.safeSave(source: "sync.durable")
            lastSyncedAt = .now
            phase = .idle
        } catch let error as YNABClientError {
            phase = .error(humanize(error))
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    private func humanize(_ err: YNABClientError) -> String {
        switch err {
        case .missingToken:        return "Add your YNAB token in Settings to sync."
        case .unauthorized:        return "Your YNAB token was rejected. Re-enter it in Settings."
        case .rateLimited:         return "YNAB rate-limited the request. Try again shortly."
        case .invalidResponse(let code, _):
            return "YNAB returned an error (\(code))."
        case .decoding:            return "Couldn't read YNAB's response."
        case .transport(let err):  return err.localizedDescription
        case .cancelled:           return "Sync cancelled."
        }
    }

    // MARK: - Upserts

    private func upsertBudgets(_ budgets: [YNABBudgetSummary]) {
        for b in budgets {
            let targetId = b.id
            let existing = fetchOne(CachedBudget.self, where: #Predicate { $0.id == targetId })
            if let existing {
                existing.name = b.name
                existing.currencyISO = b.currency_format?.iso_code ?? existing.currencyISO
            } else {
                cacheContext.insert(CachedBudget(
                    id: b.id, name: b.name,
                    currencyISO: b.currency_format?.iso_code ?? "USD",
                    lastModifiedRaw: b.last_modified_on
                ))
            }
        }
    }

    private func upsertAccounts(_ accounts: [YNABAccountDTO], budgetId: String) {
        for a in accounts {
            let targetId = a.id
            let existing = fetchOne(CachedAccount.self, where: #Predicate { $0.id == targetId })
            if let existing {
                existing.name = a.name
                existing.typeRaw = a.type
                existing.balanceMilliunits = a.balance
                existing.clearedMilliunits = a.cleared_balance
                existing.unclearedMilliunits = a.uncleared_balance
                existing.onBudget = a.on_budget
                existing.closed = a.closed
                existing.deleted = a.deleted
                existing.updatedAt = .now
            } else {
                cacheContext.insert(CachedAccount(
                    id: a.id, budgetId: budgetId, name: a.name, typeRaw: a.type,
                    balanceMilliunits: a.balance, clearedMilliunits: a.cleared_balance,
                    unclearedMilliunits: a.uncleared_balance,
                    onBudget: a.on_budget, closed: a.closed, deleted: a.deleted
                ))
            }
        }
    }

    private func upsertTransactions(_ txns: [YNABTransactionDTO], budgetId: String) {
        for t in txns {
            guard let parsed = YNABTransactionDTO.dateParser.date(from: t.date) else { continue }
            let targetId = t.id
            let existing = fetchOne(CachedTransaction.self, where: #Predicate { $0.id == targetId })
            if let existing {
                existing.amountMilliunits = t.amount
                existing.cleared = t.cleared == "cleared" || t.cleared == "reconciled"
                existing.approved = t.approved
                existing.payeeName = t.payee_name
                existing.categoryName = t.category_name
                existing.memo = t.memo
                existing.deleted = t.deleted
                existing.date = parsed
            } else {
                cacheContext.insert(CachedTransaction(
                    id: t.id, budgetId: budgetId, accountId: t.account_id, date: parsed,
                    amountMilliunits: t.amount,
                    cleared: t.cleared == "cleared" || t.cleared == "reconciled",
                    approved: t.approved,
                    payeeName: t.payee_name, categoryName: t.category_name,
                    memo: t.memo, deleted: t.deleted
                ))
            }
        }
    }

    private func upsertScheduled(_ scheds: [YNABScheduledTransactionDTO], budgetId: String) {
        for s in scheds {
            guard let parsed = YNABTransactionDTO.dateParser.date(from: s.date_next) else { continue }
            let targetId = s.id
            let existing = fetchOne(CachedScheduledTransaction.self, where: #Predicate { $0.id == targetId })
            if let existing {
                existing.nextDate = parsed
                existing.frequencyRaw = s.frequency
                existing.amountMilliunits = s.amount
                existing.payeeName = s.payee_name
                existing.memo = s.memo
                existing.deleted = s.deleted
            } else {
                cacheContext.insert(CachedScheduledTransaction(
                    id: s.id, budgetId: budgetId, accountId: s.account_id,
                    nextDate: parsed, frequencyRaw: s.frequency,
                    amountMilliunits: s.amount,
                    payeeName: s.payee_name, memo: s.memo, deleted: s.deleted
                ))
            }
        }
    }

    private func updateUserLastSynced(date: Date, budgetId: String) {
        let descriptor = FetchDescriptor<DurableUserSettings>()
        let settings: DurableUserSettings
        if let existing = try? durableContext.fetch(descriptor).first {
            settings = existing
        } else {
            settings = DurableUserSettings()
            durableContext.insert(settings)
        }
        settings.lastSyncedAt = date
        if settings.selectedBudgetId == nil {
            settings.selectedBudgetId = budgetId
        }
    }

    // MARK: - Helpers

    private func cursor(key: String) -> Int64? {
        fetchOne(SyncCursor.self, where: #Predicate { $0.key == key })?.serverKnowledge
    }

    private func saveCursor(key: String, value: Int64?) {
        guard let value else { return }
        if let existing = fetchOne(SyncCursor.self, where: #Predicate { $0.key == key }) {
            existing.serverKnowledge = value
            existing.updatedAt = .now
        } else {
            cacheContext.insert(SyncCursor(key: key, serverKnowledge: value))
        }
    }

    private func fetchOne<T: PersistentModel>(_ type: T.Type, where predicate: Predicate<T>) -> T? {
        var descriptor = FetchDescriptor<T>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try? cacheContext.fetch(descriptor).first
    }
}
