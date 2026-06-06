import Testing
import SwiftData
@testable import Networth
import NetworthCore

@MainActor
@Suite("AppContainer wiring")
struct AppContainerTests {

    @Test func bootstrapWithNoTokenLeavesUnlockedTrue() async {
        let container = AppContainerController.makePreview()
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
}
