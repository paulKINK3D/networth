import SwiftUI
import SwiftData
import Charts
import UIKit
import NetworthCore

/// Spending History — the Spending tab (Phase 1 step 3).
///
/// Month navigation, the review card for posted transactions awaiting
/// approval, the selected month's total and per-group columns, and a
/// 24-month selectable spending trend. Only approved activity counts; the
/// current month is month-to-date, completed months are final.
struct SpendingHistoryView: View {
    @SwiftUI.Environment(AppContainerController.self) private var container

    @State private var model: SpendingHistoryModel?
    @State private var selectedMonth: Date?
    @State private var selectedChartSeriesID = "networth:spending:all"
    @State private var historyChartScrollPosition = Date.now
    @State private var detailSelection: SpendingGroupDetailSelection?
    @State private var showingGroupedReview = false
    @State private var showingIndividualReview = false
    @State private var showingGroupManager = false
    @State private var rebuildTask: Task<Void, Never>?

    private let calendar = Calendar.current
    private let historyVisibleDuration: TimeInterval = 60 * 60 * 24 * 30.5 * 8

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
                            monthTotalCard(month, model: model)
                            spendingBreakdown(month, model: model)
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NwTopLevelMenu(
                        canRefresh: container.hasPlaidBackendToken,
                        contextualActions: [
                            NwTopLevelMenuAction(
                                title: "Manage Spending Groups",
                                systemImage: "slider.horizontal.3",
                                action: { showingGroupManager = true }
                            )
                        ],
                        onRefresh: {
                            Task { await container.syncNow() }
                        },
                        onSettings: { SettingsRouter.open() }
                    )
                }
            }
        }
        .task {
            await rebuild()
        }
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
        .sheet(isPresented: $showingGroupManager) {
            SpendingGroupManagementSheet().environment(container)
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
        return VStack(spacing: 2) {
            Text(
                current?.month.formatted(
                    .dateTime.month(.wide).year()
                ) ?? ""
            )
            .font(NwTypography.titleSmall)
        }
        .frame(maxWidth: .infinity)
    }

    private func isCurrentMonth(_ month: Date?) -> Bool {
        guard let month else { return false }
        return calendar.isDate(month, equalTo: .now, toGranularity: .month)
    }

    // MARK: - Selected month

    private func monthTotalCard(
        _ month: SpendingHistoryMonth,
        model: SpendingHistoryModel
    ) -> some View {
        NwCard(style: .primary) {
            VStack(alignment: .leading, spacing: NwSpacing.xs) {
                Text("Spent")
                    .font(NwTypography.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: NwSpacing.sm) {
                    NwAmountText(
                        month.wholeDollarDisplay.ordinaryHeadline,
                        variant: .hero,
                        showCents: false
                    )
                    if let typical = typicalMonthlySpend(model) {
                        Text("/ \(CurrencyFormatter.currency(typical, showCents: false))")
                            .font(NwTypography.title)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedChartSeriesID = Self.allSpendingSeriesID
        }
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    guard abs(value.translation.width)
                            > abs(value.translation.height),
                          abs(value.translation.width) >= 50 else { return }
                    moveDisplayedMonth(
                        in: model,
                        by: value.translation.width > 0 ? -1 : 1
                    )
                }
        )
        .accessibilityAction(named: "Previous Month") {
            moveDisplayedMonth(in: model, by: -1)
        }
        .accessibilityAction(named: "Next Month") {
            moveDisplayedMonth(in: model, by: 1)
        }
        .accessibilityHint("Double-tap to show all spending history")
    }

    /// A quiet reference point for the "Spent" headline: the median out-of-
    /// pocket monthly total across complete (non-current) months, on the same
    /// basis as the headline so the "$spent / $typical" pair is apples-to-
    /// apples. Same helper Goals uses for its emergency median. Nil until there
    /// are at least two complete months; the in-progress month is excluded so
    /// it can't skew the anchor.
    private func typicalMonthlySpend(_ model: SpendingHistoryModel) -> Money? {
        let completeMonths = model.months
            .filter { !isCurrentMonth($0.month) }
            .sorted { $0.month < $1.month }
            .suffix(12)
            .map(\.ordinaryTotal)
        return EmergencyFundMath.medianOfCompleteMonths(Array(completeMonths))
    }

    private func moveDisplayedMonth(
        in model: SpendingHistoryModel,
        by offset: Int
    ) {
        guard let current = displayedMonth(model),
              let index = model.months.firstIndex(where: {
                  $0.month == current.month
              }) else { return }
        let destination = index + offset
        guard model.months.indices.contains(destination) else { return }
        selectedMonth = model.months[destination].month
    }

    /// The month's out-of-pocket spending as a pie, sized against a normal
    /// month. The gray disc is the typical monthly spend (the same "/typical"
    /// figure shown beside the headline); the colored pie is this month, scaled
    /// by *area* so a below-normal month nests visibly inside the gray and a
    /// dashed ring always marks the typical level. The colored slices are the
    /// ordinary spending groups, which together sum to the "Spent" headline —
    /// there is no per-group budget, so the only reference is your own history.
    /// The legend below carries selection and reorder, and marks
    /// non-spending groups (transfers, savings, investing, unassigned) with a
    /// hollow swatch since they sit outside the pie.
    private func spendingBreakdown(
        _ month: SpendingHistoryMonth,
        model: SpendingHistoryModel
    ) -> some View {
        let groups = orderedGroups(in: month)
        let displayAmounts = month.wholeDollarDisplay.groupAmountsByID
        let currentTotal = Double(max(0, month.ordinaryTotalMilliunits))
        let typical = typicalMonthlySpend(model)
            .map { Double($0.milliunits) } ?? currentTotal
        let slices: [SpendingSlice] = groups
            .filter { $0.isOrdinarySpending && $0.spentMilliunits > 0 }
            .map {
                SpendingSlice(
                    id: $0.id,
                    value: Double($0.spentMilliunits),
                    color: color(for: $0.id)
                )
            }
        return NwCard(style: .primary, padding: 0) {
            VStack(spacing: 0) {
                if groups.isEmpty {
                    Text("No approved spending this month.")
                        .font(NwTypography.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(NwSpacing.md)
                } else {
                    NestedSpendingPie(
                        slices: slices,
                        currentTotal: currentTotal,
                        typicalTotal: max(0, typical)
                    )
                    .frame(height: 200)
                    .frame(maxWidth: .infinity)
                    .padding(.top, NwSpacing.lg)
                    .padding(.bottom, NwSpacing.md)
                    .accessibilityLabel("Spending versus a typical month")
                    Divider().padding(.leading, NwSpacing.md)
                    ForEach(Array(groups.enumerated()), id: \.element.id) {
                        index, group in
                        legendRow(
                            group,
                            month: month,
                            displayAmount: displayAmounts[group.id]
                                ?? group.spent
                        )
                        if index < groups.count - 1 {
                            Divider().padding(.leading, NwSpacing.md)
                        }
                    }
                }
            }
        }
    }

    private func orderedGroups(
        in month: SpendingHistoryMonth
    ) -> [SpendingHistoryGroupTotal] {
        guard let model else { return month.groups }
        return month.groups.sorted {
            let lhs = model.orderIndex(for: $0.id)
            let rhs = model.orderIndex(for: $1.id)
            if lhs != rhs { return lhs < rhs }
            return $0.name.localizedCaseInsensitiveCompare($1.name)
                == .orderedAscending
        }
    }

    /// A legend row beneath the pie: color key, group name, and amount. A
    /// filled swatch matches a pie slice; a hollow swatch marks a group that
    /// sits outside the spending pie (transfers, savings, investing,
    /// unassigned). The name selects the group's 24-month history; the amount
    /// opens the selected month's category and transaction detail. The context
    /// menu keeps the quick reorder action available.
    private func legendRow(
        _ group: SpendingHistoryGroupTotal,
        month: SpendingHistoryMonth,
        displayAmount: Money
    ) -> some View {
        let isSelected = selectedChartSeriesID == group.id
        let isSpending = group.isOrdinarySpending
        return HStack(spacing: NwSpacing.sm) {
            Button {
                selectedChartSeriesID = group.id
            } label: {
                HStack(spacing: NwSpacing.sm) {
                    swatch(for: group, isSpending: isSpending)
                    Text(group.name)
                        .font(
                            isSelected
                                ? NwTypography.bodyEmphasis
                                : NwTypography.body
                        )
                        .foregroundStyle(
                            isSelected
                                ? NwAppColors.primary
                                : NwAppColors.textPrimary
                        )
                        .lineLimit(1)
                    Spacer(minLength: NwSpacing.sm)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(group.name)
            .accessibilityValue(isSelected ? "Selected" : "")
            .accessibilityHint("Shows this group's spending history")

            if group.categories.isEmpty {
                legendAmount(group, amount: displayAmount)
            } else {
                Button {
                    detailSelection = SpendingGroupDetailSelection(
                        month: month,
                        group: group
                    )
                } label: {
                    legendAmount(group, amount: displayAmount)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "Open \(group.name) details, \(CurrencyFormatter.currency(displayAmount))"
                )
            }
        }
        .padding(.horizontal, NwSpacing.md)
        .padding(.vertical, NwSpacing.rowVertical)
        .contextMenu {
            if group.id != SpendingHistoryBuilder.ungroupedIdentity
                && group.id != SpendingGroupSetup.unassignedIdentity {
                Button {
                    moveGroupEarlier(group.id)
                } label: {
                    Label("Move Up", systemImage: "arrow.up")
                }
            }
        }
    }

    private func legendAmount(
        _ group: SpendingHistoryGroupTotal,
        amount: Money
    ) -> some View {
        NwAmountText(
            amount,
            variant: .body,
            showCents: false,
            color: group.spentMilliunits < 0
                ? NwAppColors.liability
                : NwAppColors.textPrimary
        )
    }

    @ViewBuilder
    private func swatch(
        for group: SpendingHistoryGroupTotal,
        isSpending: Bool
    ) -> some View {
        if isSpending {
            Circle()
                .fill(color(for: group.id))
                .frame(width: 11, height: 11)
        } else {
            Circle()
                .strokeBorder(NwAppColors.chartOther, lineWidth: 1.5)
                .frame(width: 11, height: 11)
        }
    }

    /// Column order is user-owned: swap the group one position earlier
    /// after normalizing display orders to a clean sequence.
    private func moveGroupEarlier(_ identity: String) {
        let ctx = container.modelContainer.mainContext
        let groups = ((try? ctx.fetch(
            FetchDescriptor<DurableCategoryGroup>()
        )) ?? [])
            .filter { SpendingGroupSetup.isUserGroup($0) }
            .sorted {
                if $0.displayOrder != $1.displayOrder {
                    return $0.displayOrder < $1.displayOrder
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name)
                    == .orderedAscending
            }
        guard let index = groups.firstIndex(where: {
            $0.groupIdentity == identity
        }), index > 0 else { return }
        for (position, group) in groups.enumerated() {
            group.displayOrder = position
        }
        groups[index].displayOrder = index - 1
        groups[index - 1].displayOrder = index
        groups[index].updatedAt = .now
        groups[index - 1].updatedAt = .now
        ctx.safeSave(source: "spending.groupReorder")
    }

    // MARK: - 24-month chart

    private static let allSpendingSeriesID = "networth:spending:all"

    private struct ChartDatum: Identifiable {
        let month: Date
        let dollars: Double
        let isPartial: Bool
        var id: Date { month }
    }

    private func chartData(
        _ model: SpendingHistoryModel
    ) -> [ChartDatum] {
        model.months.map { month in
            let milliunits: Int64
            if selectedChartSeriesID == Self.allSpendingSeriesID {
                // Out-of-pocket basis: matches the "Spent" headline, so
                // investing and savings transfers don't inflate the series.
                milliunits = month.ordinaryTotalMilliunits
            } else {
                milliunits = max(
                    0,
                    month.groups.first {
                        $0.id == selectedChartSeriesID
                    }?.spentMilliunits ?? 0
                )
            }
            return ChartDatum(
                month: month.month,
                dollars: Double(milliunits) / 1000,
                isPartial: isCurrentMonth(month.month)
            )
        }
    }

    private func selectedChartSeriesName(
        in model: SpendingHistoryModel
    ) -> String {
        guard selectedChartSeriesID != Self.allSpendingSeriesID else {
            return "All Spending"
        }
        return model.months.lazy
            .flatMap(\.groups)
            .first { $0.id == selectedChartSeriesID }?.name ?? "All Spending"
    }

    private func color(for groupID: String) -> Color {
        guard let index = model?.paletteIndex(for: groupID) else {
            return NwAppColors.chartOther
        }
        return NwAppColors.chartCategorical[index]
    }

    private func historyChartCard(_ model: SpendingHistoryModel) -> some View {
        let data = chartData(model)
        let seriesName = selectedChartSeriesName(in: model)
        let chartColor = selectedChartSeriesID == Self.allSpendingSeriesID
            ? NwAppColors.primary
            : color(for: selectedChartSeriesID)
        return NwCard(style: .primary) {
            VStack(alignment: .leading, spacing: NwSpacing.sm) {
                Text(seriesName)
                    .font(NwTypography.body.weight(.semibold))
                    .foregroundStyle(NwAppColors.textPrimary)

                Chart(data) { datum in
                    BarMark(
                        x: .value("Month", datum.month, unit: .month),
                        y: .value("Monthly spending", datum.dollars),
                        width: .ratio(0.68)
                    )
                    .foregroundStyle(
                        chartColor.opacity(datum.isPartial ? 0.45 : 0.9)
                    )
                    .cornerRadius(3)
                }
                .chartLegend(.hidden)
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
                .chartYScale(domain: .automatic(includesZero: true))
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: historyVisibleDuration)
                .chartScrollPosition(x: $historyChartScrollPosition)
                .frame(height: 220)
                .accessibilityLabel(
                    "Monthly \(seriesName)"
                )
                .chartGesture { proxy in
                    SpatialTapGesture()
                        .onEnded { value in
                            handleChartTap(
                                atX: value.location.x,
                                proxy: proxy,
                                model: model,
                                seriesID: selectedChartSeriesID
                            )
                    }
                }
            }
        }
    }

    /// A tap selects the underlying month. For a selected group, it also opens
    /// that month's unsmoothed category detail.
    private func handleChartTap(
        atX xPosition: CGFloat,
        proxy: ChartProxy,
        model: SpendingHistoryModel,
        seriesID: String
    ) {
        guard let tappedDate: Date = proxy.value(atX: xPosition),
              let monthStart = calendar.dateInterval(
                of: .month, for: tappedDate
              )?.start,
              let month = model.months.first(where: {
                  $0.month == monthStart
              }) else {
            return
        }
        selectedMonth = month.month
        guard seriesID != Self.allSpendingSeriesID,
              let group = month.groups.first(where: { $0.id == seriesID }),
              !group.categories.isEmpty else { return }
        detailSelection = SpendingGroupDetailSelection(
            month: month, group: group
        )
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
        if selectedChartSeriesID != Self.allSpendingSeriesID,
           !built.months.contains(where: { month in
               month.groups.contains { $0.id == selectedChartSeriesID }
           }) {
            selectedChartSeriesID = Self.allSpendingSeriesID
        }
        if let selectedMonth,
           !built.months.contains(where: { $0.month == selectedMonth }) {
            self.selectedMonth = nil
        }
    }
}

// MARK: - Group management

private struct ManagedSpendingGroup: Identifiable, Hashable {
    let identity: String
    let name: String
    let displayOrder: Int

    var id: String { identity }

    var subtitle: String {
        "Categories"
    }
}

private struct SpendingGroupEditorTarget: Identifiable {
    let identity: String?
    let initialName: String
    var id: String { identity ?? "new" }
}

private enum SpendingGroupManagementAlert: Identifiable {
    case deletion(ManagedSpendingGroup, CanonicalGroupDeletionImpact)
    case error(String)

    var id: String {
        switch self {
        case .deletion: "deletion"
        case .error: "error"
        }
    }
}

struct SpendingGroupManagementSheet: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(AppContainerController.self) private var container
    @Query private var groupRows: [DurableCategoryGroup]
    @Query private var categoryRows: [DurableCanonicalCategory]

    @State private var editorTarget: SpendingGroupEditorTarget?
    @State private var activeAlert: SpendingGroupManagementAlert?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        editorTarget = SpendingGroupEditorTarget(
                            identity: nil,
                            initialName: ""
                        )
                    } label: {
                        Label("Create Group", systemImage: "plus.circle.fill")
                    }
                } footer: {
                    Text("Create your groups, then assign categories to them.")
                }

                Section {
                    if groups.isEmpty {
                        Text("No groups yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(groups) { group in
                            managedGroupRow(group)
                        }
                        .onMove(perform: moveGroups)
                    }
                } header: {
                    Text("Your Groups")
                }

                Section {
                    NavigationLink {
                        SpendingGroupCategoryList(group: unassignedGroup)
                            .environment(container)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Unassigned Categories")
                                    .foregroundStyle(NwAppColors.textPrimary)
                                Text("Tap to place categories into your groups")
                                    .font(NwTypography.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(unassignedCategoryCount)")
                                .font(NwTypography.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Spending Groups")
            .navigationBarTitleDisplayMode(.inline)
            .alert(item: $activeAlert) { alert in
                switch alert {
                case .deletion(let group, let impact):
                    Alert(
                        title: Text("Delete \(group.name)?"),
                        message: Text(deleteConfirmationMessage(impact)),
                        primaryButton: .destructive(Text("Delete")) {
                            delete(group)
                        },
                        secondaryButton: .cancel()
                    )
                case .error(let message):
                    Alert(
                        title: Text("Couldn’t Delete Group"),
                        message: Text(message),
                        dismissButton: .cancel(Text("OK"))
                    )
                }
            }
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
                ToolbarItem(placement: .primaryAction) {
                    EditButton()
                }
            }
        }
        .sheet(item: $editorTarget) { target in
            SpendingGroupEditorSheet(target: target) {
                editorTarget = nil
            }
            .environment(container)
        }
    }

    private var groups: [ManagedSpendingGroup] {
        let rowsByIdentity = Dictionary(grouping: groupRows) {
            $0.groupIdentity
        }
        return rowsByIdentity.compactMap { identity, rows in
            guard let latest = rows.max(by: { $0.updatedAt < $1.updatedAt }),
                  SpendingGroupSetup.isUserGroup(latest) else {
                return nil
            }
            return ManagedSpendingGroup(
                identity: identity,
                name: latest.name,
                displayOrder: latest.displayOrder
            )
        }
        .sorted(by: groupSort)
    }

    private var unassignedGroup: ManagedSpendingGroup {
        ManagedSpendingGroup(
            identity: SpendingGroupSetup.unassignedIdentity,
            name: SpendingGroupSetup.unassignedName,
            displayOrder: Int.max
        )
    }

    private var unassignedCategoryCount: Int {
        assignableCategories.filter(isUnassigned).count
    }

    private var assignableCategories: [DurableCanonicalCategory] {
        let latestGroupByIdentity = Dictionary(
            grouping: groupRows,
            by: \.groupIdentity
        ).compactMapValues { rows in
            rows.max(by: { $0.updatedAt < $1.updatedAt })
        }
        return SpendingGroupSetup.latestCategories(categoryRows).filter {
            SpendingGroupSetup.isAssignableCategory(
                $0,
                groupByIdentity: latestGroupByIdentity
            )
        }
    }

    private func isUnassigned(_ category: DurableCanonicalCategory) -> Bool {
        SpendingGroupSetup.isUnassignedCategory(
            category,
            userGroupIdentities: Set(groups.map(\.identity))
        )
    }

    private func groupSort(
        _ lhs: ManagedSpendingGroup,
        _ rhs: ManagedSpendingGroup
    ) -> Bool {
        if lhs.displayOrder != rhs.displayOrder {
            return lhs.displayOrder < rhs.displayOrder
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            == .orderedAscending
    }

    private func groupLabel(_ group: ManagedSpendingGroup) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(group.name)
                .foregroundStyle(NwAppColors.textPrimary)
            Text(group.subtitle)
                .font(NwTypography.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func managedGroupRow(_ group: ManagedSpendingGroup) -> some View {
        NavigationLink {
            SpendingGroupCategoryList(group: group)
                .environment(container)
        } label: {
            HStack {
                groupLabel(group)
                Spacer()
                Text("\(categoryCount(for: group.identity))")
                    .font(NwTypography.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                edit(group)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(NwAppColors.info)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                prepareDeletion(group)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(NwAppColors.liability)
        }
    }

    private func categoryCount(for identity: String) -> Int {
        return Set(SpendingGroupSetup.latestCategories(categoryRows).lazy.filter {
            $0.categoryGroupIdentity == identity
                && !$0.deletedAtSource
        }.map(\.canonicalId)).count
    }

    private func edit(_ group: ManagedSpendingGroup) {
        editorTarget = SpendingGroupEditorTarget(
            identity: group.identity,
            initialName: group.name
        )
    }

    private func deleteConfirmationMessage(
        _ impact: CanonicalGroupDeletionImpact
    ) -> String {
        let count = impact.categoryCount
        let categoryText = count == 1 ? "1 category" : "\(count) categories"
        return "This permanently removes the group and moves \(categoryText) to Unassigned."
    }

    private func prepareDeletion(_ group: ManagedSpendingGroup) {
        do {
            let impact = try CanonicalDirectoryService(
                context: container.modelContainer.mainContext
            ).groupDeletionImpact(groupIdentity: group.identity)
            activeAlert = .deletion(group, impact)
        } catch {
            activeAlert = .error(error.localizedDescription)
        }
    }

    private func delete(_ group: ManagedSpendingGroup) {
        do {
            try CanonicalDirectoryService(
                context: container.modelContainer.mainContext
            ).deleteGroup(groupIdentity: group.identity)
        } catch {
            activeAlert = .error(error.localizedDescription)
        }
    }

    private func moveGroups(from offsets: IndexSet, to destination: Int) {
        var reordered = groups
        reordered.move(fromOffsets: offsets, toOffset: destination)
        let orderByIdentity = Dictionary(
            uniqueKeysWithValues: reordered.enumerated().map {
                ($0.element.identity, $0.offset)
            }
        )
        for row in groupRows {
            guard let order = orderByIdentity[row.groupIdentity] else { continue }
            row.displayOrder = order
            row.updatedAt = .now
        }
        container.modelContainer.mainContext.safeSave(
            source: "spending.groupManagement.order"
        )
    }

}

private struct SpendingGroupEditorSheet: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(AppContainerController.self) private var container
    let target: SpendingGroupEditorTarget
    let onSaved: () -> Void

    @State private var name: String

    init(target: SpendingGroupEditorTarget, onSaved: @escaping () -> Void) {
        self.target = target
        self.onSaved = onSaved
        _name = State(initialValue: target.initialName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Group name", text: $name)
                }
            }
            .navigationTitle(target.identity == nil ? "Add Group" : "Rename Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(NwAppColors.liability)
                    }
                    .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(
                                canSave
                                    ? NwAppColors.positive
                                    : Color.secondary.opacity(0.35)
                            )
                    }
                    .disabled(!canSave)
                    .accessibilityLabel("Save")
                }
            }
        }
    }

    private var cleanedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool { !cleanedName.isEmpty }

    private func save() {
        let context = container.modelContainer.mainContext
        let rows = (try? context.fetch(
            FetchDescriptor<DurableCategoryGroup>()
        )) ?? []
        if let identity = target.identity {
            let matches = rows.filter { $0.groupIdentity == identity }
            guard !matches.isEmpty else { return }
            for row in matches {
                row.name = cleanedName
                row.updatedAt = .now
            }
            let categories = (try? context.fetch(
                FetchDescriptor<DurableCanonicalCategory>()
            )) ?? []
            for category in categories
            where category.categoryGroupIdentity == identity {
                category.groupName = cleanedName
                category.userEdited = true
                category.updatedAt = .now
            }
        } else {
            let nextOrder = (rows.map(\.displayOrder).max() ?? -1) + 1
            context.insert(DurableCategoryGroup(
                groupIdentity: SpendingGroupSetup.userGroupIdentityPrefix
                    + UUID().uuidString.lowercased(),
                name: cleanedName,
                displayOrder: nextOrder,
                reportingRole: .spending
            ))
        }
        guard context.safeSave(source: "spending.groupManagement.edit") else {
            return
        }
        onSaved()
        dismiss()
    }

}

private struct ManagedSpendingCategory: Identifiable {
    let id: String
    let name: String
}

private struct SpendingGroupCategoryList: View {
    @SwiftUI.Environment(AppContainerController.self) private var container
    @Query private var categories: [DurableCanonicalCategory]
    @Query private var groupRows: [DurableCategoryGroup]
    let group: ManagedSpendingGroup

    @State private var categoryToMove: ManagedSpendingCategory?
    @State private var isSelecting = false
    @State private var selectedCategoryIDs: Set<String> = []

    var body: some View {
        List {
            if assignedCategories.isEmpty {
                NwEmptyState(
                    title: "No Categories",
                    message: group.identity == SpendingGroupSetup.unassignedIdentity
                        ? "Every assignable category is already in one of your groups."
                        : "Assign categories here from Unassigned Categories or another group.",
                    icon: .empty
                )
            } else {
                Section {
                    ForEach(assignedCategories) { category in
                        Button {
                            if isSelecting {
                                toggleSelection(category.id)
                            } else {
                                categoryToMove = category
                            }
                        } label: {
                            HStack {
                                if isSelecting {
                                    Image(systemName: selectedCategoryIDs.contains(
                                        category.id
                                    ) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(
                                        selectedCategoryIDs.contains(category.id)
                                            ? NwAppColors.positive
                                            : Color.secondary
                                    )
                                }
                                Text(category.name)
                                    .foregroundStyle(NwAppColors.textPrimary)
                                Spacer()
                                if !isSelecting {
                                    Image(systemName: "arrow.right.circle")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text(
                        isSelecting
                            ? "Select categories, then use Add to Group."
                            : "Tap a category to move it to another Spending group."
                    )
                }
            }
        }
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isUnassignedList {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSelecting ? "Done" : "Select") {
                        isSelecting.toggle()
                        if !isSelecting {
                            selectedCategoryIDs.removeAll()
                        }
                    }
                    .disabled(assignedCategories.isEmpty)
                }
                if isSelecting {
                    ToolbarItem(placement: .bottomBar) {
                        Menu {
                            ForEach(destinationGroups) { destination in
                                Button(destination.name) {
                                    moveSelectedCategories(to: destination)
                                }
                            }
                        } label: {
                            Label(
                                selectedCategoryIDs.isEmpty
                                    ? "Add to Group"
                                    : "Add \(selectedCategoryIDs.count) to Group",
                                systemImage: "folder"
                            )
                        }
                        .disabled(
                            selectedCategoryIDs.isEmpty
                                || destinationGroups.isEmpty
                        )
                    }
                }
            }
        }
        .sheet(item: $categoryToMove) { category in
            CategoryGroupPickerSheet(
                category: category,
                groups: destinationGroups,
                currentGroupIdentity: group.identity,
                onMove: moveCategory
            )
        }
    }

    private var assignedCategories: [ManagedSpendingCategory] {
        let latestGroupByIdentity = Dictionary(
            grouping: groupRows,
            by: \.groupIdentity
        ).compactMapValues { rows in
            rows.max(by: { $0.updatedAt < $1.updatedAt })
        }
        let userGroupIdentities = Set(latestGroupByIdentity.values.filter {
            SpendingGroupSetup.isUserGroup($0)
        }.map(\.groupIdentity))
        return SpendingGroupSetup.latestCategories(categories)
            .filter {
                guard SpendingGroupSetup.isAssignableCategory(
                    $0,
                    groupByIdentity: latestGroupByIdentity
                ) else { return false }
                if group.identity == SpendingGroupSetup.unassignedIdentity {
                    return SpendingGroupSetup.isUnassignedCategory(
                        $0,
                        userGroupIdentities: userGroupIdentities
                    )
                }
                return $0.categoryGroupIdentity == group.identity
            }
            .map { ManagedSpendingCategory(id: $0.canonicalId, name: $0.name) }
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name)
                    == .orderedAscending
            }
    }

    private var isUnassignedList: Bool {
        group.identity == SpendingGroupSetup.unassignedIdentity
    }

    private var destinationGroups: [ManagedSpendingGroup] {
        let rowsByIdentity = Dictionary(grouping: groupRows) {
            $0.groupIdentity
        }
        return rowsByIdentity.compactMap { identity, rows in
            guard let latest = rows.max(by: { $0.updatedAt < $1.updatedAt }),
                  SpendingGroupSetup.isUserGroup(latest) else {
                return nil
            }
            return ManagedSpendingGroup(
                identity: identity,
                name: latest.name,
                displayOrder: latest.displayOrder
            )
        }
        .sorted {
            if $0.displayOrder != $1.displayOrder {
                return $0.displayOrder < $1.displayOrder
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name)
                == .orderedAscending
        }
    }

    private func moveCategory(
        _ category: ManagedSpendingCategory,
        to destination: ManagedSpendingGroup
    ) -> Bool {
        let matches = categories.filter { $0.canonicalId == category.id }
        guard !matches.isEmpty else { return false }
        for row in matches {
            row.categoryGroupIdentity = destination.identity
            row.groupName = destination.name
            row.userEdited = true
            row.updatedAt = .now
        }
        return container.modelContainer.mainContext.safeSave(
            source: "spending.groupManagement.moveCategory"
        )
    }

    private func toggleSelection(_ categoryID: String) {
        if selectedCategoryIDs.contains(categoryID) {
            selectedCategoryIDs.remove(categoryID)
        } else {
            selectedCategoryIDs.insert(categoryID)
        }
    }

    private func moveSelectedCategories(to destination: ManagedSpendingGroup) {
        let matches = categories.filter {
            selectedCategoryIDs.contains($0.canonicalId)
        }
        guard !matches.isEmpty else { return }
        for row in matches {
            row.categoryGroupIdentity = destination.identity
            row.groupName = destination.name
            row.userEdited = true
            row.updatedAt = .now
        }
        guard container.modelContainer.mainContext.safeSave(
            source: "spending.groupManagement.moveSelectedCategories"
        ) else { return }
        selectedCategoryIDs.removeAll()
        isSelecting = false
    }
}

private struct CategoryGroupPickerSheet: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let category: ManagedSpendingCategory
    let groups: [ManagedSpendingGroup]
    let currentGroupIdentity: String
    let onMove: (ManagedSpendingCategory, ManagedSpendingGroup) -> Bool

    var body: some View {
        NavigationStack {
            List {
                ForEach(groups) { group in
                    Button {
                        guard onMove(category, group) else { return }
                        dismiss()
                    } label: {
                        HStack {
                            Text(group.name)
                                .foregroundStyle(NwAppColors.textPrimary)
                            Spacer()
                            if group.identity == currentGroupIdentity {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(NwAppColors.positive)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(group.identity == currentGroupIdentity)
                }
            }
            .navigationTitle("Move \(category.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(NwAppColors.liability)
                    }
                    .accessibilityLabel("Cancel")
                }
            }
        }
    }
}

// MARK: - Pie

/// One colored wedge of the spending pie. `value` is milliunits spent.
private struct SpendingSlice: Identifiable {
    let id: String
    let value: Double
    let color: Color
}

/// This month's spending as a pie nested inside a gray disc that represents a
/// typical month. Both are sized by *area* against the larger of the two, so:
/// when this month is below normal the colored pie sits visibly inside the gray
/// (the empty gray ring is what's left of a normal month); when it's above,
/// the colored pie fills the frame. A dashed ring always marks the typical
/// level, so the reference stays legible either way. There is no per-group
/// budget — the only benchmark is the user's own history.
private struct NestedSpendingPie: View {
    let slices: [SpendingSlice]
    let currentTotal: Double
    let typicalTotal: Double

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            guard side > 0 else { return }
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let frameR = side / 2
            let maxVal = max(currentTotal, typicalTotal, 1)
            let typicalR = frameR * (typicalTotal / maxVal).squareRoot()
            let currentR = frameR * (currentTotal / maxVal).squareRoot()

            // Gray disc: a normal month's spend.
            context.fill(
                disc(center: center, radius: typicalR),
                with: .color(NwAppColors.chartOther.opacity(0.16))
            )

            // Colored pie: this month, wedge per group.
            if currentTotal > 0 && currentR > 0 {
                var start = Angle.degrees(-90)
                let separator = GraphicsContext.Shading.color(
                    NwAppColors.cardSurface
                )
                for slice in slices where slice.value > 0 {
                    let sweep = Angle.degrees(360 * slice.value / currentTotal)
                    let end = start + sweep
                    var wedge = Path()
                    wedge.move(to: center)
                    wedge.addArc(
                        center: center,
                        radius: currentR,
                        startAngle: start,
                        endAngle: end,
                        clockwise: false
                    )
                    wedge.closeSubpath()
                    context.fill(wedge, with: .color(slice.color))
                    if slices.count > 1 {
                        context.stroke(wedge, with: separator, lineWidth: 1.5)
                    }
                    start = end
                }
            }

            // Dashed ring: the typical level, always visible.
            if typicalR > 0 {
                context.stroke(
                    Path(ellipseIn: CGRect(
                        x: center.x - typicalR,
                        y: center.y - typicalR,
                        width: typicalR * 2,
                        height: typicalR * 2
                    )),
                    with: .color(NwAppColors.chartOther.opacity(0.7)),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
            }
        }
    }

    private func disc(center: CGPoint, radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
    }
}

// MARK: - Model

struct SpendingHistoryModel: Sendable {
    let months: [SpendingHistoryMonth]
    /// groupIdentity -> fixed palette slot (by group display order). Only
    /// the first `NwAppColors.chartCategorical.count` spending groups get a
    /// hue; the rest fold into "Other".
    let paletteIndexByGroupID: [String: Int]
    /// groupIdentity -> display position: columns and chart stacks follow
    /// the user's group order, never the month's spend ranking.
    let orderIndexByGroupID: [String: Int]
    func paletteIndex(for groupID: String) -> Int? {
        paletteIndexByGroupID[groupID]
    }

    func orderIndex(for groupID: String) -> Int {
        orderIndexByGroupID[groupID] ?? Int.max
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
        let accounts = try modelContext.fetch(
            FetchDescriptor<CachedFinancialAccount>()
        )
        let pipelineContext = SpendingEntryPipeline.Context(
            groups: groups, categories: categories, accounts: accounts
        )
        let entries = SpendingEntryPipeline.assembleEntries(
            rows: rows, context: pipelineContext
        )

        var seenDefinitions = Set<String>()
        let groupDefinitions = groups
            .filter { SpendingGroupSetup.isUserGroup($0) }
            .sorted {
                if $0.displayOrder != $1.displayOrder {
                    return $0.displayOrder < $1.displayOrder
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name)
                    == .orderedAscending
            }
            .filter { seenDefinitions.insert($0.groupIdentity).inserted }
            .map {
                SpendingHistoryGroupDefinition(
                    id: $0.groupIdentity,
                    name: $0.name
                )
            }

        let months = SpendingHistoryBuilder.build(
            entries: entries,
            groups: groupDefinitions,
            monthsBack: monthsBack,
            now: now,
            calendar: calendar
        )

        // Fixed hue order follows the entity: spending groups sorted by
        // display order (then name) claim palette slots permanently.
        // Deduped by identity so CloudKit copies can't occupy two slots.
        var seenIdentities = Set<String>()
        let spendingGroups = groups
            .filter { SpendingGroupSetup.isUserGroup($0) }
            .sorted {
                if $0.displayOrder != $1.displayOrder {
                    return $0.displayOrder < $1.displayOrder
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name)
                    == .orderedAscending
            }
            .filter { seenIdentities.insert($0.groupIdentity).inserted }
        var paletteIndex: [String: Int] = [:]
        var orderIndex: [String: Int] = [:]
        for (index, group) in spendingGroups.enumerated() {
            orderIndex[group.groupIdentity] = index
            if index < NwAppColors.chartCategorical.count {
                paletteIndex[group.groupIdentity] = index
            }
        }
        // Type-derived reporting groups sit after the user's spending groups
        // and never participate in category-group management or palette order.
        orderIndex[SpendingGroupSetup.investmentReportingIdentity] =
            spendingGroups.count
        return SpendingHistoryModel(
            months: months,
            paletteIndexByGroupID: paletteIndex,
            orderIndexByGroupID: orderIndex
        )
    }
}

// MARK: - Group detail

/// Month/group drill-down: categories retain the selected month's totals and
/// transaction list, with a separate path to complete cached history.
struct SpendingGroupDetailSheet: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let selection: SpendingGroupDetailSelection

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Spent") {
                        Text(CurrencyFormatter.currency(selection.group.spent))
                    }
                }
                // One compact row per category in a single joined list;
                // transactions live one tap deeper.
                Section {
                    ForEach(selection.group.categories) { category in
                        NavigationLink {
                            SpendingCategoryMonthDetailView(
                                month: selection.month.month,
                                category: category,
                                reportingRole: selection.group.reportingRole
                            )
                        } label: {
                            HStack(spacing: NwSpacing.xs) {
                                Text(category.name)
                                    .lineLimit(1)
                                Text("(\(category.transactionIds.count))")
                                    .font(NwTypography.footnote)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(CurrencyFormatter.currency(category.spent))
                                    .foregroundStyle(.secondary)
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
        }
    }
}

private struct SpendingCategoryMonthDetailView: View {
    @SwiftUI.Environment(AppContainerController.self) private var container
    let month: Date
    let category: SpendingHistoryCategoryTotal
    let reportingRole: CategoryReportingRole?

    @State private var rowsByID: [String: CachedFinancialTransaction] = [:]

    var body: some View {
        List {
            Section {
                NavigationLink {
                    FinancialAccountTransactionHistoryView(
                        categoryFilter: categoryFilter
                    )
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("View All History")
                                .foregroundStyle(NwAppColors.textPrimary)
                            Text("Every cached month")
                                .font(NwTypography.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(NwAppColors.primary)
                    }
                }
            }

            Section(month.formatted(.dateTime.month(.wide).year())) {
                ForEach(monthTransactions, id: \.id) { row in
                    NavigationLink {
                        PlaidTransactionReviewEditor(
                            transaction: row,
                            dismissAfterSave: true,
                            onSaved: loadRows
                        )
                    } label: {
                        NwTransactionRow(
                            title: row.displayName,
                            subtitle: row.postedDate.formatted(
                                date: .abbreviated,
                                time: .omitted
                            ),
                            amount: Money(
                                milliunits:
                                    category.lineAmountsByTransactionId[row.id]
                                        ?? row.amountMilliunits
                            )
                        )
                    }
                }
            }
        }
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadRows)
    }

    private var categoryFilter: FinancialTransactionCategoryFilter {
        FinancialTransactionCategoryFilter(
            key: category.id,
            name: category.name,
            isInvestmentContribution: reportingRole == .investment
        )
    }

    private var monthTransactions: [CachedFinancialTransaction] {
        category.transactionIds
            .compactMap { rowsByID[$0] }
            .sorted { $0.postedDate > $1.postedDate }
    }

    private func loadRows() {
        let ids = Set(category.transactionIds)
        guard !ids.isEmpty else {
            rowsByID = [:]
            return
        }
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
