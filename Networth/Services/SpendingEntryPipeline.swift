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

struct SpendingSavingsLineKey: Hashable, Sendable {
    let transactionID: String
    let subtransactionID: String?
}

struct SpendingSavingsAttribution: Hashable, Sendable {
    let groupIdentity: String
    let groupName: String
    let month: BudgetMonth
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
        let savingsAttributionByLine: [
            SpendingSavingsLineKey: SpendingSavingsAttribution
        ]
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
            savingsAttributionByLine: [
                SpendingSavingsLineKey: SpendingSavingsAttribution
            ] = [:],
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
            var attributions = savingsAttributionByLine
            if let savingsGroup {
                for (transactionID, month) in
                    savingsTransferMonthByTransactionID {
                    attributions[SpendingSavingsLineKey(
                        transactionID: transactionID,
                        subtransactionID: nil
                    )] = SpendingSavingsAttribution(
                        groupIdentity: savingsGroup.identity,
                        groupName: savingsGroup.name,
                        month: month
                    )
                }
            }
            self.savingsAttributionByLine = attributions
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

        func savings(
            transactionID: String,
            subtransactionID: String?
        ) -> SpendingSavingsAttribution? {
            savingsAttributionByLine[SpendingSavingsLineKey(
                transactionID: transactionID,
                subtransactionID: subtransactionID
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
                // Only explicitly month-assigned legacy deposits remain.
                // Broad account-type inference is intentionally retired.
                guard let savings = context.savings(
                    transactionID: row.id,
                    subtransactionID: nil
                ),
                      context.accountTypeByIdentity[row.canonicalAccountId]
                        == .savings,
                      !context.excludedSavingsAccountIDs.contains(
                        row.canonicalAccountId
                      ),
                      row.amountMilliunits != 0 else {
                    continue
                }
                entries.append(SpendingHistoryEntry(
                    transactionId: row.id,
                    date: savings.month.startDate(),
                    amountMilliunits: row.amountMilliunits,
                    treatment: .internalTransfer,
                    reportingRole: .transfer,
                    groupIdentity: savings.groupIdentity,
                    groupName: savings.groupName,
                    categoryKey: "networth:savings-transfers",
                    categoryName: "Savings Transfers"
                ))
                continue
            }
            if !row.isSplit, row.forecastTreatment == .savings {
                guard let savings = context.savings(
                    transactionID: row.id,
                    subtransactionID: nil
                ), row.amountMilliunits < 0 else { continue }
                entries.append(SpendingHistoryEntry(
                    transactionId: row.id,
                    date: savings.month.startDate(),
                    amountMilliunits: row.amountMilliunits,
                    treatment: .savings,
                    reportingRole: .transfer,
                    groupIdentity: savings.groupIdentity,
                    groupName: savings.groupName,
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
                    if treatment == .savings {
                        guard let savings = context.savings(
                            transactionID: row.id,
                            subtransactionID: leg.id
                        ), leg.amount < .zero else { continue }
                        entries.append(SpendingHistoryEntry(
                            transactionId: row.id,
                            date: savings.month.startDate(),
                            amountMilliunits: leg.amount.milliunits,
                            treatment: .savings,
                            reportingRole: .transfer,
                            groupIdentity: savings.groupIdentity,
                            groupName: savings.groupName,
                            categoryKey: "networth:savings-transfers",
                            categoryName: "Savings Transfers"
                        ))
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
    func setArchived(_ archived: Bool, fundID: UUID) -> Bool {
        guard let funds = try? context.fetch(
            FetchDescriptor<DurableSpendingSinkingFund>()
        ) else { return false }
        let matches = funds.filter { $0.id == fundID }
        guard !matches.isEmpty else { return false }
        let now = Date.now
        for fund in matches {
            fund.archived = archived
            fund.updatedAt = now
        }
        guard context.safeSave(
            source: archived
                ? "spending.reserve.archive"
                : "spending.reserve.restore"
        ) else {
            context.rollback()
            return false
        }
        return true
    }

    /// Permanently removes one Reserve planning construct. Imported
    /// transactions are deliberately not touched; deleting expense overlays
    /// returns those purchases to their ordinary monthly-budget treatment.
    @discardableResult
    func deleteFund(fundID: UUID) -> Bool {
        guard let funds = try? context.fetch(
            FetchDescriptor<DurableSpendingSinkingFund>()
        ), let contributions = try? context.fetch(
            FetchDescriptor<DurableSpendingSinkingFundContribution>()
        ), let expenses = try? context.fetch(
            FetchDescriptor<DurableSpendingSinkingFundExpense>()
        ) else { return false }
        let matchingFunds = funds.filter { $0.id == fundID }
        guard !matchingFunds.isEmpty else { return false }

        for row in contributions where row.fundId == fundID {
            context.delete(row)
        }
        for row in expenses where row.fundId == fundID {
            context.delete(row)
        }
        for fund in matchingFunds {
            context.delete(fund)
        }
        guard context.safeSave(source: "spending.reserve.delete") else {
            context.rollback()
            return false
        }
        return true
    }

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
