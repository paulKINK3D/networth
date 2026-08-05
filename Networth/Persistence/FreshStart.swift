import Foundation
import NetworthCore
import SwiftData
import os

/// Versioned, destructive Plaid-first clean start (Phase 1 redesign).
///
/// Deletes every row from both SwiftData stores — YNAB and Plaid caches,
/// cursors, settings, account mappings, canonical directories, transaction
/// decisions, merchant rules, manual assets and value history, Net Worth
/// snapshots, investment balance history, projection/card configuration, and
/// legacy budget/fund records — then creates a fresh Plaid-first default
/// settings row. Nothing is migrated from old rows into the fresh stores.
///
/// Untouched: Keychain secrets (the YNAB PAT is retained solely for explicit
/// reference imports), Plaid Worker Item connections, and the external
/// read-only IBR App Group document.
///
/// Idempotence: the wipe, the fresh settings row, and the `freshStartVersion`
/// completion marker commit in ONE atomic save — either the clean start fully
/// happens or nothing changes, so an attempt interrupted or failed at any
/// point leaves legacy state intact and re-runs on the next launch. The
/// durable marker syncs via CloudKit, but the cache store is device-local, so
/// a separate per-device marker (UserDefaults) ensures every device wipes its
/// own cache store even when another device already completed the durable
/// wipe. Once complete, `purgeResurrectedLegacyRows` deletes retired-model
/// rows and stale settings rows that CloudKit sync resurrects from an old
/// device or backup. Resurrected rows of still-live durable types are
/// indistinguishable from fresh user data and rely on the wiping device's
/// propagated CloudKit deletions instead.
@MainActor
enum FreshStart {
    /// Bump to run a new destructive clean start.
    static let currentVersion = 1

    /// Per-device marker for the local cache store wipe. Deliberately not
    /// CloudKit-backed: a device that learns the durable wipe completed
    /// elsewhere must still clear its own legacy caches exactly once.
    static let localCacheWipeVersionKey = "networth.freshStartLocalCacheWipeVersion"

    private static let logger = Logger(
        subsystem: "com.bluelava.me.networth", category: "freshStart"
    )

    static func runIfNeeded(
        context: ModelContext,
        defaults: UserDefaults = .standard
    ) {
        let settingsRows =
            (try? context.fetch(FetchDescriptor<DurableUserSettings>())) ?? []
        let completedVersion = settingsRows.map(\.freshStartVersion).max() ?? 0
        if completedVersion >= currentVersion {
            // The durable wipe completed — possibly on another device whose
            // marker arrived via CloudKit. This device's local cache store is
            // untouched by that; wipe it here exactly once. Never re-wipe the
            // durable store: it may already hold rows created after the
            // clean start.
            wipeLocalCacheIfNeeded(context: context, defaults: defaults)
            purgeResurrectedLegacyRows(context: context)
            return
        }
        performCleanStart(context: context, defaults: defaults)
    }

    // MARK: - Clean start

    private static func performCleanStart(
        context: ModelContext,
        defaults: UserDefaults
    ) {
        logger.notice("Starting Plaid-first clean start v\(currentVersion, privacy: .public)")

        guard deleteEveryRow(context: context) else {
            context.rollback()
            logger.error("Clean start aborted: row deletion failed; will retry next launch")
            return
        }
        // Pending deletions are visible to fetches, so emptiness is verified
        // before committing anything.
        guard bothStoresAreEmpty(context: context) else {
            context.rollback()
            logger.error("Clean start aborted: stores not empty after deletion pass; will retry next launch")
            return
        }

        let settings = DurableUserSettings()
        settings.settingsSchemaVersion = 3
        settings.historyBackfillVersion = SyncCoordinator.currentHistoryBackfillVersion
        settings.canonicalTransactionDataVersion =
            PlaidTransactionSyncCoordinator.currentCanonicalTransactionDataVersion
        settings.primaryFinancialDataSource = .plaid
        settings.plaidTransactionsEnabled = true
        settings.freshStartVersion = currentVersion
        context.insert(settings)
        // One atomic commit: the wipe, the fresh defaults, and the completion
        // marker land together, or a failure rolls everything back to legacy
        // state for a clean retry on the next launch.
        guard context.safeSave(source: "freshStart.complete", notifyDataSync: false) else {
            context.rollback()
            logger.error("Clean start save failed; legacy state left intact for retry next launch")
            return
        }
        defaults.set(currentVersion, forKey: localCacheWipeVersionKey)
        logger.notice("Plaid-first clean start v\(currentVersion, privacy: .public) complete")
    }

    /// Wipes only the device-local cache store. Runs on devices where the
    /// durable clean start already completed (locally or on another device)
    /// but this device's caches predate it.
    private static func wipeLocalCacheIfNeeded(
        context: ModelContext,
        defaults: UserDefaults
    ) {
        guard defaults.integer(forKey: localCacheWipeVersionKey) < currentVersion else {
            return
        }
        guard deleteCacheStoreRows(context: context) else {
            context.rollback()
            logger.error("Local cache wipe aborted: deletion failed; will retry next launch")
            return
        }
        guard context.safeSave(source: "freshStart.localCacheWipe", notifyDataSync: false) else {
            context.rollback()
            return
        }
        defaults.set(currentVersion, forKey: localCacheWipeVersionKey)
        logger.notice("Legacy local caches wiped for clean start v\(currentVersion, privacy: .public)")
    }

    /// Deletes every row of every model type in both configurations. Returns
    /// false when any fetch fails, so an unverifiable wipe never proceeds to
    /// the completion marker.
    private static func deleteEveryRow(context: ModelContext) -> Bool {
        deleteCacheStoreRows(context: context)
            && deleteDurableStoreRows(context: context)
    }

    private static func deleteCacheStoreRows(context: ModelContext) -> Bool {
        // Cache store (local, re-fetchable).
        guard deleteAllRows(CachedBudget.self, context: context),
              deleteAllRows(CachedAccount.self, context: context),
              deleteAllRows(CachedTransaction.self, context: context),
              deleteAllRows(CachedScheduledTransaction.self, context: context),
              deleteAllRows(CachedCategory.self, context: context),
              deleteAllRows(CachedCategoryMonth.self, context: context),
              deleteAllRows(SyncCursor.self, context: context),
              deleteAllRows(CachedPlaidItem.self, context: context),
              deleteAllRows(CachedPlaidAccount.self, context: context),
              deleteAllRows(CachedPlaidSecurity.self, context: context),
              deleteAllRows(CachedPlaidHolding.self, context: context),
              deleteAllRows(CachedFinancialAccount.self, context: context),
              deleteAllRows(CachedFinancialTransaction.self, context: context),
              deleteAllRows(PlaidTransactionCursor.self, context: context),
              deleteAllRows(PlaidAccountCoverage.self, context: context),
              deleteAllRows(LegacyTransactionMatchRow.self, context: context)
        else { return false }
        return true
    }

    private static func deleteDurableStoreRows(context: ModelContext) -> Bool {
        // Durable store (CloudKit private DB). Deletions propagate to other
        // devices through SwiftData's CloudKit mirroring.
        guard deleteAllRows(DurableManualAsset.self, context: context),
              deleteAllRows(DurableManualAssetValue.self, context: context),
              deleteAllRows(DurableNetWorthSnapshot.self, context: context),
              deleteAllRows(DurableCardSettings.self, context: context),
              deleteAllRows(DurableUserSettings.self, context: context),
              deleteAllRows(DurableExcludedSpendCategory.self, context: context),
              deleteAllRows(DurableExcludedSpendTransaction.self, context: context),
              deleteAllRows(DurableIncludedClosedAccount.self, context: context),
              deleteAllRows(DurableProjectionCashAccountOverride.self, context: context),
              deleteAllRows(DurablePlaidAccountTreatment.self, context: context),
              deleteAllRows(DurablePlaidBalanceSnapshot.self, context: context),
              deleteAllRows(DurableCanonicalAccountBinding.self, context: context),
              deleteAllRows(DurableCanonicalPayee.self, context: context),
              deleteAllRows(DurablePayeeAlias.self, context: context),
              deleteAllRows(DurableCanonicalCategory.self, context: context),
              deleteAllRows(DurableCategoryGroup.self, context: context),
              deleteAllRows(DurableCanonicalTransactionDecision.self, context: context),
              deleteAllRows(DurableMerchantRule.self, context: context),
              deleteAllRows(DurableTransactionCategory.self, context: context),
              deleteAllRows(DurableTransactionOverride.self, context: context),
              deleteAllRows(DurableFixedCommitment.self, context: context),
              deleteAllRows(DurableBudgetCategoryAssignment.self, context: context),
              deleteAllRows(DurableIncomePatternOverride.self, context: context),
              deleteAllRows(DurableSinkingFund.self, context: context),
              deleteAllRows(DurableFundEvent.self, context: context)
        else { return false }
        return true
    }

    private static func deleteAllRows<T: PersistentModel>(
        _ type: T.Type, context: ModelContext
    ) -> Bool {
        guard let rows = try? context.fetch(FetchDescriptor<T>()) else {
            return false
        }
        for row in rows { context.delete(row) }
        return true
    }

    private static func bothStoresAreEmpty(context: ModelContext) -> Bool {
        isEmpty(CachedBudget.self, context: context)
            && isEmpty(CachedAccount.self, context: context)
            && isEmpty(CachedTransaction.self, context: context)
            && isEmpty(CachedScheduledTransaction.self, context: context)
            && isEmpty(CachedCategory.self, context: context)
            && isEmpty(CachedCategoryMonth.self, context: context)
            && isEmpty(SyncCursor.self, context: context)
            && isEmpty(CachedPlaidItem.self, context: context)
            && isEmpty(CachedPlaidAccount.self, context: context)
            && isEmpty(CachedPlaidSecurity.self, context: context)
            && isEmpty(CachedPlaidHolding.self, context: context)
            && isEmpty(CachedFinancialAccount.self, context: context)
            && isEmpty(CachedFinancialTransaction.self, context: context)
            && isEmpty(PlaidTransactionCursor.self, context: context)
            && isEmpty(PlaidAccountCoverage.self, context: context)
            && isEmpty(LegacyTransactionMatchRow.self, context: context)
            && isEmpty(DurableManualAsset.self, context: context)
            && isEmpty(DurableManualAssetValue.self, context: context)
            && isEmpty(DurableNetWorthSnapshot.self, context: context)
            && isEmpty(DurableCardSettings.self, context: context)
            && isEmpty(DurableUserSettings.self, context: context)
            && isEmpty(DurableExcludedSpendCategory.self, context: context)
            && isEmpty(DurableExcludedSpendTransaction.self, context: context)
            && isEmpty(DurableIncludedClosedAccount.self, context: context)
            && isEmpty(DurableProjectionCashAccountOverride.self, context: context)
            && isEmpty(DurablePlaidAccountTreatment.self, context: context)
            && isEmpty(DurablePlaidBalanceSnapshot.self, context: context)
            && isEmpty(DurableCanonicalAccountBinding.self, context: context)
            && isEmpty(DurableCanonicalPayee.self, context: context)
            && isEmpty(DurablePayeeAlias.self, context: context)
            && isEmpty(DurableCanonicalCategory.self, context: context)
            && isEmpty(DurableCategoryGroup.self, context: context)
            && isEmpty(DurableCanonicalTransactionDecision.self, context: context)
            && isEmpty(DurableMerchantRule.self, context: context)
            && isEmpty(DurableTransactionCategory.self, context: context)
            && isEmpty(DurableTransactionOverride.self, context: context)
            && isEmpty(DurableFixedCommitment.self, context: context)
            && isEmpty(DurableBudgetCategoryAssignment.self, context: context)
            && isEmpty(DurableIncomePatternOverride.self, context: context)
            && isEmpty(DurableSinkingFund.self, context: context)
            && isEmpty(DurableFundEvent.self, context: context)
    }

    private static func isEmpty<T: PersistentModel>(
        _ type: T.Type, context: ModelContext
    ) -> Bool {
        ((try? context.fetchCount(FetchDescriptor<T>())) ?? -1) == 0
    }

    // MARK: - Post-completion legacy purge

    /// Rows of these types are never created after the clean start, so any
    /// that reappear (CloudKit restore, an old device pushing before it
    /// updates) are legacy by definition and are deleted on sight.
    private static func purgeResurrectedLegacyRows(context: ModelContext) {
        var purged = 0
        purged += purgeAllRows(DurableFixedCommitment.self, context: context)
        purged += purgeAllRows(DurableBudgetCategoryAssignment.self, context: context)
        purged += purgeAllRows(DurableIncomePatternOverride.self, context: context)
        purged += purgeAllRows(DurableSinkingFund.self, context: context)
        purged += purgeAllRows(DurableFundEvent.self, context: context)

        // A settings row carrying an older fresh-start version is a
        // resurrected pre-wipe row, not a peer of the fresh singleton.
        let settingsRows =
            (try? context.fetch(FetchDescriptor<DurableUserSettings>())) ?? []
        for row in settingsRows where row.freshStartVersion < currentVersion {
            context.delete(row)
            purged += 1
        }

        guard purged > 0 else { return }
        logger.notice("Purged \(purged, privacy: .public) resurrected legacy rows")
        if !context.safeSave(source: "freshStart.purgeLegacy", notifyDataSync: false) {
            context.rollback()
        }
    }

    private static func purgeAllRows<T: PersistentModel>(
        _ type: T.Type, context: ModelContext
    ) -> Int {
        guard let rows = try? context.fetch(FetchDescriptor<T>()), !rows.isEmpty else {
            return 0
        }
        for row in rows { context.delete(row) }
        return rows.count
    }
}
