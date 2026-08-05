import Foundation
import NetworthCore
import SwiftData
import os

/// User-initiated "Build YNAB Reference" import.
///
/// Fetches YNAB data with the retained token — never during normal launch or
/// sync — scoped per reconciled account to that account's imported Plaid
/// coverage window, matches YNAB history against cached Plaid transactions,
/// and writes `YNABReferenceSuggestion` rows plus Networth-owned canonical
/// payees, category groups, and categories. Every match is a suggestion, not
/// a reviewed decision; confirmed user decisions are never overwritten.
///
/// Raw YNAB responses are processed in memory and discarded: no
/// `CachedTransaction`, `CachedCategory`, or other YNAB cache rows are
/// persisted by this flow. Re-running deletes and rebuilds every suggestion
/// row, so the reference table is always reproducible from source data.
/// Lightweight, never-persisted YNAB account identity used by the mapping
/// sheet after the clean start (when no YNAB cache exists).
public struct YNABAccountOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let kind: AccountKind

    public init(id: String, name: String, kind: AccountKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

@MainActor
@Observable
public final class YNABReferenceImportCoordinator {
    public enum Phase: Equatable {
        case idle
        case running(String)
        case error(String)
        case completed(String)
    }

    public private(set) var phase: Phase = .idle

    private let client: any YNABClient
    private let mainContext: ModelContext
    private let logger = Logger(
        subsystem: "com.bluelava.me.networth", category: "ynabReference"
    )

    public init(client: any YNABClient, mainContext: ModelContext) {
        self.client = client
        self.mainContext = mainContext
    }

    @discardableResult
    public func buildReference() async -> Bool {
        if case .running = phase { return false }
        // The importer shares the main model context: a concurrent Plaid
        // sync could commit this flow's partial directory writes (or lose
        // its own on our rollback). Refuse to overlap.
        if let plaidCoordinator, case .syncing = plaidCoordinator.phase {
            phase = .error("Wait for the current sync to finish, then try again.")
            return false
        }
        phase = .running("Preparing")

        // Scope prerequisites: reviewed Plaid→YNAB account mappings and
        // per-account Plaid coverage. Never use a global history window.
        let bindings = ((try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalAccountBinding>()
        )) ?? []).filter { $0.reviewed && $0.ynabAccountId != nil }
        guard !bindings.isEmpty else {
            phase = .error("Map your Plaid accounts to their YNAB accounts first.")
            return false
        }
        let coverageRows = (try? mainContext.fetch(
            FetchDescriptor<PlaidAccountCoverage>()
        )) ?? []
        let coverageByPlaidID = Dictionary(
            uniqueKeysWithValues: coverageRows.map { ($0.plaidAccountId, $0) }
        )
        let scopedBindings = bindings.filter { binding in
            guard let coverage = coverageByPlaidID[binding.plaidAccountId] else {
                return false
            }
            return coverage.earliestImportedDate != nil
                && coverage.latestImportedDate != nil
        }
        guard !scopedBindings.isEmpty else {
            phase = .error("Sync your Plaid transactions first so the import window is known.")
            return false
        }

        do {
            phase = .running("Loading budget")
            let budgets = try await client.budgets()
            guard let budgetId = try selectBudgetId(from: budgets) else {
                phase = .error("No YNAB budget is available for this token.")
                return false
            }

            phase = .running("Importing categories")
            let categoriesResponse = try await client.categories(
                budgetId: budgetId, lastKnowledge: nil
            )
            seedCategoryGroupsAndCategories(categoriesResponse.category_groups)
            ensureRoleGroupsExist()

            phase = .running("Importing contacts")
            let payeesResponse = try await client.payees(
                budgetId: budgetId, lastKnowledge: nil
            )
            seedCanonicalPayees(payeesResponse.payees)

            // Per-account, coverage-scoped transaction fetch. YNAB-only
            // dates and unmapped accounts never enter the reference process.
            var dtoByID: [String: YNABTransactionDTO] = [:]
            var legacySummaries: [TransactionSummary] = []
            var ynabMap: [String: String] = [:]
            for binding in scopedBindings {
                guard let ynabAccountId = binding.ynabAccountId,
                      let coverage = coverageByPlaidID[binding.plaidAccountId],
                      let earliest = coverage.earliestImportedDate,
                      let latest = coverage.latestImportedDate else {
                    continue
                }
                phase = .running("Importing \(binding.accountName)")
                ynabMap[ynabAccountId] = binding.canonicalAccountId
                // Fetch with the matcher's ±3-day slack on BOTH bounds so a
                // YNAB row dated just before the earliest Plaid posting can
                // still match it.
                let windowStart = Calendar.current.date(
                    byAdding: .day, value: -3, to: earliest
                ) ?? earliest
                let response = try await client.transactions(
                    budgetId: budgetId,
                    accountId: ynabAccountId,
                    sinceDate: windowStart,
                    lastKnowledge: nil
                )
                // Clip to the imported Plaid window (plus the matcher's date
                // slack) so YNAB-only history stays out of the reference.
                let windowEnd = Calendar.current.date(
                    byAdding: .day, value: 3, to: latest
                ) ?? latest
                for dto in response.transactions where !dto.deleted {
                    guard let summary = dto.toSummary(),
                          summary.date <= windowEnd else { continue }
                    dtoByID[summary.id] = dto
                    legacySummaries.append(summary)
                }
            }

            phase = .running("Matching history")
            let scopedCanonicalIDs = Set(ynabMap.values)
            let plaidRows = ((try? mainContext.fetch(
                FetchDescriptor<CachedFinancialTransaction>(
                    predicate: #Predicate { !$0.deleted && !$0.pending }
                )
            )) ?? []).filter {
                scopedCanonicalIDs.contains($0.canonicalAccountId)
            }
            let matches = HistoricalTransactionMatcher().matches(
                legacy: legacySummaries,
                plaid: plaidRows.map { $0.toSummary() },
                canonicalAccountIdByYNABId: ynabMap
            )

            phase = .running("Writing suggestions")
            let written = try rebuildSuggestions(
                matches: matches,
                dtoByID: dtoByID,
                creditCardYNABIds: Set(
                    scopedBindings
                        .filter { $0.accountType == .creditCard }
                        .compactMap(\.ynabAccountId)
                )
            )

            // Re-apply the canonical state so suggestions prefill unreviewed
            // rows immediately, then persist everything in one save.
            plaidCoordinator?.reapplyCanonicalStateAfterReferenceImport()
            guard mainContext.safeSave(source: "ynabReference.build") else {
                mainContext.rollback()
                phase = .error("Saving the reference data failed. Try again.")
                return false
            }
            let summary = "\(written) suggestions across \(scopedBindings.count) accounts"
            logger.notice("YNAB reference built: \(summary, privacy: .public)")
            phase = .completed(summary)
            return true
        } catch {
            mainContext.rollback()
            logger.error("YNAB reference import failed: \(error.localizedDescription, privacy: .public)")
            phase = .error("The YNAB import failed. Check the token and try again.")
            return false
        }
    }

    /// Set after init by the container so the import can trigger a canonical
    /// re-apply without owning the transaction coordinator.
    public weak var plaidCoordinator: PlaidTransactionSyncCoordinator?

    /// In-memory YNAB account directory for the mapping step. Nothing is
    /// persisted — the raw response is discarded when the sheet closes.
    public func fetchAccountOptions() async -> [YNABAccountOption] {
        do {
            let budgets = try await client.budgets()
            guard let budgetId = try selectBudgetId(from: budgets) else {
                return []
            }
            let response = try await client.accounts(
                budgetId: budgetId, lastKnowledge: nil
            )
            return response.accounts
                .filter { !$0.closed && !$0.deleted }
                .map {
                    YNABAccountOption(
                        id: $0.id,
                        name: $0.name,
                        kind: AccountKind.fromYNAB($0.type)
                    )
                }
                .sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name)
                        == .orderedAscending
                }
        } catch {
            logger.error("YNAB account fetch failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    // MARK: - Budget

    private func selectBudgetId(from budgets: [YNABBudgetSummary]) throws -> String? {
        let settings = try? mainContext.fetch(
            FetchDescriptor<DurableUserSettings>()
        ).first
        if let selected = settings?.selectedBudgetId,
           budgets.contains(where: { $0.id == selected }) {
            return selected
        }
        // With no persisted selection, prefer the most recently modified
        // budget — the active one in practice — over YNAB's array order.
        let candidate = budgets.max(by: {
            ($0.last_modified_on ?? "") < ($1.last_modified_on ?? "")
        }) ?? budgets.first
        guard let candidate else { return nil }
        settings?.selectedBudgetId = candidate.id
        return candidate.id
    }

    // MARK: - Directory seeding (Networth-owned after import)

    private func seedCanonicalPayees(_ payees: [YNABPayeeDTO]) {
        let existing = (try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalPayee>()
        )) ?? []
        let byYNABID = Dictionary(
            uniqueKeysWithValues: existing.compactMap { row in
                row.ynabPayeeId.map { ($0, row) }
            }
        )
        for payee in payees where !payee.deleted {
            if let row = byYNABID[payee.id] {
                row.sourceName = payee.name
                if !row.userEdited { row.name = payee.name }
                row.updatedAt = .now
            } else {
                mainContext.insert(DurableCanonicalPayee(
                    canonicalId: "ynab:\(payee.id)",
                    ynabPayeeId: payee.id,
                    name: payee.name,
                    sourceName: payee.name,
                    transferAccountId: payee.transfer_account_id
                ))
            }
        }
    }

    private func seedCategoryGroupsAndCategories(
        _ groups: [YNABCategoryGroupDTO]
    ) {
        let existingGroups = (try? mainContext.fetch(
            FetchDescriptor<DurableCategoryGroup>()
        )) ?? []
        let groupByIdentity = Dictionary(
            uniqueKeysWithValues: existingGroups.map { ($0.groupIdentity, $0) }
        )
        let existingCategories = (try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalCategory>()
        )) ?? []
        let categoryByYNABID = Dictionary(
            uniqueKeysWithValues: existingCategories.compactMap { row in
                row.ynabCategoryId.map { ($0, row) }
            }
        )

        for (index, group) in groups.enumerated() where !group.deleted {
            let identity = "ynab:\(group.id)"
            if groupByIdentity[identity] == nil {
                // Seed only; names, ordering, roles, and visibility belong
                // to Networth afterward — existing rows are never rewritten.
                mainContext.insert(DurableCategoryGroup(
                    groupIdentity: identity,
                    name: group.name,
                    displayOrder: index,
                    reportingRole: Self.inferredRole(forGroupName: group.name),
                    hidden: group.hidden
                ))
            }
            for category in group.categories where !category.deleted {
                if let row = categoryByYNABID[category.id] {
                    row.sourceName = category.name
                    row.sourceGroupName = group.name
                    // Grouping belongs to Networth after import: fill only a
                    // missing assignment, never move a category the user (or
                    // a prior import) already placed.
                    if row.categoryGroupIdentity == nil {
                        row.categoryGroupIdentity = identity
                    }
                    if !row.userEdited {
                        row.name = category.name
                        row.groupName = group.name
                        row.hidden = category.hidden || group.hidden
                    }
                    row.updatedAt = .now
                } else {
                    mainContext.insert(DurableCanonicalCategory(
                        canonicalId: "ynab:\(category.id)",
                        ynabCategoryId: category.id,
                        ynabGroupId: group.id,
                        name: category.name,
                        groupName: group.name,
                        sourceName: category.name,
                        sourceGroupName: group.name,
                        categoryGroupIdentity: identity,
                        hidden: category.hidden || group.hidden
                    ))
                }
            }
        }
    }

    static func inferredRole(forGroupName name: String) -> CategoryReportingRole {
        let lowered = name.lowercased()
        if lowered.contains("income") { return .income }
        if lowered.contains("invest") { return .investment }
        return .spending
    }

    /// YNAB budgets often have no explicit income or investment group (YNAB
    /// tracks inflows internally), yet the type-first contract needs a
    /// category of the matching role for income and investment activity.
    /// Guarantee one Networth-owned group + starter category per missing
    /// role. Additive: never touches existing rows.
    private func ensureRoleGroupsExist() {
        let groups = (try? mainContext.fetch(
            FetchDescriptor<DurableCategoryGroup>()
        )) ?? []
        let categories = (try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalCategory>()
        )) ?? []
        let fallbacks: [(role: CategoryReportingRole, identity: String,
                         groupName: String, categoryName: String)] = [
            (.income, "networth:income", "Income", "Income"),
            (.investment, "networth:investments", "Investments",
             "Investment Contributions")
        ]
        for fallback in fallbacks {
            guard !groups.contains(where: {
                $0.reportingRole == fallback.role && !$0.hidden
            }) else { continue }
            if !groups.contains(where: {
                $0.groupIdentity == fallback.identity
            }) {
                mainContext.insert(DurableCategoryGroup(
                    groupIdentity: fallback.identity,
                    name: fallback.groupName,
                    displayOrder: groups.count,
                    reportingRole: fallback.role
                ))
            }
            let categoryCanonicalId = "networth:\(fallback.identity)-default"
            if !categories.contains(where: {
                $0.canonicalId == categoryCanonicalId
            }) {
                mainContext.insert(DurableCanonicalCategory(
                    canonicalId: categoryCanonicalId,
                    name: fallback.categoryName,
                    groupName: fallback.groupName,
                    categoryGroupIdentity: fallback.identity
                ))
            }
        }
    }

    // MARK: - Suggestions

    private func rebuildSuggestions(
        matches: [HistoricalTransactionMatch],
        dtoByID: [String: YNABTransactionDTO],
        creditCardYNABIds: Set<String>
    ) throws -> Int {
        // The reference table is rebuildable evidence: delete and rebuild.
        for row in (try? mainContext.fetch(
            FetchDescriptor<YNABReferenceSuggestion>()
        )) ?? [] {
            mainContext.delete(row)
        }

        let payees = (try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalPayee>()
        )) ?? []
        let payeeByYNABID = Dictionary(
            uniqueKeysWithValues: payees.compactMap { row in
                row.ynabPayeeId.map { ($0, row) }
            }
        )
        let categories = (try? mainContext.fetch(
            FetchDescriptor<DurableCanonicalCategory>()
        )) ?? []
        let categoryByYNABID = Dictionary(
            uniqueKeysWithValues: categories.compactMap { row in
                row.ynabCategoryId.map { ($0, row) }
            }
        )

        var written = 0
        for match in matches {
            guard let dto = dtoByID[match.legacyTransactionId],
                  let summary = dto.toSummary() else { continue }
            let payee = dto.payee_id.flatMap { payeeByYNABID[$0] }
            let category = dto.category_id.flatMap { categoryByYNABID[$0] }
            let splitData: Data?
            if summary.isSplit {
                let legs = summary.subtransactions.map { leg in
                    SubTransactionSummary(
                        id: leg.id,
                        amount: leg.amount,
                        categoryId: leg.categoryId,
                        categoryName: leg.categoryName,
                        categoryCanonicalId: leg.categoryId.map { "ynab:\($0)" },
                        forecastTreatment: leg.forecastTreatment,
                        transferAccountId: leg.transferAccountId,
                        payeeName: leg.payeeName,
                        memo: leg.memo,
                        deleted: leg.deleted
                    )
                }
                splitData = try? JSONEncoder().encode(legs)
            } else {
                splitData = nil
            }
            mainContext.insert(YNABReferenceSuggestion(
                plaidTransactionId: match.plaidTransactionId,
                ynabTransactionId: match.legacyTransactionId,
                payeeCanonicalId: payee?.canonicalId,
                payeeNameSnapshot: payee?.name
                    ?? summary.payeeName?.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ) ?? "",
                categoryCanonicalId: category?.canonicalId,
                categoryNameSnapshot: category?.name ?? summary.categoryName,
                forecastTreatment: Self.treatment(
                    for: summary, creditCardYNABIds: creditCardYNABIds
                ),
                subtransactionsData: splitData,
                confidence: match.confidence,
                score: match.score,
                strong: match.isAutomatic
            ))
            written += 1
        }
        return written
    }

    static func treatment(
        for summary: TransactionSummary,
        creditCardYNABIds: Set<String>
    ) -> ForecastTreatment {
        if let transfer = summary.transferAccountId {
            return creditCardYNABIds.contains(summary.accountId)
                || creditCardYNABIds.contains(transfer)
                ? .cardPayment
                : .internalTransfer
        }
        if summary.amount.milliunits < 0 { return .ordinarySpending }
        if summary.categoryName?.localizedCaseInsensitiveContains("income")
            == true {
            return .income
        }
        return .refund
    }
}
