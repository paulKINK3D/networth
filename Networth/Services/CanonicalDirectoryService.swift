import Foundation
import NetworthCore
import SwiftData

struct CanonicalCategoryDeletionImpact: Equatable {
    let categoryRecordCount: Int
    let transactionCount: Int
    let recurringExpectationCount: Int
    let referenceRecordCount: Int
}

/// Owns destructive category-directory mutations so the impact preview and
/// the write use the same complete, fail-closed reference scan.
@MainActor
struct CanonicalDirectoryService {
    let context: ModelContext

    enum Failure: LocalizedError, Equatable {
        case categoryNotFound
        case invalidSplitData
        case saveFailed

        var errorDescription: String? {
            switch self {
            case .categoryNotFound:
                "This category no longer exists."
            case .invalidSplitData:
                "A saved split transaction could not be read. The category was not deleted."
            case .saveFailed:
                "The category could not be deleted. Nothing was changed."
            }
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
                    row.nativeCategoryRaw = NativeTransactionCategory.other.rawValue
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

            for (suggestion, legs) in scan.suggestions {
                let topLevelMatch = suggestion.categoryCanonicalId == canonicalId
                let updatedLegs = moveToUnassigned(
                    legs,
                    canonicalId: canonicalId
                )
                guard topLevelMatch || updatedLegs != legs else { continue }
                if topLevelMatch {
                    suggestion.categoryCanonicalId = nil
                    suggestion.categoryNameSnapshot = nil
                }
                if updatedLegs != legs {
                    suggestion.subtransactionsData = try encode(updatedLegs)
                }
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
        let suggestions:
            [(
                YNABReferenceSuggestion,
                [SubTransactionSummary]
            )]
        let recurringExpectations: [DurableRecurringExpectation]
        let impact: CanonicalCategoryDeletionImpact
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
        let suggestions = try context.fetch(
            FetchDescriptor<YNABReferenceSuggestion>()
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
        for (suggestion, legs) in suggestions
        where suggestion.categoryCanonicalId == canonicalId
            || containsCategory(legs, canonicalId: canonicalId)
        {
            transactionIDs.insert(
                transactionKey(
                    suggestion.plaidTransactionId,
                    fallback: "suggestion:\(suggestion.ynabTransactionId)"
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
            suggestions: suggestions,
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
