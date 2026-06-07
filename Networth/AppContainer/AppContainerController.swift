import Foundation
import SwiftData
import Observation
import os

/// Top-level state container. `@Observable` + `@Environment`-injected so any view
/// can reach into protocol-based services without view-model boilerplate.
@MainActor
@Observable
public final class AppContainerController {
    public let secretStore: any SecretStore
    public let biometricGate: any BiometricGate
    public let ynabClient: any YNABClient
    public let modelContainer: ModelContainer
    public let connectivity: ConnectivityMonitor
    public let snapshotScheduler: SnapshotScheduler
    public let syncCoordinator: SyncCoordinator

    public var unlocked: Bool = false
    public var bootstrapped: Bool = false
    public var hasYNABToken: Bool = false
    public var selectedBudgetId: String?
    public var lastPersistenceError: PersistenceFailure?

    private let logger = Logger(subsystem: "com.bluelava.me.networth", category: "app-container")

    public init(
        secretStore: any SecretStore,
        biometricGate: any BiometricGate,
        ynabClient: any YNABClient,
        modelContainer: ModelContainer
    ) {
        self.secretStore = secretStore
        self.biometricGate = biometricGate
        self.ynabClient = ynabClient
        self.modelContainer = modelContainer
        self.connectivity = ConnectivityMonitor()
        let ctx = modelContainer.mainContext
        self.snapshotScheduler = SnapshotScheduler(cacheContext: ctx, durableContext: ctx)
        self.syncCoordinator = SyncCoordinator(client: ynabClient, cacheContext: ctx, durableContext: ctx)

        observePersistenceFailures()
    }

    /// Bootstrap reads the token from Keychain and prefills the YNAB client.
    /// Determines initial unlock state based on the user's Face ID setting and
    /// flips `bootstrapped = true` so ContentView can render the right state.
    public func bootstrap() async {
        let token: String?
        do { token = try secretStore.load(.ynabPersonalAccessToken) }
        catch {
            logger.error("secret load failed: \(error.localizedDescription, privacy: .public)")
            token = nil
        }
        await ynabClient.setToken(token)
        hasYNABToken = (token?.isEmpty == false)

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

        if settings.faceIDEnabled && biometricGate.isAvailable {
            unlocked = false
        } else {
            unlocked = true
        }
        bootstrapped = true
    }

    public func unlockWithBiometrics() async {
        do {
            unlocked = try await biometricGate.authenticate(reason: "Unlock BlueLava Networth")
        } catch {
            unlocked = false
        }
    }

    public func saveYNABToken(_ token: String) async throws {
        try secretStore.save(token, for: .ynabPersonalAccessToken)
        await ynabClient.setToken(token)
        hasYNABToken = !token.isEmpty
    }

    public func clearYNABToken() async throws {
        try secretStore.delete(.ynabPersonalAccessToken)
        await ynabClient.setToken(nil)
        hasYNABToken = false
    }

    public func recordDailySnapshot() {
        snapshotScheduler.recordIfNeeded()
    }

    public func syncNow() async {
        await syncCoordinator.syncAll(budgetId: selectedBudgetId)
        recordDailySnapshot()
        let descriptor = FetchDescriptor<DurableUserSettings>()
        if let settings = try? modelContainer.mainContext.fetch(descriptor).first {
            selectedBudgetId = settings.selectedBudgetId
        }
    }

    /// Full reset: wipe all YNAB delta cursors, the historical-backfill marker,
    /// AND every `DurableNetWorthSnapshot` row in the CloudKit-backed store,
    /// then run a full sync. The snapshot purge is what makes the chart
    /// consistent with the current account set — old `.live` rows from
    /// previous sessions (when more accounts were open) would otherwise
    /// shadow the freshly reconstructed history via the dedupe pass.
    ///
    /// Preserves manual assets, their value history, user settings, and card
    /// settings. Only chart snapshots are destroyed.
    public func forceFullResync() async {
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
            settings.historyBackfillVersion = 0
        }
        ctx.safeSave(source: "forceFullResync.wipeAll")
        await syncNow()
    }

    // MARK: - Factories

    /// Production wiring.
    public static func makeProduction() throws -> AppContainerController {
        let secretStore = KeychainSecretStore()
        let biometric = LocalAuthBiometricGate()
        let client = LiveYNABClient()
        let container = try ModelContainerFactory.makeContainer()
        return AppContainerController(
            secretStore: secretStore,
            biometricGate: biometric,
            ynabClient: client,
            modelContainer: container
        )
    }

    /// Preview / test wiring — in-memory only, scriptable fakes.
    public static func makePreview() -> AppContainerController {
        let container = try! ModelContainerFactory.makeContainer(inMemory: true)
        return AppContainerController(
            secretStore: InMemorySecretStore(),
            biometricGate: ScriptableBiometricGate(),
            ynabClient: RecordedYNABClient(),
            modelContainer: container
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
