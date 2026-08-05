import SwiftUI
import SwiftData
import Charts
import UIKit
import NetworthCore

/// Spending History — the Spending tab (Phase 1 step 3).
///
/// Month navigation, the review card for posted transactions awaiting
/// approval, the selected month's total and per-group columns, and a
/// 24-month stacked column chart by category group. Only approved activity
/// counts; the current month is month-to-date, completed months are final.
struct SpendingHistoryView: View {
    @SwiftUI.Environment(AppContainerController.self) private var container

    @State private var model: SpendingHistoryModel?
    @State private var selectedMonth: Date?
    @State private var detailSelection: SpendingGroupDetailSelection?
    @State private var showingGroupedReview = false
    @State private var showingIndividualReview = false
    @State private var rebuildTask: Task<Void, Never>?

    private let calendar = Calendar.current

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NwSpacing.lg) {
                    if pendingReviewCount > 0 {
                        reviewCard
                    }
                    if let model {
                        monthHeader(model)
                        if let month = displayedMonth(model) {
                            monthTotalCard(month)
                            groupColumns(month)
                        }
                        historyChartCard(model)
                    } else {
                        NwLoadingState("Loading spending…")
                            .frame(maxWidth: .infinity, minHeight: 240)
                    }
                }
                .padding(.horizontal, NwSpacing.screenPadding)
                .padding(.vertical, NwSpacing.md)
            }
            .background(NwAppColors.background.ignoresSafeArea())
            .navigationTitle("Spending History")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await rebuild() }
        .onReceive(
            NotificationCenter.default
                .publisher(for: .networthModelContextSaved)
                .debounce(for: .seconds(0.6), scheduler: RunLoop.main)
        ) { _ in
            rebuildTask?.cancel()
            rebuildTask = Task { await rebuild() }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.significantTimeChangeNotification
            )
        ) { _ in
            // Month rollover while the tab stays mounted: refresh the
            // 24-month window so the new current month appears.
            rebuildTask?.cancel()
            rebuildTask = Task { await rebuild() }
        }
        .sheet(item: $detailSelection) { selection in
            SpendingGroupDetailSheet(selection: selection)
                .environment(container)
        }
        .sheet(isPresented: $showingGroupedReview) {
            GroupedHistoricalReviewSheet().environment(container)
        }
        .sheet(isPresented: $showingIndividualReview) {
            PlaidClassificationReviewSheet().environment(container)
        }
    }

    // MARK: - Review card

    private var pendingReviewCount: Int {
        container.plaidTransactionSyncCoordinator.pendingTransactionReviewCount
    }

    private var reviewCard: some View {
        NwCard(style: .primary) {
            VStack(alignment: .leading, spacing: NwSpacing.sm) {
                HStack {
                    NwIcon.warning.image
                        .foregroundStyle(NwAppColors.caution)
                    Text("\(pendingReviewCount) transactions to review")
                        .font(NwTypography.body.weight(.semibold))
                    Spacer()
                }
                Text("Approved transactions appear here and in projections.")
                    .font(NwTypography.footnote)
                    .foregroundStyle(.secondary)
                HStack(spacing: NwSpacing.md) {
                    Button("Review groups") { showingGroupedReview = true }
                        .buttonStyle(.borderedProminent)
                        .tint(NwAppColors.primary)
                    Button("One by one") { showingIndividualReview = true }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: - Month navigation

    private func displayedMonth(
        _ model: SpendingHistoryModel
    ) -> SpendingHistoryMonth? {
        guard let selectedMonth else { return model.months.last }
        return model.months.first { $0.month == selectedMonth }
            ?? model.months.last
    }

    private func monthHeader(_ model: SpendingHistoryModel) -> some View {
        let current = displayedMonth(model)
        let index = model.months.firstIndex { $0.month == current?.month }
        let canGoBack = (index ?? 0) > 0
        let canGoForward = index.map { $0 < model.months.count - 1 } ?? false
        return HStack {
            Button {
                if let index, canGoBack {
                    selectedMonth = model.months[index - 1].month
                }
            } label: {
                Image(systemName: "chevron.left.circle.fill")
                    .font(.title2)
                    .foregroundStyle(
                        canGoBack ? NwAppColors.primary : Color.secondary.opacity(0.4)
                    )
            }
            .disabled(!canGoBack)
            .accessibilityLabel("Previous month")

            Spacer()
            VStack(spacing: 2) {
                Text(
                    current?.month.formatted(
                        .dateTime.month(.wide).year()
                    ) ?? ""
                )
                .font(NwTypography.titleSmall)
                if isCurrentMonth(current?.month) {
                    Text("Month to date")
                        .font(NwTypography.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()

            Button {
                if let index, canGoForward {
                    selectedMonth = model.months[index + 1].month
                }
            } label: {
                Image(systemName: "chevron.right.circle.fill")
                    .font(.title2)
                    .foregroundStyle(
                        canGoForward ? NwAppColors.primary : Color.secondary.opacity(0.4)
                    )
            }
            .disabled(!canGoForward)
            .accessibilityLabel("Next month")
        }
    }

    private func isCurrentMonth(_ month: Date?) -> Bool {
        guard let month else { return false }
        return calendar.isDate(month, equalTo: .now, toGranularity: .month)
    }

    // MARK: - Selected month

    private func monthTotalCard(_ month: SpendingHistoryMonth) -> some View {
        NwCard(style: .primary) {
            VStack(alignment: .leading, spacing: NwSpacing.xs) {
                Text("Spent")
                    .font(NwTypography.caption)
                    .foregroundStyle(.secondary)
                NwAmountText(month.total, variant: .hero, showCents: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Vertical columns for the selected month's groups; tapping a column
    /// opens that month/group detail.
    private func groupColumns(_ month: SpendingHistoryMonth) -> some View {
        let maxSpent = max(month.groups.map(\.spentMilliunits).max() ?? 1, 1)
        return NwCard(style: .primary) {
            VStack(alignment: .leading, spacing: NwSpacing.sm) {
                if month.groups.isEmpty {
                    Text("No approved spending this month.")
                        .font(NwTypography.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .bottom, spacing: NwSpacing.md) {
                            ForEach(month.groups) { group in
                                groupColumn(
                                    group,
                                    month: month,
                                    maxSpent: maxSpent
                                )
                            }
                        }
                        .padding(.top, NwSpacing.xs)
                    }
                }
            }
        }
    }

    private func groupColumn(
        _ group: SpendingHistoryGroupTotal,
        month: SpendingHistoryMonth,
        maxSpent: Int64
    ) -> some View {
        let height = max(
            12,
            CGFloat(group.spentMilliunits) / CGFloat(maxSpent) * 120
        )
        return Button {
            detailSelection = SpendingGroupDetailSelection(
                month: month, group: group
            )
        } label: {
            VStack(spacing: NwSpacing.xs) {
                Text(CurrencyFormatter.currency(group.spent, showCents: false))
                    .font(NwTypography.caption)
                    .foregroundStyle(NwAppColors.textPrimary)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color(for: group.id))
                    .frame(width: 44, height: height)
                Text(group.name)
                    .font(NwTypography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 72)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 24-month chart

    private struct ChartDatum: Identifiable {
        let month: Date
        let seriesID: String
        let seriesName: String
        /// Explicit stack bounds: the chart renders exactly the cumulative
        /// order the tap resolution walks, with no framework stacking-order
        /// assumption.
        let startDollars: Double
        let endDollars: Double
        var id: String { "\(month.timeIntervalSince1970):\(seriesID)" }
    }

    /// Chart series for one month in fixed palette order (bottom-up), with
    /// every group beyond the fixed categorical order folded into "Other".
    /// Net-negative groups (refunds exceeding spending) are visible in the
    /// month's group columns but excluded from the stacked chart.
    private func chartSeries(
        for month: SpendingHistoryMonth,
        model: SpendingHistoryModel
    ) -> [ChartDatum] {
        var byID: [String: (name: String, milliunits: Int64)] = [:]
        for group in month.groups where group.spentMilliunits > 0 {
            let folded = model.paletteIndex(for: group.id) == nil
            let seriesID = folded
                ? SpendingHistoryBuilder.ungroupedIdentity
                : group.id
            let name = folded
                ? SpendingHistoryBuilder.ungroupedName
                : group.name
            var bucket = byID[seriesID] ?? (name, 0)
            bucket.milliunits += group.spentMilliunits
            byID[seriesID] = bucket
        }
        let ordered = byID
            .map { (id: $0.key, name: $0.value.name, milliunits: $0.value.milliunits) }
            .sorted {
                seriesOrder($0.id, model: model)
                    < seriesOrder($1.id, model: model)
            }
        var cumulative = 0.0
        return ordered.map { series in
            let start = cumulative
            cumulative += Double(series.milliunits) / 1000
            return ChartDatum(
                month: month.month,
                seriesID: series.id,
                seriesName: series.name,
                startDollars: start,
                endDollars: cumulative
            )
        }
    }

    private func seriesOrder(
        _ seriesID: String, model: SpendingHistoryModel
    ) -> Int {
        model.paletteIndex(for: seriesID)
            ?? NwAppColors.chartCategorical.count
    }

    private func color(for groupID: String) -> Color {
        guard let index = model?.paletteIndex(for: groupID) else {
            return NwAppColors.chartOther
        }
        return NwAppColors.chartCategorical[index]
    }

    private func historyChartCard(_ model: SpendingHistoryModel) -> some View {
        let data = model.months.flatMap { chartSeries(for: $0, model: model) }
        let seriesIDs = orderedSeriesIDs(in: data, model: model)
        let names = seriesIDs.compactMap { id in
            data.first { $0.seriesID == id }?.seriesName
        }
        let colors = seriesIDs.map { color(for: $0) }
        return NwCard(style: .primary) {
            VStack(alignment: .leading, spacing: NwSpacing.sm) {
                Text("Last 24 Months")
                    .font(NwTypography.caption)
                    .foregroundStyle(.secondary)
                Chart(data) { datum in
                    BarMark(
                        x: .value("Month", datum.month, unit: .month),
                        yStart: .value("Spent", datum.startDollars),
                        yEnd: .value("Spent", datum.endDollars)
                    )
                    .foregroundStyle(by: .value("Group", datum.seriesName))
                    .cornerRadius(2)
                }
                .chartForegroundStyleScale(domain: names, range: colors)
                .chartLegend(position: .bottom, spacing: NwSpacing.sm)
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(NwAppColors.strokeSubtle)
                        AxisValueLabel {
                            if let dollars = value.as(Double.self) {
                                Text(
                                    CurrencyFormatter.compact(
                                        Money(milliunits: Int64(dollars * 1000))
                                    )
                                )
                                .font(NwTypography.caption)
                            }
                        }
                    }
                }
                .frame(height: 220)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture { location in
                                handleChartTap(
                                    at: location,
                                    proxy: proxy,
                                    geo: geo,
                                    model: model
                                )
                            }
                    }
                }
            }
        }
    }

    private func orderedSeriesIDs(
        in data: [ChartDatum], model: SpendingHistoryModel
    ) -> [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for datum in data where !seen.contains(datum.seriesID) {
            seen.insert(datum.seriesID)
            ids.append(datum.seriesID)
        }
        return ids.sorted {
            seriesOrder($0, model: model) < seriesOrder($1, model: model)
        }
    }

    /// Resolves a tap to the month column and the stacked group segment at
    /// that height, then opens the month/group detail.
    private func handleChartTap(
        at location: CGPoint,
        proxy: ChartProxy,
        geo: GeometryProxy,
        model: SpendingHistoryModel
    ) {
        guard let plotFrame = proxy.plotFrame else { return }
        let origin = geo[plotFrame].origin
        let position = CGPoint(
            x: location.x - origin.x, y: location.y - origin.y
        )
        guard let tappedDate: Date = proxy.value(atX: position.x),
              let tappedDollars: Double = proxy.value(atY: position.y),
              let monthStart = calendar.dateInterval(
                of: .month, for: tappedDate
              )?.start,
              let month = model.months.first(where: {
                  $0.month == monthStart
              }) else {
            return
        }
        selectedMonth = month.month
        // Walk the same explicit stack bounds the chart rendered.
        for datum in chartSeries(for: month, model: model)
        where tappedDollars <= datum.endDollars {
            openDetail(for: datum.seriesID, in: month, model: model)
            return
        }
    }

    private func openDetail(
        for seriesID: String,
        in month: SpendingHistoryMonth,
        model: SpendingHistoryModel
    ) {
        if seriesID == SpendingHistoryBuilder.ungroupedIdentity {
            // Merge exactly what the chart's "Other" segment shows: folded
            // groups with positive spend. Net-negative folded groups stay
            // visible in the month's group columns instead.
            let folded = month.groups.filter {
                model.paletteIndex(for: $0.id) == nil
                    && $0.spentMilliunits > 0
            }
            guard !folded.isEmpty else { return }
            let merged = SpendingHistoryGroupTotal(
                id: SpendingHistoryBuilder.ungroupedIdentity,
                name: SpendingHistoryBuilder.ungroupedName,
                spentMilliunits: folded.reduce(0) { $0 + $1.spentMilliunits },
                categories: folded.flatMap(\.categories).sorted {
                    $0.spentMilliunits > $1.spentMilliunits
                }
            )
            detailSelection = SpendingGroupDetailSelection(
                month: month, group: merged
            )
        } else if let group = month.groups.first(where: {
            $0.id == seriesID
        }) {
            detailSelection = SpendingGroupDetailSelection(
                month: month, group: group
            )
        }
    }

    // MARK: - Build

    private func rebuild() async {
        // Detached so the full-table fetch and aggregation never run on the
        // UI executor.
        let modelContainer = container.modelContainer
        let built = await Task.detached(priority: .userInitiated) {
            () -> SpendingHistoryModel? in
            let actor = SpendingHistoryBuildActor(
                modelContainer: modelContainer
            )
            return try? await actor.build(now: .now)
        }.value
        guard let built, !Task.isCancelled else { return }
        model = built
        if let selectedMonth,
           !built.months.contains(where: { $0.month == selectedMonth }) {
            self.selectedMonth = nil
        }
    }
}

// MARK: - Model

struct SpendingHistoryModel: Sendable {
    let months: [SpendingHistoryMonth]
    /// groupIdentity -> fixed palette slot (by group display order). Only
    /// the first `NwAppColors.chartCategorical.count` spending groups get a
    /// hue; the rest fold into "Other".
    let paletteIndexByGroupID: [String: Int]

    func paletteIndex(for groupID: String) -> Int? {
        paletteIndexByGroupID[groupID]
    }
}

struct SpendingGroupDetailSelection: Identifiable {
    let month: SpendingHistoryMonth
    let group: SpendingHistoryGroupTotal
    var id: String { "\(month.month.timeIntervalSince1970):\(group.id)" }
}

/// Off-main aggregation: maps approved cached transactions plus the
/// Networth-owned category directory into SpendingHistoryBuilder input.
@ModelActor
actor SpendingHistoryBuildActor {
    func build(now: Date, monthsBack: Int = 24) throws -> SpendingHistoryModel {
        let calendar = Calendar.current
        let rows = try modelContext.fetch(
            FetchDescriptor<CachedFinancialTransaction>(
                predicate: #Predicate {
                    !$0.deleted && !$0.pending && !$0.requiresReview
                }
            )
        )
        let categories = try modelContext.fetch(
            FetchDescriptor<DurableCanonicalCategory>()
        )
        let groups = try modelContext.fetch(
            FetchDescriptor<DurableCategoryGroup>()
        )
        let groupByIdentity = Dictionary(
            groups.map { ($0.groupIdentity, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let categoryByCanonicalID = Dictionary(
            categories.map { ($0.canonicalId, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        func resolvedGroup(
            categoryCanonicalId: String?
        ) -> (identity: String, name: String)? {
            guard let categoryCanonicalId,
                  let category = categoryByCanonicalID[categoryCanonicalId],
                  let identity = category.categoryGroupIdentity,
                  let group = groupByIdentity[identity],
                  group.reportingRole == .spending else {
                return nil
            }
            return (identity, group.name)
        }

        var entries: [SpendingHistoryEntry] = []
        for row in rows {
            let legs = row.subtransactions
            if legs.isEmpty {
                let group = resolvedGroup(
                    categoryCanonicalId: row.categoryCanonicalId
                )
                entries.append(SpendingHistoryEntry(
                    transactionId: row.id,
                    date: row.postedDate,
                    amountMilliunits: row.amountMilliunits,
                    treatment: row.forecastTreatment,
                    groupIdentity: group?.identity,
                    groupName: group?.name,
                    categoryKey: row.categoryCanonicalId
                        ?? "name:\(row.categoryName ?? "Uncategorized")",
                    categoryName: row.categoryName ?? "Uncategorized"
                ))
            } else {
                for leg in legs where !leg.deleted {
                    // Confirmed splits persist the canonical identity in
                    // `categoryId`; reference-suggested splits use
                    // `categoryCanonicalId`. Accept either.
                    let legCanonicalId = leg.categoryCanonicalId
                        ?? leg.categoryId
                    let group = resolvedGroup(
                        categoryCanonicalId: legCanonicalId
                    )
                    entries.append(SpendingHistoryEntry(
                        transactionId: row.id,
                        date: row.postedDate,
                        amountMilliunits: leg.amount.milliunits,
                        treatment: leg.forecastTreatment
                            ?? row.forecastTreatment,
                        groupIdentity: group?.identity,
                        groupName: group?.name,
                        categoryKey: legCanonicalId
                            ?? "name:\(leg.categoryName ?? "Uncategorized")",
                        categoryName: leg.categoryName ?? "Uncategorized"
                    ))
                }
            }
        }

        let months = SpendingHistoryBuilder.build(
            entries: entries,
            monthsBack: monthsBack,
            now: now,
            calendar: calendar
        )

        // Fixed hue order follows the entity: spending groups sorted by
        // display order (then name) claim palette slots permanently.
        let spendingGroups = groups
            .filter { $0.reportingRole == .spending && !$0.hidden }
            .sorted {
                if $0.displayOrder != $1.displayOrder {
                    return $0.displayOrder < $1.displayOrder
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name)
                    == .orderedAscending
            }
        var paletteIndex: [String: Int] = [:]
        for (index, group) in spendingGroups.enumerated()
        where index < NwAppColors.chartCategorical.count {
            paletteIndex[group.groupIdentity] = index
        }
        return SpendingHistoryModel(
            months: months,
            paletteIndexByGroupID: paletteIndex
        )
    }
}

// MARK: - Group detail

/// Month/group drill-down: categories with totals; each category expands to
/// its approved transactions.
struct SpendingGroupDetailSheet: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(AppContainerController.self) private var container
    let selection: SpendingGroupDetailSelection

    @State private var rowsByID: [String: CachedFinancialTransaction] = [:]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Spent") {
                        Text(CurrencyFormatter.currency(selection.group.spent))
                    }
                }
                ForEach(selection.group.categories) { category in
                    Section(category.name) {
                        LabeledContent("Total") {
                            Text(CurrencyFormatter.currency(category.spent))
                        }
                        DisclosureGroup("\(category.transactionIds.count) transactions") {
                            ForEach(
                                transactions(for: category), id: \.id
                            ) { row in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(row.displayName)
                                        Text(row.postedDate.formatted(
                                            date: .abbreviated, time: .omitted
                                        ))
                                        .font(NwTypography.footnote)
                                        .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(CurrencyFormatter.currency(
                                        displayAmount(
                                            for: row, category: category
                                        )
                                    ))
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(
                "\(selection.group.name) · \(selection.month.month.formatted(.dateTime.month(.abbreviated).year()))"
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(NwAppColors.liability)
                    }
                    .accessibilityLabel("Close")
                }
            }
            .onAppear(perform: loadRows)
        }
    }

    private func transactions(
        for category: SpendingHistoryCategoryTotal
    ) -> [CachedFinancialTransaction] {
        category.transactionIds
            .compactMap { rowsByID[$0] }
            .sorted { $0.postedDate > $1.postedDate }
    }

    /// For a split, only the legs belonging to this category count — never
    /// the parent total.
    private func displayAmount(
        for row: CachedFinancialTransaction,
        category: SpendingHistoryCategoryTotal
    ) -> Money {
        let legs = row.subtransactions.filter { !$0.deleted }
        guard !legs.isEmpty else {
            return Money(milliunits: row.amountMilliunits)
        }
        let matching = legs.filter { leg in
            let canonicalId = leg.categoryCanonicalId ?? leg.categoryId
            if let canonicalId { return canonicalId == category.id }
            return "name:\(leg.categoryName ?? "Uncategorized")"
                == category.id
        }
        return Money(
            milliunits: matching.reduce(0) { $0 + $1.amount.milliunits }
        )
    }

    private func loadRows() {
        let ids = Set(selection.group.categories.flatMap(\.transactionIds))
        guard !ids.isEmpty else { return }
        let idList = Array(ids)
        let descriptor = FetchDescriptor<CachedFinancialTransaction>(
            predicate: #Predicate { idList.contains($0.id) }
        )
        let rows = (try? container.modelContainer.mainContext.fetch(
            descriptor
        )) ?? []
        rowsByID = Dictionary(
            uniqueKeysWithValues: rows.map { ($0.id, $0) }
        )
    }
}
