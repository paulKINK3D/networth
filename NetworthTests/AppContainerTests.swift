import Foundation
import Testing
import SwiftData
@testable import Networth
import NetworthCore

@MainActor
@Suite("AppContainer wiring")
struct AppContainerTests {

    @Test func bootstrapWithBiometricAvailableLocksUntilUnlock() async {
        // With biometrics available (the ScriptableBiometricGate default) and
        // the shipped Face-ID-on-by-default behavior, bootstrap should leave
        // the app locked behind the biometric prompt regardless of token state.
        let container = AppContainerController.makePreview()
        await container.bootstrap()
        #expect(container.unlocked == false)
        #expect(container.hasYNABToken == false)
    }

    @Test func bootstrapWithBiometricUnavailableLeavesUnlocked() async {
        // When the device cannot use biometrics, the Face ID gate cannot
        // engage and the app must boot straight into the tabs.
        let container = AppContainerController(
            secretStore: InMemorySecretStore(),
            biometricGate: ScriptableBiometricGate(isAvailable: false),
            ynabClient: RecordedYNABClient(),
            modelContainer: try! ModelContainerFactory.makeContainer(inMemory: true)
        )
        await container.bootstrap()
        #expect(container.unlocked == true)
        #expect(container.hasYNABToken == false)
    }

    @Test func saveAndClearYNABTokenUpdatesFlag() async throws {
        let container = AppContainerController.makePreview()
        await container.bootstrap()
        try await container.saveYNABToken("test-token")
        #expect(container.hasYNABToken == true)
        try await container.clearYNABToken()
        #expect(container.hasYNABToken == false)
    }

    @Test func snapshotIsIdempotentForSameDay() async {
        let container = AppContainerController.makePreview()
        await container.bootstrap()
        let first = container.snapshotScheduler.recordIfNeeded()
        let second = container.snapshotScheduler.recordIfNeeded()
        #expect(first?.id == second?.id)
    }

    @Test func breakdownAddsManualAssets() async throws {
        let container = AppContainerController.makePreview()
        await container.bootstrap()
        let ctx = container.modelContainer.mainContext
        let house = DurableManualAsset(name: "Home", kind: .realEstate)
        ctx.insert(house)
        let entry = DurableManualAssetValue(amountMilliunits: Money.dollars(500_000).milliunits, asset: house)
        ctx.insert(entry)
        house.values = [entry]
        try ctx.save()
        let bd = container.snapshotScheduler.computeBreakdown()
        #expect(bd.manualAssets == Money.dollars(500_000))
        #expect(bd.netWorth == Money.dollars(500_000))
    }

    // MARK: - Historical backfill

    @Test func backfillWritesReconstructedSnapshots() async throws {
        let container = AppContainerController.makePreview()
        await container.bootstrap()
        let ctx = container.modelContainer.mainContext

        seedAccountWithRecentTransactions(into: ctx, budgetId: "b1")
        try ctx.save()

        container.syncCoordinator.runHistoryBackfillIfNeeded(budgetId: "b1")

        let snaps = try ctx.fetch(FetchDescriptor<DurableNetWorthSnapshot>())
        #expect(snaps.count > 1)
        #expect(snaps.allSatisfy { $0.source == .backfill })
    }

    @Test func backfillMarkerSkipsSecondRun() async throws {
        let container = AppContainerController.makePreview()
        await container.bootstrap()
        let ctx = container.modelContainer.mainContext

        seedAccountWithRecentTransactions(into: ctx, budgetId: "b1")
        try ctx.save()

        container.syncCoordinator.runHistoryBackfillIfNeeded(budgetId: "b1")
        let firstCount = try ctx.fetch(FetchDescriptor<DurableNetWorthSnapshot>()).count

        let settings = try #require(try ctx.fetch(FetchDescriptor<DurableUserSettings>()).first)
        #expect(settings.historyBackfillVersion == SyncCoordinator.currentHistoryBackfillVersion)

        container.syncCoordinator.runHistoryBackfillIfNeeded(budgetId: "b1")
        let secondCount = try ctx.fetch(FetchDescriptor<DurableNetWorthSnapshot>()).count
        #expect(secondCount == firstCount)
    }

    @Test func backfillCollapsesPreSeededDuplicateDay() async throws {
        let container = AppContainerController.makePreview()
        await container.bootstrap()
        let ctx = container.modelContainer.mainContext

        seedAccountWithRecentTransactions(into: ctx, budgetId: "b1")

        // Pre-seed a duplicate `.backfill` row from a hypothetical interrupted
        // prior run for a day inside the reconstruction window.
        let cal = Calendar(identifier: .gregorian)
        let day = cal.startOfDay(for: cal.date(byAdding: .day, value: -10, to: .now)!)
        ctx.insert(DurableNetWorthSnapshot(
            date: day,
            assetsMilliunits: 1_000_000,
            liabilitiesMilliunits: 0,
            source: .backfill
        ))
        try ctx.save()

        container.syncCoordinator.runHistoryBackfillIfNeeded(budgetId: "b1")

        let snaps = try ctx.fetch(FetchDescriptor<DurableNetWorthSnapshot>())
        let byDay = Dictionary(grouping: snaps) { cal.startOfDay(for: $0.date) }
        #expect(byDay.allSatisfy { $0.value.count == 1 })
    }

    @Test func dedupePreservesRicherLiveSnapshot() async throws {
        let container = AppContainerController.makePreview()
        await container.bootstrap()
        let ctx = container.modelContainer.mainContext

        seedAccountWithRecentTransactions(into: ctx, budgetId: "b1")

        // Pre-seed a `.live` snapshot for a specific day inside the window with
        // a much richer assets total (simulating a day where manual assets had
        // already been counted).
        let cal = Calendar(identifier: .gregorian)
        let day = cal.startOfDay(for: cal.date(byAdding: .day, value: -10, to: .now)!)
        let liveAssets: Int64 = 999_999_999_000  // far richer than reconstruction
        let liveSnap = DurableNetWorthSnapshot(
            date: day,
            assetsMilliunits: liveAssets,
            liabilitiesMilliunits: 0,
            source: .live
        )
        ctx.insert(liveSnap)
        try ctx.save()

        container.syncCoordinator.runHistoryBackfillIfNeeded(budgetId: "b1")

        let snaps = try ctx.fetch(FetchDescriptor<DurableNetWorthSnapshot>(
            predicate: #Predicate { $0.date == day }
        ))
        #expect(snaps.count == 1)
        let survivor = try #require(snaps.first)
        #expect(survivor.source == .live)
        #expect(survivor.assetsMilliunits == liveAssets)
    }

    // MARK: - Helpers

    private func seedAccountWithRecentTransactions(into ctx: ModelContext, budgetId: String) {
        let account = CachedAccount(
            id: "a1",
            budgetId: budgetId,
            name: "Checking",
            typeRaw: "checking",
            balanceMilliunits: Money.dollars(5_000).milliunits,
            clearedMilliunits: Money.dollars(5_000).milliunits,
            unclearedMilliunits: 0,
            onBudget: true,
            closed: false,
            deleted: false
        )
        ctx.insert(account)

        let cal = Calendar(identifier: .gregorian)
        for offset in [3, 30, 180] {
            let date = cal.date(byAdding: .day, value: -offset, to: .now)!
            ctx.insert(CachedTransaction(
                id: "t\(offset)",
                budgetId: budgetId,
                accountId: "a1",
                date: date,
                amountMilliunits: Money.dollars(-50).milliunits,
                cleared: true,
                approved: true,
                payeeName: "Coffee",
                categoryName: nil,
                memo: nil,
                deleted: false
            ))
        }
    }
}
