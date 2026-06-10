import SwiftUI
import SwiftData
import NetworthCore

struct AccountsView: View {
    @Environment(AppContainerController.self) private var container
    @Query(sort: \CachedAccount.name) private var accounts: [CachedAccount]
    @Query(sort: \DurableManualAsset.name) private var manualAssets: [DurableManualAsset]

    @State private var showingNewAsset = false
    @State private var updatingAsset: DurableManualAsset? = nil

    var body: some View {
        NavigationStack {
            List {
                let ynab = accounts.filter { !$0.deleted && !$0.closed }
                if !ynab.isEmpty {
                    ForEach(ynabKindSections(from: ynab), id: \.kind) { section in
                        Section(subtitle(for: section.kind)) {
                            ForEach(section.accounts) { account in
                                NavigationLink {
                                    AccountDetailView(account: account)
                                } label: {
                                    accountRow(name: account.name,
                                               subtitle: subtitle(for: account.kind),
                                               icon: NwIcon.forAccountKind(account.typeRaw),
                                               amount: account.balance,
                                               isLiability: account.kind.isLiability)
                                }
                            }
                        }
                    }
                }

                let assets = manualAssets.filter { !$0.deleted }
                if !assets.isEmpty {
                    Section("Manual Assets") {
                        ForEach(manualGroups(from: assets)) { group in
                            manualGroupRows(group)
                        }
                    }
                }

                if accounts.isEmpty && manualAssets.isEmpty {
                    NwEmptyState(
                        title: "No accounts yet",
                        message: "Add your YNAB token to import accounts, or add a manual asset in Settings.",
                        icon: .accounts
                    )
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Accounts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingNewAsset = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingNewAsset) {
                ManualAssetForm(asset: nil).environment(container)
            }
            .sheet(item: $updatingAsset) { asset in
                ManualAssetUpdateSheet(asset: asset).environment(container)
            }
        }
    }

    private func accountRow(name: String, subtitle: String, icon: NwIcon, amount: Money, isLiability: Bool) -> some View {
        HStack(spacing: NwSpacing.md) {
            icon.image.foregroundStyle(NwAppColors.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(NwTypography.body)
                Text(subtitle).font(NwTypography.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            NwAmountText(amount, variant: .body, color: isLiability ? NwAppColors.liability : nil)
        }
    }

    private func subtitle(for kind: AccountKind) -> String {
        switch kind {
        case .checking: return "Checking"
        case .savings:  return "Savings"
        case .cash:     return "Cash"
        case .creditCard: return "Credit Card"
        case .lineOfCredit: return "Line of Credit"
        case .mortgage: return "Mortgage"
        case .autoLoan: return "Auto Loan"
        case .studentLoan: return "Student Loan"
        case .personalLoan: return "Personal Loan"
        case .medicalDebt: return "Medical Debt"
        case .otherDebt: return "Other Debt"
        case .otherAsset: return "Other Asset"
        case .otherLiability: return "Other Liability"
        case .investment: return "Investment"
        case .unknown: return "Other"
        }
    }

    private struct YnabKindSection {
        let kind: AccountKind
        let accounts: [CachedAccount]
    }

    /// Display order for YNAB account sub-sections — assets above liabilities,
    /// each group ordered by typical use.
    private static let ynabKindOrder: [AccountKind] = [
        .checking, .savings, .cash, .investment, .otherAsset,
        .creditCard, .lineOfCredit, .mortgage, .autoLoan,
        .studentLoan, .personalLoan, .medicalDebt, .otherDebt, .otherLiability,
        .unknown
    ]

    private func ynabKindSections(from accounts: [CachedAccount]) -> [YnabKindSection] {
        Self.ynabKindOrder.compactMap { kind in
            let matching = accounts.filter { $0.kind == kind }
                .sorted { $0.name.lowercased() < $1.name.lowercased() }
            guard !matching.isEmpty else { return nil }
            return YnabKindSection(kind: kind, accounts: matching)
        }
    }

    private struct ManualGroup: Identifiable {
        let title: String
        var id: String { title }
        let displayHeader: String?
        let assets: [DurableManualAsset]
        var total: Money {
            Money(milliunits: assets.reduce(Int64(0)) { $0 + $1.currentValueMilliunits })
        }
    }

    private func manualGroups(from assets: [DurableManualAsset]) -> [ManualGroup] {
        let buckets = Dictionary(grouping: assets) {
            ($0.groupName ?? "").trimmingCharacters(in: .whitespaces)
        }
        return buckets.map { key, list in
            let sorted = list.sorted { $0.name.lowercased() < $1.name.lowercased() }
            return ManualGroup(
                title: key.isEmpty ? "" : key,
                displayHeader: key.isEmpty ? nil : key,
                assets: sorted
            )
        }
        .sorted { lhs, rhs in
            if lhs.title.isEmpty { return false }
            if rhs.title.isEmpty { return true }
            return lhs.title.lowercased() < rhs.title.lowercased()
        }
    }

    @ViewBuilder
    private func manualGroupRows(_ group: ManualGroup) -> some View {
        let isGrouped = group.displayHeader != nil
        if let title = group.displayHeader {
            HStack {
                Text(title)
                    .font(NwTypography.footnoteEm)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text(CurrencyFormatter.compact(group.total))
                    .font(NwTypography.footnoteEm)
                    .foregroundStyle(.secondary)
            }
        }
        ForEach(group.assets) { asset in
            Button {
                updatingAsset = asset
            } label: {
                accountRow(name: asset.name,
                           subtitle: asset.kind.displayName,
                           icon: manualIcon(for: asset.kind),
                           amount: asset.currentValue,
                           isLiability: false)
                    .padding(.leading, isGrouped ? NwSpacing.md : 0)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func manualIcon(for kind: ManualAssetKind) -> NwIcon {
        switch kind {
        case .realEstate:  return .realEstate
        case .vehicle:     return .vehicle
        case .brokerage:   return .brokerage
        case .retirement:  return .retirement
        case .crypto:      return .crypto
        case .collectible: return .collectible
        case .other:       return .otherAsset
        }
    }
}

private struct AccountDetailView: View {
    let account: CachedAccount
    @Query private var allTransactions: [CachedTransaction]

    init(account: CachedAccount) {
        self.account = account
        let id = account.id
        _allTransactions = Query(
            filter: #Predicate<CachedTransaction> { $0.accountId == id && $0.deleted == false },
            sort: [SortDescriptor(\.date, order: .reverse)]
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NwSpacing.lg) {
                NwCard(style: .primary) {
                    VStack(alignment: .leading, spacing: NwSpacing.sm) {
                        Text("Balance").font(NwTypography.caption)
                            .foregroundStyle(.secondary).textCase(.uppercase)
                        NwAmountText(account.balance, variant: .large,
                                     color: account.kind.isLiability ? NwAppColors.liability : nil)
                        Text("Cleared: \(CurrencyFormatter.currency(Money(milliunits: account.clearedMilliunits)))")
                            .font(NwTypography.footnote).foregroundStyle(.secondary)
                    }
                }
                NwSectionHeader("Recent Activity").padding(.horizontal, 0)
                NwCard(style: .primary) {
                    VStack(alignment: .leading, spacing: 0) {
                        let visible = allTransactions.prefix(40)
                        if visible.isEmpty {
                            Text("No recent transactions in cache.")
                                .foregroundStyle(.secondary)
                                .padding(.vertical, NwSpacing.md)
                        } else {
                            ForEach(Array(visible)) { txn in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(txn.payeeName ?? "—").font(NwTypography.body)
                                        Text(DateDisplay.shortDate(txn.date))
                                            .font(NwTypography.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    NwAmountText(Money(milliunits: txn.amountMilliunits), variant: .body,
                                                 color: txn.amountMilliunits >= 0 ? NwAppColors.positive : NwAppColors.textPrimary)
                                }
                                .padding(.vertical, NwSpacing.xs)
                                if txn.id != visible.last?.id { Divider() }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, NwSpacing.screenPadding)
            .padding(.vertical, NwSpacing.lg)
        }
        .background(NwAppColors.background.ignoresSafeArea())
        .navigationTitle(account.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ManualAssetDetailView: View {
    let asset: DurableManualAsset

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NwSpacing.lg) {
                NwCard(style: .primary) {
                    VStack(alignment: .leading, spacing: NwSpacing.sm) {
                        Text(asset.kind.displayName)
                            .font(NwTypography.caption)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        NwAmountText(asset.currentValue, variant: .large)
                        Text("Updated \(DateDisplay.shortDate(asset.lastUpdatedAt))")
                            .font(NwTypography.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if !asset.sortedValues.isEmpty {
                    NwSectionHeader("Value History").padding(.horizontal, 0)
                    NwCard(style: .primary) {
                        VStack(spacing: NwSpacing.sm) {
                            ForEach(asset.sortedValues.reversed()) { entry in
                                HStack {
                                    Text(DateDisplay.shortDate(entry.recordedAt))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    NwAmountText(Money(milliunits: entry.amountMilliunits), variant: .body)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, NwSpacing.screenPadding)
            .padding(.vertical, NwSpacing.lg)
        }
        .background(NwAppColors.background.ignoresSafeArea())
        .navigationTitle(asset.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
