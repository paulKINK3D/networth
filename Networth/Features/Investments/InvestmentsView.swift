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

private enum InvestmentHolding: Identifiable {
    case manual(DurableManualAsset)
    case plaid(CachedPlaidAccount)

    var id: String {
        switch self {
        case .manual(let asset): return "manual:\(asset.id.uuidString)"
        case .plaid(let account): return "plaid:\(account.id)"
        }
    }

    var name: String {
        switch self {
        case .manual(let asset): return asset.name.isEmpty ? "Untitled Asset" : asset.name
        case .plaid(let account): return account.name
        }
    }

    var subtitle: String {
        switch self {
        case .manual(let asset): return asset.kind.displayName
        case .plaid(let account):
            let kind = PlaidRetirementClassifier.isRetirement(
                subtype: account.subtype
            ) ? "Retirement" : "Brokerage"
            let institution = account.mask.map {
                "\(account.institutionName) •••• \($0)"
            } ?? account.institutionName
            return "\(kind) · \(institution)"
        }
    }

    var icon: NwIcon {
        switch self {
        case .manual(let asset):
            switch asset.kind {
            case .brokerage: return .brokerage
            case .retirement: return .retirement
            case .crypto: return .crypto
            default: return .otherAsset
            }
        case .plaid(let account):
            return PlaidRetirementClassifier.isRetirement(
                subtype: account.subtype
            ) ? .retirement : .brokerage
        }
    }

    var value: Money {
        switch self {
        case .manual(let asset): return asset.currentValue
        case .plaid(let account): return account.currentBalance ?? .zero
        }
    }
}

/// Category-scoped portfolio detail reached from the Net Worth balance sheet.
struct InvestmentsView: View {
    let scope: InvestmentCategoryScope

    @Environment(AppContainerController.self) private var container
    @Query(sort: \DurableManualAsset.name) private var manualAssets: [DurableManualAsset]
    @Query(sort: \CachedPlaidAccount.name) private var plaidAccounts: [CachedPlaidAccount]
    @Query private var plaidItems: [CachedPlaidItem]
    @Query private var plaidTreatments: [DurablePlaidAccountTreatment]
    @Query private var accountNicknames: [DurableAccountNickname]
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
            "\(manualAssets.count)", "\(plaidBalanceSnapshots.count)",
            "\(plaidAccounts.count)", "\(plaidTreatments.count)",
            "\(accountNicknames.count)",
            range.rawValue, scope.rawValue
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
                return await dataActor.build(
                    rangeMonths: rangeMonths,
                    scope: scope
                )
            }.value
            guard !Task.isCancelled else { return }
            cachedPoints = points
        }
    }

    private var manualInvestments: [DurableManualAsset] {
        manualAssets.filter {
            !$0.deleted && scope.includes(manualAssetKind: $0.kind)
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

    private var scopedPlaidAccounts: [CachedPlaidAccount] {
        plaidResolver.contributingPlaidAccounts.filter { account in
            if plaidResolver.matchedManualAssetID(for: account) != nil {
                return true
            }
            return scope.includes(plaidSubtype: account.subtype)
        }
    }

    private var totalValue: Money {
        unreplacedManualInvestments.map(\.currentValue).sum()
            + scopedPlaidAccounts.compactMap(\.currentBalance).sum()
    }

    private var holdings: [InvestmentHolding] {
        let values = unreplacedManualInvestments.map(InvestmentHolding.manual)
            + scopedPlaidAccounts.map(InvestmentHolding.plaid)
        return values.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return holdingName($0).localizedCaseInsensitiveCompare(
                holdingName($1)
            ) == .orderedAscending
        }
    }

    private var isEmpty: Bool { holdings.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NwSpacing.lg) {
                if pendingPlaidReviewCount > 0 {
                    NwInlineNotice(
                        "Review connected accounts",
                        message: "Review balances before inclusion.",
                        tone: .caution,
                        actionTitle: "Review",
                        action: { showingPlaidReview = true }
                    )
                } else if case .error(let message) = container.plaidSyncCoordinator.phase {
                    NwInlineNotice(
                        "Investment sync issue",
                        message: message,
                        tone: .caution,
                        actionTitle: "Retry",
                        action: { Task { await container.syncPlaidInvestments() } }
                    )
                }

                if isEmpty {
                    NwEmptyState(
                        title: "No \(scopeTitle.lowercased()) yet",
                        message: "Connect an account or add one manually.",
                        icon: scope == .retirement ? .retirement : .investment
                    )
                    .frame(minHeight: 320)
                } else if let points = cachedPoints {
                    heroCard(history: points)
                    trendCard(history: points)
                    holdingsSection
                } else {
                    // Cold load: history builds off the render path.
                    NwLoadingState("Loading \(scopeTitle.lowercased())…")
                        .frame(minHeight: 320)
                }
            }
            .padding(.horizontal, NwSpacing.screenPadding)
            .padding(.vertical, NwSpacing.lg)
        }
        .nwFrostedFieldBackground()
        .navigationTitle(scopeTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NwTopLevelMenu(
                    canRefresh: container.hasPlaidBackendToken,
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
                Text(holdingName(holding))
                    .font(NwTypography.bodyEmphasis)
                    .foregroundStyle(NwAppColors.textPrimary)
                Text(holding.subtitle)
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
        case .manual(let asset):
            ManualAssetDetailView(asset: asset)
                .environment(container)
        case .plaid(let account):
            PlaidInvestmentAccountDetailView(account: account)
        }
    }

    private func holdingName(_ holding: InvestmentHolding) -> String {
        switch holding {
        case .plaid(let account):
            return AccountDisplayNameResolver(nicknames: accountNicknames)
                .name(for: account)
        default:
            return holding.name
        }
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
        var dates = manualInvestments.map(\.lastUpdatedAt)
        dates += plaidItems.compactMap(\.lastSyncedAt)
        return dates.max()?.formatted(.relative(presentation: .named)) ?? "never"
    }

    private var pendingPlaidReviewCount: Int {
        plaidAccounts.filter {
            scope.includes(plaidSubtype: $0.subtype)
                && plaidTreatment(for: $0.id) == .pendingReview
        }.count
    }

    private var scopeTitle: String {
        scope == .retirement ? "Retirement" : "Investments"
    }

    private func plaidTreatment(for accountID: String) -> PlaidAccountTreatment {
        plaidTreatments.last(where: { $0.plaidAccountId == accountID })?.treatment
            ?? .pendingReview
    }
}

struct PlaidInvestmentAccountDetailView: View {
    @Environment(AppContainerController.self) private var container
    let account: CachedPlaidAccount
    @Query private var holdings: [CachedPlaidHolding]
    @Query private var securities: [CachedPlaidSecurity]
    @Query private var items: [CachedPlaidItem]
    @Query private var accountNicknames: [DurableAccountNickname]
    @Query private var treatments: [DurablePlaidAccountTreatment]
    @Query private var goalReserveAccounts: [DurableGoalReserveAccount]
    @State private var showingRename = false
    @State private var showingAccountReview = false
    @State private var accountUseError: String?

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
                        if displayName != account.name {
                            Text("Imported as \(account.name)")
                                .font(NwTypography.caption)
                                .foregroundStyle(.secondary)
                        }
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

                VStack(alignment: .leading, spacing: NwSpacing.md) {
                    Text("Used By")
                        .font(NwTypography.titleSmall)
                    NwCard(style: .primary, padding: 0) {
                        VStack(spacing: 0) {
                            Button {
                                showingAccountReview = true
                            } label: {
                                HStack {
                                    Text("Net Worth")
                                        .foregroundStyle(NwAppColors.textPrimary)
                                    Spacer()
                                    Text(netWorthTreatmentLabel)
                                        .foregroundStyle(.secondary)
                                    NwIcon.chevron.image
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                                .padding(NwSpacing.md)
                            }
                            .buttonStyle(.plain)

                            if canBackGoals {
                                Divider()
                                // Captured value: a Binding get that reads
                                // @Query results re-runs during SwiftUI's
                                // graph update and can wedge iOS 27 in an
                                // endless loop.
                                let goalsBacked = backsGoals
                                Toggle(
                                    "Back Goals",
                                    isOn: Binding(
                                        get: { goalsBacked },
                                        set: { setBacksGoals($0) }
                                    )
                                )
                                .tint(NwAppColors.primary)
                                .padding(NwSpacing.md)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: NwSpacing.md) {
                    Text("Connection")
                        .font(NwTypography.titleSmall)
                    NwCard(style: .primary, padding: 0) {
                        VStack(spacing: 0) {
                            LabeledContent("Source", value: "Plaid")
                                .padding(NwSpacing.md)
                            Divider()
                            LabeledContent(
                                "Status",
                                value: connectionStatus
                            )
                            .padding(NwSpacing.md)
                            Divider()
                            NavigationLink {
                                SettingsView(page: .connections)
                            } label: {
                                HStack {
                                    Text("Manage Connection")
                                        .foregroundStyle(
                                            NwAppColors.textPrimary
                                        )
                                    Spacer()
                                    NwIcon.chevron.image
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                                .padding(NwSpacing.md)
                            }
                            .buttonStyle(.plain)
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
        .nwFrostedFieldBackground()
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingRename = true
                } label: {
                    Image(systemName: "pencil.circle")
                }
                .accessibilityLabel("Rename account")
            }
        }
        .sheet(isPresented: $showingRename) {
            AccountNicknameSheet(
                plaidAccountId: account.id,
                providerName: account.name,
                currentName: displayName
            )
        }
        .sheet(isPresented: $showingAccountReview) {
            PlaidAccountReviewSheet().environment(container)
        }
        .alert(
            "Account Settings",
            isPresented: Binding(
                get: { accountUseError != nil },
                set: { if !$0 { accountUseError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { accountUseError = nil }
        } message: {
            Text(accountUseError ?? "Please try again.")
        }
    }

    private var displayName: String {
        AccountDisplayNameResolver(nicknames: accountNicknames)
            .name(for: account)
    }

    private var treatment: PlaidAccountTreatment {
        treatments.last { $0.plaidAccountId == account.id }?.treatment
            ?? .pendingReview
    }

    private var netWorthTreatmentLabel: String {
        switch treatment {
        case .pendingReview: "Needs Review"
        case .included, .duplicateYNAB: "Included"
        case .duplicateManualAsset: "Matched to Manual Asset"
        case .excluded: "Excluded"
        }
    }

    private var canBackGoals: Bool {
        account.currentBalanceMilliunits != nil
            && !PlaidRetirementClassifier.isRetirement(
                subtype: account.subtype
            )
            && treatment != .excluded
            && treatment != .duplicateManualAsset
    }

    private var backsGoals: Bool {
        goalReserveAccounts.contains {
            $0.active && $0.canonicalAccountId == account.id
        }
    }

    private func setBacksGoals(_ enabled: Bool) {
        guard enabled != backsGoals else { return }
        do {
            let service = GoalLedgerService(
                context: container.modelContainer.mainContext
            )
            if enabled {
                try service.addReserveAccount(
                    canonicalAccountId: account.id,
                    accountName: displayName,
                    institutionName: account.institutionName,
                    mask: account.mask ?? ""
                )
            } else if let row = goalReserveAccounts.first(where: {
                $0.active && $0.canonicalAccountId == account.id
            }) {
                try service.removeReserveAccount(row)
            }
        } catch {
            accountUseError = error.localizedDescription
        }
    }

    private var connectionStatus: String {
        guard let item = items.last(where: { $0.id == account.itemId }) else {
            return "Connected"
        }
        return item.status == "healthy" ? "Connected" : "Needs Attention"
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
    func build(
        rangeMonths: Int,
        scope: InvestmentCategoryScope
    ) -> [InvestmentHistoryBuilder.Point] {
        let calendar = Calendar(identifier: .gregorian)
        guard let start = calendar.date(
            byAdding: .month, value: -rangeMonths, to: .now
        ) else { return [] }
        let context = modelContext
        let manualAssets = (try? context.fetch(
            FetchDescriptor<DurableManualAsset>()
        )) ?? []
        let plaidSnapshots = (try? context.fetch(
            FetchDescriptor<DurablePlaidBalanceSnapshot>(
                sortBy: [SortDescriptor(\.date)]
            )
        )) ?? []
        let plaidAccounts = (try? context.fetch(
            FetchDescriptor<CachedPlaidAccount>()
        )) ?? []
        let manualInvestments = manualAssets.filter {
            !$0.deleted && scope.includes(manualAssetKind: $0.kind)
        }
        let manualInvestmentIDs = Set(manualInvestments.map(\.id))
        let subtypeByPlaidAccountID = Dictionary(
            uniqueKeysWithValues: plaidAccounts.map { ($0.id, $0.subtype) }
        )
        let scopedPlaidSnapshots = plaidSnapshots.filter { snapshot in
            if let manualAssetID = snapshot.matchedManualAssetId {
                return manualInvestmentIDs.contains(manualAssetID)
            }
            return scope.includes(
                plaidSubtype: subtypeByPlaidAccountID[snapshot.plaidAccountId]
                    ?? nil
            )
        }
        return InvestmentHistoryBuilder(calendar: calendar).build(
            accounts: [],
            manualAssets: manualInvestments.map { $0.toSnapshot() },
            plaidSnapshots: scopedPlaidSnapshots.map { $0.toHistorySnapshot() },
            from: start,
            to: .now
        )
    }
}
