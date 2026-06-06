import Foundation
import SwiftData
import os

public enum ModelContainerFactory {
    private static let logger = Logger(subsystem: "com.bluelava.me.networth", category: "persistence")

    /// Unified container with two configurations.
    /// - Cache config (no CloudKit): YNAB-derived data we can always re-fetch.
    /// - Durable config (CloudKit private DB): manual assets, snapshots, settings.
    public static func makeContainer(inMemory: Bool = false, cloudKitContainerId: String? = nil) throws -> ModelContainer {
        let cacheSchema = Schema([
            CachedBudget.self,
            CachedAccount.self,
            CachedTransaction.self,
            CachedScheduledTransaction.self,
            CachedCategory.self,
            SyncCursor.self
        ])
        let durableSchema = Schema([
            DurableManualAsset.self,
            DurableManualAssetValue.self,
            DurableNetWorthSnapshot.self,
            DurableCardSettings.self,
            DurableUserSettings.self,
            DurableExcludedSpendCategory.self
        ])

        let cacheConfig = ModelConfiguration(
            "NetworthLocalCache",
            schema: cacheSchema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none
        )

        let cloud: ModelConfiguration.CloudKitDatabase
        if inMemory {
            cloud = .none
        } else if let id = cloudKitContainerId {
            cloud = .private(id)
        } else {
            cloud = .automatic
        }
        let durableConfig = ModelConfiguration(
            "NetworthDurable",
            schema: durableSchema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: cloud
        )

        let unified = Schema([
            CachedBudget.self,
            CachedAccount.self,
            CachedTransaction.self,
            CachedScheduledTransaction.self,
            CachedCategory.self,
            SyncCursor.self,
            DurableManualAsset.self,
            DurableManualAssetValue.self,
            DurableNetWorthSnapshot.self,
            DurableCardSettings.self,
            DurableUserSettings.self,
            DurableExcludedSpendCategory.self
        ])
        return try ModelContainer(for: unified, configurations: [cacheConfig, durableConfig])
    }
}
