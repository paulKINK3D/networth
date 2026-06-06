import SwiftUI
import SwiftData
import NetworthCore

struct AccountsView: View {
    @Environment(AppContainerController.self) private var container
    @Query(sort: \CachedAccount.name) private var accounts: [CachedAccount]
    @Query(sort: \DurableManualAsset.name) private var manualAssets: [DurableManualAsset]

    var body: some View {
        NavigationStack {
            List {
                let ynab = accounts.filter { !$0.deleted && !$0.closed }
                if !ynab.isEmpty {
                    Section("YNAB") {
                        ForEach(ynab) { account in
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

                let assets = manualAssets.filter { !$0.deleted }
                if !assets.isEmpty {
                    Section("Manual Assets") {
                        ForEach(assets) { asset in
                            NavigationLink {
                                ManualAssetDetailView(asset: asset)
                            } label: {
                                accountRow(name: asset.name,
                                           subtitle: asset.kind.displayName,
                                           icon: manualIcon(for: asset.kind),
                                           amount: asset.currentValue,
                                           isLiability: false)
                            }
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
