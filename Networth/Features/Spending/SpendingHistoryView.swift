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
    case threeMonths = 3
    case sixMonths = 6
    case twelveMonths = 12
    case twentyFourMonths = 24

    var id: Int { rawValue }
    var label: String { "\(rawValue) mo" }
    var axisStride: Int {
        switch self {
        case .threeMonths: return 1
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

enum SpendingBudgetVisibility {
    static func visibleBudgets(
        _ budgets: [SpendingGroupBudgetSnapshot],
        featuredGroupID: String?,
        expanded: Bool
    ) -> [SpendingGroupBudgetSnapshot] {
        guard !expanded, budgets.count > 3 else { return budgets }
        guard let featuredGroupID,
              let featured = budgets.first(where: {
                  $0.groupIdentity == featuredGroupID
              }),
              !budgets.prefix(3).contains(where: {
                  $0.groupIdentity == featuredGroupID
              }) else {
            return Array(budgets.prefix(3))
        }
        return Array(budgets.prefix(2)) + [featured]
    }
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

    private struct DisplayedPeriod {
        let months: [SpendingHistoryMonth]
        let summary: SpendingHistoryMonth

        var startMonth: Date { months[0].month }
    }

    @State private var model: SpendingHistoryModel?
    @State private var selectedMonth: Date?
    @State private var detailSelection: SpendingGroupDetailSelection?
    @State private var showingGroupedReview = false
    @State private var showingIndividualReview = false
    @State private var showingGroupManager = false
    @State private var showingAllBudgets = false
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
                        if let period = displayedPeriod(model) {
                            monthOverviewCard(period, model: model)
                            budgetBreakdown(period, model: model)
                        }
                        spendingDetailLinks(model)
                    } else {
                        NwLoadingState("Loading spending…")
                            .frame(maxWidth: .infinity, minHeight: 240)
                    }
                }
                .padding(.horizontal, NwSpacing.screenPadding)
                .padding(.vertical, NwSpacing.md)
            }
            .background(NwAppColors.background.ignoresSafeArea())
            .navigationTitle("Spending")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let model {
                        monthMenu(model)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NwTopLevelMenu(
                        canRefresh: container.hasPlaidBackendToken,
                        contextualActions: [
                            NwTopLevelMenuAction(
                                title: "Groups & Budgets",
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
        .onChange(of: selectedMonth) { _, _ in
            showingAllBudgets = false
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
        guard let month = displayedMonth(model) else { return nil }
        return DisplayedPeriod(months: [month], summary: month)
    }

    private func monthMenu(_ model: SpendingHistoryModel) -> some View {
        let current = displayedMonth(model)
        return Menu {
            ForEach(selectableMonths(in: model).reversed()) { month in
                Button {
                    selectedMonth = month.month
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
                        .dateTime.month(.abbreviated).year()
                    ) ?? "Select Month"
                )
                .font(NwTypography.bodyEmphasis)
                .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(NwTypography.caption)
            }
            .foregroundStyle(NwAppColors.textPrimary)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Spending month")
        .accessibilityHint("Selects the month to review")
    }

    private func isCurrentMonth(_ month: Date?) -> Bool {
        guard let month else { return false }
        return calendar.isDate(month, equalTo: .now, toGranularity: .month)
    }

    // MARK: - Selected month

    private func monthOverviewCard(
        _ period: DisplayedPeriod,
        model: SpendingHistoryModel
    ) -> some View {
        let month = period.summary
        let display = month.fundingDisplay(
            fundedBy: SpendingHistoryBuilder.fundingIncome(
                for: month,
                within: model.months,
                calendar: calendar
            )
        )
        let budget = model.budgetSummary(for: month)
        return VStack(spacing: NwSpacing.md) {
            if budget.groups.isEmpty {
                noBudgetHero(display, month: month.month)
            } else {
                spendingBudgetHero(budget, month: month.month)
            }
            retainedStrip(display)
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

    private func noBudgetHero(
        _ display: SpendingHistoryFundingDisplay,
        month: Date
    ) -> some View {
        NwDashboardHero {
            VStack(alignment: .leading, spacing: NwSpacing.lg) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isCurrentMonth(month) ? "SPENT THIS MONTH" : "SPENT")
                        .font(NwTypography.caption)
                        .foregroundStyle(NwAppColors.dashboardHeroSecondary)
                    NwAmountText(
                        display.ordinaryHeadline,
                        variant: .hero,
                        showCents: false,
                        color: NwAppColors.dashboardHeroText
                    )
                }

                Button {
                    showingGroupManager = true
                } label: {
                    HStack(spacing: NwSpacing.sm) {
                        NwIcon.add.image
                        Text("Set Up Budgets")
                    }
                    .font(NwTypography.bodyEmphasis)
                    .foregroundStyle(NwAppColors.dashboardHeroSurface)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(
                        RoundedRectangle(
                            cornerRadius: NwCornerRadius.md,
                            style: .continuous
                        )
                        .fill(NwAppColors.gold)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func spendingBudgetHero(
        _ budget: SpendingBudgetSummary,
        month: Date
    ) -> some View {
        let displayedProgress = min(max(budget.progress, 0), 1)
        let pace = budgetPaceStatus(progress: budget.progress, month: month)
        return NwDashboardHero {
            VStack(alignment: .leading, spacing: NwSpacing.lg) {
                HStack(alignment: .center, spacing: NwSpacing.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MONTHLY BUDGET")
                            .font(NwTypography.caption)
                            .foregroundStyle(
                                NwAppColors.dashboardHeroSecondary
                            )
                        NwAmountText(
                            budget.remaining.absolute,
                            variant: .hero,
                            showCents: false,
                            color: budget.isOver
                                ? NwAppColors.dashboardHeroOver
                                : NwAppColors.dashboardHeroText
                        )
                    }
                    Spacer(minLength: NwSpacing.sm)
                    spendingBudgetArc(
                        progress: displayedProgress,
                        isOver: budget.isOver
                    )
                }

                if let days = daysLeft(in: month) {
                    Text("\(days) day\(days == 1 ? "" : "s")")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .font(NwTypography.footnoteEm)
                        .foregroundStyle(
                            NwAppColors.dashboardHeroSecondary
                        )
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Monthly budget")
        .accessibilityValue(
            "\(budgetStatusText(budget.remaining)), "
                + "\(budgetPaceLabel(pace, month: month)), "
                + "\(budgetAmountProgressText(spent: budget.spent, target: budget.target))"
        )
    }

    private func spendingBudgetArc(
        progress: Double,
        isOver: Bool
    ) -> some View {
        ZStack {
            Circle()
                .trim(from: 0.125, to: 0.875)
                .stroke(
                    NwAppColors.dashboardHeroTrack,
                    style: StrokeStyle(lineWidth: 12, lineCap: .round)
                )
                .rotationEffect(.degrees(90))
            Circle()
                .trim(from: 0.125, to: 0.125 + (0.75 * progress))
                .stroke(
                    isOver
                        ? NwAppColors.dashboardHeroOver
                        : NwAppColors.dashboardHeroProgress,
                    style: StrokeStyle(lineWidth: 12, lineCap: .round)
                )
                .rotationEffect(.degrees(90))
        }
        .frame(width: 118, height: 118)
        .accessibilityHidden(true)
    }

    private func budgetPaceStatus(
        progress: Double,
        month: Date
    ) -> SpendingBudgetPaceStatus {
        SpendingBudgetPaceEvaluator().status(
            progress: progress,
            month: BudgetMonth(containing: month, calendar: calendar),
            now: .now,
            calendar: calendar
        )
    }

    private func budgetPaceLabel(
        _ pace: SpendingBudgetPaceStatus,
        month: Date
    ) -> String {
        if !isCurrentMonth(month) {
            return pace == .atRisk ? "Over budget" : "Within budget"
        }
        switch pace {
        case .onTrack: return "On track"
        case .watch: return "Watch"
        case .atRisk: return "At risk"
        }
    }

    private func budgetProgressColor(
        isOver: Bool
    ) -> Color {
        isOver ? NwAppColors.budgetOver : NwAppColors.primary
    }

    private func retainedStrip(
        _ display: SpendingHistoryFundingDisplay
    ) -> some View {
        NwCard(style: .secondary) {
            VStack(spacing: NwSpacing.md) {
                HStack(alignment: .firstTextBaseline, spacing: NwSpacing.md) {
                    fundingMetric(
                        title: "Funded",
                        amount: display.fundedHeadline,
                        color: NwAppColors.primary,
                        alignment: .leading
                    )
                    Spacer(minLength: NwSpacing.md)
                    fundingMetric(
                        title: "Retained",
                        amount: display.remainingHeadline,
                        color: retainedColor(display.remainingHeadline),
                        alignment: .trailing
                    )
                }
                retainedBar(display)
            }
        }
    }

    private func fundingMetric(
        title: String,
        amount: Money?,
        color: Color = NwAppColors.textPrimary,
        alignment: HorizontalAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(title)
                .font(NwTypography.caption)
                .foregroundStyle(NwAppColors.textSecondary)
            if let amount {
                NwAmountText(
                    amount,
                    variant: .compact,
                    showCents: false,
                    color: color
                )
            } else {
                Text("—")
                    .font(NwTypography.headline)
                    .foregroundStyle(NwAppColors.textSecondary)
            }
        }
    }

    @ViewBuilder
    private func retainedBar(
        _ display: SpendingHistoryFundingDisplay
    ) -> some View {
        if let funded = display.fundedHeadline, funded > .zero {
            let spentShare = min(
                max(display.ordinaryHeadline.doubleValue / funded.doubleValue, 0),
                1
            )
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(NwAppColors.favorableFill)
                    Capsule()
                        .fill(
                            display.remainingHeadline?.isNegative == true
                                ? NwAppColors.budgetOver
                                : NwAppColors.primary
                        )
                        .frame(width: proxy.size.width * spentShare)
                }
            }
            .frame(height: 8)
            .accessibilityElement()
            .accessibilityLabel("Funding use")
            .accessibilityValue(
                "\(CurrencyFormatter.currency(display.ordinaryHeadline, showCents: false)) spent, "
                    + "\(display.remainingHeadline.map { CurrencyFormatter.currency($0, showCents: false) } ?? "unknown") retained"
            )
        } else {
            Capsule()
                .fill(NwAppColors.strokeSubtle)
                .frame(height: 8)
                .accessibilityHidden(true)
        }
    }

    private func budgetStatusText(_ remaining: Money) -> String {
        if remaining.isNegative {
            return "\(CurrencyFormatter.currency(remaining.absolute, showCents: false)) over"
        }
        return "\(CurrencyFormatter.currency(remaining, showCents: false)) left"
    }

    private func daysLeft(in month: Date) -> Int? {
        guard isCurrentMonth(month),
              let days = calendar.range(of: .day, in: .month, for: month)
        else { return nil }
        let today = calendar.component(.day, from: .now)
        return max(0, days.count - today)
    }

    private func retainedColor(_ amount: Money?) -> Color {
        guard let amount else { return NwAppColors.textSecondary }
        if amount.isNegative { return NwAppColors.budgetOver }
        if amount > .zero { return NwAppColors.favorableText }
        return NwAppColors.textSecondary
    }

    private func moveDisplayedMonth(
        in model: SpendingHistoryModel,
        by offset: Int
    ) {
        let selectableMonths = selectableMonths(in: model)
        guard let current = displayedMonth(model),
              let index = selectableMonths.firstIndex(where: {
                  $0.month == current.month
              }) else { return }
        let destination = index + offset
        guard selectableMonths.indices.contains(destination) else { return }
        selectedMonth = selectableMonths[destination].month
    }

    /// The selected month's active group budgets. The featured group stays in
    /// the same visual list so every budget exposes the same useful detail.
    @ViewBuilder
    private func budgetBreakdown(
        _ period: DisplayedPeriod,
        model: SpendingHistoryModel
    ) -> some View {
        let month = period.summary
        let budgets = model.budgetSummary(for: month).groups
        let visibleBudgets = SpendingBudgetVisibility.visibleBudgets(
            budgets,
            featuredGroupID: model.focusGroupIdentity,
            expanded: showingAllBudgets
        )
        if !budgets.isEmpty {
            VStack(alignment: .leading, spacing: NwSpacing.sm) {
                HStack {
                    Text("Budgets")
                        .font(NwTypography.caption)
                        .foregroundStyle(NwAppColors.textSecondary)
                        .textCase(.uppercase)
                }
                .padding(.horizontal, NwSpacing.xs)

                VStack(spacing: NwSpacing.xs) {
                    ForEach(visibleBudgets) { budget in
                        budgetRow(
                            budget,
                            month: month,
                            periodStartMonth: period.startMonth
                        )
                    }

                    if budgets.count > 3 {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showingAllBudgets.toggle()
                            }
                        } label: {
                            HStack {
                                Text(
                                    showingAllBudgets
                                        ? "Show fewer"
                                        : "Show all \(budgets.count)"
                                )
                                Spacer()
                                Image(
                                    systemName: showingAllBudgets
                                        ? "chevron.up"
                                        : "chevron.down"
                                )
                            }
                            .font(NwTypography.bodyEmphasis)
                            .foregroundStyle(NwAppColors.primary)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .padding(.horizontal, NwSpacing.md)
                            .background(
                                RoundedRectangle(
                                    cornerRadius: NwCornerRadius.md,
                                    style: .continuous
                                )
                                .fill(NwAppColors.cardSurface)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text("Half-width comparison")
                    .font(NwTypography.caption)
                    .foregroundStyle(NwAppColors.textSecondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, NwSpacing.xs)
                    .padding(.top, NwSpacing.sm)

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: NwSpacing.sm),
                        GridItem(.flexible(), spacing: NwSpacing.sm)
                    ],
                    spacing: NwSpacing.sm
                ) {
                    ForEach(visibleBudgets) { budget in
                        halfWidthBudgetCard(
                            budget,
                            month: month,
                            periodStartMonth: period.startMonth
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func budgetRow(
        _ budget: SpendingGroupBudgetSnapshot,
        month: SpendingHistoryMonth,
        periodStartMonth: Date
    ) -> some View {
        let group = month.groups.first { $0.id == budget.groupIdentity }
        let pace = budgetPaceStatus(
            progress: budget.progress,
            month: month.month
        )
        Button {
            guard let group else { return }
            detailSelection = SpendingGroupDetailSelection(
                month: month,
                group: group,
                periodStartMonth: periodStartMonth
            )
        } label: {
            budgetRowContent(budget)
        }
        .buttonStyle(.plain)
        .disabled(group == nil)
        .accessibilityLabel(
            "Open \(budget.groupName) details, "
                + "\(budgetStatusText(budget.remaining)), "
                + "\(budgetPaceLabel(pace, month: month.month)), "
                + "\(budgetAmountProgressText(spent: budget.spent, target: budget.target))"
        )
        .accessibilityHint("Shows categories and transactions")
    }

    private func budgetRowContent(
        _ budget: SpendingGroupBudgetSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: NwSpacing.sm) {
                Text(budget.groupName)
                    .font(NwTypography.bodyEmphasis)
                    .foregroundStyle(NwAppColors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: NwSpacing.sm)
                Text(budgetDisplayAmount(budget.remaining))
                    .font(NwTypography.bodyEmphasis)
                    .foregroundStyle(
                        budget.isOver
                            ? NwAppColors.budgetOver
                            : NwAppColors.primary
                    )
                    .monospacedDigit()
            }

            NwBudgetProgress(
                progress: budget.progress,
                isOver: budget.isOver,
                tint: budgetProgressColor(isOver: budget.isOver),
                height: 6,
                accessibilityLabel: "\(budget.groupName) budget progress"
            )
        }
        .padding(.horizontal, NwSpacing.md)
        .padding(.vertical, NwSpacing.xs)
        .frame(minHeight: 44)
        .background(
            RoundedRectangle(
                cornerRadius: NwCornerRadius.card,
                style: .continuous
            )
            .fill(NwAppColors.cardSurface)
        )
        .nwShadow(NwShadow.card)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func halfWidthBudgetCard(
        _ budget: SpendingGroupBudgetSnapshot,
        month: SpendingHistoryMonth,
        periodStartMonth: Date
    ) -> some View {
        let group = month.groups.first { $0.id == budget.groupIdentity }
        let pace = budgetPaceStatus(
            progress: budget.progress,
            month: month.month
        )
        Button {
            guard let group else { return }
            detailSelection = SpendingGroupDetailSelection(
                month: month,
                group: group,
                periodStartMonth: periodStartMonth
            )
        } label: {
            VStack(alignment: .leading, spacing: NwSpacing.sm) {
                Text(budget.groupName)
                    .font(NwTypography.footnoteEm)
                    .foregroundStyle(NwAppColors.textPrimary)
                    .lineLimit(1)

                Text(budgetDisplayAmount(budget.remaining))
                    .font(NwTypography.headline)
                    .foregroundStyle(
                        budget.isOver
                            ? NwAppColors.budgetOver
                            : NwAppColors.primary
                    )
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                NwBudgetProgress(
                    progress: budget.progress,
                    isOver: budget.isOver,
                    tint: budgetProgressColor(isOver: budget.isOver),
                    height: 6,
                    accessibilityLabel: "\(budget.groupName) budget progress"
                )
            }
            .padding(NwSpacing.md)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            .background(
                RoundedRectangle(
                    cornerRadius: NwCornerRadius.card,
                    style: .continuous
                )
                .fill(NwAppColors.cardSurface)
            )
            .nwShadow(NwShadow.card)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(group == nil)
        .accessibilityLabel(
            "Open \(budget.groupName) details, "
                + "\(budgetStatusText(budget.remaining)), "
                + "\(budgetPaceLabel(pace, month: month.month)), "
                + "\(budgetAmountProgressText(spent: budget.spent, target: budget.target))"
        )
        .accessibilityHint("Shows categories and transactions")
    }

    private func budgetAmountProgressText(
        spent: Money,
        target: Money
    ) -> String {
        "\(CurrencyFormatter.currency(spent, showCents: false)) of "
            + CurrencyFormatter.currency(target, showCents: false)
    }

    private func budgetDisplayAmount(_ remaining: Money) -> String {
        CurrencyFormatter.currency(remaining.absolute, showCents: false)
    }

    private func spendingDetailLinks(
        _ model: SpendingHistoryModel
    ) -> some View {
        NwCard(style: .primary, padding: 0) {
            HStack(spacing: 0) {
                NavigationLink {
                    SpendingTrendsView(model: model)
                } label: {
                    spendingDetailAction(
                        icon: .netWorth,
                        title: "Trends"
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows detailed monthly spending trends")

                Divider().frame(height: 36)

                NavigationLink {
                    FinancialAccountTransactionHistoryView()
                } label: {
                    spendingDetailAction(
                        icon: .history,
                        title: "Transactions"
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows all transactions")
            }
        }
    }

    private func spendingDetailAction(
        icon: NwIcon,
        title: String
    ) -> some View {
        HStack(spacing: NwSpacing.sm) {
            icon.image
                .font(NwTypography.headline)
            Text(title)
                .font(NwTypography.bodyEmphasis)
                .lineLimit(1)
        }
        .foregroundStyle(NwAppColors.primary)
        .frame(maxWidth: .infinity, minHeight: 56)
        .contentShape(Rectangle())
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
                        VStack(alignment: .leading, spacing: 2) {
                            Text(monthLabel(for: datum))
                                .font(NwTypography.caption)
                                .foregroundStyle(NwAppColors.textSecondary)
                            NwAmountText(
                                datum.amount,
                                variant: .large,
                                showCents: false
                            )
                        }
                        Spacer()
                        if let average = historicalAverage {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("12-mo average")
                                    .font(NwTypography.caption)
                                    .foregroundStyle(NwAppColors.textSecondary)
                                NwAmountText(
                                    average,
                                    variant: .large,
                                    showCents: false,
                                    color: NwAppColors.textSecondary
                                )
                            }
                        }
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

    private var historicalAverage: Money? {
        let amounts = spendingTrendData(
            model: model,
            monthCount: 24,
            seriesID: selectedSeriesID,
            calendar: calendar
        )
        .filter { !$0.isPartial }
        .suffix(12)
        .map(\.amount)
        return EmergencyFundMath.meanOfCompleteMonths(Array(amounts))
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
    let budgetTarget: Money?
    let isBudgetFocus: Bool

    init(
        identity: String,
        name: String,
        displayOrder: Int,
        budgetTarget: Money? = nil,
        isBudgetFocus: Bool = false
    ) {
        self.identity = identity
        self.name = name
        self.displayOrder = displayOrder
        self.budgetTarget = budgetTarget
        self.isBudgetFocus = isBudgetFocus
    }

    var id: String { identity }

    var subtitle: String {
        guard let budgetTarget else { return "No budget" }
        let amount = CurrencyFormatter.currency(
            budgetTarget,
            showCents: false
        )
        return "\(amount) monthly"
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
    @Query private var budgetRows: [DurableSpendingGroupBudgetRule]

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
                        title: Text("Couldn’t Save Changes"),
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
            let rule = SpendingGroupBudgetResolver().activeRule(
                for: identity,
                month: BudgetMonth(containing: .now),
                rules: budgetRows.map(\.coreRule)
            )
            return ManagedSpendingGroup(
                identity: identity,
                name: latest.name,
                displayOrder: latest.displayOrder,
                budgetTarget: rule?.enabled == true ? rule?.target : nil,
                isBudgetFocus: latest.isBudgetFocus
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
        HStack(spacing: NwSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                    .foregroundStyle(NwAppColors.textPrimary)
                Text(group.subtitle)
                    .font(NwTypography.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: NwSpacing.sm)
            if group.isBudgetFocus {
                Image(systemName: "pin.fill")
                    .foregroundStyle(NwAppColors.primary)
                    .accessibilityLabel("Pinned")
            }
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
            if group.budgetTarget != nil {
                Button {
                    toggleBudgetPin(group)
                } label: {
                    Label(
                        group.isBudgetFocus ? "Unpin" : "Pin",
                        systemImage: group.isBudgetFocus
                            ? "pin.slash"
                            : "pin.fill"
                    )
                }
                .tint(NwAppColors.primary)
            }
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

    private func toggleBudgetPin(_ group: ManagedSpendingGroup) {
        let shouldPin = !group.isBudgetFocus
        let now = Date.now
        for row in groupRows where SpendingGroupSetup.isUserGroup(row) {
            if row.groupIdentity == group.identity {
                row.isBudgetFocus = shouldPin
                row.updatedAt = now
            } else if shouldPin && row.isBudgetFocus {
                row.isBudgetFocus = false
                row.updatedAt = now
            }
        }
        guard container.modelContainer.mainContext.safeSave(
            source: "spending.groupBudget.pin"
        ) else {
            activeAlert = .error("Your pinned group wasn’t saved.")
            return
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
    @Query private var budgetRows: [DurableSpendingGroupBudgetRule]
    let group: ManagedSpendingGroup

    @State private var categoryToMove: ManagedSpendingCategory?
    @State private var isSelecting = false
    @State private var selectedCategoryIDs: Set<String> = []
    @State private var showingBudgetEditor = false
    @State private var persistenceError: String?

    var body: some View {
        List {
            if !isUnassignedList {
                Section {
                    Toggle(
                        "Include in Budget",
                        isOn: Binding(
                            get: { activeBudgetRule?.enabled == true },
                            set: { enabled in
                                setBudgetEnabled(enabled)
                            }
                        )
                    )

                    if let rule = activeBudgetRule, rule.enabled {
                        Button {
                            showingBudgetEditor = true
                        } label: {
                            HStack {
                                Text("Monthly Budget")
                                    .foregroundStyle(NwAppColors.textPrimary)
                                Spacer()
                                Text(
                                    CurrencyFormatter.currency(
                                        rule.target,
                                        showCents: false
                                    )
                                )
                                .foregroundStyle(NwAppColors.textSecondary)
                            }
                        }
                    }
                } header: {
                    Text("Budget")
                }
            }

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
        .alert(
            "Couldn’t Save Budget",
            isPresented: Binding(
                get: { persistenceError != nil },
                set: { if !$0 { persistenceError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { persistenceError = nil }
        } message: {
            Text(persistenceError ?? "Please try again.")
        }
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
        .sheet(isPresented: $showingBudgetEditor) {
            SpendingGroupBudgetEditorSheet(
                groupName: group.name,
                initialTarget: activeBudgetRule?.target,
                onSave: saveBudget
            )
        }
    }

    private var currentBudgetMonth: BudgetMonth {
        BudgetMonth(containing: .now)
    }

    private var activeBudgetRule: SpendingGroupBudgetRule? {
        SpendingGroupBudgetResolver().activeRule(
            for: group.identity,
            month: currentBudgetMonth,
            rules: budgetRows.map(\.coreRule)
        )
    }

    private var isBudgetFocus: Bool {
        groupRows
            .filter { $0.groupIdentity == group.identity }
            .max(by: { $0.updatedAt < $1.updatedAt })?
            .isBudgetFocus == true
    }

    private func setBudgetEnabled(_ enabled: Bool) {
        if enabled {
            showingBudgetEditor = true
        } else {
            let saved = writeBudgetRule(
                target: activeBudgetRule?.target ?? .zero,
                enabled: false
            )
            if saved && isBudgetFocus {
                setBudgetFocus(false)
            }
        }
    }

    private func saveBudget(_ target: Money) -> Bool {
        writeBudgetRule(target: target, enabled: true)
    }

    @discardableResult
    private func writeBudgetRule(target: Money, enabled: Bool) -> Bool {
        let current = currentBudgetMonth
        let matches = budgetRows.filter {
            $0.groupIdentity == group.identity
                && $0.effectiveYear == current.year
                && $0.effectiveMonth == current.month
        }
        if matches.isEmpty {
            container.modelContainer.mainContext.insert(
                DurableSpendingGroupBudgetRule(
                    groupIdentity: group.identity,
                    effectiveYear: current.year,
                    effectiveMonth: current.month,
                    targetMilliunits: target.milliunits,
                    enabled: enabled
                )
            )
        } else {
            for row in matches {
                row.targetMilliunits = target.milliunits
                row.enabled = enabled
                row.updatedAt = .now
            }
        }
        guard container.modelContainer.mainContext.safeSave(
            source: "spending.groupBudget.save"
        ) else {
            persistenceError = "Your budget change wasn’t saved."
            return false
        }
        return true
    }

    private func setBudgetFocus(_ focused: Bool) {
        let now = Date.now
        for row in groupRows where SpendingGroupSetup.isUserGroup(row) {
            if row.groupIdentity == group.identity {
                row.isBudgetFocus = focused
                row.updatedAt = now
            } else if focused && row.isBudgetFocus {
                row.isBudgetFocus = false
                row.updatedAt = now
            }
        }
        guard container.modelContainer.mainContext.safeSave(
            source: "spending.groupBudget.focus"
        ) else {
            persistenceError = "Your featured group wasn’t saved."
            return
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

private struct SpendingGroupBudgetEditorSheet: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss

    let groupName: String
    let onSave: (Money) -> Bool

    @State private var amountText: String

    init(
        groupName: String,
        initialTarget: Money?,
        onSave: @escaping (Money) -> Bool
    ) {
        self.groupName = groupName
        self.onSave = onSave
        _amountText = State(
            initialValue: initialTarget.map(CurrencyInputFormatter.text(for:))
                ?? ""
        )
    }

    var body: some View {
        NwModalLayout(
            title: "\(groupName) Budget",
            onClose: { dismiss() },
            onConfirm: save,
            confirmDisabled: target == nil
        ) {
            NwCard(style: .primary) {
                HStack(spacing: NwSpacing.md) {
                    Text("Monthly budget")
                    Spacer()
                    TextField("0.00", text: $amountText)
                        .multilineTextAlignment(.trailing)
                        .nwCurrencyInput(text: $amountText)
                    .frame(width: 140, height: 44)
                }
            }
        }
    }

    private var target: Money? {
        guard let amount = CurrencyInputFormatter.money(from: amountText),
              amount > .zero else { return nil }
        return amount
    }

    private func save() {
        guard let target, onSave(target) else { return }
        dismiss()
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

struct SpendingHistoryModel: Sendable {
    let months: [SpendingHistoryMonth]
    let budgetRules: [SpendingGroupBudgetRule]
    let focusGroupIdentity: String?
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

    func budgetSummary(for month: SpendingHistoryMonth) -> SpendingBudgetSummary {
        SpendingGroupBudgetResolver().summary(
            for: BudgetMonth(containing: month.month),
            groups: month.groups,
            rules: budgetRules,
            orderIndex: orderIndex(for:)
        )
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
        let budgetRows = try modelContext.fetch(
            FetchDescriptor<DurableSpendingGroupBudgetRule>()
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
        let latestGroups = Dictionary(grouping: groups, by: \.groupIdentity)
            .compactMapValues { rows in
                rows.max(by: { $0.updatedAt < $1.updatedAt })
            }
        let focusIdentity = latestGroups.values
            .filter { $0.isBudgetFocus && SpendingGroupSetup.isUserGroup($0) }
            .max(by: { $0.updatedAt < $1.updatedAt })?
            .groupIdentity
        return SpendingHistoryModel(
            months: months,
            budgetRules: budgetRows.map(\.coreRule),
            focusGroupIdentity: focusIdentity,
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
