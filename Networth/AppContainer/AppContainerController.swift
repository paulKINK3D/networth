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

        let descriptor = FetchDescriptor<DurableUserSettings>()
        let ctx = modelContainer.mainContext
        let settings = (try? ctx.fetch(descriptor).first) ?? {
            let s = DurableUserSettings()
            ctx.insert(s)
            ctx.safeSave(source: "bootstrap.settings")
            return s
        }()
        selectedBudgetId = settings.selectedBudgetId

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
        try await plaidClient.createLinkToken().linkToken
    }

    @discardableResult
    public func completePlaidLink(publicToken: String) async throws -> PlaidItemDTO {
        let result = try await plaidClient.exchangePublicToken(publicToken)
        if await plaidSyncCoordinator.syncAll() {
            recordPlaidBalanceSnapshot()
            recordDailySnapshot()
        }
        return result.item
    }

    public func removePlaidItem(id: String) async throws {
        try await plaidClient.removeItem(id: id)
        if await plaidSyncCoordinator.syncAll() {
            recordPlaidBalanceSnapshot()
            recordDailySnapshot()
        }
    }

    public func recordPlaidBalanceSnapshot() {
        snapshotScheduler.recordPlaidBalancesIfNeeded()
    }

    public func recordDailySnapshot() {
        snapshotScheduler.recordIfNeeded()
    }

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

    public func syncNow() async {
        await syncCoordinator.syncAll(budgetId: selectedBudgetId)
        if hasPlaidBackendToken, plaidBackendBaseURL != nil {
            if await plaidSyncCoordinator.syncAll() {
                recordPlaidBalanceSnapshot()
            }
        }
        recordDailySnapshot()
        let descriptor = FetchDescriptor<DurableUserSettings>()
        if let settings = try? modelContainer.mainContext.fetch(descriptor).first {
            selectedBudgetId = settings.selectedBudgetId
        }
    }

    /// Refreshes the local YNAB cache only when the current successful sync is
    /// older than the requested age. Keeps foreground refreshes comfortably
    /// below YNAB's rate limit while making the projection useful on open.
    public func refreshIfStale(now: Date = .now, maxAge: TimeInterval = 15 * 60) async {
        guard unlocked, hasYNABToken else { return }
        if case .syncing = syncCoordinator.phase { return }
        let descriptor = FetchDescriptor<DurableUserSettings>()
        let lastSync = (try? modelContainer.mainContext.fetch(descriptor).first)?.lastSyncedAt
        if let lastSync, now.timeIntervalSince(lastSync) < maxAge { return }
        await syncNow()
    }

    /// Full reset: wipe all YNAB delta cursors, the historical-backfill marker,
    /// AND every `DurableNetWorthSnapshot` row in the CloudKit-backed store,
    /// then run a full sync. The snapshot purge is what makes the chart
    /// consistent with the current account set — old `.live` rows from
    /// previous sessions (when more accounts were open) would otherwise
    /// shadow the freshly reconstructed history via the dedupe pass.
    ///
    /// Rebuilds the historical chart snapshots from cached YNAB data + current
    /// manual-asset values. Does NOT hit the YNAB API — meant for fast local
    /// refreshes when manual assets change. Existing `.live` rows are
    /// preserved; only `.backfill` rows are regenerated.
    public func rebuildChartHistory() async {
        if case .syncing = syncCoordinator.phase { return }
        guard let budgetId = selectedBudgetId else { return }
        let ctx = modelContainer.mainContext
        if let settings = try? ctx.fetch(FetchDescriptor<DurableUserSettings>()).first {
            settings.historyBackfillVersion = 0
        }
        ctx.safeSave(source: "rebuildChartHistory.resetMarker")
        _ = syncCoordinator.runHistoryBackfillIfNeeded(budgetId: budgetId)
    }

    /// Preserves manual assets, their value history, user settings, and card
    /// settings. Only chart snapshots are destroyed.
    public func forceFullResync() async {
        // Block the wipe if a sync is already running — we don't want to
        // delete snapshots and cursors out from under it. The user should
        // wait for the active sync to finish before resyncing from scratch.
        if case .syncing = syncCoordinator.phase { return }
        let ctx = modelContainer.mainContext
        let cursorDescriptor = FetchDescriptor<SyncCursor>()
        if let cursors = try? ctx.fetch(cursorDescriptor) {
            for cursor in cursors { ctx.delete(cursor) }
        }
        let snapshotDescriptor = FetchDescriptor<DurableNetWorthSnapshot>()
        if let snapshots = try? ctx.fetch(snapshotDescriptor) {
            for snap in snapshots { ctx.delete(snap) }
        }
        let settingsDescriptor = FetchDescriptor<DurableUserSettings>()
        if let settings = try? ctx.fetch(settingsDescriptor).first {
            // Reset to the "never run" sentinel. The guard in
            // `runHistoryBackfillIfNeeded` compares against
            // `SyncCoordinator.currentHistoryBackfillVersion`, so any value
            // less than the current version triggers a re-run on the next sync.
            settings.historyBackfillVersion = 0
        }
        guard ctx.safeSave(source: "forceFullResync.wipeAll") else {
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
}
