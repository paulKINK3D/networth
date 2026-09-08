import SwiftUI
import SwiftData
import Charts
import Combine
import NetworthCore

private enum NetWorthCategory: String, CaseIterable, Identifiable {
    case cash
    case investments
    case retirement
    case property
    case otherAssets
    case cards
    case loans
    case otherLiabilities

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cash: return "Cash"
        case .investments: return "Investments"
        case .retirement: return "Retirement"
        case .property: return "Property & Valuables"
        case .otherAssets: return "Other Assets"
        case .cards: return "Credit Cards"
        case .loans: return "Loans"
        case .otherLiabilities: return "Other Liabilities"
        }
    }

    var icon: NwIcon {
        switch self {
        case .cash: return .cash
        case .investments: return .investment
        case .retirement: return .retirement
        case .property: return .realEstate
        case .otherAssets: return .otherAsset
        case .cards: return .creditCard
        case .loans: return .mortgage
        case .otherLiabilities: return .otherLiability
        }
    }

    var isLiability: Bool {
        switch self {
        case .cards, .loans, .otherLiabilities: return true
        case .cash, .investments, .retirement, .property, .otherAssets: return false
        }
    }
}

private struct NetWorthEntry: Identifiable {
    let id: String
    let name: String
    let subtitle: String
    let amount: Money
    let updatedAt: Date?
    let destination: NetWorthEntryDestination
}

private enum NetWorthEntryDestination {
    case financialAccount(CachedFinancialAccount)
    case manualAsset(DurableManualAsset)
    case plaidInvestment(CachedPlaidAccount)
    case linkedIBR(SharedIBRLoanDocument)
}

private struct NetWorthTrendPoint: Identifiable, Sendable {
    var id: Date { date }
    let date: Date
    let assets: Money
    let liabilities: Money
    var netWorth: Money { assets - liabilities }
}

private struct NetWorthTabRequest: Sendable {
    let linkedLoan: SharedIBRLoanDocument?
    let loanHistoryStart: Date?
}

private struct NetWorthTabModel: Sendable {
    let breakdown: NetWorthBreakdown
    let trendPoints: [NetWorthTrendPoint]
}

/// Off-main assembly of everything the Net Worth tab renders. Owns its own
/// ModelContext so the multi-table breakdown and per-snapshot IBR balance
/// lookups never touch the main thread.
@ModelActor
private actor NetWorthDataActor {
    func build(_ request: NetWorthTabRequest) -> NetWorthTabModel {
        let breakdown = SnapshotScheduler.computeBreakdown(
            context: modelContext,
            linkedIBRLoan: request.linkedLoan?.current
        )
        let snapshots = (try? modelContext.fetch(
            FetchDescriptor<DurableNetWorthSnapshot>(
                sortBy: [SortDescriptor(\.date)]
            )
        )) ?? []
        let points = snapshots.map { snapshot in
            let loanBalance = request.linkedLoan?.balance(
                on: snapshot.date,
                historyStartDate: request.loanHistoryStart
            ) ?? .zero
            return NetWorthTrendPoint(
                date: snapshot.date,
                assets: snapshot.assets,
                liabilities: snapshot.liabilities + loanBalance
            )
        }
        return NetWorthTabModel(breakdown: breakdown, trendPoints: points)
    }
}

struct NetWorthView: View {
    @Environment(AppContainerController.self) private var container
    @Query(sort: \CachedFinancialAccount.currentBalanceMilliunits, order: .reverse)
    private var financialAccounts: [CachedFinancialAccount]
    @Query(sort: \DurableManualAsset.name) private var manualAssets: [DurableManualAsset]
    @Query private var userSettings: [DurableUserSettings]
    @Query(sort: \CachedPlaidAccount.name) private var plaidAccounts: [CachedPlaidAccount]
    @Query private var plaidTreatments: [DurablePlaidAccountTreatment]
    @Query private var accountNicknames: [DurableAccountNickname]

    @State private var range: Range = .twelveMonths
    @State private var showingTrendDetail = false
    /// Currently scrubbed date on the trend chart. `nil` when the user isn't
    /// touching the chart.
    @State private var scrubbedDate: Date? = nil
    /// Trend chart disclosure. Deliberately not persisted — the chart starts
    /// collapsed on every visit while post-clean-start history accrues.
    @State private var isChartExpanded = false

    enum Range: String, CaseIterable, Identifiable {
        case threeMonths = "3M"
        case sixMonths   = "6M"
        case twelveMonths = "1Y"
        case twoYears    = "2Y"
        case fiveYears   = "5Y"
        var id: String { rawValue }
        var months: Int {
            switch self {
            case .threeMonths: return 3
            case .sixMonths:   return 6
            case .twelveMonths: return 12
            case .twoYears:    return 24
            case .fiveYears:   return 60
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NwSpacing.lg) {
                    if !hasPrimaryConnection {
                        NwInlineNotice(
                            "Connect your accounts",
                            message: "Connect your bank through Plaid in Settings to start tracking.",
                            tone: .info,
                            actionTitle: "Open Settings",
                            action: { SettingsRouter.open() }
                        )
                    } else if case .error(let msg) = container.plaidTransactionSyncCoordinator.phase {
                        NwInlineNotice(
                            "Sync issue",
                            message: msg,
                            tone: .caution,
                            actionTitle: "Retry",
                            action: { Task { await container.syncNow() } }
                        )
                    }

                    if cachedBreakdown != nil {
                        heroCard
                        chartCard
                        balanceSheet
                    } else {
                        // Cold load: the breakdown computes off the render
                        // path; never fetch-through inside body.
                        NwLoadingState("Loading net worth…")
                            .frame(maxWidth: .infinity, minHeight: 320)
                    }
                }
                .padding(.horizontal, NwSpacing.screenPadding)
                .padding(.vertical, NwSpacing.lg)
            }
            .nwFieldBackground(
                photo: container.backgroundPhotoStore.image,
                wash: container.backgroundPhotoStore.washOpacity
            )
            .navigationTitle("Net Worth")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NwTopLevelMenu(
                        canRefresh: hasPrimaryConnection,
                        onAccounts: {
                            SettingsRouter.open(SettingsPage.accounts)
                        },
                        onRefresh: {
                            Task { await container.syncNow() }
                        },
                        onSettings: { SettingsRouter.open() }
                    )
                }
            }
            .sheet(isPresented: $showingTrendDetail) {
                TrendDetailView().environment(container)
            }
            .task { refreshCaches() }
            .onAppear {
                isVisible = true
                refreshCaches()
            }
            .onDisappear { isVisible = false }
            .onReceive(Self.saveEvents) { _ in
                if isVisible {
                    refreshCaches(force: true)
                } else {
                    cacheFingerprint = ""
                }
            }
        }
    }

    // MARK: - Cards

    /// Caches: `computeBreakdown` refetches several tables and the trend
    /// series walks every snapshot (with per-point IBR lookups). The view
    /// reads both repeatedly per render, and chart scrubbing re-renders
    /// continuously — so both refresh once per debounced save burst, and
    /// only while this tab is visible.
    @State private var cachedBreakdown: NetWorthBreakdown?
    @State private var cachedTrendPoints: [NetWorthTrendPoint]?
    @State private var cacheFingerprint = ""
    @State private var isVisible = false

    private static let saveEvents: AnyPublisher<Notification, Never> =
        NotificationCenter.default
            .publisher(for: .networthModelContextSaved)
            .debounce(for: .seconds(0.6), scheduler: RunLoop.main)
            .eraseToAnyPublisher()

    /// Cheap staleness signal covering CloudKit-driven changes that never
    /// post the local save notification.
    private var inputFingerprint: String {
        [
            "\(financialAccounts.count)",
            "\(manualAssets.count)", "\(plaidAccounts.count)",
            "\(plaidTreatments.count)",
            "\(userSettings.first?.chartStartDate?.timeIntervalSince1970 ?? 0)",
            "\(userSettings.first?.lastSyncedAt?.timeIntervalSince1970 ?? 0)"
        ].joined(separator: "|")
    }

    @State private var refreshTask: Task<Void, Never>?

    private func refreshCaches(force: Bool = false) {
        let fingerprint = inputFingerprint
        guard force || cachedBreakdown == nil
            || cacheFingerprint != fingerprint else { return }
        cacheFingerprint = fingerprint
        let request = NetWorthTabRequest(
            linkedLoan: container.linkedIBRLoanDocument,
            loanHistoryStart:
                container.effectiveLinkedIBRLoanHistoryStartDate()
        )
        let modelContainer = container.modelContainer
        refreshTask?.cancel()
        refreshTask = Task {
            // Detached: @ModelActor inherits the creating executor; built on
            // main it would compute on main.
            let model = await Task.detached(priority: .userInitiated) {
                let dataActor = NetWorthDataActor(
                    modelContainer: modelContainer
                )
                return await dataActor.build(request)
            }.value
            guard !Task.isCancelled else { return }
            cachedBreakdown = model.breakdown
            cachedTrendPoints = model.trendPoints
        }
    }

    /// UI is gated on the cache being present; the zero fallback exists only
    /// so accessors are total — it never renders.
    private var breakdown: NetWorthBreakdown {
        cachedBreakdown ?? NetWorthBreakdown(
            cash: .zero, investments: .zero, otherAssets: .zero,
            manualAssets: .zero, creditCardDebt: .zero, loans: .zero,
            otherLiabilities: .zero
        )
    }

    /// Plaid is the only primary source. A missing connection produces this
    /// connection state.
    private var hasPrimaryConnection: Bool {
        container.hasPlaidBackendToken
    }

    private var plaidResolver: PlaidContributionResolver {
        PlaidContributionResolver(
            plaidAccounts: plaidAccounts,
            treatments: plaidTreatments,
            manualAssets: manualAssets
        )
    }

    private var heroCard: some View {
        let total = breakdown.netWorth
        let delta = monthDelta()
        return NwCard(style: .primary) {
            VStack(alignment: .leading, spacing: NwSpacing.md) {
                NwAmountText(total, variant: .hero, showCents: false)
                if let delta {
                    HStack(spacing: NwSpacing.xs) {
                        (delta.isNegative ? NwIcon.arrowDown : NwIcon.arrowUp).image
                            .font(NwTypography.footnoteEm)
                        NwAmountText(
                            delta,
                            variant: .signed,
                            showCents: false,
                            color: delta.isNegative ? NwAppColors.liability : NwAppColors.positive
                        )
                        Text("over 30 days")
                            .font(NwTypography.footnote)
                    }
                    .foregroundStyle(delta.isNegative ? NwAppColors.liability : NwAppColors.positive)
                } else {
                    Text("More history needed for a 30-day change.")
                        .font(NwTypography.footnote)
                        .foregroundStyle(.secondary)
                }

                Divider()
                HStack(spacing: NwSpacing.xl) {
                    balanceMetric(
                        "Assets",
                        amount: breakdown.totalAssets,
                        color: NwAppColors.positive
                    )
                    balanceMetric(
                        "Liabilities",
                        amount: breakdown.totalLiabilities,
                        color: NwAppColors.liability
                    )
                }
            }
        }
    }

    private func balanceMetric(_ label: String, amount: Money, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(NwTypography.caption)
                .foregroundStyle(.secondary)
            NwAmountText(amount, variant: .body, showCents: false, color: color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Small readout above the chart showing the date and value at the
    /// scrubbed position. Falls back to a neutral hint when the user isn't
    /// touching the chart.
    @ViewBuilder
    private func scrubReadout(visible: [NetWorthTrendPoint]) -> some View {
        let cal = Calendar(identifier: .gregorian)
        let target = scrubbedDate ?? visible.last?.date
        let nearest: NetWorthTrendPoint? = {
            guard let target else { return visible.last }
            let targetDay = cal.startOfDay(for: target)
            return visible.min { lhs, rhs in
                abs(cal.startOfDay(for: lhs.date).timeIntervalSince(targetDay)) <
                abs(cal.startOfDay(for: rhs.date).timeIntervalSince(targetDay))
            } ?? visible.last
        }()
        HStack(spacing: NwSpacing.sm) {
            if let nearest {
                Text(DateDisplay.shortDate(nearest.date))
                    .font(NwTypography.footnoteEm)
                    .foregroundStyle(.secondary)
                Spacer()
                NwAmountText(nearest.netWorth, variant: .body, showCents: false)
                    .foregroundStyle(scrubbedDate == nil ? .secondary : NwAppColors.textPrimary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chartCard: some View {
        NwCard(style: .primary) {
            VStack(alignment: .leading, spacing: NwSpacing.md) {
                chartHeader
                if isChartExpanded {
                    chartContent(visible: filteredSnapshots())
                }
            }
        }
    }

    private var chartHeader: some View {
        HStack {
            Text("Net Worth Trend")
                .font(NwTypography.headline)
            if isChartExpanded {
                Button {
                    showingTrendDetail = true
                } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Net worth trend details")
            }
            Spacer()
            Image(systemName: isChartExpanded ? "chevron.up" : "chevron.down")
                .font(NwTypography.footnoteEm)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                isChartExpanded.toggle()
                if !isChartExpanded { scrubbedDate = nil }
            }
        }
    }

    @ViewBuilder
    private func chartContent(visible: [NetWorthTrendPoint]) -> some View {
        Picker("Trend range", selection: $range) {
            ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)

        if visible.count < 2 {
            Text("More history needed.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .font(NwTypography.footnote)
                .frame(height: 180, alignment: .center)
                .frame(maxWidth: .infinity)
        } else {
            scrubReadout(visible: visible)
            Chart(visible) { snap in
                AreaMark(
                    x: .value("Date", snap.date),
                    y: .value("Net Worth", snap.netWorth.doubleValue)
                )
                .foregroundStyle(.linearGradient(
                    colors: [NwAppColors.primary.opacity(0.5), NwAppColors.primary.opacity(0.05)],
                    startPoint: .top, endPoint: .bottom
                ))
                LineMark(
                    x: .value("Date", snap.date),
                    y: .value("Net Worth", snap.netWorth.doubleValue)
                )
                .foregroundStyle(NwAppColors.primary)
                .lineStyle(StrokeStyle(lineWidth: 2.5))
                if let scrubbed = scrubbedDate {
                    RuleMark(x: .value("Scrubbed", scrubbed))
                        .foregroundStyle(NwAppColors.primary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            .chartXSelection(value: $scrubbedDate)
            .frame(height: 220)
        }
    }

    private var balanceSheet: some View {
        VStack(alignment: .leading, spacing: NwSpacing.md) {
            Text("Balance Sheet")
                .font(NwTypography.titleSmall)

            NwCard(style: .primary, padding: 0) {
                VStack(spacing: 0) {
                    compositionHeader(
                        "Assets",
                        total: breakdown.totalAssets,
                        color: NwAppColors.positive
                    )
                    ForEach(assetCategories) { category in
                        Divider()
                        categoryLink(category)
                    }

                    Divider()
                        .padding(.vertical, NwSpacing.xs)

                    compositionHeader(
                        "Liabilities",
                        total: breakdown.totalLiabilities,
                        color: NwAppColors.liability
                    )
                    if liabilityCategories.isEmpty {
                        Text("No liabilities")
                            .font(NwTypography.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, NwSpacing.md)
                            .padding(.bottom, NwSpacing.md)
                    } else {
                        ForEach(liabilityCategories) { category in
                            Divider()
                            categoryLink(category)
                        }
                    }
                }
            }
        }
    }

    private func compositionHeader(_ title: String, total: Money, color: Color) -> some View {
        HStack {
            Text(title.uppercased())
                .font(NwTypography.caption)
                .foregroundStyle(.secondary)
            Spacer()
            NwAmountText(total, variant: .body, showCents: false, color: color)
        }
        .padding(NwSpacing.md)
    }

    private func categoryLink(_ category: NetWorthCategory) -> some View {
        let entries = entries(for: category)
        let amount = amount(for: category)
        return NavigationLink {
            categoryDestination(
                category,
                entries: entries,
                total: amount
            )
        } label: {
            HStack(spacing: NwSpacing.md) {
                category.icon.image
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(category.isLiability ? NwAppColors.liability : NwAppColors.primary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title)
                        .font(NwTypography.headline)
                        .foregroundStyle(NwAppColors.textPrimary)
                    Text(categorySubtitle(category, amount: amount))
                        .font(NwTypography.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                NwAmountText(
                    amount,
                    variant: .body,
                    showCents: false,
                    color: category.isLiability ? NwAppColors.liability : nil
                )
                NwIcon.chevron.image
                    .font(NwTypography.footnote)
                    .foregroundStyle(.tertiary)
            }
            .padding(NwSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func categoryDestination(
        _ category: NetWorthCategory,
        entries: [NetWorthEntry],
        total: Money
    ) -> some View {
        switch category {
        case .investments:
            InvestmentsView(scope: .investments)
        case .retirement:
            InvestmentsView(scope: .retirement)
        default:
            NetWorthCategoryDetailView(
                category: category,
                entries: entries,
                total: total
            )
        }
    }

    private var assetCategories: [NetWorthCategory] {
        [.cash, .investments, .retirement, .property, .otherAssets]
            .filter { !amount(for: $0).isZero }
    }

    private var liabilityCategories: [NetWorthCategory] {
        [.cards, .loans, .otherLiabilities]
            .filter { !amount(for: $0).isZero }
    }

    private func amount(for category: NetWorthCategory) -> Money {
        switch category {
        case .cash: return breakdown.cash
        case .investments: return breakdown.investments
        case .retirement: return breakdown.retirement
        case .property: return breakdown.manualAssets
        case .otherAssets: return breakdown.otherAssets
        case .cards: return breakdown.creditCardDebt
        case .loans: return breakdown.loans
        case .otherLiabilities: return breakdown.otherLiabilities
        }
    }

    private func categorySubtitle(
        _ category: NetWorthCategory,
        amount: Money
    ) -> String {
        let sideTotal = category.isLiability
            ? breakdown.totalLiabilities
            : breakdown.totalAssets
        guard sideTotal > .zero else { return "" }
        let share = Int((amount.doubleValue / sideTotal.doubleValue * 100).rounded())
        let side = category.isLiability ? "liabilities" : "assets"
        return "\(share)% of \(side)"
    }

    private func entries(for category: NetWorthCategory) -> [NetWorthEntry] {
        let financialEntries = financialAccounts.compactMap { account -> NetWorthEntry? in
            guard !account.deleted else { return nil }
            let matches: Bool
            switch category {
            case .cash:
                matches = account.type.isCashLike
            case .investments:
                matches = account.type == .investment
            case .cards:
                matches = account.type == .creditCard
            case .loans:
                matches = account.type == .loan
            case .otherAssets:
                matches = account.type == .other && !account.balance.isNegative
            case .otherLiabilities:
                matches = account.type == .other && account.balance.isNegative
            case .retirement, .property:
                matches = false
            }
            guard matches else { return nil }
            let mask = account.mask.map { " •••• \($0)" } ?? ""
            return NetWorthEntry(
                id: "financial:\(account.canonicalAccountId)",
                name: accountNameResolver.name(for: account),
                subtitle: "\(account.institutionName ?? accountKindLabel(account.kind))\(mask)",
                amount: category.isLiability ? account.balance.absolute : account.balance,
                updatedAt: account.updatedAt,
                destination: .financialAccount(account)
            )
        }

        let durableEntries = manualAssets
            .filter {
                !$0.deleted
                    && manualAsset($0, belongsTo: category)
            }
            .map { asset in
                NetWorthEntry(
                    id: "manual:\(asset.id.uuidString)",
                    name: asset.name.isEmpty ? "Untitled Asset" : asset.name,
                    subtitle: asset.kind.displayName,
                    amount: plaidResolver.effectiveValue(for: asset),
                    updatedAt: asset.lastUpdatedAt,
                    destination: .manualAsset(asset)
                )
            }

        let plaidEntries: [NetWorthEntry]
        if category == .investments || category == .retirement {
            let contributingIDs = Set(plaidResolver.standalonePlaidAccounts.map(\.id))
            plaidEntries = plaidAccounts.compactMap { account in
                guard contributingIDs.contains(account.id),
                      let balance = account.currentBalance,
                      PlaidRetirementClassifier.isRetirement(subtype: account.subtype)
                          == (category == .retirement) else {
                    return nil
                }
                let mask = account.mask.map { " •••• \($0)" } ?? ""
                return NetWorthEntry(
                    id: "plaid:\(account.id)",
                    name: accountNameResolver.name(for: account),
                    subtitle: "\(account.institutionName)\(mask)",
                    amount: balance,
                    updatedAt: nil,
                    destination: .plaidInvestment(account)
                )
            }
        } else {
            plaidEntries = []
        }

        var combined = financialEntries + durableEntries + plaidEntries
        if category == .loans,
           let document = container.linkedIBRLoanDocument {
            let loan = document.current
            combined.append(NetWorthEntry(
                id: "ibr:primary",
                name: "Student Loans",
                subtitle: "Student Loan, linked from IBR",
                amount: loan.totalBalance,
                updatedAt: loan.asOf,
                destination: .linkedIBR(document)
            ))
        }

        return combined.sorted { lhs, rhs in
            if lhs.amount != rhs.amount { return lhs.amount > rhs.amount }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var accountNameResolver: AccountDisplayNameResolver {
        AccountDisplayNameResolver(nicknames: accountNicknames)
    }

    private func manualAsset(
        _ asset: DurableManualAsset,
        belongsTo category: NetWorthCategory
    ) -> Bool {
        switch category {
        case .investments:
            return [.brokerage, .crypto].contains(asset.kind)
        case .retirement:
            return asset.kind == .retirement
        case .property:
            return [.realEstate, .vehicle, .collectible].contains(asset.kind)
        case .otherAssets:
            return asset.kind == .other
        case .cash, .cards, .loans, .otherLiabilities:
            return false
        }
    }

    private func accountKindLabel(_ kind: AccountKind) -> String {
        switch kind {
        case .checking: return "Checking"
        case .savings: return "Savings"
        case .cash: return "Cash"
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

    // MARK: - Data slicing

    /// Honors `DurableUserSettings.chartStartDate` if set — anything older is
    /// hidden so a user-initiated "Reset chart history" stays sticky even if
    /// stale rows haven't been physically purged from the store yet.
    private var chartFloor: Date? {
        guard let raw = userSettings.first?.chartStartDate else { return nil }
        return Calendar(identifier: .gregorian).startOfDay(for: raw)
    }

    private var trendPoints: [NetWorthTrendPoint] {
        cachedTrendPoints ?? []
    }

    private func filteredSnapshots() -> [NetWorthTrendPoint] {
        let cal = Calendar(identifier: .gregorian)
        let rangeCutoff = cal.date(byAdding: .month, value: -range.months, to: .now)
        let cutoffs = [rangeCutoff, chartFloor].compactMap { $0 }
        guard let effective = cutoffs.max() else { return trendPoints }
        return trendPoints.filter { $0.date >= effective }
    }

    private func monthDelta() -> Money? {
        let cal = Calendar(identifier: .gregorian)
        guard let target = cal.date(byAdding: .day, value: -30, to: .now) else { return nil }
        // Respect the chart floor too — comparing today to a snapshot before
        // the user's reset point would surface the very numbers they asked to
        // hide.
        let floor = chartFloor
        let priorSnap = trendPoints.last { snap in
            guard snap.date <= target else { return false }
            if let floor, snap.date < floor { return false }
            return true
        }
        guard let priorSnap else { return nil }
        return breakdown.netWorth - priorSnap.netWorth
    }
}

private struct NetWorthCategoryDetailView: View {
    let category: NetWorthCategory
    let entries: [NetWorthEntry]
    let total: Money

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Total")
                        .font(NwTypography.bodyEmphasis)
                    Spacer()
                    NwAmountText(
                        total,
                        variant: .body,
                        color: category.isLiability ? NwAppColors.liability : nil
                    )
                }
            }

            Section("Included") {
                if entries.isEmpty {
                    Text("No contributing accounts")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entries) { entry in
                        NavigationLink {
                            destination(for: entry)
                        } label: {
                            HStack(spacing: NwSpacing.md) {
                                category.icon.image
                                    .foregroundStyle(
                                        category.isLiability
                                            ? NwAppColors.liability
                                            : NwAppColors.primary
                                    )
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name)
                                    Text(entrySubtitle(entry))
                                        .font(NwTypography.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                NwAmountText(
                                    entry.amount,
                                    variant: .body,
                                    color: category.isLiability
                                        ? NwAppColors.liability
                                        : nil
                                )
                            }
                        }
                    }
                }
            }
        }
        .nwScreenBackground()
        .navigationTitle(category.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func destination(for entry: NetWorthEntry) -> some View {
        switch entry.destination {
        case .financialAccount(let account):
            FinancialAccountDetailView(account: account)
        case .manualAsset(let asset):
            ManualAssetDetailView(asset: asset)
        case .plaidInvestment(let account):
            PlaidInvestmentAccountDetailView(account: account)
        case .linkedIBR(let document):
            LinkedIBRLoanDetailView(document: document)
        }
    }

    private func entrySubtitle(_ entry: NetWorthEntry) -> String {
        guard let updatedAt = entry.updatedAt else { return entry.subtitle }
        return "\(entry.subtitle), updated \(updatedAt.formatted(.relative(presentation: .named)))"
    }
}

extension Notification.Name {
    public static let selectTab = Notification.Name("NetworthSelectTab")
    public static let showTutorial = Notification.Name("NetworthShowTutorial")
    public static let openSettings = Notification.Name("NetworthOpenSettings")
    public static let openTransactionReview = Notification.Name(
        "NetworthOpenTransactionReview"
    )
}
