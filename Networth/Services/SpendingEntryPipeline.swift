import Foundation
import SwiftData
import NetworthCore

/// The one shared spending pipeline: raw approved rows → entries →
/// goal-assignment resolution → purchase/refund adjustment. Both
/// `SpendingHistoryBuildActor` and `GoalsBuildActor` consume
/// this, so the Spending display and the Goals emergency input are always the
/// same numbers.
enum SpendingEntryPipeline {

    /// Prebuilt lookups shared by every stage. Build once per pipeline run
    /// from already-fetched rows.
    struct Context {
        let groupByIdentity: [String: DurableCategoryGroup]
        let accountTypeByIdentity: [String: FinancialAccountType]
        let categoryByCanonicalID: [String: DurableCanonicalCategory]

        init(
            groups: [DurableCategoryGroup],
            categories: [DurableCanonicalCategory],
            accounts: [CachedFinancialAccount]
        ) {
            groupByIdentity = Dictionary(
                groups.sorted { $0.updatedAt > $1.updatedAt }
                    .map { ($0.groupIdentity, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            accountTypeByIdentity = Dictionary(
                accounts.map { ($0.canonicalAccountId, $0.type) },
                uniquingKeysWith: { first, _ in first }
            )
            categoryByCanonicalID = Dictionary(
                categories.map { ($0.canonicalId, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }

        func resolvedGroup(
            categoryCanonicalId: String?
        ) -> (identity: String, name: String) {
            guard let categoryCanonicalId,
                  let category = categoryByCanonicalID[categoryCanonicalId],
                  let identity = category.categoryGroupIdentity,
                  let group = groupByIdentity[identity],
                  SpendingGroupSetup.isUserGroup(group) else {
                return (
                    SpendingGroupSetup.unassignedIdentity,
                    SpendingGroupSetup.unassignedName
                )
            }
            return (identity, group.name)
        }
    }

    // MARK: Stage 1 — assembly

    /// Maps approved rows to entries. Split legs map one entry each; internal
    /// transfers are omitted; investment rows use the cash side.
    static func assembleEntries(
        rows: [CachedFinancialTransaction],
        context: Context
    ) -> [SpendingHistoryEntry] {
        var entries: [SpendingHistoryEntry] = []
        for row in rows {
            // Corrupt split JSON and unknown future raw types fail closed:
            // neither can be reinterpreted as a normal unsplit expense.
            if row.subtransactionsDecodeFailed
                || (!row.isSplit && row.forecastTreatment == .unknown) {
                continue
            }
            if row.forecastTreatment == .reimbursement
                || row.forecastTreatment == .goalSpend
                || row.forecastTreatment == .goalRefund {
                continue
            }
            if row.forecastTreatment == .internalTransfer {
                // Moving money between owned accounts is not spending or
                // savings activity. Goal funding comes from explicit reserve
                // account selection and allocations, never transfer rows.
                continue
            }
            if row.forecastTreatment == .investmentContribution {
                // Count the linked cash-account side only. If a provider also
                // exposes the investment-account counterpart, ignoring it
                // prevents the contribution from cancelling itself out.
                guard context.accountTypeByIdentity[row.canonicalAccountId]?
                        .isCashLike == true else { continue }
                entries.append(SpendingHistoryEntry(
                    transactionId: row.id,
                    date: row.postedDate,
                    amountMilliunits: row.amountMilliunits,
                    treatment: .investmentContribution,
                    reportingRole: .investment,
                    groupIdentity:
                        SpendingGroupSetup.investmentReportingIdentity,
                    groupName: SpendingGroupSetup.investmentReportingName,
                    categoryKey:
                        SpendingGroupSetup.investmentReportingIdentity,
                    categoryName: SpendingGroupSetup.investmentReportingName
                ))
                continue
            }
            let legs = row.subtransactions
            if legs.isEmpty {
                let group = context.resolvedGroup(
                    categoryCanonicalId: row.categoryCanonicalId
                )
                entries.append(SpendingHistoryEntry(
                    transactionId: row.id,
                    date: row.postedDate,
                    amountMilliunits: row.amountMilliunits,
                    treatment: row.forecastTreatment,
                    reportingRole: .spending,
                    groupIdentity: group.identity,
                    groupName: group.name,
                    categoryKey: row.categoryCanonicalId
                        ?? "name:\(row.categoryName ?? "Uncategorized")",
                    categoryName: row.categoryName ?? "Uncategorized"
                ))
            } else {
                for leg in legs where !leg.deleted {
                    // Confirmed splits persist the canonical identity in
                    // `categoryId`; reference-suggested splits use
                    // `categoryCanonicalId`. Accept either.
                    let legCanonicalId = leg.categoryCanonicalId
                        ?? leg.categoryId
                    let group = context.resolvedGroup(
                        categoryCanonicalId: legCanonicalId
                    )
                    entries.append(SpendingHistoryEntry(
                        transactionId: row.id,
                        date: row.postedDate,
                        amountMilliunits: leg.amount.milliunits,
                        // An unmarked part of an INCOMING split must not
                        // inherit the whole-transaction Reimbursement label
                        // and offset spending; nil excludes it. Outgoing
                        // splits are ordinary spending either way.
                        treatment: leg.forecastTreatment
                            ?? (row.amountMilliunits < 0
                                ? row.forecastTreatment
                                : nil),
                        reportingRole: .spending,
                        groupIdentity: group.identity,
                        groupName: group.name,
                        categoryKey: legCanonicalId
                            ?? "name:\(leg.categoryName ?? "Uncategorized")",
                        categoryName: leg.categoryName ?? "Uncategorized"
                    ))
                }
            }
        }
        return entries
    }

    // MARK: Stage 2 — goal-assignment resolution

    /// Resolves ledger external ids to cached row ids and folds purchase and
    /// refund entries into per-transaction magnitudes. Ledger rows whose
    /// external id matches no cached row resolve to nothing (orphans are
    /// surfaced separately by the Goals build).
    static func resolveAssignments(
        ledgerEntries: [DurableGoalLedgerEntry],
        rows: [CachedFinancialTransaction]
    ) -> GoalPurchaseAssignments {
        var rowIdByExternalId: [String: String] = [:]
        for row in rows where !row.externalId.isEmpty {
            rowIdByExternalId[row.externalId] = row.id
        }
        var purchases: [String: Int64] = [:]
        var refunds: [String: Int64] = [:]
        for entry in ledgerEntries {
            guard let externalId = entry.linkedTransactionExternalId,
                  let rowId = rowIdByExternalId[externalId] else { continue }
            switch entry.kind {
            case .purchase where entry.amountMilliunits < 0:
                purchases[rowId, default: 0] += -entry.amountMilliunits
            case .purchaseRefund where entry.amountMilliunits > 0:
                refunds[rowId, default: 0] += entry.amountMilliunits
            default:
                continue
            }
        }
        return GoalPurchaseAssignments(
            purchasesByTransactionId: purchases,
            refundsByTransactionId: refunds
        )
    }

    /// The full pipeline. `ledgerEntries` may be empty (no goals yet) — the
    /// result is then identical to the pre-Goals behavior.
    static func adjustedEntries(
        rows: [CachedFinancialTransaction],
        ledgerEntries: [DurableGoalLedgerEntry],
        context: Context
    ) -> [SpendingHistoryEntry] {
        let assembled = assembleEntries(rows: rows, context: context)
        return GoalPurchaseAdjuster.apply(
            entries: assembled,
            assignments: resolveAssignments(
                ledgerEntries: ledgerEntries, rows: rows
            )
        )
    }

    /// The assignable ceiling for one transaction, for entry validation and
    /// the purchase-marking UI: the sum of the row's negative ordinary
    /// entries minus what other assignments already consumed.
    static func remainingAdjustableAmount(
        row: CachedFinancialTransaction,
        existingLedgerEntries: [DurableGoalLedgerEntry],
        context: Context
    ) -> Money {
        let entries = assembleEntries(rows: [row], context: context)
        let ceiling = GoalPurchaseAdjuster.adjustableAmount(
            entries: entries, transactionId: row.id
        )
        let externalId = row.externalId
        guard !externalId.isEmpty else { return ceiling }
        let assigned = existingLedgerEntries.reduce(Int64(0)) { sum, entry in
            guard entry.linkedTransactionExternalId == externalId,
                  entry.kind == .purchase,
                  entry.amountMilliunits < 0 else { return sum }
            return sum - entry.amountMilliunits
        }
        return max(ceiling - Money(milliunits: assigned), .zero)
    }
}
