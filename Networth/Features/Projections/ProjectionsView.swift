import SwiftUI
import SwiftData
import Charts
import NetworthCore

/// Top-level so sibling files (filter sheet, transactions drill-down) can refer
/// to it. Identifies a category's aggregated *net* spend within the lookback
/// window. `total` = outflows − inflows (positive when category net-spends,
/// negative when refunds/credits exceed spending).
struct CategorySpendingRow: Identifiable, Hashable {
    let id: String
    let name: String
    let groupName: String
    let total: Money
    let inflow: Money
    let txnCount: Int

    var hasInflow: Bool { !inflow.isZero }
}

struct ProjectionsView: View {
    @Environment(AppContainerController.self) private var container
    @Query(sort: \CachedAccount.name) private var accounts: [CachedAccount]
    @Query(sort: \CachedScheduledTransaction.nextDate) private var scheduled: [CachedScheduledTransaction]
    @Query private var allTransactions: [CachedTransaction]
    @Query private var categories: [CachedCategory]
    @Query(sort: \DurableCardSettings.accountId) private var cardSettings: [DurableCardSettings]
    @Query private var userSettings: [DurableUserSettings]
    @Query private var exclusions: [DurableExcludedSpendCategory]

    init() {
        // Bound the historical-transactions query so we never pull years of
        // data into memory. 365 days comfortably covers the max 180-day
        // variable-spend lookback plus the per-category breakdown.
        let cutoff = Calendar(identifier: .gregorian)
            .date(byAdding: .day, value: -365, to: .now) ?? .distantPast
        _allTransactions = Query(
            filter: #Predicate<CachedTransaction> { $0.date >= cutoff && !$0.deleted },
            sort: [SortDescriptor(\CachedTransaction.date, order: .reverse)]
        )
    }

    var body: some View {
        // Map CachedTransaction → TransactionSummary ONCE per render. Each
        // toSummary() call decodes the JSON-encoded subtransactions; doing it
        // three times (one per consumer) was the main source of the tab-switch
        // lag.
        let history = allTransactions.filter { !$0.deleted }.map { $0.toSummary() }
        let projection = cashProjection(history: history)
        let cards = cardProjections(history: history)
        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NwSpacing.lg) {
                    if cards.isEmpty && projection.pointsWithVariable.isEmpty {
                        NwEmptyState(
                            title: "Nothing to project yet",
                            message: "Add your YNAB token in Settings and set statement-close days on your credit cards.",
                            icon: .projections
                        )
                        .frame(minHeight: 320)
                    } else {
                        if !cards.isEmpty {
                            CCForecastSection(projections: cards)
                        }
                        if !projection.pointsWithVariable.isEmpty {
                            cashCard(projection: projection)
                        }
                        if !projection.alerts.isEmpty {
                            alertsCard(alerts: projection.alerts)
                        }
                        if !history.isEmpty {
                            CategorySpendingCard(history: history)
                                .environment(container)
                        }
                    }
                }
                .padding(.horizontal, NwSpacing.screenPadding)
                .padding(.vertical, NwSpacing.lg)
            }
            .background(NwAppColors.background.ignoresSafeArea())
            .navigationTitle("Projections")
        }
    }

    // MARK: - Data

    private var horizon: Int {
        userSettings.first?.projectionHorizonDays ?? 90
    }

    private var dipThreshold: Money {
        Money(milliunits: userSettings.first?.dipThresholdMilliunits ?? 500_000)
    }

    private func cardProjections(history: [TransactionSummary]) -> [StatementProjection] {
        let forecaster = CCPaymentForecaster()
        let scheduledSummaries = scheduled.filter { !$0.deleted }.map { $0.toSummary() }
        // Pre-group already-summarized history by accountId so each per-card
        // forecast walks just that card's slice.
        var historyByAccount: [String: [TransactionSummary]] = [:]
        for txn in history {
            historyByAccount[txn.accountId, default: []].append(txn)
        }
        let exclusions = excludedCategoryIds
        let outflowHidden = hiddenOutflowOnlyCategoryIds
        let spendIds = spendAccountIds
        let lookback = lookbackDays
        return accounts.filter { !$0.deleted && !$0.closed && $0.kind.isCreditCardLike }
            .compactMap { card in
                guard let setting = cardSettings.first(where: { $0.accountId == card.id }) else {
                    return nil
                }
                return forecaster.forecast(
                    card: card.toSnapshot(),
                    settings: setting.toCore(),
                    scheduled: scheduledSummaries,
                    historicalTransactions: historyByAccount[card.id] ?? [],
                    excludedCategoryIds: exclusions,
                    outflowOnlyExcludedCategoryIds: outflowHidden,
                    spendAccountIds: spendIds,
                    lookbackDays: lookback,
                    asOf: .now
                )
            }
    }

    private var lookbackDays: Int {
        userSettings.first?.spendingLookbackDays ?? 60
    }

    /// User-hidden categories (`hidden: true` and NOT in YNAB's special
    /// Internal Master Category group). These are archived by the user and
    /// should be fully excluded from spending and projection math.
    private var userHiddenCategoryIds: Set<String> {
        Set(categories.filter {
            $0.hidden && !$0.deleted && $0.groupName != "Internal Master Category"
        }.map { $0.id })
    }

    /// YNAB Internal Master Category members (e.g. "Inflow: Ready to Assign").
    /// Hidden but system-managed — we keep their inflows so paychecks count.
    private var internalMasterCategoryIds: Set<String> {
        Set(categories.filter {
            $0.hidden && !$0.deleted && $0.groupName == "Internal Master Category"
        }.map { $0.id })
    }

    /// User-explicit exclusions + user-hidden categories — apply both directions.
    private var excludedCategoryIds: Set<String> {
        Set(exclusions.map { $0.categoryId }).union(userHiddenCategoryIds)
    }

    /// Outflow-only filter: applied solely to negative amounts. Used for the
    /// Internal Master Category so inflows like "Ready to Assign" still count
    /// but stray outflows (rare) don't pollute spend.
    private var hiddenOutflowOnlyCategoryIds: Set<String> {
        internalMasterCategoryIds
    }

    /// All spend-type accounts (cash + credit card), **including closed ones**.
    /// YNAB hides closed accounts from its sidebar, but a transfer from an
    /// active account to a closed one is still an internal money movement —
    /// not real spend. Use this set for the transfer filter.
    private var spendAccountIds: Set<String> {
        Set(accounts.filter { !$0.deleted && $0.kind.isSpendAccount }.map { $0.id })
    }

    private func cashProjection(history: [TransactionSummary]) -> CashPositionProjector.Result {
        let projector = CashPositionProjector()
        let cashAccounts = accounts
            .filter { !$0.deleted && !$0.closed && $0.kind.isCashLike }
            .map { $0.toSnapshot() }
        let scheduledSummaries = scheduled.filter { !$0.deleted }.map { $0.toSummary() }
        return projector.project(
            cashAccounts: cashAccounts,
            scheduled: scheduledSummaries,
            historicalTransactions: history,
            excludedCategoryIds: excludedCategoryIds,
            outflowOnlyExcludedCategoryIds: hiddenOutflowOnlyCategoryIds,
            spendAccountIds: spendAccountIds,
            lookbackDays: lookbackDays,
            asOf: .now,
            horizonDays: horizon,
            dipThreshold: dipThreshold
        )
    }

    private func cashCard(projection: CashPositionProjector.Result) -> some View {
        NwCard(style: .primary) {
            VStack(alignment: .leading, spacing: NwSpacing.md) {
                HStack {
                    Text("Cash Position — Next \(horizon) Days")
                        .font(NwTypography.headline)
                    Spacer()
                    if projection.hasVariableProjection {
                        let net = projection.dailyVariableNet
                        let label = net.isNegative
                            ? "≈ \(CurrencyFormatter.compact(net.absolute))/day net drain"
                            : "≈ \(CurrencyFormatter.compact(net))/day net inflow"
                        Text(label)
                            .font(NwTypography.footnote)
                            .foregroundStyle(net.isNegative ? NwAppColors.liability : NwAppColors.positive)
                    }
                }

                Chart {
                    ForEach(projection.scheduledPoints) { point in
                        AreaMark(
                            x: .value("Date", point.date),
                            y: .value("Balance", point.balance.doubleValue)
                        )
                        .foregroundStyle(.linearGradient(
                            colors: [NwAppColors.accent.opacity(0.45), NwAppColors.accent.opacity(0.05)],
                            startPoint: .top, endPoint: .bottom
                        ))
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("Balance", point.balance.doubleValue),
                            series: .value("series", "Scheduled")
                        )
                        .foregroundStyle(NwAppColors.accent)
                    }

                    if projection.hasVariableProjection {
                        let variableColor: Color = projection.dailyVariableNet.isNegative
                            ? NwAppColors.liability
                            : NwAppColors.positive
                        ForEach(projection.pointsWithVariable) { point in
                            LineMark(
                                x: .value("Date", point.date),
                                y: .value("Balance", point.balance.doubleValue),
                                series: .value("series", "With variable")
                            )
                            .foregroundStyle(variableColor)
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        }
                    }
                }
                .frame(height: 200)

                if projection.hasVariableProjection {
                    let variableColor: Color = projection.dailyVariableNet.isNegative
                        ? NwAppColors.liability
                        : NwAppColors.positive
                    let variableLabel = projection.dailyVariableNet.isNegative
                        ? "Incl. variable drain"
                        : "Incl. variable inflow"
                    HStack(spacing: NwSpacing.md) {
                        legendDot(color: NwAppColors.accent, dashed: false, label: "Scheduled only")
                        legendDot(color: variableColor, dashed: true, label: variableLabel)
                    }
                    .font(NwTypography.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func legendDot(color: Color, dashed: Bool, label: String) -> some View {
        HStack(spacing: NwSpacing.xs) {
            if dashed {
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { _ in
                        Capsule().fill(color).frame(width: 4, height: 2)
                    }
                }
            } else {
                Capsule().fill(color).frame(width: 14, height: 2)
            }
            Text(label)
        }
    }

    private func alertsCard(alerts: [CashPositionProjector.AlertPoint]) -> some View {
        NwCard(style: .primary) {
            VStack(alignment: .leading, spacing: NwSpacing.md) {
                Text("Heads-up")
                    .font(NwTypography.headline)
                let preview = Array(alerts.prefix(6))
                ForEach(preview) { alert in
                    HStack {
                        NwIcon.warning.image
                            .foregroundStyle(alert.kind == .overdraft ? NwAppColors.liability : NwAppColors.caution)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(alert.kind == .overdraft ? "Overdraft risk" : "Cash dip")
                                .font(NwTypography.body)
                            Text(DateDisplay.relativeDay(alert.date, relativeTo: .now))
                                .font(NwTypography.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        NwAmountText(alert.balance, variant: .body,
                                     color: alert.kind == .overdraft ? NwAppColors.liability : NwAppColors.caution)
                    }
                    if alert.id != preview.last?.id { Divider() }
                }
            }
        }
    }
}

/// Section accordion above the individual CCForecastCard rows. Owns its own
/// `expanded` state so toggling it doesn't ripple into ProjectionsView's body
/// and force a recompute of cash + per-card projections.
private struct CCForecastSection: View {
    let projections: [StatementProjection]
    @State private var expanded: Bool = false

    private var totalProjected: Money {
        Money(milliunits: projections.reduce(0) { $0 + $1.projectedStatementBalance.milliunits })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NwSpacing.md) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: NwSpacing.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Credit Card Forecast")
                            .font(NwTypography.titleSmall)
                            .foregroundStyle(NwAppColors.textPrimary)
                        Text("\(projections.count) card\(projections.count == 1 ? "" : "s") · projected statements")
                            .font(NwTypography.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    NwAmountText(totalProjected, variant: .body, color: NwAppColors.liability)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(projections) { ccProjection in
                    CCForecastCard(projection: ccProjection)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

private struct CCForecastCard: View {
    let projection: StatementProjection
    @State private var expanded: Bool = false

    private var hasProjectedCharges: Bool { !projection.projectedVariableCharges.isZero }

    var body: some View {
        NwCard(style: .primary) {
            VStack(alignment: .leading, spacing: NwSpacing.md) {
                header
                if expanded {
                    expandedDetail
                }
            }
        }
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
        } label: {
            HStack(spacing: NwSpacing.md) {
                NwIcon.creditCard.image.foregroundStyle(NwAppColors.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(projection.cardName)
                        .font(NwTypography.headline)
                        .foregroundStyle(NwAppColors.textPrimary)
                    Text("Closes \(DateDisplay.relativeDay(projection.nextCloseDate, relativeTo: projection.asOf))")
                        .font(NwTypography.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                NwAmountText(projection.projectedStatementBalance, variant: .body)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: NwSpacing.md) {
            VStack(alignment: .leading, spacing: NwSpacing.xs) {
                Text("Projected statement")
                    .font(NwTypography.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                NwAmountText(projection.projectedStatementBalance, variant: .large)
                if hasProjectedCharges {
                    Text("≈ \(CurrencyFormatter.compact(projection.dailyAverageCharge))/day average")
                        .font(NwTypography.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(spacing: NwSpacing.sm) {
                row(label: "Current owed",
                    value: projection.currentBalanceOwed,
                    color: NwAppColors.textPrimary)
                if !projection.scheduledChargesBeforeClose.isZero {
                    row(label: "Scheduled charges",
                        value: projection.scheduledChargesBeforeClose,
                        color: NwAppColors.liability)
                }
                if hasProjectedCharges {
                    row(label: "Projected variable charges",
                        value: projection.projectedVariableCharges,
                        color: NwAppColors.liability)
                }
                if !projection.scheduledPaymentsBeforeClose.isZero {
                    row(label: "Scheduled payments",
                        value: projection.scheduledPaymentsBeforeClose,
                        color: NwAppColors.positive)
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    @ViewBuilder
    private func row(label: String, value: Money, color: Color) -> some View {
        HStack {
            Text(label)
                .font(NwTypography.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Text(CurrencyFormatter.compact(value))
                .font(NwTypography.footnoteEm)
                .foregroundStyle(color)
        }
    }
}

/// Per-category spending breakdown over the user's lookback window.
/// All categories selected by default — tap to filter to a subset.
private struct CategorySpendingCard: View {
    @Environment(AppContainerController.self) private var container
    @Query(sort: \CachedCategory.groupName) private var categories: [CachedCategory]
    @Query(sort: \CachedAccount.name) private var accounts: [CachedAccount]
    @Query private var userSettings: [DurableUserSettings]

    /// Already-summarized history passed in from ProjectionsView. Avoids a
    /// duplicate @Query against CachedTransaction and skips a second pass of
    /// JSON sub-decode work per render.
    let history: [TransactionSummary]

    enum Mode: String, CaseIterable, Identifiable {
        case historical = "Historical"
        case projection = "Projection"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .historical
    @State private var windowDays: Int = 60
    /// nil = "all selected" pseudo-state (default). Empty set = none selected.
    @State private var selection: Set<String>? = nil
    @State private var showingFilterSheet = false
    @State private var transactionsRow: Row? = nil

    /// Window pill options.
    private static let pillOptions: [Int] = [30, 60, 90]

    init(history: [TransactionSummary]) {
        self.history = history
    }

    /// Used as the historical basis for projection mode.
    private var settingsLookbackDays: Int { userSettings.first?.spendingLookbackDays ?? 60 }

    /// User-facing rename for YNAB's hidden system group. "Internal Master
    /// Category" houses inflows like "Inflow: Ready to Assign"; calling it
    /// "Income" matches the user's mental model.
    private func displayGroupName(_ raw: String) -> String {
        raw == "Internal Master Category" ? "Income" : raw
    }

    /// Active accounts whose transactions we scan for the breakdown.
    private var activeSpendAccountIds: Set<String> {
        Set(accounts.filter { !$0.deleted && !$0.closed && $0.kind.isSpendAccount }.map { $0.id })
    }

    /// All spend-type accounts including closed ones — used to detect internal
    /// transfers. Transfers to a closed YNAB account are still internal money
    /// movement, not real spend.
    private var internalAccountIds: Set<String> {
        Set(accounts.filter { !$0.deleted && $0.kind.isSpendAccount }.map { $0.id })
    }

    typealias Row = CategorySpendingRow

    /// Aggregate the per-category totals once per body render. Hidden and
    /// deleted categories are skipped so this view stays consistent with the
    /// auto-excluded hidden categories in the cash projection.
    private func computeRows(lookbackDays: Int) -> [Row] {
        let now = Date.now
        let cal = Calendar(identifier: .gregorian)
        guard let windowStart = cal.date(byAdding: .day, value: -lookbackDays, to: cal.startOfDay(for: now)) else {
            return []
        }
        var nameById: [String: (name: String, group: String)] = [:]
        var userHiddenIds = Set<String>()  // fully excluded
        var internalIds = Set<String>()    // inflow-passthrough only
        for cat in categories where !cat.deleted && !cat.name.isEmpty {
            if cat.hidden {
                if cat.groupName == "Internal Master Category" {
                    internalIds.insert(cat.id)
                    nameById[cat.id] = (cat.name, displayGroupName(cat.groupName))
                } else {
                    userHiddenIds.insert(cat.id)
                }
                continue
            }
            nameById[cat.id] = (cat.name, displayGroupName(cat.groupName))
        }
        let activeIds = activeSpendAccountIds
        let allInternalIds = internalAccountIds
        // outflowSumMU > 0 = net spend in category. Negative = net refund/inflow.
        // outflowMU/inflowMU track gross sides so the UI can show "net of $X refunds".
        var totals: [String: (outflowSumMU: Int64, inflowSumMU: Int64, count: Int, name: String, group: String)] = [:]

        func contribute(amountMU: Int64, transferId: String?, categoryId: String?, categoryName: String?) {
            if amountMU == 0 { return }
            if let xfer = transferId, allInternalIds.contains(xfer) { return }
            if let cid = categoryId {
                // User-hidden categories (archived) — drop entirely.
                if userHiddenIds.contains(cid) { return }
                // Internal Master Category — keep inflows only, drop outflows.
                if internalIds.contains(cid), amountMU < 0 { return }
            }
            let cid = categoryId ?? "uncategorized"
            let descriptor = nameById[cid] ?? (name: categoryName ?? "Uncategorized", group: "Other")
            var entry = totals[cid] ?? (0, 0, 0, descriptor.name, descriptor.group)
            if amountMU < 0 {
                entry.outflowSumMU += -amountMU
            } else {
                entry.inflowSumMU += amountMU
            }
            entry.count += 1
            totals[cid] = entry
        }

        for txn in history {
            guard activeIds.contains(txn.accountId) else { continue }
            guard txn.date >= windowStart else { continue }
            if txn.isSplit {
                for sub in txn.subtransactions where !sub.deleted {
                    contribute(
                        amountMU: sub.amount.milliunits,
                        transferId: sub.transferAccountId,
                        categoryId: sub.categoryId,
                        categoryName: sub.categoryName
                    )
                }
            } else {
                contribute(
                    amountMU: txn.amount.milliunits,
                    transferId: txn.transferAccountId,
                    categoryId: txn.categoryId,
                    categoryName: txn.categoryName
                )
            }
        }
        return totals
            .map { (id, value) in
                let netMU = value.outflowSumMU - value.inflowSumMU
                return Row(
                    id: id,
                    name: value.name,
                    groupName: value.group,
                    total: Money(milliunits: netMU),
                    inflow: Money(milliunits: value.inflowSumMU),
                    txnCount: value.count
                )
            }
            // Drop rows that net to zero or pure inflows with no spend — they're
            // distracting in a "spending" view.
            .filter { $0.total.milliunits != 0 || $0.inflow.milliunits != 0 }
            .sorted { $0.total.milliunits > $1.total.milliunits }
    }

    private func scaledRows(basis: Int, target: Int, source: [Row]) -> [Row] {
        guard basis > 0 else { return source }
        let scale = Double(target) / Double(basis)
        return source.map { row in
            Row(
                id: row.id,
                name: row.name,
                groupName: row.groupName,
                total: Money(milliunits: Int64((Double(row.total.milliunits) * scale).rounded())),
                inflow: Money(milliunits: Int64((Double(row.inflow.milliunits) * scale).rounded())),
                txnCount: row.txnCount
            )
        }
    }

    /// Rows for the selected mode/window combination. Historical = actual
    /// activity over the pill window. Projection = activity over the user's
    /// Settings lookback, scaled to the pill's future window length.
    private var rows: [Row] {
        switch mode {
        case .historical:
            return computeRows(lookbackDays: windowDays)
        case .projection:
            let basis = max(7, settingsLookbackDays)
            let actuals = computeRows(lookbackDays: basis)
            return scaledRows(basis: basis, target: windowDays, source: actuals)
        }
    }

    private func grouped(_ rows: [Row]) -> [(group: String, items: [Row])] {
        Dictionary(grouping: rows, by: { $0.groupName })
            .map { (group: $0.key, items: $0.value.sorted { $0.total.milliunits > $1.total.milliunits }) }
            .sorted { lhs, rhs in
                let lhsTotal = lhs.items.reduce(0) { $0 + $1.total.milliunits }
                let rhsTotal = rhs.items.reduce(0) { $0 + $1.total.milliunits }
                return lhsTotal > rhsTotal
            }
    }

    var body: some View {
        let allRows = rows
        let selectedRows = selection.map { sel in allRows.filter { sel.contains($0.id) } } ?? allRows
        let selectionTotal = Money(milliunits: selectedRows.reduce(0) { $0 + $1.total.milliunits })
        return content(rows: allRows, selectedRows: selectedRows, selectionTotal: selectionTotal)
    }

    @ViewBuilder
    private func content(rows: [Row], selectedRows: [Row], selectionTotal: Money) -> some View {
        NwCard(style: .primary) {
            VStack(alignment: .leading, spacing: NwSpacing.md) {
                HStack {
                    Text(mode == .historical ? "Spending by Category" : "Projected Spend by Category")
                        .font(NwTypography.headline)
                    Spacer()
                    Text(mode == .historical
                         ? "Last \(windowDays) days"
                         : "Next \(windowDays) days")
                        .font(NwTypography.footnote)
                        .foregroundStyle(.secondary)
                }

                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)

                pillsRow

                if rows.isEmpty {
                    Text(mode == .historical
                         ? "No cash-account spending in this window."
                         : "Not enough history yet to project. Sync first.")
                        .font(NwTypography.callout)
                        .foregroundStyle(.secondary)
                } else {
                    filterButton(rows: rows, selectedRows: selectedRows, selectionTotal: selectionTotal)
                    let groups = grouped(selectedRows)
                    // Pinned section headers so the floating capsule sticks to
                    // the top of the page scroll as you read down the groups.
                    LazyVStack(spacing: NwSpacing.sm, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups, id: \.group) { group in
                            Section {
                                groupRowsCard(items: group.items)
                            } header: {
                                floatingGroupHeader(
                                    title: group.group,
                                    totalMU: group.items.reduce(0) { $0 + $1.total.milliunits }
                                )
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingFilterSheet) {
            CategoryFilterSheet(rows: rows, selection: $selection)
                .environment(container)
        }
        .sheet(item: $transactionsRow) { row in
            // Drill-down always uses the *historical* window — projections are
            // derived from the same activity, so showing the basis history is
            // the most useful context.
            CategoryTransactionsSheet(
                categoryId: row.id,
                categoryName: row.name,
                lookbackDays: mode == .historical ? windowDays : settingsLookbackDays
            )
            .environment(container)
        }
    }

    private var pillsRow: some View {
        HStack(spacing: NwSpacing.sm) {
            ForEach(Self.pillOptions, id: \.self) { option in
                let isOn = windowDays == option
                Button {
                    windowDays = option
                } label: {
                    Text("\(option)d")
                        .font(NwTypography.footnoteEm)
                        .padding(.vertical, NwSpacing.xs)
                        .padding(.horizontal, NwSpacing.md)
                        .background(isOn ? NwAppColors.primary : NwAppColors.cardSurfaceAlt)
                        .foregroundStyle(isOn ? NwAppColors.textOnPrimary : NwAppColors.textPrimary)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    /// Sticky section header (modeled on WorkoutApp's `LiftFloatingHeader`).
    /// Only the capsule itself is opaque — the spacers on either side are
    /// fully transparent so content scrolls underneath cleanly.
    @ViewBuilder
    private func floatingGroupHeader(title: String, totalMU: Int64) -> some View {
        let groupColor: Color = totalMU < 0 ? NwAppColors.positive : NwAppColors.liability
        HStack {
            Spacer().frame(maxWidth: .infinity)
            HStack(spacing: NwSpacing.sm) {
                Text(title.uppercased())
                    .font(NwTypography.headline)
                    .foregroundStyle(.white)
                Text("·")
                    .foregroundStyle(.white.opacity(0.7))
                Text(CurrencyFormatter.compact(Money(milliunits: abs(totalMU))))
                    .font(NwTypography.headline)
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, NwSpacing.lg)
            .padding(.vertical, NwSpacing.sm)
            .background(
                Capsule(style: .continuous)
                    .fill(groupColor)
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
            )
            .fixedSize()
            Spacer().frame(maxWidth: .infinity)
        }
        .padding(.vertical, NwSpacing.sm)
        .background(Color.clear)
    }

    @ViewBuilder
    private func groupRowsCard(items: [Row]) -> some View {
        VStack(spacing: 0) {
            ForEach(items) { row in
                Button {
                    transactionsRow = row
                } label: {
                    rowView(row)
                        .padding(.horizontal, NwSpacing.md)
                        .padding(.vertical, NwSpacing.sm)
                }
                .buttonStyle(.plain)
                if row.id != items.last?.id {
                    Divider().padding(.leading, NwSpacing.md)
                }
            }
        }
        .background(NwAppColors.cardSurfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: NwCornerRadius.md, style: .continuous))
    }

    private func rowView(_ row: Row) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(NwTypography.body)
                    .foregroundStyle(NwAppColors.textPrimary)
                if row.hasInflow {
                    Text("incl. \(CurrencyFormatter.compact(row.inflow)) inflow")
                        .font(NwTypography.caption)
                        .foregroundStyle(NwAppColors.positive)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                NwAmountText(
                    row.total.absolute,
                    variant: .body,
                    color: row.total.isNegative ? NwAppColors.positive : NwAppColors.liability
                )
                Text(mode == .historical ? "\(row.txnCount) txns" : "projected")
                    .font(NwTypography.caption)
                    .foregroundStyle(.secondary)
            }
            NwIcon.chevron.image.foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    private func filterButton(rows: [Row], selectedRows: [Row], selectionTotal: Money) -> some View {
        Button {
            showingFilterSheet = true
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selection == nil ? "All categories" : "\(selectedRows.count) of \(rows.count) selected")
                        .font(NwTypography.bodyEmphasis)
                        .foregroundStyle(NwAppColors.textPrimary)
                    Text("Tap to filter")
                        .font(NwTypography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                NwAmountText(selectionTotal, variant: .body, color: NwAppColors.liability)
                NwIcon.chevron.image.foregroundStyle(.secondary)
            }
            .padding(NwSpacing.md)
            .background(NwAppColors.cardSurfaceAlt)
            .clipShape(RoundedRectangle(cornerRadius: NwCornerRadius.md, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
