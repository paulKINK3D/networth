import SwiftUI
import SwiftData
import Charts
import NetworthCore

struct NetWorthView: View {
    @Environment(AppContainerController.self) private var container
    @Query(sort: \DurableNetWorthSnapshot.date) private var snapshots: [DurableNetWorthSnapshot]
    @Query(sort: \CachedAccount.balanceMilliunits, order: .reverse) private var accounts: [CachedAccount]
    @Query(sort: \DurableManualAsset.name) private var manualAssets: [DurableManualAsset]
    @Query private var userSettings: [DurableUserSettings]

    @State private var range: Range = .twelveMonths
    @State private var showingTrendDetail = false

    enum Range: String, CaseIterable, Identifiable {
        case threeMonths = "3M"
        case sixMonths   = "6M"
        case twelveMonths = "1Y"
        case twoYears    = "2Y"
        var id: String { rawValue }
        var months: Int {
            switch self {
            case .threeMonths: return 3
            case .sixMonths:   return 6
            case .twelveMonths: return 12
            case .twoYears:    return 24
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NwSpacing.lg) {
                    if container.hasYNABToken == false {
                        NwBanner(
                            "Connect YNAB",
                            message: "Add your YNAB token in Settings to start tracking.",
                            tone: .info,
                            actionTitle: "Open Settings",
                            action: { NotificationCenter.default.post(name: .openSettings, object: nil) }
                        )
                    } else if case .error(let msg) = container.syncCoordinator.phase {
                        NwBanner(
                            "Sync issue",
                            message: msg,
                            tone: .caution,
                            actionTitle: "Retry",
                            action: { Task { await container.syncNow() } }
                        )
                    }

                    heroCard
                    breakdownCard
                    chartCard
                    manualAssetsCard
                }
                .padding(.horizontal, NwSpacing.screenPadding)
                .padding(.vertical, NwSpacing.lg)
            }
            .background(NwAppColors.background.ignoresSafeArea())
            .navigationTitle("Net Worth")
            .toolbar { syncToolbarItem }
            .refreshable {
                await container.syncNow()
            }
            .sheet(isPresented: $showingTrendDetail) {
                TrendDetailView().environment(container)
            }
        }
    }

    @ToolbarContentBuilder
    private var syncToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            switch container.syncCoordinator.phase {
            case .syncing(let label):
                HStack(spacing: NwSpacing.xs) {
                    ProgressView().controlSize(.small)
                    Text(label).font(NwTypography.caption).foregroundStyle(.secondary)
                }
            default:
                Menu {
                    Button {
                        Task { await container.syncNow() }
                    } label: {
                        Label("Refresh", systemImage: NwIcon.sync.rawValue)
                    }
                    .disabled(!container.hasYNABToken)

                    Button {
                        NotificationCenter.default.post(name: .openSettings, object: nil)
                    } label: {
                        Label("Settings", systemImage: NwIcon.settings.rawValue)
                    }
                } label: {
                    if case .error = container.syncCoordinator.phase {
                        NwIcon.warning.image.foregroundStyle(NwAppColors.caution)
                    } else {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    // MARK: - Cards

    private var breakdown: NetWorthBreakdown {
        container.snapshotScheduler.computeBreakdown()
    }

    private var heroCard: some View {
        let total = breakdown.netWorth
        let delta = monthDelta()
        return NwCard(style: .primary) {
            VStack(alignment: .leading, spacing: NwSpacing.sm) {
                Text("Current Net Worth")
                    .font(NwTypography.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                NwAmountText(total, variant: .hero, showCents: false)
                HStack(spacing: NwSpacing.sm) {
                    if let delta {
                        NwAmountText(delta, variant: .signed)
                        Text("vs. 30 days ago")
                            .font(NwTypography.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Snapshots will start appearing after your first sync.")
                            .font(NwTypography.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var breakdownCard: some View {
        let bd = breakdown
        return NwCard(style: .primary) {
            VStack(alignment: .leading, spacing: NwSpacing.md) {
                Text("Breakdown")
                    .font(NwTypography.headline)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: NwSpacing.md) {
                    NwMetricCapsule(label: "Cash", value: CurrencyFormatter.compact(bd.cash), valueColor: NwAppColors.positive, symbol: .cash)
                    NwMetricCapsule(label: "Investments", value: CurrencyFormatter.compact(bd.investments), valueColor: NwAppColors.accent, symbol: .investment)
                    NwMetricCapsule(label: "Manual Assets", value: CurrencyFormatter.compact(bd.manualAssets), symbol: .realEstate)
                    NwMetricCapsule(label: "Other Assets", value: CurrencyFormatter.compact(bd.otherAssets), symbol: .otherAsset)
                    NwMetricCapsule(label: "Cards", value: CurrencyFormatter.compact(bd.creditCardDebt), valueColor: NwAppColors.liability, symbol: .creditCard)
                    NwMetricCapsule(label: "Loans", value: CurrencyFormatter.compact(bd.loans), valueColor: NwAppColors.liability, symbol: .mortgage)
                }
                Divider().padding(.vertical, NwSpacing.xs)
                HStack {
                    Text("Assets")
                    Spacer()
                    NwAmountText(bd.totalAssets, variant: .body)
                }
                HStack {
                    Text("Liabilities")
                    Spacer()
                    NwAmountText(-bd.totalLiabilities, variant: .body, color: NwAppColors.liability)
                }
            }
        }
    }

    private var chartCard: some View {
        let visible = filteredSnapshots()
        return NwCard(style: .primary) {
            VStack(alignment: .leading, spacing: NwSpacing.md) {
                HStack {
                    Text("Trend")
                        .font(NwTypography.headline)
                    Spacer()
                    Button {
                        showingTrendDetail = true
                    } label: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    Picker("", selection: $range) {
                        ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                }
                if visible.count < 2 {
                    Text("Snapshots will appear after a few days of syncing.")
                        .foregroundStyle(.secondary)
                        .font(NwTypography.footnote)
                        .frame(height: 180, alignment: .center)
                        .frame(maxWidth: .infinity)
                } else {
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
                    }
                    .frame(height: 220)
                }
            }
        }
    }

    private var manualAssetsCard: some View {
        let assets = manualAssets.filter { !$0.deleted }
        return Group {
            if !assets.isEmpty {
                NwCard(style: .primary) {
                    VStack(alignment: .leading, spacing: NwSpacing.md) {
                        Text("Manual Assets")
                            .font(NwTypography.headline)
                        ForEach(assets) { asset in
                            HStack {
                                NwIcon.forAccountKind(asset.kindRaw).image
                                    .foregroundStyle(NwAppColors.accent)
                                VStack(alignment: .leading) {
                                    Text(asset.name)
                                        .font(NwTypography.body)
                                    Text(asset.kind.displayName)
                                        .font(NwTypography.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                NwAmountText(asset.currentValue, variant: .body)
                            }
                            if asset.id != assets.last?.id { Divider() }
                        }
                    }
                }
            }
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

    private func filteredSnapshots() -> [DurableNetWorthSnapshot] {
        let cal = Calendar(identifier: .gregorian)
        let rangeCutoff = cal.date(byAdding: .month, value: -range.months, to: .now)
        let cutoffs = [rangeCutoff, chartFloor].compactMap { $0 }
        guard let effective = cutoffs.max() else { return snapshots }
        return snapshots.filter { $0.date >= effective }
    }

    private func monthDelta() -> Money? {
        let cal = Calendar(identifier: .gregorian)
        guard let target = cal.date(byAdding: .day, value: -30, to: .now) else { return nil }
        // Respect the chart floor too — comparing today to a snapshot before
        // the user's reset point would surface the very numbers they asked to
        // hide.
        let floor = chartFloor
        let priorSnap = snapshots.last { snap in
            guard snap.date <= target else { return false }
            if let floor, snap.date < floor { return false }
            return true
        }
        guard let priorSnap else { return nil }
        return breakdown.netWorth - priorSnap.netWorth
    }
}

extension Notification.Name {
    public static let selectTab = Notification.Name("NetworthSelectTab")
    public static let showTutorial = Notification.Name("NetworthShowTutorial")
    public static let openSettings = Notification.Name("NetworthOpenSettings")
}
