import Foundation
import SwiftData
import os

public enum ModelContainerFactory {
    private static let logger = Logger(subsystem: "com.bluelava.me.networth", category: "persistence")

    /// Unified container with two configurations.
    /// - Cache config (no CloudKit): re-fetchable YNAB and Plaid source data.
    /// - Durable config (CloudKit private DB): user-authored assets, snapshots,
    ///   settings, account mappings, and transaction classification decisions.
    public static func makeContainer(inMemory: Bool = false, cloudKitContainerId: String? = nil) throws -> ModelContainer {
        let cacheSchema = Schema([
            CachedBudget.self,
            CachedAccount.self,
            CachedTransaction.self,
            CachedScheduledTransaction.self,
            CachedCategory.self,
            CachedCategoryMonth.self,
            SyncCursor.self,
            CachedPlaidItem.self,
            CachedPlaidAccount.self,
            CachedPlaidSecurity.self,
            CachedPlaidHolding.self,
            CachedFinancialAccount.self,
            CachedFinancialTransaction.self,
            PlaidTransactionCursor.self,
            PlaidAccountCoverage.self,
            YNABReferenceSuggestion.self,
            LegacyTransactionMatchRow.self
        ])
        let durableSchema = Schema([
            DurableManualAsset.self,
            DurableManualAssetValue.self,
            DurableNetWorthSnapshot.self,
            DurableCardSettings.self,
            DurableCardPaymentConfirmation.self,
            DurableCardPaymentSettlement.self,
            DurableCardStatementAssignment.self,
            DurableUserSettings.self,
            DurableExcludedSpendCategory.self,
            DurableExcludedSpendTransaction.self,
            DurableIncludedClosedAccount.self,
            DurableProjectionCashAccountOverride.self,
            DurablePlaidAccountTreatment.self,
            DurablePlaidBalanceSnapshot.self,
            DurableCanonicalAccountBinding.self,
            DurableAccountNickname.self,
            DurableSpendingAccountPin.self,
            DurableCanonicalPayee.self,
            DurablePayeeAlias.self,
            DurableCanonicalCategory.self,
            DurableCategoryGroup.self,
            DurableSpendingGroupBudgetRule.self,
            DurableSpendingRemainderRule.self,
            DurableSavingsBudgetChoice.self,
            DurableSavingsTransferAssignment.self,
            DurableSpendingSinkingFund.self,
            DurableSpendingSinkingFundContribution.self,
            DurableSpendingSinkingFundExpense.self,
            DurableCanonicalTransactionDecision.self,
            DurableMerchantRule.self,
            DurableTransactionCategory.self,
            DurableTransactionOverride.self,
            DurableFixedCommitment.self,
            DurableBudgetCategoryAssignment.self,
            DurableIncomePatternOverride.self,
            DurableRecurringExpectation.self,
            DurableSinkingFund.self,
            DurableFundEvent.self,
            DurableGoal.self,
            DurableGoalLedgerEntry.self,
            DurableGoalReserveAccount.self,
            DurableGoalTransferRequest.self,
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
            CachedCategoryMonth.self,
            SyncCursor.self,
            CachedPlaidItem.self,
            CachedPlaidAccount.self,
            CachedPlaidSecurity.self,
            CachedPlaidHolding.self,
            CachedFinancialAccount.self,
            CachedFinancialTransaction.self,
            PlaidTransactionCursor.self,
            PlaidAccountCoverage.self,
            YNABReferenceSuggestion.self,
            LegacyTransactionMatchRow.self,
            DurableManualAsset.self,
            DurableManualAssetValue.self,
            DurableNetWorthSnapshot.self,
            DurableCardSettings.self,
            DurableCardPaymentConfirmation.self,
            DurableCardPaymentSettlement.self,
            DurableCardStatementAssignment.self,
            DurableUserSettings.self,
            DurableExcludedSpendCategory.self,
            DurableExcludedSpendTransaction.self,
            DurableIncludedClosedAccount.self,
            DurableProjectionCashAccountOverride.self,
            DurablePlaidAccountTreatment.self,
            DurablePlaidBalanceSnapshot.self,
            DurableCanonicalAccountBinding.self,
            DurableAccountNickname.self,
            DurableSpendingAccountPin.self,
            DurableCanonicalPayee.self,
            DurablePayeeAlias.self,
            DurableCanonicalCategory.self,
            DurableCategoryGroup.self,
            DurableSpendingGroupBudgetRule.self,
            DurableSpendingRemainderRule.self,
            DurableSavingsBudgetChoice.self,
            DurableSavingsTransferAssignment.self,
            DurableSpendingSinkingFund.self,
            DurableSpendingSinkingFundContribution.self,
            DurableSpendingSinkingFundExpense.self,
            DurableCanonicalTransactionDecision.self,
            DurableMerchantRule.self,
            DurableTransactionCategory.self,
            DurableTransactionOverride.self,
            DurableFixedCommitment.self,
            DurableBudgetCategoryAssignment.self,
            DurableIncomePatternOverride.self,
            DurableRecurringExpectation.self,
            DurableSinkingFund.self,
            DurableFundEvent.self,
            DurableGoal.self,
            DurableGoalLedgerEntry.self,
            DurableGoalReserveAccount.self,
            DurableGoalTransferRequest.self,
        ])
        return try ModelContainer(for: unified, configurations: [cacheConfig, durableConfig])
    }
}
