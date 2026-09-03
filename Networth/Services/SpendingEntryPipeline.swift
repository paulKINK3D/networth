import Foundation
import SwiftData
import NetworthCore

struct SpendingSinkingFundLineKey: Hashable, Sendable {
    let transactionID: String
    let subtransactionID: String?
}

struct SpendingSinkingFundAttribution: Hashable, Sendable {
    let fundID: String
    let fundName: String
}

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
        let savingsGroup: (identity: String, name: String)?
        let savingsTransferMonthByTransactionID: [String: BudgetMonth]
        let excludedSavingsAccountIDs: Set<String>
        let sinkingFundByLine: [
            SpendingSinkingFundLineKey: SpendingSinkingFundAttribution
        ]

        init(
            groups: [DurableCategoryGroup],
            categories: [DurableCanonicalCategory],
            accounts: [CachedFinancialAccount],
            savingsGroup: (identity: String, name: String)? = nil,
            savingsTransferMonthByTransactionID: [String: BudgetMonth] = [:],
            excludedSavingsAccountIDs: Set<String> = [],
            sinkingFundByLine: [
                SpendingSinkingFundLineKey: SpendingSinkingFundAttribution
            ] = [:]
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
            self.savingsGroup = savingsGroup
            self.savingsTransferMonthByTransactionID =
                savingsTransferMonthByTransactionID
            self.excludedSavingsAccountIDs = excludedSavingsAccountIDs
            self.sinkingFundByLine = sinkingFundByLine
        }


        func sinkingFund(
            transactionID: String,
            subtransactionID: String?
        ) -> SpendingSinkingFundAttribution? {
            sinkingFundByLine[SpendingSinkingFundLineKey(
                transactionID: transactionID,
                subtransactionID: subtransactionID
            )] ?? sinkingFundByLine[SpendingSinkingFundLineKey(
                transactionID: transactionID,
                subtransactionID: nil
            )]
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
            if !row.isSplit,
               LegacyReimbursementRepresentation.matchesWholeTransaction(
                   treatmentRaw: row.forecastTreatmentRaw,
                   categoryCanonicalId: row.categoryCanonicalId,
                   categoryRaw: row.nativeCategoryRaw,
                   categoryName: row.categoryName,
                   goalId: row.goalId
               ) {
                continue
            }
            if row.forecastTreatment == .reimbursement
                || row.forecastTreatment == .goalSpend
                || row.forecastTreatment == .goalRefund {
                continue
            }
            if row.forecastTreatment == .internalTransfer {
                // Only the savings-account side contributes to the explicitly
                // designated Savings budget. The checking side is omitted so
                // one transfer cannot count twice, and goal reserve accounts
                // retain their separate ledger semantics.
                guard let savingsGroup = context.savingsGroup,
                      context.accountTypeByIdentity[row.canonicalAccountId]
                        == .savings,
                      !context.excludedSavingsAccountIDs.contains(
                        row.canonicalAccountId
                      ),
                      row.amountMilliunits != 0 else {
                    continue
                }
                let date = context.savingsTransferMonthByTransactionID[row.id]?
                    .startDate() ?? row.postedDate
                entries.append(SpendingHistoryEntry(
                    transactionId: row.id,
                    date: date,
                    amountMilliunits: row.amountMilliunits,
                    treatment: .internalTransfer,
                    reportingRole: .transfer,
                    groupIdentity: savingsGroup.identity,
                    groupName: savingsGroup.name,
                    categoryKey: "networth:savings-transfers",
                    categoryName: "Savings Transfers"
                ))
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
                let fund = context.sinkingFund(
                    transactionID: row.id,
                    subtransactionID: nil
                )
                // The source budget was charged when this money was assigned
                // to the Reserve. The later purchase drains only that carried
                // balance and must not reduce monthly Spending or Retained a
                // second time.
                guard fund == nil else { continue }
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
                    let fund = context.sinkingFund(
                        transactionID: row.id,
                        subtransactionID: leg.id
                    )
                    guard fund == nil else { continue }
                    let treatment = LegacyReimbursementRepresentation
                        .matches(leg)
                        ? TransactionType.reimbursement
                        : leg.forecastTreatment
                            ?? (row.amountMilliunits < 0
                                ? row.forecastTreatment
                                : nil)
                    if treatment == .goalSpend
                        || treatment == .goalRefund {
                        continue
                    }
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
                        treatment: treatment,
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

/// Main-context writer for explicit monthly reserve assignments and reversible
/// purchase confirmations. Imported transaction rows remain untouched.
@MainActor
struct SpendingSinkingFundLedgerService {
    let context: ModelContext

    @discardableResult
    func saveAssignment(
        id: UUID? = nil,
        fundID: UUID,
        month: BudgetMonth,
        sourceGroupIdentity: String,
        amount: Money,
        maximum: Money
    ) -> Bool {
        guard amount > .zero,
              amount <= maximum,
              !sourceGroupIdentity.isEmpty else {
            return false
        }
        let rows = (try? context.fetch(
            FetchDescriptor<DurableSpendingSinkingFundContribution>()
        )) ?? []
        let matches = id.map { id in rows.filter { $0.id == id } } ?? []
        if id == nil {
            context.insert(DurableSpendingSinkingFundContribution(
                fundId: fundID,
                budgetYear: month.year,
                budgetMonth: month.month,
                sourceGroupIdentity: sourceGroupIdentity,
                amountMilliunits: amount.milliunits,
                active: amount > .zero
            ))
        } else {
            guard !matches.isEmpty else { return false }
            for row in matches {
                row.fundId = fundID
                row.budgetYear = month.year
                row.budgetMonth = month.month
                row.sourceGroupIdentity = sourceGroupIdentity
                row.amountMilliunits = amount.milliunits
                row.active = true
                row.origin = .explicit
                row.updatedAt = .now
            }
        }
        return context.safeSave(
            source: "spending.reserve.saveAssignment"
        )
    }

    @discardableResult
    func removeAssignment(
        _ assignment: DurableSpendingSinkingFundContribution
    ) -> Bool {
        assignment.active = false
        assignment.updatedAt = .now
        return context.safeSave(
            source: "spending.reserve.removeAssignment"
        )
    }

    @discardableResult
    func assign(
        fundID: UUID,
        transactionID: String,
        subtransactionID: String?,
        date: Date,
        amount: Money
    ) -> Bool {
        let rows = (try? context.fetch(
            FetchDescriptor<DurableSpendingSinkingFundExpense>()
        )) ?? []
        let matches = rows.filter {
            $0.transactionId == transactionID
                && $0.subtransactionId == subtransactionID
        }
        if matches.isEmpty {
            context.insert(DurableSpendingSinkingFundExpense(
                fundId: fundID,
                transactionId: transactionID,
                subtransactionId: subtransactionID,
                transactionDate: date,
                amountMilliunits: amount.absolute.milliunits
            ))
        } else {
            for row in matches {
                row.fundId = fundID
                row.transactionDate = date
                row.amountMilliunits = amount.absolute.milliunits
                row.active = true
                row.updatedAt = .now
            }
        }
        return context.safeSave(source: "spending.reserve.assignExpense")
    }

    @discardableResult
    func release(_ assignment: DurableSpendingSinkingFundExpense) -> Bool {
        let rows = (try? context.fetch(
            FetchDescriptor<DurableSpendingSinkingFundExpense>()
        )) ?? []
        for row in rows where row.transactionId == assignment.transactionId
            && row.subtransactionId == assignment.subtransactionId {
            row.active = false
            row.updatedAt = .now
        }
        return context.safeSave(source: "spending.reserve.releaseExpense")
    }
}
