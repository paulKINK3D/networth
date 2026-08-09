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

}
