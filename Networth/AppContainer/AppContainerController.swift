import Foundation
import SwiftData
import Observation
import os
import NetworthCore

/// Top-level state container. `@Observable` + `@Environment`-injected so any view
/// can reach into protocol-based services without view-model boilerplate.
@MainActor
@Observable
public final class AppContainerController {
    public let secretStore: any SecretStore
    public let biometricGate: any BiometricGate
    public let ynabClient: any YNABClient
    public let plaidClient: any PlaidClient
    public let modelContainer: ModelContainer
    public let connectivity: ConnectivityMonitor
    public let snapshotScheduler: SnapshotScheduler
    public let syncCoordinator: SyncCoordinator
    public let plaidSyncCoordinator: PlaidSyncCoordinator
    public let plaidTransactionSyncCoordinator: PlaidTransactionSyncCoordinator
    public let ynabReferenceImportCoordinator: YNABReferenceImportCoordinator
    public let claudeDataSyncCoordinator: ClaudeDataSyncCoordinator
    public let ibrLoanStore: any IBRLoanStore
    public let ibrLoanHistorySettingsStore: any IBRLoanHistorySettingsStore

    public var unlocked: Bool = false
    public var bootstrapped: Bool = false
    public var hasYNABToken: Bool = false
    public var hasPlaidBackendToken: Bool = false
    public private(set) var plaidBackendBaseURL: URL?
    public var selectedBudgetId: String?
    public var lastPersistenceError: PersistenceFailure?
    public private(set) var linkedIBRLoanDocument: SharedIBRLoanDocument?
    public private(set) var linkedIBRLoanHistoryStartDate: Date?

    private let logger = Logger(subsystem: "com.bluelava.me.networth", category: "app-container")

    public init(
        secretStore: any SecretStore,
        biometricGate: any BiometricGate,
        ynabClient: any YNABClient,
        plaidClient: any PlaidClient = RecordedPlaidClient(),
        transactionInferenceProvider: any OnDeviceTransactionInferring = RecordedTransactionInferenceProvider(),
        modelContainer: ModelContainer,
        ibrLoanStore: any IBRLoanStore = AppGroupIBRLoanStore(),
        ibrLoanHistorySettingsStore: any IBRLoanHistorySettingsStore = InMemoryIBRLoanHistorySettingsStore()
    ) {
        self.secretStore = secretStore
        self.biometricGate = biometricGate
        self.ynabClient = ynabClient
        self.plaidClient = plaidClient
        self.modelContainer = modelContainer
        self.ibrLoanStore = ibrLoanStore
        self.ibrLoanHistorySettingsStore = ibrLoanHistorySettingsStore
        self.linkedIBRLoanHistoryStartDate = ibrLoanHistorySettingsStore.loadStartDate()
        self.connectivity = ConnectivityMonitor()
        let ctx = modelContainer.mainContext
        self.snapshotScheduler = SnapshotScheduler(mainContext: ctx)
        self.syncCoordinator = SyncCoordinator(client: ynabClient, mainContext: ctx)
        self.plaidSyncCoordinator = PlaidSyncCoordinator(client: plaidClient, mainContext: ctx)
        self.plaidTransactionSyncCoordinator = PlaidTransactionSyncCoordinator(
            client: plaidClient,
            inferenceProvider: transactionInferenceProvider,
            mainContext: ctx
        )
        self.ynabReferenceImportCoordinator = YNABReferenceImportCoordinator(
            client: ynabClient,
            mainContext: ctx
        )
        self.ynabReferenceImportCoordinator.plaidCoordinator =
            plaidTransactionSyncCoordinator
        self.claudeDataSyncCoordinator = ClaudeDataSyncCoordinator(
            client: plaidClient,
            mainContext: ctx
        )

        observePersistenceFailures()
    }

    /// Bootstrap reads the token from Keychain and prefills the YNAB client.
    /// Determines initial unlock state based on the user's Face ID setting and
    /// flips `bootstrapped = true` so ContentView can render the right state.
    public func bootstrap() async {
        refreshLinkedIBRLoan()
        let ynabToken: String?
        do { ynabToken = try secretStore.load(.ynabPersonalAccessToken) }
        catch {
            logger.error("YNAB secret load failed: \(error.localizedDescription, privacy: .public)")
            ynabToken = nil
        }
        await ynabClient.setToken(ynabToken)
        hasYNABToken = (ynabToken?.isEmpty == false)

        let plaidToken: String?
        do { plaidToken = try secretStore.load(.plaidBackendBearerToken) }
        catch {
            logger.error("Plaid backend secret load failed: \(error.localizedDescription, privacy: .public)")
            plaidToken = nil
        }
        plaidBackendBaseURL = Self.configuredPlaidBackendBaseURL
        await plaidClient.configure(
            baseURL: plaidBackendBaseURL,
            bearerToken: plaidToken
        )
        hasPlaidBackendToken = (plaidToken?.isEmpty == false)

        let ctx = modelContainer.mainContext
        // The versioned Plaid-first clean start must run before anything
        // observes model saves — the wipe must not trigger a Claude snapshot
        // upload of data that is being deleted.
        FreshStart.runIfNeeded(context: ctx)
        claudeDataSyncCoordinator.start()

        let descriptor = FetchDescriptor<DurableUserSettings>()
        let allSettingsRows = (try? ctx.fetch(descriptor)) ?? []
        let settings: DurableUserSettings
        if allSettingsRows.count == 1 {
            settings = allSettingsRows[0]
        } else if allSettingsRows.isEmpty {
            let s = DurableUserSettings()
            ctx.insert(s)
            ctx.safeSave(source: "bootstrap.settings")
            settings = s
        } else {
            settings = Self.dedupeSettingsRows(allSettingsRows, context: ctx)
        }
        selectedBudgetId = settings.selectedBudgetId
        plaidTransactionSyncCoordinator.runLocalMigrationsIfNeeded()

        // One-time migration: pre-default-flip installs had faceIDEnabled=false.
        // When biometric is available and we haven't migrated yet, enable it.
        if settings.settingsSchemaVersion < 2 {
            if biometricGate.isAvailable {
                settings.faceIDEnabled = true
            }
            settings.settingsSchemaVersion = 2
            ctx.safeSave(source: "bootstrap.migrate")
        }

        if settings.settingsSchemaVersion < 3 {
            settings.spendingLookbackDays = 365
            settings.settingsSchemaVersion = 3
            ctx.safeSave(source: "bootstrap.migrateProjectionLookback")
        }

        if settings.faceIDEnabled && biometricGate.isAvailable {
            // Honor the user's biometric grace window: if the app was active
            // recently and the grace minutes haven't elapsed, skip the lock.
            // Lets iOS evict the app from memory without forcing a Face ID
            // prompt on every cold launch immediately after backgrounding.
            let graceMinutes = max(0, settings.biometricGraceMinutes)
            if graceMinutes > 0 {
                let lastEpoch = UserDefaults.standard.double(forKey: Self.lastBackgroundedAtKey)
                if lastEpoch > 0 {
                    let elapsed = Date.now.timeIntervalSince(Date(timeIntervalSince1970: lastEpoch))
                    if elapsed < Double(graceMinutes) * 60 {
                        unlocked = true
                        bootstrapped = true
                        return
                    }
                }
            }
            unlocked = false
        } else {
            unlocked = true
        }
        bootstrapped = true
    }

    public static let lastBackgroundedAtKey = "networth.lastBackgroundedAt"

    /// Stamp the last-active wall-clock time so the next cold launch knows
    /// whether the biometric grace window applies. Called when the scene
    /// goes to background.
    public func markBackgrounded() {
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: Self.lastBackgroundedAtKey)
    }

    public func unlockWithBiometrics() async {
        do {
            unlocked = try await biometricGate.authenticate(reason: "Unlock BlueLava Networth")
        } catch {
            unlocked = false
        }
    }

    public func saveYNABToken(_ token: String) async throws {
        // Trim whitespace and newlines before storing. Pasted tokens from web
        // sources frequently include trailing newlines which corrupt the
        // Authorization header and produce 401s with no obvious cause.
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        try secretStore.save(trimmed, for: .ynabPersonalAccessToken)
        await ynabClient.setToken(trimmed)
        hasYNABToken = !trimmed.isEmpty
    }

    public func clearYNABToken() async throws {
        try secretStore.delete(.ynabPersonalAccessToken)
        await ynabClient.setToken(nil)
        hasYNABToken = false
    }

    public func savePlaidBackendToken(_ token: String) async throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        try secretStore.save(trimmed, for: .plaidBackendBearerToken)
        await plaidClient.configure(
            baseURL: plaidBackendBaseURL,
            bearerToken: trimmed
        )
        hasPlaidBackendToken = !trimmed.isEmpty
    }

    public func clearPlaidBackendToken() async throws {
        try secretStore.delete(.plaidBackendBearerToken)
        await plaidClient.configure(baseURL: plaidBackendBaseURL, bearerToken: nil)
        hasPlaidBackendToken = false
    }

    public func syncPlaidInvestments() async {
        guard hasPlaidBackendToken, plaidBackendBaseURL != nil else { return }
        if await plaidSyncCoordinator.syncAll() {
            recordPlaidBalanceSnapshot()
            recordDailySnapshot()
        }
    }

    public func createPlaidLinkToken() async throws -> String {
        try await plaidClient.createLinkToken(
            mode: .investments,
            itemId: nil
        ).linkToken
    }

    @discardableResult
    public func completePlaidLink(publicToken: String) async throws -> PlaidItemDTO {
        let result = try await plaidClient.exchangePublicToken(
            publicToken,
            products: ["investments"]
        )
        if await plaidSyncCoordinator.syncAll() {
            recordPlaidBalanceSnapshot()
            recordDailySnapshot()
        }
        return result.item
    }

    public func createPlaidTransactionLinkToken() async throws -> String {
        try await plaidClient.createLinkToken(
            mode: .transactions,
            itemId: nil
        ).linkToken
    }

    public func createPlaidTransactionUpdateLinkToken(itemId: String) async throws -> String {
        try await plaidClient.createLinkToken(
            mode: .updateTransactions,
            itemId: itemId
        ).linkToken
    }

    @discardableResult
    public func completePlaidTransactionLink(publicToken: String) async throws -> PlaidItemDTO {
        let result = try await plaidClient.exchangePublicToken(
            publicToken,
            products: ["transactions"]
        )
        enablePlaidTransactionsSetting()
        if await plaidTransactionSyncCoordinator.syncAll() {
            markPlaidSyncSuccess()
            recordDailySnapshot()
        }
        return result.item
    }

    public func completePlaidTransactionUpgrade(itemId: String) async throws {
        _ = try await plaidClient.enableTransactions(itemId: itemId)
        enablePlaidTransactionsSetting()
        if await plaidTransactionSyncCoordinator.syncAll() {
            markPlaidSyncSuccess()
            recordDailySnapshot()
        }
    }

    public func syncPlaidTransactions() async {
        guard hasPlaidBackendToken, plaidBackendBaseURL != nil else { return }
        if await plaidTransactionSyncCoordinator.syncAll() {
            markPlaidSyncSuccess()
            recordDailySnapshot()
        }
    }

    public func mapPlaidAccount(_ plaidAccountId: String, toYNABAccount ynabAccountId: String?) {
        plaidTransactionSyncCoordinator.mapAccount(
            plaidAccountId: plaidAccountId,
            toYNABAccountId: ynabAccountId
        )
    }

    public func reviewPlaidMerchantNames(
        ids: [String],
        displayName: String
    ) {
        plaidTransactionSyncCoordinator.reviewMerchantNames(
            ids: ids,
            displayName: displayName
        )
    }

    @discardableResult
    public func confirmPlaidTransaction(
        id: String,
        displayName: String,
        payeeCanonicalId: String? = nil,
        categoryName: String?,
        treatment: ForecastTreatment,
        categoryCanonicalId: String? = nil
    ) -> Bool {
        plaidTransactionSyncCoordinator.confirmTransaction(
            id: id,
            displayName: displayName,
            payeeCanonicalId: payeeCanonicalId,
            categoryName: categoryName,
            treatment: treatment,
            categoryCanonicalId: categoryCanonicalId
        )
    }

    @discardableResult
    public func reviewPlaidSplitTransaction(
        id: String,
        displayName: String,
        payeeCanonicalId: String? = nil,
        subtransactions: [SubTransactionSummary]
    ) -> Bool {
        plaidTransactionSyncCoordinator.reviewSplitTransaction(
            id: id,
            displayName: displayName,
            payeeCanonicalId: payeeCanonicalId,
            subtransactions: subtransactions
        )
    }

    @discardableResult
    public func createCanonicalPayee(name: String) -> Bool {
        plaidTransactionSyncCoordinator.createCanonicalPayee(name: name)
    }

    public func createCanonicalPayeeReturningId(
        name: String
    ) -> String? {
        plaidTransactionSyncCoordinator.createCanonicalPayeeReturningId(
            name: name
        )
    }

    @discardableResult
    public func updateCanonicalPayee(
        canonicalId: String,
        name: String,
        archived: Bool
    ) -> Bool {
        plaidTransactionSyncCoordinator.updateCanonicalPayee(
            canonicalId: canonicalId,
            name: name,
            archived: archived
        )
    }

    @discardableResult
    public func removeCanonicalAlias(aliasId: UUID) -> Bool {
        plaidTransactionSyncCoordinator.removeCanonicalAlias(
            aliasId: aliasId
        )
    }

    @discardableResult
    public func reassignCanonicalAlias(
        aliasId: UUID,
        to payeeCanonicalId: String
    ) -> Bool {
        plaidTransactionSyncCoordinator.reassignCanonicalAlias(
            aliasId: aliasId,
            to: payeeCanonicalId
        )
    }

    @discardableResult
    public func mergeCanonicalPayees(
        sourceCanonicalId: String,
        destinationCanonicalId: String
    ) -> Bool {
        plaidTransactionSyncCoordinator.mergeCanonicalPayees(
            sourceCanonicalId: sourceCanonicalId,
            destinationCanonicalId: destinationCanonicalId
        )
    }

    @discardableResult
    public func createCanonicalCategory(
        name: String,
        groupName: String
    ) -> Bool {
        plaidTransactionSyncCoordinator.createCanonicalCategory(
            name: name,
            groupName: groupName
        )
    }

    public func createCanonicalCategoryReturningId(
        name: String,
        groupName: String
    ) -> String? {
        plaidTransactionSyncCoordinator
            .createCanonicalCategoryReturningId(
                name: name,
                groupName: groupName
            )
    }

    @discardableResult
    public func updateCanonicalCategory(
        canonicalId: String,
        name: String,
        groupName: String,
        hidden: Bool
    ) -> Bool {
        plaidTransactionSyncCoordinator.updateCanonicalCategory(
            canonicalId: canonicalId,
            name: name,
            groupName: groupName,
            hidden: hidden
        )
    }

    public func setClaudeFallbackEnabled(_ enabled: Bool) {
        let descriptor = FetchDescriptor<DurableUserSettings>()
        guard let settings = try? modelContainer.mainContext.fetch(descriptor).first else {
            return
        }
        settings.claudeFallbackEnabled = enabled
        settings.claudeFallbackConsentAt = enabled ? .now : nil
        if !modelContainer.mainContext.safeSave(source: "settings.claudeFallback") {
            modelContainer.mainContext.rollback()
        }
    }

    public func setClaudeDataSyncEnabled(_ enabled: Bool) async throws {
        try await claudeDataSyncCoordinator.setEnabled(enabled)
    }

    public func syncClaudeDataNow() async {
        await claudeDataSyncCoordinator.runOnce()
    }

    public func generateClaudeConnectCode() async throws
        -> ClaudeConnectCodeResponseDTO {
        try await claudeDataSyncCoordinator.generateConnectCode()
    }

    public func makePlaidPrimary() async throws {
        let context = modelContainer.mainContext
        let bindings = (try? context.fetch(
            FetchDescriptor<DurableCanonicalAccountBinding>()
        )) ?? []
        let accounts = (try? context.fetch(
            FetchDescriptor<CachedFinancialAccount>(
                predicate: #Predicate { !$0.deleted }
            )
        )) ?? []
        let activePlaidAccountIDs = Set(accounts.map(\.externalId))
        let activeBindings = bindings.filter {
            activePlaidAccountIDs.contains($0.plaidAccountId)
        }
        var pendingDescriptor = FetchDescriptor<CachedFinancialTransaction>(
            predicate: #Predicate {
                $0.requiresReview && !$0.deleted
            }
        )
        pendingDescriptor.fetchLimit = 1
        var pendingNameDescriptor = FetchDescriptor<CachedFinancialTransaction>(
            predicate: #Predicate {
                $0.requiresNameReview && !$0.deleted
            }
        )
        pendingNameDescriptor.fetchLimit = 1
        guard let pendingTransactions = try? context.fetch(pendingDescriptor) else {
            throw PlaidCutoverError.reconciliationIncomplete
        }
        guard let pendingNames = try? context.fetch(pendingNameDescriptor) else {
            throw PlaidCutoverError.reconciliationIncomplete
        }
        let hasPendingTransactions = !pendingTransactions.isEmpty
        let hasPendingNames = !pendingNames.isEmpty
        var payeeDescriptor =
            FetchDescriptor<DurableCanonicalPayee>(
                predicate: #Predicate { !$0.deletedAtSource }
            )
        payeeDescriptor.fetchLimit = 1
        var categoryDescriptor =
            FetchDescriptor<DurableCanonicalCategory>(
                predicate: #Predicate { !$0.deletedAtSource }
            )
        categoryDescriptor.fetchLimit = 1
        let hasCanonicalPayees =
            ((try? context.fetch(payeeDescriptor).isEmpty) == false)
        let hasCanonicalCategories =
            ((try? context.fetch(categoryDescriptor).isEmpty) == false)
        let cursors = (try? context.fetch(FetchDescriptor<PlaidTransactionCursor>())) ?? []
        guard !accounts.isEmpty,
              hasCanonicalPayees,
              hasCanonicalCategories,
              !hasPendingTransactions,
              !hasPendingNames,
              !cursors.isEmpty,
              cursors.allSatisfy(\.historicalImportComplete),
              activeBindings.allSatisfy(\.reviewed) else {
            throw PlaidCutoverError.reconciliationIncomplete
        }
        guard let settings = try? context.fetch(
            FetchDescriptor<DurableUserSettings>()
        ).first else {
            throw PlaidCutoverError.settingsUnavailable
        }
        settings.primaryFinancialDataSource = .plaid
        settings.plaidPrimaryCutoverAt = .now
        guard context.safeSave(source: "settings.plaidCutover") else {
            context.rollback()
            throw PlaidCutoverError.saveFailed
        }
        do {
            try await clearYNABToken()
        } catch {
            settings.primaryFinancialDataSource = .ynab
            settings.plaidPrimaryCutoverAt = nil
            _ = context.safeSave(source: "settings.plaidCutoverRollback")
            throw PlaidCutoverError.tokenRemovalFailed
        }
        recordDailySnapshot()
    }

    public func removePlaidItem(id: String) async throws {
        let context = modelContainer.mainContext
        let settings = try? context.fetch(FetchDescriptor<DurableUserSettings>()).first
        let items = (try? context.fetch(FetchDescriptor<CachedPlaidItem>())) ?? []
        let targetIsTransactions = items.first(where: { $0.id == id })?
            .products.contains("transactions") == true
        let remainingTransactions = items.contains {
            $0.id != id && $0.products.contains("transactions")
        }
        if settings?.primaryFinancialDataSource == .plaid,
           targetIsTransactions,
           !remainingTransactions {
            throw PlaidRemovalError.lastPrimaryConnection
        }
        try await plaidClient.removeItem(id: id)
        try removeLocalPlaidItem(id: id)
        // Refresh both Plaid paths before recording, so the post-removal
        // snapshot reflects the final account set; a fully successful pass
        // also stamps the sync markers like any other sync.
        var allSucceeded = true
        if await plaidSyncCoordinator.syncAll() {
            recordPlaidBalanceSnapshot()
        } else {
            allSucceeded = false
        }
        if await plaidTransactionSyncCoordinator.syncAll() == false {
            allSucceeded = false
        }
        if allSucceeded {
            markPlaidSyncSuccess()
        }
        recordDailySnapshot()
    }

    public func recordPlaidBalanceSnapshot() {
        snapshotScheduler.recordPlaidBalancesIfNeeded()
    }

    /// Mutation-driven recording (sync completion, manual-asset edits):
    /// never throttled — a data change must always be able to update today's
    /// snapshot. The scheduler itself skips the save when nothing changed.
    public func recordDailySnapshot() {
        if snapshotScheduler.recordIfNeeded() != nil {
            lastDailySnapshotAt = .now
        }
    }

    /// Startup/foreground path only: bootstrap and scene activation both
    /// request a snapshot within the same breath on launch; one computation
    /// is enough. The stamp is only set by a successful recording, so a
    /// no-data launch can never block the first real snapshot.
    public func recordDailySnapshotOnActivation() {
        if let last = lastDailySnapshotAt,
           Date.now.timeIntervalSince(last) < 60 {
            return
        }
        recordDailySnapshot()
    }

    @ObservationIgnored private var lastDailySnapshotAt: Date?

    /// Refreshes IBR's opt-in, local-only App Group summary. The document is
    /// kept in memory and never copied into Networth's CloudKit-backed models.
    public func refreshLinkedIBRLoan() {
        do {
            linkedIBRLoanDocument = try ibrLoanStore.load()
        } catch {
            linkedIBRLoanDocument = nil
            logger.error("IBR loan summary could not be read: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func setLinkedIBRLoanHistoryStartDate(_ date: Date?) {
        let normalized = date.map { Calendar.current.startOfDay(for: $0) }
        linkedIBRLoanHistoryStartDate = normalized
        ibrLoanHistorySettingsStore.saveStartDate(normalized)
    }

    public func defaultLinkedIBRLoanHistoryStartDate(
        calendar: Calendar = .current
    ) -> Date? {
        if let budgetId = selectedBudgetId {
            var transactionDescriptor = FetchDescriptor<CachedTransaction>(
                predicate: #Predicate {
                    $0.budgetId == budgetId && $0.deleted == false
                },
                sortBy: [SortDescriptor(\CachedTransaction.date, order: .forward)]
            )
            transactionDescriptor.fetchLimit = 1
            if let firstTransaction = (try? modelContainer.mainContext.fetch(transactionDescriptor))?.first {
                return calendar.startOfDay(for: firstTransaction.date)
            }
        }

        var snapshotDescriptor = FetchDescriptor<DurableNetWorthSnapshot>(
            sortBy: [SortDescriptor(\DurableNetWorthSnapshot.date, order: .forward)]
        )
        snapshotDescriptor.fetchLimit = 1
        guard let firstSnapshot = (try? modelContainer.mainContext.fetch(snapshotDescriptor))?.first else {
            return nil
        }
        return calendar.startOfDay(for: firstSnapshot.date)
    }

    public func effectiveLinkedIBRLoanHistoryStartDate(
        calendar: Calendar = .current
    ) -> Date? {
        linkedIBRLoanHistoryStartDate
            ?? defaultLinkedIBRLoanHistoryStartDate(calendar: calendar)
    }

    public func linkedIBRLoanBalance(
        on date: Date,
        calendar: Calendar = .current
    ) -> Money {
        linkedIBRLoanDocument?.balance(
            on: date,
            calendar: calendar,
            historyStartDate: effectiveLinkedIBRLoanHistoryStartDate(calendar: calendar)
        ) ?? .zero
    }

    /// CloudKit can duplicate the settings singleton when two devices race
    /// their first write (or a restore re-imports it). Keep the most
    /// progressed row, merge forward-only progress markers from the others,
    /// and delete the duplicates. Idempotent: runs on every bootstrap.
    private static func dedupeSettingsRows(
        _ rows: [DurableUserSettings],
        context: ModelContext
    ) -> DurableUserSettings {
        func score(_ row: DurableUserSettings) -> Int {
            var value = row.settingsSchemaVersion
            if row.budgetSetupCompletedAt != nil { value += 8 }
            if row.discretionaryCategoryIdsData != nil { value += 2 }
            if row.historyBackfillVersion > 0 { value += 2 }
            if row.canonicalTransactionDataVersion > 0 { value += 2 }
            if row.primaryFinancialDataSource == .plaid { value += 2 }
            if row.plaidTransactionsEnabled { value += 1 }
            if row.hasSeenTutorial { value += 1 }
            if row.lastSyncedAt != nil { value += 1 }
            return value
        }
        let ranked = rows.sorted { score($0) > score($1) }
        let survivor = ranked[0]
        for other in ranked.dropFirst() {
            if survivor.budgetSetupCompletedAt == nil {
                survivor.budgetSetupCompletedAt = other.budgetSetupCompletedAt
            }
            if survivor.budgetSurplusTargetMilliunits == 1_000_000,
               other.budgetSurplusTargetMilliunits != 1_000_000 {
                survivor.budgetSurplusTargetMilliunits =
                    other.budgetSurplusTargetMilliunits
            }
            if other.hasSeenTutorial { survivor.hasSeenTutorial = true }
            if survivor.discretionaryCategoryIdsData == nil {
                survivor.discretionaryCategoryIdsData =
                    other.discretionaryCategoryIdsData
            }
            if survivor.discretionaryMonthlyTargetMilliunits == 0 {
                survivor.discretionaryMonthlyTargetMilliunits =
                    other.discretionaryMonthlyTargetMilliunits
            }
            if survivor.selectedBudgetId == nil {
                survivor.selectedBudgetId = other.selectedBudgetId
            }
            if survivor.chartStartDate == nil {
                survivor.chartStartDate = other.chartStartDate
            }
            if other.plaidTransactionsEnabled {
                survivor.plaidTransactionsEnabled = true
            }
            if survivor.plaidPrimaryCutoverAt == nil,
               let cutover = other.plaidPrimaryCutoverAt {
                survivor.plaidPrimaryCutoverAt = cutover
                survivor.primaryFinancialDataSourceRaw =
                    other.primaryFinancialDataSourceRaw
            }
            if other.claudeFallbackEnabled {
                survivor.claudeFallbackEnabled = true
                survivor.claudeFallbackConsentAt =
                    survivor.claudeFallbackConsentAt
                        ?? other.claudeFallbackConsentAt
            }
            if other.claudeDataSyncEnabled {
                survivor.claudeDataSyncEnabled = true
                survivor.claudeDataSyncConsentAt =
                    survivor.claudeDataSyncConsentAt
                        ?? other.claudeDataSyncConsentAt
            }
            survivor.settingsSchemaVersion = max(
                survivor.settingsSchemaVersion, other.settingsSchemaVersion
            )
            survivor.historyBackfillVersion = max(
                survivor.historyBackfillVersion, other.historyBackfillVersion
            )
            survivor.canonicalTransactionDataVersion = max(
                survivor.canonicalTransactionDataVersion,
                other.canonicalTransactionDataVersion
            )
            survivor.freshStartVersion = max(
                survivor.freshStartVersion, other.freshStartVersion
            )
            if let firstPlaidSync = other.firstPlaidSyncCompletedAt,
               (survivor.firstPlaidSyncCompletedAt ?? .distantFuture) > firstPlaidSync {
                // Keep the earliest stamp: it anchors day one of the new
                // Net Worth history.
                survivor.firstPlaidSyncCompletedAt = firstPlaidSync
            }
            if let synced = other.lastSyncedAt,
               (survivor.lastSyncedAt ?? .distantPast) < synced {
                survivor.lastSyncedAt = synced
            }
            if let backfill = other.lastBackfillRunAt,
               (survivor.lastBackfillRunAt ?? .distantPast) < backfill {
                survivor.lastBackfillRunAt = backfill
            }
            context.delete(other)
        }
        context.safeSave(source: "bootstrap.dedupeSettings")
        return survivor
    }

    /// Normal launch and sync never contact YNAB. Plaid is the authoritative
    /// external source; the retained YNAB token exists solely for explicit
    /// user-initiated reference imports.
    public func syncNow() async {
        // Never overlap a running YNAB reference import: both mutate the
        // shared main context and each other's saves/rollbacks would
        // interleave.
        if case .running = ynabReferenceImportCoordinator.phase { return }
        if hasPlaidBackendToken, plaidBackendBaseURL != nil {
            var allSucceeded = true
            if await plaidSyncCoordinator.syncAll() {
                recordPlaidBalanceSnapshot()
            } else {
                allSucceeded = false
            }
            let settings = try? modelContainer.mainContext.fetch(
                FetchDescriptor<DurableUserSettings>()
            ).first
            if settings?.plaidTransactionsEnabled == true,
               await plaidTransactionSyncCoordinator.syncAll() == false {
                allSucceeded = false
            }
            // Stamp only a fully successful pass: a partial success must not
            // suppress the staleness retry or open the first-snapshot gate
            // while the authoritative banking data is stale.
            if allSucceeded {
                markPlaidSyncSuccess()
            }
        }
        recordDailySnapshot()
        let descriptor = FetchDescriptor<DurableUserSettings>()
        if let settings = try? modelContainer.mainContext.fetch(descriptor).first {
            selectedBudgetId = settings.selectedBudgetId
        }
    }

    /// Approves a reviewed cluster of historical transactions in one save.
    /// Returns the number approved (0 when validation fails).
    @discardableResult
    public func approvePlaidTransactionCluster(
        ids: [String],
        displayName: String,
        payeeCanonicalId: String?,
        categoryName: String?,
        categoryCanonicalId: String?,
        treatment: ForecastTreatment
    ) -> Int {
        plaidTransactionSyncCoordinator.approveTransactions(
            ids: ids,
            displayName: displayName,
            payeeCanonicalId: payeeCanonicalId,
            categoryName: categoryName,
            categoryCanonicalId: categoryCanonicalId,
            treatment: treatment
        )
    }

    /// Explicit, user-initiated YNAB reference import — the only path that
    /// may use the retained YNAB token after the clean start.
    @discardableResult
    public func buildYNABReference() async -> Bool {
        guard hasYNABToken else { return false }
        return await ynabReferenceImportCoordinator.buildReference()
    }

    /// Stamps the sync markers a successful Plaid sync maintains: the
    /// staleness throttle, and the one-time `firstPlaidSyncCompletedAt` that
    /// gates the first Net Worth snapshot after the clean start.
    private func markPlaidSyncSuccess(now: Date = .now) {
        let ctx = modelContainer.mainContext
        guard let settings = try? ctx.fetch(
            FetchDescriptor<DurableUserSettings>()
        ).first else { return }
        settings.lastSyncedAt = now
        if settings.firstPlaidSyncCompletedAt == nil {
            settings.firstPlaidSyncCompletedAt = now
        }
        ctx.safeSave(source: "syncNow.markPlaidSuccess", notifyDataSync: false)
    }

    /// Refreshes the Plaid caches only when the current successful sync is
    /// older than the requested age, keeping foreground refreshes cheap.
    public func refreshIfStale(now: Date = .now, maxAge: TimeInterval = 15 * 60) async {
        guard unlocked, hasPlaidBackendToken else { return }
        if case .syncing = plaidTransactionSyncCoordinator.phase { return }
        let descriptor = FetchDescriptor<DurableUserSettings>()
        let lastSync = (try? modelContainer.mainContext.fetch(descriptor).first)?.lastSyncedAt
        if let lastSync, now.timeIntervalSince(lastSync) < maxAge { return }
        await syncNow()
    }

    /// Full reset of the re-fetchable Plaid state: wipe the transaction
    /// cursors (and any legacy YNAB delta cursors) so the next sync re-imports
    /// every item's full history from the Worker. Never touches
    /// `DurableNetWorthSnapshot` rows — after the clean start, Net Worth
    /// history is never reconstructed, so snapshots are irreplaceable.
    public func forceFullResync() async {
        // Block the wipe while a sync or reference import is running — we
        // don't want to delete cursors out from under one, or commit the
        // other's partial writes with our save.
        if case .syncing = plaidTransactionSyncCoordinator.phase { return }
        if case .running = ynabReferenceImportCoordinator.phase { return }
        let ctx = modelContainer.mainContext
        if let cursors = try? ctx.fetch(FetchDescriptor<PlaidTransactionCursor>()) {
            for cursor in cursors { ctx.delete(cursor) }
        }
        if let cursors = try? ctx.fetch(FetchDescriptor<SyncCursor>()) {
            for cursor in cursors { ctx.delete(cursor) }
        }
        // Coverage must rebuild from the full re-import: widen-only updates
        // can never narrow a window that a corrected upstream history shrank.
        if let coverage = try? ctx.fetch(FetchDescriptor<PlaidAccountCoverage>()) {
            for row in coverage { ctx.delete(row) }
        }
        guard ctx.safeSave(source: "forceFullResync.wipeCursors") else {
            // Save failed. Roll back the in-memory deletes so we don't leave
            // the user with a phantom-wiped store, and skip the follow-up
            // sync — the persistence-failure alert will surface via the
            // safeSave notification.
            ctx.rollback()
            return
        }
        await syncNow()
    }

    // MARK: - Factories

    private static var configuredPlaidBackendBaseURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "PlaidBackendBaseURL") as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    /// Production wiring.
    public static func makeProduction() throws -> AppContainerController {
        let secretStore = KeychainSecretStore()
        let biometric = LocalAuthBiometricGate()
        let client = LiveYNABClient()
        let plaidClient = LivePlaidClient()
        let container = try ModelContainerFactory.makeContainer()
        return AppContainerController(
            secretStore: secretStore,
            biometricGate: biometric,
            ynabClient: client,
            plaidClient: plaidClient,
            transactionInferenceProvider: AppleTransactionInferenceProvider(),
            modelContainer: container,
            ibrLoanStore: AppGroupIBRLoanStore(),
            ibrLoanHistorySettingsStore: UserDefaultsIBRLoanHistorySettingsStore()
        )
    }

    /// Preview / test wiring — in-memory only, scriptable fakes.
    public static func makePreview() -> AppContainerController {
        let container = try! ModelContainerFactory.makeContainer(inMemory: true)
        return AppContainerController(
            secretStore: InMemorySecretStore(),
            biometricGate: ScriptableBiometricGate(),
            ynabClient: RecordedYNABClient(),
            plaidClient: RecordedPlaidClient(),
            transactionInferenceProvider: RecordedTransactionInferenceProvider(),
            modelContainer: container,
            ibrLoanStore: InMemoryIBRLoanStore(),
            ibrLoanHistorySettingsStore: InMemoryIBRLoanHistorySettingsStore()
        )
    }

    // MARK: - Failure observation

    private func observePersistenceFailures() {
        NotificationCenter.default.addObserver(
            forName: .networthPersistenceFailure,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let payload = note.userInfo?["payload"] as? PersistenceFailure else { return }
            Task { @MainActor [weak self] in self?.lastPersistenceError = payload }
        }
    }

    private func enablePlaidTransactionsSetting() {
        let descriptor = FetchDescriptor<DurableUserSettings>()
        guard let settings = try? modelContainer.mainContext.fetch(descriptor).first else {
            return
        }
        settings.plaidTransactionsEnabled = true
        if !modelContainer.mainContext.safeSave(source: "settings.enablePlaidTransactions") {
            modelContainer.mainContext.rollback()
        }
    }

    private func removeLocalPlaidItem(id: String) throws {
        let context = modelContainer.mainContext
        let plaidAccounts = ((try? context.fetch(
            FetchDescriptor<CachedPlaidAccount>()
        )) ?? []).filter { $0.itemId == id }
        let plaidAccountIDs = Set(plaidAccounts.map(\.id))
        let financialAccounts = ((try? context.fetch(
            FetchDescriptor<CachedFinancialAccount>()
        )) ?? []).filter { $0.itemId == id }
        let canonicalIDs = Set(financialAccounts.map(\.canonicalAccountId))
        let financialTransactions = ((try? context.fetch(
            FetchDescriptor<CachedFinancialTransaction>()
        )) ?? []).filter { canonicalIDs.contains($0.canonicalAccountId) }
        let transactionIDs = Set(financialTransactions.map(\.id))

        ((try? context.fetch(FetchDescriptor<CachedPlaidItem>())) ?? [])
            .filter { $0.id == id }
            .forEach(context.delete)
        ((try? context.fetch(FetchDescriptor<CachedPlaidHolding>())) ?? [])
            .filter { plaidAccountIDs.contains($0.accountId) }
            .forEach(context.delete)
        plaidAccounts.forEach(context.delete)
        financialTransactions.forEach(context.delete)
        financialAccounts.forEach(context.delete)
        ((try? context.fetch(FetchDescriptor<PlaidTransactionCursor>())) ?? [])
            .filter { $0.itemId == id }
            .forEach(context.delete)
        // Coverage for a disconnected Item must not linger: orphan rows could
        // later scope a YNAB reference import to a dead account.
        ((try? context.fetch(FetchDescriptor<PlaidAccountCoverage>())) ?? [])
            .filter { $0.itemId == id }
            .forEach(context.delete)
        ((try? context.fetch(FetchDescriptor<LegacyTransactionMatchRow>())) ?? [])
            .filter { transactionIDs.contains($0.plaidTransactionId) }
            .forEach(context.delete)
        ((try? context.fetch(FetchDescriptor<DurableCanonicalAccountBinding>())) ?? [])
            .filter { $0.itemId == id }
            .forEach(context.delete)
        ((try? context.fetch(FetchDescriptor<DurablePlaidAccountTreatment>())) ?? [])
            .filter { plaidAccountIDs.contains($0.plaidAccountId) }
            .forEach(context.delete)

        let remainingTransactionItems = ((try? context.fetch(
            FetchDescriptor<CachedPlaidItem>()
        )) ?? []).contains { $0.products.contains("transactions") }
        if !remainingTransactionItems,
           let settings = try? context.fetch(FetchDescriptor<DurableUserSettings>()).first {
            settings.plaidTransactionsEnabled = false
        }
        if !context.safeSave(source: "plaid.removeLocalItem") {
            context.rollback()
            throw PlaidRemovalError.localCleanupFailed
        }
    }
}

public enum PlaidCutoverError: LocalizedError {
    case reconciliationIncomplete
    case settingsUnavailable
    case saveFailed
    case tokenRemovalFailed

    public var errorDescription: String? {
        switch self {
        case .reconciliationIncomplete:
            "Complete the historical import, account mapping, and transaction review first."
        case .settingsUnavailable:
            "Networth settings are unavailable."
        case .saveFailed:
            "The Plaid cutover could not be saved."
        case .tokenRemovalFailed:
            "The YNAB token could not be removed, so YNAB remains primary."
        }
    }
}

public enum PlaidRemovalError: LocalizedError {
    case lastPrimaryConnection
    case localCleanupFailed

    public var errorDescription: String? {
        switch self {
        case .lastPrimaryConnection:
            "Switch to another banking source before removing the last Plaid Transactions connection."
        case .localCleanupFailed:
            "Plaid disconnected, but local cleanup did not finish. Try removing the connection again."
        }
    }
}
