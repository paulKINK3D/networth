import Foundation
import SwiftData
import os
import NetworthCore

#if false // Retired provider sync kept temporarily as noncompiled migration history.
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
    public private(set) var canonicalHistoryChangedInLastSync = false

    private let client: any YNABClient
    private let mainContext: ModelContext
    private let logger = Logger(subsystem: "com.bluelava.me.networth", category: "sync")

    /// One-stop version constant for the history-backfill gate. Bumping this
    /// re-runs the 5-year reconstruction for every existing install.
    /// Versions:
    ///   1 — original reconstruction (closed-only filter).
    ///   2 — sign- and kind-aware cross-closed transfer handling (later abandoned).
    ///   3 — closed-account opt-in inclusion (Fix 2 final design).
    ///   4 — historical manual-asset values folded into the aggregate.
    ///   5 — bootstrap freshness check for cross-device iCloud sync.
    ///   6 — backfill window extended from 24 months to 60 months (5 years).
    /// Used by the guard *and* every success marker write so the two can't
    /// silently drift apart and cause backfill to re-run forever.
    public static let currentHistoryBackfillVersion: Int = 6

    public init(client: any YNABClient, mainContext: ModelContext) {
        self.client = client
        self.mainContext = mainContext
    }

    public func syncAll(budgetId: String?) async {
        // Don't pile on concurrent syncs. The phase observer doubles as a
        // sync-in-flight flag here; if another sync is already running, this
        // call is a no-op.
        if case .syncing = phase { return }
        canonicalHistoryChangedInLastSync = false
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
            resetScheduledCursorIfMissingFirstDate(budgetId: useBudget)
            resetTransactionsCursorForGhostPurge(budgetId: useBudget)

            phase = .syncing(label: "Contacts")
            let payeesCursor = cursor(key: "payees:\(useBudget)")
            let payeesResp = try await client.payees(
                budgetId: useBudget,
                lastKnowledge: payeesCursor
            )
            upsertCanonicalPayees(payeesResp.payees)
            saveCursor(
                key: "payees:\(useBudget)",
                value: payeesResp.server_knowledge
            )

            phase = .syncing(label: "Categories")
            let categoriesCursor = cursor(key: "categories:\(useBudget)")
            let categoriesResp = try await client.categories(budgetId: useBudget, lastKnowledge: categoriesCursor)
            upsertCategories(categoriesResp.category_groups, budgetId: useBudget)
            saveCursor(key: "categories:\(useBudget)", value: categoriesResp.server_knowledge)

            phase = .syncing(label: "Category Months")
            await syncCategoryMonths(budgetId: useBudget)

            phase = .syncing(label: "Scheduled")
            let schedCursor = cursor(key: "scheduled:\(useBudget)")
            let scheduledResp = try await client.scheduledTransactions(budgetId: useBudget, lastKnowledge: schedCursor)
            upsertScheduled(scheduledResp.scheduled_transactions, budgetId: useBudget)
            saveCursor(key: "scheduled:\(useBudget)", value: scheduledResp.server_knowledge)

            phase = .syncing(label: "Transactions")
            let txnCursor = cursor(key: "transactions:\(useBudget)")
            let sinceDate: Date? = txnCursor == nil ? Calendar(identifier: .gregorian)
                .date(byAdding: .month, value: -60, to: Date.now) : nil
            let txnResp = try await client.transactions(budgetId: useBudget, accountId: nil, sinceDate: sinceDate, lastKnowledge: txnCursor)
            await upsertTransactions(txnResp.transactions, budgetId: useBudget)
            if txnCursor == nil {
                tombstoneMissingTransactions(
                    fetched: txnResp.transactions,
                    budgetId: useBudget,
                    since: sinceDate
                )
            }
            saveCursor(key: "transactions:\(useBudget)", value: txnResp.server_knowledge)

            guard mainContext.safeSave(source: "sync.cache") else {
                // Roll back the upserts + cursor writes so a retry in the
                // same app session doesn't read partially-persisted state.
                mainContext.rollback()
                phase = .error("Saving synced data failed. Retry the sync in a moment.")
                return
            }
            canonicalHistoryChangedInLastSync =
                !payeesResp.payees.isEmpty
                || !categoriesResp.category_groups.isEmpty
                || !txnResp.transactions.isEmpty
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
            if let settings = try? mainContext.fetch(
                FetchDescriptor<DurableUserSettings>()
            ).first {
                settings.lastSyncedAt = .now
                mainContext.safeSave(source: "plaidTransactions.lastSyncedAt")
            }
            phase = .idle
        } catch let error as YNABClientError {
            // Any in-flight upserts before the YNAB request threw should be
            // discarded — they were never saved, but rollback also clears
            // them from the in-memory store.
            mainContext.rollback()
            if case .cancelled = error {
                // SwiftUI .refreshable cancels the task when the view goes
                // away mid-pull; that's not an error worth surfacing.
                phase = .idle
            } else {
                phase = .error(humanize(error))
            }
        } catch is CancellationError {
            mainContext.rollback()
            phase = .idle
        } catch {
            mainContext.rollback()
            if (error as NSError).code == NSURLErrorCancelled {
                phase = .idle
            } else {
                phase = .error(error.localizedDescription)
            }
        }
    }

    // MARK: - Historical net-worth backfill

    /// Reconstructs up to 5 years of daily net-worth snapshots from the cached
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
        // Always reset phase on exit so standalone callers don't get stuck on
        // the "Reconstructing history" label. `syncAll` overwrites this with
        // its own `.idle` write anyway.
        defer {
            if case .syncing(let label) = phase, label == "Reconstructing history" {
                phase = .idle
            }
        }

        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date.now)
        guard let defaultWindowStart = calendar.date(byAdding: .month, value: -60, to: today) else {
            return true
        }
        // User-chosen floor wins over the 60-month default. Setting a
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

        // Build a per-day manual-asset total for the backfill window. Each
        // `DurableManualAssetValue` is a point-in-time entry, so for any day D
        // we sum the most-recent value (recordedAt ≤ D) across every active
        // manual asset. Without this, historical chart points would exclude
        // manual assets entirely and today's value would appear to spike up.
        let manualAssetSeries = buildManualAssetSeries(windowStart: windowStart, today: today, calendar: calendar)

        let aggregated = NetWorthHistoryAggregator().aggregate(
            dailyBalancesByAccount: dailyBalancesByAccount,
            kindsById: kindsById,
            manualAssetSeries: manualAssetSeries
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
        settings.lastBackfillRunAt = .now
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

    /// Builds a daily total of all manual-asset values over the backfill
    /// window. Each asset's contribution on day D is the amount of its most
    /// recent `DurableManualAssetValue` with `recordedAt ≤ D`. Assets with
    /// no entry on or before D contribute zero.
    ///
    /// Returned dict is keyed by start-of-day so the aggregator's
    /// `manualAssetSeries[date]` lookup matches the per-account daily series.
    private func buildManualAssetSeries(windowStart: Date, today: Date, calendar: Calendar) -> [Date: Money] {
        let descriptor = FetchDescriptor<DurableManualAsset>(
            predicate: #Predicate { $0.deleted == false }
        )
        let assets = (try? mainContext.fetch(descriptor)) ?? []
        guard !assets.isEmpty else { return [:] }

        // For each asset, materialise its value entries sorted ascending by
        // recorded-at (start-of-day). Skip assets with no values entirely.
        struct AssetTimeline {
            let entries: [(day: Date, amount: Int64)]
        }
        var timelines: [AssetTimeline] = []
        for asset in assets {
            let entries = asset.sortedValues.map {
                (day: calendar.startOfDay(for: $0.recordedAt), amount: $0.amountMilliunits)
            }
            if !entries.isEmpty {
                timelines.append(AssetTimeline(entries: entries))
            }
        }
        guard !timelines.isEmpty else { return [:] }

        // Walk the backfill window day-by-day, advancing each asset's cursor
        // through its sorted entries. O(days × assets) — fine for our scale.
        var result: [Date: Money] = [:]
        var cursors = Array(repeating: 0, count: timelines.count)
        var day = calendar.startOfDay(for: windowStart)
        let endDay = calendar.startOfDay(for: today)
        while day <= endDay {
            var total: Int64 = 0
            for (i, timeline) in timelines.enumerated() {
                while cursors[i] < timeline.entries.count && timeline.entries[cursors[i]].day <= day {
                    cursors[i] += 1
                }
                if cursors[i] > 0 {
                    total += timeline.entries[cursors[i] - 1].amount
                }
            }
            result[day] = Money(milliunits: total)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
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

    private func upsertTransactions(_ txns: [YNABTransactionDTO], budgetId: String) async {
        let encoder = JSONEncoder()
        // Large pages (initial sync, cursor resets) pay one bulk fetch instead
        // of thousands of point lookups, and yield periodically so the main
        // actor can keep drawing frames between batches.
        var existingById: [String: CachedTransaction] = [:]
        if txns.count >= 25 {
            let rows = (try? mainContext.fetch(
                FetchDescriptor<CachedTransaction>()
            )) ?? []
            existingById.reserveCapacity(rows.count)
            for row in rows { existingById[row.id] = row }
        }
        for (index, t) in txns.enumerated() {
            if index.isMultiple(of: 200), index > 0 {
                await Task.yield()
            }
            guard let parsed = YNABTransactionDTO.dateParser.date(from: t.date) else { continue }
            let subSummaries: [SubTransactionSummary] = (t.subtransactions ?? []).map { $0.toSummary() }
            let subData: Data? = subSummaries.isEmpty ? nil : (try? encoder.encode(subSummaries))
            let targetId = t.id
            let existing = txns.count >= 25
                ? existingById[targetId]
                : fetchOne(CachedTransaction.self, where: #Predicate { $0.id == targetId })
            if let existing {
                existing.amountMilliunits = t.amount
                existing.cleared = t.cleared == "cleared" || t.cleared == "reconciled"
                existing.approved = t.approved
                existing.payeeId = t.payee_id
                existing.payeeName = t.payee_name
                existing.categoryId = t.category_id
                existing.categoryName = t.category_name
                existing.transferAccountId = t.transfer_account_id
                existing.transferTransactionId = t.transfer_transaction_id
                existing.importId = t.import_id
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
                    payeeId: t.payee_id,
                    transferAccountId: t.transfer_account_id,
                    transferTransactionId: t.transfer_transaction_id,
                    importId: t.import_id,
                    memo: t.memo, deleted: t.deleted,
                    subtransactionsData: subData
                ))
            }
        }
    }

    private func upsertCategories(_ groups: [YNABCategoryGroupDTO], budgetId: String) {
        // YNAB categories are disposable reference data only. They must never
        // create or mutate Networth's durable category directory.
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

    private func upsertCanonicalPayees(_ payees: [YNABPayeeDTO]) {
        let rows = (try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalPayee>()
        )) ?? []
        var byID: [String: DurableCanonicalPayee] = [:]
        for row in rows.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            byID[row.canonicalId] = row
        }
        for payee in payees {
            let canonicalId = "ynab:\(payee.id)"
            if let row = byID[canonicalId] {
                row.ynabPayeeId = payee.id
                row.sourceName = payee.name
                row.transferAccountId = payee.transfer_account_id
                row.deletedAtSource = payee.deleted
                if !row.userEdited {
                    row.name = payee.name
                    row.archived = payee.deleted
                }
                row.updatedAt = .now
            } else {
                mainContext.insert(DurableCanonicalPayee(
                    canonicalId: canonicalId,
                    ynabPayeeId: payee.id,
                    name: payee.name,
                    sourceName: payee.name,
                    transferAccountId: payee.transfer_account_id,
                    archived: payee.deleted,
                    deletedAtSource: payee.deleted
                ))
            }
        }
    }

    /// Read-only import of per-category budgeted/activity/balance. The
    /// current month refreshes on every sync (one request); the previous 12
    /// months backfill once, marked by a cursor so the 200/hr budget is never
    /// spent twice. Endpoint has no delta support.
    private func syncCategoryMonths(budgetId: String) async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-01"
        formatter.timeZone = calendar.timeZone
        let backfillKey = "categoryMonthsBackfill:\(budgetId)"
        var months = [formatter.string(from: .now)]
        let needsBackfill = cursor(key: backfillKey) == nil
        if needsBackfill {
            months += (1...12).compactMap { offset in
                calendar.date(byAdding: .month, value: -offset, to: .now)
                    .map { formatter.string(from: $0) }
            }
        }
        var allSucceeded = true
        for month in months {
            guard let detail = try? await client.monthDetail(
                budgetId: budgetId, month: month
            ) else {
                allSucceeded = false
                continue
            }
            upsertCategoryMonth(detail, budgetId: budgetId)
            await Task.yield()
        }
        if needsBackfill && allSucceeded {
            saveCursor(key: backfillKey, value: 1)
        }
    }

    private func upsertCategoryMonth(
        _ detail: YNABMonthDetailDTO,
        budgetId: String
    ) {
        let month = detail.month
        let existingRows = (try? mainContext.fetch(FetchDescriptor<CachedCategoryMonth>(
            predicate: #Predicate { $0.budgetId == budgetId && $0.month == month }
        ))) ?? []
        var byCategoryId: [String: CachedCategoryMonth] = [:]
        for row in existingRows { byCategoryId[row.categoryId] = row }
        for category in detail.categories where !category.deleted {
            if let row = byCategoryId[category.id] {
                row.budgetedMilliunits = category.budgeted
                row.activityMilliunits = category.activity
                row.balanceMilliunits = category.balance
                row.updatedAt = .now
            } else {
                mainContext.insert(CachedCategoryMonth(
                    budgetId: budgetId,
                    month: month,
                    categoryId: category.id,
                    budgetedMilliunits: category.budgeted,
                    activityMilliunits: category.activity,
                    balanceMilliunits: category.balance
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
                existing.firstDate = YNABTransactionDTO.dateParser.date(from: s.date_first)
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
                    firstDate: YNABTransactionDTO.dateParser.date(from: s.date_first),
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

    /// Schedules cached before `firstDate` was introduced will not be replayed
    /// by delta sync when unchanged. Force one full scheduled fetch so the
    /// expected-spend lookback never invents occurrences before creation.
    private func resetScheduledCursorIfMissingFirstDate(budgetId: String) {
        guard cursor(key: "scheduled:\(budgetId)") != nil else { return }
        var descriptor = FetchDescriptor<CachedScheduledTransaction>(
            predicate: #Predicate { $0.firstDate == nil && !$0.deleted }
        )
        descriptor.fetchLimit = 1
        guard ((try? mainContext.fetch(descriptor).isEmpty) == false) else { return }
        clearCursor(key: "scheduled:\(budgetId)")
        logger.info("Resetting scheduled cursor to backfill firstDate.")
    }

    /// YNAB sends deletion tombstones only through delta sync. A full refetch
    /// (no cursor) returns just the rows that still exist, so anything deleted
    /// in YNAB while no cursor was active would otherwise survive locally as a
    /// ghost and keep counting in Spending forever. After a full refetch,
    /// retire every cached row inside the refetch window that the response no
    /// longer contains.
    private func tombstoneMissingTransactions(
        fetched: [YNABTransactionDTO],
        budgetId: String,
        since: Date?
    ) {
        let fetchedIDs = Set(fetched.map(\.id))
        // An empty response against a populated cache is a partial/failed
        // fetch, not mass deletion — never wipe history on that signal.
        guard !fetchedIDs.isEmpty else { return }
        let cutoff = since ?? .distantPast
        let rows = (try? mainContext.fetch(
            FetchDescriptor<CachedTransaction>(
                predicate: #Predicate {
                    $0.budgetId == budgetId && !$0.deleted && $0.date >= cutoff
                }
            )
        )) ?? []
        var retired = 0
        for row in rows where !fetchedIDs.contains(row.id) {
            row.deleted = true
            retired += 1
        }
        if retired > 0 {
            logger.info("Tombstoned \(retired) cached transactions no longer present in YNAB.")
        }
    }

    /// Caches populated before full-refetch tombstoning existed can hold rows
    /// deleted in YNAB during past cursor resets. Clear the transactions
    /// cursor once so the next sync replays the window and purges any ghosts.
    private func resetTransactionsCursorForGhostPurge(budgetId: String) {
        let key = "transactionsGhostPurge:\(budgetId)"
        guard cursor(key: key) == nil else { return }
        clearCursor(key: "transactions:\(budgetId)")
        saveCursor(key: key, value: 1)
        logger.info("Resetting transactions cursor for one-time ghost purge.")
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
#endif

// MARK: - Plaid investments

/// Independent Plaid cache path. A Plaid failure never rolls back or changes
/// the YNAB sync state, and stale rows are removed only after a complete
/// holdings response has been received.
@MainActor
@Observable
public final class PlaidSyncCoordinator {
    public enum Phase: Sendable, Equatable {
        case idle
        case syncing
        case error(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var lastSyncedAt: Date?

    private let client: any PlaidClient
    private let mainContext: ModelContext

    public init(client: any PlaidClient, mainContext: ModelContext) {
        self.client = client
        self.mainContext = mainContext
    }

    @discardableResult
    public func syncAll() async -> Bool {
        guard phase != .syncing else { return false }
        phase = .syncing
        do {
            let snapshot = try await client.holdings().toSnapshot()
            upsert(snapshot)
            guard mainContext.safeSave(source: "plaidSync.cache") else {
                mainContext.rollback()
                phase = .error("Saving investment data failed. Retry in a moment.")
                return false
            }
            lastSyncedAt = .now
            phase = .idle
            return true
        } catch let error as PlaidClientError {
            mainContext.rollback()
            if error == .cancelled {
                phase = .idle
            } else {
                phase = .error(message(for: error))
            }
            return false
        } catch is CancellationError {
            mainContext.rollback()
            phase = .idle
            return false
        } catch {
            mainContext.rollback()
            phase = .error("Investment sync failed. Try again.")
            return false
        }
    }

    private func upsert(_ snapshot: PlaidInvestmentSnapshot) {
        let existingItems = (try? mainContext.fetch(FetchDescriptor<CachedPlaidItem>())) ?? []
        let itemsByID = Dictionary(uniqueKeysWithValues: existingItems.map { ($0.id, $0) })
        for item in snapshot.items {
            if let row = itemsByID[item.id] {
                row.institutionName = item.institutionName
                row.status = item.status
                row.lastSyncedAt = item.lastSyncedAt
                row.productsRaw = row.products.union(["investments"]).sorted().joined(separator: ",")
            } else {
                mainContext.insert(CachedPlaidItem(
                    id: item.id,
                    institutionName: item.institutionName,
                    status: item.status,
                    lastSyncedAt: item.lastSyncedAt,
                    products: ["investments"]
                ))
            }
        }

        let existingAccounts = (try? mainContext.fetch(FetchDescriptor<CachedPlaidAccount>())) ?? []
        let accountsByID = Dictionary(uniqueKeysWithValues: existingAccounts.map { ($0.id, $0) })
        for account in snapshot.accounts {
            if let row = accountsByID[account.id] {
                apply(account, to: row)
            } else {
                mainContext.insert(CachedPlaidAccount(
                    id: account.id,
                    itemId: account.itemId,
                    institutionName: account.institutionName,
                    name: account.name,
                    officialName: account.officialName,
                    mask: account.mask,
                    typeRaw: "investment",
                    subtype: account.subtype,
                    currentBalanceMilliunits: account.currentBalance?.milliunits,
                    availableBalanceMilliunits: account.availableBalance?.milliunits,
                    limitMilliunits: nil,
                    isoCurrencyCode: account.isoCurrencyCode,
                    unofficialCurrencyCode: account.unofficialCurrencyCode
                ))
            }
        }

        let existingSecurities = (try? mainContext.fetch(FetchDescriptor<CachedPlaidSecurity>())) ?? []
        let securitiesByID = Dictionary(uniqueKeysWithValues: existingSecurities.map { ($0.id, $0) })
        for security in snapshot.securities {
            if let row = securitiesByID[security.id] {
                apply(security, to: row)
            } else {
                mainContext.insert(CachedPlaidSecurity(
                    id: security.id,
                    name: security.name,
                    tickerSymbol: security.tickerSymbol,
                    typeRaw: security.type,
                    closePriceMilliunits: security.closePrice?.milliunits,
                    closePriceAsOf: security.closePriceAsOf,
                    isoCurrencyCode: security.isoCurrencyCode,
                    unofficialCurrencyCode: security.unofficialCurrencyCode
                ))
            }
        }

        let existingHoldings = (try? mainContext.fetch(FetchDescriptor<CachedPlaidHolding>())) ?? []
        let holdingsByID = Dictionary(uniqueKeysWithValues: existingHoldings.map { ($0.id, $0) })
        for holding in snapshot.holdings {
            let quantity = NSDecimalNumber(decimal: holding.quantity).stringValue
            if let row = holdingsByID[holding.id] {
                row.accountId = holding.accountId
                row.securityId = holding.securityId
                row.quantityDecimalString = quantity
                row.institutionValueMilliunits = holding.institutionValue.milliunits
                row.costBasisMilliunits = holding.costBasis?.milliunits
                row.asOf = holding.asOf
            } else {
                mainContext.insert(CachedPlaidHolding(
                    id: holding.id,
                    accountId: holding.accountId,
                    securityId: holding.securityId,
                    quantityDecimalString: quantity,
                    institutionValueMilliunits: holding.institutionValue.milliunits,
                    costBasisMilliunits: holding.costBasis?.milliunits,
                    asOf: holding.asOf
                ))
            }
        }

        let itemIDs = Set(snapshot.items.map(\.id))
        for row in existingItems where !itemIDs.contains(row.id) {
            mainContext.delete(row)
        }
        let accountIDs = Set(snapshot.accounts.map(\.id))
        for row in existingAccounts where !accountIDs.contains(row.id) {
            mainContext.delete(row)
        }
        let securityIDs = Set(snapshot.securities.map(\.id))
        for row in existingSecurities where !securityIDs.contains(row.id) {
            mainContext.delete(row)
        }
        let holdingIDs = Set(snapshot.holdings.map(\.id))
        for row in existingHoldings where !holdingIDs.contains(row.id) {
            mainContext.delete(row)
        }
        ensurePendingTreatments(for: snapshot.accounts)
    }

    private func apply(_ account: PlaidInvestmentAccount, to row: CachedPlaidAccount) {
        row.itemId = account.itemId
        row.institutionName = account.institutionName
        row.name = account.name
        row.officialName = account.officialName
        row.mask = account.mask
        row.typeRaw = "investment"
        row.subtype = account.subtype
        row.currentBalanceMilliunits = account.currentBalance?.milliunits
        row.availableBalanceMilliunits = account.availableBalance?.milliunits
        row.limitMilliunits = nil
        row.isoCurrencyCode = account.isoCurrencyCode
        row.unofficialCurrencyCode = account.unofficialCurrencyCode
    }

    private func apply(_ security: PlaidSecurity, to row: CachedPlaidSecurity) {
        row.name = security.name
        row.tickerSymbol = security.tickerSymbol
        row.typeRaw = security.type
        row.closePriceMilliunits = security.closePrice?.milliunits
        row.closePriceAsOf = security.closePriceAsOf
        row.isoCurrencyCode = security.isoCurrencyCode
        row.unofficialCurrencyCode = security.unofficialCurrencyCode
    }

    private func ensurePendingTreatments(for accounts: [PlaidInvestmentAccount]) {
        let existing = (try? mainContext.fetch(FetchDescriptor<DurablePlaidAccountTreatment>())) ?? []
        let existingIDs = Set(existing.map(\.plaidAccountId))
        for account in accounts where !existingIDs.contains(account.id) {
            mainContext.insert(DurablePlaidAccountTreatment(plaidAccountId: account.id))
        }
    }

    private func message(for error: PlaidClientError) -> String {
        switch error {
        case .missingConfiguration:
            return "Plaid backend setup is incomplete."
        case .unauthorized:
            return "The Plaid backend token was rejected."
        case .invalidResponse:
            return "The investment service returned an error."
        case .decoding:
            return "The investment response could not be read."
        case .transport:
            return "The investment service could not be reached."
        case .cancelled:
            return ""
        }
    }
}

// MARK: - Plaid banking transactions

enum LegacyReimbursementRepresentation {
    /// The former YNAB reimbursement envelope found in the single-user data.
    /// It is now represented by TransactionType.reimbursement, never by a
    /// spending category.
    static let retiredYNABCategoryID =
        "66ebfc38-ecbe-4f5c-89ab-43ef07edb560"
    static let retiredCanonicalCategoryID =
        "ynab:\(retiredYNABCategoryID)"

    static func matches(_ leg: SubTransactionSummary) -> Bool {
        leg.goalId == nil
            && isLegacyTreatment(leg.forecastTreatment)
            && isRetiredCategory(
                categoryId: leg.categoryId,
                categoryCanonicalId: leg.categoryCanonicalId,
                rawValue: nil,
                name: leg.categoryName
            )
    }

    static func matchesWholeTransaction(
        treatmentRaw: String,
        categoryCanonicalId: String?,
        categoryRaw: String?,
        categoryName: String?,
        goalId: UUID?
    ) -> Bool {
        goalId == nil
            && isLegacyTreatment(TransactionType(rawValue: treatmentRaw))
            && isRetiredCategory(
                categoryId: nil,
                categoryCanonicalId: categoryCanonicalId,
                rawValue: categoryRaw,
                name: categoryName
            )
    }

    static func repaired(_ leg: SubTransactionSummary) -> SubTransactionSummary {
        SubTransactionSummary(
            id: leg.id,
            amount: leg.amount,
            categoryId: nil,
            categoryName: nil,
            categoryCanonicalId: nil,
            goalId: nil,
            forecastTreatment: .reimbursement,
            transferAccountId: leg.transferAccountId,
            payeeName: leg.payeeName,
            memo: leg.memo,
            deleted: leg.deleted
        )
    }

    static func parentTreatment(
        for legs: [SubTransactionSummary]
    ) -> TransactionType {
        let types = Set(legs.compactMap(\.forecastTreatment))
        return types.count == 1 ? types.first ?? .unknown : .unknown
    }

    private static func isLegacyTreatment(_ value: TransactionType?) -> Bool {
        value == nil || value == .ordinarySpending || value == .refund
    }

    private static func isRetiredCategory(
        categoryId: String?,
        categoryCanonicalId: String?,
        rawValue: String?,
        name: String?
    ) -> Bool {
        if categoryId == retiredYNABCategoryID
            || categoryCanonicalId == retiredCanonicalCategoryID {
            return true
        }
        if rawValue?.localizedCaseInsensitiveCompare("reimbursements")
            == .orderedSame {
            return true
        }
        return isRetiredCategoryName(name)
    }

    static func isRetiredCategoryName(_ name: String?) -> Bool {
        let normalizedName = name?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalizedName == "reimbursement"
            || normalizedName == "reimbursements"
            || normalizedName == "reimbursement - $5k"
    }
}

@MainActor
struct LegacyReimbursementRepairService {
    struct Result: Equatable {
        var cachedTransactions = 0
        var durableDecisions = 0
        var durableOverrides = 0
        var merchantRules = 0
        var canonicalCategories = 0
        var undecodablePayloads = 0

        var repairedRecords: Int {
            cachedTransactions + durableDecisions + durableOverrides
                + merchantRules + canonicalCategories
        }
    }

    private enum SplitRepair {
        case unchanged
        case repaired(Data, TransactionType)
        case undecodable
    }

    let context: ModelContext

    func repair() throws -> Result {
        var result = Result()

        for row in try context.fetch(
            FetchDescriptor<CachedFinancialTransaction>()
        ) {
            if let data = row.subtransactionsData, !data.isEmpty {
                switch try repairSplitData(data) {
                case .unchanged:
                    break
                case .undecodable:
                    result.undecodablePayloads += 1
                case .repaired(let repairedData, let parentTreatment):
                    row.subtransactionsData = repairedData
                    row.forecastTreatmentRaw = parentTreatment.rawValue
                    row.updatedAt = .now
                    result.cachedTransactions += 1
                }
            } else if LegacyReimbursementRepresentation
                .matchesWholeTransaction(
                treatmentRaw: row.forecastTreatmentRaw,
                categoryCanonicalId: row.categoryCanonicalId,
                categoryRaw: row.nativeCategoryRaw,
                categoryName: row.categoryName,
                goalId: row.goalId
            ) {
                row.forecastTreatmentRaw = TransactionType.reimbursement.rawValue
                row.nativeCategoryRaw = "other"
                row.categoryCanonicalId = nil
                row.categoryName = nil
                row.updatedAt = .now
                result.cachedTransactions += 1
            }
        }

        for decision in try context.fetch(
            FetchDescriptor<DurableCanonicalTransactionDecision>()
        ) {
            if let data = decision.subtransactionsData, !data.isEmpty {
                switch try repairSplitData(data) {
                case .unchanged:
                    break
                case .undecodable:
                    result.undecodablePayloads += 1
                case .repaired(let repairedData, let parentTreatment):
                    decision.subtransactionsData = repairedData
                    decision.forecastTreatmentRaw = parentTreatment.rawValue
                    decision.updatedAt = .now
                    result.durableDecisions += 1
                }
            } else if LegacyReimbursementRepresentation
                .matchesWholeTransaction(
                treatmentRaw: decision.forecastTreatmentRaw,
                categoryCanonicalId: decision.categoryCanonicalId,
                categoryRaw: nil,
                categoryName: decision.categoryNameSnapshot,
                goalId: decision.goalId
            ) {
                decision.forecastTreatment = .reimbursement
                decision.categoryCanonicalId = nil
                decision.categoryNameSnapshot = nil
                decision.updatedAt = .now
                result.durableDecisions += 1
            }
        }

        for override in try context.fetch(
            FetchDescriptor<DurableTransactionOverride>()
        ) {
            if let data = override.subtransactionsData, !data.isEmpty {
                switch try repairSplitData(data) {
                case .unchanged:
                    break
                case .undecodable:
                    result.undecodablePayloads += 1
                case .repaired(let repairedData, let parentTreatment):
                    override.subtransactionsData = repairedData
                    override.forecastTreatmentRaw = parentTreatment.rawValue
                    override.updatedAt = .now
                    result.durableOverrides += 1
                }
            } else if LegacyReimbursementRepresentation
                .matchesWholeTransaction(
                    treatmentRaw: override.forecastTreatmentRaw,
                    categoryCanonicalId: nil,
                    categoryRaw: override.categoryRaw,
                    categoryName: override.categoryName,
                    goalId: nil
                ) {
                override.forecastTreatmentRaw =
                    TransactionType.reimbursement.rawValue
                override.categoryRaw = "other"
                override.categoryName = nil
                override.updatedAt = .now
                result.durableOverrides += 1
            }
        }

        for rule in try context.fetch(
            FetchDescriptor<DurableMerchantRule>()
        ) where LegacyReimbursementRepresentation.matchesWholeTransaction(
            treatmentRaw: rule.forecastTreatmentRaw,
            categoryCanonicalId: nil,
            categoryRaw: rule.categoryRaw,
            categoryName: rule.categoryName,
            goalId: nil
        ) {
            rule.forecastTreatmentRaw = TransactionType.reimbursement.rawValue
            rule.categoryRaw = "other"
            rule.categoryName = nil
            rule.categoryReusable = false
            rule.updatedAt = .now
            result.merchantRules += 1
        }

        for category in try context.fetch(
            FetchDescriptor<DurableCanonicalCategory>()
        ) where category.canonicalId
            == LegacyReimbursementRepresentation.retiredCanonicalCategoryID
            || LegacyReimbursementRepresentation
                .isRetiredCategoryName(category.name)
            || LegacyReimbursementRepresentation
                .isRetiredCategoryName(category.sourceName) {
            category.hidden = true
            category.categoryGroupIdentity = nil
            category.updatedAt = .now
            result.canonicalCategories += 1
        }

        return result
    }

    private func repairSplitData(_ data: Data) throws -> SplitRepair {
        guard let legs = try? JSONDecoder().decode(
            [SubTransactionSummary].self,
            from: data
        ) else {
            return .undecodable
        }
        var changed = false
        let repairedLegs = legs.map { leg in
            guard LegacyReimbursementRepresentation.matches(leg) else {
                return leg
            }
            changed = true
            return LegacyReimbursementRepresentation.repaired(leg)
        }
        guard changed else { return .unchanged }
        return .repaired(
            try JSONEncoder().encode(repairedLegs),
            LegacyReimbursementRepresentation.parentTreatment(
                for: repairedLegs
            )
        )
    }
}

/// Pulls transaction deltas through the private Worker, normalizes them into
/// the provider-neutral cache, and advances each Plaid cursor only after the
/// matching SwiftData page has been saved successfully.
@MainActor
@Observable
public final class PlaidTransactionSyncCoordinator {
    /// Internal (not private) so tests can assert cursors reach the current
    /// reconciliation marker without hardcoding its value.
    static let currentHistoricalReconciliationVersion = 13
    /// Internal so tests can verify the current migration marker without
    /// hardcoding it.
    static let currentCanonicalTransactionDataVersion = 2

    public enum Phase: Sendable, Equatable {
        case idle
        case syncing(String)
        case error(String)
    }

    public enum SplitReviewFailure: LocalizedError, Equatable {
        case transactionUnavailable
        case transactionPending
        case needsTwoParts
        case emptyPart
        case amountsDoNotBalance
        case contactUnavailable
        case goalsUnavailable
        case reservesUnavailable
        case invalidType
        case categoryUnavailable(String)
        case categoryIncompatible(String)
        case goalUnavailable
        case reserveUnavailable
        case savingsUnavailable
        case encodingFailed
        case saveFailed

        public var errorDescription: String? {
            switch self {
            case .transactionUnavailable:
                "This transaction is no longer available."
            case .transactionPending:
                "This transaction is still pending and cannot be edited yet."
            case .needsTwoParts:
                "A split transaction needs at least two parts."
            case .emptyPart:
                "Every split must have an amount."
            case .amountsDoNotBalance:
                "The split amounts do not equal the transaction total."
            case .contactUnavailable:
                "The selected contact could not be saved."
            case .goalsUnavailable:
                "Goals could not be loaded."
            case .reservesUnavailable:
                "Reserves could not be loaded."
            case .invalidType:
                "One split has a type that does not match this deposit."
            case .categoryUnavailable(let name):
                "The category \"\(name)\" is no longer available."
            case .categoryIncompatible(let name):
                "The category \"\(name)\" cannot be used with that transaction type."
            case .goalUnavailable:
                "The selected goal is no longer active."
            case .reserveUnavailable:
                "The selected reserve is no longer active."
            case .savingsUnavailable:
                "Choose a Savings month for every Savings split."
            case .encodingFailed:
                "The split details could not be prepared for saving."
            case .saveFailed:
                "The transaction could not be saved. Your changes are still on screen."
            }
        }
    }

    public private(set) var phase: Phase = .idle
    public private(set) var lastSyncedAt: Date?
    public private(set) var pendingTransactionReviewCount: Int = 0
    public private(set) var unresolvedPayeeReviewCount: Int = 0
    public private(set) var canonicalReviewReady: Bool = false

    private let client: any PlaidClient
    private let inferenceProvider: any OnDeviceTransactionInferring
    private let mainContext: ModelContext
    private let classifier = TransactionClassifier()
    private let logger = Logger(
        subsystem: "com.bluelava.me.networth",
        category: "plaid-transaction-sync"
    )

    public init(
        client: any PlaidClient,
        inferenceProvider: any OnDeviceTransactionInferring,
        mainContext: ModelContext
    ) {
        self.client = client
        self.inferenceProvider = inferenceProvider
        self.mainContext = mainContext
    }

    /// Applies cache/durable migrations that do not require a network request.
    /// This must run at bootstrap so a recently completed sync cannot delay a
    /// newer reconciliation rule behind the 15-minute freshness window.
    public func runLocalMigrationsIfNeeded() {
        reanchorCivilDatesIfNeeded()
        let deduplicated = deduplicateCanonicalDirectory()
        let backfilledDirection = backfillCanonicalDecisionDirection()
        let canonicalDirectoryChanged =
            deduplicated || backfilledDirection
        if canonicalDirectoryChanged,
           !mainContext.safeSave(
               source: "plaidTransactions.canonicalDeduplication"
           ) {
            mainContext.rollback()
            return
        }
        guard repairLegacyReimbursements() else { return }
        if markOrphanedTransactionsDeleted(),
           !mainContext.safeSave(
               source: "plaidTransactions.orphanedTransactions"
           ) {
            mainContext.rollback()
            return
        }
        refreshCanonicalReviewCounts()
    }

    private func repairLegacyReimbursements() -> Bool {
        // v4 targets the actual historical YNAB envelope identity found in
        // the device store. v1-v3 matched only generic names/raw codes.
        let markerKey = "legacyReimbursementRepair:v4"
        do {
            let marker = try mainContext.fetch(
                FetchDescriptor<SyncCursor>(
                    predicate: #Predicate { $0.key == markerKey }
                )
            )
            guard marker.isEmpty else { return true }
            let result = try LegacyReimbursementRepairService(
                context: mainContext
            ).repair()
            mainContext.insert(SyncCursor(
                key: markerKey,
                serverKnowledge: 1
            ))
            if !mainContext.safeSave(
                source: "plaidTransactions.legacyReimbursementRepair"
            ) {
                mainContext.rollback()
                return false
            }
            if result.repairedRecords > 0 {
                logger.info(
                    "Repaired \(result.repairedRecords) legacy reimbursement records."
                )
            }
            if result.undecodablePayloads > 0 {
                logger.error(
                    "Preserved \(result.undecodablePayloads) undecodable split payloads during reimbursement repair."
                )
            }
            return true
        } catch {
            mainContext.rollback()
            logger.error(
                "Legacy reimbursement repair failed: \(error.localizedDescription, privacy: .private)"
            )
            return false
        }
    }

    /// One-time cache repair: civil dates were historically parsed at
    /// midnight UTC, which local-timezone display renders as the previous
    /// day anywhere west of UTC. Parsing now anchors to local midnight;
    /// this shifts rows persisted under the old anchoring onto the same
    /// civil day at local midnight. Each shift fires only for
    /// exact-UTC-midnight values, so a re-run is a no-op even without the
    /// cursor guard.
    private func reanchorCivilDatesIfNeeded() {
        let key = "civilDateAnchoring:v1"
        let done = (try? mainContext.fetch(
            FetchDescriptor<SyncCursor>(predicate: #Predicate { $0.key == key })
        ).isEmpty == false) ?? false
        guard !done else { return }

        var changed = 0
        for row in (try? mainContext.fetch(
            FetchDescriptor<CachedTransaction>()
        )) ?? [] {
            if let fixed = CivilDate.reanchoredFromUTCMidnight(row.date) {
                row.date = fixed
                changed += 1
            }
        }
        for row in (try? mainContext.fetch(
            FetchDescriptor<CachedScheduledTransaction>()
        )) ?? [] {
            if let fixed = CivilDate.reanchoredFromUTCMidnight(row.nextDate) {
                row.nextDate = fixed
                changed += 1
            }
            if let first = row.firstDate,
               let fixed = CivilDate.reanchoredFromUTCMidnight(first) {
                row.firstDate = fixed
                changed += 1
            }
        }
        for row in (try? mainContext.fetch(
            FetchDescriptor<CachedFinancialTransaction>()
        )) ?? [] {
            if let fixed = CivilDate.reanchoredFromUTCMidnight(row.postedDate) {
                row.postedDate = fixed
                changed += 1
            }
            if let authorized = row.authorizedDate,
               let fixed = CivilDate.reanchoredFromUTCMidnight(authorized) {
                row.authorizedDate = fixed
                changed += 1
            }
        }
        for row in (try? mainContext.fetch(
            FetchDescriptor<DurableExcludedSpendTransaction>()
        )) ?? [] {
            if let fixed = CivilDate.reanchoredFromUTCMidnight(
                row.transactionDate
            ) {
                row.transactionDate = fixed
                changed += 1
            }
        }

        mainContext.insert(SyncCursor(key: key, serverKnowledge: 1))
        guard mainContext.safeSave(
            source: "plaidTransactions.civilDateReanchor"
        ) else {
            mainContext.rollback()
            return
        }
        logger.info("Re-anchored \(changed) civil dates to local midnight.")
    }

    /// A completed reconciliation is valid only for the YNAB cache it read.
    /// YNAB delta sync can add or change canonical contacts, categories, and
    /// transactions after that marker was written, so make the next Plaid
    /// pass replay history against the updated source.
    public func invalidateHistoricalReconciliationForYNABChanges() {
        invalidateHistoricalReconciliation()
        guard mainContext.safeSave(
            source: "plaidTransactions.invalidateAfterYNABSync"
        ) else {
            mainContext.rollback()
            return
        }
        refreshCanonicalReviewCounts()
    }

    /// A delta cursor can legitimately return no category/payee rows even
    /// though the old disposable cache is populated. If the new canonical
    /// table is empty, clear only that source cursor so the next ordinary YNAB
    /// sync performs a full directory replay. Do not touch Plaid rows,
    /// aliases, or transaction decisions.
    private func prepareMissingCanonicalDirectoryReplay() -> Bool {
        let canonicalPayees = (try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalPayee>()
        )) ?? []
        let canonicalCategories = (try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalCategory>()
        )) ?? []
        let cursors = (try? mainContext.fetch(
            FetchDescriptor<SyncCursor>()
        )) ?? []

        let needsPayeeReplay = canonicalPayees.isEmpty
            && cursors.contains { $0.key.hasPrefix("payees:") }
        let needsCategoryReplay = canonicalCategories.isEmpty
            && cursors.contains { $0.key.hasPrefix("categories:") }
        guard needsPayeeReplay || needsCategoryReplay else {
            return false
        }

        for cursor in cursors {
            if needsPayeeReplay && cursor.key.hasPrefix("payees:") {
                mainContext.delete(cursor)
            }
            if needsCategoryReplay
                && cursor.key.hasPrefix("categories:") {
                mainContext.delete(cursor)
            }
        }
        invalidateHistoricalReconciliation()
        let settings = (try? mainContext.fetch(
            FetchDescriptor<DurableUserSettings>()
        ))?.first
        if settings?.primaryFinancialDataSource == .ynab {
            settings?.lastSyncedAt = nil
        }
        return true
    }

    private func backfillCanonicalDecisionDirection() -> Bool {
        let decisions = (try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalTransactionDecision>()
        )) ?? []
        let missing = decisions.filter { $0.amountSign == 0 }
        guard !missing.isEmpty else { return false }
        let rows = (try? mainContext.fetch(
            FetchDescriptor<CachedFinancialTransaction>()
        )) ?? []
        var amountByExternalID: [String: Int64] = [:]
        for row in rows {
            amountByExternalID[row.externalId] = row.amountMilliunits
        }
        var changed = false
        for decision in missing {
            guard let amount =
                    amountByExternalID[decision.transactionExternalId],
                  amount != 0 else {
                continue
            }
            decision.amountSign = Int(amount.signum())
            decision.updatedAt = .now
            changed = true
        }
        return changed
    }

    /// CloudKit can deliver logically identical rows created on two devices.
    /// Stable string IDs are the real identity; keep the newest row for each
    /// identity before building dictionaries or presenting management UI.
    private func deduplicateCanonicalDirectory() -> Bool {
        var changed = false

        let payees = (try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalPayee>()
        )) ?? []
        for group in Dictionary(
            grouping: payees,
            by: \.canonicalId
        ).values where group.count > 1 {
            let ordered = group.sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.updatedAt > rhs.updatedAt
            }
            for duplicate in ordered.dropFirst() {
                mainContext.delete(duplicate)
                changed = true
            }
        }

        let categories = (try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalCategory>()
        )) ?? []
        for group in Dictionary(
            grouping: categories,
            by: \.canonicalId
        ).values where group.count > 1 {
            let ordered = group.sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.updatedAt > rhs.updatedAt
            }
            for duplicate in ordered.dropFirst() {
                mainContext.delete(duplicate)
                changed = true
            }
        }

        let decisions = (try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalTransactionDecision>()
        )) ?? []
        for group in Dictionary(
            grouping: decisions,
            by: \.transactionExternalId
        ).values where group.count > 1 {
            let ordered = group.sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.updatedAt > rhs.updatedAt
            }
            for duplicate in ordered.dropFirst() {
                mainContext.delete(duplicate)
                changed = true
            }
        }

        let aliases = (try? mainContext.fetch(
            FetchDescriptor<DurablePayeeAlias>()
        )) ?? []
        for group in Dictionary(
            grouping: aliases,
            by: { "\($0.aliasKey)|\($0.payeeCanonicalId)" }
        ).values where group.count > 1 {
            let ordered = group.sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.updatedAt > rhs.updatedAt
            }
            for duplicate in ordered.dropFirst() {
                mainContext.delete(duplicate)
                changed = true
            }
        }

        return changed
    }

    @discardableResult
    public func syncAll() async -> Bool {
        // A prior failure must not brick sync until relaunch: retry is
        // allowed from `.error`, only a concurrent run is blocked.
        if case .syncing = phase { return false }
        phase = .syncing("Accounts")
        do {
            let itemsResponse = try await client.items()
            upsertItems(itemsResponse.items)
            let transactionItems = itemsResponse.items.filter {
                ($0.products ?? []).contains("transactions")
            }
            let existingRows = (try? mainContext.fetch(
                FetchDescriptor<CachedFinancialTransaction>()
            )) ?? []
            var existingByID = Dictionary(
                uniqueKeysWithValues: existingRows.map { ($0.id, $0) }
            )
            for item in transactionItems {
                phase = .syncing(item.institutionName)
                guard await sync(
                    item: item,
                    existingByID: &existingByID
                ) else {
                    return false
                }
            }
            markOrphanedTransactionsDeleted()
            applyCurrentCanonicalState()
            guard mainContext.safeSave(
                source: "plaidTransactions.applyCanonicalState"
            ) else {
                mainContext.rollback()
                phase = .error("Saving banking data failed. Retry in a moment.")
                return false
            }
            refreshCanonicalReviewCounts()
            lastSyncedAt = .now
            phase = .idle
            return true
        } catch let error as PlaidClientError {
            mainContext.rollback()
            if error == .cancelled {
                phase = .idle
            } else {
                phase = .error(message(for: error))
            }
            return false
        } catch is CancellationError {
            mainContext.rollback()
            phase = .idle
            return false
        } catch {
            mainContext.rollback()
            phase = .error("Banking sync failed. Try again.")
            return false
        }
    }

    public func mapAccount(plaidAccountId: String, toYNABAccountId ynabAccountId: String?) {
        let bindings = (try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalAccountBinding>()
        )) ?? []
        guard let binding = bindings.first(where: { $0.plaidAccountId == plaidAccountId }) else {
            return
        }
        binding.ynabAccountId = ynabAccountId
        binding.reviewed = true
        binding.updatedAt = .now
        if let ynabAccountId {
            let cardSettings = (try? mainContext.fetch(FetchDescriptor<DurableCardSettings>())) ?? []
            for settings in cardSettings {
                if settings.accountId == ynabAccountId {
                    settings.canonicalAccountId = binding.canonicalAccountId
                }
                if settings.paymentAccountId == ynabAccountId {
                    settings.canonicalPaymentAccountId = binding.canonicalAccountId
                }
            }
            let cashOverrides = (try? mainContext.fetch(
                FetchDescriptor<DurableProjectionCashAccountOverride>()
            )) ?? []
            for override in cashOverrides where override.accountId == ynabAccountId {
                override.canonicalAccountId = binding.canonicalAccountId
            }
            let closedAccounts = (try? mainContext.fetch(
                FetchDescriptor<DurableIncludedClosedAccount>()
            )) ?? []
            for account in closedAccounts where account.accountId == ynabAccountId {
                account.canonicalAccountId = binding.canonicalAccountId
            }
        }
        invalidateHistoricalReconciliation()
        guard mainContext.safeSave(source: "plaidTransactions.mapAccount") else {
            mainContext.rollback()
            return
        }
        reconcileHistoryIfNeeded()
    }

    private func reconcileHistoryIfNeeded() {
        let accounts = (try? mainContext.fetch(
            FetchDescriptor<CachedFinancialAccount>(
                predicate: #Predicate { !$0.deleted }
            )
        )) ?? []
        guard !accounts.isEmpty else { return }

        let cursors = (try? mainContext.fetch(
            FetchDescriptor<PlaidTransactionCursor>()
        )) ?? []
        guard !cursors.isEmpty,
              cursors.allSatisfy(\.historicalImportComplete),
              cursors.contains(where: {
                  $0.historicalReconciliationVersion
                      < Self.currentHistoricalReconciliationVersion
              }) else {
            return
        }

        // After the Plaid-first clean start the YNAB cache never repopulates
        // during normal operation, so with no legacy rows there is nothing to
        // reconcile and no YNAB account mapping to wait for. The marker must
        // still advance, or transaction review would stay locked forever.
        let legacyRowCount = (try? mainContext.fetchCount(
            FetchDescriptor<CachedTransaction>()
        )) ?? 0
        if legacyRowCount == 0 {
            markHistoricalReconciliationComplete()
            guard mainContext.safeSave(
                source: "plaidTransactions.reconciliationNotNeeded"
            ) else {
                mainContext.rollback()
                return
            }
            refreshCanonicalReviewCounts()
            return
        }

        let activePlaidIDs = Set(accounts.map(\.externalId))
        let bindings = ((try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalAccountBinding>()
        )) ?? []).filter { activePlaidIDs.contains($0.plaidAccountId) }
        guard bindings.count == activePlaidIDs.count,
              bindings.allSatisfy(\.reviewed) else {
            return
        }
        reconcileHistory()
    }

    public func reconcileHistory() {
        let bindings = (try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalAccountBinding>()
        )) ?? []
        let ynabMap = Dictionary(
            uniqueKeysWithValues: bindings.compactMap { binding -> (String, String)? in
                guard binding.reviewed, let ynabID = binding.ynabAccountId else { return nil }
                return (ynabID, binding.canonicalAccountId)
            }
        )
        guard !ynabMap.isEmpty else { return }
        let canonicalPayees = (try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalPayee>()
        )) ?? []
        let canonicalCategories = (try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalCategory>()
        )) ?? []
        // A complete YNAB-derived directory is a prerequisite. Never clear or
        // rewrite durable decisions when the disposable source cache is absent.
        guard !canonicalPayees.isEmpty, !canonicalCategories.isEmpty else {
            return
        }

        let oldMatches = (try? mainContext.fetch(
            FetchDescriptor<LegacyTransactionMatchRow>()
        )) ?? []
        oldMatches.forEach(mainContext.delete)

        let legacyRows = (try? mainContext.fetch(FetchDescriptor<CachedTransaction>())) ?? []
        guard !legacyRows.isEmpty else { return }
        let financialRows = (try? mainContext.fetch(
            FetchDescriptor<CachedFinancialTransaction>()
        )) ?? []
        let plaidSummaries = financialRows
            .filter { !$0.deleted && !$0.pending && $0.sourceRaw == FinancialDataSource.plaid.rawValue }
            .map { $0.toSummary() }
        let matches = HistoricalTransactionMatcher().matches(
            legacy: legacyRows.map { $0.toSummary() },
            plaid: plaidSummaries,
            canonicalAccountIdByYNABId: ynabMap
        )
        for match in matches {
            mainContext.insert(
                LegacyTransactionMatchRow(
                    plaidTransactionId: match.plaidTransactionId,
                    ynabTransactionId: match.legacyTransactionId,
                    confidence: match.confidence,
                    score: match.score,
                    automatic: match.isAutomatic
                )
            )
        }
        applyCanonicalHistory(
            matches: matches,
            legacyRows: legacyRows,
            financialRows: financialRows,
            payees: canonicalPayees,
            categories: canonicalCategories
        )
        markHistoricalReconciliationComplete()
        guard mainContext.safeSave(
            source: "plaidTransactions.canonicalReconciliation"
        ) else {
            mainContext.rollback()
            return
        }
        refreshCanonicalReviewCounts()
    }

    /// One-time rebuild of all transaction-derived state. Raw YNAB and Plaid
    /// source rows, account mappings, connections, settings, snapshots, and
    /// manual assets remain untouched. Contacts and categories replay from
    /// YNAB before the retained Plaid history is reconciled again.
    private func resetDerivedTransactionDataIfNeeded() {
        var settingsRows = (try? mainContext.fetch(
            FetchDescriptor<DurableUserSettings>()
        )) ?? []
        if settingsRows.isEmpty {
            let settings = DurableUserSettings()
            mainContext.insert(settings)
            settingsRows = [settings]
        }
        guard settingsRows.contains(where: {
            $0.canonicalTransactionDataVersion
                < Self.currentCanonicalTransactionDataVersion
        }) else {
            return
        }

        ((try? mainContext.fetch(
            FetchDescriptor<DurableMerchantRule>()
        )) ?? []).forEach(mainContext.delete)
        ((try? mainContext.fetch(
            FetchDescriptor<DurableTransactionCategory>()
        )) ?? []).forEach(mainContext.delete)
        ((try? mainContext.fetch(
            FetchDescriptor<DurableTransactionOverride>()
        )) ?? []).forEach(mainContext.delete)
        ((try? mainContext.fetch(
            FetchDescriptor<DurablePayeeAlias>()
        )) ?? []).forEach(mainContext.delete)
        ((try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalTransactionDecision>()
        )) ?? []).forEach(mainContext.delete)
        ((try? mainContext.fetch(
            FetchDescriptor<LegacyTransactionMatchRow>()
        )) ?? []).forEach(mainContext.delete)
        ((try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalPayee>()
        )) ?? []).forEach(mainContext.delete)
        ((try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalCategory>()
        )) ?? []).forEach(mainContext.delete)

        let financialRows = (try? mainContext.fetch(
            FetchDescriptor<CachedFinancialTransaction>()
        )) ?? []
        for row in financialRows {
            let summary = row.toSummary()
            let sourceClassification = reviewClassification(
                classifier.classify(summary, rules: []),
                transaction: summary
            )
            row.displayName = sourceClassification.displayName
            row.payeeCanonicalId = nil
            row.categoryCanonicalId = nil
            row.categoryName = nil
            row.subtransactionsData = nil
            row.nativeCategoryRaw = "other"
            row.forecastTreatmentRaw =
                sourceClassification.treatment.rawValue
            row.classificationConfidenceRaw =
                sourceClassification.confidence.rawValue
            row.requiresNameReview = !row.pending
            row.requiresReview = !row.pending
            row.classificationProvenanceRaw =
                ClassificationProvenance.plaidEnrichment.rawValue
            row.updatedAt = .now
        }

        // Force one authoritative YNAB replay before canonical matching.
        let syncCursors = (try? mainContext.fetch(
            FetchDescriptor<SyncCursor>()
        )) ?? []
        for cursor in syncCursors where
            cursor.key.hasPrefix("transactions:")
                || cursor.key.hasPrefix("payees:")
                || cursor.key.hasPrefix("categories:") {
            mainContext.delete(cursor)
        }
        invalidateHistoricalReconciliation()
        // CloudKit can temporarily surface duplicate singleton settings rows.
        // Mark every copy so row ordering cannot skip or repeat this reset.
        for settings in settingsRows {
            settings.lastSyncedAt = nil
            settings.canonicalTransactionDataVersion =
                Self.currentCanonicalTransactionDataVersion
        }
        guard mainContext.safeSave(
            source: "plaidTransactions.resetDerivedTransactionData"
        ) else {
            mainContext.rollback()
            return
        }
    }

    private func applyCanonicalHistory(
        matches: [HistoricalTransactionMatch],
        legacyRows: [CachedTransaction],
        financialRows: [CachedFinancialTransaction],
        payees: [DurableCanonicalPayee],
        categories: [DurableCanonicalCategory]
    ) {
        let legacyByID = Dictionary(
            uniqueKeysWithValues: legacyRows.map { ($0.id, $0) }
        )
        let financialByID = Dictionary(
            uniqueKeysWithValues: financialRows.map { ($0.id, $0) }
        )
        var payeeByYNABID: [String: DurableCanonicalPayee] = [:]
        for payee in payees.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            if let ynabID = payee.ynabPayeeId {
                payeeByYNABID[ynabID] = payee
            }
        }
        let payeesByName = Dictionary(
            grouping: payees.filter { !$0.archived },
            by: {
                FinancialTransactionSummary.normalizedDescription($0.name)
            }
        )
        var categoryByYNABID: [String: DurableCanonicalCategory] = [:]
        for category in categories.sorted(by: {
            $0.updatedAt < $1.updatedAt
        }) {
            if let ynabID = category.ynabCategoryId {
                categoryByYNABID[ynabID] = category
            }
        }
        let ynabAccounts = (try? mainContext.fetch(
            FetchDescriptor<CachedAccount>()
        )) ?? []
        let creditCardIDs = Set(
            ynabAccounts.filter { $0.kind.isCreditCardLike }.map(\.id)
        )
        let persistedDecisions = (try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalTransactionDecision>()
        )) ?? []
        // YNAB-derived decisions are a reproducible cache of the current
        // reconciliation, not user data. Rebuild them from the authoritative
        // source while preserving explicit user confirmations.
        for decision in persistedDecisions where
            decision.provenanceRaw
                != ClassificationProvenance.user.rawValue {
            mainContext.delete(decision)
        }
        var decisions = persistedDecisions.filter {
            $0.provenanceRaw == ClassificationProvenance.user.rawValue
        }
        var decisionByTransactionID =
            latestCanonicalDecisionsByTransactionID(decisions)
        let persistedAliases = (try? mainContext.fetch(
            FetchDescriptor<DurablePayeeAlias>()
        )) ?? []
        for alias in persistedAliases where
            alias.provenanceRaw
                != ClassificationProvenance.user.rawValue {
            mainContext.delete(alias)
        }
        let existingAliases = persistedAliases.filter {
            $0.provenanceRaw == ClassificationProvenance.user.rawValue
        }
        var aliasesByKey = Dictionary(
            grouping: existingAliases,
            by: \.aliasKey
        )
        var learnedPayeesByEvidence: [String: Set<String>] = [:]
        var evidenceByKey: [String: PayeeIdentityEvidence] = [:]
        let encoder = JSONEncoder()

        for match in matches where match.isAutomatic {
            guard let legacy = legacyByID[match.legacyTransactionId],
                  let financial = financialByID[match.plaidTransactionId]
            else {
                continue
            }
            let payee = canonicalPayee(
                for: legacy,
                payeeByYNABID: payeeByYNABID,
                payeesByName: payeesByName
            )
            let category = legacy.categoryId.flatMap {
                categoryByYNABID[$0]
            }
            let payeeName = payee?.name
                ?? legacy.payeeName?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                ?? financial.toSummary().fallbackDisplayName
            let splitData = legacy.subtransactions.isEmpty
                ? nil
                : try? encoder.encode(legacy.subtransactions)
            let treatment = historicalTreatment(
                for: legacy,
                creditCardIDs: creditCardIDs
            )

            let decision: DurableCanonicalTransactionDecision
            if let existing = decisionByTransactionID[
                financial.externalId
            ] {
                decision = existing
                // Explicit user edits always outrank a later history rebuild.
                if decision.provenanceRaw
                    != ClassificationProvenance.user.rawValue {
                    decision.ynabTransactionId = legacy.id
                    decision.payeeCanonicalId = payee?.canonicalId
                    decision.payeeNameSnapshot = payeeName
                    decision.categoryCanonicalId = category?.canonicalId
                    decision.categoryNameSnapshot =
                        category?.name ?? legacy.categoryName
                    decision.goalId = nil
                    decision.amountSign =
                        Int(financial.amountMilliunits.signum())
                    decision.forecastTreatment = treatment
                    decision.subtransactionsData = splitData
                    decision.reviewed = true
                    decision.provenanceRaw =
                        ClassificationProvenance.historicalMatch.rawValue
                    decision.updatedAt = .now
                }
            } else {
                decision = DurableCanonicalTransactionDecision(
                    transactionExternalId: financial.externalId,
                    ynabTransactionId: legacy.id,
                    payeeCanonicalId: payee?.canonicalId,
                    payeeNameSnapshot: payeeName,
                    categoryCanonicalId: category?.canonicalId,
                    categoryNameSnapshot: category?.name
                        ?? legacy.categoryName,
                    amountSign: Int(
                        financial.amountMilliunits.signum()
                    ),
                    forecastTreatment: treatment,
                    subtransactionsData: splitData,
                    reviewed: true,
                    provenance: .historicalMatch
                )
                mainContext.insert(decision)
                decisions.append(decision)
                decisionByTransactionID[financial.externalId] = decision
            }
            applyCanonicalDecision(decision, to: financial)

            if let payee {
                for evidence in financial.toSummary()
                    .payeeIdentityEvidence {
                    learnedPayeesByEvidence[
                        evidence.key,
                        default: []
                    ].insert(payee.canonicalId)
                    evidenceByKey[evidence.key] = evidence
                }
            }
        }

        // An alias is learned only when every exact historical example for
        // that evidence key points to the same YNAB payee.
        for (key, payeeIDs) in learnedPayeesByEvidence
        where payeeIDs.count == 1 {
            guard let payeeID = payeeIDs.first,
                  let evidence = evidenceByKey[key] else {
                continue
            }
            let existingPayeeIDs = Set(
                (aliasesByKey[key] ?? []).map(\.payeeCanonicalId)
            )
            guard existingPayeeIDs.isEmpty
                    || existingPayeeIDs == [payeeID] else {
                continue
            }
            let existingAliases = aliasesByKey[key] ?? []
            guard !existingAliases.contains(where: \.suppressed) else {
                continue
            }
            if let alias = existingAliases.first {
                alias.payeeCanonicalId = payeeID
                alias.displayValue = evidence.displayValue
                alias.kindRaw = evidence.kind
                alias.confirmed = true
                alias.provenanceRaw =
                    ClassificationProvenance.historicalMatch.rawValue
                alias.updatedAt = .now
            } else {
                let alias = DurablePayeeAlias(
                    aliasKey: key,
                    payeeCanonicalId: payeeID,
                    displayValue: evidence.displayValue,
                    kindRaw: evidence.kind,
                    provenance: .historicalMatch,
                    confirmed: true
                )
                mainContext.insert(alias)
                aliasesByKey[key] = [alias]
            }
        }

        applyCanonicalDirectory(
            to: financialRows,
            payees: payees,
            aliasesByKey: aliasesByKey,
            decisions: decisions
        )
    }

    private func canonicalPayee(
        for transaction: CachedTransaction,
        payeeByYNABID: [String: DurableCanonicalPayee],
        payeesByName: [String: [DurableCanonicalPayee]]
    ) -> DurableCanonicalPayee? {
        if let payeeID = transaction.payeeId,
           let payee = payeeByYNABID[payeeID] {
            return payee
        }
        let normalized = FinancialTransactionSummary.normalizedDescription(
            transaction.payeeName ?? ""
        )
        let matches = payeesByName[normalized] ?? []
        return matches.count == 1 ? matches[0] : nil
    }

    /// `reapplyDecisions: false` skips rewriting rows that already have a
    /// decision — their cached fields were set when the decision was applied,
    /// and rewriting all of them stamps `updatedAt` on thousands of rows per
    /// save. Payee renames propagate separately via `updateCachedPayeeName`.
    private func applyCanonicalDirectory(
        to rows: [CachedFinancialTransaction],
        payees: [DurableCanonicalPayee],
        aliasesByKey: [String: [DurablePayeeAlias]],
        decisions: [DurableCanonicalTransactionDecision],
        reapplyDecisions: Bool = true
    ) {
        var payeeByID: [String: DurableCanonicalPayee] = [:]
        for payee in payees.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            payeeByID[payee.canonicalId] = payee
        }
        var payeeIDsByName: [String: Set<String>] = [:]
        var payeeIDsByLeadingPrefix: [String: Set<String>] = [:]
        for payee in payees where !payee.archived {
            let normalized =
                FinancialTransactionSummary.normalizedDescription(
                    payee.name
                )
            guard FinancialTransactionSummary.isSpecificIdentityText(
                normalized
            ) else {
                continue
            }
            payeeIDsByName[normalized, default: []]
                .insert(payee.canonicalId)
            let tokens = normalized.split(separator: " ")
            guard tokens.count > 1 else { continue }
            for tokenCount in 1..<tokens.count {
                let prefix = tokens.prefix(tokenCount)
                    .joined(separator: " ")
                guard prefix.count >= 5 else { continue }
                payeeIDsByLeadingPrefix[prefix, default: []]
                    .insert(payee.canonicalId)
            }
        }
        let decisionByID = latestCanonicalDecisionsByTransactionID(
            decisions
        )
        // Every confirmed transaction contributes evidence. Conflicting
        // categories for the same payee intentionally prevent a prefill
        // instead of allowing the most recent choice to become a global rule.
        let categories = (try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalCategory>()
        )) ?? []
        let reusableCategoryIDs = Set(
            categories.filter {
                !$0.hidden && !$0.deletedAtSource
            }.map(\.canonicalId)
        )
        let reviewedDecisions = decisions.filter {
            $0.reviewed
                && $0.subtransactionsData == nil
                && ($0.categoryCanonicalId == nil
                    || reusableCategoryIDs.contains(
                        $0.categoryCanonicalId ?? ""
                    ))
        }
        let patternsByPayee = Dictionary(
            grouping: reviewedDecisions.compactMap {
                decision -> DurableCanonicalTransactionDecision? in
                guard decision.payeeCanonicalId != nil else { return nil }
                return decision
            },
            by: { $0.payeeCanonicalId ?? "" }
        )

        for row in rows where !row.deleted && !row.pending {
            if let decision = decisionByID[row.externalId] {
                if reapplyDecisions {
                    applyCanonicalDecision(decision, to: row)
                }
                continue
            }
            let summary = row.toSummary()
            var resolvedIDs = Set<String>()
            var hasSuppressedIdentityEvidence = false
            for evidence in summary.payeeIdentityEvidence {
                let evidenceAliases =
                    aliasesByKey[evidence.key] ?? []
                if evidenceAliases.contains(where: \.suppressed) {
                    hasSuppressedIdentityEvidence = true
                }
                resolvedIDs.formUnion(
                    evidenceAliases
                        .filter { $0.confirmed && !$0.suppressed }
                        .map(\.payeeCanonicalId)
                )
            }
            if resolvedIDs.isEmpty && !hasSuppressedIdentityEvidence {
                for candidate in [
                    summary.providerMerchantName,
                    summary.counterpartyName,
                    row.displayName
                ].compactMap({ $0 }) {
                    let normalized =
                        FinancialTransactionSummary.normalizedDescription(
                            candidate
                        )
                    guard FinancialTransactionSummary
                        .isSpecificIdentityText(normalized) else {
                        continue
                    }
                    var matchingIDs =
                        payeeIDsByName[normalized] ?? []
                    matchingIDs.formUnion(
                        payeeIDsByLeadingPrefix[normalized] ?? []
                    )
                    let tokens = normalized.split(separator: " ")
                    if tokens.count > 1 {
                        for tokenCount in 1..<tokens.count {
                            let prefix = tokens.prefix(tokenCount)
                                .joined(separator: " ")
                            guard prefix.count >= 5 else { continue }
                            matchingIDs.formUnion(
                                payeeIDsByName[prefix] ?? []
                            )
                        }
                    }
                    if matchingIDs.count == 1,
                       let matchedID = matchingIDs.first {
                        resolvedIDs.insert(matchedID)
                    }
                }
            }

            guard resolvedIDs.count == 1,
                  let payeeID = resolvedIDs.first,
                  let payee = payeeByID[payeeID] else {
                row.payeeCanonicalId = nil
                let hasModelNameSuggestion =
                    row.classificationProvenanceRaw
                        == ClassificationProvenance.appleModel.rawValue
                    || row.classificationProvenanceRaw
                        == ClassificationProvenance.claude.rawValue
                if !hasModelNameSuggestion
                    || row.displayName.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty {
                    row.displayName = summary.fallbackDisplayName
                }
                row.categoryCanonicalId = nil
                row.categoryName = nil
                row.subtransactionsData = nil
                row.requiresNameReview = true
                row.requiresReview = true
                continue
            }

            row.payeeCanonicalId = payeeID
            row.displayName = payee.name
            row.requiresNameReview = false
            let patterns = patternsByPayee[payeeID] ?? []
            let directionPatterns = patterns.filter {
                $0.amountSign == Int(row.amountMilliunits.signum())
            }
            let patternKeys = Set(directionPatterns.map {
                "\($0.categoryCanonicalId ?? "")|\($0.forecastTreatmentRaw)"
            })
            if patternKeys.count == 1,
               let pattern = directionPatterns.first {
                row.categoryCanonicalId = pattern.categoryCanonicalId
                row.categoryName = pattern.categoryNameSnapshot
                row.forecastTreatmentRaw = pattern.forecastTreatmentRaw
                row.classificationConfidenceRaw =
                    ClassificationConfidence.high.rawValue
                row.classificationProvenanceRaw =
                    ClassificationProvenance.historicalMatch.rawValue
                // A decision pattern outranks any stale split data.
                row.subtransactionsData = nil
            } else {
                row.categoryCanonicalId = nil
                row.categoryName = nil
                row.subtransactionsData = nil
            }
            // Product rule: every newly posted transaction is confirmed by
            // the user even when history provides a strong prefill.
            row.requiresReview = true
        }
    }

    private func applyCanonicalDecision(
        _ decision: DurableCanonicalTransactionDecision,
        to row: CachedFinancialTransaction
    ) {
        row.payeeCanonicalId = decision.payeeCanonicalId
        row.displayName = decision.payeeNameSnapshot.isEmpty
            ? row.toSummary().fallbackDisplayName
            : decision.payeeNameSnapshot
        row.categoryCanonicalId = decision.categoryCanonicalId
        row.categoryName = decision.categoryNameSnapshot
        row.goalId = decision.goalId
        row.forecastTreatmentRaw = decision.forecastTreatmentRaw
        row.subtransactionsData = decision.subtransactionsData
        row.nativeCategoryRaw = "other"
        row.classificationConfidenceRaw =
            ClassificationConfidence.high.rawValue
        row.classificationProvenanceRaw = decision.provenanceRaw
        row.requiresNameReview = decision.payeeCanonicalId == nil
        row.requiresReview = !decision.reviewed
        normalizeLegacyReimbursement(in: row)
        row.updatedAt = .now
    }

    /// Enforces Reimbursement as a transaction type at the cache boundary.
    /// This prevents old expense/refund category data from being restored by
    /// a durable or reference replay after the one-time repair has run.
    private func normalizeLegacyReimbursement(
        in row: CachedFinancialTransaction
    ) {
        if let data = row.subtransactionsData, !data.isEmpty,
           let legs = try? JSONDecoder().decode(
               [SubTransactionSummary].self,
               from: data
           ) {
            var changed = false
            let repairedLegs = legs.map { leg in
                guard LegacyReimbursementRepresentation.matches(leg) else {
                    return leg
                }
                changed = true
                return LegacyReimbursementRepresentation.repaired(leg)
            }
            guard changed,
                  let repairedData = try? JSONEncoder().encode(repairedLegs)
            else { return }
            row.subtransactionsData = repairedData
            row.forecastTreatmentRaw = LegacyReimbursementRepresentation
                .parentTreatment(for: repairedLegs).rawValue
            return
        }
        guard LegacyReimbursementRepresentation.matchesWholeTransaction(
            treatmentRaw: row.forecastTreatmentRaw,
            categoryCanonicalId: row.categoryCanonicalId,
            categoryRaw: row.nativeCategoryRaw,
            categoryName: row.categoryName,
            goalId: row.goalId
        ) else { return }
        row.forecastTreatmentRaw = TransactionType.reimbursement.rawValue
        row.nativeCategoryRaw = "other"
        row.categoryCanonicalId = nil
        row.categoryName = nil
    }

    private func latestCanonicalDecisionsByTransactionID(
        _ decisions: [DurableCanonicalTransactionDecision]
    ) -> [String: DurableCanonicalTransactionDecision] {
        var result: [String: DurableCanonicalTransactionDecision] = [:]
        for decision in decisions.sorted(by: {
            if $0.updatedAt == $1.updatedAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.updatedAt < $1.updatedAt
        }) {
            result[decision.transactionExternalId] = decision
        }
        return result
    }

    private struct CounterpartMatchContext {
        let rows: [CachedFinancialTransaction]
        let rowsByID: [String: CachedFinancialTransaction]
        let pairs: [CounterpartPair]
        let accountNames: [String: String]
        let decisionByID: [String: DurableCanonicalTransactionDecision]
    }

    /// One shared computation of counterpart pairs across the full cached
    /// history, used by the per-sync prefill pass and the user-triggered
    /// backfill. Pure lookup — mutates nothing.
    private func counterpartMatchContext() -> CounterpartMatchContext? {
        let rows = (try? mainContext.fetch(
            FetchDescriptor<CachedFinancialTransaction>(
                predicate: #Predicate { !$0.deleted && !$0.pending }
            )
        )) ?? []
        guard !rows.isEmpty else { return nil }
        let accounts = (try? mainContext.fetch(
            FetchDescriptor<CachedFinancialAccount>(
                predicate: #Predicate { !$0.deleted }
            )
        )) ?? []
        let nicknames = (try? mainContext.fetch(
            FetchDescriptor<DurableAccountNickname>()
        )) ?? []
        let decisions = (try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalTransactionDecision>()
        )) ?? []
        let nameResolver = AccountDisplayNameResolver(nicknames: nicknames)

        var accountKinds: [String: FinancialAccountType] = [:]
        var accountNames: [String: String] = [:]
        for account in accounts {
            guard let kind = FinancialAccountType(rawValue: account.typeRaw)
            else { continue }
            accountKinds[account.canonicalAccountId] = kind
            accountNames[account.canonicalAccountId] =
                nameResolver.name(for: account)
        }

        let candidates = rows.map { row in
            CounterpartCandidate(
                id: row.id,
                accountId: row.canonicalAccountId,
                amountMilliunits: row.amountMilliunits,
                postedDate: row.postedDate,
                providerDefaultTreatment:
                    classifier.forecastTreatment(for: row.toSummary())
            )
        }
        return CounterpartMatchContext(
            rows: rows,
            rowsByID: Dictionary(
                uniqueKeysWithValues: rows.map { ($0.id, $0) }
            ),
            pairs: TransferCounterpartMatcher().matches(
                candidates: candidates,
                accountKinds: accountKinds
            ),
            accountNames: accountNames,
            decisionByID: latestCanonicalDecisionsByTransactionID(decisions)
        )
    }

    /// The identity a matched pair implies for one leg: the transfer-family
    /// type plus a label naming the twin's account.
    private func counterpartIdentity(
        kind: CounterpartPair.Kind,
        isOutflow: Bool,
        twinAccountName: String
    ) -> (treatment: TransactionType, label: String) {
        switch kind {
        case .cardPayment:
            return (.cardPayment, "Payment · \(twinAccountName)")
        case .internalTransfer:
            return (
                .internalTransfer,
                isOutflow
                    ? "Transfer to \(twinAccountName)"
                    : "Transfer from \(twinAccountName)"
            )
        }
    }

    /// Pairs the two legs of transfers and card payments across monitored
    /// accounts. Runs every sync after the canonical directory pass so the
    /// pair identity — the correct type plus a label naming the twin's
    /// account — wins over the generic payee prefill for rows the user has
    /// not reviewed. Reviewed rows only receive the twin pointer.
    private func applyCounterpartMatches() {
        guard let context = counterpartMatchContext() else { return }
        var pairedIds: Set<String> = []
        for pair in context.pairs {
            guard let outflow = context.rowsByID[pair.outflowId],
                  let inflow = context.rowsByID[pair.inflowId]
            else { continue }
            pairedIds.insert(outflow.id)
            pairedIds.insert(inflow.id)
            outflow.counterpartTransactionId = inflow.id
            inflow.counterpartTransactionId = outflow.id
            applyCounterpartPrefill(
                to: outflow, twin: inflow, kind: pair.kind,
                isOutflow: true, context: context
            )
            applyCounterpartPrefill(
                to: inflow, twin: outflow, kind: pair.kind,
                isOutflow: false, context: context
            )
        }
        for row in context.rows where row.counterpartTransactionId != nil
            && !pairedIds.contains(row.id) {
            row.counterpartTransactionId = nil
        }
    }

    private func applyCounterpartPrefill(
        to row: CachedFinancialTransaction,
        twin: CachedFinancialTransaction,
        kind: CounterpartPair.Kind,
        isOutflow: Bool,
        context: CounterpartMatchContext
    ) {
        guard row.requiresReview,
              row.classificationProvenanceRaw
                  != ClassificationProvenance.user.rawValue,
              row.classificationProvenanceRaw
                  != ClassificationProvenance.confirmedRule.rawValue,
              context.decisionByID[row.externalId] == nil
        else { return }
        guard let twinAccountName =
            context.accountNames[twin.canonicalAccountId]
        else { return }
        let identity = counterpartIdentity(
            kind: kind,
            isOutflow: isOutflow,
            twinAccountName: twinAccountName
        )
        // The pair identity also owns the contact link. Alias evidence from
        // generic bank descriptors ("Online Transfer / Payment: Debit")
        // points at whichever payee was confirmed last, so the directory's
        // resolution must not survive on matched rows — the review screen
        // titles from the payee, not the raw display name.
        guard let payee = resolveOrCreateCanonicalPayee(
            named: identity.label,
            preferredCanonicalId: nil
        ) else { return }
        row.payeeCanonicalId = payee.canonicalId
        row.requiresNameReview = false
        row.forecastTreatmentRaw = identity.treatment.rawValue
        row.displayName = payee.name
        row.categoryCanonicalId = nil
        row.categoryName = nil
        row.goalId = nil
        row.classificationConfidenceRaw =
            ClassificationConfidence.high.rawValue
        row.classificationProvenanceRaw =
            ClassificationProvenance.counterpartMatch.rawValue
    }

    private func applyCurrentCanonicalState(
        reapplyDecisions: Bool = true
    ) {
        let payees = (try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalPayee>()
        )) ?? []
        if !payees.isEmpty {
            let aliases = (try? mainContext.fetch(
                FetchDescriptor<DurablePayeeAlias>()
            )) ?? []
            let decisions = (try? mainContext.fetch(
                FetchDescriptor<DurableCanonicalTransactionDecision>()
            )) ?? []
            let rows = (try? mainContext.fetch(
                FetchDescriptor<CachedFinancialTransaction>()
            )) ?? []
            applyCanonicalDirectory(
                to: rows,
                payees: payees,
                aliasesByKey: Dictionary(grouping: aliases, by: \.aliasKey),
                decisions: decisions,
                reapplyDecisions: reapplyDecisions
            )
        }
        // Counterpart identities re-apply after every directory pass —
        // confirms rerun the directory without a sync, and the alias-driven
        // prefill would otherwise revert matched rows until the next sync.
        applyCounterpartMatches()
    }

    private func refreshCanonicalReviewCounts() {
        let cursors = (try? mainContext.fetch(
            FetchDescriptor<PlaidTransactionCursor>()
        )) ?? []
        guard !cursors.isEmpty,
              cursors.allSatisfy(\.historicalImportComplete),
              cursors.allSatisfy({
                  $0.historicalReconciliationVersion
                      >= Self.currentHistoricalReconciliationVersion
              }) else {
            canonicalReviewReady = false
            pendingTransactionReviewCount = 0
            unresolvedPayeeReviewCount = 0
            return
        }
        canonicalReviewReady = true
        let reviewDescriptor =
            FetchDescriptor<CachedFinancialTransaction>(
                predicate: #Predicate {
                    $0.requiresReview && !$0.deleted && !$0.pending
                }
            )
        let payeeDescriptor =
            FetchDescriptor<CachedFinancialTransaction>(
                predicate: #Predicate {
                    $0.requiresNameReview && !$0.deleted && !$0.pending
                }
            )
        pendingTransactionReviewCount =
            (try? mainContext.fetchCount(reviewDescriptor)) ?? 0
        unresolvedPayeeReviewCount =
            (try? mainContext.fetchCount(payeeDescriptor)) ?? 0
    }

    private func invalidateHistoricalReconciliation() {
        let cursors = (try? mainContext.fetch(
            FetchDescriptor<PlaidTransactionCursor>()
        )) ?? []
        for cursor in cursors {
            cursor.historicalReconciliationVersion = 0
        }
    }

    private func markHistoricalReconciliationComplete() {
        let cursors = (try? mainContext.fetch(
            FetchDescriptor<PlaidTransactionCursor>()
        )) ?? []
        for cursor in cursors {
            cursor.historicalReconciliationVersion =
                Self.currentHistoricalReconciliationVersion
        }
    }

    private func reviewCanonicalPayeeNames(
        ids: [String],
        displayName: String
    ) {
        guard !ids.isEmpty else { return }
        let selectedIDs = ids
        let descriptor = FetchDescriptor<CachedFinancialTransaction>(
            predicate: #Predicate {
                selectedIDs.contains($0.id) && !$0.deleted
            }
        )
        guard let rows = try? mainContext.fetch(descriptor),
              !rows.isEmpty else {
            return
        }
        let cleanedName = displayName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !cleanedName.isEmpty,
              let payee = resolveOrCreateCanonicalPayee(
                named: cleanedName,
                preferredCanonicalId: rows.compactMap(
                    \.payeeCanonicalId
                ).first
              ) else {
            return
        }
        assignAliases(for: rows, to: payee)
        for row in rows {
            row.payeeCanonicalId = payee.canonicalId
            row.displayName = payee.name
            row.requiresNameReview = false
            row.updatedAt = .now
        }
        updateCachedPayeeName(payee)
        applyCurrentCanonicalState()
        guard mainContext.safeSave(
            source: "plaidTransactions.canonicalPayeeReview"
        ) else {
            mainContext.rollback()
            return
        }
        refreshCanonicalReviewCounts()
    }

    private func confirmCanonicalTransaction(
        id: String,
        displayName: String,
        payeeCanonicalId: String?,
        categoryName: String?,
        treatment: ForecastTreatment,
        categoryCanonicalId: String?,
        goalId: UUID?,
        reserveFundId: UUID?,
        savingsMonth: BudgetMonth?
    ) -> Bool {
        var descriptor = FetchDescriptor<CachedFinancialTransaction>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard let row = try? mainContext.fetch(descriptor).first,
              !row.pending,
              TransactionTypeRules.isValidAmountSign(
                treatment,
                amountMilliunits: row.amountMilliunits
              ) else {
            return false
        }
        let cleanedName = displayName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !cleanedName.isEmpty else { return false }
        let previousTreatment = row.forecastTreatment
        let savingsGroupIdentity: String?
        if treatment == .savings {
            guard savingsMonth != nil,
                  let identity = activeSavingsGroupIdentity() else {
                return false
            }
            savingsGroupIdentity = identity
        } else {
            savingsGroupIdentity = nil
        }
        // Validate the category BEFORE creating/renaming the payee so a
        // rejected save leaves no pending directory mutation behind.
        let category: DurableCanonicalCategory?
        let isFundedExpense = treatment == .goalSpend
        if TransactionTypeRules.requiresCategory(treatment)
            || isFundedExpense {
            guard let resolved = resolveCanonicalCategory(
                canonicalId: categoryCanonicalId,
                name: categoryName,
                allowHidden: categoryCanonicalId != nil
            ) else {
                return false
            }
            // Type-first contract: an incompatible type/category combination
            // must never be saved. A category with no Networth-owned group
            // has no role yet and is accepted for any category-taking type.
            guard TransactionTypeRules.isValidCombination(
                treatment: isFundedExpense ? .ordinarySpending : treatment,
                categoryRole: reportingRole(for: resolved)
            ) else {
                return false
            }
            category = resolved
        } else {
            category = nil
        }
        let resolvedGoalId: UUID?
        if TransactionTypeRules.requiresGoal(treatment) {
            guard let goalId,
                  let goals = try? mainContext.fetch(
                    FetchDescriptor<DurableGoal>()
                  ),
                  goals.contains(where: {
                    $0.id == goalId && !$0.archived && $0.completedAt == nil
                  }) else {
                return false
            }
            resolvedGoalId = goalId
        } else {
            resolvedGoalId = nil
        }
        let resolvedReserveFund: DurableSpendingSinkingFund?
        if let reserveFundId {
            guard treatment == .ordinarySpending,
                  row.amountMilliunits < 0,
                  let funds = try? mainContext.fetch(
                    FetchDescriptor<DurableSpendingSinkingFund>()
                  ),
                  let fund = funds.first(where: {
                    $0.id == reserveFundId && !$0.archived
                  }) else {
                return false
            }
            resolvedReserveFund = fund
        } else {
            resolvedReserveFund = nil
        }
        guard let payee = resolveOrCreateCanonicalPayee(
            named: cleanedName,
            preferredCanonicalId:
                payeeCanonicalId ?? row.payeeCanonicalId
        ) else {
            return false
        }

        // A matched transfer's identity comes from the account relationship,
        // not its descriptor. Generic bank descriptors ("Online Transfer /
        // Payment: Debit") are shared by payments to many destinations, so
        // aliasing one to a card-specific payee would mislabel every future
        // transfer that lacks a monitored twin.
        let identityFromCounterpart = row.counterpartTransactionId != nil
            && (treatment == .cardPayment || treatment == .internalTransfer)
        if !identityFromCounterpart {
            assignAliases(for: [row], to: payee)
        }
        let externalId = row.externalId
        let decisions = (try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalTransactionDecision>(
                predicate: #Predicate {
                    $0.transactionExternalId == externalId
                }
            )
        )) ?? []
        let decision: DurableCanonicalTransactionDecision
        if let existing = latestCanonicalDecisionsByTransactionID(
            decisions
        )[row.externalId] {
            decision = existing
            decision.ynabTransactionId = nil
            decision.payeeCanonicalId = payee.canonicalId
            decision.payeeNameSnapshot = payee.name
            decision.categoryCanonicalId = category?.canonicalId
            decision.categoryNameSnapshot = category?.name
            decision.goalId = resolvedGoalId
            decision.amountSign = Int(row.amountMilliunits.signum())
            decision.forecastTreatment = treatment
            decision.subtransactionsData = nil
            decision.reviewed = true
            decision.provenanceRaw =
                ClassificationProvenance.user.rawValue
            decision.updatedAt = .now
        } else {
            decision = DurableCanonicalTransactionDecision(
                transactionExternalId: row.externalId,
                payeeCanonicalId: payee.canonicalId,
                payeeNameSnapshot: payee.name,
                categoryCanonicalId: category?.canonicalId,
                categoryNameSnapshot: category?.name,
                goalId: resolvedGoalId,
                amountSign: Int(row.amountMilliunits.signum()),
                forecastTreatment: treatment,
                reviewed: true,
                provenance: .user
            )
            mainContext.insert(decision)
        }
        applyCanonicalDecision(decision, to: row)
        do {
            try GoalTransferRequestService(
                context: mainContext
            ).synchronize(for: row)
        } catch {
            mainContext.rollback()
            return false
        }
        stageReserveFunding(
            for: row,
            reserveFund: resolvedReserveFund
        )
        stageSavingsFunding(
            for: row,
            previousTreatment: previousTreatment,
            month: savingsMonth,
            savingsGroupIdentity: savingsGroupIdentity
        )
        advanceRecurringExpectations(for: [row])
        updateCachedPayeeName(payee)
        applyCurrentCanonicalState(reapplyDecisions: false)
        guard mainContext.safeSave(
            source: "plaidTransactions.canonicalTransactionReview"
        ) else {
            mainContext.rollback()
            return false
        }
        refreshCanonicalReviewCounts()
        return true
    }

    /// Keeps the experimental review funding choice in the existing Reserve
    /// overlay. No imported transaction fields or historical assignments are
    /// rewritten, and choosing another source deactivates the prior overlay.
    private func stageReserveFunding(
        for row: CachedFinancialTransaction,
        reserveFund: DurableSpendingSinkingFund?
    ) {
        let rowID = row.id
        let transactionAssignments = (try? mainContext.fetch(
            FetchDescriptor<DurableSpendingSinkingFundExpense>(
                predicate: #Predicate { $0.transactionId == rowID }
            )
        )) ?? []
        let matches = transactionAssignments.filter {
            $0.subtransactionId == nil
        }
        let now = Date.now
        for assignment in transactionAssignments
            where assignment.subtransactionId != nil && assignment.active {
            assignment.active = false
            assignment.updatedAt = now
        }
        if let reserveFund {
            if matches.isEmpty {
                mainContext.insert(DurableSpendingSinkingFundExpense(
                    fundId: reserveFund.id,
                    transactionId: row.id,
                    transactionDate: row.postedDate,
                    amountMilliunits: Swift.abs(row.amountMilliunits)
                ))
            } else {
                for assignment in matches {
                    assignment.fundId = reserveFund.id
                    assignment.transactionDate = row.postedDate
                    assignment.amountMilliunits = Swift.abs(
                        row.amountMilliunits
                    )
                    assignment.active = true
                    assignment.updatedAt = now
                }
            }
        } else {
            for assignment in matches where assignment.active {
                assignment.active = false
                assignment.updatedAt = now
            }
        }
    }

    /// Synchronizes Reserve overlays with the reviewed split. Removed parts,
    /// changed funding sources, and a prior whole-transaction assignment are
    /// all handled without rewriting imported transaction data.
    private func stageSplitReserveFunding(
        for row: CachedFinancialTransaction,
        splits: [SubTransactionSummary],
        reserveFundIdBySubtransactionId: [String: UUID],
        activeReservesByID: [UUID: DurableSpendingSinkingFund]
    ) {
        let rowID = row.id
        let matches = (try? mainContext.fetch(
            FetchDescriptor<DurableSpendingSinkingFundExpense>(
                predicate: #Predicate { $0.transactionId == rowID }
            )
        )) ?? []
        let amountBySplitID = splits.reduce(into: [String: Money]()) {
            $0[$1.id] = $1.amount.absolute
        }
        let existingSplitIDs = Set(matches.compactMap(\.subtransactionId))
        let now = Date.now

        for assignment in matches {
            guard let splitID = assignment.subtransactionId,
                  let fundID = reserveFundIdBySubtransactionId[splitID],
                  activeReservesByID[fundID] != nil,
                  let amount = amountBySplitID[splitID] else {
                if assignment.active {
                    assignment.active = false
                    assignment.updatedAt = now
                }
                continue
            }
            assignment.fundId = fundID
            assignment.transactionDate = row.postedDate
            assignment.amountMilliunits = amount.milliunits
            assignment.active = true
            assignment.updatedAt = now
        }

        for (splitID, fundID) in reserveFundIdBySubtransactionId
            where !existingSplitIDs.contains(splitID) {
            guard activeReservesByID[fundID] != nil,
                  let amount = amountBySplitID[splitID] else { continue }
            mainContext.insert(DurableSpendingSinkingFundExpense(
                fundId: fundID,
                transactionId: row.id,
                subtransactionId: splitID,
                transactionDate: row.postedDate,
                amountMilliunits: amount.milliunits
            ))
        }
    }

    private func activeSavingsGroupIdentity() -> String? {
        let groups = (try? mainContext.fetch(
            FetchDescriptor<DurableCategoryGroup>()
        )) ?? []
        let latest = Dictionary(grouping: groups, by: \.groupIdentity)
            .compactMapValues { rows in
                rows.max(by: { $0.updatedAt < $1.updatedAt })
            }
        return latest.values
            .filter {
                $0.isSavingsBucket && SpendingGroupSetup.isUserGroup($0)
            }
            .max(by: { $0.updatedAt < $1.updatedAt })?
            .groupIdentity
    }

    /// Month attribution is durable user data and is staged in the same save
    /// as the canonical classification. Old receiving-side assignments remain
    /// untouched unless they were themselves explicit Savings classifications.
    private func stageSavingsFunding(
        for row: CachedFinancialTransaction,
        previousTreatment: TransactionType,
        month: BudgetMonth?,
        savingsGroupIdentity: String?
    ) {
        let assignments = (try? mainContext.fetch(
            FetchDescriptor<DurableSavingsTransferAssignment>()
        )) ?? []
        let matches = assignments.filter { $0.transactionId == row.id }
        let whole = matches.filter { $0.subtransactionId.isEmpty }
        let now = Date.now
        for assignment in matches where !assignment.subtransactionId.isEmpty {
            assignment.active = false
            assignment.updatedAt = now
        }
        guard row.forecastTreatment == .savings,
              let month,
              let savingsGroupIdentity else {
            if previousTreatment == .savings {
                for assignment in whole {
                    assignment.active = false
                    assignment.updatedAt = now
                }
            }
            return
        }
        if whole.isEmpty {
            mainContext.insert(DurableSavingsTransferAssignment(
                transactionId: row.id,
                savingsGroupIdentity: savingsGroupIdentity,
                assignedYear: month.year,
                assignedMonth: month.month
            ))
        } else {
            for assignment in whole {
                assignment.savingsGroupIdentity = savingsGroupIdentity
                assignment.assignedYear = month.year
                assignment.assignedMonth = month.month
                assignment.active = true
                assignment.updatedAt = now
            }
        }
    }

    private func stageSplitSavingsFunding(
        for row: CachedFinancialTransaction,
        previousTreatment: TransactionType,
        monthsBySplitID: [String: BudgetMonth],
        savingsGroupIdentity: String?
    ) {
        let assignments = (try? mainContext.fetch(
            FetchDescriptor<DurableSavingsTransferAssignment>()
        )) ?? []
        let matches = assignments.filter { $0.transactionId == row.id }
        let now = Date.now
        for assignment in matches {
            if assignment.subtransactionId.isEmpty {
                if previousTreatment == .savings {
                    assignment.active = false
                    assignment.updatedAt = now
                }
                continue
            }
            guard let month = monthsBySplitID[assignment.subtransactionId],
                  let savingsGroupIdentity else {
                assignment.active = false
                assignment.updatedAt = now
                continue
            }
            assignment.savingsGroupIdentity = savingsGroupIdentity
            assignment.assignedYear = month.year
            assignment.assignedMonth = month.month
            assignment.active = true
            assignment.updatedAt = now
        }
        let existingIDs = Set(matches.map(\.subtransactionId))
        guard let savingsGroupIdentity else { return }
        for (splitID, month) in monthsBySplitID
            where !existingIDs.contains(splitID) {
            mainContext.insert(DurableSavingsTransferAssignment(
                transactionId: row.id,
                subtransactionId: splitID,
                savingsGroupIdentity: savingsGroupIdentity,
                assignedYear: month.year,
                assignedMonth: month.month
            ))
        }
    }

    private func confirmCanonicalSplitTransaction(
        id: String,
        displayName: String,
        payeeCanonicalId: String?,
        subtransactions: [SubTransactionSummary],
        reserveFundIdBySubtransactionId: [String: UUID],
        savingsMonthBySubtransactionId: [String: BudgetMonth]
    ) -> Result<Void, SplitReviewFailure> {
        var descriptor = FetchDescriptor<CachedFinancialTransaction>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard let row = try? mainContext.fetch(descriptor).first else {
            return .failure(.transactionUnavailable)
        }
        guard !row.pending else { return .failure(.transactionPending) }
        guard subtransactions.count >= 2 else {
            return .failure(.needsTwoParts)
        }
        guard subtransactions.allSatisfy({
            !$0.deleted && !$0.amount.isZero
        }) else { return .failure(.emptyPart) }
        guard subtransactions.map(\.amount).sum().milliunits
                == row.amountMilliunits else {
            return .failure(.amountsDoNotBalance)
        }
        let cleanedName = displayName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !cleanedName.isEmpty,
              let payee = resolveOrCreateCanonicalPayee(
                named: cleanedName,
                preferredCanonicalId:
                    payeeCanonicalId ?? row.payeeCanonicalId
              ) else {
            return .failure(.contactUnavailable)
        }
        let isIncoming = row.amountMilliunits > 0
        guard let goals = try? mainContext.fetch(
            FetchDescriptor<DurableGoal>()
        ) else { return .failure(.goalsUnavailable) }
        let activeGoalIDs = Set(goals.filter {
            !$0.archived && $0.completedAt == nil
        }.map(\.id))
        guard let reserves = try? mainContext.fetch(
            FetchDescriptor<DurableSpendingSinkingFund>()
        ) else { return .failure(.reservesUnavailable) }
        let activeReservesByID = reserves.filter { !$0.archived }.reduce(
            into: [UUID: DurableSpendingSinkingFund]()
        ) { result, reserve in
            result[reserve.id] = reserve
        }
        let splitIDs = Set(subtransactions.map(\.id))
        guard Set(reserveFundIdBySubtransactionId.keys)
            .isSubset(of: splitIDs) else {
            return .failure(.reserveUnavailable)
        }
        guard Set(savingsMonthBySubtransactionId.keys)
            .isSubset(of: splitIDs) else {
            return .failure(.savingsUnavailable)
        }
        let allowedTypes: Set<TransactionType> = isIncoming
            ? [.income, .refund, .reimbursement, .goalRefund]
            : [.ordinarySpending, .reimbursement, .goalSpend, .savings]
        let savingsSplitIDs = Set(subtransactions.compactMap {
            $0.forecastTreatment == .savings ? $0.id : nil
        })
        guard savingsSplitIDs == Set(savingsMonthBySubtransactionId.keys)
        else { return .failure(.savingsUnavailable) }
        let savingsGroupIdentity = savingsSplitIDs.isEmpty
            ? nil : activeSavingsGroupIdentity()
        guard savingsSplitIDs.isEmpty || savingsGroupIdentity != nil else {
            return .failure(.savingsUnavailable)
        }
        let previousTreatment = row.forecastTreatment
        var canonicalSplits: [SubTransactionSummary] = []
        for split in subtransactions {
            guard let treatment = split.forecastTreatment,
                  allowedTypes.contains(treatment) else {
                return .failure(.invalidType)
            }
            if let reserveID = reserveFundIdBySubtransactionId[split.id] {
                guard !isIncoming,
                      treatment == .ordinarySpending,
                      split.amount < .zero,
                      activeReservesByID[reserveID] != nil else {
                    return .failure(.reserveUnavailable)
                }
            }
            let category: DurableCanonicalCategory?
            let isFundedExpense = treatment == .goalSpend
            if TransactionTypeRules.requiresCategory(treatment)
                || isFundedExpense {
                let rawCategoryID = split.categoryCanonicalId
                    ?? split.categoryId
                guard let resolved = resolveCanonicalCategory(
                    canonicalId: rawCategoryID.map {
                        $0.hasPrefix("ynab:") || $0.hasPrefix("networth:")
                            ? $0
                            : "ynab:\($0)"
                    },
                    name: split.categoryName
                ) else {
                    return .failure(.categoryUnavailable(
                        split.categoryName ?? "Selected category"
                    ))
                }
                guard TransactionTypeRules.isValidCombination(
                    treatment: isFundedExpense
                        ? .ordinarySpending : treatment,
                    categoryRole: reportingRole(for: resolved)
                ) else {
                    return .failure(.categoryIncompatible(resolved.name))
                }
                category = resolved
            } else {
                category = nil
            }
            let resolvedGoalId: UUID?
            if TransactionTypeRules.requiresGoal(treatment) {
                guard let goalId = split.goalId,
                      activeGoalIDs.contains(goalId) else {
                    return .failure(.goalUnavailable)
                }
                resolvedGoalId = goalId
            } else {
                resolvedGoalId = nil
            }
            canonicalSplits.append(SubTransactionSummary(
                id: split.id,
                amount: split.amount,
                categoryId: category?.canonicalId,
                categoryName: category?.name,
                categoryCanonicalId: category?.canonicalId,
                goalId: resolvedGoalId,
                forecastTreatment: treatment,
                transferAccountId: split.transferAccountId,
                payeeName: split.payeeName,
                memo: split.memo,
                deleted: split.deleted
            ))
        }
        guard let splitData = try? JSONEncoder().encode(
            canonicalSplits
        ) else {
            return .failure(.encodingFailed)
        }
        let distinctTypes = Set(canonicalSplits.compactMap(\.forecastTreatment))
        let treatment = distinctTypes.count == 1
            ? distinctTypes.first ?? .unknown
            : .unknown
        assignAliases(for: [row], to: payee)
        let externalId = row.externalId
        let decisions = (try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalTransactionDecision>(
                predicate: #Predicate {
                    $0.transactionExternalId == externalId
                }
            )
        )) ?? []
        let decision = latestCanonicalDecisionsByTransactionID(
            decisions
        )[row.externalId] ?? {
            let created = DurableCanonicalTransactionDecision(
                transactionExternalId: row.externalId
            )
            mainContext.insert(created)
            return created
        }()
        decision.ynabTransactionId = nil
        decision.payeeCanonicalId = payee.canonicalId
        decision.payeeNameSnapshot = payee.name
        decision.categoryCanonicalId = nil
        decision.categoryNameSnapshot = "Split"
        decision.goalId = nil
        decision.amountSign = Int(row.amountMilliunits.signum())
        decision.forecastTreatment = treatment
        decision.subtransactionsData = splitData
        decision.reviewed = true
        decision.provenanceRaw = ClassificationProvenance.user.rawValue
        decision.updatedAt = .now
        applyCanonicalDecision(decision, to: row)
        do {
            try GoalTransferRequestService(
                context: mainContext
            ).synchronize(for: row)
        } catch {
            mainContext.rollback()
            return .failure(.saveFailed)
        }
        stageSplitReserveFunding(
            for: row,
            splits: canonicalSplits,
            reserveFundIdBySubtransactionId:
                reserveFundIdBySubtransactionId,
            activeReservesByID: activeReservesByID
        )
        stageSplitSavingsFunding(
            for: row,
            previousTreatment: previousTreatment,
            monthsBySplitID: savingsMonthBySubtransactionId,
            savingsGroupIdentity: savingsGroupIdentity
        )
        advanceRecurringExpectations(for: [row])
        updateCachedPayeeName(payee)
        applyCurrentCanonicalState(reapplyDecisions: false)
        guard mainContext.safeSave(
            source: "plaidTransactions.canonicalSplitReview"
        ) else {
            mainContext.rollback()
            return .failure(.saveFailed)
        }
        refreshCanonicalReviewCounts()
        return .success(())
    }

    private func resolveOrCreateCanonicalPayee(
        named name: String,
        preferredCanonicalId: String?
    ) -> DurableCanonicalPayee? {
        let payees = (try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalPayee>()
        )) ?? []
        if let preferredCanonicalId,
           let payee = payees.first(where: {
               $0.canonicalId == preferredCanonicalId
           }) {
            if payee.name != name {
                // A name that exactly matches a different existing contact
                // links to that contact instead of renaming this one. A
                // stale editor otherwise renames a shared contact into a
                // duplicate, relabeling every transaction attached to it.
                let requested =
                    FinancialTransactionSummary.normalizedDescription(name)
                let existing = payees.filter {
                    $0.canonicalId != preferredCanonicalId
                        && !$0.archived
                        && FinancialTransactionSummary.normalizedDescription(
                            $0.name
                        ) == requested
                }
                if existing.count == 1 { return existing[0] }
                payee.name = name
                payee.userEdited = true
                payee.updatedAt = .now
            }
            return payee
        }
        let normalized =
            FinancialTransactionSummary.normalizedDescription(name)
        let exact = payees.filter {
            !$0.archived
                && FinancialTransactionSummary.normalizedDescription(
                    $0.name
                ) == normalized
        }
        if exact.count == 1 { return exact[0] }
        guard !normalized.isEmpty else { return nil }
        let canonicalId = "networth:\(UUID().uuidString.lowercased())"
        let payee = DurableCanonicalPayee(
            canonicalId: canonicalId,
            name: name,
            sourceName: name,
            userEdited: true
        )
        mainContext.insert(payee)
        return payee
    }

    private func resolveCanonicalCategory(
        canonicalId: String?,
        name: String?,
        allowHidden: Bool = false
    ) -> DurableCanonicalCategory? {
        let categories = (try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalCategory>()
        )) ?? []
        if let canonicalId,
           let category = categories.first(where: {
               $0.canonicalId == canonicalId
                   && (allowHidden || !$0.hidden)
                   && !$0.deletedAtSource
           }) {
            return category
        }
        let normalized = name?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        guard !normalized.isEmpty else { return nil }
        let exact = categories.filter {
            !$0.hidden
                && !$0.deletedAtSource
                && $0.name.localizedCaseInsensitiveCompare(normalized)
                    == .orderedSame
        }
        return exact.count == 1 ? exact[0] : nil
    }

    /// An approved posted transaction that matches an active expectation's
    /// next occurrence (account, payee, treatment, direction, bounded date
    /// window) replaces that occurrence: the expectation advances one
    /// cadence. Expectations otherwise advance only through explicit skip
    /// or reschedule. Mutates rows for the caller's save.
    private func advanceRecurringExpectations(
        for rows: [CachedFinancialTransaction]
    ) {
        let expectations = (try? mainContext.fetch(
            FetchDescriptor<DurableRecurringExpectation>(
                predicate: #Predicate { !$0.archived }
            )
        )) ?? []
        guard !expectations.isEmpty else { return }
        let calendar = Calendar.current
        // Chronological order so a batch containing consecutive occurrences
        // (July's and August's rent) advances the expectation stepwise.
        let orderedRows = rows
            .filter { !$0.deleted && !$0.pending }
            .sorted { $0.postedDate < $1.postedDate }
        for row in orderedRows {
            let summary = TransactionSummary(
                id: row.id,
                accountId: row.canonicalAccountId,
                date: row.postedDate,
                amount: Money(milliunits: row.amountMilliunits),
                cleared: true,
                approved: true,
                payeeName: row.displayName,
                categoryName: row.categoryName,
                payeeCanonicalId: row.payeeCanonicalId,
                categoryCanonicalId: row.categoryCanonicalId,
                forecastTreatment: row.forecastTreatment,
                memo: nil,
                deleted: false
            )
            // One approval advances at most one expectation — the best
            // occurrence match, re-evaluated against advanced dates.
            guard let best = RecurringExpectations.bestOccurrenceMatch(
                for: summary,
                among: expectations.map { $0.toCore() },
                calendar: calendar
            ), let target = expectations.first(where: {
                $0.id.uuidString == best.id
            }) else { continue }
            target.nextOccurrenceAt = RecurringExpectations.advance(
                target.nextOccurrenceAt,
                cadence: target.cadence,
                calendar: calendar
            )
            target.updatedAt = .now
        }
    }

    /// Approves a cluster of split transactions "as suggested": each row
    /// keeps its OWN prefilled legs, written as an authoritative split
    /// decision, in one save. Rows whose legs don't validate are skipped
    /// and stay in review.
    public func approveSuggestedSplitTransactions(
        ids: [String],
        finalize: Bool = true
    ) -> Int {
        guard !ids.isEmpty else { return 0 }
        let selectedIDs = ids
        let descriptor = FetchDescriptor<CachedFinancialTransaction>(
            predicate: #Predicate {
                selectedIDs.contains($0.id) && !$0.deleted && !$0.pending
            }
        )
        guard let rows = try? mainContext.fetch(descriptor),
              !rows.isEmpty else {
            return 0
        }
        let decisions = (try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalTransactionDecision>()
        )) ?? []
        let latestByID = latestCanonicalDecisionsByTransactionID(decisions)
        var approvedRows: [CachedFinancialTransaction] = []

        for row in rows {
            let legs = row.subtransactions.filter {
                !$0.deleted && !$0.amount.isZero
            }
            guard legs.count >= 2,
                  legs.map(\.amount.milliunits).reduce(0, +)
                    == row.amountMilliunits else {
                continue
            }
            let cleanedName = row.displayName.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !cleanedName.isEmpty,
                  let payee = resolveOrCreateCanonicalPayee(
                    named: cleanedName,
                    preferredCanonicalId: row.payeeCanonicalId
                  ) else {
                continue
            }
            var canonicalSplits: [SubTransactionSummary] = []
            var valid = true
            for leg in legs {
                if row.amountMilliunits > 0 {
                    guard leg.forecastTreatment == .income
                        || leg.forecastTreatment == .refund else {
                        valid = false
                        break
                    }
                    canonicalSplits.append(leg)
                    continue
                }
                let rawID = leg.categoryCanonicalId ?? leg.categoryId
                guard let category = resolveCanonicalCategory(
                    canonicalId: rawID.map {
                        $0.hasPrefix("ynab:") || $0.hasPrefix("networth:")
                            ? $0
                            : "ynab:\($0)"
                    },
                    name: leg.categoryName
                ), TransactionTypeRules.isValidCombination(
                    treatment: .ordinarySpending,
                    categoryRole: reportingRole(for: category)
                ) else {
                    valid = false
                    break
                }
                canonicalSplits.append(SubTransactionSummary(
                    id: leg.id,
                    amount: leg.amount,
                    categoryId: category.canonicalId,
                    categoryName: category.name,
                    forecastTreatment: .ordinarySpending,
                    transferAccountId: leg.transferAccountId,
                    payeeName: leg.payeeName,
                    memo: leg.memo,
                    deleted: false
                ))
            }
            guard valid,
                  let splitData = try? JSONEncoder().encode(canonicalSplits)
            else { continue }

            assignAliases(for: [row], to: payee)
            let decision: DurableCanonicalTransactionDecision
            if let existing = latestByID[row.externalId] {
                decision = existing
            } else {
                decision = DurableCanonicalTransactionDecision(
                    transactionExternalId: row.externalId
                )
                mainContext.insert(decision)
            }
            decision.ynabTransactionId = nil
            decision.payeeCanonicalId = payee.canonicalId
            decision.payeeNameSnapshot = payee.name
            decision.categoryCanonicalId = nil
            decision.categoryNameSnapshot = "Split"
            decision.goalId = nil
            decision.amountSign = Int(row.amountMilliunits.signum())
            if row.amountMilliunits < 0 {
                decision.forecastTreatment = .ordinarySpending
            } else if canonicalSplits.allSatisfy({
                $0.forecastTreatment == .income
            }) {
                decision.forecastTreatment = .income
            } else {
                decision.forecastTreatment = .refund
            }
            decision.subtransactionsData = splitData
            decision.reviewed = true
            decision.provenanceRaw = ClassificationProvenance.user.rawValue
            decision.updatedAt = .now
            applyCanonicalDecision(decision, to: row)
            approvedRows.append(row)
        }

        guard !approvedRows.isEmpty else { return 0 }
        advanceRecurringExpectations(for: approvedRows)
        guard finalize else { return approvedRows.count }
        applyCurrentCanonicalState()
        guard mainContext.safeSave(
            source: "plaidTransactions.approveSuggestedSplits"
        ) else {
            mainContext.rollback()
            return 0
        }
        refreshCanonicalReviewCounts()
        return approvedRows.count
    }

    /// Approves each selected transaction using its own currently displayed
    /// classification, then runs the expensive classifier/save pass once.
    /// Invalid rows stay in review while valid rows are committed together.
    public func approveTransactionsAsShown(ids: [String]) -> Int {
        guard !ids.isEmpty else { return 0 }
        let selectedIDs = Array(Set(ids))
        let descriptor = FetchDescriptor<CachedFinancialTransaction>(
            predicate: #Predicate {
                selectedIDs.contains($0.id)
                    && $0.requiresReview
                    && !$0.deleted
                    && !$0.pending
            }
        )
        guard let rows = try? mainContext.fetch(descriptor),
              !rows.isEmpty else {
            return 0
        }

        var approvedTotal = 0
        for row in rows {
            if row.isSplit {
                approvedTotal += approveSuggestedSplitTransactions(
                    ids: [row.id],
                    finalize: false
                )
            } else {
                approvedTotal += approveTransactions(
                    ids: [row.id],
                    displayName: row.displayName,
                    payeeCanonicalId: row.payeeCanonicalId,
                    categoryName: row.categoryName,
                    categoryCanonicalId: row.categoryCanonicalId,
                    treatment: row.forecastTreatment,
                    finalize: false
                )
            }
        }

        guard approvedTotal > 0 else { return 0 }
        return finalizeBatchApprovals() ? approvedTotal : 0
    }

    /// Re-applies alias/decision/suggestion state and refreshes review
    /// counts after a YNAB reference import rebuilt the suggestion table.
    public func reapplyCanonicalStateAfterReferenceImport() {
        applyCurrentCanonicalState()
        refreshCanonicalReviewCounts()
    }

    /// The reporting role of the category's Networth-owned group, or nil
    /// when the category has not been assigned to a group yet.
    func reportingRole(
        for category: DurableCanonicalCategory
    ) -> CategoryReportingRole? {
        guard let identity = category.categoryGroupIdentity else { return nil }
        let groups = (try? mainContext.fetch(
            FetchDescriptor<DurableCategoryGroup>(
                predicate: #Predicate { $0.groupIdentity == identity }
            )
        )) ?? []
        return groups.first?.reportingRole
    }

    /// Approves a reviewed cluster in one pass: writes one authoritative
    /// `.user` decision per transaction, learns alias evidence once, and
    /// commits a single save. Returns the number of approved transactions
    /// (0 when validation fails or nothing was saved).
    public func approveTransactions(
        ids: [String],
        displayName: String,
        payeeCanonicalId: String? = nil,
        categoryName: String?,
        categoryCanonicalId: String? = nil,
        treatment: ForecastTreatment,
        finalize: Bool = true
    ) -> Int {
        guard !ids.isEmpty else { return 0 }
        let selectedIDs = ids
        let descriptor = FetchDescriptor<CachedFinancialTransaction>(
            predicate: #Predicate {
                selectedIDs.contains($0.id) && !$0.deleted && !$0.pending
            }
        )
        guard let rows = try? mainContext.fetch(descriptor),
              !rows.isEmpty,
              !TransactionTypeRules.requiresGoal(treatment),
              rows.allSatisfy({
                TransactionTypeRules.isValidAmountSign(
                    treatment,
                    amountMilliunits: $0.amountMilliunits
                )
              }) else {
            return 0
        }
        let cleanedName = displayName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !cleanedName.isEmpty else { return 0 }
        // Validate the category BEFORE creating/renaming the payee so a
        // rejected batch leaves no pending directory mutation behind.
        let category: DurableCanonicalCategory?
        if TransactionTypeRules.requiresCategory(treatment) {
            guard let resolved = resolveCanonicalCategory(
                canonicalId: categoryCanonicalId,
                name: categoryName,
                allowHidden: categoryCanonicalId != nil
            ), TransactionTypeRules.isValidCombination(
                treatment: treatment,
                categoryRole: reportingRole(for: resolved)
            ) else {
                return 0
            }
            category = resolved
        } else {
            category = nil
        }
        guard let payee = resolveOrCreateCanonicalPayee(
            named: cleanedName,
            preferredCanonicalId: payeeCanonicalId
                ?? rows.compactMap(\.payeeCanonicalId).first
        ) else {
            return 0
        }

        assignAliases(for: rows, to: payee)
        let decisions = (try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalTransactionDecision>()
        )) ?? []
        let latestByID = latestCanonicalDecisionsByTransactionID(decisions)
        for row in rows {
            let decision: DurableCanonicalTransactionDecision
            if let existing = latestByID[row.externalId] {
                decision = existing
            } else {
                decision = DurableCanonicalTransactionDecision(
                    transactionExternalId: row.externalId
                )
                mainContext.insert(decision)
            }
            decision.ynabTransactionId = nil
            decision.payeeCanonicalId = payee.canonicalId
            decision.payeeNameSnapshot = payee.name
            decision.categoryCanonicalId = category?.canonicalId
            decision.categoryNameSnapshot = category?.name
            decision.goalId = nil
            decision.amountSign = Int(row.amountMilliunits.signum())
            decision.forecastTreatment = treatment
            decision.subtransactionsData = nil
            decision.reviewed = true
            decision.provenanceRaw = ClassificationProvenance.user.rawValue
            decision.updatedAt = .now
            applyCanonicalDecision(decision, to: row)
        }
        advanceRecurringExpectations(for: rows)
        updateCachedPayeeName(payee)
        // Batch callers apply many clusters then finalize ONCE — the
        // full-table classifier pass per cluster is what made large
        // selections crawl.
        guard finalize else { return rows.count }
        applyCurrentCanonicalState()
        guard mainContext.safeSave(
            source: "plaidTransactions.approveCluster"
        ) else {
            mainContext.rollback()
            return 0
        }
        refreshCanonicalReviewCounts()
        return rows.count
    }

    /// One classifier pass + one save for a batch of finalize-deferred
    /// approvals. Returns false (rolling everything back) on save failure.
    public func finalizeBatchApprovals() -> Bool {
        applyCurrentCanonicalState()
        guard mainContext.safeSave(
            source: "plaidTransactions.batchApprove"
        ) else {
            mainContext.rollback()
            return false
        }
        refreshCanonicalReviewCounts()
        return true
    }

    private func assignAliases(
        for rows: [CachedFinancialTransaction],
        to payee: DurableCanonicalPayee
    ) {
        let aliases = (try? mainContext.fetch(
            FetchDescriptor<DurablePayeeAlias>()
        )) ?? []
        let aliasesByKey = Dictionary(grouping: aliases, by: \.aliasKey)
        for evidence in rows.flatMap({
            $0.toSummary().payeeIdentityEvidence
        }) {
            if let existing = aliasesByKey[evidence.key],
               !existing.isEmpty {
                for alias in existing {
                    alias.payeeCanonicalId = payee.canonicalId
                    alias.displayValue = evidence.displayValue
                    alias.kindRaw = evidence.kind
                    alias.confirmed = true
                    alias.suppressed = false
                    alias.provenanceRaw =
                        ClassificationProvenance.user.rawValue
                    alias.updatedAt = .now
                }
            } else {
                mainContext.insert(DurablePayeeAlias(
                    aliasKey: evidence.key,
                    payeeCanonicalId: payee.canonicalId,
                    displayValue: evidence.displayValue,
                    kindRaw: evidence.kind,
                    provenance: .user,
                    confirmed: true
                ))
            }
        }
    }

    private func updateCachedPayeeName(
        _ payee: DurableCanonicalPayee
    ) {
        let canonicalId = payee.canonicalId
        let rows = (try? mainContext.fetch(
            FetchDescriptor<CachedFinancialTransaction>(
                predicate: #Predicate {
                    $0.payeeCanonicalId == canonicalId
                }
            )
        )) ?? []
        // Write only rows whose values actually change: most confirms don't
        // rename the payee, and unconditional writes dirty every row and
        // decision for the payee on each save.
        for row in rows where row.displayName != payee.name
            || row.requiresNameReview {
            row.displayName = payee.name
            row.requiresNameReview = false
            row.updatedAt = .now
        }
        let decisions = (try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalTransactionDecision>(
                predicate: #Predicate {
                    $0.payeeCanonicalId == canonicalId
                }
            )
        )) ?? []
        for decision in decisions
        where decision.payeeNameSnapshot != payee.name {
            decision.payeeNameSnapshot = payee.name
            decision.updatedAt = .now
        }
    }

    @discardableResult
    public func createCanonicalPayee(name: String) -> Bool {
        createCanonicalPayeeReturningId(name: name) != nil
    }

    public func createCanonicalPayeeReturningId(
        name: String
    ) -> String? {
        let cleaned = name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !cleaned.isEmpty else { return nil }
        let canonicalId = "networth:\(UUID().uuidString.lowercased())"
        mainContext.insert(DurableCanonicalPayee(
            canonicalId: canonicalId,
            name: cleaned,
            sourceName: cleaned,
            userEdited: true
        ))
        guard mainContext.safeSave(
            source: "canonicalPayees.create"
        ) else {
            mainContext.rollback()
            return nil
        }
        return canonicalId
    }

    @discardableResult
    public func updateCanonicalPayee(
        canonicalId: String,
        name: String,
        archived: Bool
    ) -> Bool {
        let cleaned = name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !cleaned.isEmpty else { return false }
        let payees = (try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalPayee>()
        )) ?? []
        guard let payee = payees.first(where: {
            $0.canonicalId == canonicalId
        }) else {
            return false
        }
        payee.name = cleaned
        payee.archived = archived
        payee.userEdited = true
        payee.updatedAt = .now
        updateCachedPayeeName(payee)
        guard mainContext.safeSave(
            source: "canonicalPayees.update"
        ) else {
            mainContext.rollback()
            return false
        }
        refreshCanonicalReviewCounts()
        return true
    }

    @discardableResult
    public func reassignCanonicalAlias(
        aliasId: UUID,
        to payeeCanonicalId: String
    ) -> Bool {
        let aliases = (try? mainContext.fetch(
            FetchDescriptor<DurablePayeeAlias>()
        )) ?? []
        let payees = (try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalPayee>()
        )) ?? []
        guard let alias = aliases.first(where: { $0.id == aliasId }),
              payees.contains(where: {
                  $0.canonicalId == payeeCanonicalId
              }) else {
            return false
        }
        alias.payeeCanonicalId = payeeCanonicalId
        alias.confirmed = true
        alias.suppressed = false
        alias.provenanceRaw = ClassificationProvenance.user.rawValue
        alias.updatedAt = .now
        applyCurrentCanonicalState()
        guard mainContext.safeSave(
            source: "canonicalPayees.reassignAlias"
        ) else {
            mainContext.rollback()
            return false
        }
        refreshCanonicalReviewCounts()
        return true
    }

    @discardableResult
    public func removeCanonicalAlias(aliasId: UUID) -> Bool {
        let aliases = (try? mainContext.fetch(
            FetchDescriptor<DurablePayeeAlias>()
        )) ?? []
        guard let alias = aliases.first(where: { $0.id == aliasId }) else {
            return false
        }
        alias.confirmed = false
        alias.suppressed = true
        alias.provenanceRaw = ClassificationProvenance.user.rawValue
        alias.updatedAt = .now
        applyCurrentCanonicalState()
        guard mainContext.safeSave(
            source: "canonicalPayees.removeAlias"
        ) else {
            mainContext.rollback()
            return false
        }
        refreshCanonicalReviewCounts()
        return true
    }

    @discardableResult
    public func mergeCanonicalPayees(
        sourceCanonicalId: String,
        destinationCanonicalId: String
    ) -> Bool {
        guard sourceCanonicalId != destinationCanonicalId else {
            return false
        }
        let payees = (try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalPayee>()
        )) ?? []
        guard let source = payees.first(where: {
                  $0.canonicalId == sourceCanonicalId
              }),
              let destination = payees.first(where: {
                  $0.canonicalId == destinationCanonicalId
              }) else {
            return false
        }
        let aliases = (try? mainContext.fetch(
            FetchDescriptor<DurablePayeeAlias>()
        )) ?? []
        for alias in aliases
        where alias.payeeCanonicalId == sourceCanonicalId {
            alias.payeeCanonicalId = destinationCanonicalId
            alias.provenanceRaw = ClassificationProvenance.user.rawValue
            alias.confirmed = true
            alias.updatedAt = .now
        }
        let decisions = (try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalTransactionDecision>()
        )) ?? []
        for decision in decisions
        where decision.payeeCanonicalId == sourceCanonicalId {
            decision.payeeCanonicalId = destinationCanonicalId
            decision.payeeNameSnapshot = destination.name
            decision.provenanceRaw = ClassificationProvenance.user.rawValue
            decision.updatedAt = .now
        }
        let rows = (try? mainContext.fetch(
            FetchDescriptor<CachedFinancialTransaction>()
        )) ?? []
        for row in rows where row.payeeCanonicalId == sourceCanonicalId {
            row.payeeCanonicalId = destinationCanonicalId
            row.displayName = destination.name
            row.updatedAt = .now
        }
        source.archived = true
        source.userEdited = true
        source.updatedAt = .now
        guard mainContext.safeSave(
            source: "canonicalPayees.merge"
        ) else {
            mainContext.rollback()
            return false
        }
        return true
    }

    @discardableResult
    public func createCanonicalCategory(
        name: String,
        groupName: String
    ) -> Bool {
        createCanonicalCategoryReturningId(
            name: name,
            groupName: groupName
        ) != nil
    }

    public func createCanonicalCategoryReturningId(
        name: String,
        groupName: String
    ) -> String? {
        let cleanedName = name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let cleanedGroup = groupName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !cleanedName.isEmpty else { return nil }
        guard !LegacyReimbursementRepresentation
            .isRetiredCategoryName(cleanedName) else { return nil }
        let canonicalId = "networth:\(UUID().uuidString.lowercased())"
        mainContext.insert(DurableCanonicalCategory(
            canonicalId: canonicalId,
            name: cleanedName,
            groupName: cleanedGroup.isEmpty
                ? "Networth Categories"
                : cleanedGroup,
            sourceName: cleanedName,
            sourceGroupName: cleanedGroup.isEmpty
                ? "Networth Categories"
                : cleanedGroup,
            userEdited: true
        ))
        guard mainContext.safeSave(
            source: "canonicalCategories.create"
        ) else {
            mainContext.rollback()
            return nil
        }
        return canonicalId
    }

    @discardableResult
    public func updateCanonicalCategory(
        canonicalId: String,
        name: String,
        groupName: String,
        hidden: Bool
    ) -> Bool {
        let categories = (try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalCategory>()
        )) ?? []
        guard let category = categories.first(where: {
                  $0.canonicalId == canonicalId
              }) else {
            return false
        }
        let cleanedName = name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let cleanedGroup = groupName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !cleanedName.isEmpty,
              !cleanedGroup.isEmpty,
              !LegacyReimbursementRepresentation
                .isRetiredCategoryName(cleanedName) else {
            return false
        }
        category.name = cleanedName
        category.groupName = cleanedGroup
        category.hidden = hidden
        category.userEdited = true
        category.updatedAt = .now
        let decisions = (try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalTransactionDecision>()
        )) ?? []
        for decision in decisions
        where decision.categoryCanonicalId == canonicalId {
            decision.categoryNameSnapshot = cleanedName
            decision.updatedAt = .now
        }
        let rows = (try? mainContext.fetch(
            FetchDescriptor<CachedFinancialTransaction>()
        )) ?? []
        for row in rows where row.categoryCanonicalId == canonicalId {
            row.categoryName = cleanedName
            row.updatedAt = .now
        }
        guard mainContext.safeSave(
            source: "canonicalCategories.update"
        ) else {
            mainContext.rollback()
            return false
        }
        return true
    }

    public func reviewMerchantName(
        id: String,
        displayName: String
    ) {
        reviewCanonicalPayeeNames(ids: [id], displayName: displayName)
    }

    public func reviewMerchantNames(
        ids: [String],
        displayName: String
    ) {
        reviewCanonicalPayeeNames(ids: ids, displayName: displayName)
    }

    /// One-time bridge from retired receiving-account inference. A candidate
    /// is only requeued when one unassigned savings deposit has exactly one
    /// equal-and-opposite cash-account transfer in a four-day window and that
    /// outflow is not claimed by another deposit. Nothing is auto-classified.
    @discardableResult
    public func stageLegacySavingsCandidatesForReview() -> Int {
        let accounts = (try? mainContext.fetch(
            FetchDescriptor<CachedFinancialAccount>()
        )) ?? []
        let accountTypeByID = Dictionary(
            uniqueKeysWithValues: accounts.map {
                ($0.canonicalAccountId, $0.type)
            }
        )
        let goalReserveIDs = Set(((try? mainContext.fetch(
            FetchDescriptor<DurableGoalReserveAccount>()
        )) ?? []).filter(\.active).map(\.canonicalAccountId))
        let assignedTransactionIDs = Set(((try? mainContext.fetch(
            FetchDescriptor<DurableSavingsTransferAssignment>()
        )) ?? []).filter {
            $0.active && $0.subtransactionId.isEmpty
        }.map(\.transactionId))
        let rows = (try? mainContext.fetch(
            FetchDescriptor<CachedFinancialTransaction>()
        )) ?? []
        let deposits = rows.filter {
            !$0.deleted && !$0.pending
                && $0.forecastTreatment == .internalTransfer
                && $0.amountMilliunits > 0
                && accountTypeByID[$0.canonicalAccountId] == .savings
                && !goalReserveIDs.contains($0.canonicalAccountId)
                && !assignedTransactionIDs.contains($0.id)
        }
        let outflows = rows.filter {
            !$0.deleted && !$0.pending
                && $0.forecastTreatment == .internalTransfer
                && $0.amountMilliunits < 0
                && accountTypeByID[$0.canonicalAccountId]?.isCashLike == true
                && accountTypeByID[$0.canonicalAccountId] != .savings
        }
        let proposedPairs = deposits.compactMap {
            deposit -> (depositID: String, outflow: CachedFinancialTransaction)? in
            let matches = outflows.filter {
                $0.amountMilliunits == -deposit.amountMilliunits
                    && abs($0.postedDate.timeIntervalSince(deposit.postedDate))
                        <= 4 * 86_400
            }
            guard matches.count == 1, let match = matches.first else {
                return nil
            }
            return (deposit.id, match)
        }
        let countsByOutflowID = Dictionary(grouping: proposedPairs) {
            $0.outflow.id
        }.mapValues(\.count)
        let candidates = proposedPairs.compactMap {
            countsByOutflowID[$0.outflow.id] == 1 ? $0.outflow : nil
        }
        let decisions = (try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalTransactionDecision>()
        )) ?? []
        let decisionByExternalID = latestCanonicalDecisionsByTransactionID(
            decisions
        )
        let now = Date.now
        for row in candidates {
            row.requiresReview = true
            row.updatedAt = now
            if let decision = decisionByExternalID[row.externalId] {
                decision.reviewed = false
                decision.updatedAt = now
            }
        }
        return candidates.count
    }

    @discardableResult
    public func confirmTransaction(
        id: String,
        displayName: String,
        payeeCanonicalId: String? = nil,
        categoryName: String?,
        treatment: ForecastTreatment,
        categoryCanonicalId: String? = nil,
        goalId: UUID? = nil,
        reserveFundId: UUID? = nil,
        savingsMonth: BudgetMonth? = nil
    ) -> Bool {
        return confirmCanonicalTransaction(
            id: id,
            displayName: displayName,
            payeeCanonicalId: payeeCanonicalId,
            categoryName: categoryName,
            treatment: treatment,
            categoryCanonicalId: categoryCanonicalId,
            goalId: goalId,
            reserveFundId: reserveFundId,
            savingsMonth: savingsMonth
        )
    }

    @discardableResult
    public func reviewSplitTransaction(
        id: String,
        displayName: String,
        payeeCanonicalId: String? = nil,
        subtransactions: [SubTransactionSummary],
        reserveFundIdBySubtransactionId: [String: UUID] = [:],
        savingsMonthBySubtransactionId: [String: BudgetMonth] = [:]
    ) -> Bool {
        switch reviewSplitTransactionResult(
            id: id,
            displayName: displayName,
            payeeCanonicalId: payeeCanonicalId,
            subtransactions: subtransactions,
            reserveFundIdBySubtransactionId:
                reserveFundIdBySubtransactionId,
            savingsMonthBySubtransactionId:
                savingsMonthBySubtransactionId
        ) {
        case .success: true
        case .failure: false
        }
    }

    public func reviewSplitTransactionResult(
        id: String,
        displayName: String,
        payeeCanonicalId: String? = nil,
        subtransactions: [SubTransactionSummary],
        reserveFundIdBySubtransactionId: [String: UUID] = [:],
        savingsMonthBySubtransactionId: [String: BudgetMonth] = [:]
    ) -> Result<Void, SplitReviewFailure> {
        confirmCanonicalSplitTransaction(
            id: id,
            displayName: displayName,
            payeeCanonicalId: payeeCanonicalId,
            subtransactions: subtransactions,
            reserveFundIdBySubtransactionId:
                reserveFundIdBySubtransactionId,
            savingsMonthBySubtransactionId:
                savingsMonthBySubtransactionId
        )
    }

    private func sync(
        item: PlaidItemDTO,
        existingByID: inout [String: CachedFinancialTransaction]
    ) async -> Bool {
        let cursorRows = (try? mainContext.fetch(
            FetchDescriptor<PlaidTransactionCursor>()
        )) ?? []
        let cursorRow = cursorRows.first(where: { $0.itemId == item.id })
            ?? {
                let row = PlaidTransactionCursor(itemId: item.id)
                mainContext.insert(row)
                return row
            }()
        let isHistoricalImport = !cursorRow.historicalImportComplete
        let settings = (try? mainContext.fetch(
            FetchDescriptor<DurableUserSettings>()
        ))?.first
        let coverageRows = (try? mainContext.fetch(
            FetchDescriptor<PlaidAccountCoverage>()
        )) ?? []
        var coverageByPlaidAccountID = Dictionary(
            uniqueKeysWithValues: coverageRows.map { ($0.plaidAccountId, $0) }
        )
        var cursor = cursorRow.cursor
        var hasMore = true
        while hasMore {
            let response = try? await client.transactions(
                itemId: item.id,
                cursor: cursor,
                count: 500
            )
            guard let response else {
                mainContext.rollback()
                phase = .error("Banking sync failed for \(item.institutionName).")
                return false
            }
            let canonicalByPlaidID = ensureBindingsAndAccounts(
                response.accounts,
                itemId: item.id
            )
            for (index, transaction) in (response.added + response.modified).enumerated() {
                guard let canonicalID = canonicalByPlaidID[transaction.accountId],
                      let summary = transaction.financialSummary(
                        canonicalAccountId: canonicalID
                      ) else {
                    continue
                }
                let suggestion = await classification(
                    for: summary,
                    allowModelInference: !isHistoricalImport,
                    claudeFallbackEnabled: settings?.claudeFallbackEnabled == true
                )
                let classification = reviewClassification(
                    suggestion,
                    transaction: summary
                )
                upsert(
                    summary,
                    classification: classification,
                    subtransactionsData: nil,
                    requiresNameReview: !summary.pending,
                    reviewOriginRaw: isHistoricalImport ? "historical" : "new",
                    existingByID: &existingByID
                )
                recordCoverage(
                    plaidAccountId: transaction.accountId,
                    itemId: item.id,
                    date: summary.postedDate,
                    into: &coverageByPlaidAccountID
                )
                if let pendingID = summary.pendingTransactionId {
                    markDeleted(
                        id: "plaid:\(pendingID)",
                        existingByID: existingByID
                    )
                }
                if index.isMultiple(of: 100) {
                    await Task.yield()
                }
            }
            for removedID in response.removed {
                markDeleted(id: "plaid:\(removedID)", existingByID: existingByID)
            }
            cursor = response.nextCursor
            cursorRow.cursor = cursor
            cursorRow.updateStatus = response.updateStatus
            cursorRow.updatedAt = .now
            hasMore = response.hasMore
            guard mainContext.safeSave(source: "plaidTransactions.page") else {
                mainContext.rollback()
                phase = .error("Saving banking data failed. Retry in a moment.")
                return false
            }
        }
        return true
    }

    /// Widens the account's imported-history record to include `date`.
    /// Coverage is tracked per account — imported start and end dates are
    /// account-specific and never replaced by one global history window.
    private func recordCoverage(
        plaidAccountId: String,
        itemId: String,
        date: Date,
        into coverageByPlaidAccountID: inout [String: PlaidAccountCoverage]
    ) {
        let row: PlaidAccountCoverage
        if let existing = coverageByPlaidAccountID[plaidAccountId] {
            row = existing
        } else {
            row = PlaidAccountCoverage(plaidAccountId: plaidAccountId, itemId: itemId)
            mainContext.insert(row)
            coverageByPlaidAccountID[plaidAccountId] = row
        }
        if row.earliestImportedDate.map({ date < $0 }) ?? true {
            row.earliestImportedDate = date
        }
        if row.latestImportedDate.map({ date > $0 }) ?? true {
            row.latestImportedDate = date
        }
        row.updatedAt = .now
    }

    private func ensureBindingsAndAccounts(
        _ accounts: [PlaidAccountDTO],
        itemId: String
    ) -> [String: String] {
        let bindings = (try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalAccountBinding>()
        )) ?? []
        var bindingByPlaidID = Dictionary(
            uniqueKeysWithValues: bindings.map { ($0.plaidAccountId, $0) }
        )
        let cached = (try? mainContext.fetch(
            FetchDescriptor<CachedFinancialAccount>()
        )) ?? []
        var cachedByCanonicalID = Dictionary(
            uniqueKeysWithValues: cached.map { ($0.canonicalAccountId, $0) }
        )

        var returnedPlaidAccountIDs = Set<String>()
        for account in accounts {
            let provisional = account.financialSummary(canonicalAccountId: UUID().uuidString)
            // Transactions replaces YNAB only for banking and card data.
            // Investments retain their dedicated Plaid path; loans retain
            // their existing local/legacy sources.
            guard provisional.type != .investment, provisional.type != .loan else {
                continue
            }
            returnedPlaidAccountIDs.insert(account.id)
            let binding: DurableCanonicalAccountBinding
            if let existing = bindingByPlaidID[account.id] {
                binding = existing
                binding.itemId = account.itemId
                binding.institutionName = account.institutionName
                binding.accountName = account.name
                binding.mask = account.mask
                binding.accountType = provisional.type
                binding.updatedAt = .now
            } else {
                binding = DurableCanonicalAccountBinding(
                    canonicalAccountId: provisional.id,
                    plaidAccountId: account.id,
                    itemId: account.itemId,
                    institutionName: account.institutionName,
                    accountName: account.name,
                    mask: account.mask,
                    accountType: provisional.type
                )
                mainContext.insert(binding)
                bindingByPlaidID[account.id] = binding
            }
            let summary = account.financialSummary(
                canonicalAccountId: binding.canonicalAccountId
            )
            if let row = cachedByCanonicalID[binding.canonicalAccountId] {
                apply(summary, to: row)
            } else {
                let row = CachedFinancialAccount(
                    canonicalAccountId: summary.id,
                    externalId: summary.externalId,
                    itemId: summary.itemId,
                    source: summary.source,
                    institutionName: summary.institutionName,
                    name: summary.name,
                    officialName: summary.officialName,
                    mask: summary.mask,
                    type: summary.type,
                    subtype: summary.subtype,
                    currentBalanceMilliunits: summary.currentBalance?.milliunits,
                    availableBalanceMilliunits: summary.availableBalance?.milliunits,
                    creditLimitMilliunits: summary.creditLimit?.milliunits,
                    isoCurrencyCode: summary.isoCurrencyCode
                )
                mainContext.insert(row)
                cachedByCanonicalID[summary.id] = row
            }
        }
        for row in cached where row.itemId == itemId {
            row.deleted = !returnedPlaidAccountIDs.contains(row.externalId)
            if row.deleted { row.updatedAt = .now }
        }
        return Dictionary(
            uniqueKeysWithValues: bindingByPlaidID.compactMap {
                guard returnedPlaidAccountIDs.contains($0.key) else { return nil }
                return ($0.key, $0.value.canonicalAccountId)
            }
        )
    }

    private func classification(
        for transaction: FinancialTransactionSummary,
        allowModelInference: Bool,
        claudeFallbackEnabled: Bool
    ) async -> TransactionClassification {
        let providerResult = classifier.classify(
            transaction,
            rules: []
        )
        guard providerResult.requiresReview,
              allowModelInference else {
            return providerResult
        }

        let apple = await inferenceProvider.suggestion(for: transaction)
        if apple?.confidence == .high {
            return classifier.classify(
                transaction,
                rules: [],
                modelSuggestion: apple
            )
        }
        if claudeFallbackEnabled {
            let claudeDTO = try? await client.inferTransaction(
                PlaidInferenceRequestDTO(transaction: transaction)
            )
            if let claude = claudeDTO?.suggestion(provenance: .claude) {
                return classifier.classify(
                    transaction,
                    rules: [],
                    modelSuggestion: claude
                )
            }
        }
        return classifier.classify(
            transaction,
            rules: [],
            modelSuggestion: apple
        )
    }

    private func reviewClassification(
        _ suggestion: TransactionClassification,
        transaction: FinancialTransactionSummary
    ) -> TransactionClassification {
        TransactionClassification(
            displayName: suggestion.displayName,
            categoryName: suggestion.categoryName,
            treatment: suggestion.treatment,
            confidence: suggestion.confidence,
            provenance: suggestion.provenance,
            requiresReview: !transaction.pending
        )
    }

    private func upsert(
        _ summary: FinancialTransactionSummary,
        classification: TransactionClassification,
        subtransactionsData: Data?,
        requiresNameReview: Bool,
        reviewOriginRaw: String,
        existingByID: inout [String: CachedFinancialTransaction]
    ) {
        if let row = existingByID[summary.id] {
            apply(
                summary,
                classification: classification,
                subtransactionsData: subtransactionsData,
                requiresNameReview: requiresNameReview,
                to: row
            )
        } else {
            let row = CachedFinancialTransaction(
                summary: summary,
                classification: classification,
                subtransactionsData: subtransactionsData,
                requiresNameReview: requiresNameReview,
                reviewOriginRaw: reviewOriginRaw
            )
            mainContext.insert(row)
            existingByID[summary.id] = row
        }
    }

    private func markDeleted(
        id: String,
        existingByID: [String: CachedFinancialTransaction]
    ) {
        if let row = existingByID[id] {
            row.deleted = true
            row.updatedAt = .now
        }
    }

    /// A transaction whose owning account row is gone or deleted is
    /// unreachable from every account screen, yet the spending and
    /// projection filters look only at the transaction's own fields, so it
    /// would keep counting forever. Re-links mint a fresh canonical account
    /// id for the same real-world account and item removal cleans only the
    /// ids it can still reach, so orphans are possible; retire them.
    @discardableResult
    private func markOrphanedTransactionsDeleted() -> Bool {
        let accounts = (try? mainContext.fetch(
            FetchDescriptor<CachedFinancialAccount>()
        )) ?? []
        let liveIDs = Set(
            accounts.filter { !$0.deleted }.map(\.canonicalAccountId)
        )
        // An empty live set means a partial or pre-sync cache; retiring
        // everything against it would erase real history irrecoverably now
        // that deleted rows are never resurrected.
        guard !liveIDs.isEmpty else { return false }
        let rows = (try? mainContext.fetch(
            FetchDescriptor<CachedFinancialTransaction>(
                predicate: #Predicate { !$0.deleted }
            )
        )) ?? []
        var changed = false
        for row in rows where !liveIDs.contains(row.canonicalAccountId) {
            row.deleted = true
            row.updatedAt = .now
            changed = true
        }
        if changed {
            logger.info("Retired orphaned Plaid transactions with no live account.")
        }
        return changed
    }

    private func historicalTreatment(
        for transaction: CachedTransaction,
        creditCardIDs: Set<String>
    ) -> ForecastTreatment {
        if let transferAccountID = transaction.transferAccountId {
            return creditCardIDs.contains(transaction.accountId)
                || creditCardIDs.contains(transferAccountID)
                ? .cardPayment
                : .internalTransfer
        }
        if transaction.amountMilliunits < 0 {
            return .ordinarySpending
        }
        if transaction.categoryName?.localizedCaseInsensitiveContains("income") == true {
            return .income
        }
        return .refund
    }

    private func upsertItems(_ items: [PlaidItemDTO]) {
        let rows = (try? mainContext.fetch(FetchDescriptor<CachedPlaidItem>())) ?? []
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        for item in items {
            if let row = byID[item.id] {
                row.institutionName = item.institutionName
                row.status = item.status
                row.lastSyncedAt = item.lastSyncedAt
                row.productsRaw = (item.products ?? []).sorted().joined(separator: ",")
            } else {
                mainContext.insert(
                    CachedPlaidItem(
                        id: item.id,
                        institutionName: item.institutionName,
                        status: item.status,
                        lastSyncedAt: item.lastSyncedAt,
                        products: item.products ?? []
                    )
                )
            }
        }
    }

    private func apply(_ summary: FinancialAccountSummary, to row: CachedFinancialAccount) {
        row.externalId = summary.externalId
        row.itemId = summary.itemId
        row.sourceRaw = summary.source.rawValue
        row.institutionName = summary.institutionName
        row.name = summary.name
        row.officialName = summary.officialName
        row.mask = summary.mask
        row.typeRaw = summary.type.rawValue
        row.subtype = summary.subtype
        row.currentBalanceMilliunits = summary.currentBalance?.milliunits
        row.availableBalanceMilliunits = summary.availableBalance?.milliunits
        row.creditLimitMilliunits = summary.creditLimit?.milliunits
        row.isoCurrencyCode = summary.isoCurrencyCode
        row.deleted = false
        row.updatedAt = .now
    }

    private func apply(
        _ summary: FinancialTransactionSummary,
        classification: TransactionClassification,
        subtransactionsData: Data?,
        requiresNameReview: Bool,
        to row: CachedFinancialTransaction
    ) {
        let preservesCompletedHistoricalNameReview =
            !row.pending
                && row.reviewOriginRaw == "historical"
                && !row.requiresNameReview
        row.externalId = summary.externalId
        row.sourceRaw = summary.source.rawValue
        row.canonicalAccountId = summary.accountId
        row.postedDate = summary.postedDate
        row.authorizedDate = summary.authorizedDate
        row.amountMilliunits = summary.amount.milliunits
        row.pending = summary.pending
        row.pendingTransactionId = summary.pendingTransactionId
        row.rawDescription = summary.rawDescription
        row.originalDescription = summary.originalDescription
        row.providerMerchantName = summary.providerMerchantName
        row.merchantEntityId = summary.merchantEntityId
        row.counterpartyName = summary.counterpartyName
        row.counterpartyType = summary.counterpartyType
        row.counterpartyEntityId = summary.counterpartyEntityId
        row.counterpartyConfidence = summary.counterpartyConfidence
        row.paymentChannel = summary.paymentChannel
        row.providerCategoryPrimary = summary.providerCategoryPrimary
        row.providerCategoryDetailed = summary.providerCategoryDetailed
        row.providerCategoryConfidence = summary.providerCategoryConfidence
        row.transactionCode = summary.transactionCode
        row.displayName = classification.displayName
        row.nativeCategoryRaw = "other"
        row.categoryName = classification.categoryName
        row.forecastTreatmentRaw = classification.treatment.rawValue
        row.subtransactionsData = subtransactionsData
        row.classificationConfidenceRaw = classification.confidence.rawValue
        row.classificationProvenanceRaw = classification.provenance.rawValue
        row.requiresReview = classification.requiresReview
        row.requiresNameReview = requiresNameReview
            && !preservesCompletedHistoricalNameReview
        normalizeLegacyReimbursement(in: row)
        // Never resurrect: local deletion only ever comes from a bank removal
        // or a posted transaction superseding its pending authorization, and
        // Plaid never un-removes an id. A later added/modified redelivery for
        // the same id must not bring a dead row back into spending.
        row.updatedAt = .now
    }

    private func message(for error: PlaidClientError) -> String {
        switch error {
        case .missingConfiguration: "Plaid backend setup is incomplete."
        case .unauthorized: "The Plaid backend token was rejected."
        case .invalidResponse: "The banking service returned an error."
        case .decoding: "The banking response could not be read."
        case .transport: "The banking service could not be reached."
        case .cancelled: ""
        }
    }
}

public enum ClaudeDataSyncPhase: Sendable, Equatable {
    case idle
    case syncing
    case success(Date)
    case error(String)
}

public enum ClaudeDataSyncError: Error, LocalizedError {
    case settingsUnavailable
    case syncDisabled
    case snapshotUnavailable
    case saveFailed

    public var errorDescription: String? {
        switch self {
        case .settingsUnavailable:
            "Networth settings are unavailable."
        case .syncDisabled:
            "Turn on Claude.ai data access first."
        case .snapshotUnavailable:
            "Sync the financial copy successfully before connecting Claude.ai."
        case .saveFailed:
            "The Claude.ai sync setting could not be saved."
        }
    }
}

/// Full-replacement, read-only snapshot sync for the personal Claude.ai MCP
/// connector. A successful app save schedules one upload after a short
/// debounce. The snapshot deliberately excludes secrets, provider IDs,
/// account masks, notes, raw bank descriptions, and unreviewed transactions.
@MainActor
@Observable
public final class ClaudeDataSyncCoordinator {
    public private(set) var phase: ClaudeDataSyncPhase = .idle

    private let client: any PlaidClient
    private let mainContext: ModelContext
    private var observerToken: NSObjectProtocol?
    private var debounceTask: Task<Void, Never>?
    private var isRunning = false
    private let logger = Logger(
        subsystem: "com.bluelava.me.networth",
        category: "claude-data-sync"
    )

    public init(
        client: any PlaidClient,
        mainContext: ModelContext
    ) {
        self.client = client
        self.mainContext = mainContext
    }

    public func start() {
        guard observerToken == nil else { return }
        observerToken = NotificationCenter.default.addObserver(
            forName: .networthModelContextSaved,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleSync()
            }
        }
    }

    public func setEnabled(_ enabled: Bool) async throws {
        guard let settings = userSettings else {
            throw ClaudeDataSyncError.settingsUnavailable
        }
        if enabled {
            settings.claudeDataSyncEnabled = true
            settings.claudeDataSyncConsentAt = .now
            guard mainContext.safeSave(
                source: "settings.claudeDataSync.enable",
                notifyDataSync: false
            ) else {
                mainContext.rollback()
                throw ClaudeDataSyncError.saveFailed
            }
            await runOnce()
            return
        }

        // Keep the local opt-in state intact until the remote copy and OAuth
        // grants have actually been removed, so the UI never claims a wipe
        // succeeded when the backend was unreachable.
        try await client.revokeClaudeAccess()
        settings.claudeDataSyncEnabled = false
        settings.claudeDataSyncConsentAt = nil
        settings.claudeDataLastSyncedAt = nil
        guard mainContext.safeSave(
            source: "settings.claudeDataSync.disable",
            notifyDataSync: false
        ) else {
            mainContext.rollback()
            throw ClaudeDataSyncError.saveFailed
        }
        phase = .idle
    }

    public func runOnce() async {
        guard isEnabled, !isRunning else { return }
        isRunning = true
        phase = .syncing
        defer { isRunning = false }

        do {
            let generatedAt = Date.now
            let snapshot = try ClaudeFinancialSnapshotBuilder.build(
                mainContext: mainContext,
                generatedAt: generatedAt
            )
            try await client.uploadClaudeSnapshot(snapshot)
            if let settings = userSettings {
                settings.claudeDataLastSyncedAt = generatedAt
                guard mainContext.safeSave(
                    source: "claudeDataSync.lastSyncedAt",
                    notifyDataSync: false
                ) else {
                    mainContext.rollback()
                    throw ClaudeDataSyncError.saveFailed
                }
            }
            phase = .success(generatedAt)
        } catch {
            logger.error(
                "Claude.ai snapshot sync failed: \(error.localizedDescription, privacy: .public)"
            )
            phase = .error("The Claude.ai copy could not be updated.")
        }
    }

    public func generateConnectCode() async throws
        -> ClaudeConnectCodeResponseDTO {
        guard isEnabled else {
            throw ClaudeDataSyncError.syncDisabled
        }
        guard userSettings?.claudeDataLastSyncedAt != nil else {
            throw ClaudeDataSyncError.snapshotUnavailable
        }
        return try await client.generateClaudeConnectCode()
    }

    private var userSettings: DurableUserSettings? {
        try? mainContext.fetch(
            FetchDescriptor<DurableUserSettings>()
        ).first
    }

    private var isEnabled: Bool {
        userSettings?.claudeDataSyncEnabled == true
    }

    private func scheduleSync() {
        guard isEnabled else { return }
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1_500))
            guard !Task.isCancelled else { return }
            await self?.runOnce()
        }
    }
}

@MainActor
enum ClaudeFinancialSnapshotBuilder {
    static func build(
        mainContext: ModelContext,
        generatedAt: Date = .now
    ) throws -> ClaudeFinancialSnapshotDTO {
        let settings = try mainContext.fetch(
            FetchDescriptor<DurableUserSettings>()
        ).first
        let primarySource = settings?.primaryFinancialDataSource ?? .plaid
        let manualAssets = try mainContext.fetch(
            FetchDescriptor<DurableManualAsset>()
        ).filter { !$0.deleted }
        let plaidAccounts = try mainContext.fetch(
            FetchDescriptor<CachedPlaidAccount>()
        )
        let plaidTreatments = try mainContext.fetch(
            FetchDescriptor<DurablePlaidAccountTreatment>()
        )
        let accountNameResolver = AccountDisplayNameResolver(
            nicknames: try mainContext.fetch(
                FetchDescriptor<DurableAccountNickname>()
            )
        )
        let resolver = PlaidContributionResolver(
            plaidAccounts: plaidAccounts,
            treatments: plaidTreatments,
            manualAssets: manualAssets
        )

        return ClaudeFinancialSnapshotDTO(
            generatedAt: generatedAt,
            primarySource: primarySource.rawValue,
            accounts: try accountDTOs(
                mainContext: mainContext,
                source: primarySource,
                budgetID: settings?.selectedBudgetId,
                accountNameResolver: accountNameResolver
            ),
            manualAssets: manualAssets
                .map {
                    ClaudeManualAssetDTO(
                        name: $0.name,
                        groupName: $0.groupName?.trimmed.nilIfEmpty,
                        type: $0.kind.rawValue,
                        currentValueMilliunits:
                            resolver.effectiveValue(for: $0).milliunits,
                        lastUpdatedAt: $0.lastUpdatedAt
                    )
                }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            holdings: try holdingDTOs(
                mainContext: mainContext,
                accounts: plaidAccounts,
                includedAccountIDs:
                    resolver.contributingPlaidAccountIDs,
                accountNameResolver: accountNameResolver
            ),
            transactions: try transactionDTOs(
                mainContext: mainContext,
                source: primarySource,
                budgetID: settings?.selectedBudgetId
            ),
            netWorthHistory: try netWorthDTOs(
                mainContext: mainContext
            )
        )
    }

    private static func accountDTOs(
        mainContext: ModelContext,
        source: FinancialDataSource,
        budgetID: String?,
        accountNameResolver: AccountDisplayNameResolver
    ) throws -> [ClaudeAccountDTO] {
        if source == .plaid {
            return try mainContext.fetch(
                FetchDescriptor<CachedFinancialAccount>()
            )
            .filter { !$0.deleted }
            .map {
                ClaudeAccountDTO(
                    name: accountNameResolver.name(for: $0),
                    institutionName:
                        $0.institutionName?.trimmed.nilIfEmpty,
                    type: $0.type.rawValue,
                    balanceMilliunits: $0.balance.milliunits,
                    availableBalanceMilliunits:
                        $0.availableBalanceMilliunits,
                    closed: false
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }

        return try mainContext.fetch(
            FetchDescriptor<CachedAccount>()
        )
        .filter {
            !$0.deleted
                && (budgetID == nil || $0.budgetId == budgetID)
        }
        .map {
            ClaudeAccountDTO(
                name: $0.name,
                institutionName: nil,
                type: $0.kind.rawValue,
                balanceMilliunits: $0.balanceMilliunits,
                availableBalanceMilliunits: nil,
                closed: $0.closed
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func holdingDTOs(
        mainContext: ModelContext,
        accounts: [CachedPlaidAccount],
        includedAccountIDs: Set<String>,
        accountNameResolver: AccountDisplayNameResolver
    ) throws -> [ClaudeHoldingDTO] {
        let accountByID = Dictionary(
            uniqueKeysWithValues: accounts.compactMap {
                includedAccountIDs.contains($0.id)
                    ? ($0.id, $0)
                    : nil
            }
        )
        let securities = try mainContext.fetch(
            FetchDescriptor<CachedPlaidSecurity>()
        )
        let securityByID = Dictionary(
            uniqueKeysWithValues: securities.map { ($0.id, $0) }
        )
        return try mainContext.fetch(
            FetchDescriptor<CachedPlaidHolding>()
        )
        .compactMap { holding in
            guard let account = accountByID[holding.accountId],
                  let security = securityByID[holding.securityId] else {
                return nil
            }
            let securityName =
                security.name?.trimmed.nilIfEmpty
                ?? security.tickerSymbol?.trimmed.nilIfEmpty
                ?? "Unknown security"
            return ClaudeHoldingDTO(
                accountName: accountNameResolver.name(for: account),
                institutionName:
                    account.institutionName.trimmed.nilIfEmpty,
                securityName: securityName,
                tickerSymbol:
                    security.tickerSymbol?.trimmed.nilIfEmpty,
                securityType: security.typeRaw?.trimmed.nilIfEmpty,
                quantity: holding.quantityDecimalString,
                valueMilliunits: holding.institutionValueMilliunits,
                costBasisMilliunits: holding.costBasisMilliunits,
                asOf: holding.asOf
            )
        }
        .sorted {
            if $0.accountName == $1.accountName {
                return $0.securityName.localizedStandardCompare(
                    $1.securityName
                ) == .orderedAscending
            }
            return $0.accountName.localizedStandardCompare(
                $1.accountName
            ) == .orderedAscending
        }
    }

    private static func transactionDTOs(
        mainContext: ModelContext,
        source: FinancialDataSource,
        budgetID: String?
    ) throws -> [ClaudeTransactionDTO] {
        if source == .plaid {
            let accounts = try mainContext.fetch(
                FetchDescriptor<CachedFinancialAccount>()
            )
            let accountNameByID = Dictionary(
                uniqueKeysWithValues: accounts.map {
                    ($0.canonicalAccountId, $0.name)
                }
            )
            return try mainContext.fetch(
                FetchDescriptor<CachedFinancialTransaction>()
            )
            .filter {
                !$0.deleted
                    && !$0.pending
                    && !$0.requiresReview
                    && !$0.requiresNameReview
            }
            .map {
                ClaudeTransactionDTO(
                    date: $0.postedDate,
                    accountName:
                        accountNameByID[$0.canonicalAccountId]
                        ?? "Unknown account",
                    contactName: $0.displayName,
                    categoryName: $0.isSplit
                        ? "Split"
                        : $0.categoryName?.trimmed.nilIfEmpty,
                    treatment: $0.forecastTreatment.rawValue,
                    amountMilliunits: $0.amountMilliunits,
                    splits: $0.subtransactions.map {
                        ClaudeTransactionSplitDTO(
                            categoryName:
                                $0.categoryName?.trimmed.nilIfEmpty,
                            treatment:
                                $0.forecastTreatment?.rawValue,
                            amountMilliunits: $0.amount.milliunits
                        )
                    }
                )
            }
            .sorted { $0.date > $1.date }
        }

        let accounts = try mainContext.fetch(
            FetchDescriptor<CachedAccount>()
        )
        let accountNameByID = Dictionary(
            uniqueKeysWithValues: accounts.map { ($0.id, $0.name) }
        )
        return try mainContext.fetch(
            FetchDescriptor<CachedTransaction>()
        )
        .filter {
            !$0.deleted
                && (budgetID == nil || $0.budgetId == budgetID)
        }
        .map {
            let treatment: String
            if $0.transferAccountId != nil {
                treatment = ForecastTreatment.internalTransfer.rawValue
            } else if $0.amountMilliunits >= 0 {
                treatment = ForecastTreatment.income.rawValue
            } else {
                treatment = ForecastTreatment.ordinarySpending.rawValue
            }
            return ClaudeTransactionDTO(
                date: $0.date,
                accountName:
                    accountNameByID[$0.accountId] ?? "Unknown account",
                contactName:
                    $0.payeeName?.trimmed.nilIfEmpty ?? "Unknown",
                categoryName: $0.subtransactions.isEmpty
                    ? $0.categoryName?.trimmed.nilIfEmpty
                    : "Split",
                treatment: treatment,
                amountMilliunits: $0.amountMilliunits,
                splits: $0.subtransactions.map {
                    ClaudeTransactionSplitDTO(
                        categoryName:
                            $0.categoryName?.trimmed.nilIfEmpty,
                        treatment: $0.forecastTreatment?.rawValue,
                        amountMilliunits: $0.amount.milliunits
                    )
                }
            )
        }
        .sorted { $0.date > $1.date }
    }

    private static func netWorthDTOs(
        mainContext: ModelContext
    ) throws -> [ClaudeNetWorthPointDTO] {
        let snapshots = try mainContext.fetch(
            FetchDescriptor<DurableNetWorthSnapshot>()
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var byDay: [Date: DurableNetWorthSnapshot] = [:]
        for snapshot in snapshots {
            let day = calendar.startOfDay(for: snapshot.date)
            guard let existing = byDay[day] else {
                byDay[day] = snapshot
                continue
            }
            let shouldReplace =
                snapshot.source == .live && existing.source != .live
                || snapshot.source == existing.source
                    && snapshot.createdAt > existing.createdAt
            if shouldReplace {
                byDay[day] = snapshot
            }
        }
        return byDay.map { day, snapshot in
            ClaudeNetWorthPointDTO(
                date: day,
                assetsMilliunits: snapshot.assetsMilliunits,
                liabilitiesMilliunits:
                    snapshot.liabilitiesMilliunits
            )
        }
        .sorted { $0.date < $1.date }
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
