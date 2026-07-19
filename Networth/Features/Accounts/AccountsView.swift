import SwiftUI
import SwiftData
import NetworthCore

struct AccountsView: View {
    @Environment(AppContainerController.self) private var container
    @Query(sort: \CachedAccount.name) private var accounts: [CachedAccount]
    @Query(sort: \DurableManualAsset.name) private var manualAssets: [DurableManualAsset]

    @State private var showingNewAsset = false

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
        var total: Money {
            accounts.map { kind.isLiability ? $0.balance.absolute : $0.balance }.sum()
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if !accountSections.isEmpty {
                    ForEach(accountSections) { section in
                        Section {
                            ForEach(section.accounts) { account in
                                NavigationLink {
                                    AccountDetailView(account: account)
                                } label: {
                                    accountRow(account)
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
                    assets.isEmpty &&
                    container.linkedIBRLoanDocument == nil {
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
                    .accessibilityLabel("Add manual asset")
                }
            }
            .sheet(isPresented: $showingNewAsset) {
                ManualAssetForm(asset: nil).environment(container)
            }
        }
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
        let open = accounts.filter { !$0.deleted && !$0.closed }
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
            NavigationLink {
                ManualAssetDetailView(asset: asset)
                    .environment(container)
            } label: {
                HStack(spacing: NwSpacing.md) {
                    manualIcon(for: asset.kind).image
                        .foregroundStyle(NwAppColors.primary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(asset.name.isEmpty ? "Untitled Asset" : asset.name)
                            .font(NwTypography.body)
                        Text("\(asset.kind.displayName), updated \(asset.lastUpdatedAt.formatted(.relative(presentation: .named)))")
                            .font(NwTypography.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    NwAmountText(asset.currentValue, variant: .body)
                }
                    .padding(.leading, isGrouped ? NwSpacing.md : 0)
                    .contentShape(Rectangle())
            }
        }
    }

    private var manualAssetTotal: Money {
        manualAssets.filter { !$0.deleted }.map(\.currentValue).sum()
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
                        let visible = allTransactions.prefix(40)
                        if visible.isEmpty {
                            Text("No recent transactions in cache.")
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

    private var thirtyDayTransactions: [CachedTransaction] {
        let calendar = Calendar(identifier: .gregorian)
        let cutoff = calendar.date(byAdding: .day, value: -30, to: .now) ?? .distantPast
        return allTransactions.filter { $0.date >= cutoff }
    }

    private var moneyIn: Money {
        thirtyDayTransactions
            .filter { $0.amountMilliunits > 0 }
            .map { Money(milliunits: $0.amountMilliunits) }
            .sum()
    }

    private var moneyOut: Money {
        thirtyDayTransactions
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
    let asset: DurableManualAsset
    @State private var showingUpdate = false

    private struct HistoryRow: Identifiable {
        let id: UUID
        let date: Date
        let value: Money
        let delta: Money?
        let note: String?
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NwSpacing.lg) {
                NwCard(style: .primary) {
                    VStack(alignment: .leading, spacing: NwSpacing.md) {
                        Text(asset.kind.displayName)
                            .font(NwTypography.caption)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        NwAmountText(asset.currentValue, variant: .large)
                        Text("Updated \(asset.lastUpdatedAt.formatted(.relative(presentation: .named)))")
                            .font(NwTypography.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    showingUpdate = true
                } label: {
                    Label("Update Value", systemImage: NwIcon.edit.rawValue)
                }
                .buttonStyle(NwPrimaryButtonStyle())

                if !historyRows.isEmpty {
                    NwSectionHeader("Value History").padding(.horizontal, 0)
                    NwCard(style: .primary, padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(historyRows) { entry in
                                HStack(spacing: NwSpacing.md) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(DateDisplay.shortDate(entry.date))
                                            .font(NwTypography.body)
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
                        message: "Update this asset to record its first value.",
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

    private var historyRows: [HistoryRow] {
        let sorted = asset.sortedValues
        let rows = sorted.enumerated().map { index, entry in
            let value = Money(milliunits: entry.amountMilliunits)
            let prior = index > 0
                ? Money(milliunits: sorted[index - 1].amountMilliunits)
                : nil
            return HistoryRow(
                id: entry.id,
                date: entry.recordedAt,
                value: value,
                delta: prior.map { value - $0 },
                note: entry.note
            )
        }
        return Array(rows.reversed())
    }
}
