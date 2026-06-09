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
    private let mainContext: ModelContext
    private let logger = Logger(subsystem: "com.bluelava.me.networth", category: "sync")

    /// One-stop version constant for the history-backfill gate. Bumping this
    /// re-runs the 24-month reconstruction for every existing install.
    /// Versions:
    ///   1 — original reconstruction (closed-only filter).
    ///   2 — sign- and kind-aware cross-closed transfer handling (later abandoned).
    ///   3 — closed-account opt-in inclusion (Fix 2 final design).
    /// Used by the guard *and* every success marker write so the two can't
    /// silently drift apart and cause backfill to re-run forever.
    public static let currentHistoryBackfillVersion: Int = 3

    public init(client: any YNABClient, mainContext: ModelContext) {
        self.client = client
        self.mainContext = mainContext
    }

    public func syncAll(budgetId: String?) async {
        // Don't pile on concurrent syncs. The phase observer doubles as a
        // sync-in-flight flag here; if another sync is already running, this
        // call is a no-op.
        if case .syncing = phase { return }
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

            // One-time migration: caches that predate category sync need a full
            // refetch of transactions + scheduled so category_id and
            // transfer_account_id land on existing rows. Self-healing — runs
            // once, then never again because the categories cursor exists.
            resetCursorsIfPreCategoryCache(budgetId: useBudget)

            phase = .syncing(label: "Categories")
            let categoriesCursor = cursor(key: "categories:\(useBudget)")
            let categoriesResp = try await client.categories(budgetId: useBudget, lastKnowledge: categoriesCursor)
            upsertCategories(categoriesResp.category_groups, budgetId: useBudget)
            saveCursor(key: "categories:\(useBudget)", value: categoriesResp.server_knowledge)

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

            guard mainContext.safeSave(source: "sync.cache") else {
                // Roll back the upserts + cursor writes so a retry in the
                // same app session doesn't read partially-persisted state.
                mainContext.rollback()
                phase = .error("Saving synced data failed. Retry the sync in a moment.")
                return
            }
            updateUserLastSynced(date: .now, budgetId: useBudget)
            guard mainContext.safeSave(source: "sync.durable") else {
                mainContext.rollback()
                phase = .error("Saving sync state failed. Retry the sync in a moment.")
                return
            }

            let backfillOK = runHistoryBackfillIfNeeded(budgetId: useBudget)
            guard backfillOK else {
                phase = .error("Saving the historical chart data failed. Retry the sync in a moment.")
                return
            }

            lastSyncedAt = .now
            phase = .idle
        } catch let error as YNABClientError {
            // Any in-flight upserts before the YNAB request threw should be
            // discarded — they were never saved, but rollback also clears
            // them from the in-memory store.
            mainContext.rollback()
            phase = .error(humanize(error))
        } catch {
            mainContext.rollback()
            phase = .error(error.localizedDescription)
        }
    }

    // MARK: - Historical net-worth backfill

    /// Reconstructs 24 months of daily net-worth snapshots from the cached
    /// YNAB transactions and writes them as `.backfill` rows. Gated by a
    /// CloudKit-synced marker on `DurableUserSettings` so it runs once per
    /// iCloud account (re-runnable via `forceFullResync()`, which resets the
    /// marker before syncing).
    ///
    /// Manual assets are intentionally excluded — their value history doesn't
    /// extend that far back. When a backfill row collides with a `.live` row
    /// for the same day, the dedupe pass keeps `.live` so manual-asset totals
    /// are preserved.
    /// Returns `true` when the backfill is in a clean state (either it ran
    /// to completion and persisted, or it was already done and nothing was
    /// needed). Returns `false` only when the marker is still at 0 due to a
    /// failed save — the caller should propagate that as a sync failure so
    /// `lastSyncedAt` and `.idle` aren't set on a half-finished backfill.
    @discardableResult
    func runHistoryBackfillIfNeeded(budgetId: String) -> Bool {
        let settingsDescriptor = FetchDescriptor<DurableUserSettings>()
        // A failed fetch or a missing row both mean we can't trust the
        // backfill state — treat as a real failure so sync surfaces it
        // instead of silently reporting success.
        let settings: DurableUserSettings
        do {
            guard let row = try mainContext.fetch(settingsDescriptor).first else {
                logger.error("History backfill: no DurableUserSettings row; treating as failure.")
                return false
            }
            settings = row
        } catch {
            logger.error("History backfill: settings fetch failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        guard settings.historyBackfillVersion < Self.currentHistoryBackfillVersion else { return true }

        phase = .syncing(label: "Reconstructing history")

        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date.now)
        guard let defaultWindowStart = calendar.date(byAdding: .month, value: -24, to: today) else {
            return true
        }
        // User-chosen floor wins over the 24-month default. Setting a
        // `chartStartDate` is the user's way of saying "the historical
        // reconstruction before this date is unreliable; don't try."
        let chartFloor = settings.chartStartDate.map { calendar.startOfDay(for: $0) }
        let windowStart = max(defaultWindowStart, chartFloor ?? defaultWindowStart)
        // If the floor is at or after today, there's nothing to reconstruct.
        guard windowStart <= today else {
            settings.historyBackfillVersion = Self.currentHistoryBackfillVersion
            if !mainContext.safeSave(source: "sync.backfill.marker") {
                mainContext.rollback()
                logger.error("History backfill marker save failed when chartStartDate >= today; will retry on next sync.")
                return false
            }
            return true
        }

        // Purge stale `.backfill` rows first so a re-run (via `forceFullResync`
        // or a version bump) regenerates clean history reflecting the current
        // reconstruction logic. `.live` rows are preserved — they were
        // written by `recordIfNeeded` during normal app use and already
        // reflect the right account filter.
        let backfillRaw = SnapshotSource.backfill.rawValue
        let staleDescriptor = FetchDescriptor<DurableNetWorthSnapshot>(
            predicate: #Predicate { $0.sourceRaw == backfillRaw }
        )
        if let stale = try? mainContext.fetch(staleDescriptor) {
            for row in stale { mainContext.delete(row) }
        }

        // Fetch open accounts (`!closed && !deleted`) — those always contribute
        // to the historical reconstruction. Then fetch the user's
        // opt-in list of closed accounts to also walk. Walking a closed
        // account today (with balance $0) recovers its real historical
        // balance via the transactions YNAB still has on file; the user
        // toggles in only accounts whose history matters (brokerage
        // staging accounts, etc).
        let openAccountsDescriptor = FetchDescriptor<CachedAccount>(
            predicate: #Predicate {
                $0.budgetId == budgetId && $0.deleted == false && $0.closed == false
            }
        )
        let openAccounts = (try? mainContext.fetch(openAccountsDescriptor)) ?? []
        let includedClosedDescriptor = FetchDescriptor<DurableIncludedClosedAccount>()
        let includedIds = Set(((try? mainContext.fetch(includedClosedDescriptor)) ?? []).map { $0.accountId })
        let closedAccountsDescriptor = FetchDescriptor<CachedAccount>(
            predicate: #Predicate {
                $0.budgetId == budgetId && $0.deleted == false && $0.closed == true
            }
        )
        let includedClosedAccounts = ((try? mainContext.fetch(closedAccountsDescriptor)) ?? [])
            .filter { includedIds.contains($0.id) }
        let walkedAccounts = openAccounts + includedClosedAccounts
        guard !walkedAccounts.isEmpty else {
            // Nothing to reconstruct, but mark complete so we don't keep retrying.
            settings.historyBackfillVersion = Self.currentHistoryBackfillVersion
            if !mainContext.safeSave(source: "sync.backfill.marker") {
                mainContext.rollback()
                logger.error("History backfill marker save failed for empty-accounts case; will retry on next sync.")
                return false
            }
            return true
        }

        var dailyBalancesByAccount: [String: [AccountHistoryReconstructor.DailyBalance]] = [:]
        var kindsById: [String: AccountKind] = [:]
        let reconstructor = AccountHistoryReconstructor(calendar: calendar)

        for account in walkedAccounts {
            kindsById[account.id] = account.kind
            let accountId = account.id
            let txnDescriptor = FetchDescriptor<CachedTransaction>(
                predicate: #Predicate {
                    $0.accountId == accountId && $0.budgetId == budgetId && $0.deleted == false
                }
            )
            let txns = ((try? mainContext.fetch(txnDescriptor)) ?? []).map { $0.toSummary() }
            dailyBalancesByAccount[account.id] = reconstructor.reconstruct(
                currentBalance: account.balance,
                transactions: txns,
                from: windowStart,
                to: today
            )
        }

        let aggregated = NetWorthHistoryAggregator().aggregate(
            dailyBalancesByAccount: dailyBalancesByAccount,
            kindsById: kindsById,
            manualAssetSeries: [:]
        )

        // After the purge above, the only days with existing snapshots are
        // `.live` rows. Skip those so we never overwrite a richer live total
        // (which includes manual assets) with a thinner backfill row.
        let liveRaw = SnapshotSource.live.rawValue
        let liveDescriptor = FetchDescriptor<DurableNetWorthSnapshot>(
            predicate: #Predicate { $0.sourceRaw == liveRaw }
        )
        let liveDays = Set(((try? mainContext.fetch(liveDescriptor)) ?? [])
            .map { calendar.startOfDay(for: $0.date) })

        for snap in aggregated {
            let day = calendar.startOfDay(for: snap.date)
            if liveDays.contains(day) { continue }
            mainContext.insert(DurableNetWorthSnapshot(
                date: day,
                assetsMilliunits: snap.assets.milliunits,
                liabilitiesMilliunits: snap.liabilities.milliunits,
                source: .backfill
            ))
        }

        // Dedupe before flipping the marker so any same-day collisions get
        // collapsed and the chart never renders a duplicate day.
        SnapshotScheduler(mainContext: mainContext, calendar: calendar)
            .dedupeSnapshotsForDuplicateDays()

        guard mainContext.safeSave(source: "sync.backfill") else {
            // Snapshot save failed. Discard the inserted-but-unsaved rows
            // and the deletes-pending-save so the next retry starts from
            // the same on-disk state we started this run from. Marker stays
            // at its previous version.
            mainContext.rollback()
            logger.error("History backfill snapshot save failed; marker stays at \(settings.historyBackfillVersion) for retry.")
            return false
        }

        settings.historyBackfillVersion = Self.currentHistoryBackfillVersion
        if !mainContext.safeSave(source: "sync.backfill.marker") {
            // Snapshots saved but marker didn't. Roll back the unsaved
            // marker change so in-memory state matches disk; the next sync
            // sees the prior version on disk and re-runs. Dedupe and the
            // .live-preserving skip keep that re-run idempotent.
            mainContext.rollback()
            logger.error("History backfill marker save failed; snapshots persisted but marker stays at \(settings.historyBackfillVersion).")
            return false
        }

        logger.info("History backfill complete: wrote \(aggregated.count) reconstructed days for budget \(budgetId, privacy: .private(mask: .hash)); walked \(walkedAccounts.count) accounts (\(includedClosedAccounts.count) closed opt-ins).")
        return true
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
                mainContext.insert(CachedBudget(
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
                mainContext.insert(CachedAccount(
                    id: a.id, budgetId: budgetId, name: a.name, typeRaw: a.type,
                    balanceMilliunits: a.balance, clearedMilliunits: a.cleared_balance,
                    unclearedMilliunits: a.uncleared_balance,
                    onBudget: a.on_budget, closed: a.closed, deleted: a.deleted
                ))
            }
        }
    }

    private func upsertTransactions(_ txns: [YNABTransactionDTO], budgetId: String) {
        let encoder = JSONEncoder()
        for t in txns {
            guard let parsed = YNABTransactionDTO.dateParser.date(from: t.date) else { continue }
            let subSummaries: [SubTransactionSummary] = (t.subtransactions ?? []).map { $0.toSummary() }
            let subData: Data? = subSummaries.isEmpty ? nil : (try? encoder.encode(subSummaries))
            let targetId = t.id
            let existing = fetchOne(CachedTransaction.self, where: #Predicate { $0.id == targetId })
            if let existing {
                existing.amountMilliunits = t.amount
                existing.cleared = t.cleared == "cleared" || t.cleared == "reconciled"
                existing.approved = t.approved
                existing.payeeName = t.payee_name
                existing.categoryId = t.category_id
                existing.categoryName = t.category_name
                existing.transferAccountId = t.transfer_account_id
                existing.memo = t.memo
                existing.deleted = t.deleted
                existing.date = parsed
                existing.subtransactionsData = subData
            } else {
                mainContext.insert(CachedTransaction(
                    id: t.id, budgetId: budgetId, accountId: t.account_id, date: parsed,
                    amountMilliunits: t.amount,
                    cleared: t.cleared == "cleared" || t.cleared == "reconciled",
                    approved: t.approved,
                    payeeName: t.payee_name,
                    categoryId: t.category_id, categoryName: t.category_name,
                    transferAccountId: t.transfer_account_id,
                    memo: t.memo, deleted: t.deleted,
                    subtransactionsData: subData
                ))
            }
        }
    }

    private func upsertCategories(_ groups: [YNABCategoryGroupDTO], budgetId: String) {
        for group in groups {
            for cat in group.categories {
                let targetId = cat.id
                let existing = fetchOne(CachedCategory.self, where: #Predicate { $0.id == targetId })
                if let existing {
                    existing.groupId = group.id
                    existing.groupName = group.name
                    existing.name = cat.name
                    existing.hidden = cat.hidden || group.hidden
                    existing.deleted = cat.deleted || group.deleted
                } else {
                    mainContext.insert(CachedCategory(
                        id: cat.id, budgetId: budgetId,
                        groupId: group.id, groupName: group.name,
                        name: cat.name,
                        hidden: cat.hidden || group.hidden,
                        deleted: cat.deleted || group.deleted
                    ))
                }
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
                existing.categoryId = s.category_id
                existing.transferAccountId = s.transfer_account_id
                existing.memo = s.memo
                existing.deleted = s.deleted
            } else {
                mainContext.insert(CachedScheduledTransaction(
                    id: s.id, budgetId: budgetId, accountId: s.account_id,
                    nextDate: parsed, frequencyRaw: s.frequency,
                    amountMilliunits: s.amount,
                    payeeName: s.payee_name,
                    categoryId: s.category_id,
                    transferAccountId: s.transfer_account_id,
                    memo: s.memo, deleted: s.deleted
                ))
            }
        }
    }

    private func updateUserLastSynced(date: Date, budgetId: String) {
        let descriptor = FetchDescriptor<DurableUserSettings>()
        let settings: DurableUserSettings
        if let existing = try? mainContext.fetch(descriptor).first {
            settings = existing
        } else {
            settings = DurableUserSettings()
            mainContext.insert(settings)
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

    private func clearCursor(key: String) {
        if let existing = fetchOne(SyncCursor.self, where: #Predicate { $0.key == key }) {
            mainContext.delete(existing)
        }
    }

    /// Caches populated before category sync existed have transactions and
    /// scheduled-transactions rows with nil `categoryId` / `transferAccountId`.
    /// YNAB's delta sync won't replay them, so we need a full refetch.
    ///
    /// Trigger conditions (either):
    ///   1. Cursor pre-state: transactions cursor exists but categories cursor doesn't.
    ///   2. Data backfill: cached transactions exist but NONE have categoryId yet
    ///      (handles the case where a prior sync ran partially and saved the
    ///      categories cursor but never finished the transactions full-refetch).
    private func resetCursorsIfPreCategoryCache(budgetId: String) {
        let hasTxnCursor = cursor(key: "transactions:\(budgetId)") != nil
        guard hasTxnCursor else { return }
        let hasCategoriesCursor = cursor(key: "categories:\(budgetId)") != nil
        let preCategorySync = !hasCategoriesCursor
        let needsBackfill = !anyCachedTransactionHasCategoryId()
        guard preCategorySync || needsBackfill else { return }
        clearCursor(key: "transactions:\(budgetId)")
        clearCursor(key: "scheduled:\(budgetId)")
        logger.info("Resetting transactions+scheduled cursors (preCategorySync=\(preCategorySync), needsBackfill=\(needsBackfill)).")
    }

    private func anyCachedTransactionHasCategoryId() -> Bool {
        var descriptor = FetchDescriptor<CachedTransaction>(
            predicate: #Predicate { $0.categoryId != nil }
        )
        descriptor.fetchLimit = 1
        return ((try? mainContext.fetch(descriptor).count) ?? 0) > 0
    }

    private func saveCursor(key: String, value: Int64?) {
        guard let value else { return }
        if let existing = fetchOne(SyncCursor.self, where: #Predicate { $0.key == key }) {
            existing.serverKnowledge = value
            existing.updatedAt = .now
        } else {
            mainContext.insert(SyncCursor(key: key, serverKnowledge: value))
        }
    }

    private func fetchOne<T: PersistentModel>(_ type: T.Type, where predicate: Predicate<T>) -> T? {
        var descriptor = FetchDescriptor<T>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try? mainContext.fetch(descriptor).first
    }
}
