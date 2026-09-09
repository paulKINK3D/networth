import Foundation
import NetworthCore
import SwiftData

struct CanonicalCategoryDeletionImpact: Equatable {
    let categoryRecordCount: Int
    let transactionCount: Int
    let recurringExpectationCount: Int
    let referenceRecordCount: Int
}

struct CanonicalGroupDeletionImpact: Equatable {
    let groupRecordCount: Int
    let categoryCount: Int
    let categoryRecordCount: Int
}

/// Shared identities and eligibility rules for the user-owned Spending
/// directory. Persisted legacy fields remain readable, but this type performs
/// no launch-time migrations or cleanup.
enum SpendingGroupSetup {
    static let userGroupIdentityPrefix = "networth:spending:user:"
    static let unassignedIdentity = "networth:spending:unassigned"
    static let unassignedName = "Unassigned"
    static let investmentReportingIdentity =
        "networth:investment-contributions"
    static let investmentReportingName = "Investing"

    private struct RetiredDefault {
        let identity: String
        let name: String
    }

    private static let retiredDefaults = [
        RetiredDefault(identity: "networth:spending:fixed", name: "Fixed"),
        RetiredDefault(
            identity: "networth:spending:necessities",
            name: "Necessities"
        ),
        RetiredDefault(identity: "networth:spending:surplus", name: "Surplus"),
        RetiredDefault(identity: "networth:spending:savings", name: "Savings"),
        RetiredDefault(
            identity: "networth:spending:investment",
            name: "Investment"
        ),
    ]

    static func isUserGroup(_ group: DurableCategoryGroup) -> Bool {
        group.reportingRole == .spending
            && !group.groupIdentity.hasPrefix("ynab:")
            && group.groupIdentity != unassignedIdentity
            && !retiredDefaults.contains {
                $0.identity == group.groupIdentity && $0.name == group.name
            }
    }

    static func isAssignableCategory(
        _ category: DurableCanonicalCategory,
        groupByIdentity: [String: DurableCategoryGroup]
    ) -> Bool {
        guard !category.deletedAtSource else { return false }
        guard let identity = category.categoryGroupIdentity,
              let sourceGroup = groupByIdentity[identity] else {
            return true
        }
        return sourceGroup.reportingRole == .spending
    }

    static func isUnassignedCategory(
        _ category: DurableCanonicalCategory,
        userGroupIdentities: Set<String>
    ) -> Bool {
        guard let identity = category.categoryGroupIdentity else { return true }
        return !userGroupIdentities.contains(identity)
    }

    static func latestCategories(
        _ rows: [DurableCanonicalCategory]
    ) -> [DurableCanonicalCategory] {
        Dictionary(grouping: rows, by: \.canonicalId).compactMap { _, copies in
            copies.max(by: { $0.updatedAt < $1.updatedAt })
        }
    }
}

/// Owns destructive category-directory mutations so the impact preview and
/// the write use the same complete, fail-closed reference scan.
@MainActor
struct CanonicalDirectoryService {
    let context: ModelContext

    enum Failure: LocalizedError, Equatable {
        case categoryNotFound
        case groupNotFound
        case groupNotDeletable
        case invalidSplitData
        case saveFailed

        var errorDescription: String? {
            switch self {
            case .categoryNotFound:
                "This category no longer exists."
            case .groupNotFound:
                "This group no longer exists."
            case .groupNotDeletable:
                "This group is managed by Networth and cannot be deleted."
            case .invalidSplitData:
                "A saved split transaction could not be read. The category was not deleted."
            case .saveFailed:
                "The change could not be saved. Nothing was changed."
            }
        }
    }

    func groupDeletionImpact(
        groupIdentity: String
    ) throws -> CanonicalGroupDeletionImpact {
        try scanGroup(groupIdentity: groupIdentity).impact
    }

    @discardableResult
    func deleteGroup(
        groupIdentity: String
    ) throws -> CanonicalGroupDeletionImpact {
        // Re-scan at confirmation time so a category assigned after the
        // preview is still moved safely instead of being orphaned.
        let scan = try scanGroup(groupIdentity: groupIdentity)
        let now = Date.now

        do {
            for category in scan.categories {
                category.categoryGroupIdentity = nil
                category.groupName = ""
                category.userEdited = true
                category.updatedAt = now
            }
            for group in scan.groups {
                context.delete(group)
            }
            for rule in scan.budgetRules {
                context.delete(rule)
            }
            for choice in scan.savingsChoices {
                context.delete(choice)
            }
            for assignment in scan.savingsTransferAssignments {
                context.delete(assignment)
            }
            guard context.safeSave(source: "canonicalGroups.delete") else {
                throw Failure.saveFailed
            }
            return scan.impact
        } catch {
            context.rollback()
            throw error
        }
    }

    func deletionImpact(
        canonicalId: String
    ) throws -> CanonicalCategoryDeletionImpact {
        try scan(canonicalId: canonicalId).impact
    }

    @discardableResult
    func deleteCategory(
        canonicalId: String
    ) throws -> CanonicalCategoryDeletionImpact {
        // Re-scan at confirmation time instead of trusting a stale preview.
        // All fetches and JSON decoding finish before the first mutation.
        let scan = try scan(canonicalId: canonicalId)
        let now = Date.now

        do {
            for (decision, legs) in scan.decisions {
                let topLevelMatch = decision.categoryCanonicalId == canonicalId
                let updatedLegs = moveToUnassigned(
                    legs,
                    canonicalId: canonicalId
                )
                guard topLevelMatch || updatedLegs != legs else { continue }
                if topLevelMatch {
                    decision.categoryCanonicalId = nil
                    decision.categoryNameSnapshot = nil
                }
                if updatedLegs != legs {
                    decision.subtransactionsData = try encode(updatedLegs)
                }
                decision.reviewed = false
                decision.updatedAt = now
            }

            for (row, legs) in scan.cachedTransactions {
                let topLevelMatch = row.categoryCanonicalId == canonicalId
                let updatedLegs = moveToUnassigned(
                    legs,
                    canonicalId: canonicalId
                )
                guard topLevelMatch || updatedLegs != legs else { continue }
                if topLevelMatch {
                    row.categoryCanonicalId = nil
                    row.categoryName = nil
                    row.nativeCategoryRaw = "other"
                }
                if updatedLegs != legs {
                    row.subtransactionsData = try encode(updatedLegs)
                }
                row.requiresReview = true
                row.updatedAt = now
            }

            for (override, legs) in scan.overrides {
                let updatedLegs = moveToUnassigned(
                    legs,
                    canonicalId: canonicalId
                )
                guard updatedLegs != legs else { continue }
                override.subtransactionsData = try encode(updatedLegs)
                override.updatedAt = now
            }

            for expectation in scan.recurringExpectations
            where expectation.categoryCanonicalId == canonicalId {
                expectation.categoryCanonicalId = nil
                expectation.categoryName = nil
                expectation.updatedAt = now
            }

            for category in scan.categories {
                context.delete(category)
            }

            guard context.safeSave(source: "canonicalCategories.delete") else {
                throw Failure.saveFailed
            }
            return scan.impact
        } catch {
            context.rollback()
            throw error
        }
    }

    private struct Scan {
        let categories: [DurableCanonicalCategory]
        let decisions:
            [(
                DurableCanonicalTransactionDecision,
                [SubTransactionSummary]
            )]
        let cachedTransactions:
            [(
                CachedFinancialTransaction,
                [SubTransactionSummary]
            )]
        let overrides:
            [(
                DurableTransactionOverride,
                [SubTransactionSummary]
            )]
        let recurringExpectations: [DurableRecurringExpectation]
        let impact: CanonicalCategoryDeletionImpact
    }

    private struct GroupScan {
        let groups: [DurableCategoryGroup]
        let categories: [DurableCanonicalCategory]
        let budgetRules: [DurableSpendingGroupBudgetRule]
        let savingsChoices: [DurableSavingsBudgetChoice]
        let savingsTransferAssignments: [DurableSavingsTransferAssignment]
        let impact: CanonicalGroupDeletionImpact
    }

    private func scanGroup(groupIdentity: String) throws -> GroupScan {
        let groups = try context.fetch(
            FetchDescriptor<DurableCategoryGroup>()
        ).filter { $0.groupIdentity == groupIdentity }
        guard let latest = groups.max(by: { $0.updatedAt < $1.updatedAt }) else {
            throw Failure.groupNotFound
        }
        guard SpendingGroupSetup.isUserGroup(latest) else {
            throw Failure.groupNotDeletable
        }
        let categories = try context.fetch(
            FetchDescriptor<DurableCanonicalCategory>()
        ).filter { $0.categoryGroupIdentity == groupIdentity }
        let budgetRules = try context.fetch(
            FetchDescriptor<DurableSpendingGroupBudgetRule>()
        ).filter { $0.groupIdentity == groupIdentity }
        let savingsChoices = try context.fetch(
            FetchDescriptor<DurableSavingsBudgetChoice>()
        ).filter {
            $0.sourceGroupIdentity == groupIdentity
                || $0.savingsGroupIdentity == groupIdentity
        }
        let savingsTransferAssignments = try context.fetch(
            FetchDescriptor<DurableSavingsTransferAssignment>()
        ).filter { $0.savingsGroupIdentity == groupIdentity }

        return GroupScan(
            groups: groups,
            categories: categories,
            budgetRules: budgetRules,
            savingsChoices: savingsChoices,
            savingsTransferAssignments: savingsTransferAssignments,
            impact: CanonicalGroupDeletionImpact(
                groupRecordCount: groups.count,
                categoryCount: Set(categories.map(\.canonicalId)).count,
                categoryRecordCount: categories.count
            )
        )
    }

    private func scan(canonicalId: String) throws -> Scan {
        let categories = try context.fetch(
            FetchDescriptor<DurableCanonicalCategory>()
        ).filter { $0.canonicalId == canonicalId }
        guard !categories.isEmpty else { throw Failure.categoryNotFound }

        let decisions = try context.fetch(
            FetchDescriptor<DurableCanonicalTransactionDecision>()
        ).map { ($0, try decode($0.subtransactionsData)) }
        let cachedTransactions = try context.fetch(
            FetchDescriptor<CachedFinancialTransaction>()
        ).map { ($0, try decode($0.subtransactionsData)) }
        let overrides = try context.fetch(
            FetchDescriptor<DurableTransactionOverride>()
        ).map { ($0, try decode($0.subtransactionsData)) }
        let recurringExpectations = try context.fetch(
            FetchDescriptor<DurableRecurringExpectation>()
        )

        var transactionIDs = Set<String>()
        var referenceRecordCount = 0
        let externalIDByCachedID = Dictionary(
            cachedTransactions.map { ($0.0.id, $0.0.externalId) },
            uniquingKeysWith: { first, _ in first }
        )

        func transactionKey(_ value: String, fallback: String) -> String {
            let resolved = externalIDByCachedID[value] ?? value
            return resolved.isEmpty ? fallback : resolved
        }

        for (decision, legs) in decisions
        where decision.categoryCanonicalId == canonicalId
            || containsCategory(legs, canonicalId: canonicalId)
        {
            transactionIDs.insert(
                transactionKey(
                    decision.transactionExternalId,
                    fallback: "decision:\(decision.id)"
                ))
            referenceRecordCount += 1
        }
        for (row, legs) in cachedTransactions
        where row.categoryCanonicalId == canonicalId
            || containsCategory(legs, canonicalId: canonicalId)
        {
            transactionIDs.insert(
                transactionKey(
                    row.externalId,
                    fallback: "cached:\(row.id)"
                ))
            referenceRecordCount += 1
        }
        for (override, legs) in overrides
        where containsCategory(legs, canonicalId: canonicalId) {
            transactionIDs.insert(
                transactionKey(
                    override.transactionExternalId,
                    fallback: "override:\(override.id)"
                ))
            referenceRecordCount += 1
        }
        let affectedExpectations = recurringExpectations.filter {
            $0.categoryCanonicalId == canonicalId
        }
        referenceRecordCount += affectedExpectations.count

        return Scan(
            categories: categories,
            decisions: decisions,
            cachedTransactions: cachedTransactions,
            overrides: overrides,
            recurringExpectations: recurringExpectations,
            impact: CanonicalCategoryDeletionImpact(
                categoryRecordCount: categories.count,
                transactionCount: transactionIDs.count,
                recurringExpectationCount: affectedExpectations.count,
                referenceRecordCount: referenceRecordCount
            )
        )
    }

    private func decode(
        _ data: Data?
    ) throws -> [SubTransactionSummary] {
        guard let data, !data.isEmpty else { return [] }
        do {
            return try JSONDecoder().decode(
                [SubTransactionSummary].self,
                from: data
            )
        } catch {
            throw Failure.invalidSplitData
        }
    }

    private func encode(
        _ legs: [SubTransactionSummary]
    ) throws -> Data {
        do {
            return try JSONEncoder().encode(legs)
        } catch {
            throw Failure.invalidSplitData
        }
    }

    private func containsCategory(
        _ legs: [SubTransactionSummary],
        canonicalId: String
    ) -> Bool {
        legs.contains { referencesCategory($0, canonicalId: canonicalId) }
    }

    private func moveToUnassigned(
        _ legs: [SubTransactionSummary],
        canonicalId: String
    ) -> [SubTransactionSummary] {
        legs.map { leg in
            guard referencesCategory(leg, canonicalId: canonicalId) else {
                return leg
            }
            return SubTransactionSummary(
                id: leg.id,
                amount: leg.amount,
                categoryId: nil,
                categoryName: nil,
                categoryCanonicalId: nil,
                goalId: leg.goalId,
                forecastTreatment: leg.forecastTreatment,
                transferAccountId: leg.transferAccountId,
                payeeName: leg.payeeName,
                memo: leg.memo,
                deleted: leg.deleted
            )
        }
    }

    private func referencesCategory(
        _ leg: SubTransactionSummary,
        canonicalId: String
    ) -> Bool {
        if leg.categoryCanonicalId == canonicalId
            || leg.categoryId == canonicalId
        {
            return true
        }
        guard canonicalId.hasPrefix("ynab:") else { return false }
        return leg.categoryId == String(canonicalId.dropFirst("ynab:".count))
    }
}
