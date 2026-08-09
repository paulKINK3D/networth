import Foundation
import NetworthCore
import SwiftData
import Testing

@testable import Networth

@MainActor
@Suite("Canonical category directory")
struct CanonicalDirectoryServiceTests {
    @Test func groupDeletionMovesEveryCategoryCopyToUnassigned() throws {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let context = container.mainContext
        let groupID = "networth:spending:user:travel"

        context.insert(DurableCategoryGroup(
            groupIdentity: groupID,
            name: "Travel",
            reportingRole: .spending
        ))
        context.insert(DurableCategoryGroup(
            groupIdentity: groupID,
            name: "Travel",
            reportingRole: .spending
        ))
        let category = DurableCanonicalCategory(
            canonicalId: "category:flights",
            name: "Flights",
            groupName: "Travel",
            categoryGroupIdentity: groupID
        )
        let duplicate = DurableCanonicalCategory(
            canonicalId: "category:flights",
            name: "Flights",
            groupName: "Travel",
            categoryGroupIdentity: groupID
        )
        let hotel = DurableCanonicalCategory(
            canonicalId: "category:hotels",
            name: "Hotels",
            groupName: "Travel",
            categoryGroupIdentity: groupID
        )
        context.insert(category)
        context.insert(duplicate)
        context.insert(hotel)
        try context.save()

        let service = CanonicalDirectoryService(context: context)
        let preview = try service.groupDeletionImpact(groupIdentity: groupID)
        #expect(preview.groupRecordCount == 2)
        #expect(preview.categoryCount == 2)
        #expect(preview.categoryRecordCount == 3)

        let deleted = try service.deleteGroup(groupIdentity: groupID)
        #expect(deleted == preview)
        #expect(try context.fetch(FetchDescriptor<DurableCategoryGroup>())
            .allSatisfy { $0.groupIdentity != groupID })

        let categories = try context.fetch(
            FetchDescriptor<DurableCanonicalCategory>()
        )
        #expect(categories.count == 3)
        #expect(categories.allSatisfy { $0.categoryGroupIdentity == nil })
        #expect(categories.allSatisfy { $0.groupName.isEmpty })
        #expect(categories.allSatisfy { $0.userEdited })
    }

    @Test func groupDeletionRejectsReferenceGroupsWithoutMutation() throws {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let context = container.mainContext
        let groupID = "ynab:travel"
        context.insert(DurableCategoryGroup(
            groupIdentity: groupID,
            name: "Travel",
            reportingRole: .spending
        ))
        let category = DurableCanonicalCategory(
            canonicalId: "category:flights",
            name: "Flights",
            groupName: "Travel",
            categoryGroupIdentity: groupID
        )
        context.insert(category)
        try context.save()

        do {
            try CanonicalDirectoryService(context: context)
                .deleteGroup(groupIdentity: groupID)
            Issue.record("Expected a reference group deletion to fail")
        } catch let error as CanonicalDirectoryService.Failure {
            #expect(error == .groupNotDeletable)
        }

        #expect(category.categoryGroupIdentity == groupID)
        #expect(try context.fetch(FetchDescriptor<DurableCategoryGroup>())
            .contains { $0.groupIdentity == groupID })
    }

    @Test func deletionRemovesDuplicatesAndMovesEveryReferenceToUnassigned()
        throws
    {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let context = container.mainContext
        let targetID = "networth:travel"
        let otherID = "networth:groceries"

        context.insert(
            DurableCanonicalCategory(
                canonicalId: targetID,
                name: "Travel",
                groupName: "Fun"
            ))
        context.insert(
            DurableCanonicalCategory(
                canonicalId: targetID,
                name: "Travel duplicate",
                groupName: "Fun"
            ))
        context.insert(
            DurableCanonicalCategory(
                canonicalId: otherID,
                name: "Groceries",
                groupName: "Living"
            ))

        let targetSplits = try encodedSplits(targetID: targetID)
        let topDecision = DurableCanonicalTransactionDecision(
            transactionExternalId: "tx-1",
            categoryCanonicalId: targetID,
            categoryNameSnapshot: "Travel",
            reviewed: true,
            provenance: .user
        )
        let splitDecision = DurableCanonicalTransactionDecision(
            transactionExternalId: "tx-2",
            categoryNameSnapshot: "Split",
            subtransactionsData: targetSplits,
            reviewed: true,
            provenance: .user
        )
        context.insert(topDecision)
        context.insert(splitDecision)

        let topRow = transaction(externalID: "tx-1")
        topRow.categoryCanonicalId = targetID
        topRow.categoryName = "Travel"
        topRow.requiresReview = false
        let splitRow = transaction(
            externalID: "tx-2",
            subtransactionsData: targetSplits
        )
        splitRow.requiresReview = false
        let unrelatedRow = transaction(externalID: "tx-unrelated")
        unrelatedRow.categoryCanonicalId = otherID
        unrelatedRow.categoryName = "Groceries"
        context.insert(topRow)
        context.insert(splitRow)
        context.insert(unrelatedRow)

        let override = DurableTransactionOverride(
            transactionExternalId: "tx-3",
            displayName: "Trip",
            subtransactionsData: targetSplits
        )
        context.insert(override)
        let suggestion = YNABReferenceSuggestion(
            plaidTransactionId: splitRow.id,
            ynabTransactionId: "ynab-tx-2",
            categoryNameSnapshot: "Split",
            subtransactionsData: targetSplits
        )
        context.insert(suggestion)
        let expectation = DurableRecurringExpectation(
            accountCanonicalId: "checking",
            payeeName: "Annual trip",
            categoryCanonicalId: targetID,
            categoryName: "Travel",
            amountMilliunits: -100_000
        )
        context.insert(expectation)
        try context.save()

        let service = CanonicalDirectoryService(context: context)
        let preview = try service.deletionImpact(canonicalId: targetID)

        #expect(preview.categoryRecordCount == 2)
        #expect(preview.transactionCount == 3)
        #expect(preview.recurringExpectationCount == 1)
        #expect(preview.referenceRecordCount == 7)

        let deleted = try service.deleteCategory(canonicalId: targetID)
        #expect(deleted == preview)

        let categories = try context.fetch(
            FetchDescriptor<DurableCanonicalCategory>()
        )
        #expect(!categories.contains { $0.canonicalId == targetID })
        #expect(categories.contains { $0.canonicalId == otherID })

        #expect(topDecision.categoryCanonicalId == nil)
        #expect(topDecision.categoryNameSnapshot == nil)
        #expect(!topDecision.reviewed)
        #expect(splitDecision.subtransactions[0].categoryCanonicalId == nil)
        #expect(splitDecision.subtransactions[0].categoryId == nil)
        #expect(splitDecision.subtransactions[0].categoryName == nil)
        #expect(splitDecision.subtransactions[1].categoryCanonicalId == otherID)
        #expect(!splitDecision.reviewed)

        #expect(topRow.categoryCanonicalId == nil)
        #expect(topRow.categoryName == nil)
        #expect(topRow.requiresReview)
        #expect(splitRow.subtransactions[0].categoryCanonicalId == nil)
        #expect(splitRow.subtransactions[1].categoryCanonicalId == otherID)
        #expect(splitRow.requiresReview)

        #expect(override.subtransactions[0].categoryCanonicalId == nil)
        #expect(override.subtransactions[1].categoryCanonicalId == otherID)
        #expect(suggestion.subtransactions[0].categoryCanonicalId == nil)
        #expect(suggestion.subtransactions[1].categoryCanonicalId == otherID)
        #expect(expectation.categoryCanonicalId == nil)
        #expect(expectation.categoryName == nil)
        #expect(unrelatedRow.categoryCanonicalId == otherID)
        #expect(unrelatedRow.categoryName == "Groceries")
        #expect(!unrelatedRow.requiresReview)
    }

    @Test func malformedSplitStopsDeletionBeforeAnyMutation() throws {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let context = container.mainContext
        let targetID = "networth:travel"
        context.insert(
            DurableCanonicalCategory(
                canonicalId: targetID,
                name: "Travel",
                groupName: "Fun"
            ))
        context.insert(
            DurableCanonicalTransactionDecision(
                transactionExternalId: "broken",
                categoryCanonicalId: targetID,
                categoryNameSnapshot: "Travel",
                subtransactionsData: Data([0xFF]),
                reviewed: true,
                provenance: .user
            ))
        try context.save()

        do {
            try CanonicalDirectoryService(context: context)
                .deleteCategory(canonicalId: targetID)
            Issue.record("Expected malformed split data to block deletion")
        } catch let error as CanonicalDirectoryService.Failure {
            #expect(error == .invalidSplitData)
        }

        let categories = try context.fetch(
            FetchDescriptor<DurableCanonicalCategory>()
        )
        let decisions = try context.fetch(
            FetchDescriptor<DurableCanonicalTransactionDecision>()
        )
        #expect(categories.contains { $0.canonicalId == targetID })
        #expect(decisions.first?.categoryCanonicalId == targetID)
        #expect(decisions.first?.reviewed == true)
    }

    private func encodedSplits(targetID: String) throws -> Data {
        try JSONEncoder().encode([
            SubTransactionSummary(
                id: "target-leg",
                amount: Money(milliunits: -60_000),
                categoryId: targetID,
                categoryName: "Travel",
                categoryCanonicalId: targetID,
                payeeName: nil,
                memo: nil,
                deleted: false
            ),
            SubTransactionSummary(
                id: "other-leg",
                amount: Money(milliunits: -40_000),
                categoryId: "networth:groceries",
                categoryName: "Groceries",
                categoryCanonicalId: "networth:groceries",
                payeeName: nil,
                memo: nil,
                deleted: false
            ),
        ])
    }

    private func transaction(
        externalID: String,
        subtransactionsData: Data? = nil
    ) -> CachedFinancialTransaction {
        let summary = FinancialTransactionSummary(
            id: "plaid:\(externalID)",
            externalId: externalID,
            source: .plaid,
            accountId: "checking",
            postedDate: .now,
            authorizedDate: nil,
            amount: Money(milliunits: -100_000),
            pending: false,
            pendingTransactionId: nil,
            rawDescription: "Transaction",
            originalDescription: nil,
            providerMerchantName: nil,
            merchantEntityId: nil,
            counterpartyName: nil,
            counterpartyType: nil,
            counterpartyEntityId: nil,
            counterpartyConfidence: nil,
            paymentChannel: nil,
            providerCategoryPrimary: nil,
            providerCategoryDetailed: nil,
            providerCategoryConfidence: nil,
            transactionCode: nil
        )
        return CachedFinancialTransaction(
            summary: summary,
            classification: TransactionClassification(
                displayName: "Transaction",
                category: .other,
                categoryName: "Other",
                treatment: .ordinarySpending,
                confidence: .high,
                provenance: .user,
                requiresReview: false
            ),
            subtransactionsData: subtransactionsData,
            requiresNameReview: false
        )
    }
}
