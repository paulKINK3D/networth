import SwiftUI
import SwiftData
import Charts
import Combine
import NetworthCore

private enum InvestmentRange: String, CaseIterable, Identifiable {
    case threeMonths = "3M"
    case sixMonths = "6M"
    case oneYear = "1Y"
    case twoYears = "2Y"
    case fiveYears = "5Y"

    var id: String { rawValue }

    var months: Int {
        switch self {
        case .threeMonths: return 3
        case .sixMonths: return 6
        case .oneYear: return 12
        case .twoYears: return 24
        case .fiveYears: return 60
        }
    }
}

private struct InvestmentAllocation: Identifiable {
    let id: String
    let title: String
    let icon: NwIcon
    let amount: Money
}

private enum InvestmentHolding: Identifiable {
    case ynab(CachedAccount)
    case manual(DurableManualAsset)
    case plaid(CachedPlaidAccount)

    var id: String {
        switch self {
        case .ynab(let account): return "ynab:\(account.id)"
        case .manual(let asset): return "manual:\(asset.id.uuidString)"
        case .plaid(let account): return "plaid:\(account.id)"
        }
    }

    var name: String {
        switch self {
        case .ynab(let account): return account.name
        case .manual(let asset): return asset.name.isEmpty ? "Untitled Asset" : asset.name
        case .plaid(let account): return account.name
        }
    }

    var subtitle: String {
        switch self {
        case .ynab: return "YNAB Investment"
        case .manual(let asset): return asset.kind.displayName
        case .plaid(let account):
            return account.mask.map { "\(account.institutionName) •••• \($0)" }
                ?? account.institutionName
        }
    }

    var icon: NwIcon {
        switch self {
        case .ynab: return .investment
        case .manual(let asset):
            switch asset.kind {
            case .brokerage: return .brokerage
            case .retirement: return .retirement
            case .crypto: return .crypto
            default: return .otherAsset
            }
        case .plaid:
            return .brokerage
        }
    }

    var value: Money {
        switch self {
        case .ynab(let account): return account.balance
        case .manual(let asset): return asset.currentValue
        case .plaid(let account): return account.currentBalance ?? .zero
        }
    }
}

/// Portfolio view for YNAB investment accounts and manually tracked brokerage,
/// retirement, and crypto holdings.
struct InvestmentsView: View {
    @Environment(AppContainerController.self) private var container
    @Query(sort: \CachedAccount.name) private var accounts: [CachedAccount]
    @Query(sort: \DurableManualAsset.name) private var manualAssets: [DurableManualAsset]
    @Query private var userSettings: [DurableUserSettings]
    @Query(sort: \CachedPlaidAccount.name) private var plaidAccounts: [CachedPlaidAccount]
    @Query private var plaidItems: [CachedPlaidItem]
    @Query private var plaidTreatments: [DurablePlaidAccountTreatment]
    @Query(sort: \DurablePlaidBalanceSnapshot.date) private var plaidBalanceSnapshots: [DurablePlaidBalanceSnapshot]

    @State private var range: InvestmentRange = .oneYear
    @State private var scrubbedDate: Date?
    @State private var showingPlaidReview = false
    /// History cache: rebuilding daily balance histories from the transaction
    /// table must never run per body evaluation (chart scrubbing re-evaluates
    /// continuously). Refreshed on range change and once per debounced save
    /// burst — and only while this tab is visible.
    @State private var cachedPoints: [InvestmentHistoryBuilder.Point]?
    @State private var cacheFingerprint = ""
    @State private var isVisible = false

    private static let saveEvents: AnyPublisher<Notification, Never> =
        NotificationCenter.default
            .publisher(for: .networthModelContextSaved)
            .debounce(for: .seconds(0.6), scheduler: RunLoop.main)
            .eraseToAnyPublisher()

    private var inputFingerprint: String {
        [
            "\(accounts.count)",
            "\(manualAssets.count)", "\(plaidBalanceSnapshots.count)",
            "\(plaidAccounts.count)", "\(plaidTreatments.count)",
            range.rawValue
        ].joined(separator: "|")
    }

    @State private var refreshTask: Task<Void, Never>?

    private func refreshCache(force: Bool = false) {
        let fingerprint = inputFingerprint
        guard force || cachedPoints == nil || cacheFingerprint != fingerprint
        else { return }
        cacheFingerprint = fingerprint
        let rangeMonths = range.months
        let modelContainer = container.modelContainer
        refreshTask?.cancel()
        refreshTask = Task {
            // Detached: @ModelActor inherits the creating executor; built on
            // main it would compute on main.
            let points = await Task.detached(priority: .userInitiated) {
                let dataActor = InvestmentsDataActor(
                    modelContainer: modelContainer
                )
                return await dataActor.build(rangeMonths: rangeMonths)
            }.value
            guard !Task.isCancelled else { return }
            cachedPoints = points
        }
    }

    private static let investmentManualKinds: Set<ManualAssetKind> = [
        .brokerage, .retirement, .crypto
    ]

    private var ynabInvestments: [CachedAccount] {
        accounts.filter { !$0.deleted && !$0.closed && $0.kind == .investment }
    }

    private var historicalYNABInvestments: [CachedAccount] {
        accounts.filter { !$0.deleted && $0.kind == .investment }
    }

    private var manualInvestments: [DurableManualAsset] {
        manualAssets.filter {
            !$0.deleted && Self.investmentManualKinds.contains($0.kind)
        }
    }

    private var plaidResolver: PlaidContributionResolver {
        PlaidContributionResolver(
            plaidAccounts: plaidAccounts,
            treatments: plaidTreatments,
            manualAssets: manualInvestments
        )
    }

    private var unreplacedManualInvestments: [DurableManualAsset] {
        manualInvestments.filter { !plaidResolver.isReplacing($0) }
    }

    private var totalValue: Money {
        ynabInvestments.map(\.balance).sum()
            + unreplacedManualInvestments.map(\.currentValue).sum()
            + plaidResolver.contributingPlaidAccounts.compactMap(\.currentBalance).sum()
    }

    private var holdings: [InvestmentHolding] {
        let values = ynabInvestments.map(InvestmentHolding.ynab)
            + unreplacedManualInvestments.map(InvestmentHolding.manual)
            + plaidResolver.contributingPlaidAccounts.map(InvestmentHolding.plaid)
        return values.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var isEmpty: Bool { holdings.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NwSpacing.lg) {
                    if pendingPlaidReviewCount > 0 {
                        NwBanner(
                            "Review connected accounts",
                            message: "Review balances before inclusion.",
                            tone: .caution,
                            actionTitle: "Review",
                            action: { showingPlaidReview = true }
                        )
                    } else if case .error(let message) = container.plaidSyncCoordinator.phase {
                        NwBanner(
                            "Investment sync issue",
                            message: message,
                            tone: .caution,
                            actionTitle: "Retry",
                            action: { Task { await container.syncPlaidInvestments() } }
                        )
                    }

                    if isEmpty {
                        NwEmptyState(
                            title: "No investments yet",
                            message: "Connect an investment account or add one manually.",
                            icon: .investment
                        )
                        .frame(minHeight: 320)
                    } else if let points = cachedPoints {
                        heroCard(history: points)
                        trendCard(history: points)
                        allocationSection
                        holdingsSection
                    } else {
                        // Cold load: history builds off the render path.
                        NwLoadingState("Loading investments…")
                            .frame(minHeight: 320)
                    }
                }
                .padding(.horizontal, NwSpacing.screenPadding)
                .padding(.vertical, NwSpacing.lg)
            }
            .background(NwAppColors.background.ignoresSafeArea())
            .navigationTitle("Investments")
            .sheet(isPresented: $showingPlaidReview) {
                PlaidAccountReviewSheet().environment(container)
            }
            .task { refreshCache() }
            .onAppear {
                isVisible = true
                refreshCache()
            }
            .onDisappear { isVisible = false }
            .onChange(of: range) { _, _ in refreshCache(force: true) }
            .onReceive(Self.saveEvents) { _ in
                if isVisible {
                    refreshCache(force: true)
                } else {
                    cacheFingerprint = ""
                }
            }
        }
    }

    private func heroCard(history: [InvestmentHistoryBuilder.Point]) -> some View {
        let change = thirtyDayChange(in: history)
        return NwCard(style: .primary) {
            VStack(alignment: .leading, spacing: NwSpacing.md) {
                NwAmountText(totalValue, variant: .hero, showCents: false)

                if let change {
                    HStack(spacing: NwSpacing.xs) {
                        (change.isNegative ? NwIcon.arrowDown : NwIcon.arrowUp).image
                        NwAmountText(
                            change,
                            variant: .signed,
                            showCents: false,
                            color: change.isNegative
                                ? NwAppColors.liability
                                : NwAppColors.positive
                        )
                        Text("balance change over 30 days")
                            .font(NwTypography.footnote)
                    }
                    .foregroundStyle(
                        change.isNegative ? NwAppColors.liability : NwAppColors.positive
                    )
                }

                Text("Updated \(lastUpdatedText)")
                    .font(NwTypography.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func trendCard(history: [InvestmentHistoryBuilder.Point]) -> some View {
        let points = sampledHistoryPoints(from: history)
        let selected = selectedPoint(in: points)
        return NwCard(style: .primary) {
            VStack(alignment: .leading, spacing: NwSpacing.md) {
                Text("Balance Trend")
                    .font(NwTypography.headline)

                Picker("Investment history range", selection: $range) {
                    ForEach(InvestmentRange.allCases) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)

                if let selected {
                    HStack {
                        Text(DateDisplay.shortDate(selected.date))
                            .font(NwTypography.footnoteEm)
                            .foregroundStyle(.secondary)
                        Spacer()
                        NwAmountText(selected.value, variant: .body, showCents: false)
                    }
                }

                if points.count < 2 {
                    Text("More history needed.")
                        .font(NwTypography.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
                } else {
                    Chart(points) { point in
                        AreaMark(
                            x: .value("Date", point.date),
                            y: .value("Balance", point.value.doubleValue)
                        )
                        .foregroundStyle(.linearGradient(
                            colors: [NwAppColors.accent.opacity(0.35), NwAppColors.accent.opacity(0.03)],
                            startPoint: .top,
                            endPoint: .bottom
                        ))

                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("Balance", point.value.doubleValue)
                        )
                        .foregroundStyle(NwAppColors.primary)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))

                        if let scrubbedDate {
                            RuleMark(x: .value("Selected date", scrubbedDate))
                                .foregroundStyle(NwAppColors.primary.opacity(0.5))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                    }
                    .chartXSelection(value: $scrubbedDate)
                    .frame(height: 220)
                }
            }
        }
        .onChange(of: range) { _, _ in scrubbedDate = nil }
    }

    private var allocationSection: some View {
        VStack(alignment: .leading, spacing: NwSpacing.md) {
            Text("Allocation")
                .font(NwTypography.titleSmall)

            NwCard(style: .primary, padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(allocations.enumerated()), id: \.element.id) { index, allocation in
                        allocationRow(allocation)
                        if index < allocations.count - 1 {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
            }
        }
    }

    private func allocationRow(_ allocation: InvestmentAllocation) -> some View {
        let share = allocationShare(for: allocation.amount)
        return HStack(spacing: NwSpacing.md) {
            allocation.icon.image
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(NwAppColors.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: NwSpacing.xs) {
                HStack {
                    Text(allocation.title)
                        .font(NwTypography.bodyEmphasis)
                    Spacer()
                    Text(share.formatted(.percent.precision(.fractionLength(0))))
                        .font(NwTypography.footnoteEm)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: max(0, min(1, share)))
                    .tint(NwAppColors.accent)
            }
            NwAmountText(allocation.amount, variant: .body, showCents: false)
                .frame(minWidth: 76, alignment: .trailing)
        }
        .padding(NwSpacing.md)
    }

    private var holdingsSection: some View {
        VStack(alignment: .leading, spacing: NwSpacing.md) {
            Text("Holdings")
                .font(NwTypography.titleSmall)

            NwCard(style: .primary, padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(holdings.enumerated()), id: \.element.id) { index, holding in
                        NavigationLink {
                            holdingDestination(holding)
                        } label: {
                            holdingRow(holding)
                        }
                        .buttonStyle(.plain)

                        if index < holdings.count - 1 {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
            }
        }
    }

    private func holdingRow(_ holding: InvestmentHolding) -> some View {
        HStack(spacing: NwSpacing.md) {
            holding.icon.image
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(NwAppColors.primary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(holding.name)
                    .font(NwTypography.bodyEmphasis)
                    .foregroundStyle(NwAppColors.textPrimary)
                Text("\(holding.subtitle), \(holdingShareText(holding.value))")
                    .font(NwTypography.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            NwAmountText(holding.value, variant: .body, showCents: false)
            NwIcon.chevron.image
                .font(NwTypography.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(NwSpacing.md)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func holdingDestination(_ holding: InvestmentHolding) -> some View {
        switch holding {
        case .ynab(let account):
            InvestmentAccountDetailView(account: account)
        case .manual(let asset):
            ManualAssetDetailView(asset: asset)
                .environment(container)
        case .plaid(let account):
            PlaidInvestmentAccountDetailView(account: account)
        }
    }

    private var allocations: [InvestmentAllocation] {
        var result: [InvestmentAllocation] = []
        let ynabTotal = ynabInvestments.map(\.balance).sum()
        if !ynabTotal.isZero {
            result.append(InvestmentAllocation(
                id: "ynab",
                title: "YNAB Investments",
                icon: .investment,
                amount: ynabTotal
            ))
        }

        let plaidTotal = plaidResolver.contributingPlaidAccounts
            .compactMap(\.currentBalance)
            .sum()
        if !plaidTotal.isZero {
            result.append(InvestmentAllocation(
                id: "plaid",
                title: "Connected Investments",
                icon: .brokerage,
                amount: plaidTotal
            ))
        }

        let kinds: [(ManualAssetKind, String, NwIcon)] = [
            (.brokerage, "Brokerage", .brokerage),
            (.retirement, "Retirement", .retirement),
            (.crypto, "Crypto", .crypto)
        ]
        for (kind, title, icon) in kinds {
            let amount = unreplacedManualInvestments
                .filter { $0.kind == kind }
                .map(\.currentValue)
                .sum()
            if !amount.isZero {
                result.append(InvestmentAllocation(
                    id: kind.rawValue,
                    title: title,
                    icon: icon,
                    amount: amount
                ))
            }
        }
        return result.sorted { $0.amount > $1.amount }
    }

    private func allocationShare(for amount: Money) -> Double {
        guard totalValue > .zero else { return 0 }
        return amount.doubleValue / totalValue.doubleValue
    }

    private func holdingShareText(_ amount: Money) -> String {
        allocationShare(for: amount).formatted(.percent.precision(.fractionLength(0)))
    }


    private func sampledHistoryPoints(
        from points: [InvestmentHistoryBuilder.Point]
    ) -> [InvestmentHistoryBuilder.Point] {
        let stride = max(1, points.count / 260)
        var sampled = points.enumerated().compactMap { index, point in
            index.isMultiple(of: stride) ? point : nil
        }
        if let last = points.last, sampled.last?.date != last.date {
            sampled.append(last)
        }
        return sampled
    }

    private func selectedPoint(
        in points: [InvestmentHistoryBuilder.Point]
    ) -> InvestmentHistoryBuilder.Point? {
        guard let scrubbedDate else { return points.last }
        return points.min {
            abs($0.date.timeIntervalSince(scrubbedDate))
                < abs($1.date.timeIntervalSince(scrubbedDate))
        }
    }

    private func thirtyDayChange(
        in points: [InvestmentHistoryBuilder.Point]
    ) -> Money? {
        let calendar = Calendar(identifier: .gregorian)
        guard let target = calendar.date(byAdding: .day, value: -30, to: .now),
              let prior = points.last(where: { $0.date <= target }) else {
            return nil
        }
        return totalValue - prior.value
    }

    private var lastUpdatedText: String {
        var dates = ynabInvestments.map(\.updatedAt) + manualInvestments.map(\.lastUpdatedAt)
        dates += plaidItems.compactMap(\.lastSyncedAt)
        if let syncDate = userSettings.first?.lastSyncedAt {
            dates.append(syncDate)
        }
        return dates.max()?.formatted(.relative(presentation: .named)) ?? "never"
    }

    private var pendingPlaidReviewCount: Int {
        plaidAccounts.filter { plaidTreatment(for: $0.id) == .pendingReview }.count
    }

    private func plaidTreatment(for accountID: String) -> PlaidAccountTreatment {
        plaidTreatments.last(where: { $0.plaidAccountId == accountID })?.treatment
            ?? .pendingReview
    }
}

private struct InvestmentAccountDetailView: View {
    let account: CachedAccount
    @Query private var transactions: [CachedTransaction]

    init(account: CachedAccount) {
        self.account = account
        let accountId = account.id
        _transactions = Query(
            filter: #Predicate<CachedTransaction> {
                $0.accountId == accountId && $0.deleted == false
            },
            sort: [SortDescriptor(\.date, order: .reverse)]
        )
    }

    var body: some View {
        let points = historyPoints
        ScrollView {
            VStack(alignment: .leading, spacing: NwSpacing.lg) {
                NwCard(style: .primary) {
                    VStack(alignment: .leading, spacing: NwSpacing.md) {
                        Text("BALANCE")
                            .font(NwTypography.caption)
                            .foregroundStyle(.secondary)
                        NwAmountText(account.balance, variant: .large)
                        if let change = thirtyDayChange(in: points) {
                            HStack(spacing: NwSpacing.xs) {
                                NwAmountText(
                                    change,
                                    variant: .signed,
                                    showCents: false,
                                    color: change.isNegative
                                        ? NwAppColors.liability
                                        : NwAppColors.positive
                                )
                                Text("balance change over 30 days")
                                    .font(NwTypography.footnote)
                            }
                        }
                        Divider()
                        HStack(spacing: NwSpacing.xl) {
                            balanceMetric(
                                "Cleared",
                                Money(milliunits: account.clearedMilliunits)
                            )
                            balanceMetric(
                                "Pending",
                                Money(milliunits: account.unclearedMilliunits)
                            )
                        }
                        Text("Updated \(account.updatedAt.formatted(.relative(presentation: .named)))")
                            .font(NwTypography.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                NwCard(style: .primary) {
                    VStack(alignment: .leading, spacing: NwSpacing.md) {
                        Text("Balance Trend")
                            .font(NwTypography.headline)
                        if points.count < 2 {
                            Text("More history needed.")
                                .font(NwTypography.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
                        } else {
                            Chart(points) { point in
                                LineMark(
                                    x: .value("Date", point.date),
                                    y: .value("Balance", point.value.doubleValue)
                                )
                                .foregroundStyle(NwAppColors.primary)
                                .lineStyle(StrokeStyle(lineWidth: 2.5))
                            }
                            .frame(height: 190)
                        }
                    }
                }

                if !transactions.isEmpty {
                    VStack(alignment: .leading, spacing: NwSpacing.md) {
                        Text("Recent Activity")
                            .font(NwTypography.titleSmall)
                        NwCard(style: .primary, padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(transactions.prefix(20).enumerated()), id: \.element.id) { index, transaction in
                                    transactionRow(transaction)
                                    if index < min(transactions.count, 20) - 1 {
                                        Divider().padding(.leading, NwSpacing.md)
                                    }
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
        .navigationTitle(account.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func balanceMetric(_ title: String, _ value: Money) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(NwTypography.caption)
                .foregroundStyle(.secondary)
            NwAmountText(value, variant: .body, showCents: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func transactionRow(_ transaction: CachedTransaction) -> some View {
        HStack(spacing: NwSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.payeeName ?? transaction.memo ?? "Transaction")
                    .font(NwTypography.body)
                Text(transactionSubtitle(transaction))
                    .font(NwTypography.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            NwAmountText(
                Money(milliunits: transaction.amountMilliunits),
                variant: .signed,
                color: transaction.amountMilliunits < 0
                    ? NwAppColors.liability
                    : NwAppColors.positive
            )
        }
        .padding(NwSpacing.md)
    }

    private func transactionSubtitle(_ transaction: CachedTransaction) -> String {
        let date = DateDisplay.shortDate(transaction.date)
        guard let category = transaction.categoryName, !category.isEmpty else { return date }
        return "\(date), \(category)"
    }

    private var historyPoints: [InvestmentHistoryBuilder.Point] {
        let calendar = Calendar(identifier: .gregorian)
        guard let start = calendar.date(byAdding: .year, value: -1, to: .now) else {
            return []
        }
        return InvestmentHistoryBuilder(calendar: calendar).build(
            accounts: [InvestmentHistoryBuilder.Account(
                id: account.id,
                currentBalance: account.balance,
                transactions: transactions.map { $0.toSummary() }
            )],
            manualAssets: [],
            from: start,
            to: .now
        )
    }

    private func thirtyDayChange(
        in points: [InvestmentHistoryBuilder.Point]
    ) -> Money? {
        let calendar = Calendar(identifier: .gregorian)
        guard let target = calendar.date(byAdding: .day, value: -30, to: .now),
              let prior = points.last(where: { $0.date <= target }) else {
            return nil
        }
        return account.balance - prior.value
    }
}

private struct PlaidInvestmentAccountDetailView: View {
    let account: CachedPlaidAccount
    @Query private var holdings: [CachedPlaidHolding]
    @Query private var securities: [CachedPlaidSecurity]
    @Query private var items: [CachedPlaidItem]

    init(account: CachedPlaidAccount) {
        self.account = account
        let accountID = account.id
        _holdings = Query(
            filter: #Predicate<CachedPlaidHolding> { $0.accountId == accountID },
            sort: [SortDescriptor(\.institutionValueMilliunits, order: .reverse)]
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NwSpacing.lg) {
                NwCard(style: .primary) {
                    VStack(alignment: .leading, spacing: NwSpacing.md) {
                        Text("BALANCE")
                            .font(NwTypography.caption)
                            .foregroundStyle(.secondary)
                        NwAmountText(account.currentBalance ?? .zero, variant: .large)
                        HStack(spacing: NwSpacing.xl) {
                            balanceMetric("Holdings", holdingsTotal)
                            if !reconciliationDifference.isZero {
                                balanceMetric("Other", reconciliationDifference)
                            }
                        }
                        if let updated = items.first(where: { $0.id == account.itemId })?.lastSyncedAt {
                            Text("Updated \(updated.formatted(.relative(presentation: .named)))")
                                .font(NwTypography.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !holdings.isEmpty {
                    VStack(alignment: .leading, spacing: NwSpacing.md) {
                        Text("Holdings")
                            .font(NwTypography.titleSmall)
                        NwCard(style: .primary, padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(holdings.enumerated()), id: \.element.id) { index, holding in
                                    holdingRow(holding)
                                    if index < holdings.count - 1 {
                                        Divider().padding(.leading, NwSpacing.md)
                                    }
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
        .navigationTitle(account.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var securityByID: [String: CachedPlaidSecurity] {
        Dictionary(uniqueKeysWithValues: securities.map { ($0.id, $0) })
    }

    private var holdingsTotal: Money {
        holdings.map(\.institutionValue).sum()
    }

    private var reconciliationDifference: Money {
        (account.currentBalance ?? .zero) - holdingsTotal
    }

    private func balanceMetric(_ title: String, _ value: Money) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(NwTypography.caption)
                .foregroundStyle(.secondary)
            NwAmountText(value, variant: .body, showCents: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func holdingRow(_ holding: CachedPlaidHolding) -> some View {
        let security = securityByID[holding.securityId]
        return HStack(alignment: .firstTextBaseline, spacing: NwSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(security?.name ?? security?.tickerSymbol ?? "Holding")
                    .font(NwTypography.bodyEmphasis)
                Text(holdingSubtitle(holding, security: security))
                    .font(NwTypography.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                NwAmountText(holding.institutionValue, variant: .body, showCents: false)
                if let costBasis = holding.costBasisMilliunits.map(Money.init(milliunits:)) {
                    Text("Cost \(CurrencyFormatter.compact(costBasis))")
                        .font(NwTypography.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(NwSpacing.md)
    }

    private func holdingSubtitle(
        _ holding: CachedPlaidHolding,
        security: CachedPlaidSecurity?
    ) -> String {
        var values: [String] = []
        if let ticker = security?.tickerSymbol, !ticker.isEmpty {
            values.append(ticker)
        }
        if let quantity = holding.quantity {
            values.append("\(NSDecimalNumber(decimal: quantity).stringValue) shares")
        }
        return values.isEmpty ? "Position" : values.joined(separator: " · ")
    }
}

/// Off-main reconstruction of the investment balance history. Owns its own
/// ModelContext; the view renders only finished results.
@ModelActor
private actor InvestmentsDataActor {
    func build(rangeMonths: Int) -> [InvestmentHistoryBuilder.Point] {
        let calendar = Calendar(identifier: .gregorian)
        guard let start = calendar.date(
            byAdding: .month, value: -rangeMonths, to: .now
        ) else { return [] }
        let context = modelContext
        let transactions = (try? context.fetch(
            FetchDescriptor<CachedTransaction>(
                predicate: #Predicate { $0.date >= start && !$0.deleted }
            )
        )) ?? []
        let accounts = (try? context.fetch(
            FetchDescriptor<CachedAccount>()
        )) ?? []
        let manualAssets = (try? context.fetch(
            FetchDescriptor<DurableManualAsset>()
        )) ?? []
        let plaidSnapshots = (try? context.fetch(
            FetchDescriptor<DurablePlaidBalanceSnapshot>(
                sortBy: [SortDescriptor(\.date)]
            )
        )) ?? []
        let historicalInvestments = accounts.filter {
            !$0.deleted && $0.kind == .investment
        }
        let manualInvestments = manualAssets.filter {
            !$0.deleted
                && [.brokerage, .retirement, .crypto].contains($0.kind)
        }
        let byAccount = Dictionary(
            grouping: transactions
        ) { $0.accountId }
        let inputs = historicalInvestments.map { account in
            InvestmentHistoryBuilder.Account(
                id: account.id,
                currentBalance: account.balance,
                transactions: (byAccount[account.id] ?? [])
                    .map { $0.toSummary() }
            )
        }
        return InvestmentHistoryBuilder(calendar: calendar).build(
            accounts: inputs,
            manualAssets: manualInvestments.map { $0.toSnapshot() },
            plaidSnapshots: plaidSnapshots.map { $0.toHistorySnapshot() },
            from: start,
            to: .now
        )
    }
}
