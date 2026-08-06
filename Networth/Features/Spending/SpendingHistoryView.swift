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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingGroupManager = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Manage spending groups")
                }
            }
        }
        .task {
            ensureSpendingGroupSetup()
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
                NwAmountText(month.total, variant: .hero, showCents: false)
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

    /// Vertical columns for the selected month's groups in the user's group
    /// order; tapping a column selects that group's 24-month history. Few
    /// groups share the full width; many scroll.
    private func groupColumns(_ month: SpendingHistoryMonth) -> some View {
        let groups = orderedGroups(in: month)
        let maxSpent = max(groups.map(\.spentMilliunits).max() ?? 1, 1)
        return NwCard(style: .primary) {
            VStack(alignment: .leading, spacing: NwSpacing.sm) {
                if groups.isEmpty {
                    Text("No approved spending this month.")
                        .font(NwTypography.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if groups.count <= 5 {
                    HStack(alignment: .bottom, spacing: NwSpacing.md) {
                        ForEach(groups) { group in
                            groupColumn(
                                group,
                                month: month,
                                maxSpent: maxSpent,
                                flexible: true
                            )
                        }
                    }
                    .padding(.top, NwSpacing.xs)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .bottom, spacing: NwSpacing.md) {
                            ForEach(groups) { group in
                                groupColumn(
                                    group,
                                    month: month,
                                    maxSpent: maxSpent,
                                    flexible: false
                                )
                            }
                        }
                        .padding(.top, NwSpacing.xs)
                    }
                }
                if let model, !model.hiddenGroups.isEmpty {
                    HStack {
                        Spacer()
                        Menu {
                            ForEach(model.hiddenGroups) { hidden in
                                Button {
                                    setGroupHidden(hidden.identity, hidden: false)
                                } label: {
                                    Label(hidden.name, systemImage: "eye")
                                }
                            }
                        } label: {
                            Image(systemName: "eye.slash")
                                .font(NwTypography.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.top, NwSpacing.xs)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Hidden groups")
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

    private func groupColumn(
        _ group: SpendingHistoryGroupTotal,
        month: SpendingHistoryMonth,
        maxSpent: Int64,
        flexible: Bool
    ) -> some View {
        let isSelected = selectedChartSeriesID == group.id
        let height = max(
            12,
            CGFloat(group.spentMilliunits) / CGFloat(maxSpent) * 120
        )
        return Button {
            selectedChartSeriesID = group.id
        } label: {
            VStack(spacing: NwSpacing.xs) {
                Text(CurrencyFormatter.currency(group.spent, showCents: false))
                    .font(NwTypography.caption)
                    .foregroundStyle(
                        group.spentMilliunits < 0
                            ? NwAppColors.liability
                            : NwAppColors.textPrimary
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color(for: group.id))
                    .frame(
                        maxWidth: flexible ? .infinity : 44,
                        alignment: .center
                    )
                    .frame(
                        width: flexible ? nil : 44,
                        height: height
                    )
                Text(group.name)
                    .font(
                        isSelected
                            ? NwTypography.caption.weight(.semibold)
                            : NwTypography.caption
                    )
                    .foregroundStyle(
                        isSelected ? NwAppColors.primary : .secondary
                    )
                    .lineLimit(1)
                    .frame(maxWidth: flexible ? .infinity : 72)
            }
            .frame(maxWidth: flexible ? .infinity : nil)
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityHint("Shows this group's spending history")
        .contextMenu {
            if group.id != SpendingHistoryBuilder.ungroupedIdentity
                && group.id != SpendingGroupSetup.unassignedIdentity {
                Button {
                    moveGroupEarlier(group.id)
                } label: {
                    Label("Move Left", systemImage: "arrow.left")
                }
                Button(role: .destructive) {
                    setGroupHidden(group.id, hidden: true)
                } label: {
                    Label("Hide from Spending", systemImage: "eye.slash")
                }
            }
        }
    }

    /// Hiding removes the group from every Spending History total, column,
    /// and chart stack until unhidden via the eye-slash menu on the columns
    /// card.
    private func setGroupHidden(_ identity: String, hidden: Bool) {
        let ctx = container.modelContainer.mainContext
        let rows = (try? ctx.fetch(
            FetchDescriptor<DurableCategoryGroup>(
                predicate: #Predicate { $0.groupIdentity == identity }
            )
        )) ?? []
        guard !rows.isEmpty else { return }
        // Stamp every copy: CloudKit-duplicated rows must all agree.
        for row in rows {
            row.hidden = hidden
            row.updatedAt = .now
        }
        ctx.safeSave(source: "spending.groupHidden")
    }

    /// Prepare Networth's assignable automatic categories and migrate away
    /// from the retired seeded-group experiment. Users own every real group.
    private func ensureSpendingGroupSetup() {
        SpendingGroupSetup.ensure(in: container.modelContainer.mainContext)
    }

    /// Column order is user-owned: swap the group one position earlier
    /// after normalizing display orders to a clean sequence.
    private func moveGroupEarlier(_ identity: String) {
        let ctx = container.modelContainer.mainContext
        let groups = ((try? ctx.fetch(
            FetchDescriptor<DurableCategoryGroup>()
        )) ?? [])
            .filter { SpendingGroupSetup.isUserGroup($0) && !$0.hidden }
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
                milliunits = month.totalMilliunits
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

enum SpendingGroupSetup {
    static let userOwnedGroupsVersion = 3
    static let currentVersion = 4
    static let userGroupIdentityPrefix = "networth:spending:user:"
    static let unassignedIdentity = "networth:spending:unassigned"
    static let unassignedName = "Unassigned"
    static let savingsCategoryIdentity = "networth:savings-transfers"
    static let investmentCategoryIdentity = "networth:investment-contributions"
    static let automaticCategoryIdentities: Set<String> = [
        savingsCategoryIdentity, investmentCategoryIdentity
    ]

    private struct RetiredDefault {
        let identity: String
        let name: String
    }

    private static let retiredDefaults = [
        RetiredDefault(identity: "networth:spending:fixed", name: "Fixed"),
        RetiredDefault(
            identity: "networth:spending:necessities",
            name: "Necessities"
        ),
        RetiredDefault(identity: "networth:spending:surplus", name: "Surplus"),
        RetiredDefault(identity: "networth:spending:savings", name: "Savings"),
        RetiredDefault(
            identity: "networth:spending:investment",
            name: "Investment"
        )
    ]

    static func isUserGroup(_ group: DurableCategoryGroup) -> Bool {
        group.reportingRole == .spending
            && !group.groupIdentity.hasPrefix("ynab:")
            && group.groupIdentity != unassignedIdentity
            && !retiredDefaults.contains {
                $0.identity == group.groupIdentity && $0.name == group.name
            }
    }

    static func isAssignableCategory(
        _ category: DurableCanonicalCategory,
        groupByIdentity: [String: DurableCategoryGroup]
    ) -> Bool {
        guard !category.deletedAtSource else { return false }
        if automaticCategoryIdentities.contains(category.canonicalId) {
            return true
        }
        guard let identity = category.categoryGroupIdentity,
              let sourceGroup = groupByIdentity[identity] else {
            return true
        }
        return sourceGroup.reportingRole == .spending
    }

    static func isUnassignedCategory(
        _ category: DurableCanonicalCategory,
        userGroupIdentities: Set<String>
    ) -> Bool {
        guard let identity = category.categoryGroupIdentity else { return true }
        return !userGroupIdentities.contains(identity)
    }

    static func categoryIdentitiesWithTransactions(
        transactions: [CachedFinancialTransaction],
        accounts: [CachedFinancialAccount]
    ) -> Set<String> {
        let accountTypeByIdentity = Dictionary(
            accounts.map { ($0.canonicalAccountId, $0.type) },
            uniquingKeysWith: { first, _ in first }
        )
        var identities = Set<String>()
        for transaction in transactions where !transaction.deleted {
            if transaction.forecastTreatment == .internalTransfer,
               accountTypeByIdentity[transaction.canonicalAccountId] == .savings {
                identities.insert(savingsCategoryIdentity)
            }
            if transaction.forecastTreatment == .investmentContribution,
               accountTypeByIdentity[transaction.canonicalAccountId]?.isCashLike
                    == true {
                identities.insert(investmentCategoryIdentity)
            }

            let legs = transaction.subtransactions.filter { !$0.deleted }
            if legs.isEmpty {
                if let categoryID = transaction.categoryCanonicalId {
                    identities.insert(categoryID)
                }
            } else {
                for leg in legs {
                    if let categoryID = leg.categoryCanonicalId ?? leg.categoryId {
                        identities.insert(categoryID)
                    }
                }
            }
        }
        return identities
    }

    /// User-created groups are the only Spending structure. YNAB grouping is
    /// retained solely as reference metadata and is never surfaced here.
    @MainActor
    static func ensure(in context: ModelContext) {
        let settings = (try? context.fetch(
            FetchDescriptor<DurableUserSettings>()
        ))?.first
        let existing = (try? context.fetch(
            FetchDescriptor<DurableCategoryGroup>()
        )) ?? []
        let categories = (try? context.fetch(
            FetchDescriptor<DurableCanonicalCategory>()
        )) ?? []
        let transactions = (try? context.fetch(
            FetchDescriptor<CachedFinancialTransaction>()
        )) ?? []
        let accounts = (try? context.fetch(
            FetchDescriptor<CachedFinancialAccount>()
        )) ?? []
        var changed = false

        if (settings?.spendingGroupSetupVersion ?? 0) < userOwnedGroupsVersion {
            // Retire only untouched defaults. A renamed row represents a group
            // the user chose to keep and remains fully editable.
            for retired in retiredDefaults {
                let matchingRows = existing.filter {
                    $0.groupIdentity == retired.identity
                }
                guard !matchingRows.isEmpty,
                      matchingRows.allSatisfy({ $0.name == retired.name }) else {
                    continue
                }
                for category in categories
                where category.categoryGroupIdentity == retired.identity {
                    category.categoryGroupIdentity = nil
                    category.groupName = ""
                    category.updatedAt = .now
                }
                for row in matchingRows {
                    row.hidden = true
                    row.updatedAt = .now
                }
                changed = true
            }
        }

        let automaticCategories = [
            (savingsCategoryIdentity, "Savings Transfers"),
            (investmentCategoryIdentity, "Investment Contributions")
        ]
        let transactionCategoryIDs = categoryIdentitiesWithTransactions(
            transactions: transactions,
            accounts: accounts
        )
        for automatic in automaticCategories
        where transactionCategoryIDs.contains(automatic.0)
            && !categories.contains(where: { $0.canonicalId == automatic.0 }) {
            context.insert(DurableCanonicalCategory(
                canonicalId: automatic.0,
                name: automatic.1,
                sourceName: automatic.1,
                userEdited: true
            ))
            changed = true
        }

        if let settings,
           settings.spendingGroupSetupVersion < userOwnedGroupsVersion {
            settings.spendingGroupSetupVersion = userOwnedGroupsVersion
            changed = true
        }

        let activeTransactions = transactions.filter { !$0.deleted }
        let canPruneUnusedCategories = (settings?.spendingGroupSetupVersion
                ?? 0) < currentVersion
            && settings?.firstPlaidSyncCompletedAt != nil
            && !activeTransactions.isEmpty
            && !activeTransactions.contains {
                !$0.pending && $0.requiresReview
            }
        if canPruneUnusedCategories {
            var retainedCategoryIDs = transactionCategoryIDs
            let decisions = (try? context.fetch(
                FetchDescriptor<DurableCanonicalTransactionDecision>()
            )) ?? []
            for decision in decisions {
                if let categoryID = decision.categoryCanonicalId {
                    retainedCategoryIDs.insert(categoryID)
                }
                for leg in decision.subtransactions where !leg.deleted {
                    if let categoryID = leg.categoryCanonicalId ?? leg.categoryId {
                        retainedCategoryIDs.insert(categoryID)
                    }
                }
            }
            let overrides = (try? context.fetch(
                FetchDescriptor<DurableTransactionOverride>()
            )) ?? []
            for override in overrides {
                for leg in override.subtransactions where !leg.deleted {
                    if let categoryID = leg.categoryCanonicalId ?? leg.categoryId {
                        retainedCategoryIDs.insert(categoryID)
                    }
                }
            }
            let expectations = (try? context.fetch(
                FetchDescriptor<DurableRecurringExpectation>()
            )) ?? []
            for expectation in expectations {
                if let categoryID = expectation.categoryCanonicalId {
                    retainedCategoryIDs.insert(categoryID)
                }
            }
            for category in categories
            where !retainedCategoryIDs.contains(category.canonicalId) {
                context.delete(category)
                changed = true
            }
            settings?.spendingGroupSetupVersion = currentVersion
            changed = true
        }
        if changed {
            context.safeSave(source: "spending.groupSetup")
        }
    }
}

private struct ManagedSpendingGroup: Identifiable, Hashable {
    let identity: String
    let name: String
    let displayOrder: Int
    let hidden: Bool

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

struct SpendingGroupManagementSheet: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(AppContainerController.self) private var container
    @Query private var groupRows: [DurableCategoryGroup]
    @Query private var categoryRows: [DurableCanonicalCategory]
    @Query private var transactionRows: [CachedFinancialTransaction]
    @Query private var accountRows: [CachedFinancialAccount]

    @State private var editorTarget: SpendingGroupEditorTarget?

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
                    if visibleGroups.isEmpty {
                        Text("No groups yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(visibleGroups) { group in
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
                } footer: {
                    Text(
                        "Savings Transfers and Investment Contributions are automatic categories; you decide which group contains them."
                    )
                }

                if !hiddenGroups.isEmpty {
                    Section("Hidden") {
                        ForEach(hiddenGroups) { group in
                            Button {
                                setHidden(group.identity, hidden: false)
                            } label: {
                                HStack {
                                    groupLabel(group)
                                    Spacer()
                                    Image(systemName: "eye")
                                        .foregroundStyle(NwAppColors.primary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Spending Groups")
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
                ToolbarItem(placement: .primaryAction) {
                    EditButton()
                }
            }
        }
        .onAppear {
            SpendingGroupSetup.ensure(
                in: container.modelContainer.mainContext
            )
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
                displayOrder: latest.displayOrder,
                hidden: rows.contains(where: \.hidden)
            )
        }
        .sorted(by: groupSort)
    }

    private var visibleGroups: [ManagedSpendingGroup] {
        groups.filter { !$0.hidden }
    }

    private var hiddenGroups: [ManagedSpendingGroup] {
        groups.filter(\.hidden)
    }

    private var unassignedGroup: ManagedSpendingGroup {
        ManagedSpendingGroup(
            identity: SpendingGroupSetup.unassignedIdentity,
            name: SpendingGroupSetup.unassignedName,
            displayOrder: Int.max,
            hidden: false
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
        let categoryIDs = SpendingGroupSetup.categoryIdentitiesWithTransactions(
            transactions: transactionRows,
            accounts: accountRows
        )
        return categoryRows.filter {
            categoryIDs.contains($0.canonicalId)
                && SpendingGroupSetup.isAssignableCategory(
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
        VStack(alignment: .leading, spacing: NwSpacing.sm) {
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
            HStack(spacing: NwSpacing.md) {
                Button {
                    edit(group)
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    setHidden(group.identity, hidden: true)
                } label: {
                    Label("Hide", systemImage: "eye.slash")
                }
            }
            .font(NwTypography.footnote)
            .buttonStyle(.borderless)
        }
        .padding(.vertical, NwSpacing.xs)
    }

    private func categoryCount(for identity: String) -> Int {
        let categoryIDs = SpendingGroupSetup.categoryIdentitiesWithTransactions(
            transactions: transactionRows,
            accounts: accountRows
        )
        return Set(categoryRows.lazy.filter {
            $0.categoryGroupIdentity == identity
                && !$0.deletedAtSource
                && categoryIDs.contains($0.canonicalId)
        }.map(\.canonicalId)).count
    }

    private func edit(_ group: ManagedSpendingGroup) {
        editorTarget = SpendingGroupEditorTarget(
            identity: group.identity,
            initialName: group.name
        )
    }

    private func setHidden(_ identity: String, hidden: Bool) {
        let matches = groupRows.filter { $0.groupIdentity == identity }
        guard !matches.isEmpty else { return }
        for row in matches {
            row.hidden = hidden
            row.updatedAt = .now
        }
        container.modelContainer.mainContext.safeSave(
            source: "spending.groupManagement.visibility"
        )
    }

    private func moveGroups(from offsets: IndexSet, to destination: Int) {
        var reordered = visibleGroups
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
    @Query private var transactionRows: [CachedFinancialTransaction]
    @Query private var accountRows: [CachedFinancialAccount]
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
        let categoryIDs = SpendingGroupSetup.categoryIdentitiesWithTransactions(
            transactions: transactionRows,
            accounts: accountRows
        )
        return categories
            .filter {
                guard categoryIDs.contains($0.canonicalId) else { return false }
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
                  SpendingGroupSetup.isUserGroup(latest),
                  !rows.contains(where: \.hidden) else {
                return nil
            }
            return ManagedSpendingGroup(
                identity: identity,
                name: latest.name,
                displayOrder: latest.displayOrder,
                hidden: false
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

// MARK: - Model

struct HiddenSpendingGroup: Sendable, Identifiable {
    let identity: String
    let name: String
    var id: String { identity }
}

struct SpendingHistoryModel: Sendable {
    let months: [SpendingHistoryMonth]
    /// groupIdentity -> fixed palette slot (by group display order). Only
    /// the first `NwAppColors.chartCategorical.count` spending groups get a
    /// hue; the rest fold into "Other".
    let paletteIndexByGroupID: [String: Int]
    /// groupIdentity -> display position: columns and chart stacks follow
    /// the user's group order, never the month's spend ranking.
    let orderIndexByGroupID: [String: Int]
    /// Spending groups the user hid from Spending History entirely.
    let hiddenGroups: [HiddenSpendingGroup]

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
        let groupByIdentity = Dictionary(
            groups.sorted { $0.updatedAt > $1.updatedAt }
                .map { ($0.groupIdentity, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // CloudKit can duplicate group rows; hiding must win if ANY copy of
        // the identity is hidden, whichever copy other lookups picked.
        let hiddenIdentities = Set(
            groups.filter {
                SpendingGroupSetup.isUserGroup($0) && $0.hidden
            }
                .map(\.groupIdentity)
        )
        let accountTypeByIdentity = Dictionary(
            accounts.map { ($0.canonicalAccountId, $0.type) },
            uniquingKeysWith: { first, _ in first }
        )
        let categoryByCanonicalID = Dictionary(
            categories.map { ($0.canonicalId, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        func resolvedGroup(
            categoryCanonicalId: String?
        ) -> (identity: String, name: String, hidden: Bool) {
            guard let categoryCanonicalId,
                  let category = categoryByCanonicalID[categoryCanonicalId],
                  let identity = category.categoryGroupIdentity,
                  let group = groupByIdentity[identity],
                  SpendingGroupSetup.isUserGroup(group) else {
                return (
                    SpendingGroupSetup.unassignedIdentity,
                    SpendingGroupSetup.unassignedName,
                    false
                )
            }
            return (identity, group.name, hiddenIdentities.contains(identity))
        }

        let savingsGroup = resolvedGroup(
            categoryCanonicalId: SpendingGroupSetup.savingsCategoryIdentity
        )
        let investmentGroup = resolvedGroup(
            categoryCanonicalId: SpendingGroupSetup.investmentCategoryIdentity
        )

        var entries: [SpendingHistoryEntry] = []
        for row in rows {
            if row.forecastTreatment == .internalTransfer {
                // Count only the savings-account side. The corresponding
                // checking row is ignored, preventing a transfer from being
                // shown twice while preserving net deposits minus withdrawals.
                guard accountTypeByIdentity[row.canonicalAccountId] == .savings,
                      !savingsGroup.hidden else { continue }
                entries.append(SpendingHistoryEntry(
                    transactionId: row.id,
                    date: row.postedDate,
                    amountMilliunits: row.amountMilliunits,
                    treatment: .internalTransfer,
                    reportingRole: .transfer,
                    groupIdentity: savingsGroup.identity,
                    groupName: savingsGroup.name,
                    categoryKey: SpendingGroupSetup.savingsCategoryIdentity,
                    categoryName: "Savings Transfers"
                ))
                continue
            }
            if row.forecastTreatment == .investmentContribution {
                // Count the linked cash-account side only. If a provider also
                // exposes the investment-account counterpart, ignoring it
                // prevents the contribution from cancelling itself out.
                guard accountTypeByIdentity[row.canonicalAccountId]?.isCashLike
                        == true,
                      !investmentGroup.hidden else { continue }
                entries.append(SpendingHistoryEntry(
                    transactionId: row.id,
                    date: row.postedDate,
                    amountMilliunits: row.amountMilliunits,
                    treatment: .investmentContribution,
                    reportingRole: .investment,
                    groupIdentity: investmentGroup.identity,
                    groupName: investmentGroup.name,
                    categoryKey: SpendingGroupSetup.investmentCategoryIdentity,
                    categoryName: "Investment Contributions"
                ))
                continue
            }
            let legs = row.subtransactions
            if legs.isEmpty {
                let group = resolvedGroup(
                    categoryCanonicalId: row.categoryCanonicalId
                )
                // A hidden spending group is excluded from Spending History
                // entirely — totals, columns, and chart.
                if group.hidden { continue }
                entries.append(SpendingHistoryEntry(
                    transactionId: row.id,
                    date: row.postedDate,
                    amountMilliunits: row.amountMilliunits,
                    treatment: row.forecastTreatment,
                    reportingRole: .spending,
                    groupIdentity: group.identity,
                    groupName: group.name,
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
                    if group.hidden { continue }
                    entries.append(SpendingHistoryEntry(
                        transactionId: row.id,
                        date: row.postedDate,
                        amountMilliunits: leg.amount.milliunits,
                        // An unmarked part of an INCOMING split must not
                        // inherit the whole-transaction Reimbursement label
                        // and offset spending; nil excludes it. Outgoing
                        // splits are ordinary spending either way.
                        treatment: leg.forecastTreatment
                            ?? (row.amountMilliunits < 0
                                ? row.forecastTreatment
                                : nil),
                        reportingRole: .spending,
                        groupIdentity: group.identity,
                        groupName: group.name,
                        categoryKey: legCanonicalId
                            ?? "name:\(leg.categoryName ?? "Uncategorized")",
                        categoryName: leg.categoryName ?? "Uncategorized"
                    ))
                }
            }
        }

        var seenDefinitions = Set<String>()
        let groupDefinitions = groups
            .filter {
                SpendingGroupSetup.isUserGroup($0)
                    && !hiddenIdentities.contains($0.groupIdentity)
            }
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
            .filter {
                SpendingGroupSetup.isUserGroup($0)
                    && !hiddenIdentities.contains($0.groupIdentity)
            }
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
        var seenHidden = Set<String>()
        let hiddenGroups = groups
            .filter {
                SpendingGroupSetup.isUserGroup($0)
                    && hiddenIdentities.contains($0.groupIdentity)
            }
            .filter { seenHidden.insert($0.groupIdentity).inserted }
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name)
                    == .orderedAscending
            }
            .map {
                HiddenSpendingGroup(identity: $0.groupIdentity, name: $0.name)
            }
        return SpendingHistoryModel(
            months: months,
            paletteIndexByGroupID: paletteIndex,
            orderIndexByGroupID: orderIndex,
            hiddenGroups: hiddenGroups
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
                // One compact row per category in a single joined list;
                // transactions live one tap deeper.
                Section {
                    ForEach(selection.group.categories) { category in
                        NavigationLink {
                            categoryTransactions(category)
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
            .onAppear(perform: loadRows)
        }
    }

    private func categoryTransactions(
        _ category: SpendingHistoryCategoryTotal
    ) -> some View {
        List {
            ForEach(transactions(for: category), id: \.id) { row in
                NavigationLink {
                    PlaidTransactionReviewEditor(
                        transaction: row,
                        matchingTransactions: [row],
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
                        amount: displayAmount(for: row, category: category)
                    )
                }
            }
        }
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.inline)
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
