import SwiftUI
import SwiftData
import Charts
import UIKit
import NetworthCore

private enum SpendingPeriodFormatter {
    static func label(from startMonth: Date, through endMonth: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(
            startMonth,
            equalTo: endMonth,
            toGranularity: .month
        ) {
            return endMonth.formatted(.dateTime.month(.wide).year())
        }
        if calendar.isDate(
            startMonth,
            equalTo: endMonth,
            toGranularity: .year
        ) {
            return "\(startMonth.formatted(.dateTime.month(.abbreviated)))–\(endMonth.formatted(.dateTime.month(.abbreviated).year()))"
        }
        return "\(startMonth.formatted(.dateTime.month(.abbreviated).year()))–\(endMonth.formatted(.dateTime.month(.abbreviated).year()))"
    }
}

private enum SpendingTrendSeries {
    static let all = "networth:spending:all"
}

private enum SpendingTrendRange: Int, CaseIterable, Identifiable {
    case sixMonths = 6
    case twelveMonths = 12
    case twentyFourMonths = 24

    var id: Int { rawValue }
    var label: String { "\(rawValue) mo" }
    var axisStride: Int {
        switch self {
        case .sixMonths: return 1
        case .twelveMonths: return 2
        case .twentyFourMonths: return 3
        }
    }
}

private struct SpendingTrendDatum: Identifiable {
    let month: Date
    let amount: Money
    let isPartial: Bool

    var id: Date { month }
}

private func spendingTrendData(
    model: SpendingHistoryModel,
    monthCount: Int,
    seriesID: String,
    calendar: Calendar = .current
) -> [SpendingTrendDatum] {
    model.months.suffix(monthCount).map { month in
        let milliunits: Int64
        if seriesID == SpendingTrendSeries.all {
            milliunits = month.ordinaryTotalMilliunits
        } else {
            milliunits = max(
                0,
                month.groups.first { $0.id == seriesID }?.spentMilliunits ?? 0
            )
        }
        return SpendingTrendDatum(
            month: month.month,
            amount: Money(milliunits: milliunits),
            isPartial: calendar.isDate(
                month.month,
                equalTo: .now,
                toGranularity: .month
            )
        )
    }
}

private struct SpendingTrendChart: View {
    let data: [SpendingTrendDatum]
    let color: Color
    let compact: Bool
    let axisStride: Int
    let selectedMonth: Date?
    var onSelect: ((Date) -> Void)? = nil

    var body: some View {
        Chart(data) { datum in
            BarMark(
                x: .value("Month", datum.month, unit: .month),
                y: .value("Monthly spending", datum.amount.doubleValue),
                width: .ratio(0.68)
            )
            .foregroundStyle(
                color.opacity(
                    datum.isPartial
                        ? 0.45
                        : selectedMonth == nil || selectedMonth == datum.month
                            ? 0.9
                            : 0.55
                )
            )
            .cornerRadius(3)
        }
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(
                values: .stride(by: .month, count: axisStride)
            ) { value in
                AxisGridLine()
                    .foregroundStyle(NwAppColors.strokeSubtle)
                AxisValueLabel {
                    if let month = value.as(Date.self) {
                        Text(
                            month.formatted(
                                compact
                                    ? .dateTime.month(.narrow)
                                    : .dateTime.month(.abbreviated)
                            )
                        )
                        .font(NwTypography.caption)
                    }
                }
            }
        }
        .chartYAxis {
            if !compact {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                        .foregroundStyle(NwAppColors.strokeSubtle)
                    AxisValueLabel {
                        if let dollars = value.as(Double.self) {
                            Text(
                                CurrencyFormatter.compact(
                                    Money(
                                        milliunits: Int64(dollars * 1000)
                                    )
                                )
                            )
                            .font(NwTypography.caption)
                        }
                    }
                }
            }
        }
        .chartYScale(domain: .automatic(includesZero: true))
        .chartGesture { proxy in
            SpatialTapGesture()
                .onEnded { value in
                    guard let month: Date = proxy.value(
                        atX: value.location.x
                    ) else { return }
                    onSelect?(month)
                }
        }
    }
}

/// Spending History — the Spending tab (Phase 1 step 3).
///
/// Month navigation, the review card for posted transactions awaiting
/// approval, the selected month's total and per-group columns, and a compact
/// link to the dedicated Spending Trends detail. Only approved activity
/// counts; the current month is month-to-date, completed months are final.
struct SpendingHistoryView: View {
    @SwiftUI.Environment(AppContainerController.self) private var container

    private enum SummaryRange: Int, CaseIterable, Identifiable, Hashable {
        case oneMonth = 1
        case threeMonths = 3
        case sixMonths = 6
        case twelveMonths = 12

        var id: Int { rawValue }
        var label: String { "\(rawValue) mo" }
    }

    private struct DisplayedPeriod {
        let months: [SpendingHistoryMonth]
        let summary: SpendingHistoryMonth

        var startMonth: Date { months[0].month }
        var monthCount: Int { months.count }
        var label: String {
            SpendingPeriodFormatter.label(
                from: startMonth,
                through: summary.month
            )
        }
    }

    @State private var model: SpendingHistoryModel?
    @State private var selectedMonth: Date?
    @State private var summaryRange = SummaryRange.oneMonth
    @State private var detailSelection: SpendingGroupDetailSelection?
    @State private var showingGroupedReview = false
    @State private var showingIndividualReview = false
    @State private var showingGroupManager = false
    @State private var rebuildTask: Task<Void, Never>?

    private let calendar = Calendar.current
    private let visibleMonthCount = 24

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NwSpacing.lg) {
                    if pendingReviewCount > 0 {
                        reviewCard
                    }
                    if let model {
                        monthHeader(model)
                        if let period = displayedPeriod(model) {
                            monthTotalCard(period, model: model)
                            spendingBreakdown(period, model: model)
                        }
                        spendingTrendPreview(model)
                        allTransactionsLink
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

    private var allTransactionsLink: some View {
        NavigationLink {
            FinancialAccountTransactionHistoryView()
        } label: {
            NwCard(style: .primary) {
                HStack(spacing: NwSpacing.sm) {
                    NwIcon.history.image
                        .font(NwTypography.headline)
                        .foregroundStyle(NwAppColors.primary)
                    Text("All Transactions")
                        .font(NwTypography.headline)
                        .foregroundStyle(NwAppColors.textPrimary)
                    Spacer()
                    NwIcon.chevron.image
                        .font(NwTypography.footnoteEm)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Month navigation

    private func displayedMonth(
        _ model: SpendingHistoryModel
    ) -> SpendingHistoryMonth? {
        let selectableMonths = selectableMonths(in: model)
        guard let selectedMonth else { return selectableMonths.last }
        return selectableMonths.first { $0.month == selectedMonth }
            ?? selectableMonths.last
    }

    private func selectableMonths(
        in model: SpendingHistoryModel
    ) -> [SpendingHistoryMonth] {
        Array(model.months.suffix(visibleMonthCount))
    }

    private func displayedPeriod(
        _ model: SpendingHistoryModel
    ) -> DisplayedPeriod? {
        if summaryRange != .oneMonth {
            let months = Array(
                model.months
                    .filter { !isCurrentMonth($0.month) }
                    .suffix(summaryRange.rawValue)
            )
            guard let summary = SpendingHistoryBuilder.aggregate(months: months)
            else { return nil }
            return DisplayedPeriod(months: months, summary: summary)
        }

        guard let endingMonth = displayedMonth(model),
              let endingIndex = model.months.firstIndex(where: {
                  $0.month == endingMonth.month
              }) else { return nil }
        let startIndex = max(
            model.months.startIndex,
            endingIndex - summaryRange.rawValue + 1
        )
        let months = Array(model.months[startIndex...endingIndex])
        guard let summary = SpendingHistoryBuilder.aggregate(months: months)
        else { return nil }
        return DisplayedPeriod(months: months, summary: summary)
    }

    private func monthHeader(_ model: SpendingHistoryModel) -> some View {
        let current = displayedMonth(model)
        return HStack(spacing: NwSpacing.sm) {
            Menu {
                ForEach(selectableMonths(in: model).reversed()) { month in
                    Button {
                        selectedMonth = month.month
                        summaryRange = .oneMonth
                    } label: {
                        if month.month == current?.month {
                            Label(
                                month.month.formatted(
                                    .dateTime.month(.wide).year()
                                ),
                                systemImage: "checkmark"
                            )
                        } else {
                            Text(
                                month.month.formatted(
                                    .dateTime.month(.wide).year()
                                )
                            )
                        }
                    }
                }
            } label: {
                HStack(spacing: NwSpacing.xs) {
                    Text(
                        current?.month.formatted(
                            .dateTime.month(.wide).year()
                        ) ?? "Select Month"
                    )
                    .font(NwTypography.titleSmall)
                    .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(NwTypography.caption)
                }
                .foregroundStyle(
                    summaryRange == .oneMonth
                        ? NwAppColors.textPrimary
                        : NwAppColors.textSecondary
                )
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Spending month")
            .accessibilityHint("Selecting a month switches to 1 month")

            Spacer(minLength: 0)

            Picker("Spending summary range", selection: $summaryRange) {
                ForEach(SummaryRange.allCases) { range in
                    Text(range.label).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
        }
        .frame(maxWidth: .infinity)
    }

    private func isCurrentMonth(_ month: Date?) -> Bool {
        guard let month else { return false }
        return calendar.isDate(month, equalTo: .now, toGranularity: .month)
    }

    // MARK: - Selected month

    private func monthTotalCard(
        _ period: DisplayedPeriod,
        model: SpendingHistoryModel
    ) -> some View {
        let month = period.summary
        let display = month.wholeDollarDisplay
        return NwCard(style: .primary) {
            VStack(alignment: .leading, spacing: NwSpacing.sm) {
                Text(
                    period.monthCount == 1
                        ? "Spent"
                        : "Spent · \(period.label)"
                )
                    .font(NwTypography.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: NwSpacing.sm) {
                    NwAmountText(
                        display.ordinaryHeadline,
                        variant: .hero,
                        showCents: false
                    )
                    if let comparison = spendingComparison(
                        for: period,
                        model: model
                    ) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(comparison.label)
                                .font(NwTypography.caption)
                            Text(
                                CurrencyFormatter.currency(
                                    comparison.amount,
                                    showCents: true
                                )
                            )
                            .font(NwTypography.title)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        }
                        .foregroundStyle(.secondary)
                    }
                }

                Divider()
                    .padding(.vertical, NwSpacing.xs)

                HStack(alignment: .top, spacing: NwSpacing.md) {
                    companionMetric(
                        title: "Income",
                        amount: display.incomeHeadline
                    )

                    Divider()
                        .frame(height: 52)

                    companionMetric(
                        title: "Retained",
                        amount: display.retainedHeadline,
                        color: retainedColor(display.retainedHeadline)
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
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
    }

    private func companionMetric(
        title: String,
        amount: Money,
        color: Color = NwAppColors.textPrimary
    ) -> some View {
        VStack(alignment: .leading, spacing: NwSpacing.xs) {
            Text(title)
                .font(NwTypography.caption)
                .foregroundStyle(NwAppColors.textSecondary)
            NwAmountText(
                amount,
                variant: .large,
                showCents: false,
                color: color
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func retainedColor(_ amount: Money) -> Color {
        if amount.isNegative { return NwAppColors.liability }
        if amount > .zero { return NwAppColors.positive }
        return NwAppColors.textSecondary
    }

    /// Arithmetic mean of the latest 12 complete months. Every real expense
    /// remains represented, including lumpy purchases and timing shifts.
    private func averageMonthlySpend(_ model: SpendingHistoryModel) -> Money? {
        let completeMonths = model.months
            .filter { !isCurrentMonth($0.month) }
            .sorted { $0.month < $1.month }
            .suffix(12)
            .map(\.ordinaryTotal)
        return EmergencyFundMath.meanOfCompleteMonths(Array(completeMonths))
    }

    private func spendingComparison(
        for period: DisplayedPeriod,
        model: SpendingHistoryModel
    ) -> (label: String, amount: Money)? {
        if period.monthCount == 1 {
            return averageMonthlySpend(model).map { ("12-mo avg", $0) }
        }
        return (
            "Avg/mo",
            Money(
                milliunits: period.summary.ordinaryTotalMilliunits
                    / Int64(period.monthCount)
            )
        )
    }

    private func moveDisplayedMonth(
        in model: SpendingHistoryModel,
        by offset: Int
    ) {
        guard summaryRange == .oneMonth else { return }
        let selectableMonths = selectableMonths(in: model)
        guard let current = displayedMonth(model),
              let index = selectableMonths.firstIndex(where: {
                  $0.month == current.month
              }) else { return }
        let destination = index + offset
        guard selectableMonths.indices.contains(destination) else { return }
        selectedMonth = selectableMonths[destination].month
    }

    /// The selected period's out-of-pocket spending composition. A single
    /// month is sized against the trailing 12-month arithmetic mean; aggregate
    /// periods show composition only because their own monthly average is
    /// already displayed in the summary card.
    /// Each row opens its category detail. Non-spending groups (transfers,
    /// savings, investing, unassigned) use a hollow swatch because they sit
    /// outside the pie.
    private func spendingBreakdown(
        _ period: DisplayedPeriod,
        model: SpendingHistoryModel
    ) -> some View {
        let month = period.summary
        let groups = orderedGroups(in: month)
        let displayAmounts = month.wholeDollarDisplay.groupAmountsByID
        let currentTotal = Double(max(0, month.ordinaryTotalMilliunits))
        let referenceTotal = period.monthCount == 1
            ? averageMonthlySpend(model).map { Double($0.milliunits) }
            : nil
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
                    Text(
                        period.monthCount == 1
                            ? "No approved spending this month."
                            : "No approved spending in this period."
                    )
                        .font(NwTypography.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(NwSpacing.md)
                } else {
                    NestedSpendingPie(
                        slices: slices,
                        currentTotal: currentTotal,
                        referenceTotal: referenceTotal.map { max(0, $0) }
                    )
                    .frame(height: 200)
                    .frame(maxWidth: .infinity)
                    .padding(.top, NwSpacing.lg)
                    .padding(.bottom, NwSpacing.md)
                    .accessibilityLabel(
                        period.monthCount == 1
                            ? "Spending versus the 12 month average"
                            : "Spending composition for \(period.label)"
                    )
                    Divider().padding(.leading, NwSpacing.md)
                    ForEach(Array(groups.enumerated()), id: \.element.id) {
                        index, group in
                        legendRow(
                            group,
                            month: month,
                            periodStartMonth: period.startMonth,
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

    /// One full-row action beneath the pie: open this group's category and
    /// transaction detail. Trend selection lives in Spending Trends.
    @ViewBuilder
    private func legendRow(
        _ group: SpendingHistoryGroupTotal,
        month: SpendingHistoryMonth,
        periodStartMonth: Date,
        displayAmount: Money
    ) -> some View {
        if group.categories.isEmpty {
            legendRowContent(group, displayAmount: displayAmount)
        } else {
            Button {
                detailSelection = SpendingGroupDetailSelection(
                    month: month,
                    group: group,
                    periodStartMonth: periodStartMonth
                )
            } label: {
                legendRowContent(
                    group,
                    displayAmount: displayAmount,
                    showsDisclosure: true
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "Open \(group.name) details, \(CurrencyFormatter.currency(displayAmount))"
            )
        }
    }

    private func legendRowContent(
        _ group: SpendingHistoryGroupTotal,
        displayAmount: Money,
        showsDisclosure: Bool = false
    ) -> some View {
        HStack(spacing: NwSpacing.sm) {
            swatch(for: group, isSpending: group.isOrdinarySpending)
            Text(group.name)
                .font(NwTypography.body)
                .foregroundStyle(NwAppColors.textPrimary)
                .lineLimit(1)
            Spacer(minLength: NwSpacing.sm)
            legendAmount(group, amount: displayAmount)
            if showsDisclosure {
                NwIcon.chevron.image
                    .font(NwTypography.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, NwSpacing.md)
        .padding(.vertical, NwSpacing.rowVertical)
        .contentShape(Rectangle())
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

    private func color(for groupID: String) -> Color {
        guard let index = model?.paletteIndex(for: groupID) else {
            return NwAppColors.chartOther
        }
        return NwAppColors.chartCategorical[index]
    }

    private func spendingTrendPreview(
        _ model: SpendingHistoryModel
    ) -> some View {
        let data = spendingTrendData(
            model: model,
            monthCount: 12,
            seriesID: SpendingTrendSeries.all,
            calendar: calendar
        )
        return NavigationLink {
            SpendingTrendsView(model: model)
        } label: {
            NwCard(style: .primary) {
                VStack(alignment: .leading, spacing: NwSpacing.sm) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Spending Trends")
                                .font(NwTypography.headline)
                                .foregroundStyle(NwAppColors.textPrimary)
                            Text("Last 12 months")
                                .font(NwTypography.footnote)
                                .foregroundStyle(NwAppColors.textSecondary)
                        }
                        Spacer()
                        NwIcon.chevron.image
                            .font(NwTypography.footnote)
                            .foregroundStyle(.tertiary)
                    }

                    SpendingTrendChart(
                        data: data,
                        color: NwAppColors.primary,
                        compact: true,
                        axisStride: 3,
                        selectedMonth: nil
                    )
                    .frame(height: 110)
                    .allowsHitTesting(false)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows detailed monthly spending trends")
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
           !selectableMonths(in: built).contains(where: {
               $0.month == selectedMonth
           }) {
            self.selectedMonth = nil
        }
    }
}

// MARK: - Spending trends

private struct SpendingTrendGroupOption: Identifiable {
    let id: String
    let name: String
}

private struct SpendingTrendsView: View {
    let model: SpendingHistoryModel

    @State private var range = SpendingTrendRange.twentyFourMonths
    @State private var selectedSeriesID = SpendingTrendSeries.all
    @State private var selectedMonth: Date?
    @State private var detailSelection: SpendingGroupDetailSelection?

    private let calendar = Calendar.current

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NwSpacing.lg) {
                controlsCard
                chartCard
            }
            .padding(.horizontal, NwSpacing.screenPadding)
            .padding(.vertical, NwSpacing.lg)
        }
        .background(NwAppColors.background.ignoresSafeArea())
        .navigationTitle("Spending Trends")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $detailSelection) { selection in
            SpendingGroupDetailSheet(selection: selection)
        }
        .onChange(of: range) { _, _ in
            selectedMonth = nil
        }
        .onChange(of: selectedSeriesID) { _, _ in
            selectedMonth = nil
        }
    }

    private var controlsCard: some View {
        NwCard(style: .primary) {
            VStack(spacing: NwSpacing.md) {
                HStack {
                    Text("Series")
                        .font(NwTypography.body)
                        .foregroundStyle(NwAppColors.textSecondary)
                    Spacer()
                    Picker("Series", selection: $selectedSeriesID) {
                        Text("All Spending")
                            .tag(SpendingTrendSeries.all)
                        ForEach(groupOptions) { option in
                            Text(option.name).tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                Picker("History range", selection: $range) {
                    ForEach(SpendingTrendRange.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var chartCard: some View {
        NwCard(style: .primary) {
            VStack(alignment: .leading, spacing: NwSpacing.md) {
                if let datum = displayedDatum {
                    HStack(alignment: .firstTextBaseline) {
                        Text(monthLabel(for: datum))
                            .font(NwTypography.bodyEmphasis)
                            .foregroundStyle(NwAppColors.textSecondary)
                        Spacer()
                        NwAmountText(
                            datum.amount,
                            variant: .large,
                            showCents: false
                        )
                    }
                }

                SpendingTrendChart(
                    data: data,
                    color: seriesColor,
                    compact: false,
                    axisStride: range.axisStride,
                    selectedMonth: selectedMonth,
                    onSelect: selectMonth
                )
                .frame(height: 300)
                .accessibilityLabel("Monthly \(selectedSeriesName)")

                if let group = selectedGroup,
                   !group.categories.isEmpty,
                   let month = selectedHistoryMonth {
                    Button {
                        detailSelection = SpendingGroupDetailSelection(
                            month: month,
                            group: group
                        )
                    } label: {
                        HStack {
                            Text("View \(group.name) details")
                                .font(NwTypography.bodyEmphasis)
                            Spacer()
                            NwIcon.chevron.image
                                .font(NwTypography.footnote)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(NwAppColors.primary)
                }

                Text("The current month is month to date.")
                    .font(NwTypography.caption)
                    .foregroundStyle(NwAppColors.textSecondary)
            }
        }
    }

    private var data: [SpendingTrendDatum] {
        spendingTrendData(
            model: model,
            monthCount: range.rawValue,
            seriesID: selectedSeriesID,
            calendar: calendar
        )
    }

    private var displayedDatum: SpendingTrendDatum? {
        guard let selectedMonth else { return data.last }
        return data.first { $0.month == selectedMonth } ?? data.last
    }

    private var selectedHistoryMonth: SpendingHistoryMonth? {
        guard let selectedMonth else { return nil }
        return model.months.first { $0.month == selectedMonth }
    }

    private var selectedGroup: SpendingHistoryGroupTotal? {
        guard selectedSeriesID != SpendingTrendSeries.all else { return nil }
        return selectedHistoryMonth?.groups.first {
            $0.id == selectedSeriesID
        }
    }

    private var selectedSeriesName: String {
        guard selectedSeriesID != SpendingTrendSeries.all else {
            return "All Spending"
        }
        return groupOptions.first { $0.id == selectedSeriesID }?.name
            ?? "Spending"
    }

    private var seriesColor: Color {
        guard selectedSeriesID != SpendingTrendSeries.all else {
            return NwAppColors.primary
        }
        guard let index = model.paletteIndex(for: selectedSeriesID) else {
            return NwAppColors.chartOther
        }
        return NwAppColors.chartCategorical[index]
    }

    private var groupOptions: [SpendingTrendGroupOption] {
        var byID: [String: SpendingTrendGroupOption] = [:]
        for month in model.months.reversed() {
            for group in month.groups where byID[group.id] == nil {
                byID[group.id] = SpendingTrendGroupOption(
                    id: group.id,
                    name: group.name
                )
            }
        }
        return byID.values.sorted { lhs, rhs in
            let lhsOrder = model.orderIndex(for: lhs.id)
            let rhsOrder = model.orderIndex(for: rhs.id)
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                == .orderedAscending
        }
    }

    private func selectMonth(_ date: Date) {
        guard let nearest = data.min(by: {
            abs($0.month.timeIntervalSince(date))
                < abs($1.month.timeIntervalSince(date))
        }) else { return }
        selectedMonth = nearest.month
    }

    private func monthLabel(for datum: SpendingTrendDatum) -> String {
        let month = datum.month.formatted(.dateTime.month(.wide).year())
        return datum.isPartial ? "\(month) · MTD" : month
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

/// Spending composition for the selected period. A single month is nested
/// inside a gray disc representing the trailing 12-month arithmetic mean;
/// aggregate periods omit that benchmark and use the full available area.
private struct NestedSpendingPie: View {
    let slices: [SpendingSlice]
    let currentTotal: Double
    let referenceTotal: Double?

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            guard side > 0 else { return }
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let frameR = side / 2
            let maxVal = max(currentTotal, referenceTotal ?? 0, 1)
            let currentR = frameR * (currentTotal / maxVal).squareRoot()

            if let referenceTotal {
                let referenceR = frameR
                    * (referenceTotal / maxVal).squareRoot()
                // Gray disc: trailing 12-month average spending.
                context.fill(
                    disc(center: center, radius: referenceR),
                    with: .color(NwAppColors.chartOther.opacity(0.16))
                )

                // Dashed ring: the average level, always visible.
                if referenceR > 0 {
                    context.stroke(
                        disc(center: center, radius: referenceR),
                        with: .color(NwAppColors.chartOther.opacity(0.7)),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
                }
            }

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
    let periodStartMonth: Date

    init(
        month: SpendingHistoryMonth,
        group: SpendingHistoryGroupTotal,
        periodStartMonth: Date? = nil
    ) {
        self.month = month
        self.group = group
        self.periodStartMonth = periodStartMonth ?? month.month
    }

    var id: String {
        "\(periodStartMonth.timeIntervalSince1970):\(month.month.timeIntervalSince1970):\(group.id)"
    }

    var periodLabel: String {
        SpendingPeriodFormatter.label(
            from: periodStartMonth,
            through: month.month
        )
    }
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

/// Period/group drill-down: categories retain the selected period's totals and
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
                                periodLabel: selection.periodLabel,
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
                "\(selection.group.name) · \(selection.periodLabel)"
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
    let periodLabel: String
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

            Section(periodLabel) {
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
