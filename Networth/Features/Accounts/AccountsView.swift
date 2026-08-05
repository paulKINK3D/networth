import SwiftUI
import SwiftData
import NetworthCore

struct AccountsView: View {
    @Environment(AppContainerController.self) private var container
    @Query(sort: \CachedAccount.name) private var accounts: [CachedAccount]
    @Query(sort: \CachedFinancialAccount.name) private var financialAccounts: [CachedFinancialAccount]
    @Query private var userSettings: [DurableUserSettings]
    @Query(sort: \DurableManualAsset.name) private var manualAssets: [DurableManualAsset]
    @Query(sort: \CachedPlaidAccount.name) private var plaidAccounts: [CachedPlaidAccount]
    @Query private var plaidItems: [CachedPlaidItem]
    @Query private var plaidTreatments: [DurablePlaidAccountTreatment]
    @Query private var canonicalBindings: [DurableCanonicalAccountBinding]
    @Query private var plaidTransactionCursors: [PlaidTransactionCursor]
    @Query(sort: \DurableCanonicalPayee.name)
    private var canonicalPayees: [DurableCanonicalPayee]
    @Query(sort: \DurableCanonicalCategory.name)
    private var canonicalCategories: [DurableCanonicalCategory]

    @State private var showingNewAsset = false
    @State private var showingClassificationReview = false
    @State private var showingGroupedReview = false
    @State private var showingPlaidAccountMapping = false
    @State private var showingPlaidCutoverConfirm = false
    @State private var plaidCutoverError: String?

    /// True when pushed from Net Worth, which already provides the
    /// navigation stack. The tabless default owns its own stack.
    private let embedded: Bool

    init(embedded: Bool = false) {
        self.embedded = embedded
    }

    private enum SectionKind: String, CaseIterable, Identifiable {
        case cash
        case investments
        case creditCards
        case loans
        case otherAssets
        case otherLiabilities

        var id: String { rawValue }

        var title: String {
            switch self {
            case .cash: return "Cash"
            case .investments: return "Investments"
            case .creditCards: return "Credit Cards"
            case .loans: return "Loans"
            case .otherAssets: return "Other Assets"
            case .otherLiabilities: return "Other Liabilities"
            }
        }

        var isLiability: Bool {
            switch self {
            case .creditCards, .loans, .otherLiabilities: return true
            case .cash, .investments, .otherAssets: return false
            }
        }
    }

    private struct AccountSection: Identifiable {
        let kind: SectionKind
        let accounts: [CachedAccount]
        var id: String { kind.id }
    }

    private struct FinancialAccountSection: Identifiable {
        let kind: SectionKind
        let accounts: [CachedFinancialAccount]
        var id: String { "financial:\(kind.id)" }
        var total: Money {
            accounts.map { kind.isLiability ? $0.balance.absolute : $0.balance }.sum()
        }
    }

    var body: some View {
        if embedded {
            accountsList
        } else {
            NavigationStack { accountsList }
        }
    }

    private var accountsList: some View {
            List {
                Section("Networth Data") {
                    NavigationLink {
                        CanonicalPayeeListView()
                    } label: {
                        LabeledContent(
                            "Contacts",
                            value: "\(canonicalPayees.filter { !$0.archived }.count)"
                        )
                    }
                    NavigationLink {
                        CanonicalCategoryListView()
                    } label: {
                        LabeledContent(
                            "Categories",
                            value: "\(canonicalCategories.filter { !$0.hidden }.count)"
                        )
                    }
                }

                if hasTransactionConnection && !usesPlaidTransactions {
                    Section {
                        Button {
                            showingPlaidAccountMapping = true
                        } label: {
                            HStack {
                                Text("Reconcile accounts with YNAB")
                                    .foregroundStyle(NwAppColors.textPrimary)
                                Spacer()
                                if pendingBindingCount > 0 {
                                    NwStatusBadge(
                                        "\(pendingBindingCount)",
                                        style: .caution,
                                        icon: .warning
                                    )
                                } else {
                                    NwStatusBadge("Done", style: .positive, icon: .success)
                                }
                                NwIcon.chevron.image.foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }

                        HStack {
                            Text("Historical import")
                            Spacer()
                            NwStatusBadge(
                                historicalImportComplete ? "Done" : "In progress",
                                style: historicalImportComplete ? .positive : .caution,
                                icon: historicalImportComplete ? .success : .warning
                            )
                        }

                        HStack {
                            Text("YNAB contacts")
                            Spacer()
                            NwStatusBadge(
                                canonicalPayees.isEmpty
                                    ? "Importing"
                                    : "\(canonicalPayees.count)",
                                style: canonicalPayees.isEmpty
                                    ? .caution
                                    : .positive,
                                icon: canonicalPayees.isEmpty
                                    ? .warning
                                    : .success
                            )
                        }

                        HStack {
                            Text("YNAB categories")
                            Spacer()
                            NwStatusBadge(
                                canonicalCategories.isEmpty
                                    ? "Importing"
                                    : "\(canonicalCategories.count)",
                                style: canonicalCategories.isEmpty
                                    ? .caution
                                    : .positive,
                                icon: canonicalCategories.isEmpty
                                    ? .warning
                                    : .success
                            )
                        }

                        Button {
                            showingClassificationReview = true
                        } label: {
                            HStack {
                                Text("Review transactions")
                                    .foregroundStyle(NwAppColors.textPrimary)
                                Spacer()
                                if !canonicalReviewReady {
                                    NwStatusBadge(
                                        "Waiting",
                                        style: .caution,
                                        icon: .warning
                                    )
                                } else if pendingClassificationReviewCount > 0 {
                                    NwStatusBadge(
                                        "\(pendingClassificationReviewCount)",
                                        style: .caution,
                                        icon: .warning
                                    )
                                } else {
                                    NwStatusBadge(
                                        "Done",
                                        style: .positive,
                                        icon: .success
                                    )
                                }
                                NwIcon.chevron.image.foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .disabled(!canonicalReviewReady)

                        Button("Make Plaid Primary") {
                            showingPlaidCutoverConfirm = true
                        }
                        .disabled(!cutoverReady)

                        if let plaidCutoverError {
                            Text(plaidCutoverError)
                                .font(NwTypography.footnote)
                                .foregroundStyle(NwAppColors.liability)
                        }
                    } header: {
                        Text("Finish Plaid Setup")
                    } footer: {
                        Text("YNAB contacts, categories, and exact historical decisions are imported before Plaid activity is reviewed.")
                    }
                } else if pendingClassificationReviewCount > 0 {
                    Section {
                        Button {
                            showingGroupedReview = true
                        } label: {
                            HStack(spacing: NwSpacing.md) {
                                NwIcon.warning.image
                                    .foregroundStyle(NwAppColors.caution)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Review imported history")
                                        .foregroundStyle(NwAppColors.textPrimary)
                                    Text("Approve suggested groups in one tap; open a group to fix anything first.")
                                        .font(NwTypography.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                NwStatusBadge(
                                    "\(pendingClassificationReviewCount)",
                                    style: .caution,
                                    icon: .warning
                                )
                                NwIcon.chevron.image
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        Button {
                            showingClassificationReview = true
                        } label: {
                            HStack(spacing: NwSpacing.md) {
                                NwIcon.confirm.image
                                    .foregroundStyle(NwAppColors.primary)
                                Text("Review one by one")
                                    .foregroundStyle(NwAppColors.textPrimary)
                                Spacer()
                                NwIcon.chevron.image
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                    }
                }

                if usesPlaidTransactions {
                    ForEach(financialAccountSections) { section in
                        Section {
                            ForEach(section.accounts) { account in
                                NavigationLink {
                                    FinancialAccountDetailView(account: account)
                                } label: {
                                    financialAccountRow(account)
                                }
                            }
                        } header: {
                            sectionHeader(
                                section.kind.title,
                                total: section.total,
                                isLiability: section.kind.isLiability
                            )
                        }
                    }
                }

                if !accountSections.isEmpty {
                    ForEach(accountSections) { section in
                        Section {
                            ForEach(section.accounts) { account in
                                NavigationLink {
                                    if let mappedAccount = mappedFinancialAccount(
                                        for: account
                                    ) {
                                        FinancialAccountDetailView(
                                            account: mappedAccount
                                        )
                                    } else {
                                        AccountDetailView(account: account)
                                    }
                                } label: {
                                    if let mappedAccount = mappedFinancialAccount(
                                        for: account
                                    ) {
                                        financialAccountRow(mappedAccount)
                                    } else {
                                        accountRow(account)
                                    }
                                }
                            }
                        } header: {
                            sectionHeader(
                                section.kind.title,
                                total: accountSectionTotal(section),
                                isLiability: section.kind.isLiability
                            )
                        }
                    }
                }

                if let linkedDocument = container.linkedIBRLoanDocument {
                    Section {
                        NavigationLink {
                            LinkedIBRLoanDetailView(document: linkedDocument)
                        } label: {
                            linkedLoanRow(linkedDocument.current)
                        }
                    } header: {
                        sectionHeader(
                            "Student Loans",
                            total: linkedDocument.current.totalBalance,
                            isLiability: true
                        )
                    }
                }

                let assets = manualAssets.filter { !$0.deleted }
                if !assets.isEmpty {
                    Section {
                        ForEach(manualGroups(from: assets)) { group in
                            manualGroupRows(group)
                        }
                    } header: {
                        sectionHeader("Manual Assets", total: manualAssetTotal, isLiability: false)
                    }
                }

                if accountSections.isEmpty &&
                    financialAccountSections.isEmpty &&
                    assets.isEmpty &&
                    container.linkedIBRLoanDocument == nil {
                    NwEmptyState(
                        title: "No accounts yet",
                        message: "Connect YNAB or add an asset manually.",
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
                    .accessibilityLabel("Add manual asset")
                }
            }
            .sheet(isPresented: $showingNewAsset) {
                ManualAssetForm(asset: nil).environment(container)
            }
            .sheet(isPresented: $showingClassificationReview) {
                PlaidClassificationReviewSheet().environment(container)
            }
            .sheet(isPresented: $showingGroupedReview) {
                GroupedHistoricalReviewSheet().environment(container)
            }
            .sheet(isPresented: $showingPlaidAccountMapping) {
                PlaidAccountMappingSheet().environment(container)
            }
            .alert("Make Plaid Primary?", isPresented: $showingPlaidCutoverConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Switch") {
                    Task { @MainActor in
                        do {
                            try await container.makePlaidPrimary()
                            plaidCutoverError = nil
                        } catch {
                            plaidCutoverError = (error as? LocalizedError)?.errorDescription
                                ?? "The switch could not be completed."
                        }
                    }
                }
            } message: {
                Text("Networth will use Plaid for cash, credit-card balances, and new transaction history. Your local YNAB history and reconciliation matches remain available; the YNAB token will be removed.")
            }
    }

    private var usesPlaidTransactions: Bool {
        userSettings.first?.primaryFinancialDataSource == .plaid
    }

    private var pendingReviewCount: Int {
        container.plaidTransactionSyncCoordinator
            .unresolvedPayeeReviewCount
    }

    private var pendingClassificationReviewCount: Int {
        container.plaidTransactionSyncCoordinator
            .pendingTransactionReviewCount
    }

    private var canonicalReviewReady: Bool {
        container.plaidTransactionSyncCoordinator
            .canonicalReviewReady
    }

    private var hasTransactionConnection: Bool {
        userSettings.first?.plaidTransactionsEnabled == true
            || plaidItems.contains { $0.products.contains("transactions") }
    }

    private var pendingBindingCount: Int {
        let activeIDs = Set(
            financialAccounts.filter { !$0.deleted }.map(\.externalId)
        )
        return canonicalBindings.filter {
            activeIDs.contains($0.plaidAccountId) && !$0.reviewed
        }.count
    }

    private var historicalImportComplete: Bool {
        !plaidTransactionCursors.isEmpty
            && plaidTransactionCursors.allSatisfy(\.historicalImportComplete)
    }

    private var cutoverReady: Bool {
        hasTransactionConnection
            && !financialAccounts.isEmpty
            && !canonicalBindings.isEmpty
            && canonicalPayees.contains { !$0.deletedAtSource }
            && canonicalCategories.contains { !$0.deletedAtSource }
            && pendingBindingCount == 0
            && pendingReviewCount == 0
            && pendingClassificationReviewCount == 0
            && historicalImportComplete
            && canonicalReviewReady
    }

    private func financialAccountRow(_ account: CachedFinancialAccount) -> some View {
        let isLiability = account.kind.isLiability
        return HStack(spacing: NwSpacing.md) {
            NwIcon.forAccountKind(account.kind.rawValue).image
                .foregroundStyle(isLiability ? NwAppColors.liability : NwAppColors.primary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name).font(NwTypography.body)
                Text(financialAccountSubtitle(account))
                    .font(NwTypography.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            NwAmountText(
                isLiability ? account.balance.absolute : account.balance,
                variant: .body,
                color: isLiability ? NwAppColors.liability : nil
            )
        }
    }

    private func financialAccountSubtitle(_ account: CachedFinancialAccount) -> String {
        let institution = account.institutionName ?? subtitle(for: account.kind)
        let mask = account.mask.map { " •••• \($0)" } ?? ""
        return "\(institution)\(mask)"
    }

    private func accountRow(_ account: CachedAccount) -> some View {
        let isLiability = account.kind.isLiability
        let pending = Money(milliunits: account.unclearedMilliunits)
        return HStack(spacing: NwSpacing.md) {
            NwIcon.forAccountKind(account.typeRaw).image
                .foregroundStyle(isLiability ? NwAppColors.liability : NwAppColors.primary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name).font(NwTypography.body)
                Text(accountSubtitle(account, pending: pending))
                    .font(NwTypography.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            NwAmountText(
                isLiability ? account.balance.absolute : account.balance,
                variant: .body,
                color: isLiability ? NwAppColors.liability : nil
            )
        }
    }

    private func mappedFinancialAccount(
        for account: CachedAccount
    ) -> CachedFinancialAccount? {
        guard let canonicalID = canonicalBindings.first(where: {
            $0.reviewed && $0.ynabAccountId == account.id
        })?.canonicalAccountId else {
            return nil
        }
        return financialAccounts.first {
            $0.canonicalAccountId == canonicalID && !$0.deleted
        }
    }

    private func accountSectionTotal(_ section: AccountSection) -> Money {
        section.accounts.map { account in
            let balance = mappedFinancialAccount(for: account)?.balance
                ?? account.balance
            return section.kind.isLiability ? balance.absolute : balance
        }
        .sum()
    }

    private func linkedLoanRow(_ loan: SharedIBRLoanSnapshot) -> some View {
        HStack(spacing: NwSpacing.md) {
            NwIcon.studentLoan.image
                .foregroundStyle(NwAppColors.liability)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Student Loans")
                    .font(NwTypography.body)
                Text("Linked from IBR, updated \(loan.asOf.formatted(.relative(presentation: .named)))")
                    .font(NwTypography.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            NwAmountText(
                loan.totalBalance,
                variant: .body,
                color: NwAppColors.liability
            )
        }
    }

    private func accountSubtitle(_ account: CachedAccount, pending: Money) -> String {
        let kind = subtitle(for: account.kind)
        guard !pending.isZero else { return kind }
        return "\(kind), \(CurrencyFormatter.compact(pending.absolute)) pending"
    }

    private func sectionHeader(_ title: String, total: Money, isLiability: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(CurrencyFormatter.compact(total))
                .foregroundStyle(isLiability ? NwAppColors.liability : NwAppColors.textSecondary)
                .monospacedDigit()
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

    private var accountSections: [AccountSection] {
        let legacyLoanKinds: Set<AccountKind> = [
            .mortgage, .autoLoan, .studentLoan, .personalLoan,
            .medicalDebt, .otherDebt, .otherLiability
        ]
        let open = accounts.filter {
            !$0.deleted && !$0.closed
                && (!usesPlaidTransactions || legacyLoanKinds.contains($0.kind))
        }
        return SectionKind.allCases.compactMap { kind in
            let matching = open.filter { account in
                switch kind {
                case .cash:
                    return account.kind.isCashLike
                case .investments:
                    return account.kind == .investment
                case .creditCards:
                    return account.kind.isCreditCardLike
                case .loans:
                    return [.mortgage, .autoLoan, .studentLoan, .personalLoan,
                            .medicalDebt, .otherDebt].contains(account.kind)
                case .otherAssets:
                    return account.kind == .otherAsset || account.kind == .unknown
                case .otherLiabilities:
                    return account.kind == .otherLiability
                }
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            guard !matching.isEmpty else { return nil }
            return AccountSection(kind: kind, accounts: matching)
        }
    }

    private var financialAccountSections: [FinancialAccountSection] {
        guard usesPlaidTransactions else { return [] }
        let open = financialAccounts.filter { !$0.deleted }
        return SectionKind.allCases.compactMap { kind in
            let matching = open.filter { account in
                switch kind {
                case .cash: account.kind.isCashLike
                case .investments: account.kind == .investment
                case .creditCards: account.kind.isCreditCardLike
                case .loans: account.type == .loan
                case .otherAssets: account.type == .other && !account.balance.isNegative
                case .otherLiabilities: account.type == .other && account.balance.isNegative
                }
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            guard !matching.isEmpty else { return nil }
            return FinancialAccountSection(kind: kind, accounts: matching)
        }
    }

    private struct ManualGroup: Identifiable {
        let title: String
        var id: String { title }
        let displayHeader: String?
        let assets: [DurableManualAsset]
        let total: Money
    }

    private var plaidResolver: PlaidContributionResolver {
        PlaidContributionResolver(
            plaidAccounts: plaidAccounts,
            treatments: plaidTreatments,
            manualAssets: manualAssets
        )
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
                assets: sorted,
                total: sorted.map { plaidResolver.effectiveValue(for: $0) }.sum()
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
            let replacementAccounts = plaidResolver.replacementAccounts(for: asset)
            let updatedAt = effectiveManualAssetUpdatedAt(
                asset,
                replacementAccounts: replacementAccounts,
                plaidItems: plaidItems
            )
            NavigationLink {
                ManualAssetDetailView(asset: asset)
                    .environment(container)
            } label: {
                HStack(spacing: NwSpacing.md) {
                    manualIcon(for: asset.kind).image
                        .foregroundStyle(NwAppColors.primary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: NwSpacing.xs) {
                            Text(asset.name.isEmpty ? "Untitled Asset" : asset.name)
                                .font(NwTypography.body)
                            if !replacementAccounts.isEmpty {
                                NwConnectionIndicator()
                            }
                        }
                        Text("Updated \(updatedAt.formatted(.relative(presentation: .named)))")
                            .font(NwTypography.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    NwAmountText(plaidResolver.effectiveValue(for: asset), variant: .body)
                }
                    .padding(.leading, isGrouped ? NwSpacing.md : 0)
                    .contentShape(Rectangle())
            }
        }
    }

    private var manualAssetTotal: Money {
        manualAssets.filter { !$0.deleted }
            .map { plaidResolver.effectiveValue(for: $0) }
            .sum()
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

private struct LinkedIBRLoanDetailView: View {
    @Environment(AppContainerController.self) private var container
    @Environment(\.openURL) private var openURL
    @State private var historyStartDateDraft = Date.now
    @State private var activeHistoryStartDate = Date.now
    @State private var ynabHistoryStartDate: Date?
    @State private var loadedHistoryDates = false
    let document: SharedIBRLoanDocument

    private var loan: SharedIBRLoanSnapshot { document.current }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NwSpacing.lg) {
                NwCard(style: .primary) {
                    VStack(alignment: .leading, spacing: NwSpacing.md) {
                        Text("AMOUNT OWED")
                            .font(NwTypography.caption)
                            .foregroundStyle(.secondary)
                        NwAmountText(
                            loan.totalBalance,
                            variant: .large,
                            color: NwAppColors.liability
                        )
                        Divider()
                        HStack(spacing: NwSpacing.xl) {
                            metric("Principal", loan.principal)
                            metric("Accrued Interest", loan.accruedInterest)
                        }
                        Text("Updated \(loan.asOf.formatted(.relative(presentation: .named)))")
                            .font(NwTypography.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: NwSpacing.md) {
                    Text("Net Worth History")
                        .font(NwTypography.titleSmall)
                    NwCard(style: .primary, padding: 0) {
                        VStack(spacing: 0) {
                            DatePicker(
                                "Count Loan Starting",
                                selection: $historyStartDateDraft,
                                in: ...Date.now,
                                displayedComponents: .date
                            )
                            .datePickerStyle(.compact)
                            .padding(NwSpacing.md)

                            if hasPendingHistoryStartChange {
                                Divider()
                                Button {
                                    applyHistoryStartDate()
                                } label: {
                                    Label("Apply Start Date", systemImage: "checkmark.circle.fill")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(NwAppColors.positive)
                                .padding(NwSpacing.md)
                            }

                            if let ynabHistoryStartDate {
                                Divider()
                                if container.linkedIBRLoanHistoryStartDate == nil {
                                    HStack {
                                        Label("Matched to YNAB Start", systemImage: "checkmark.circle.fill")
                                        Spacer()
                                        Text(ynabHistoryStartDate.formatted(date: .abbreviated, time: .omitted))
                                            .foregroundStyle(.secondary)
                                    }
                                    .foregroundStyle(NwAppColors.positive)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(NwSpacing.md)
                                } else {
                                    Button {
                                        matchYNABStartDate(ynabHistoryStartDate)
                                    } label: {
                                        HStack {
                                            Label("Match YNAB Start", systemImage: "arrow.counterclockwise")
                                            Spacer()
                                            Text(ynabHistoryStartDate.formatted(date: .abbreviated, time: .omitted))
                                                .foregroundStyle(.secondary)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(NwAppColors.primary)
                                    .padding(NwSpacing.md)
                                }
                            }

                            Divider()
                            Text(historyEstimateDescription)
                                .font(NwTypography.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(NwSpacing.md)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: NwSpacing.md) {
                    Text("Repayment")
                        .font(NwTypography.titleSmall)
                    NwCard(style: .primary, padding: 0) {
                        VStack(spacing: 0) {
                            detailRow(
                                "Monthly Payment",
                                value: loan.actualMonthlyPayment.map {
                                    CurrencyFormatter.currency($0)
                                } ?? "Not recorded"
                            )
                            Divider()
                            detailRow(
                                "Qualifying Payments",
                                value: "\(loan.qualifyingPayments) of \(loan.forgivenessThreshold)"
                            )
                            Divider()
                            detailRow(
                                "Payments Remaining",
                                value: "\(loan.paymentsRemaining)"
                            )
                            Divider()
                            detailRow(
                                "Forgiveness Date",
                                value: loan.forgivenessDate.formatted(date: .abbreviated, time: .omitted)
                            )
                        }
                    }
                }

                Button {
                    guard let url = URL(string: "blibr://loan") else { return }
                    openURL(url)
                } label: {
                    Label("Open BL IBR", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(NwPrimaryButtonStyle())
            }
            .padding(.horizontal, NwSpacing.screenPadding)
            .padding(.vertical, NwSpacing.lg)
        }
        .background(NwAppColors.background.ignoresSafeArea())
        .navigationTitle("Student Loans")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadHistoryDatesIfNeeded)
    }

    private func metric(_ title: String, _ amount: Money) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(NwTypography.caption)
                .foregroundStyle(.secondary)
            NwAmountText(amount, variant: .body, showCents: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var defaultHistoryStartDate: Date {
        document.history.map(\.asOf).min() ?? loan.asOf
    }

    private var hasPendingHistoryStartChange: Bool {
        !Calendar.current.isDate(historyStartDateDraft, inSameDayAs: activeHistoryStartDate)
    }

    private func loadHistoryDatesIfNeeded() {
        guard !loadedHistoryDates else { return }
        let ynabStart = container.defaultLinkedIBRLoanHistoryStartDate()
        let activeStart = container.linkedIBRLoanHistoryStartDate
            ?? ynabStart
            ?? defaultHistoryStartDate
        ynabHistoryStartDate = ynabStart
        activeHistoryStartDate = activeStart
        historyStartDateDraft = activeStart
        loadedHistoryDates = true
    }

    private func applyHistoryStartDate() {
        let normalized = Calendar.current.startOfDay(for: historyStartDateDraft)
        container.setLinkedIBRLoanHistoryStartDate(normalized)
        activeHistoryStartDate = normalized
        historyStartDateDraft = normalized
    }

    private func matchYNABStartDate(_ date: Date) {
        let normalized = Calendar.current.startOfDay(for: date)
        container.setLinkedIBRLoanHistoryStartDate(nil)
        activeHistoryStartDate = normalized
        historyStartDateDraft = normalized
    }

    private var historyEstimateDescription: String {
        let sharedRate = document.history
            .sorted { $0.asOf < $1.asOf }
            .compactMap(\.weightedInterestRatePercent)
            .first
            ?? loan.weightedInterestRatePercent
        guard let rate = sharedRate, rate > 0 else {
            return "Earlier dates use the first available IBR balance as an estimate."
        }
        return "Earlier balances assume $0 payments at \(rateText(rate)) simple interest. Capitalization is excluded."
    }

    private func rateText(_ rate: Decimal) -> String {
        "\(NSDecimalNumber(decimal: rate).stringValue)%"
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NwSpacing.md) {
            Text(title)
                .font(NwTypography.body)
            Spacer()
            Text(value)
                .font(NwTypography.bodyEmphasis)
                .foregroundStyle(NwAppColors.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .padding(NwSpacing.md)
    }
}

private struct FinancialAccountDetailView: View {
    let account: CachedFinancialAccount
    @Query private var recentTransactions: [CachedFinancialTransaction]

    init(account: CachedFinancialAccount) {
        self.account = account
        let id = account.canonicalAccountId
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -30,
            to: .now
        ) ?? .distantPast
        _recentTransactions = Query(
            filter: #Predicate<CachedFinancialTransaction> {
                $0.canonicalAccountId == id
                    && $0.deleted == false
                    && $0.pending == false
                    && $0.postedDate >= cutoff
            },
            sort: [SortDescriptor(\.postedDate, order: .reverse)]
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NwSpacing.lg) {
                NwCard(style: .primary) {
                    VStack(alignment: .leading, spacing: NwSpacing.md) {
                        Text(account.kind.isLiability ? "AMOUNT OWED" : "BALANCE")
                            .font(NwTypography.caption)
                            .foregroundStyle(.secondary)
                        NwAmountText(
                            account.kind.isLiability ? account.balance.absolute : account.balance,
                            variant: .large,
                            color: account.kind.isLiability ? NwAppColors.liability : nil
                        )
                        if let available = account.availableBalanceMilliunits {
                            Divider()
                            HStack {
                                Text("Available")
                                    .font(NwTypography.footnote)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                NwAmountText(
                                    Money(milliunits: available),
                                    variant: .body,
                                    showCents: false
                                )
                            }
                        }
                        Text("Updated \(account.updatedAt.formatted(.relative(presentation: .named)))")
                            .font(NwTypography.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: NwSpacing.md) {
                    Text("30-Day Activity")
                        .font(NwTypography.titleSmall)
                    NwCard(style: .primary) {
                        HStack(spacing: NwSpacing.xl) {
                            activityMetric("Money In", amount: moneyIn, color: NwAppColors.positive)
                            activityMetric(
                                "Money Out",
                                amount: moneyOut,
                                color: account.kind.isLiability
                                    ? NwAppColors.liability
                                    : NwAppColors.textPrimary
                            )
                        }
                    }
                }

                NwSectionHeader("Recent Activity").padding(.horizontal, 0)
                NwCard(style: .primary, padding: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        let visible = Array(recentTransactions.prefix(10))
                        if visible.isEmpty {
                            Text("No recent activity.")
                                .foregroundStyle(.secondary)
                                .padding(NwSpacing.md)
                        } else {
                            ForEach(visible) { transaction in
                                NavigationLink {
                                    PlaidTransactionReviewEditor(
                                        transaction: transaction,
                                        matchingTransactions: [transaction],
                                        dismissAfterSave: true,
                                        onSaved: {}
                                    )
                                } label: {
                                    NwTransactionRow(
                                        title: transaction.displayName,
                                        subtitle: financialTransactionSubtitle(
                                            transaction
                                        ),
                                        amount: Money(
                                            milliunits: transaction.amountMilliunits
                                        )
                                    )
                                }
                                .buttonStyle(.plain)
                                .padding(NwSpacing.md)
                                if transaction.id != visible.last?.id { Divider() }
                            }
                        }
                    }
                }

                NavigationLink {
                    FinancialAccountTransactionHistoryView(account: account)
                } label: {
                    NwCard(style: .primary) {
                        HStack(spacing: NwSpacing.md) {
                            NwIcon.history.image
                                .foregroundStyle(NwAppColors.primary)
                            Text("View all transactions")
                                .font(NwTypography.bodyEmphasis)
                                .foregroundStyle(NwAppColors.textPrimary)
                            Spacer()
                            NwIcon.chevron.image.foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, NwSpacing.screenPadding)
            .padding(.vertical, NwSpacing.lg)
        }
        .background(NwAppColors.background.ignoresSafeArea())
        .navigationTitle(account.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var moneyIn: Money {
        recentTransactions
            .filter { $0.amountMilliunits > 0 }
            .map { Money(milliunits: $0.amountMilliunits) }
            .sum()
    }

    private var moneyOut: Money {
        recentTransactions
            .filter { $0.amountMilliunits < 0 }
            .map { Money(milliunits: $0.amountMilliunits).absolute }
            .sum()
    }

    private func activityMetric(_ title: String, amount: Money, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(NwTypography.caption)
                .foregroundStyle(.secondary)
            NwAmountText(amount, variant: .body, showCents: false, color: color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FinancialAccountTransactionHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    let account: CachedFinancialAccount

    @State private var transactions: [CachedFinancialTransaction] = []
    @State private var isLoading = false
    @State private var hasMore = true
    @State private var loadError: String?

    private static let pageSize = 50

    var body: some View {
        List {
            if transactions.isEmpty, !isLoading, loadError == nil {
                NwEmptyState(
                    title: "No transactions",
                    message: "Posted transactions will appear here.",
                    icon: .empty
                )
                .listRowBackground(Color.clear)
            }

            ForEach(transactions) { transaction in
                NavigationLink {
                    PlaidTransactionReviewEditor(
                        transaction: transaction,
                        matchingTransactions: [transaction],
                        dismissAfterSave: true,
                        onSaved: {}
                    )
                } label: {
                    NwTransactionRow(
                        title: transaction.displayName,
                        subtitle: financialTransactionSubtitle(transaction),
                        amount: Money(
                            milliunits: transaction.amountMilliunits
                        )
                    )
                }
                .onAppear {
                    if transaction.id == transactions.last?.id {
                        loadNextPage()
                    }
                }
            }

            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } else if let loadError {
                Button("Retry") {
                    self.loadError = nil
                    loadNextPage()
                }
                Text(loadError)
                    .font(NwTypography.footnote)
                    .foregroundStyle(NwAppColors.liability)
            } else if hasMore {
                Button("Load more") {
                    loadNextPage()
                }
            }
        }
        .navigationTitle("Transactions")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard transactions.isEmpty else { return }
            loadNextPage()
        }
    }

    private func loadNextPage() {
        guard !isLoading, hasMore else { return }
        isLoading = true
        loadError = nil

        do {
            let page = try FinancialTransactionPageFetcher.fetch(
                accountID: account.canonicalAccountId,
                offset: transactions.count,
                limit: Self.pageSize,
                context: modelContext
            )
            transactions.append(contentsOf: page)
            hasMore = page.count == Self.pageSize
        } catch {
            loadError = "More transactions could not be loaded."
        }
        isLoading = false
    }
}

private func financialTransactionSubtitle(
    _ transaction: CachedFinancialTransaction
) -> String {
    let classification: String
    if transaction.forecastTreatment.requiresCategory {
        let categoryName = transaction.categoryName?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        classification = categoryName.isEmpty
            ? "Needs category"
            : categoryName
    } else {
        classification = transaction.forecastTreatment.displayName
    }
    let date = transaction.postedDate.formatted(
        date: .abbreviated,
        time: .omitted
    )
    return "\(classification) · \(date)"
}

@MainActor
enum FinancialTransactionPageFetcher {
    static func fetch(
        accountID: String,
        offset: Int,
        limit: Int = 50,
        context: ModelContext
    ) throws -> [CachedFinancialTransaction] {
        var descriptor = FetchDescriptor<CachedFinancialTransaction>(
            predicate: #Predicate {
                $0.canonicalAccountId == accountID
                    && $0.deleted == false
                    && $0.pending == false
            },
            sortBy: [
                SortDescriptor(\.postedDate, order: .reverse),
                SortDescriptor(\.id)
            ]
        )
        descriptor.fetchLimit = limit
        descriptor.fetchOffset = offset
        return try context.fetch(descriptor)
    }
}

private struct AccountDetailView: View {
    let account: CachedAccount
    @Query private var recentTransactions: [CachedTransaction]

    init(account: CachedAccount) {
        self.account = account
        let id = account.id
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -30,
            to: .now
        ) ?? .distantPast
        _recentTransactions = Query(
            filter: #Predicate<CachedTransaction> {
                $0.accountId == id
                    && $0.deleted == false
                    && $0.date >= cutoff
            },
            sort: [SortDescriptor(\.date, order: .reverse)]
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NwSpacing.lg) {
                NwCard(style: .primary) {
                    VStack(alignment: .leading, spacing: NwSpacing.md) {
                        Text(account.kind.isLiability ? "AMOUNT OWED" : "BALANCE")
                            .font(NwTypography.caption)
                            .foregroundStyle(.secondary)
                        NwAmountText(
                            displayAmount(account.balance),
                            variant: .large,
                            color: account.kind.isLiability ? NwAppColors.liability : nil
                        )
                        Divider()
                        HStack(spacing: NwSpacing.xl) {
                            balanceMetric(
                                "Cleared",
                                amount: displayAmount(Money(milliunits: account.clearedMilliunits))
                            )
                            balanceMetric(
                                "Pending",
                                amount: displayAmount(Money(milliunits: account.unclearedMilliunits))
                            )
                        }
                        Text("Updated \(account.updatedAt.formatted(.relative(presentation: .named)))")
                            .font(NwTypography.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: NwSpacing.md) {
                    Text("30-Day Activity")
                        .font(NwTypography.titleSmall)
                    NwCard(style: .primary) {
                        HStack(spacing: NwSpacing.xl) {
                            activityMetric(
                                account.kind.isLiability ? "Payments & Credits" : "Money In",
                                amount: moneyIn,
                                color: NwAppColors.positive
                            )
                            activityMetric(
                                account.kind.isLiability ? "Charges" : "Money Out",
                                amount: moneyOut,
                                color: account.kind.isLiability
                                    ? NwAppColors.liability
                                    : NwAppColors.textPrimary
                            )
                        }
                    }
                }

                NwSectionHeader("Recent Activity").padding(.horizontal, 0)
                NwCard(style: .primary, padding: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        let visible = recentTransactions.prefix(40)
                        if visible.isEmpty {
                            Text("No recent activity.")
                                .foregroundStyle(.secondary)
                                .padding(NwSpacing.md)
                        } else {
                            ForEach(Array(visible)) { txn in
                                HStack(spacing: NwSpacing.md) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(txn.payeeName ?? "Transaction")
                                            .font(NwTypography.body)
                                        Text(transactionSubtitle(txn))
                                            .font(NwTypography.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    NwAmountText(
                                        Money(milliunits: txn.amountMilliunits),
                                        variant: .body,
                                        color: transactionColor(txn)
                                    )
                                }
                                .padding(NwSpacing.md)
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

    private var moneyIn: Money {
        recentTransactions
            .filter { $0.amountMilliunits > 0 }
            .map { Money(milliunits: $0.amountMilliunits) }
            .sum()
    }

    private var moneyOut: Money {
        recentTransactions
            .filter { $0.amountMilliunits < 0 }
            .map { Money(milliunits: $0.amountMilliunits).absolute }
            .sum()
    }

    private func displayAmount(_ amount: Money) -> Money {
        account.kind.isLiability ? amount.absolute : amount
    }

    private func balanceMetric(_ title: String, amount: Money) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(NwTypography.caption)
                .foregroundStyle(.secondary)
            NwAmountText(
                amount,
                variant: .body,
                color: account.kind.isLiability ? NwAppColors.liability : nil
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func activityMetric(_ title: String, amount: Money, color: Color) -> some View {
        VStack(alignment: .leading, spacing: NwSpacing.xs) {
            Text(title.uppercased())
                .font(NwTypography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            NwAmountText(amount, variant: .body, showCents: false, color: color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func transactionSubtitle(_ transaction: CachedTransaction) -> String {
        let date = DateDisplay.shortDate(transaction.date)
        guard let category = transaction.categoryName, !category.isEmpty else { return date }
        return "\(date), \(category)"
    }

    private func transactionColor(_ transaction: CachedTransaction) -> Color {
        if transaction.amountMilliunits > 0 { return NwAppColors.positive }
        if account.kind.isLiability { return NwAppColors.liability }
        return NwAppColors.textPrimary
    }
}

struct ManualAssetDetailView: View {
    @Environment(AppContainerController.self) private var container
    @Query(sort: \CachedPlaidAccount.name) private var plaidAccounts: [CachedPlaidAccount]
    @Query private var plaidItems: [CachedPlaidItem]
    @Query private var plaidTreatments: [DurablePlaidAccountTreatment]
    @Query(sort: \DurablePlaidBalanceSnapshot.date) private var plaidBalanceSnapshots: [DurablePlaidBalanceSnapshot]
    let asset: DurableManualAsset
    @State private var showingUpdate = false

    private struct HistoryRow: Identifiable {
        let id: String
        let date: Date
        let value: Money
        let delta: Money?
        let note: String?
        let connected: Bool
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NwSpacing.lg) {
                NwCard(style: .primary) {
                    VStack(alignment: .leading, spacing: NwSpacing.md) {
                        NwAmountText(effectiveValue, variant: .large)
                        HStack(spacing: NwSpacing.xs) {
                            if !replacementAccounts.isEmpty {
                                NwConnectionIndicator()
                            }
                            Text("Updated \(updatedAt.formatted(.relative(presentation: .named)))")
                                .font(NwTypography.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if replacementAccounts.isEmpty {
                    Button {
                        showingUpdate = true
                    } label: {
                        Label("Update Value", systemImage: NwIcon.edit.rawValue)
                    }
                    .buttonStyle(NwPrimaryButtonStyle())
                }

                if !historyRows.isEmpty {
                    NwSectionHeader("Value History").padding(.horizontal, 0)
                    NwCard(style: .primary, padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(historyRows) { entry in
                                HStack(spacing: NwSpacing.md) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: NwSpacing.xs) {
                                            Text(DateDisplay.shortDate(entry.date))
                                                .font(NwTypography.body)
                                            if entry.connected {
                                                NwConnectionIndicator()
                                            }
                                        }
                                        if let note = entry.note, !note.isEmpty {
                                            Text(note)
                                                .font(NwTypography.footnote)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        NwAmountText(entry.value, variant: .body)
                                        if let delta = entry.delta, !delta.isZero {
                                            NwAmountText(
                                                delta,
                                                variant: .signed,
                                                color: delta.isNegative
                                                    ? NwAppColors.liability
                                                    : NwAppColors.positive
                                            )
                                            .font(NwTypography.footnote)
                                        }
                                    }
                                }
                                .padding(NwSpacing.md)
                                if entry.id != historyRows.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                } else {
                    NwEmptyState(
                        title: "No value history",
                        message: "Add an update to start history.",
                        icon: .empty
                    )
                    .frame(minHeight: 180)
                }
            }
            .padding(.horizontal, NwSpacing.screenPadding)
            .padding(.vertical, NwSpacing.lg)
        }
        .background(NwAppColors.background.ignoresSafeArea())
        .navigationTitle(asset.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingUpdate) {
            ManualAssetUpdateSheet(asset: asset)
                .environment(container)
        }
    }

    private var plaidResolver: PlaidContributionResolver {
        PlaidContributionResolver(
            plaidAccounts: plaidAccounts,
            treatments: plaidTreatments,
            manualAssets: [asset]
        )
    }

    private var replacementAccounts: [CachedPlaidAccount] {
        plaidResolver.replacementAccounts(for: asset)
    }

    private var effectiveValue: Money {
        plaidResolver.effectiveValue(for: asset)
    }

    private var updatedAt: Date {
        effectiveManualAssetUpdatedAt(
            asset,
            replacementAccounts: replacementAccounts,
            plaidItems: plaidItems
        )
    }

    private var historyRows: [HistoryRow] {
        let points = ManualAssetHistoryBuilder().build(
            manualAsset: asset.toSnapshot(),
            plaidSnapshots: plaidBalanceSnapshots.map { $0.toHistorySnapshot() }
        )
        let rows = points.enumerated().map { index, point in
            let prior = index > 0 ? points[index - 1].value : nil
            return HistoryRow(
                id: "\(point.source)-\(point.date.timeIntervalSinceReferenceDate)-\(index)",
                date: point.date,
                value: point.value,
                delta: prior.map { point.value - $0 },
                note: point.note,
                connected: point.source == .plaid
            )
        }
        return Array(rows.reversed())
    }
}

private func effectiveManualAssetUpdatedAt(
    _ asset: DurableManualAsset,
    replacementAccounts: [CachedPlaidAccount],
    plaidItems: [CachedPlaidItem]
) -> Date {
    guard !replacementAccounts.isEmpty else { return asset.lastUpdatedAt }
    let itemIDs = Set(replacementAccounts.map(\.itemId))
    return plaidItems
        .filter { itemIDs.contains($0.id) }
        .compactMap(\.lastSyncedAt)
        .max() ?? asset.lastUpdatedAt
}

private struct CanonicalPayeeListView: View {
    @Query(sort: \DurableCanonicalPayee.name)
    private var payees: [DurableCanonicalPayee]
    @State private var searchText = ""
    @State private var showingNewPayee = false

    var body: some View {
        List {
            ForEach(filteredPayees) { payee in
                NavigationLink {
                    CanonicalPayeeEditor(payee: payee)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(payee.name)
                        if payee.archived {
                            Text("Archived")
                                .font(NwTypography.caption)
                                .foregroundStyle(.secondary)
                        } else if payee.ynabPayeeId != nil {
                            Text("Imported from YNAB")
                                .font(NwTypography.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Created in Networth")
                                .font(NwTypography.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Contacts")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search contacts")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingNewPayee = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New contact")
            }
        }
        .sheet(isPresented: $showingNewPayee) {
            NavigationStack {
                CanonicalPayeeEditor(payee: nil)
            }
        }
    }

    private var filteredPayees: [DurableCanonicalPayee] {
        let query = searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !query.isEmpty else { return payees }
        return payees.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.sourceName.localizedCaseInsensitiveContains(query)
        }
    }
}

private struct CanonicalPayeeEditor: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(AppContainerController.self) private var container
    @Query(sort: \DurablePayeeAlias.displayValue)
    private var allAliases: [DurablePayeeAlias]
    @Query(sort: \DurableCanonicalPayee.name)
    private var allPayees: [DurableCanonicalPayee]

    let payee: DurableCanonicalPayee?
    @State private var name: String
    @State private var archived: Bool
    @State private var mergeDestinationId: String?

    init(payee: DurableCanonicalPayee?) {
        self.payee = payee
        _name = State(initialValue: payee?.name ?? "")
        _archived = State(initialValue: payee?.archived ?? false)
    }

    var body: some View {
        Form {
            Section("Contact") {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)
                if payee != nil {
                    Toggle("Archived", isOn: $archived)
                }
            }

            if let payee, payee.userEdited,
               !payee.sourceName.isEmpty,
               payee.sourceName != payee.name {
                Section("Original YNAB Value") {
                    Text(payee.sourceName)
                }
            }

            if let payee {
                Section("Aliases") {
                    let aliases = allAliases.filter {
                        $0.payeeCanonicalId == payee.canonicalId
                            && !$0.suppressed
                    }
                    if aliases.isEmpty {
                        Text("No Plaid aliases yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(aliases) { alias in
                            NavigationLink {
                                CanonicalAliasEditor(alias: alias)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(alias.displayValue)
                                    Text(alias.kindRaw)
                                        .font(NwTypography.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    _ = container.removeCanonicalAlias(
                                        aliasId: alias.id
                                    )
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                    }
                }

                let destinations = allPayees.filter {
                    !$0.archived && $0.canonicalId != payee.canonicalId
                }
                if !destinations.isEmpty {
                    Section {
                        Picker(
                            "Merge into",
                            selection: $mergeDestinationId
                        ) {
                            Text("Select contact").tag(String?.none)
                            ForEach(destinations) { destination in
                                Text(destination.name)
                                    .tag(Optional(destination.canonicalId))
                            }
                        }
                        Button("Merge") {
                            guard let mergeDestinationId,
                                  container.mergeCanonicalPayees(
                                    sourceCanonicalId: payee.canonicalId,
                                    destinationCanonicalId:
                                        mergeDestinationId
                                  ) else {
                                return
                            }
                            dismiss()
                        }
                        .disabled(mergeDestinationId == nil)
                    } header: {
                        Text("Merge Contact")
                    } footer: {
                        Text("Aliases and transaction decisions move to the selected contact. This contact is then archived.")
                    }
                }
            }
        }
        .navigationTitle(payee == nil ? "New Contact" : "Edit Contact")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if payee == nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        NwIcon.close.image
                            .foregroundStyle(NwAppColors.liability)
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    let saved: Bool
                    if let payee {
                        saved = container.updateCanonicalPayee(
                            canonicalId: payee.canonicalId,
                            name: name,
                            archived: archived
                        )
                    } else {
                        saved = container.createCanonicalPayee(name: name)
                    }
                    if saved { dismiss() }
                } label: {
                    NwIcon.confirm.image
                        .foregroundStyle(NwAppColors.positive)
                }
                .disabled(name.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty)
            }
        }
    }
}

private struct CanonicalAliasEditor: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(AppContainerController.self) private var container
    @Query(sort: \DurableCanonicalPayee.name)
    private var payees: [DurableCanonicalPayee]

    let alias: DurablePayeeAlias
    @State private var selectedPayeeId: String

    init(alias: DurablePayeeAlias) {
        self.alias = alias
        _selectedPayeeId = State(initialValue: alias.payeeCanonicalId)
    }

    var body: some View {
        Form {
            Section("Bank Description") {
                Text(alias.displayValue)
                Text(alias.kindRaw)
                    .font(NwTypography.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Assigned Contact") {
                Picker("Contact", selection: $selectedPayeeId) {
                    ForEach(payees.filter { !$0.archived }) { payee in
                        Text(payee.name).tag(payee.canonicalId)
                    }
                }
            }
        }
        .navigationTitle("Edit Alias")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    if container.reassignCanonicalAlias(
                        aliasId: alias.id,
                        to: selectedPayeeId
                    ) {
                        dismiss()
                    }
                } label: {
                    NwIcon.confirm.image
                        .foregroundStyle(NwAppColors.positive)
                }
            }
        }
    }
}

private struct CanonicalCategoryListView: View {
    @Query(sort: [
        SortDescriptor(\DurableCanonicalCategory.groupName),
        SortDescriptor(\DurableCanonicalCategory.name)
    ])
    private var categories: [DurableCanonicalCategory]
    @State private var searchText = ""
    @State private var showingNewCategory = false

    var body: some View {
        List {
            ForEach(categoryGroups, id: \.name) { group in
                Section(group.name) {
                    ForEach(group.categories) { category in
                        NavigationLink {
                            CanonicalCategoryEditor(category: category)
                        } label: {
                            HStack {
                                Text(category.name)
                                Spacer()
                                if category.hidden {
                                    Text("Hidden")
                                        .font(NwTypography.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Categories")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search categories")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingNewCategory = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New category")
            }
        }
        .sheet(isPresented: $showingNewCategory) {
            NavigationStack {
                CanonicalCategoryEditor(category: nil)
            }
        }
    }

    private struct CategoryGroup {
        let name: String
        let categories: [DurableCanonicalCategory]
    }

    private var categoryGroups: [CategoryGroup] {
        let query = searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let visible = query.isEmpty ? categories : categories.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.groupName.localizedCaseInsensitiveContains(query)
        }
        return Dictionary(grouping: visible, by: \.groupName)
            .map {
                CategoryGroup(
                    name: $0.key,
                    categories: $0.value.sorted {
                        $0.name.localizedCaseInsensitiveCompare($1.name)
                            == .orderedAscending
                    }
                )
            }
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name)
                    == .orderedAscending
            }
    }
}

private struct CanonicalCategoryEditor: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(AppContainerController.self) private var container
    let category: DurableCanonicalCategory?
    @State private var name: String
    @State private var groupName: String
    @State private var hidden: Bool

    init(category: DurableCanonicalCategory?) {
        self.category = category
        _name = State(initialValue: category?.name ?? "")
        _groupName = State(
            initialValue: category?.groupName ?? "Networth Categories"
        )
        _hidden = State(initialValue: category?.hidden ?? false)
    }

    var body: some View {
        Form {
            Section("Category") {
                TextField("Name", text: $name)
                TextField("Group", text: $groupName)
                if category != nil {
                    Toggle("Hidden", isOn: $hidden)
                }
            }
            if let category, category.userEdited,
               category.sourceName != category.name
                    || category.sourceGroupName != category.groupName {
                Section("Original YNAB Value") {
                    LabeledContent("Name", value: category.sourceName)
                    LabeledContent(
                        "Group",
                        value: category.sourceGroupName
                    )
                }
            }
        }
        .navigationTitle(
            category == nil ? "New Category" : "Edit Category"
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if category == nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        NwIcon.close.image
                            .foregroundStyle(NwAppColors.liability)
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    let saved: Bool
                    if let category {
                        saved = container.updateCanonicalCategory(
                            canonicalId: category.canonicalId,
                            name: name,
                            groupName: groupName,
                            hidden: hidden
                        )
                    } else {
                        saved = container.createCanonicalCategory(
                            name: name,
                            groupName: groupName
                        )
                    }
                    if saved { dismiss() }
                } label: {
                    NwIcon.confirm.image
                        .foregroundStyle(NwAppColors.positive)
                }
                .disabled(
                    name.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                    || groupName.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                )
            }
        }
    }
}
