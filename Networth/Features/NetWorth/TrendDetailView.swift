import SwiftUI
    import SwiftData
import NetworthCore

private func label(for kind: AccountKind) -> String {
    switch kind {
    case .checking:        return "Checking"
    case .savings:         return "Savings"
    case .cash:            return "Cash"
    case .creditCard:      return "Credit Card"
    case .lineOfCredit:    return "Line of Credit"
    case .otherAsset:      return "Other Asset"
    case .otherLiability:  return "Other Liability"
    case .mortgage:        return "Mortgage"
    case .autoLoan:        return "Auto Loan"
    case .studentLoan:     return "Student Loan"
    case .personalLoan:    return "Personal Loan"
    case .medicalDebt:     return "Medical Debt"
    case .otherDebt:       return "Other Debt"
    case .investment:      return "Investment"
    case .unknown:         return "Unknown"
    }
}

/// Diagnostic sheet for the Net Worth trend chart. Lets the user inspect:
///   - Which accounts currently contribute to the reconstruction (same filter
///     the backfill uses: `!deleted && !closed`, scoped to the selected budget).
///   - How many snapshots exist per month and the month-end net worth value.
///   - The split between `.live` and `.backfill` rows in the durable store.
///
/// Tapping a contributing account pushes a per-account view showing that
/// account's reconstructed month-end balances — useful for tracing which
/// account is producing a surprising dip or spike in the chart.
struct TrendDetailView: View {
    @Environment(AppContainerController.self) private var container
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \DurableNetWorthSnapshot.date, order: .forward)
    private var snapshots: [DurableNetWorthSnapshot]
    @Query(sort: \CachedAccount.balanceMilliunits, order: .reverse)
    private var allAccounts: [CachedAccount]
    @Query private var userSettings: [DurableUserSettings]
    @Query(sort: \DurableManualAsset.name)
    private var manualAssets: [DurableManualAsset]
    @Query private var includedClosed: [DurableIncludedClosedAccount]

    private let calendar = Calendar(identifier: .gregorian)
    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        return f
    }()

    var body: some View {
        NavigationStack {
            List {
                if contributingAccounts.isEmpty {
                    Section {
                        Text("No accounts in the current budget. Sync to populate.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(contributingAccounts) { account in
                            NavigationLink {
                                AccountTrendDetailView(accountId: account.id, accountName: account.name)
                                    .environment(container)
                            } label: {
                                accountRow(account)
                            }
                        }
                    } header: {
                        Text("Contributing Accounts (\(contributingAccounts.count))")
                    } footer: {
                        Text("Closed and deleted accounts are excluded from the chart. Open YNAB to change account state.")
                    }
                }

                Section {
                    if monthlyBuckets.isEmpty {
                        Text("No snapshots yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(monthlyBuckets, id: \.monthStart) { bucket in
                            HStack {
                                Text(Self.monthFormatter.string(from: bucket.monthStart))
                                Spacer()
                                Text("\(bucket.snapshotCount) snap")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                Text(CurrencyFormatter.compact(bucket.endValue))
                                    .monospacedDigit()
                                    .foregroundStyle(bucket.endValue < .zero ? NwAppColors.liability : .primary)
                            }
                        }
                    }
                } header: {
                    Text("Monthly Net Worth (\(monthlyBuckets.count) months)")
                } footer: {
                    Text("Shows the last snapshot value recorded in each month. Tap an account above to see that account's contribution to the totals.")
                }

                if !overlapHints.isEmpty {
                    Section {
                        ForEach(overlapHints, id: \.id) { hint in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hint.label)
                                    .font(NwTypography.body)
                                Text(hint.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        Text("Possible Double-Count")
                    } footer: {
                        Text("Manual-asset entries that overlap with the same-name (or similarly-named) closed YNAB accounts you've opted into. If your chart shows a peak then drop, this is the likely cause. Trim the manual-asset earliest entry to the YNAB closure date, or untick the closed account in Settings → Include Closed Accounts.")
                    }
                }

                if !manualAssetContributions.isEmpty {
                    Section {
                        ForEach(manualAssetContributions, id: \.id) { entry in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name)
                                        .font(NwTypography.body)
                                    Text("From \(entry.firstEntryLabel)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(CurrencyFormatter.compact(entry.currentValue))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("Manual Asset Contributions")
                    } footer: {
                        Text("Each manual asset adds its value to days on or after its earliest entry. Edit the asset to delete or move that earliest entry forward.")
                    }
                }

                if !includedClosedContributions.isEmpty {
                    Section {
                        ForEach(includedClosedContributions, id: \.id) { entry in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name)
                                        .font(NwTypography.body)
                                    Text(entry.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                    } header: {
                        Text("Included Closed Accounts")
                    } footer: {
                        Text("Closed YNAB accounts you opted into. They contribute their walked-back historical balance until the day they hit $0 / closed in YNAB.")
                    }
                }

                Section {
                    HStack {
                        Text(".live")
                        Spacer()
                        Text("\(liveCount)").monospacedDigit().foregroundStyle(.secondary)
                    }
                    HStack {
                        Text(".backfill")
                        Spacer()
                        Text("\(backfillCount)").monospacedDigit().foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Backfill marker")
                        Spacer()
                        Text("\(userSettings.first?.historyBackfillVersion ?? 0)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Snapshot Store")
                } footer: {
                    Text(".live rows are written by the daily snapshot scheduler. .backfill rows are produced by the 24-month reconstruction. Force Full Resync (in Settings) wipes both and rebuilds.")
                }

            }
            .navigationTitle("Trend Detail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func accountRow(_ account: CachedAccount) -> some View {
        HStack {
            NwIcon.forAccountKind(account.typeRaw).image
                .foregroundStyle(NwAppColors.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .font(NwTypography.body)
                Text(label(for: account.kind))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(CurrencyFormatter.compact(account.balance))
                .monospacedDigit()
                .foregroundStyle(account.kind.isLiability ? NwAppColors.liability : .primary)
        }
    }

    // MARK: - Derived data: contributions & overlap

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    private struct ManualEntry {
        let id: UUID
        let name: String
        let firstEntryAt: Date?
        let currentValue: Money
        var firstEntryLabel: String {
            guard let date = firstEntryAt else { return "—" }
            return TrendDetailView.shortDateFormatter.string(from: date)
        }
    }

    private struct ClosedEntry {
        let id: String
        let name: String
        let detail: String
    }

    private struct OverlapHint {
        let id: String
        let label: String
        let detail: String
    }

    private var manualAssetContributions: [ManualEntry] {
        manualAssets.filter { !$0.deleted }.map { asset in
            ManualEntry(
                id: asset.id,
                name: asset.name.isEmpty ? "Untitled" : asset.name,
                firstEntryAt: asset.sortedValues.first?.recordedAt,
                currentValue: asset.currentValue
            )
        }
        .sorted { ($0.firstEntryAt ?? .distantPast) < ($1.firstEntryAt ?? .distantPast) }
    }

    private var includedClosedContributions: [ClosedEntry] {
        let selectedIds = Set(includedClosed.map { $0.accountId })
        return allAccounts
            .filter { !$0.deleted && $0.closed && selectedIds.contains($0.id) }
            .map { ClosedEntry(id: $0.id, name: $0.name, detail: "\(label(for: $0.kind)) · closed") }
    }

    /// Heuristic: flag every manual-asset / included-closed-account pair
    /// whose names share at least the first 3 characters (case-insensitive).
    /// Catches the common "Vanguard" manual ↔ "Vanguard Brokerage" closed
    /// YNAB overlap without doing balance reconciliation.
    private var overlapHints: [OverlapHint] {
        let manuals = manualAssetContributions
        let closed = includedClosedContributions
        var hints: [OverlapHint] = []
        for m in manuals {
            let mNorm = normalize(m.name)
            guard mNorm.count >= 3 else { continue }
            for c in closed {
                let cNorm = normalize(c.name)
                guard cNorm.count >= 3 else { continue }
                if mNorm.hasPrefix(cNorm.prefix(3)) || cNorm.hasPrefix(mNorm.prefix(3)) {
                    hints.append(OverlapHint(
                        id: "\(m.id.uuidString)-\(c.id)",
                        label: "\(m.name) ↔ \(c.name)",
                        detail: "Manual asset entries from \(m.firstEntryLabel) may double-count the closed YNAB account's reconstructed history."
                    ))
                }
            }
        }
        return hints
    }

    private func normalize(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Derived data

    private var selectedBudgetId: String? { container.selectedBudgetId }

    private var contributingAccounts: [CachedAccount] {
        allAccounts.filter { acc in
            !acc.deleted &&
            !acc.closed &&
            (selectedBudgetId == nil || acc.budgetId == selectedBudgetId)
        }
    }

    private var chartFloor: Date? {
        guard let raw = userSettings.first?.chartStartDate else { return nil }
        return calendar.startOfDay(for: raw)
    }

    private var visibleSnapshots: [DurableNetWorthSnapshot] {
        guard let floor = chartFloor else { return snapshots }
        return snapshots.filter { $0.date >= floor }
    }

    private var liveCount: Int { visibleSnapshots.filter { $0.source == .live }.count }
    private var backfillCount: Int { visibleSnapshots.filter { $0.source == .backfill }.count }

    private struct MonthlyBucket {
        let monthStart: Date
        let snapshotCount: Int
        let endValue: Money
    }

    private var monthlyBuckets: [MonthlyBucket] {
        let pool = visibleSnapshots
        guard !pool.isEmpty else { return [] }
        let groups = Dictionary(grouping: pool) { snap -> Date in
            let comps = calendar.dateComponents([.year, .month], from: snap.date)
            return calendar.date(from: comps) ?? snap.date
        }
        return groups.map { (monthStart, rows) in
            let sorted = rows.sorted { $0.date < $1.date }
            return MonthlyBucket(
                monthStart: monthStart,
                snapshotCount: rows.count,
                endValue: sorted.last?.netWorth ?? .zero
            )
        }
        .sorted { $0.monthStart < $1.monthStart }
    }
}

/// Per-account drill-down. Reconstructs the account's daily balance series on
/// the fly (same algorithm the backfill uses) and reports month-end balances
/// so the user can see which account is producing weird values in the chart.
struct AccountTrendDetailView: View {
    let accountId: String
    let accountName: String
    @Environment(AppContainerController.self) private var container

    @Query private var accountQuery: [CachedAccount]
    @Query private var allTransactions: [CachedTransaction]

    init(accountId: String, accountName: String) {
        self.accountId = accountId
        self.accountName = accountName
        let id = accountId
        _accountQuery = Query(filter: #Predicate<CachedAccount> { $0.id == id })
        _allTransactions = Query(
            filter: #Predicate<CachedTransaction> { $0.accountId == id && $0.deleted == false }
        )
    }

    private let calendar = Calendar(identifier: .gregorian)
    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        return f
    }()

    var body: some View {
        List {
            if let account = accountQuery.first {
                Section("Current State") {
                    HStack { Text("Kind"); Spacer(); Text(label(for: account.kind)).foregroundStyle(.secondary) }
                    HStack { Text("On budget"); Spacer(); Text(account.onBudget ? "Yes" : "No").foregroundStyle(.secondary) }
                    HStack { Text("Current balance"); Spacer()
                        Text(CurrencyFormatter.compact(account.balance))
                            .monospacedDigit()
                            .foregroundStyle(account.kind.isLiability ? NwAppColors.liability : .primary)
                    }
                    HStack { Text("Transactions in window"); Spacer(); Text("\(transactionsInWindow.count)").foregroundStyle(.secondary) }
                }

                Section {
                    if monthlySeries.isEmpty {
                        Text("Insufficient history.").foregroundStyle(.secondary)
                    } else {
                        ForEach(monthlySeries, id: \.monthStart) { entry in
                            HStack {
                                Text(Self.monthFormatter.string(from: entry.monthStart))
                                Spacer()
                                Text(CurrencyFormatter.compact(entry.balance))
                                    .monospacedDigit()
                                    .foregroundStyle(entry.balance < .zero ? NwAppColors.liability : .primary)
                            }
                        }
                    }
                } header: {
                    Text("Month-End Balance (reconstructed)")
                } footer: {
                    Text("Reconstructed by walking transactions backward from today's balance. If a month shows a value that doesn't match what the account actually held, the contributing transactions are likely off (e.g. an unexpectedly large deposit or a missed transfer).")
                }
            } else {
                Text("Account not found.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(accountName)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Derived data

    private struct MonthlyBalance {
        let monthStart: Date
        let balance: Money
    }

    private var transactionsInWindow: [CachedTransaction] {
        let today = calendar.startOfDay(for: Date.now)
        guard let start = calendar.date(byAdding: .month, value: -60, to: today) else { return [] }
        return allTransactions.filter { $0.date >= start && $0.date <= today }
    }

    private var monthlySeries: [MonthlyBalance] {
        guard let account = accountQuery.first else { return [] }
        let today = calendar.startOfDay(for: Date.now)
        guard let windowStart = calendar.date(byAdding: .month, value: -60, to: today) else { return [] }

        let reconstructor = AccountHistoryReconstructor(calendar: calendar)
        let summaries = allTransactions.map { $0.toSummary() }
        let dailies = reconstructor.reconstruct(
            currentBalance: account.balance,
            transactions: summaries,
            from: windowStart,
            to: today
        )

        let grouped = Dictionary(grouping: dailies) { daily -> Date in
            let comps = calendar.dateComponents([.year, .month], from: daily.date)
            return calendar.date(from: comps) ?? daily.date
        }
        return grouped.map { (monthStart, entries) in
            let sorted = entries.sorted { $0.date < $1.date }
            return MonthlyBalance(monthStart: monthStart, balance: sorted.last?.balance ?? .zero)
        }
        .sorted { $0.monthStart < $1.monthStart }
    }
}
