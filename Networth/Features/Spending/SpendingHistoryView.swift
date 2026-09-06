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
/// Month navigation, the selected month's total and per-group columns, and a
/// compact link to the dedicated Spending Trends detail. Posted transactions
/// awaiting approval are surfaced inside the stable monthly hero. Only
/// approved activity counts; the current month is month-to-date, completed
/// months are final.
struct SpendingHistoryView: View {
    private enum OverviewSection: String, CaseIterable, Identifiable {
        case plan
        case future

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    @SwiftUI.Environment(AppContainerController.self) private var container
    @Query(sort: \CachedFinancialAccount.name)
    private var financialAccounts: [CachedFinancialAccount]
    @Query private var spendingAccountPins: [DurableSpendingAccountPin]
    @Query private var accountNicknames: [DurableAccountNickname]

    private struct DisplayedPeriod {
        let months: [SpendingHistoryMonth]
        let summary: SpendingHistoryMonth

        var startMonth: Date { months[0].month }
    }

    @State private var model: SpendingHistoryModel?
    @State private var selectedMonth: Date?
    @State private var detailSelection: SpendingGroupDetailSelection?
    @State private var savingsBucketSelection: SavingsBucketSelection?
    @State private var savingsTransferPromptSelection:
        SavingsTransferPromptSelection?
    @State private var showingSinkingFunds = false
    @State private var showingIndividualReview = false
    @State private var showingGroupManager = false
    @State private var rebuildTask: Task<Void, Never>?
    @State private var overviewSection: OverviewSection = .plan

    private let calendar = Calendar.current
    private let visibleMonthCount = 24
    private let reviewRequestID: Int

    init(reviewRequestID: Int = 0) {
        self.reviewRequestID = reviewRequestID
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NwSpacing.lg) {
                    if let model {
                        if let period = displayedPeriod(model) {
                            monthOverviewCard(period, model: model)
                            spendingAccountsSection
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
        }
        .task {
            await rebuild()
        }
        .task(id: reviewRequestID) {
            if reviewRequestID > 0 {
                showingIndividualReview = true
            }
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
        .sheet(item: $savingsBucketSelection) { selection in
            SavingsBucketDetailSheet(selection: selection)
                .environment(container)
        }
        .sheet(item: $savingsTransferPromptSelection) { selection in
            SavingsTransferPromptDetailSheet(selection: selection)
        }
        .sheet(isPresented: $showingIndividualReview) {
            PlaidClassificationReviewSheet().environment(container)
        }
        .sheet(isPresented: $showingGroupManager) {
            SpendingGroupManagementSheet().environment(container)
        }
        .sheet(
            isPresented: $showingSinkingFunds,
            onDismiss: scheduleRebuild
        ) {
            SpendingSinkingFundsSheet(
                month: reserveMonth(in: model),
                sourceBudgetsByMonth: reserveSourceBudgetsByMonth(in: model)
            )
            .environment(container)
        }
    }

    // MARK: - Transaction review

    private var pendingReviewCount: Int {
        container.plaidTransactionSyncCoordinator.pendingTransactionReviewCount
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
            HStack(spacing: NwSpacing.sm) {
                Text(
                    current?.month.formatted(
                        .dateTime.month(.wide).year()
                    ) ?? "Select Month"
                )
                .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(NwTypography.micro)
                    .foregroundStyle(NwAppColors.dashboardHeroSecondary)
            }
            .font(NwTypography.footnoteEm)
            .foregroundStyle(NwAppColors.dashboardHeroText)
            .padding(.horizontal, NwSpacing.md)
            .frame(height: 32)
            .background(
                Capsule()
                    .fill(NwAppColors.dashboardHeroTrack)
            )
            .overlay {
                Capsule()
                    .stroke(
                        NwAppColors.dashboardHeroSecondary.opacity(0.35),
                        lineWidth: NwStrokeWidth.thin
                    )
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44, alignment: .leading)
        .accessibilityLabel("Spending month")
        .accessibilityHint("Selects the month to review")
    }

    private func isCurrentMonth(_ month: Date?) -> Bool {
        guard let month else { return false }
        return calendar.isDate(month, equalTo: .now, toGranularity: .month)
    }

    private func reserveMonth(
        in model: SpendingHistoryModel?
    ) -> BudgetMonth {
        guard let model else { return BudgetMonth(containing: .now) }
        return BudgetMonth(containing: displayedMonth(model)?.month ?? .now)
    }

    private func reserveSourceBudgetsByMonth(
        in model: SpendingHistoryModel?
    ) -> [BudgetMonth: [SpendingReserveSourceBudget]] {
        guard let model else { return [:] }
        return Dictionary(uniqueKeysWithValues: model.months.map { month in
            let budgetMonth = BudgetMonth(containing: month.month)
            let sources = model.budgetSummary(for: month).groups.compactMap {
                group -> SpendingReserveSourceBudget? in
                guard group.groupIdentity != model.savingsGroupIdentity else {
                    return nil
                }
                let capacity = group.remaining + group.reallocatedToReserves
                return SpendingReserveSourceBudget(
                    id: group.groupIdentity,
                    name: group.groupName,
                    capacity: capacity > .zero ? capacity : .zero
                )
            }
            return (budgetMonth, sources)
        })
    }

    // MARK: - Selected month

    private func monthOverviewCard(
        _ period: DisplayedPeriod,
        model: SpendingHistoryModel
    ) -> some View {
        let month = period.summary
        let funded = SpendingHistoryBuilder.fundingIncome(
            for: month,
            within: model.months,
            calendar: calendar
        )
        let budget = model.budgetSummary(for: month)
        let display = budget.groups.isEmpty
            ? month.fundingDisplay(fundedBy: funded)
            : budget.fundingDisplay(fundedBy: funded)
        return VStack(spacing: NwSpacing.md) {
            if budget.groups.isEmpty {
                noBudgetHero(display, month: month.month, model: model)
                retainedStrip(display)
            } else {
                spendingBudgetHero(
                    budget,
                    display: display,
                    month: month.month,
                    model: model
                )
            }
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
        month: Date,
        model: SpendingHistoryModel
    ) -> some View {
        NwDashboardHero {
            VStack(alignment: .leading, spacing: NwSpacing.lg) {
                monthMenu(model)

                VStack(alignment: .leading, spacing: 2) {
                    Text(isCurrentMonth(month) ? "SPENT THIS MONTH" : "SPENT")
                        .font(NwTypography.caption)
                        .foregroundStyle(NwAppColors.dashboardHeroSecondary)
                    NwAmountText(
                        display.usedHeadline,
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
        display: SpendingHistoryFundingDisplay,
        month: Date,
        model: SpendingHistoryModel
    ) -> some View {
        let displayedProgress = min(max(budget.progress, 0), 1)
        let remainingDays = daysLeft(in: month)
        return NwDashboardHero {
            VStack(alignment: .leading, spacing: NwSpacing.md) {
                HStack(alignment: .top, spacing: NwSpacing.md) {
                    VStack(alignment: .leading, spacing: NwSpacing.sm) {
                        monthMenu(model)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("MONTHLY BUDGET")
                                .font(NwTypography.caption)
                                .foregroundStyle(
                                    NwAppColors.dashboardHeroSecondary
                                )
                                .lineLimit(1)
                                .minimumScaleFactor(0.9)
                                .frame(width: 126, alignment: .leading)
                            NwAmountText(
                                budget.remaining.absolute,
                                variant: .dashboardHero,
                                showCents: false,
                                color: budget.isOver
                                    ? NwAppColors.dashboardHeroOver
                                    : NwAppColors.dashboardHeroText
                            )
                            if pendingReviewCount > 0 {
                                reviewTransactionsButton
                            }
                        }
                    }
                    Spacer(minLength: NwSpacing.sm)
                    spendingBudgetArc(
                        progress: displayedProgress,
                        isOver: budget.isOver,
                        daysLeft: remainingDays
                    )
                }

                Rectangle()
                    .fill(NwAppColors.dashboardHeroTrack)
                    .frame(height: NwStrokeWidth.thin)

                HStack(alignment: .firstTextBaseline, spacing: NwSpacing.md) {
                    heroFundingMetric(
                        title: "Funded",
                        amount: display.fundedHeadline,
                        color: NwAppColors.dashboardHeroText,
                        alignment: .leading
                    )
                    Spacer(minLength: NwSpacing.md)
                    heroFundingMetric(
                        title: "Retained",
                        amount: display.remainingHeadline,
                        color: heroRetainedColor(display.remainingHeadline),
                        alignment: .trailing
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Monthly budget")
        .accessibilityValue(
            "\(budgetStatusText(budget.remaining)), "
                + "\(budgetAmountProgressText(spent: budget.spent, target: budget.target))"
                + (remainingDays.map { ", \($0) days left" } ?? "")
        )
    }

    private var reviewTransactionsButton: some View {
        Button {
            showingIndividualReview = true
        } label: {
            HStack(spacing: NwSpacing.xs) {
                NwIcon.attention.image
                    .font(NwTypography.micro)
                Text("Review \(pendingReviewCount)")
            }
            .font(NwTypography.micro)
            .foregroundStyle(NwAppColors.dashboardHeroReviewText)
            .frame(width: 126, height: 22)
            .background(
                Capsule()
                    .fill(NwAppColors.dashboardHeroReviewSurface)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(width: 126, height: 44, alignment: .bottom)
        .contentShape(Rectangle())
        .accessibilityLabel(
            "Review \(pendingReviewCount) transaction"
                + (pendingReviewCount == 1 ? "" : "s")
        )
    }

    private func heroFundingMetric(
        title: String,
        amount: Money?,
        color: Color,
        alignment: HorizontalAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(title)
                .font(NwTypography.captionSmall)
                .foregroundStyle(NwAppColors.dashboardHeroSecondary)
            if let amount {
                NwAmountText(
                    amount,
                    variant: .dashboardMetric,
                    showCents: false,
                    color: color
                )
            } else {
                Text("—")
                    .font(NwTypography.headline)
                    .foregroundStyle(NwAppColors.dashboardHeroSecondary)
            }
        }
    }

    private func heroRetainedColor(_ amount: Money?) -> Color {
        guard let amount else { return NwAppColors.dashboardHeroSecondary }
        if amount.isNegative { return NwAppColors.dashboardHeroOver }
        if amount > .zero { return NwAppColors.favorableFill }
        return NwAppColors.dashboardHeroSecondary
    }

    private func spendingBudgetArc(
        progress: Double,
        isOver: Bool,
        daysLeft: Int?
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
            if let daysLeft {
                VStack(spacing: 1) {
                    Text("\(daysLeft)")
                        .font(NwTypography.bodyEmphasis)
                    Text("days left")
                        .font(NwTypography.micro)
                }
                .foregroundStyle(NwAppColors.dashboardHeroSecondary)
            }
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

    private func retainedStrip(
        _ display: SpendingHistoryFundingDisplay
    ) -> some View {
        NwCard(style: .secondary) {
            VStack(spacing: NwSpacing.md) {
                HStack(alignment: .firstTextBaseline, spacing: NwSpacing.md) {
                    fundingMetric(
                        title: "Funded",
                        amount: display.fundedHeadline,
                        color: NwAppColors.protected,
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
            let usedShare = min(
                max(display.usedHeadline.doubleValue / funded.doubleValue, 0),
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
                        .frame(width: proxy.size.width * usedShare)
                }
            }
            .frame(height: 8)
            .accessibilityElement()
            .accessibilityLabel("Funding use")
            .accessibilityValue(
                "\(CurrencyFormatter.currency(display.usedHeadline, showCents: false)) used, "
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

    @ViewBuilder
    private var spendingAccountsSection: some View {
        let accounts = visibleSpendingAccounts
        if !accounts.isEmpty {
            VStack(alignment: .leading, spacing: NwSpacing.sm) {
                Text("Accounts")
                    .font(NwTypography.titleSmall)
                    .foregroundStyle(NwAppColors.textPrimary)
                    .padding(.horizontal, NwSpacing.xs)

                VStack(spacing: NwSpacing.sm) {
                    ForEach(accounts) { account in
                        NavigationLink {
                            FinancialAccountDetailView(account: account)
                        } label: {
                            spendingAccountCard(account)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func spendingAccountCard(
        _ account: CachedFinancialAccount
    ) -> some View {
        let metric = spendingAccountMetric(account)
        return NwCard(style: .primary, padding: NwSpacing.md) {
            HStack(spacing: NwSpacing.md) {
                NwIcon.forAccountKind(account.type.rawValue).image
                    .font(NwTypography.headline)
                    .foregroundStyle(NwAppColors.primary)
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(
                            cornerRadius: NwCornerRadius.md,
                            style: .continuous
                        )
                        .fill(NwAppColors.primary.opacity(0.1))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(accountNameResolver.name(for: account))
                        .font(NwTypography.bodyEmphasis)
                        .foregroundStyle(NwAppColors.textPrimary)
                        .lineLimit(1)

                    Text(CurrencyFormatter.currency(
                        metric.amount,
                        showCents: false
                    ))
                    .font(NwTypography.metricCompact)
                    .foregroundStyle(metric.color)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                }

                Spacer(minLength: NwSpacing.sm)
                NwIcon.chevron.image
                    .foregroundStyle(NwAppColors.textSecondary)
            }
            .frame(minHeight: 52, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(accountNameResolver.name(for: account)), "
                + CurrencyFormatter.currency(metric.amount)
        )
        .accessibilityHint("Opens account details")
    }

    private var visibleSpendingAccounts: [CachedFinancialAccount] {
        let eligible = financialAccounts.filter {
            SpendingAccountPinEligibility.canShow($0)
        }
        let byID = Dictionary(
            uniqueKeysWithValues: eligible.map {
                ($0.canonicalAccountId, $0)
            }
        )
        return SpendingAccountPinResolver(rows: spendingAccountPins)
            .visibleAccountIDs(availableAccountIDs: Set(byID.keys))
            .compactMap { byID[$0] }
    }

    private var accountNameResolver: AccountDisplayNameResolver {
        AccountDisplayNameResolver(nicknames: accountNicknames)
    }

    private func spendingAccountMetric(
        _ account: CachedFinancialAccount
    ) -> (amount: Money, color: Color) {
        if account.type == .creditCard {
            return (
                account.balance.absolute,
                NwAppColors.liability
            )
        }
        if let available = account.availableBalanceMilliunits {
            let amount = Money(milliunits: available)
            return (
                amount,
                amount.isNegative
                    ? NwAppColors.liability : NwAppColors.textPrimary
            )
        }
        return (
            account.balance,
            account.balance.isNegative
                ? NwAppColors.liability : NwAppColors.textPrimary
        )
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

    /// Separates monthly spending limits from money intentionally set aside so
    /// cards with different number meanings never appear as one peer group.
    @ViewBuilder
    private func budgetBreakdown(
        _ period: DisplayedPeriod,
        model: SpendingHistoryModel
    ) -> some View {
        let month = period.summary
        let budgets = model.budgetSummary(for: month).groups
        let ordinaryBudgets = budgets.filter {
            $0.groupIdentity != model.savingsGroupIdentity
        }
        let savingsBudget = budgets.first {
            $0.groupIdentity == model.savingsGroupIdentity
        }
        let closedSavingsStatuses = closedSavingsStatuses(for: model)
        let savingsTransferStatus = closedSavingsStatuses.first
        let hasSinkingFunds = model.sinkingFunds.contains { !$0.archived }
        let hasPlan = !ordinaryBudgets.isEmpty
        let hasFuture = savingsBudget != nil || hasSinkingFunds
        if hasPlan || hasFuture {
            VStack(alignment: .leading, spacing: NwSpacing.md) {
                if hasPlan && hasFuture {
                    overviewSectionSelector
                }

                if (overviewSection == .future && hasFuture) || !hasPlan {
                    VStack(spacing: NwSpacing.sm) {
                        LazyVGrid(
                            columns: futureGridColumns,
                            spacing: NwSpacing.sm
                        ) {
                            if let savingsBudget {
                                budgetCard(
                                    savingsBudget,
                                    month: month,
                                    periodStartMonth: period.startMonth,
                                    model: model
                                )
                            }
                            if hasSinkingFunds {
                                let reserveMonth = BudgetMonth(
                                    containing: month.month
                                )
                                let reserveSnapshots =
                                    model.sinkingFundSnapshots(
                                        through: reserveMonth
                                    )
                                sinkingFundsCard(
                                    balance: model.sinkingFundBalance(
                                        through: reserveMonth
                                    ),
                                    featured: SpendingSinkingFundMath
                                        .featuredSnapshots(
                                            from: reserveSnapshots
                                        ),
                                    activeCount: reserveSnapshots.count
                                )
                            }
                        }

                        if let savingsBudget, let savingsTransferStatus {
                            savingsTransferPromptCard(
                                status: savingsTransferStatus
                            ) {
                                selectSavingsTransferPrompt(
                                    savingsBudget,
                                    model: model,
                                    status: savingsTransferStatus
                                )
                            }
                        }
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(
                            Array(ordinaryBudgets.enumerated()),
                            id: \.element.id
                        ) { index, budget in
                            budgetCard(
                                budget,
                                month: month,
                                periodStartMonth: period.startMonth,
                                model: model
                            )
                            if index < ordinaryBudgets.count - 1 {
                                Divider()
                                    .padding(.leading, NwSpacing.md)
                            }
                        }
                    }
                    .nwCardStyle(.planning, padding: 0)
                }
            }
        }
    }

    private var overviewSectionSelector: some View {
        HStack(spacing: NwSpacing.xs) {
            ForEach(OverviewSection.allCases) { section in
                let isSelected = overviewSection == section
                Button {
                    overviewSection = section
                } label: {
                    Text(section.title)
                        .font(NwTypography.bodyEmphasis)
                        .foregroundStyle(
                            isSelected
                                ? NwAppColors.textOnPrimary
                                : NwAppColors.textSecondary
                        )
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(
                            RoundedRectangle(
                                cornerRadius: NwCornerRadius.md,
                                style: .continuous
                            )
                            .fill(
                                isSelected
                                    ? NwAppColors.primary
                                    : Color.clear
                            )
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(
                    isSelected ? .isSelected : []
                )
            }
        }
        .padding(NwSpacing.xs)
        .background(
            RoundedRectangle(
                cornerRadius: NwCornerRadius.card,
                style: .continuous
            )
            .fill(NwAppColors.cardSurfaceAlt)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spending view")
    }

    private var futureGridColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: NwSpacing.sm),
            GridItem(.flexible(), spacing: NwSpacing.sm)
        ]
    }

    private func closedSavingsStatuses(
        for model: SpendingHistoryModel
    ) -> [SavingsMonthStatus] {
        model.savingsStatuses(
            through: BudgetMonth(containing: Date.now).previous
        ).filter { $0.outstanding > .zero }
    }

    private func selectSavingsBucket(
        _ budget: SpendingGroupBudgetSnapshot,
        month: SpendingHistoryMonth,
        model: SpendingHistoryModel,
        outstandingMonths: [SavingsMonthStatus]
    ) {
        savingsBucketSelection = SavingsBucketSelection(
            month: month.month,
            groupIdentity: budget.groupIdentity,
            groupName: budget.groupName,
            transfers: model.savingsTransfers,
            budgetSnapshots: model.budgetSummary(for: month).groups,
            outstandingMonths: outstandingMonths
        )
    }

    private func selectSavingsTransferPrompt(
        _ budget: SpendingGroupBudgetSnapshot,
        model: SpendingHistoryModel,
        status: SavingsMonthStatus
    ) {
        savingsTransferPromptSelection = SavingsTransferPromptSelection(
            status: status,
            transfers: model.savingsTransfers.filter {
                $0.groupIdentity == budget.groupIdentity
                    && $0.effectiveMonth == status.month
            }
        )
    }

    private func savingsTransferPromptCard(
        status: SavingsMonthStatus,
        action: @escaping () -> Void
    ) -> some View {
        let monthLabel = status.month.startDate().formatted(
            .dateTime.month(.wide).year()
        )
        return Button(action: action) {
            NwCard(style: .primary) {
                HStack(spacing: NwSpacing.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Savings transfer")
                            .font(NwTypography.footnoteEm)
                            .foregroundStyle(NwAppColors.textPrimary)
                        Text(
                            "\(CurrencyFormatter.currency(status.outstanding, showCents: false)) to transfer"
                        )
                        .font(NwTypography.headline)
                        .foregroundStyle(NwAppColors.primary)
                        .monospacedDigit()
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: NwSpacing.xs) {
                        Text(monthLabel)
                            .font(NwTypography.caption)
                            .foregroundStyle(NwAppColors.textSecondary)
                        NwIcon.chevron.image
                            .foregroundStyle(NwAppColors.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "Savings transfer for \(monthLabel), \(CurrencyFormatter.currency(status.outstanding, showCents: false)) remaining"
        )
        .accessibilityHint("Shows this month's Savings transfer progress")
    }

    private func sinkingFundsCard(
        balance: Money,
        featured: [SpendingSinkingFundSnapshot],
        activeCount: Int
    ) -> some View {
        Button {
            showingSinkingFunds = true
        } label: {
            HStack(alignment: .bottom, spacing: NwSpacing.sm) {
                VStack(alignment: .leading, spacing: NwSpacing.sm) {
                    Text("Reserves")
                        .font(NwTypography.footnoteEm)
                        .foregroundStyle(NwAppColors.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(CurrencyFormatter.currency(
                        balance,
                        showCents: false
                    ))
                    .font(NwTypography.headline)
                    .foregroundStyle(
                        balance.isNegative
                            ? NwAppColors.budgetOver : NwAppColors.protected
                    )
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                reserveColumnCluster(
                    featured,
                    activeCount: activeCount
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
        .accessibilityLabel(
            reserveAccessibilityLabel(
                balance: balance,
                featured: featured,
                activeCount: activeCount
            )
        )
        .accessibilityHint("Shows individual reserves")
    }

    private func reserveColumnCluster(
        _ snapshots: [SpendingSinkingFundSnapshot],
        activeCount: Int
    ) -> some View {
        let scaleMaximum = snapshots.reduce(Money.zero) { maximum, snapshot in
            max(maximum, max(snapshot.balance, snapshot.fund.target))
        }
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(snapshots) { snapshot in
                let positiveBalance = max(snapshot.balance, .zero)
                let balanceShare = scaleMaximum > .zero
                    ? positiveBalance.doubleValue / scaleMaximum.doubleValue
                    : 0
                let targetShare = snapshot.fund.target > .zero
                    && scaleMaximum > .zero
                    ? snapshot.fund.target.doubleValue
                        / scaleMaximum.doubleValue
                    : nil
                NwReserveBalanceColumn(
                    balanceShare: balanceShare,
                    targetShare: targetShare
                )
                .accessibilityHidden(true)
            }
            if activeCount > snapshots.count {
                Text("+\(activeCount - snapshots.count)")
                    .font(NwTypography.caption)
                    .foregroundStyle(NwAppColors.textSecondary)
                    .monospacedDigit()
                    .padding(.bottom, 1)
            }
        }
        .frame(height: 56, alignment: .bottom)
    }

    private func reserveAccessibilityLabel(
        balance: Money,
        featured: [SpendingSinkingFundSnapshot],
        activeCount: Int
    ) -> String {
        var value = "Reserves, "
            + "\(CurrencyFormatter.currency(balance, showCents: false)) reserved"
        for snapshot in featured {
            value += ", \(snapshot.fund.name), "
                + CurrencyFormatter.currency(
                    snapshot.balance,
                    showCents: false
                )
            if snapshot.fund.target > .zero {
                value += " of " + CurrencyFormatter.currency(
                    snapshot.fund.target,
                    showCents: false
                )
            }
        }
        if activeCount > featured.count {
            value += ", plus \(activeCount - featured.count) more"
        }
        return value
    }

    @ViewBuilder
    private func budgetCard(
        _ budget: SpendingGroupBudgetSnapshot,
        month: SpendingHistoryMonth,
        periodStartMonth: Date,
        model: SpendingHistoryModel
    ) -> some View {
        let group = month.groups.first { $0.id == budget.groupIdentity }
        let pace = budgetPaceStatus(
            progress: budget.progress,
            month: month.month
        )
        Button {
            if budget.groupIdentity == model.savingsGroupIdentity {
                selectSavingsBucket(
                    budget,
                    month: month,
                    model: model,
                    outstandingMonths: closedSavingsStatuses(for: model)
                )
                return
            }
            guard let group else { return }
            detailSelection = SpendingGroupDetailSelection(
                month: month,
                group: group,
                periodStartMonth: periodStartMonth,
                savingsChoices: model.savingsChoices.filter {
                    $0.month == BudgetMonth(containing: month.month)
                        && $0.sourceGroupIdentity == group.id
                },
                reserveAssignments: model.reserveAssignments(
                    in: BudgetMonth(containing: month.month),
                    from: group.id
                )
            )
        } label: {
            if budget.groupIdentity == model.savingsGroupIdentity {
                futureSavingsBudgetContent(budget)
            } else {
                standardPlanBudgetContent(budget)
            }
        }
        .buttonStyle(.plain)
        .disabled(
            group == nil
                && budget.groupIdentity != model.savingsGroupIdentity
        )
        .accessibilityLabel(
            budget.groupIdentity == model.savingsGroupIdentity
                ? savingsBudgetAccessibilityLabel(budget)
                : "Open \(budget.groupName) details, "
                    + "\(drainingBudgetAccessibilityLabel(budget)), "
                    + "\(budgetPaceLabel(pace, month: month.month)), "
                    + "\(budgetAmountProgressText(spent: budget.spent, target: budget.target))"
        )
        .accessibilityHint(
            budget.groupIdentity == model.savingsGroupIdentity
                ? "Shows transfers and assigned savings"
                : "Shows categories and transactions"
        )
    }

    private func standardPlanBudgetContent(
        _ budget: SpendingGroupBudgetSnapshot
    ) -> some View {
        HStack(alignment: .center, spacing: NwSpacing.md) {
            Text(budget.groupName)
                .font(NwTypography.headline)
                .foregroundStyle(NwAppColors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)

            Text(budgetDisplayAmount(budget.remaining))
                .font(NwTypography.metricSmall)
                .foregroundStyle(
                    budget.isOver
                        ? NwAppColors.budgetOver
                        : NwAppColors.protected
                )
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            NwDrainingBudgetColumn(
                remainingShare: budget.baseTarget > .zero
                    ? budget.remaining.doubleValue
                        / budget.baseTarget.doubleValue
                    : 0,
                reallocatedShare: budget.baseTarget > .zero
                    ? budget.reallocatedOut.doubleValue
                        / budget.baseTarget.doubleValue
                    : 0,
                isOver: budget.isOver,
                height: 48,
                accessibilityValue: drainingBudgetAccessibilityLabel(budget)
            )
        }
        .padding(NwSpacing.md)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func futureSavingsBudgetContent(
        _ budget: SpendingGroupBudgetSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: NwSpacing.sm) {
            Text(budget.groupName)
                .font(NwTypography.footnoteEm)
                .foregroundStyle(NwAppColors.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 0)

            Text(savingsFutureAmount(budget))
                .font(NwTypography.headline)
                .foregroundStyle(NwAppColors.favorableText)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .padding(NwSpacing.md)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .nwCardStyle(.planning, padding: 0)
        .contentShape(Rectangle())
    }

    private func savingsFutureAmount(
        _ budget: SpendingGroupBudgetSnapshot
    ) -> String {
        CurrencyFormatter.currency(budget.spent, showCents: false)
            + " + "
            + CurrencyFormatter.currency(
                budget.additionalTarget,
                showCents: false
            )
    }

    private func drainingBudgetAccessibilityLabel(
        _ budget: SpendingGroupBudgetSnapshot
    ) -> String {
        var parts = [
            budgetStatusText(budget.remaining),
            "\(CurrencyFormatter.currency(budget.spent, showCents: false)) spent"
        ]
        if budget.reallocatedToSavings > .zero {
            parts.append(
                "\(CurrencyFormatter.currency(budget.reallocatedToSavings, showCents: false)) moved to Savings"
            )
        }
        if budget.reallocatedToReserves > .zero {
            parts.append(
                "\(CurrencyFormatter.currency(budget.reallocatedToReserves, showCents: false)) moved to Reserves"
            )
        }
        return parts.joined(separator: ", ")
    }

    private func savingsBudgetAccessibilityLabel(
        _ budget: SpendingGroupBudgetSnapshot
    ) -> String {
        var value = "\(budget.groupName), "
            + "\(CurrencyFormatter.currency(budget.spent, showCents: false)) transferred, "
            + "\(CurrencyFormatter.currency(budget.baseTarget, showCents: false)) monthly budget"
        if budget.additionalTarget > .zero {
            value += ", plus \(CurrencyFormatter.currency(budget.additionalTarget, showCents: false)) assigned to Savings"
        }
        value += ", \(CurrencyFormatter.currency(maxMoney(budget.remaining, .zero), showCents: false)) remaining to move"
        return value
    }

    private func maxMoney(_ lhs: Money, _ rhs: Money) -> Money {
        lhs > rhs ? lhs : rhs
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

    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { await rebuild() }
    }

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
                            group: group,
                            savingsChoices: model.savingsChoices.filter {
                                $0.month == BudgetMonth(
                                    containing: month.month
                                )
                                    && $0.sourceGroupIdentity == group.id
                            },
                            reserveAssignments: model.reserveAssignments(
                                in: BudgetMonth(containing: month.month),
                                from: group.id
                            )
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
    let isAutomaticRemainder: Bool
    let isBudgetFocus: Bool
    let isSavingsBucket: Bool

    init(
        identity: String,
        name: String,
        displayOrder: Int,
        budgetTarget: Money? = nil,
        isAutomaticRemainder: Bool = false,
        isBudgetFocus: Bool = false,
        isSavingsBucket: Bool = false
    ) {
        self.identity = identity
        self.name = name
        self.displayOrder = displayOrder
        self.budgetTarget = budgetTarget
        self.isAutomaticRemainder = isAutomaticRemainder
        self.isBudgetFocus = isBudgetFocus
        self.isSavingsBucket = isSavingsBucket
    }

    var id: String { identity }

    var subtitle: String {
        guard let budgetTarget else { return "No budget" }
        if isAutomaticRemainder { return "Automatic remainder" }
        let amount = CurrencyFormatter.currency(
            budgetTarget,
            showCents: false
        )
        return isSavingsBucket
            ? "\(amount) monthly · Savings bucket"
            : "\(amount) monthly"
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
    @Query private var remainderRows: [DurableSpendingRemainderRule]

    @State private var editorTarget: SpendingGroupEditorTarget?
    @State private var activeAlert: SpendingGroupManagementAlert?

    let allowsReordering: Bool

    init(allowsReordering: Bool = false) {
        self.allowsReordering = allowsReordering
    }

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
                        .moveDisabled(!allowsReordering)
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
                if allowsReordering {
                    ToolbarItem(placement: .primaryAction) {
                        EditButton()
                    }
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
        let remainderIdentity = SpendingGroupBudgetResolver()
            .activeRemainderGroupIdentity(
                for: BudgetMonth(containing: .now),
                rules: remainderRows.map(\.coreRule)
            )
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
                isAutomaticRemainder: remainderIdentity == identity,
                isBudgetFocus: latest.isBudgetFocus,
                isSavingsBucket: latest.isSavingsBucket
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
        guard allowsReordering else { return }
        var reordered = groups
        reordered.move(fromOffsets: offsets, toOffset: destination)
        let orderByIdentity = Dictionary(
            uniqueKeysWithValues: reordered.enumerated().map {
                ($0.element.identity, $0.offset)
            }
        )
        let previous = groupRows.map {
            (row: $0, order: $0.displayOrder, updatedAt: $0.updatedAt)
        }
        let now = Date.now
        for row in groupRows {
            guard let order = orderByIdentity[row.groupIdentity] else { continue }
            row.displayOrder = order
            row.updatedAt = now
        }
        guard container.modelContainer.mainContext.safeSave(
            source: "spending.groupManagement.order"
        ) else {
            for prior in previous {
                prior.row.displayOrder = prior.order
                prior.row.updatedAt = prior.updatedAt
            }
            activeAlert = .error("Your Plan order wasn’t saved.")
            return
        }
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
    @Query private var remainderRows: [DurableSpendingRemainderRule]
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
                        if isAutomaticRemainder {
                            HStack {
                                Text("Monthly Budget")
                                    .foregroundStyle(NwAppColors.textPrimary)
                                Spacer()
                                Text("Automatic remainder")
                                .foregroundStyle(NwAppColors.textSecondary)
                            }
                        } else {
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

                        Toggle(
                            "Automatic Remainder",
                            isOn: Binding(
                                get: { isAutomaticRemainder },
                                set: { enabled in
                                    setAutomaticRemainder(enabled)
                                }
                            )
                        )

                        Toggle(
                            "Use as Savings Bucket",
                            isOn: Binding(
                                get: { isSavingsBucket },
                                set: { enabled in
                                    setSavingsBucket(enabled)
                                }
                            )
                        )
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

    private var isSavingsBucket: Bool {
        groupRows
            .filter { $0.groupIdentity == group.identity }
            .max(by: { $0.updatedAt < $1.updatedAt })?
            .isSavingsBucket == true
    }

    private var isAutomaticRemainder: Bool {
        SpendingGroupBudgetResolver().activeRemainderGroupIdentity(
            for: currentBudgetMonth,
            rules: remainderRows.map(\.coreRule)
        ) == group.identity
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
            if saved && isSavingsBucket {
                setSavingsBucket(false)
            }
            if saved && isAutomaticRemainder {
                setAutomaticRemainder(false)
            }
        }
    }

    private func saveBudget(_ target: Money) -> Bool {
        writeBudgetRule(target: target, enabled: true)
    }

    private func setAutomaticRemainder(_ enabled: Bool) {
        let current = currentBudgetMonth
        let matches = remainderRows.filter {
            $0.effectiveYear == current.year
                && $0.effectiveMonth == current.month
        }
        if matches.isEmpty {
            container.modelContainer.mainContext.insert(
                DurableSpendingRemainderRule(
                    groupIdentity: group.identity,
                    effectiveYear: current.year,
                    effectiveMonth: current.month,
                    enabled: enabled
                )
            )
        } else {
            for row in matches {
                row.groupIdentity = group.identity
                row.enabled = enabled
                row.updatedAt = .now
            }
        }
        guard container.modelContainer.mainContext.safeSave(
            source: "spending.groupBudget.remainder"
        ) else {
            persistenceError = "Your automatic remainder choice wasn’t saved."
            return
        }
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

    private func setSavingsBucket(_ enabled: Bool) {
        if enabled && !assignedCategories.isEmpty {
            persistenceError = "Move this group’s categories before using it as the Savings bucket."
            return
        }
        let now = Date.now
        for row in groupRows where SpendingGroupSetup.isUserGroup(row) {
            if row.groupIdentity == group.identity {
                row.isSavingsBucket = enabled
                row.updatedAt = now
            } else if enabled && row.isSavingsBucket {
                row.isSavingsBucket = false
                row.updatedAt = now
            }
        }
        guard container.modelContainer.mainContext.safeSave(
            source: "spending.savingsBucket.designate"
        ) else {
            persistenceError = "Your Savings bucket wasn’t saved."
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
                  SpendingGroupSetup.isUserGroup(latest),
                  !latest.isSavingsBucket else {
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
    let remainderRules: [SpendingRemainderRule]
    let savingsChoices: [SavingsBudgetChoice]
    let savingsGroupIdentity: String?
    let savingsTransfers: [SavingsTransferActivity]
    let focusGroupIdentity: String?
    let sinkingFunds: [SpendingSinkingFund]
    let sinkingFundContributions: [SpendingSinkingFundContribution]
    let sinkingFundExpenses: [SpendingSinkingFundExpense]
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
        let budgetMonth = BudgetMonth(containing: month.month)
        return SpendingGroupBudgetResolver().summary(
            for: budgetMonth,
            groups: month.groups,
            rules: budgetRules,
            savingsChoices: savingsChoices,
            reserveAssignments: sinkingFundContributions,
            funded: SpendingHistoryBuilder.fundingIncome(
                for: month,
                within: months
            ),
            remainderGroupIdentity: SpendingGroupBudgetResolver()
                .activeRemainderGroupIdentity(
                    for: budgetMonth,
                    rules: remainderRules
                ),
            orderIndex: orderIndex(for:)
        )
    }

    func sinkingFundSnapshots(
        through month: BudgetMonth
    ) -> [SpendingSinkingFundSnapshot] {
        sinkingFunds.filter { !$0.archived }.map {
            SpendingSinkingFundMath.snapshot(
                fund: $0,
                contributions: sinkingFundContributions,
                expenses: sinkingFundExpenses,
                through: month
            )
        }
    }

    func sinkingFundBalance(through month: BudgetMonth) -> Money {
        sinkingFundSnapshots(through: month).map(\.balance).sum()
    }

    func reserveAssignments(
        in month: BudgetMonth,
        from sourceGroupIdentity: String
    ) -> [SpendingReserveAssignmentActivity] {
        let fundNames = sinkingFunds.reduce(into: [String: String]()) {
            $0[$1.id] = $1.name
        }
        return Dictionary(
            grouping: sinkingFundContributions.filter {
                $0.month == month
                    && $0.sourceGroupIdentity == sourceGroupIdentity
            },
            by: \.id
        ).compactMapValues { rows in
            rows.max {
                if $0.updatedAt != $1.updatedAt {
                    return $0.updatedAt < $1.updatedAt
                }
                return $0.id < $1.id
            }
        }.values.filter {
            $0.active && $0.amount > .zero
        }.map {
            SpendingReserveAssignmentActivity(
                id: $0.id,
                fundName: fundNames[$0.fundID] ?? "Reserve",
                amount: $0.amount,
                updatedAt: $0.updatedAt
            )
        }.sorted {
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt > $1.updatedAt
            }
            return $0.id < $1.id
        }
    }

    func savingsStatuses(through month: BudgetMonth) -> [SavingsMonthStatus] {
        guard let savingsGroupIdentity else { return [] }
        let savedByMonth = Dictionary(
            grouping: savingsTransfers.filter {
                $0.groupIdentity == savingsGroupIdentity
            },
            by: \.effectiveMonth
        ).mapValues { $0.map(\.amount).sum() }
        return SavingsMonthStatusResolver().statuses(
            groupIdentity: savingsGroupIdentity,
            rules: budgetRules,
            choices: savingsChoices,
            savedByMonth: savedByMonth,
            through: month
        )
    }

}

struct SavingsTransferActivity: Identifiable, Hashable, Sendable {
    let transactionID: String
    let subtransactionID: String?
    let groupIdentity: String
    let postedDate: Date
    let effectiveMonth: BudgetMonth
    let amount: Money
    let title: String
    let accountName: String

    var id: String {
        subtransactionID.map { "\(transactionID)|\($0)" } ?? transactionID
    }
}

struct SpendingReserveAssignmentActivity: Identifiable, Hashable, Sendable {
    let id: String
    let fundName: String
    let amount: Money
    let updatedAt: Date
}

struct SpendingGroupDetailSelection: Identifiable {
    let month: SpendingHistoryMonth
    let group: SpendingHistoryGroupTotal
    let periodStartMonth: Date
    let savingsChoices: [SavingsBudgetChoice]
    let reserveAssignments: [SpendingReserveAssignmentActivity]

    init(
        month: SpendingHistoryMonth,
        group: SpendingHistoryGroupTotal,
        periodStartMonth: Date? = nil,
        savingsChoices: [SavingsBudgetChoice] = [],
        reserveAssignments: [SpendingReserveAssignmentActivity] = []
    ) {
        self.month = month
        self.group = group
        self.periodStartMonth = periodStartMonth ?? month.month
        self.savingsChoices = savingsChoices.sorted {
            if $0.occurredAt != $1.occurredAt {
                return $0.occurredAt > $1.occurredAt
            }
            return $0.id < $1.id
        }
        self.reserveAssignments = reserveAssignments.sorted {
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt > $1.updatedAt
            }
            return $0.id < $1.id
        }
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

struct SavingsBucketSelection: Identifiable {
    let month: Date
    let groupIdentity: String
    let groupName: String
    let transfers: [SavingsTransferActivity]
    let budgetSnapshots: [SpendingGroupBudgetSnapshot]
    let outstandingMonths: [SavingsMonthStatus]

    var id: String {
        "\(groupIdentity):\(BudgetMonth(containing: month).id)"
    }
}

struct SavingsTransferPromptSelection: Identifiable {
    let status: SavingsMonthStatus
    let transfers: [SavingsTransferActivity]

    var id: String { status.id }
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
        let remainderRows = try modelContext.fetch(
            FetchDescriptor<DurableSpendingRemainderRule>()
        )
        let savingsChoiceRows = try modelContext.fetch(
            FetchDescriptor<DurableSavingsBudgetChoice>()
        )
        let savingsAssignmentRows = try modelContext.fetch(
            FetchDescriptor<DurableSavingsTransferAssignment>()
        )
        let sinkingFundRows = try modelContext.fetch(
            FetchDescriptor<DurableSpendingSinkingFund>()
        )
        let sinkingContributionRows = try modelContext.fetch(
            FetchDescriptor<DurableSpendingSinkingFundContribution>()
        )
        let sinkingExpenseRows = try modelContext.fetch(
            FetchDescriptor<DurableSpendingSinkingFundExpense>()
        )
        let goalReserveRows = try modelContext.fetch(
            FetchDescriptor<DurableGoalReserveAccount>()
        )
        let accounts = try modelContext.fetch(
            FetchDescriptor<CachedFinancialAccount>()
        )
        let latestGroups = Dictionary(grouping: groups, by: \.groupIdentity)
            .compactMapValues { rows in
                rows.max(by: { $0.updatedAt < $1.updatedAt })
            }
        let savingsGroup = latestGroups.values
            .filter {
                $0.isSavingsBucket && SpendingGroupSetup.isUserGroup($0)
            }
            .max(by: { $0.updatedAt < $1.updatedAt })
        let latestAssignments = Dictionary(
            grouping: savingsAssignmentRows,
            by: {
                SpendingSavingsLineKey(
                    transactionID: $0.transactionId,
                    subtransactionID: $0.subtransactionId.isEmpty
                        ? nil : $0.subtransactionId
                )
            }
        ).compactMapValues { rows in
            rows.max(by: { $0.updatedAt < $1.updatedAt })
        }
        let savingsAttributionByLine = latestAssignments.reduce(into: [
            SpendingSavingsLineKey: SpendingSavingsAttribution
        ]()) { result, pair in
            let assignment = pair.value
            guard assignment.active else { return }
            let groupName = latestGroups[
                assignment.savingsGroupIdentity
            ]?.name ?? savingsGroup?.name ?? "Savings"
            result[pair.key] = SpendingSavingsAttribution(
                groupIdentity: assignment.savingsGroupIdentity,
                groupName: groupName,
                month: assignment.assignedBudgetMonth
            )
        }
        let excludedSavingsAccountIDs = Set(
            goalReserveRows.filter { $0.active }
                .map { $0.canonicalAccountId }
        )
        let activeFundsByID = Dictionary(
            uniqueKeysWithValues: sinkingFundRows.filter { !$0.archived }.map {
                ($0.id, $0)
            }
        )
        let latestSinkingExpenses = Dictionary(
            grouping: sinkingExpenseRows,
            by: {
                SpendingSinkingFundLineKey(
                    transactionID: $0.transactionId,
                    subtransactionID: $0.subtransactionId
                )
            }
        ).compactMapValues { rows in
            rows.max {
                if $0.updatedAt != $1.updatedAt {
                    return $0.updatedAt < $1.updatedAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
        }
        let sinkingFundByLine = latestSinkingExpenses.reduce(into: [
            SpendingSinkingFundLineKey: SpendingSinkingFundAttribution
        ]()) { result, pair in
            let expense = pair.value
            guard expense.active,
                  let fund = activeFundsByID[expense.fundId] else { return }
            result[pair.key] = SpendingSinkingFundAttribution(
                fundID: fund.id.uuidString,
                fundName: fund.name
            )
        }
        let pipelineContext = SpendingEntryPipeline.Context(
            groups: groups,
            categories: categories,
            accounts: accounts,
            savingsGroup: savingsGroup.map {
                ($0.groupIdentity, $0.name)
            },
            savingsAttributionByLine: savingsAttributionByLine,
            excludedSavingsAccountIDs: excludedSavingsAccountIDs,
            sinkingFundByLine: sinkingFundByLine
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
        let focusIdentity = latestGroups.values
            .filter { $0.isBudgetFocus && SpendingGroupSetup.isUserGroup($0) }
            .max(by: { $0.updatedAt < $1.updatedAt })?
            .groupIdentity
        let latestChoices = Dictionary(grouping: savingsChoiceRows) { $0.id }
            .compactMapValues { rows in
                rows.max(by: { $0.updatedAt < $1.updatedAt })
            }
            .values
            .map { $0.coreChoice }
        let accountByID = Dictionary(
            uniqueKeysWithValues: accounts.map {
                ($0.canonicalAccountId, $0)
            }
        )
        let savingsTransfers: [SavingsTransferActivity]
        if savingsGroup != nil {
            savingsTransfers = rows.flatMap { row -> [SavingsTransferActivity] in
                let accountName = accountByID[row.canonicalAccountId]?.name
                    ?? "Account"
                if row.forecastTreatment == .internalTransfer,
                   accountByID[row.canonicalAccountId]?.type == .savings,
                   !excludedSavingsAccountIDs.contains(row.canonicalAccountId),
                   row.amountMilliunits != 0,
                   let assignment = latestAssignments[
                    SpendingSavingsLineKey(
                        transactionID: row.id,
                        subtransactionID: nil
                    )
                   ], assignment.active {
                    return [SavingsTransferActivity(
                        transactionID: row.id,
                        subtransactionID: nil,
                        groupIdentity: assignment.savingsGroupIdentity,
                        postedDate: row.postedDate,
                        effectiveMonth: assignment.assignedBudgetMonth,
                        amount: Money(milliunits: row.amountMilliunits),
                        title: row.displayName,
                        accountName: accountName
                    )]
                }
                if !row.isSplit, row.forecastTreatment == .savings,
                   row.amountMilliunits < 0,
                   let assignment = latestAssignments[
                    SpendingSavingsLineKey(
                        transactionID: row.id,
                        subtransactionID: nil
                    )
                   ], assignment.active {
                    return [SavingsTransferActivity(
                        transactionID: row.id,
                        subtransactionID: nil,
                        groupIdentity: assignment.savingsGroupIdentity,
                        postedDate: row.postedDate,
                        effectiveMonth: assignment.assignedBudgetMonth,
                        amount: Money(milliunits: -row.amountMilliunits),
                        title: row.displayName,
                        accountName: accountName
                    )]
                }
                return row.subtransactions.compactMap { leg in
                    guard !leg.deleted,
                          leg.forecastTreatment == .savings,
                          leg.amount < .zero,
                          let assignment = latestAssignments[
                            SpendingSavingsLineKey(
                                transactionID: row.id,
                                subtransactionID: leg.id
                            )
                          ], assignment.active else { return nil }
                    return SavingsTransferActivity(
                        transactionID: row.id,
                        subtransactionID: leg.id,
                        groupIdentity: assignment.savingsGroupIdentity,
                        postedDate: row.postedDate,
                        effectiveMonth: assignment.assignedBudgetMonth,
                        amount: leg.amount.absolute,
                        title: row.displayName,
                        accountName: accountName
                    )
                }
            }
            .sorted { lhs, rhs in
                if lhs.postedDate != rhs.postedDate {
                    return lhs.postedDate > rhs.postedDate
                }
                return lhs.id < rhs.id
            }
        } else {
            savingsTransfers = []
        }
        return SpendingHistoryModel(
            months: months,
            budgetRules: budgetRows.map(\.coreRule),
            remainderRules: remainderRows.map(\.coreRule),
            savingsChoices: Array(latestChoices),
            savingsGroupIdentity: savingsGroup?.groupIdentity,
            savingsTransfers: savingsTransfers,
            focusGroupIdentity: focusIdentity,
            sinkingFunds: sinkingFundRows.map(\.coreFund),
            sinkingFundContributions:
                sinkingContributionRows.map(\.coreContribution),
            sinkingFundExpenses: sinkingExpenseRows.map(\.coreExpense),
            paletteIndexByGroupID: paletteIndex,
            orderIndexByGroupID: orderIndex
        )
    }
}

// MARK: - Savings bucket

private struct SavingsSourceGroupOption: Identifiable, Hashable {
    let id: String
    let name: String
    let available: Money
}

private struct SavingsChoiceEditorTarget: Identifiable {
    let choiceID: UUID?
    let amount: Money?
    let note: String
    let occurredAt: Date
    let sourceGroupIdentity: String?

    var id: String { choiceID?.uuidString ?? "new" }
}

private struct SavingsTransferAssignmentTarget: Identifiable {
    let transfer: SavingsTransferActivity
    let proposedMonth: BudgetMonth
    let savingsGroupIdentity: String
    let monthOptions: [BudgetMonth]

    var id: String { transfer.id }
}

private struct SavingsTransferPromptDetailSheet: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss

    let selection: SavingsTransferPromptSelection

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Total to transfer") {
                        NwAmountText(selection.status.target, variant: .body)
                    }
                } header: {
                    Text(monthLabel)
                }

                Section("Transfers made") {
                    if selection.transfers.isEmpty {
                        Text("No transfers yet")
                            .foregroundStyle(NwAppColors.textSecondary)
                    } else {
                        ForEach(selection.transfers) { transfer in
                            HStack(spacing: NwSpacing.md) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Transfer")
                                        .foregroundStyle(NwAppColors.textPrimary)
                                    Text(transferDate(transfer))
                                        .font(NwTypography.footnote)
                                        .foregroundStyle(
                                            NwAppColors.textSecondary
                                        )
                                }
                                Spacer(minLength: 0)
                                NwAmountText(
                                    transfer.amount,
                                    variant: .body,
                                    color: NwAppColors.favorableText
                                )
                            }
                        }
                    }
                }

                Section {
                    LabeledContent("Remaining") {
                        NwAmountText(
                            selection.status.outstanding,
                            variant: .body,
                            color: selection.status.outstanding > .zero
                                ? NwAppColors.primary
                                : NwAppColors.favorableText
                        )
                    }
                }
            }
            .navigationTitle("Savings transfer")
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

    private var monthLabel: String {
        selection.status.month.startDate().formatted(
            .dateTime.month(.wide).year()
        )
    }

    private func transferDate(_ transfer: SavingsTransferActivity) -> String {
        transfer.postedDate.formatted(
            .dateTime.month(.abbreviated).day().year()
        )
    }
}

private struct SavingsBucketDetailSheet: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(AppContainerController.self) private var container
    @Query private var choiceRows: [DurableSavingsBudgetChoice]
    @Query private var assignmentRows: [DurableSavingsTransferAssignment]

    let selection: SavingsBucketSelection

    @State private var choiceEditor: SavingsChoiceEditorTarget?
    @State private var assignmentEditor: SavingsTransferAssignmentTarget?
    @State private var persistenceError: String?

    var body: some View {
        NavigationStack {
            List {
                VStack(spacing: NwSpacing.xl) {
                    VStack(spacing: NwSpacing.xs) {
                        HStack(spacing: 0) {
                            Text(CurrencyFormatter.currency(
                                transferred,
                                showCents: false
                            ))
                            .foregroundStyle(NwAppColors.primary)
                            Text(" + ")
                                .foregroundStyle(NwAppColors.textSecondary)
                            Text(CurrencyFormatter.currency(
                                additionalTarget,
                                showCents: false
                            ))
                            .foregroundStyle(NwAppColors.favorableText)
                        }
                        .font(NwTypography.displayLarge)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        Text("Transferred + Savings")
                            .font(NwTypography.headline)
                            .foregroundStyle(NwAppColors.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)

                    HStack(alignment: .top, spacing: NwSpacing.sm) {
                        NwCompactMoneyMetricCard(
                            amount: baseTarget,
                            label: "Available"
                        )
                        NwCompactMoneyMetricCard(
                            amount: additionalTarget,
                            label: "Assigned",
                            color: NwAppColors.favorableText
                        )
                    }
                }
                .padding(.vertical, NwSpacing.sm)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                activityColumnHeader
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                if activityRows.isEmpty {
                    Text("No savings activity")
                        .font(NwTypography.body)
                        .foregroundStyle(NwAppColors.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 72)
                        .background(
                            RoundedRectangle(
                                cornerRadius: NwCornerRadius.card,
                                style: .continuous
                            )
                            .fill(NwAppColors.cardSurface)
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(activityRows) { row in
                        Group {
                            if row.isInteractive {
                                Button {
                                    openActivity(row)
                                } label: {
                                    activityRow(row)
                                }
                                .buttonStyle(.plain)
                                .swipeActions {
                                    if case let .savings(choice) = row.kind {
                                        Button(role: .destructive) {
                                            deleteChoice(choice)
                                        } label: {
                                            Label(
                                                "Delete",
                                                systemImage: "trash"
                                            )
                                        }
                                    }
                                }
                            } else {
                                activityRow(row)
                            }
                        }
                        .listRowInsets(EdgeInsets(
                            top: NwSpacing.xs,
                            leading: 0,
                            bottom: NwSpacing.xs,
                            trailing: 0
                        ))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
            }
            .listStyle(.plain)
            .contentMargins(
                .horizontal,
                NwSpacing.screenPadding,
                for: .scrollContent
            )
            .background(NwAppColors.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                Button("Add Savings") {
                    choiceEditor = SavingsChoiceEditorTarget(
                        choiceID: nil,
                        amount: nil,
                        note: "",
                        occurredAt: defaultChoiceDate,
                        sourceGroupIdentity: defaultSourceGroupID
                    )
                }
                .buttonStyle(NwPrimaryButtonStyle())
                .disabled(sourceOptions(excluding: nil).isEmpty)
                .opacity(
                    sourceOptions(excluding: nil).isEmpty ? 0.4 : 1
                )
                .padding(.horizontal, NwSpacing.screenPadding)
                .padding(.vertical, NwSpacing.sm)
                .background(.ultraThinMaterial)
            }
            .navigationTitle(selection.groupName)
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
        .sheet(item: $choiceEditor) { target in
            SavingsChoiceEditorSheet(
                target: target,
                budgetMonth: budgetMonth,
                savingsGroupIdentity: selection.groupIdentity,
                sourceOptions: sourceOptions(excluding: target.choiceID)
            )
            .environment(container)
        }
        .sheet(item: $assignmentEditor) { target in
            SavingsTransferAssignmentSheet(target: target)
                .environment(container)
        }
        .alert(
            "Couldn’t Save Changes",
            isPresented: Binding(
                get: { persistenceError != nil },
                set: { if !$0 { persistenceError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { persistenceError = nil }
        } message: {
            Text(persistenceError ?? "Please try again.")
        }
    }

    private var budgetMonth: BudgetMonth {
        BudgetMonth(containing: selection.month)
    }

    private var monthChoices: [DurableSavingsBudgetChoice] {
        Dictionary(grouping: choiceRows, by: { $0.id })
            .compactMapValues { rows in
                rows.max(by: { $0.updatedAt < $1.updatedAt })
            }
            .values
            .filter {
                $0.budgetYear == budgetMonth.year
                    && $0.budgetMonth == budgetMonth.month
                    && $0.savingsGroupIdentity == selection.groupIdentity
            }
            .sorted {
                if $0.occurredAt != $1.occurredAt {
                    return $0.occurredAt > $1.occurredAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    private var baseTarget: Money {
        selection.budgetSnapshots.first {
            $0.groupIdentity == selection.groupIdentity
        }?.baseTarget ?? .zero
    }

    private var additionalTarget: Money {
        monthChoices.map {
            Money(milliunits: $0.amountMilliunits)
        }.sum()
    }

    private var transferred: Money {
        let total = monthTransfers.map(\.amount).sum()
        return total > .zero ? total : .zero
    }

    private var monthTransfers: [SavingsTransferActivity] {
        selection.transfers.filter {
            $0.groupIdentity == selection.groupIdentity
                && $0.effectiveMonth == budgetMonth
        }
    }

    private enum ActivityKind {
        case savings(DurableSavingsBudgetChoice)
        case transfer(SavingsTransferActivity)
        case emptyTransfer
    }

    private struct ActivityRow: Identifiable {
        let id: String
        let date: Date?
        let title: String
        let detail: String
        let amount: Money
        let kind: ActivityKind

        var isInteractive: Bool {
            if case .emptyTransfer = kind { return false }
            return true
        }
    }

    private var activityRows: [ActivityRow] {
        let savings = monthChoices.map { choice in
            let sourceName = selection.budgetSnapshots.first {
                $0.groupIdentity == choice.sourceGroupIdentity
            }?.groupName ?? "Budget"
            return ActivityRow(
                id: "savings:\(choice.id.uuidString)",
                date: choice.occurredAt,
                title: choice.note.isEmpty ? "Savings" : choice.note,
                detail: "Savings · \(sourceName)",
                amount: Money(milliunits: choice.amountMilliunits),
                kind: .savings(choice)
            )
        }
        var transfers = monthTransfers.map { transfer in
            ActivityRow(
                id: "transfer:\(transfer.id)",
                date: transfer.postedDate,
                title: transfer.title,
                detail: "Transfer · \(transfer.accountName)",
                amount: transfer.amount,
                kind: .transfer(transfer)
            )
        }
        if transfers.isEmpty {
            transfers = [ActivityRow(
                id: "transfer:empty",
                date: nil,
                title: "Transfer",
                detail: "No transfers",
                amount: .zero,
                kind: .emptyTransfer
            )]
        }
        return (savings + transfers).sorted {
            if $0.date != $1.date {
                return ($0.date ?? .distantPast) > ($1.date ?? .distantPast)
            }
            return $0.id < $1.id
        }
    }

    private var activityColumnHeader: some View {
        HStack(spacing: NwSpacing.sm) {
            Text("Date")
                .frame(width: 62, alignment: .leading)
            Text("Activity")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Amount")
                .frame(width: 78, alignment: .trailing)
        }
        .font(NwTypography.caption)
        .foregroundStyle(NwAppColors.textSecondary)
        .textCase(.uppercase)
        .padding(.horizontal, NwSpacing.md)
    }

    private func activityRow(_ row: ActivityRow) -> some View {
        HStack(spacing: NwSpacing.sm) {
            Text(row.date?.formatted(
                .dateTime.month(.abbreviated).day()
            ) ?? "—")
                .font(NwTypography.footnoteEm)
                .foregroundStyle(NwAppColors.textPrimary)
                .frame(width: 62, alignment: .leading)
                .lineLimit(1)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(NwTypography.bodyEmphasis)
                    .foregroundStyle(NwAppColors.textPrimary)
                    .lineLimit(1)
                Text(row.detail)
                    .font(NwTypography.caption)
                    .foregroundStyle(NwAppColors.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            NwAmountText(
                row.amount,
                variant: .body,
                showCents: false,
                color: row.amount.isNegative
                    ? NwAppColors.budgetOver : NwAppColors.favorableText
            )
            .frame(width: 78, alignment: .trailing)
        }
        .padding(NwSpacing.md)
        .background(
            RoundedRectangle(
                cornerRadius: NwCornerRadius.card,
                style: .continuous
            )
            .fill(NwAppColors.cardSurface)
        )
        .nwShadow(NwShadow.card)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            row.title + ", "
                + (row.date?.formatted(
                    .dateTime.month(.wide).day().year()
                ) ?? "no transfer date")
                + ", "
                + CurrencyFormatter.currency(row.amount, showCents: false)
        )
        .accessibilityHint(
            row.isInteractive ? "Opens savings activity" : ""
        )
    }

    private func openActivity(_ row: ActivityRow) {
        switch row.kind {
        case let .savings(choice):
            choiceEditor = SavingsChoiceEditorTarget(
                choiceID: choice.id,
                amount: Money(milliunits: choice.amountMilliunits),
                note: choice.note,
                occurredAt: choice.occurredAt,
                sourceGroupIdentity: choice.sourceGroupIdentity
            )
        case let .transfer(transfer):
            assignmentEditor = SavingsTransferAssignmentTarget(
                transfer: transfer,
                proposedMonth: transfer.effectiveMonth,
                savingsGroupIdentity: selection.groupIdentity,
                monthOptions: assignmentMonthOptions(for: transfer)
            )
        case .emptyTransfer:
            break
        }
    }

    private var defaultChoiceDate: Date {
        if budgetMonth.contains(.now) { return .now }
        return Calendar.current.date(
            byAdding: .day,
            value: -1,
            to: budgetMonth.next.startDate()
        ) ?? selection.month
    }

    private var defaultSourceGroupID: String? {
        let options = sourceOptions(excluding: nil)
        return options.first {
            $0.name.localizedCaseInsensitiveCompare("Surplus")
                == .orderedSame
        }?.id ?? options.first?.id
    }

    private func sourceOptions(
        excluding choiceID: UUID?
    ) -> [SavingsSourceGroupOption] {
        selection.budgetSnapshots.compactMap { snapshot in
            guard snapshot.groupIdentity != selection.groupIdentity else {
                return nil
            }
            let available = SpendingGroupBudgetResolver()
                .availableForSavingsChoice(
                    from: snapshot,
                    month: budgetMonth,
                    choices: monthChoices.map(\.coreChoice),
                    excludingChoiceID: choiceID?.uuidString
                )
            return SavingsSourceGroupOption(
                id: snapshot.groupIdentity,
                name: snapshot.groupName,
                available: available
            )
        }
        .sorted {
            if $0.name.localizedCaseInsensitiveCompare("Surplus")
                == .orderedSame { return true }
            if $1.name.localizedCaseInsensitiveCompare("Surplus")
                == .orderedSame { return false }
            return $0.name.localizedCaseInsensitiveCompare($1.name)
                == .orderedAscending
        }
    }

    private func assignmentMonthOptions(
        for transfer: SavingsTransferActivity
    ) -> [BudgetMonth] {
        let posted = BudgetMonth(containing: transfer.postedDate)
        var months = Set(selection.outstandingMonths.compactMap {
            $0.month < posted ? $0.month : nil
        })
        months.insert(posted)
        months.insert(transfer.effectiveMonth)
        return months.sorted()
    }

    private func deleteChoice(_ choice: DurableSavingsBudgetChoice) {
        let matches = choiceRows.filter { $0.id == choice.id }
        for row in matches {
            container.modelContainer.mainContext.delete(row)
        }
        guard container.modelContainer.mainContext.safeSave(
            source: "spending.savingsChoice.delete"
        ) else {
            container.modelContainer.mainContext.rollback()
            persistenceError = "Your savings wasn’t deleted."
            return
        }
    }
}

private struct SavingsChoiceEditorSheet: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(AppContainerController.self) private var container
    @Query private var choiceRows: [DurableSavingsBudgetChoice]

    let target: SavingsChoiceEditorTarget
    let budgetMonth: BudgetMonth
    let savingsGroupIdentity: String
    let sourceOptions: [SavingsSourceGroupOption]

    @State private var amountText: String
    @State private var note: String
    @State private var occurredAt: Date
    @State private var sourceGroupIdentity: String
    @State private var persistenceError: String?

    init(
        target: SavingsChoiceEditorTarget,
        budgetMonth: BudgetMonth,
        savingsGroupIdentity: String,
        sourceOptions: [SavingsSourceGroupOption]
    ) {
        self.target = target
        self.budgetMonth = budgetMonth
        self.savingsGroupIdentity = savingsGroupIdentity
        self.sourceOptions = sourceOptions
        _amountText = State(initialValue: target.amount.map {
            CurrencyInputFormatter.wholeDollarText(for: $0)
        } ?? "")
        _note = State(initialValue: target.note)
        _occurredAt = State(initialValue: target.occurredAt)
        _sourceGroupIdentity = State(
            initialValue: target.sourceGroupIdentity
                ?? sourceOptions.first?.id ?? ""
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Savings") {
                    NwWholeDollarEntryRow(
                        "Amount",
                        text: $amountText,
                        inputTitle: "Savings amount"
                    )
                    Picker("From", selection: $sourceGroupIdentity) {
                        ForEach(sourceOptions) { option in
                            Text(option.name).tag(option.id)
                        }
                    }
                    if let selectedSource {
                        LabeledContent("Available") {
                            NwAmountText(
                                selectedSource.available,
                                variant: .body,
                                showCents: false
                            )
                        }
                    }
                    DatePicker(
                        "Date",
                        selection: $occurredAt,
                        in: dateRange,
                        displayedComponents: .date
                    )
                }

                Section("Optional") {
                    TextField("What did you skip?", text: $note)
                }
            }
            .navigationTitle(
                target.choiceID == nil ? "Add Savings" : "Edit Savings"
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
                    .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) {
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
            .alert(
                "Couldn’t Save Savings",
                isPresented: Binding(
                    get: { persistenceError != nil },
                    set: { if !$0 { persistenceError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {
                    persistenceError = nil
                }
            } message: {
                Text(persistenceError ?? "Please try again.")
            }
        }
    }

    private var amount: Money? {
        CurrencyInputFormatter.wholeDollarMoney(from: amountText)
    }

    private var selectedSource: SavingsSourceGroupOption? {
        sourceOptions.first { $0.id == sourceGroupIdentity }
    }

    private var canSave: Bool {
        guard let amount, amount > .zero, let selectedSource else {
            return false
        }
        return amount <= selectedSource.available
    }

    private var dateRange: ClosedRange<Date> {
        let interval = budgetMonth.interval()
        let end = Calendar.current.date(
            byAdding: .second,
            value: -1,
            to: interval.end
        ) ?? interval.end
        return interval.start...end
    }

    private func save() {
        guard let amount, amount > .zero,
              let selectedSource,
              amount <= selectedSource.available else {
            return
        }
        let now = Date.now
        if let choiceID = target.choiceID {
            let matches = choiceRows.filter { $0.id == choiceID }
            guard !matches.isEmpty else {
                persistenceError = "This savings entry no longer exists."
                return
            }
            for row in matches {
                row.budgetYear = budgetMonth.year
                row.budgetMonth = budgetMonth.month
                row.sourceGroupIdentity = sourceGroupIdentity
                row.savingsGroupIdentity = savingsGroupIdentity
                row.amountMilliunits = amount.milliunits
                row.note = note.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                row.occurredAt = occurredAt
                row.updatedAt = now
            }
        } else {
            container.modelContainer.mainContext.insert(
                DurableSavingsBudgetChoice(
                    budgetYear: budgetMonth.year,
                    budgetMonth: budgetMonth.month,
                    sourceGroupIdentity: sourceGroupIdentity,
                    savingsGroupIdentity: savingsGroupIdentity,
                    amountMilliunits: amount.milliunits,
                    note: note.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ),
                    occurredAt: occurredAt
                )
            )
        }
        guard container.modelContainer.mainContext.safeSave(
            source: "spending.savingsChoice.save"
        ) else {
            container.modelContainer.mainContext.rollback()
            persistenceError = "Your savings wasn’t saved."
            return
        }
        dismiss()
    }
}

private struct SavingsTransferAssignmentSheet: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(AppContainerController.self) private var container
    @Query private var assignmentRows: [DurableSavingsTransferAssignment]

    let target: SavingsTransferAssignmentTarget

    @State private var selectedMonth: BudgetMonth
    @State private var persistenceError: String?

    init(target: SavingsTransferAssignmentTarget) {
        self.target = target
        _selectedMonth = State(initialValue: target.proposedMonth)
    }

    var body: some View {
        NwModalLayout(
            title: "Savings Month",
            onClose: { dismiss() },
            onConfirm: save
        ) {
            NwCard(style: .primary) {
                VStack(spacing: NwSpacing.md) {
                    LabeledContent("Transfer") {
                        NwAmountText(target.transfer.amount, variant: .body)
                    }
                    Divider()
                    LabeledContent("Posted") {
                        Text(target.transfer.postedDate.formatted(
                            .dateTime.month(.abbreviated).day().year()
                        ))
                    }
                }
            }

            NwCard(style: .primary) {
                Picker("Apply to", selection: $selectedMonth) {
                    ForEach(monthOptions, id: \.id) { month in
                        Text(month.startDate().formatted(
                            .dateTime.month(.wide).year()
                        ))
                        .tag(month)
                    }
                }
                .pickerStyle(.inline)
            }

            if let persistenceError {
                NwInlineNotice(
                    "Couldn’t Save Month",
                    message: persistenceError,
                    tone: .warning
                )
            }
        }
    }

    private var postedMonth: BudgetMonth {
        BudgetMonth(containing: target.transfer.postedDate)
    }

    private var monthOptions: [BudgetMonth] {
        target.monthOptions
    }

    private func save() {
        let matches = assignmentRows.filter {
            $0.transactionId == target.transfer.transactionID
                && $0.subtransactionId
                    == (target.transfer.subtransactionID ?? "")
        }
        if matches.isEmpty {
            container.modelContainer.mainContext.insert(
                DurableSavingsTransferAssignment(
                    transactionId: target.transfer.transactionID,
                    subtransactionId:
                        target.transfer.subtransactionID ?? "",
                    savingsGroupIdentity: target.savingsGroupIdentity,
                    assignedYear: selectedMonth.year,
                    assignedMonth: selectedMonth.month
                )
            )
        } else {
            for row in matches {
                row.savingsGroupIdentity = target.savingsGroupIdentity
                row.assignedYear = selectedMonth.year
                row.assignedMonth = selectedMonth.month
                row.active = true
                row.updatedAt = .now
            }
        }
        guard container.modelContainer.mainContext.safeSave(
            source: "spending.savingsTransfer.assignMonth"
        ) else {
            container.modelContainer.mainContext.rollback()
            persistenceError = "The transfer month wasn’t saved."
            return
        }
        dismiss()
    }
}

// MARK: - Spending reserves

private struct SpendingReserveSourceBudget: Identifiable, Hashable {
    let id: String
    let name: String
    /// Unspent capacity before any Reserve assignments for this month.
    let capacity: Money
}

private struct SpendingReserveSourceOption: Identifiable, Hashable {
    let id: String
    let name: String
    let available: Money
}

private struct SpendingSinkingFundEditorTarget: Identifiable {
    let fundID: UUID?
    var id: String { fundID?.uuidString ?? "new" }
}

private struct SpendingReserveAssignmentTarget: Identifiable {
    let assignmentID: UUID?
    let month: BudgetMonth
    let amount: Money
    let sourceGroupIdentity: String?

    var id: String { assignmentID?.uuidString ?? "new" }
}

private struct SpendingSinkingFundLifecycleTarget: Identifiable {
    let fund: DurableSpendingSinkingFund
    var id: UUID { fund.id }
}

private struct SpendingSinkingFundsSheet: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(AppContainerController.self) private var container
    @Query private var fundRows: [DurableSpendingSinkingFund]
    @Query private var contributionRows:
        [DurableSpendingSinkingFundContribution]
    @Query private var expenseRows: [DurableSpendingSinkingFundExpense]

    let month: BudgetMonth
    let sourceBudgetsByMonth: [BudgetMonth: [SpendingReserveSourceBudget]]

    @State private var editorTarget: SpendingSinkingFundEditorTarget?
    @State private var archiveTarget: SpendingSinkingFundLifecycleTarget?
    @State private var deleteTarget: SpendingSinkingFundLifecycleTarget?
    @State private var persistenceError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: NwSpacing.xl) {
                    VStack(spacing: NwSpacing.xs) {
                        NwAmountText(
                            totalBalance,
                            variant: .hero,
                            showCents: false,
                            color: totalBalance.isNegative
                                ? NwAppColors.liability : NwAppColors.primary
                        )
                        Text("Total Reserves")
                            .font(NwTypography.headline)
                            .foregroundStyle(NwAppColors.textSecondary)
                    }
                    .frame(maxWidth: .infinity)

                    if activeFunds.isEmpty {
                        Text("No reserves")
                            .font(NwTypography.body)
                            .foregroundStyle(NwAppColors.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 96)
                            .nwCardStyle(.primary)
                    } else {
                        LazyVGrid(
                            columns: reserveGridColumns,
                            spacing: NwSpacing.sm
                        ) {
                            ForEach(activeFunds) { fund in
                                NavigationLink {
                                    SpendingSinkingFundDetailView(
                                        fundID: fund.id,
                                        month: month,
                                        sourceBudgetsByMonth:
                                            sourceBudgetsByMonth
                                    )
                                    .environment(container)
                                } label: {
                                    fundCard(fund)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        archiveTarget =
                                            SpendingSinkingFundLifecycleTarget(
                                                fund: fund
                                            )
                                    } label: {
                                        Label(
                                            "Archive",
                                            systemImage: "archivebox"
                                        )
                                    }
                                    Button(role: .destructive) {
                                        deleteTarget =
                                            SpendingSinkingFundLifecycleTarget(
                                                fund: fund
                                            )
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, NwSpacing.screenPadding)
                .padding(.top, NwSpacing.xl)
                .padding(.bottom, NwSpacing.xl)
            }
            .background(NwAppColors.background.ignoresSafeArea())
            .navigationTitle("Reserves")
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
                    Menu {
                        NavigationLink {
                            SpendingArchivedSinkingFundsView(
                                month: month,
                                sourceBudgetsByMonth: sourceBudgetsByMonth
                            )
                            .environment(container)
                        } label: {
                            Label(
                                "Archived Reserves",
                                systemImage: "archivebox"
                            )
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button("Add Reserve") {
                    editorTarget = SpendingSinkingFundEditorTarget(
                        fundID: nil
                    )
                }
                .buttonStyle(NwPrimaryButtonStyle())
                .padding(.horizontal, NwSpacing.screenPadding)
                .padding(.vertical, NwSpacing.sm)
                .background(.ultraThinMaterial)
            }
            .alert(item: $archiveTarget) { target in
                Alert(
                    title: Text("Archive \(target.fund.name)?"),
                    message: Text(
                        "It will move to Archived Reserves with all of its activity."
                    ),
                    primaryButton: .destructive(Text("Archive")) {
                        archive(target.fund)
                    },
                    secondaryButton: .cancel()
                )
            }
            .alert(item: $deleteTarget) { target in
                Alert(
                    title: Text("Delete \(target.fund.name)?"),
                    message: Text(
                        "This permanently removes the Reserve and all of its assignments and purchase links. Imported transactions are unchanged."
                    ),
                    primaryButton: .destructive(Text("Delete")) {
                        delete(target.fund)
                    },
                    secondaryButton: .cancel()
                )
            }
            .alert(
                "Couldn’t Save Changes",
                isPresented: Binding(
                    get: { persistenceError != nil },
                    set: { if !$0 { persistenceError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { persistenceError = nil }
            } message: {
                Text(persistenceError ?? "Please try again.")
            }
        }
        .sheet(item: $editorTarget) { target in
            SpendingSinkingFundEditorSheet(fundID: target.fundID)
                .environment(container)
        }
    }

    private var activeFunds: [DurableSpendingSinkingFund] {
        fundRows.filter { !$0.archived }.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.name.localizedCaseInsensitiveCompare($1.name)
                == .orderedAscending
        }
    }

    private var coreContributions: [SpendingSinkingFundContribution] {
        contributionRows.map(\.coreContribution)
    }

    private var coreExpenses: [SpendingSinkingFundExpense] {
        expenseRows.map(\.coreExpense)
    }

    private func snapshot(
        for fund: DurableSpendingSinkingFund
    ) -> SpendingSinkingFundSnapshot {
        SpendingSinkingFundMath.snapshot(
            fund: fund.coreFund,
            contributions: coreContributions,
            expenses: coreExpenses,
            through: month
        )
    }

    private var totalBalance: Money {
        activeFunds.map { snapshot(for: $0).balance }.sum()
    }

    private var reserveGridColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: NwSpacing.sm),
            GridItem(.flexible(), spacing: NwSpacing.sm)
        ]
    }

    private func fundCard(
        _ fund: DurableSpendingSinkingFund
    ) -> some View {
        let snapshot = snapshot(for: fund)
        let balance = snapshot.balance
        let target = Money(milliunits: fund.targetMilliunits)
        return VStack(alignment: .leading, spacing: NwSpacing.sm) {
            Text(fund.name)
                .font(NwTypography.footnoteEm)
                .foregroundStyle(NwAppColors.textPrimary)
                .lineLimit(2)

            Spacer(minLength: 0)

            HStack(spacing: NwSpacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    NwAmountText(
                        balance,
                        variant: .large,
                        showCents: false,
                        color: balance.isNegative
                            ? NwAppColors.liability : NwAppColors.primary
                    )
                    if target > .zero {
                        Text("/ " + CurrencyFormatter.currency(
                            target,
                            showCents: false
                        ))
                        .font(NwTypography.footnoteEm)
                        .foregroundStyle(NwAppColors.textSecondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    } else {
                        Text("No target")
                            .font(NwTypography.footnoteEm)
                            .foregroundStyle(NwAppColors.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                reserveBalanceColumn(balance: balance, target: target)
            }
        }
        .padding(NwSpacing.md)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .leading)
        .background(
            RoundedRectangle(
                cornerRadius: NwCornerRadius.card,
                style: .continuous
            )
            .fill(NwAppColors.cardSurface)
        )
        .nwShadow(NwShadow.card)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reserveCardAccessibilityLabel(
            fund: fund,
            balance: balance,
            target: target
        ))
        .accessibilityHint("Opens reserve details")
    }

    private func reserveBalanceColumn(
        balance: Money,
        target: Money
    ) -> some View {
        let positiveBalance = max(balance, .zero)
        let balanceShare = reserveScaleMaximum > .zero
            ? positiveBalance.doubleValue / reserveScaleMaximum.doubleValue
            : 0
        let targetShare = target > .zero && reserveScaleMaximum > .zero
            ? target.doubleValue / reserveScaleMaximum.doubleValue
            : nil
        return NwReserveBalanceColumn(
            balanceShare: balanceShare,
            targetShare: targetShare,
            width: 18,
            height: 68
        )
        .accessibilityHidden(true)
    }

    private var reserveScaleMaximum: Money {
        activeFunds.reduce(Money.zero) { maximum, fund in
            let fundSnapshot = snapshot(for: fund)
            return max(
                maximum,
                max(
                    fundSnapshot.balance,
                    Money(milliunits: fund.targetMilliunits)
                )
            )
        }
    }

    private func reserveCardAccessibilityLabel(
        fund: DurableSpendingSinkingFund,
        balance: Money,
        target: Money
    ) -> String {
        var label = fund.name + ", "
            + CurrencyFormatter.currency(balance, showCents: false)
            + " reserved"
        if target > .zero {
            label += ", "
                + CurrencyFormatter.currency(target, showCents: false)
                + " target"
        } else {
            label += ", no target"
        }
        return label
    }

    private func archive(_ fund: DurableSpendingSinkingFund) {
        guard SpendingSinkingFundLedgerService(
            context: container.modelContainer.mainContext
        ).setArchived(true, fundID: fund.id) else {
            persistenceError = "The reserve wasn’t archived."
            return
        }
    }

    private func delete(_ fund: DurableSpendingSinkingFund) {
        guard SpendingSinkingFundLedgerService(
            context: container.modelContainer.mainContext
        ).deleteFund(fundID: fund.id) else {
            persistenceError = "The reserve wasn’t deleted."
            return
        }
    }
}

private struct SpendingArchivedSinkingFundsView: View {
    @SwiftUI.Environment(AppContainerController.self) private var container
    @Query private var fundRows: [DurableSpendingSinkingFund]
    @Query private var contributionRows:
        [DurableSpendingSinkingFundContribution]
    @Query private var expenseRows: [DurableSpendingSinkingFundExpense]

    let month: BudgetMonth
    let sourceBudgetsByMonth: [BudgetMonth: [SpendingReserveSourceBudget]]

    @State private var deleteTarget: SpendingSinkingFundLifecycleTarget?
    @State private var persistenceError: String?

    var body: some View {
        List {
            if archivedFunds.isEmpty {
                Text("No archived reserves")
                    .font(NwTypography.body)
                    .foregroundStyle(NwAppColors.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 96)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(archivedFunds) { fund in
                    NavigationLink {
                        SpendingSinkingFundDetailView(
                            fundID: fund.id,
                            month: month,
                            sourceBudgetsByMonth: sourceBudgetsByMonth
                        )
                        .environment(container)
                    } label: {
                        HStack(spacing: NwSpacing.md) {
                            Text(fund.name)
                                .font(NwTypography.bodyEmphasis)
                                .foregroundStyle(NwAppColors.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            NwAmountText(
                                snapshot(for: fund).balance,
                                variant: .body,
                                showCents: false,
                                color: snapshot(for: fund).balance.isNegative
                                    ? NwAppColors.liability
                                    : NwAppColors.primary
                            )
                        }
                        .contentShape(Rectangle())
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button("Restore") {
                            restore(fund)
                        }
                        .tint(NwAppColors.primary)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", role: .destructive) {
                            deleteTarget = SpendingSinkingFundLifecycleTarget(
                                fund: fund
                            )
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(NwAppColors.background.ignoresSafeArea())
        .navigationTitle("Archived Reserves")
        .navigationBarTitleDisplayMode(.inline)
        .alert(item: $deleteTarget) { target in
            Alert(
                title: Text("Delete \(target.fund.name)?"),
                message: Text(
                    "This permanently removes the Reserve and all of its assignments and purchase links. Imported transactions are unchanged."
                ),
                primaryButton: .destructive(Text("Delete")) {
                    delete(target.fund)
                },
                secondaryButton: .cancel()
            )
        }
        .alert(
            "Couldn’t Save Changes",
            isPresented: Binding(
                get: { persistenceError != nil },
                set: { if !$0 { persistenceError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { persistenceError = nil }
        } message: {
            Text(persistenceError ?? "Please try again.")
        }
    }

    private var archivedFunds: [DurableSpendingSinkingFund] {
        fundRows.filter(\.archived).sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.name.localizedCaseInsensitiveCompare($1.name)
                == .orderedAscending
        }
    }

    private func snapshot(
        for fund: DurableSpendingSinkingFund
    ) -> SpendingSinkingFundSnapshot {
        SpendingSinkingFundMath.snapshot(
            fund: fund.coreFund,
            contributions: contributionRows.map(\.coreContribution),
            expenses: expenseRows.map(\.coreExpense),
            through: month
        )
    }

    private func restore(_ fund: DurableSpendingSinkingFund) {
        guard SpendingSinkingFundLedgerService(
            context: container.modelContainer.mainContext
        ).setArchived(false, fundID: fund.id) else {
            persistenceError = "The reserve wasn’t restored."
            return
        }
    }

    private func delete(_ fund: DurableSpendingSinkingFund) {
        guard SpendingSinkingFundLedgerService(
            context: container.modelContainer.mainContext
        ).deleteFund(fundID: fund.id) else {
            persistenceError = "The reserve wasn’t deleted."
            return
        }
    }
}

private struct SpendingSinkingFundEditorSheet: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(AppContainerController.self) private var container

    let fundID: UUID?

    @State private var name = ""
    @State private var targetText = ""
    @State private var monthlyText = ""
    @State private var openingText = ""
    @State private var targetDate = Calendar.current.date(
        byAdding: .year,
        value: 1,
        to: .now
    ) ?? .now
    @State private var hasDueDate = false
    @State private var loaded = false
    @State private var persistenceError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Reserve") {
                    TextField("Name", text: $name)
                }

                Section("Plan") {
                    NwWholeDollarEntryRow("Target", text: $targetText)
                    if target > .zero {
                        Toggle("Due date", isOn: $hasDueDate)
                        if hasDueDate {
                            DatePicker(
                                "Date",
                                selection: $targetDate,
                                in: Date.now...,
                                displayedComponents: .date
                            )
                            if manualMonthly.isZero {
                                LabeledContent("Suggested monthly") {
                                    Text(CurrencyFormatter.currency(
                                        calculatedMonthlyPlan,
                                        showCents: false
                                    ))
                                    .foregroundStyle(
                                        NwAppColors.textSecondary
                                    )
                                }
                            }
                        }
                    }
                    NwWholeDollarEntryRow(
                        "Monthly plan",
                        text: $monthlyText
                    )
                    NwWholeDollarEntryRow(
                        "Starting balance",
                        text: $openingText
                    )
                }
            }
            .navigationTitle(fundID == nil ? "Add Reserve" : "Edit Reserve")
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
                    Button(action: save) {
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
            .alert(
                "Couldn’t Save Reserve",
                isPresented: Binding(
                    get: { persistenceError != nil },
                    set: { if !$0 { persistenceError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { persistenceError = nil }
            } message: {
                Text(persistenceError ?? "Please try again.")
            }
        }
        .onAppear(perform: load)
    }

    private var cleanedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var target: Money {
        CurrencyInputFormatter.wholeDollarMoney(from: targetText) ?? .zero
    }

    private var openingBalance: Money {
        CurrencyInputFormatter.wholeDollarMoney(from: openingText) ?? .zero
    }

    private var manualMonthly: Money {
        CurrencyInputFormatter.wholeDollarMoney(from: monthlyText) ?? .zero
    }

    private var calculatedMonthlyPlan: Money {
        SpendingSinkingFundMath.calculatedMonthlyPlan(
            target: target,
            balance: openingBalance,
            targetDate: targetDate,
            asOf: .now
        )
    }

    private var canSave: Bool {
        !cleanedName.isEmpty
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let fundID,
              let row = try? container.modelContainer.mainContext.fetch(
                FetchDescriptor<DurableSpendingSinkingFund>(
                    predicate: #Predicate { $0.id == fundID }
                )
              ).first else { return }
        name = row.name
        targetText = CurrencyInputFormatter.wholeDollarText(
            for: Money(milliunits: row.targetMilliunits)
        )
        monthlyText = CurrencyInputFormatter.wholeDollarText(
            for: Money(milliunits: row.plannedMonthlyMilliunits)
        )
        openingText = CurrencyInputFormatter.wholeDollarText(
            for: Money(milliunits: row.openingBalanceMilliunits)
        )
        if let date = row.targetDate { targetDate = date }
        hasDueDate = row.targetDate != nil
    }

    private func save() {
        guard canSave else { return }
        let context = container.modelContainer.mainContext
        let current = BudgetMonth(containing: .now)
        let mode: SpendingSinkingFundMode
        if target > .zero, hasDueDate {
            mode = .dueByDate
        } else if target > .zero {
            mode = .buildToAmount
        } else {
            mode = .ongoingReserve
        }
        let row: DurableSpendingSinkingFund
        if let fundID,
           let existing = try? context.fetch(
            FetchDescriptor<DurableSpendingSinkingFund>(
                predicate: #Predicate { $0.id == fundID }
            )
           ).first {
            row = existing
            row.name = cleanedName
            row.mode = mode
            row.targetMilliunits = target.milliunits
            row.targetDate = mode == .dueByDate ? targetDate : nil
            row.plannedMonthlyMilliunits = manualMonthly.milliunits
            row.openingBalanceMilliunits = openingBalance.milliunits
            row.updatedAt = .now
        } else {
            row = DurableSpendingSinkingFund(
                name: cleanedName,
                mode: mode,
                targetMilliunits: target.milliunits,
                targetDate: mode == .dueByDate ? targetDate : nil,
                plannedMonthlyMilliunits: manualMonthly.milliunits,
                openingBalanceMilliunits: openingBalance.milliunits,
                startYear: current.year,
                startMonth: current.month
            )
            context.insert(row)
        }
        guard context.safeSave(source: "spending.reserve.save") else {
            persistenceError = "Your reserve wasn’t saved."
            return
        }
        dismiss()
    }
}

private struct SpendingSinkingFundDetailView: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(AppContainerController.self) private var container
    @Query private var fundRows: [DurableSpendingSinkingFund]
    @Query private var contributionRows:
        [DurableSpendingSinkingFundContribution]
    @Query private var expenseRows: [DurableSpendingSinkingFundExpense]
    @Query private var transactionRows: [CachedFinancialTransaction]

    let fundID: UUID
    let month: BudgetMonth
    let sourceBudgetsByMonth: [BudgetMonth: [SpendingReserveSourceBudget]]

    @State private var assignmentTarget: SpendingReserveAssignmentTarget?
    @State private var showingPurchasePicker = false
    @State private var showingEditor = false
    @State private var showingArchiveConfirmation = false
    @State private var showingDeleteConfirmation = false
    @State private var persistenceError: String?

    var body: some View {
        ScrollView {
            if let fund {
                VStack(spacing: NwSpacing.xl) {
                    VStack(spacing: NwSpacing.xs) {
                        NwAmountText(
                            snapshot.balance,
                            variant: .hero,
                            showCents: false,
                            color: snapshot.balance.isNegative
                                ? NwAppColors.liability : NwAppColors.primary
                        )
                        Text(fund.name + " Reserve Total")
                            .font(NwTypography.headline)
                            .foregroundStyle(NwAppColors.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)

                    HStack(alignment: .top, spacing: NwSpacing.sm) {
                        NwCompactMoneyMetricCard(
                            amount: monthlyPlan,
                            label: "Monthly"
                        )
                        NwCompactMoneyMetricCard(
                            amount: Money(
                                milliunits: fund.targetMilliunits
                            ),
                            label: "Target",
                            detail: fund.targetDate?.formatted(
                                .dateTime
                                    .month(.abbreviated)
                                    .day()
                                    .year()
                            )
                        )
                    }

                    VStack(alignment: .leading, spacing: NwSpacing.sm) {
                        ledgerColumnHeader
                        ForEach(ledgerRows) { row in
                            NavigationLink {
                                monthActivityView(row.month)
                            } label: {
                                ledgerMonthRow(row)
                            }
                            .buttonStyle(.plain)
                        }
                        startLedgerRow
                    }
                }
                .padding(.horizontal, NwSpacing.screenPadding)
                .padding(.top, NwSpacing.xl)
                .padding(.bottom, NwSpacing.xl)
            } else {
                Text("Reserve unavailable")
                    .font(NwTypography.body)
                    .foregroundStyle(NwAppColors.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 240)
            }
        }
        .background(NwAppColors.background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            if fund?.archived == false {
                reserveActionCards
            }
        }
        .navigationTitle(fund?.name ?? "Reserve")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if fund?.archived == false {
                    Button { showingEditor = true } label: {
                        Image(systemName: "pencil.circle.fill")
                            .foregroundStyle(NwAppColors.primary)
                    }
                    .accessibilityLabel("Edit reserve")
                }
                if let fund {
                    Menu {
                        if fund.archived {
                            Button {
                                restore()
                            } label: {
                                Label(
                                    "Restore Reserve",
                                    systemImage: "arrow.uturn.backward"
                                )
                            }
                        } else {
                            Button(role: .destructive) {
                                showingArchiveConfirmation = true
                            } label: {
                                Label(
                                    "Archive Reserve",
                                    systemImage: "archivebox"
                                )
                            }
                        }
                        Button(role: .destructive) {
                            showingDeleteConfirmation = true
                        } label: {
                            Label("Delete Reserve", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Reserve actions")
                }
            }
        }
        .sheet(isPresented: $showingPurchasePicker) {
            SpendingSinkingFundPurchasePicker(fundID: fundID)
                .environment(container)
        }
        .sheet(item: $assignmentTarget) { target in
            SpendingReserveAssignmentSheet(
                assignmentID: target.assignmentID,
                fundID: fundID,
                fundName: fund?.name ?? "Reserve",
                month: target.month,
                current: target.amount,
                currentSourceGroupIdentity: target.sourceGroupIdentity,
                sources: sourceOptions(
                    for: target.month,
                    excluding: target.assignmentID
                )
            )
            .environment(container)
        }
        .sheet(isPresented: $showingEditor) {
            SpendingSinkingFundEditorSheet(fundID: fundID)
                .environment(container)
        }
        .alert(
            "Archive \(fund?.name ?? "Reserve")?",
            isPresented: $showingArchiveConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Archive", role: .destructive) {
                archive()
            }
        } message: {
            Text(
                "It will move to Archived Reserves with all of its activity."
            )
        }
        .alert(
            "Delete \(fund?.name ?? "Reserve")?",
            isPresented: $showingDeleteConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                delete()
            }
        } message: {
            Text(
                "This permanently removes the Reserve and all of its assignments and purchase links. Imported transactions are unchanged."
            )
        }
        .alert(
            "Couldn’t Save Changes",
            isPresented: Binding(
                get: { persistenceError != nil },
                set: { if !$0 { persistenceError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { persistenceError = nil }
        } message: {
            Text(persistenceError ?? "Please try again.")
        }
    }

    private var reserveActionCards: some View {
        HStack(spacing: NwSpacing.sm) {
            Button {
                assignmentTarget = SpendingReserveAssignmentTarget(
                    assignmentID: nil,
                    month: month,
                    amount: .zero,
                    sourceGroupIdentity: nil
                )
            } label: {
                Text("Assign\nMoney")
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(NwPrimaryButtonStyle())
            .disabled(sourceOptions(for: month, excluding: nil).isEmpty)
            .opacity(
                sourceOptions(for: month, excluding: nil).isEmpty ? 0.4 : 1
            )

            Button {
                showingPurchasePicker = true
            } label: {
                Text("Choose Purchase")
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(NwPrimaryButtonStyle())
        }
        .padding(.horizontal, NwSpacing.screenPadding)
        .padding(.vertical, NwSpacing.sm)
        .background(.ultraThinMaterial)
    }

    private struct LedgerRow: Identifiable {
        let month: BudgetMonth
        let change: Money
        let balance: Money

        var id: BudgetMonth { month }
    }

    private var ledgerRows: [LedgerRow] {
        var rows: [LedgerRow] = []
        var cursor = month
        let start = ledgerStartMonth
        while cursor >= start {
            rows.append(LedgerRow(
                month: cursor,
                change: netChange(in: cursor),
                balance: snapshot(through: cursor).balance
            ))
            if cursor == start { break }
            cursor = cursor.previous
        }
        return rows
    }

    private var ledgerStartMonth: BudgetMonth {
        guard let fund else { return month }
        var start = min(fund.coreFund.startMonth, month)
        for row in latestContributionRows where row.coreContribution.active {
            let contributionMonth = BudgetMonth(
                year: row.budgetYear,
                month: row.budgetMonth
            )
            if contributionMonth <= month {
                start = min(start, contributionMonth)
            }
        }
        for row in activeExpenses {
            let expenseMonth = BudgetMonth(containing: row.transactionDate)
            if expenseMonth <= month {
                start = min(start, expenseMonth)
            }
        }
        return start
    }

    private var ledgerColumnHeader: some View {
        HStack(spacing: NwSpacing.sm) {
            Text("Month")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Change")
                .frame(width: 78, alignment: .trailing)
            Text("Balance")
                .frame(width: 78, alignment: .trailing)
        }
        .font(NwTypography.caption)
        .foregroundStyle(NwAppColors.textSecondary)
        .textCase(.uppercase)
        .padding(.horizontal, NwSpacing.md)
    }

    private func ledgerMonthRow(_ row: LedgerRow) -> some View {
        HStack(spacing: NwSpacing.sm) {
            Text(row.month.startDate().formatted(
                .dateTime.month(.abbreviated).year()
            ))
            .font(NwTypography.bodyEmphasis)
            .foregroundStyle(NwAppColors.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(1)

            Text(signedCurrency(row.change))
                .font(NwTypography.footnoteEm)
                .foregroundStyle(changeColor(row.change))
                .monospacedDigit()
                .frame(width: 78, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.65)

            NwAmountText(
                row.balance,
                variant: .body,
                showCents: false,
                color: row.balance.isNegative
                    ? NwAppColors.liability : NwAppColors.primary
            )
            .frame(width: 78, alignment: .trailing)
        }
        .padding(NwSpacing.md)
        .background(
            RoundedRectangle(
                cornerRadius: NwCornerRadius.card,
                style: .continuous
            )
            .fill(NwAppColors.cardSurface)
        )
        .nwShadow(NwShadow.card)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            row.month.startDate().formatted(.dateTime.month(.wide).year())
                + ", change " + signedCurrency(row.change)
                + ", balance "
                + CurrencyFormatter.currency(row.balance, showCents: false)
        )
        .accessibilityHint("Shows this month's reserve activity")
    }

    private var startLedgerRow: some View {
        let openingBalance = Money(
            milliunits: fund?.openingBalanceMilliunits ?? 0
        )
        return HStack(spacing: NwSpacing.sm) {
            Text("Start")
                .font(NwTypography.bodyEmphasis)
                .foregroundStyle(NwAppColors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("—")
                .font(NwTypography.footnoteEm)
                .foregroundStyle(NwAppColors.textSecondary)
                .frame(width: 78, alignment: .trailing)
            NwAmountText(
                openingBalance,
                variant: .body,
                showCents: false,
                color: openingBalance.isNegative
                    ? NwAppColors.liability : NwAppColors.primary
            )
            .frame(width: 78, alignment: .trailing)
        }
        .padding(NwSpacing.md)
        .background(
            RoundedRectangle(
                cornerRadius: NwCornerRadius.card,
                style: .continuous
            )
            .fill(NwAppColors.cardSurfaceAlt)
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: NwCornerRadius.card,
                style: .continuous
            )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Starting balance, "
                + CurrencyFormatter.currency(
                    openingBalance,
                    showCents: false
                )
        )
    }

    private func netChange(in activityMonth: BudgetMonth) -> Money {
        let assigned = latestContributionRows.filter {
            $0.fundId == fundID
                && $0.budgetYear == activityMonth.year
                && $0.budgetMonth == activityMonth.month
                && $0.coreContribution.active
        }.map { Money(milliunits: $0.amountMilliunits) }.sum()
        let spent = activeExpenses.filter {
            BudgetMonth(containing: $0.transactionDate) == activityMonth
        }.map { Money(milliunits: $0.amountMilliunits) }.sum()
        return assigned - spent
    }

    private func signedCurrency(_ amount: Money) -> String {
        if amount.isZero { return "$0" }
        let formatted = CurrencyFormatter.currency(
            amount.absolute,
            showCents: false
        )
        return amount.isNegative ? "−" + formatted : "+" + formatted
    }

    private func changeColor(_ amount: Money) -> Color {
        if amount.isZero { return NwAppColors.textSecondary }
        return amount.isNegative ? NwAppColors.liability : NwAppColors.primary
    }

    private func monthActivityView(
        _ activityMonth: BudgetMonth
    ) -> some View {
        List {
            let items = activity(in: activityMonth)
            if items.isEmpty {
                Text("No activity")
                    .foregroundStyle(NwAppColors.textSecondary)
            } else {
                ForEach(items) { item in
                    if let contribution = item.contribution,
                       fund?.archived == false {
                        Button {
                            assignmentTarget =
                                SpendingReserveAssignmentTarget(
                                    assignmentID: contribution.id,
                                    month: activityMonth,
                                    amount: Money(
                                        milliunits: contribution
                                            .amountMilliunits
                                    ),
                                    sourceGroupIdentity: contribution
                                        .sourceGroupIdentity
                                )
                        } label: {
                            activityRow(item)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button("Remove", role: .destructive) {
                                remove(contribution)
                            }
                        }
                    } else if fund?.archived == false {
                        activityRow(item)
                            .swipeActions(edge: .trailing) {
                                if let expense = item.expense {
                                    Button("Return to budget") {
                                        release(expense)
                                    }
                                    .tint(NwAppColors.primary)
                                }
                            }
                    } else {
                        activityRow(item)
                    }
                }
            }
        }
        .navigationTitle(
            activityMonth.startDate().formatted(
                .dateTime.month(.wide).year()
            )
        )
        .navigationBarTitleDisplayMode(.inline)
    }

    private var fund: DurableSpendingSinkingFund? {
        fundRows.filter { $0.id == fundID }.max {
            $0.updatedAt < $1.updatedAt
        }
    }

    private var activeExpenses: [DurableSpendingSinkingFundExpense] {
        let latest = Dictionary(
            grouping: expenseRows.filter { $0.fundId == fundID },
            by: {
                SpendingSinkingFundLineKey(
                    transactionID: $0.transactionId,
                    subtransactionID: $0.subtransactionId
                )
            }
        ).compactMapValues { rows in
            rows.max(by: { $0.updatedAt < $1.updatedAt })
        }
        return latest.values.filter(\.active)
    }

    private var snapshot: SpendingSinkingFundSnapshot {
        snapshot(through: month)
    }

    private func snapshot(
        through snapshotMonth: BudgetMonth
    ) -> SpendingSinkingFundSnapshot {
        SpendingSinkingFundMath.snapshot(
            fund: fund?.coreFund ?? SpendingSinkingFund(
                id: fundID.uuidString,
                name: "",
                mode: .ongoingReserve,
                startMonth: snapshotMonth
            ),
            contributions: contributionRows.map(\.coreContribution),
            expenses: expenseRows.map(\.coreExpense),
            through: snapshotMonth
        )
    }

    private var monthlyPlan: Money {
        guard let fund else { return .zero }
        let prior = SpendingSinkingFundMath.snapshot(
            fund: fund.coreFund,
            contributions: contributionRows.map(\.coreContribution),
            expenses: expenseRows.map(\.coreExpense),
            through: month.previous
        )
        return SpendingSinkingFundMath.monthlyPlan(
            for: fund.coreFund,
            balance: prior.balance,
            asOf: month.startDate()
        )
    }

    private func sourceOptions(
        for month: BudgetMonth,
        excluding assignmentID: UUID?
    ) -> [SpendingReserveSourceOption] {
        let activeIDs = Set(fundRows.filter { !$0.archived }.map(\.id))
        let otherAssignments = latestContributionRows.filter {
            $0.id != assignmentID
                && activeIDs.contains($0.fundId)
                && $0.budgetYear == month.year
                && $0.budgetMonth == month.month
        }.map(\.coreContribution).filter(\.active)
        let assignedBySource = Dictionary(grouping: otherAssignments) {
            $0.sourceGroupIdentity
        }.mapValues { $0.map(\.amount).sum() }
        return (sourceBudgetsByMonth[month] ?? []).map { source in
            let available = source.capacity
                - (assignedBySource[source.id] ?? .zero)
            return SpendingReserveSourceOption(
                id: source.id,
                name: source.name,
                available: available > .zero ? available : .zero
            )
        }
    }

    private struct ActivityItem: Identifiable {
        let id: String
        let date: Date
        let title: String
        let subtitle: String
        let amount: Money
        let contribution: DurableSpendingSinkingFundContribution?
        let expense: DurableSpendingSinkingFundExpense?
    }

    private func activity(
        in activityMonth: BudgetMonth
    ) -> [ActivityItem] {
        let contributions = latestContributionRows.filter {
            $0.fundId == fundID
                && $0.budgetYear == activityMonth.year
                && $0.budgetMonth == activityMonth.month
        }.filter {
            $0.coreContribution.active
        }.map { row in
            ActivityItem(
                id: "contribution:\(row.id)",
                date: BudgetMonth(
                    year: row.budgetYear,
                    month: row.budgetMonth
                ).startDate(),
                title: "Assigned",
                subtitle: BudgetMonth(
                    year: row.budgetYear,
                    month: row.budgetMonth
                ).startDate().formatted(.dateTime.month(.wide).year())
                    + sourceNameSuffix(
                        row.sourceGroupIdentity,
                        in: BudgetMonth(
                            year: row.budgetYear,
                            month: row.budgetMonth
                        )
                    ),
                amount: Money(milliunits: row.amountMilliunits),
                contribution: row,
                expense: nil
            )
        }
        let transactionsByID = Dictionary(
            uniqueKeysWithValues: transactionRows.map { ($0.id, $0) }
        )
        let expenses = activeExpenses.filter {
            BudgetMonth(containing: $0.transactionDate) == activityMonth
        }.map { row in
            let transaction = transactionsByID[row.transactionId]
            return ActivityItem(
                id: "expense:\(row.id)",
                date: row.transactionDate,
                title: transaction?.displayName ?? "Purchase",
                subtitle: row.transactionDate.formatted(
                    date: .abbreviated,
                    time: .omitted
                ),
                amount: -Money(milliunits: row.amountMilliunits),
                contribution: nil,
                expense: row
            )
        }
        return (contributions + expenses).sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id < $1.id
        }
    }

    private var latestContributionRows:
        [DurableSpendingSinkingFundContribution] {
        Dictionary(grouping: contributionRows, by: \.id)
            .compactMapValues { rows in
                rows.max(by: { $0.updatedAt < $1.updatedAt })
            }
            .values.map { $0 }
    }

    private func activityRow(_ item: ActivityItem) -> some View {
        NwTransactionRow(
            title: item.title,
            subtitle: item.subtitle,
            amount: item.amount,
            showCents: false
        )
    }

    private func sourceNameSuffix(
        _ identity: String,
        in month: BudgetMonth
    ) -> String {
        guard let source = sourceBudgetsByMonth[month]?.first(where: {
            $0.id == identity
        })
        else { return "" }
        return " · from \(source.name)"
    }

    private func release(_ expense: DurableSpendingSinkingFundExpense) {
        guard SpendingSinkingFundLedgerService(
            context: container.modelContainer.mainContext
        ).release(expense) else {
            persistenceError = "The purchase stayed assigned to this reserve."
            return
        }
    }

    private func remove(
        _ contribution: DurableSpendingSinkingFundContribution
    ) {
        guard SpendingSinkingFundLedgerService(
            context: container.modelContainer.mainContext
        ).removeAssignment(contribution) else {
            persistenceError = "The assignment wasn’t removed."
            return
        }
    }

    private func archive() {
        guard SpendingSinkingFundLedgerService(
            context: container.modelContainer.mainContext
        ).setArchived(true, fundID: fundID) else {
            persistenceError = "The reserve wasn’t archived."
            return
        }
        dismiss()
    }

    private func restore() {
        guard SpendingSinkingFundLedgerService(
            context: container.modelContainer.mainContext
        ).setArchived(false, fundID: fundID) else {
            persistenceError = "The reserve wasn’t restored."
            return
        }
        dismiss()
    }

    private func delete() {
        guard SpendingSinkingFundLedgerService(
            context: container.modelContainer.mainContext
        ).deleteFund(fundID: fundID) else {
            persistenceError = "The reserve wasn’t deleted."
            return
        }
        dismiss()
    }
}

private struct SpendingReserveAssignmentSheet: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(AppContainerController.self) private var container

    let assignmentID: UUID?
    let fundID: UUID
    let fundName: String
    let month: BudgetMonth
    let current: Money
    let currentSourceGroupIdentity: String?
    let sources: [SpendingReserveSourceOption]

    @State private var amountText: String
    @State private var selectedSourceGroupIdentity: String
    @State private var persistenceError: String?

    init(
        assignmentID: UUID?,
        fundID: UUID,
        fundName: String,
        month: BudgetMonth,
        current: Money,
        currentSourceGroupIdentity: String?,
        sources: [SpendingReserveSourceOption]
    ) {
        self.assignmentID = assignmentID
        self.fundID = fundID
        self.fundName = fundName
        self.month = month
        self.current = current
        self.currentSourceGroupIdentity = currentSourceGroupIdentity
        self.sources = sources
        _amountText = State(
            initialValue: CurrencyInputFormatter.wholeDollarText(for: current)
        )
        let initialSource = sources.contains {
            $0.id == currentSourceGroupIdentity
        } ? currentSourceGroupIdentity : sources.first?.id
        _selectedSourceGroupIdentity = State(initialValue: initialSource ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(
                        "Month",
                        value: month.startDate().formatted(
                            .dateTime.month(.wide).year()
                        )
                    )
                    Picker("From", selection: $selectedSourceGroupIdentity) {
                        ForEach(sources) { source in
                            Text(source.name).tag(source.id)
                        }
                    }
                    LabeledContent("Maximum") {
                        NwAmountText(
                            maximum,
                            variant: .body,
                            showCents: false
                        )
                    }
                    NwWholeDollarEntryRow(
                        "Assignment",
                        text: $amountText
                    )
                }
                if amount > maximum {
                    Section {
                        NwInlineNotice(
                            "Not enough in this budget",
                            message: "Reduce the assignment to "
                                + CurrencyFormatter.currency(
                                    maximum,
                                    showCents: false
                                ) + " or less.",
                            tone: .caution
                        )
                    }
                }
            }
            .navigationTitle(fundName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(NwAppColors.liability)
                    }
                    .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(
                                canSave
                                    ? NwAppColors.positive
                                    : Color.secondary.opacity(0.35)
                            )
                    }
                    .disabled(!canSave)
                    .accessibilityLabel("Save assignment")
                }
            }
            .alert(
                "Couldn’t Save Assignment",
                isPresented: Binding(
                    get: { persistenceError != nil },
                    set: { if !$0 { persistenceError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { persistenceError = nil }
            } message: {
                Text(persistenceError ?? "Please try again.")
            }
        }
    }

    private var amount: Money {
        CurrencyInputFormatter.wholeDollarMoney(from: amountText) ?? .zero
    }

    private var maximum: Money {
        sources.first { $0.id == selectedSourceGroupIdentity }?
            .available ?? .zero
    }

    private var canSave: Bool {
        amount > .zero
            && amount <= maximum
            && !selectedSourceGroupIdentity.isEmpty
            && (assignmentID == nil
                || amount != current
                || selectedSourceGroupIdentity != currentSourceGroupIdentity)
    }

    private func save() {
        guard SpendingSinkingFundLedgerService(
            context: container.modelContainer.mainContext
        ).saveAssignment(
            id: assignmentID,
            fundID: fundID,
            month: month,
            sourceGroupIdentity: selectedSourceGroupIdentity,
            amount: amount,
            maximum: maximum
        ) else {
            persistenceError = "The assignment wasn’t saved."
            return
        }
        dismiss()
    }
}

private struct SpendingSinkingFundPurchaseCandidate: Identifiable {
    let transactionID: String
    let subtransactionID: String?
    let title: String
    let categoryName: String
    let date: Date
    let amount: Money

    var id: String {
        "\(transactionID)|\(subtransactionID ?? "whole")"
    }
}

private struct SpendingSinkingFundPurchasePicker: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(AppContainerController.self) private var container
    @Query private var fundRows: [DurableSpendingSinkingFund]
    @Query private var transactionRows: [CachedFinancialTransaction]
    @Query private var expenseRows: [DurableSpendingSinkingFundExpense]

    let fundID: UUID

    @State private var pendingCandidate: SpendingSinkingFundPurchaseCandidate?
    @State private var persistenceError: String?

    var body: some View {
        NavigationStack {
            List {
                if candidates.isEmpty {
                    Text("No recent purchases")
                        .foregroundStyle(NwAppColors.textSecondary)
                } else {
                    ForEach(candidates) { candidate in
                        Button {
                            pendingCandidate = candidate
                        } label: {
                            NwTransactionRow(
                                title: candidate.title,
                                subtitle: candidate.categoryName + " · "
                                    + candidate.date.formatted(
                                        date: .abbreviated,
                                        time: .omitted
                                    ),
                                amount: -candidate.amount,
                                showCents: false
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Choose Purchase")
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
            .alert(item: $pendingCandidate) { candidate in
                Alert(
                    title: Text("Use \(fundName)?"),
                    message: Text(
                        "Apply \(CurrencyFormatter.currency(candidate.amount, showCents: false)) from this reserve to \(candidate.title)?"
                    ),
                    primaryButton: .default(Text("Use Reserve")) {
                        assign(candidate)
                    },
                    secondaryButton: .cancel()
                )
            }
            .alert(
                "Couldn’t Assign Purchase",
                isPresented: Binding(
                    get: { persistenceError != nil },
                    set: { if !$0 { persistenceError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { persistenceError = nil }
            } message: {
                Text(persistenceError ?? "Please try again.")
            }
        }
    }

    private var fundName: String {
        fundRows.first { $0.id == fundID }?.name ?? "Reserve"
    }

    private var assignedKeys: Set<SpendingSinkingFundLineKey> {
        let latest = Dictionary(
            grouping: expenseRows,
            by: {
                SpendingSinkingFundLineKey(
                    transactionID: $0.transactionId,
                    subtransactionID: $0.subtransactionId
                )
            }
        ).compactMapValues { rows in
            rows.max(by: { $0.updatedAt < $1.updatedAt })
        }
        return Set(latest.compactMap { $0.value.active ? $0.key : nil })
    }

    private var candidates: [SpendingSinkingFundPurchaseCandidate] {
        let recentCutoff = Calendar.current.date(
            byAdding: .month,
            value: -6,
            to: .now
        ) ?? .distantPast
        let fundStart = fundRows.first { $0.id == fundID }.map {
            BudgetMonth(year: $0.startYear, month: $0.startMonth).startDate()
        } ?? .distantPast
        let cutoff = recentCutoff > fundStart ? recentCutoff : fundStart
        return transactionRows.flatMap { row -> [SpendingSinkingFundPurchaseCandidate] in
            guard !row.deleted, !row.pending, !row.requiresReview,
                  row.postedDate >= cutoff else { return [] }
            let legs = row.subtransactions.filter { !$0.deleted }
            if legs.isEmpty {
                let key = SpendingSinkingFundLineKey(
                    transactionID: row.id,
                    subtransactionID: nil
                )
                guard row.forecastTreatment == .ordinarySpending,
                      row.amountMilliunits < 0,
                      !assignedKeys.contains(key) else { return [] }
                return [SpendingSinkingFundPurchaseCandidate(
                    transactionID: row.id,
                    subtransactionID: nil,
                    title: row.displayName,
                    categoryName: row.categoryDisplayName,
                    date: row.postedDate,
                    amount: Money(milliunits: -row.amountMilliunits)
                )]
            }
            return legs.compactMap { leg in
                let treatment = leg.forecastTreatment
                    ?? (row.amountMilliunits < 0
                        ? row.forecastTreatment : nil)
                let key = SpendingSinkingFundLineKey(
                    transactionID: row.id,
                    subtransactionID: leg.id
                )
                guard treatment == .ordinarySpending,
                      leg.amount.milliunits < 0,
                      !assignedKeys.contains(key) else { return nil }
                return SpendingSinkingFundPurchaseCandidate(
                    transactionID: row.id,
                    subtransactionID: leg.id,
                    title: row.displayName,
                    categoryName: leg.categoryName ?? "Uncategorized",
                    date: row.postedDate,
                    amount: leg.amount.absolute
                )
            }
        }.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.title.localizedCaseInsensitiveCompare($1.title)
                == .orderedAscending
        }
    }

    private func assign(_ candidate: SpendingSinkingFundPurchaseCandidate) {
        guard SpendingSinkingFundLedgerService(
            context: container.modelContainer.mainContext
        ).assign(
            fundID: fundID,
            transactionID: candidate.transactionID,
            subtransactionID: candidate.subtransactionID,
            date: candidate.date,
            amount: candidate.amount
        ) else {
            persistenceError = "The purchase wasn’t assigned."
            return
        }
        dismiss()
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
                    if savingsChoiceTotal > .zero {
                        LabeledContent("Moved to Savings") {
                            Text(CurrencyFormatter.currency(savingsChoiceTotal))
                        }
                    }
                    if reserveAssignmentTotal > .zero {
                        LabeledContent("Moved to Reserves") {
                            Text(CurrencyFormatter.currency(
                                reserveAssignmentTotal
                            ))
                        }
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
                    if !selection.savingsChoices.isEmpty {
                        NavigationLink {
                            SavingsChoiceMonthDetailView(
                                periodLabel: selection.periodLabel,
                                choices: selection.savingsChoices
                            )
                        } label: {
                            HStack(spacing: NwSpacing.xs) {
                                Text("Savings Choices")
                                    .lineLimit(1)
                                Text("(\(selection.savingsChoices.count))")
                                    .font(NwTypography.footnote)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(CurrencyFormatter.currency(
                                    savingsChoiceTotal
                                ))
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !selection.reserveAssignments.isEmpty {
                        NavigationLink {
                            ReserveAssignmentMonthDetailView(
                                periodLabel: selection.periodLabel,
                                assignments: selection.reserveAssignments
                            )
                        } label: {
                            HStack(spacing: NwSpacing.xs) {
                                Text("Reserve Assignments")
                                    .lineLimit(1)
                                Text("(\(selection.reserveAssignments.count))")
                                    .font(NwTypography.footnote)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(CurrencyFormatter.currency(
                                    reserveAssignmentTotal
                                ))
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

    private var savingsChoiceTotal: Money {
        selection.savingsChoices.map(\.amount).sum()
    }

    private var reserveAssignmentTotal: Money {
        selection.reserveAssignments.map(\.amount).sum()
    }
}

private struct SavingsChoiceMonthDetailView: View {
    let periodLabel: String
    let choices: [SavingsBudgetChoice]

    var body: some View {
        List {
            Section(periodLabel) {
                ForEach(choices) { choice in
                    NwTransactionRow(
                        title: choice.note.isEmpty
                            ? "Savings choice" : choice.note,
                        subtitle: "Moved to Savings · "
                            + choice.occurredAt.formatted(
                                date: .abbreviated,
                                time: .omitted
                            ),
                        amount: choice.amount
                    )
                }
            }
        }
        .navigationTitle("Savings Choices")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ReserveAssignmentMonthDetailView: View {
    let periodLabel: String
    let assignments: [SpendingReserveAssignmentActivity]

    var body: some View {
        List {
            Section(periodLabel) {
                ForEach(assignments) { assignment in
                    NwTransactionRow(
                        title: assignment.fundName,
                        subtitle: "Moved to Reserves · "
                            + assignment.updatedAt.formatted(
                                date: .abbreviated,
                                time: .omitted
                            ),
                        amount: assignment.amount
                    )
                }
            }
        }
        .navigationTitle("Reserve Assignments")
        .navigationBarTitleDisplayMode(.inline)
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
