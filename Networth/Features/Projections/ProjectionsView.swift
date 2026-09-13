import SwiftUI
import SwiftData
import Charts
import Combine
import NetworthCore

enum ProjectionAccountWarningCopy {
    static func title(for account: CashAccountProjection) -> String {
        "\(account.accountName) may be overdrawn"
    }

    static func message(for account: CashAccountProjection) -> String {
        guard let lowPoint = account.projectedShortfallLowPoint else {
            return "This account is projected to fall below $0."
        }
        let amount = CurrencyFormatter.compact(lowPoint.balance.absolute)
        let date = lowPoint.date.formatted(
            .dateTime.month(.abbreviated).day()
        )
        return "Projected to fall \(amount) below $0 on \(date)."
    }
}

enum ProjectionHeroMetricKind: Sendable, Equatable {
    case setup
    case available
    case transferNeeded
    case bufferGap
    case projectedBalance
    case projectedLow
}

struct ProjectionHeroMetric: Sendable, Equatable {
    let kind: ProjectionHeroMetricKind
    let label: String
    let amount: Money?

    static func resolve(
        setupIncomplete: Bool,
        canLeadWithSpendingRoom: Bool,
        availableAmount: Money?,
        showsPaymentFundingHeadline: Bool,
        status: CashProjectionStatus,
        headlineAmount: Money?,
        tightLabel: String = "Buffer gap"
    ) -> ProjectionHeroMetric {
        if setupIncomplete {
            return ProjectionHeroMetric(
                kind: .setup,
                label: "Setup needed",
                amount: nil
            )
        }
        if canLeadWithSpendingRoom, let availableAmount {
            return ProjectionHeroMetric(
                kind: .available,
                label: "Available",
                amount: availableAmount
            )
        }
        if showsPaymentFundingHeadline {
            return ProjectionHeroMetric(
                kind: .transferNeeded,
                label: "Transfer needed",
                amount: headlineAmount
            )
        }
        if status == .tight {
            return ProjectionHeroMetric(
                kind: .bufferGap,
                label: tightLabel,
                amount: headlineAmount
            )
        }
        if status == .shortfall {
            return ProjectionHeroMetric(
                kind: .projectedBalance,
                label: "Projected balance",
                amount: headlineAmount
            )
        }
        return ProjectionHeroMetric(
            kind: .projectedLow,
            label: "Projected low",
            amount: headlineAmount
        )
    }
}

private struct CardPaymentDetailSelection: Identifiable {
    let payment: UpcomingCardPayment
    let transactions: [TransactionSummary]
    /// Paying-account outflows offered as the actual debit when the
    /// payment is past due and unsettled.
    let bankCandidates: [TransactionSummary]

    var id: String { payment.id }
}

/// The app's daily decision surface: what cash is available, what will move,
/// and whether known obligations plus ordinary spending remain above buffer.
struct ProjectionsView: View {
    /// Debounced app-wide save events: the projection recomputes once per
    /// burst of persistence activity instead of on every body evaluation.
    private static let saveEvents: AnyPublisher<Notification, Never> =
        NotificationCenter.default
            .publisher(for: .networthModelContextSaved)
            .debounce(for: .seconds(0.6), scheduler: RunLoop.main)
            .eraseToAnyPublisher()

    @Environment(AppContainerController.self) private var container
    @Query(sort: \CachedFinancialAccount.name) private var financialAccounts: [CachedFinancialAccount]
    @Query private var cardSettings: [DurableCardSettings]
    @Query private var cardPaymentConfirmations:
        [DurableCardPaymentConfirmation]
    @Query private var cardStatementAssignments:
        [DurableCardStatementAssignment]
    @Query private var incomePatternOverrides: [DurableIncomePatternOverride]
    @Query private var recurringExpectations: [DurableRecurringExpectation]
    @Query private var userSettings: [DurableUserSettings]
    @Query private var exclusions: [DurableExcludedSpendCategory]
    @Query private var transactionExclusions: [DurableExcludedSpendTransaction]
    @Query private var cashAccountOverrides: [DurableProjectionCashAccountOverride]

    // (Cash-pool membership rules live in ProjectionCashSelection below so
    // the derived Goals-reserve exclusion is unit-testable.)

    @State private var showingAssumptions = false
    @State private var showingSafeToSpendDetails = false
    @State private var selectedPayment: CardPaymentDetailSelection?
    @State private var scrubbedProjectionDate: Date?
    @State private var showingAllUpcomingActivity = false
    @State private var showingPaycheckSchedule = false
    @State private var openPaycheckAfterAssumptions = false
    @State private var editingRecurringIncome: DurableRecurringExpectation?
    /// Forecast cache: computing the projection is the single most expensive
    /// render-path operation in the app; body must never do it per frame
    /// (chart scrubbing re-evaluates body continuously).
    @State private var cachedData: ProjectionData?
    @State private var cacheFingerprint = ""
    @State private var isVisible = false

    var body: some View {
        NavigationStack {
            Group {
                if let data = cachedData {
                    content(data)
                } else {
                    // Never compute the forecast inside body: cold loads show
                    // a placeholder until the first cache fill lands.
                    NwLoadingState("Building projections…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .nwFieldBackground(
                            photo: container.backgroundPhotoStore.image,
                            wash: container.backgroundPhotoStore.washOpacity
                        )
                        .navigationTitle("Projections")
                }
            }
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
            .task { refreshCache() }
            .onAppear {
                isVisible = true
                refreshCache()
            }
            .onDisappear { isVisible = false }
            .onReceive(Self.saveEvents) { _ in
                if isVisible {
                    refreshCache(force: true)
                } else {
                    // Hidden tab: mark stale, recompute on return.
                    cacheFingerprint = ""
                }
            }
        }
    }

    /// Cheap staleness signal. Transactions live in the local-only cache
    /// store, so the save notification fully covers their changes; only
    /// small durable tables (CloudKit-synced) contribute here.
    private var inputFingerprint: String {
        [
            "\(financialAccounts.count)",
            "\(cardSettings.count)", "\(exclusions.count)",
            "\(cardPaymentConfirmations.count)",
            "\(cardStatementAssignments.count)",
            "\(incomePatternOverrides.count)",
            "\(recurringExpectations.count)",
            "\(transactionExclusions.count)", "\(cashAccountOverrides.count)",
            "\(userSettings.first?.lastSyncedAt?.timeIntervalSince1970 ?? 0)"
        ].joined(separator: "|")
    }

    @State private var refreshTask: Task<Void, Never>?

    private func refreshCache(force: Bool = false) {
        let fingerprint = inputFingerprint
        guard force || cachedData == nil || cacheFingerprint != fingerprint
        else { return }
        cacheFingerprint = fingerprint
        let modelContainer = container.modelContainer
        refreshTask?.cancel()
        refreshTask = Task {
            // Detached: @ModelActor inherits the creating executor; built on
            // main it would compute on main.
            let data = await Task.detached(priority: .userInitiated) {
                let dataActor = ProjectionsDataActor(
                    modelContainer: modelContainer
                )
                return await dataActor.build()
            }.value
            guard !Task.isCancelled else { return }
            cachedData = data
        }
    }

    private func content(_ data: ProjectionData) -> some View {
            ScrollView {
                VStack(alignment: .leading, spacing: NwSpacing.lg) {
                    if data.selectedCashAccounts.isEmpty {
                        priorityNotice(data)

                        NwEmptyState(
                            title: availableAccountSnapshots.isEmpty ? "Sync your accounts" : "Choose your cash accounts",
                            message: availableAccountSnapshots.isEmpty
                                ? "Connect your financial accounts in Settings."
                                : "Select cash accounts in Settings.",
                            icon: .projections
                        )
                        .frame(minHeight: 300)
                    } else {
                        // Lead with the answer (the Outlook number), then the
                        // caveat beneath it — reassurance on arrival, detail after.
                        cashChart(data)
                        priorityNotice(data)
                        timeline(data)
                    }
                }
                .padding(.horizontal, NwSpacing.screenPadding)
                .padding(.vertical, NwSpacing.lg)
            }
            .nwFieldBackground(
                photo: container.backgroundPhotoStore.image,
                wash: container.backgroundPhotoStore.washOpacity
            )
            .navigationTitle("Projections")
            .refreshable { await container.syncNow() }
            .sheet(
                isPresented: $showingAssumptions,
                onDismiss: {
                    guard openPaycheckAfterAssumptions else { return }
                    openPaycheckAfterAssumptions = false
                    showingPaycheckSchedule = true
                }
            ) {
                ProjectionAssumptionsSheet(data: data) {
                    openPaycheckAfterAssumptions = true
                    showingAssumptions = false
                }
            }
            .sheet(isPresented: $showingSafeToSpendDetails) {
                if let estimate = data.result.safeToSpend {
                    SafeToSpendDetailSheet(data: data, estimate: estimate)
                        .environment(container)
                }
            }
            .sheet(item: $selectedPayment) { payment in
                CardPaymentDetailSheet(
                    payment: payment.payment,
                    transactions: payment.transactions,
                    bankCandidates: payment.bankCandidates
                )
                .environment(container)
            }
            .sheet(isPresented: $showingPaycheckSchedule) {
                if case .detected(let paycheck) = data.paycheckDetection {
                    PaycheckScheduleSheet(
                        paycheck: paycheck,
                        existingOverride: activePaycheckOverride(for: paycheck)
                    )
                    .environment(container)
                }
            }
            .sheet(item: $editingRecurringIncome) { expectation in
                RecurringExpectationForm(expectation: expectation)
                    .environment(container)
            }
    }

    @ViewBuilder
    private func priorityNotice(_ data: ProjectionData) -> some View {
        switch container.plaidTransactionSyncCoordinator.phase {
        case .syncing(let label):
            HStack(spacing: NwSpacing.sm) {
                ProgressView().controlSize(.small)
                Text("Updating \(label.lowercased())…")
                    .font(NwTypography.footnote)
                    .foregroundStyle(.secondary)
            }
        case .error(let message):
            NwInlineNotice("Update failed", message: message, tone: .warning)
        case .idle:
            if !data.missingCardNames.isEmpty {
                settingsNotice(
                    "Finish credit-card setup",
                    message: "Set card timing and payment account for \(data.missingCardNames.joined(separator: ", "))."
                )
            } else if !data.unfundedCardNames.isEmpty {
                settingsNotice(
                    "Include card payment accounts",
                    message: "Include the payment account for \(data.unfundedCardNames.joined(separator: ", "))."
                )
            } else if let account = data.primaryPaymentAccountShortfall,
                      !data.showsPaymentFundingHeadline {
                projectionIssueNotice(
                    ProjectionAccountWarningCopy.title(for: account),
                    message: ProjectionAccountWarningCopy.message(for: account)
                )
            } else if let account = data.primaryOtherAccountShortfall {
                projectionIssueNotice(
                    ProjectionAccountWarningCopy.title(for: account),
                    message: ProjectionAccountWarningCopy.message(for: account)
                )
            } else if let warning = data.incomeWarning {
                settingsNotice(warning.title, message: warning.message)
            } else if isStale {
                NwInlineNotice(
                    "Projection data is stale",
                    message: "Last updated \(lastUpdatedText). Pull to retry.",
                    tone: .caution
                )
            }
        }
    }

    private func projectionIssueNotice(_ title: String, message: String) -> some View {
        NwInlineNotice(
            title,
            message: message,
            tone: .warning,
            actionTitle: "Why"
        ) {
            showingAssumptions = true
        }
    }

    private func settingsNotice(_ title: String, message: String) -> some View {
        Button {
            SettingsRouter.open()
        } label: {
            NwInlineNotice(
                title,
                message: message,
                tone: .caution
            )
        }
        .buttonStyle(.plain)
    }

    private func cashChart(_ data: ProjectionData) -> some View {
        let selectedPoint = selectedProjectionPoint(data)
        let hero = projectionHeroMetric(data)
        let accent = projectionHeroAccent(hero.kind)
        return NwDashboardHero {
            VStack(alignment: .leading, spacing: NwSpacing.lg) {
                HStack {
                    Text("CASH OUTLOOK")
                        .font(NwTypography.caption)
                        .foregroundStyle(NwAppColors.dashboardHeroSecondary)
                    Spacer()
                    Button {
                        showingAssumptions = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(NwTypography.headline)
                            .foregroundStyle(NwAppColors.dashboardHeroSecondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Projection assumptions")
                }
                .frame(height: 28)

                projectionHeroSummary(data, hero: hero, accent: accent)

                if !data.result.expectedPoints.isEmpty {
                    Chart {
                        ForEach(data.result.expectedPoints) { point in
                            AreaMark(
                                x: .value("Date", point.date),
                                y: .value(
                                    "Projected cash",
                                    point.balance.doubleValue
                                )
                            )
                            .foregroundStyle(.linearGradient(
                                colors: [
                                    accent.opacity(0.34),
                                    accent.opacity(0.03)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ))

                            LineMark(
                                x: .value("Date", point.date),
                                y: .value(
                                    "Projected cash",
                                    point.balance.doubleValue
                                ),
                                series: .value("Series", "Projected cash")
                            )
                            .foregroundStyle(accent)
                            .lineStyle(StrokeStyle(lineWidth: 3))
                        }
                        RuleMark(
                            y: .value(
                                "Buffer",
                                minimumCashBuffer.doubleValue
                            )
                        )
                        .foregroundStyle(NwAppColors.gold.opacity(0.75))
                        .lineStyle(
                            StrokeStyle(lineWidth: 1, dash: [4, 4])
                        )

                        if let lowPoint = data.result.expectedLowPoint {
                            PointMark(
                                x: .value("Low date", lowPoint.date),
                                y: .value(
                                    "Projected low",
                                    lowPoint.balance.doubleValue
                                )
                            )
                            .foregroundStyle(accent)
                            .symbolSize(55)
                        }

                        if let scrubbedProjectionDate {
                            RuleMark(
                                x: .value(
                                    "Selected date",
                                    scrubbedProjectionDate
                                )
                            )
                            .foregroundStyle(
                                NwAppColors.dashboardHeroText.opacity(0.55)
                            )
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                    }
                    .chartLegend(.hidden)
                    .chartYAxis(.hidden)
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 3)) { value in
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(
                                        date,
                                        format: .dateTime
                                            .month(.abbreviated)
                                            .day()
                                    )
                                    .font(NwTypography.caption)
                                    .foregroundStyle(
                                        NwAppColors.dashboardHeroSecondary
                                    )
                                }
                            }
                        }
                    }
                    .chartXSelection(value: $scrubbedProjectionDate)
                    .frame(height: 158)
                }

                if let selectedPoint {
                    HStack(alignment: .firstTextBaseline) {
                        Text(
                            scrubbedProjectionDate == nil
                                ? "Low · \(selectedPoint.date.formatted(.dateTime.month(.abbreviated).day().weekday(.abbreviated)))"
                                : selectedPoint.date.formatted(
                                    .dateTime.month(.abbreviated).day()
                                        .weekday(.abbreviated)
                                )
                        )
                        .font(NwTypography.footnoteEm)
                        .foregroundStyle(NwAppColors.dashboardHeroSecondary)
                        Spacer(minLength: NwSpacing.sm)
                        NwAmountText(
                            selectedPoint.balance,
                            variant: .body,
                            showCents: false,
                            color: NwAppColors.dashboardHeroText
                        )
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Cash outlook")
    }

    private func projectionHeroMetric(
        _ data: ProjectionData
    ) -> ProjectionHeroMetric {
        ProjectionHeroMetric.resolve(
            setupIncomplete: data.setupIncomplete,
            canLeadWithSpendingRoom: data.canLeadWithSpendingRoom,
            availableAmount: data.result.safeToSpend?.amount,
            showsPaymentFundingHeadline: data.showsPaymentFundingHeadline,
            status: data.result.status,
            headlineAmount: data.headlineAmount,
            tightLabel: data.protectionGapLabel
        )
    }

    private func projectionHeroAccent(
        _ kind: ProjectionHeroMetricKind
    ) -> Color {
        switch kind {
        case .available, .projectedLow:
            return NwAppColors.gold
        case .setup, .transferNeeded, .bufferGap:
            return NwAppColors.dashboardHeroCaution
        case .projectedBalance:
            return NwAppColors.dashboardHeroLiability
        }
    }

    private func projectionHeroSummary(
        _ data: ProjectionData,
        hero: ProjectionHeroMetric,
        accent: Color
    ) -> some View {
        Button {
            if hero.kind == .available {
                showingSafeToSpendDetails = true
            } else {
                showingAssumptions = true
            }
        } label: {
            HStack(alignment: .center, spacing: NwSpacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(hero.label.uppercased())
                        .font(NwTypography.caption)
                        .foregroundStyle(accent)
                    if let amount = hero.amount {
                        NwAmountText(
                            amount,
                            variant: .hero,
                            showCents: false,
                            color: NwAppColors.dashboardHeroText
                        )
                    } else {
                        NwIcon.projections.image
                            .font(NwTypography.display)
                            .foregroundStyle(accent)
                            .padding(.vertical, NwSpacing.xs)
                    }
                    Text(data.headlineTitle)
                        .font(NwTypography.footnoteEm)
                        .foregroundStyle(NwAppColors.dashboardHeroSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: NwSpacing.sm)
                NwIcon.chevron.image
                    .font(NwTypography.headline)
                    .foregroundStyle(accent)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(
            hero.kind == .available
                ? "Shows how available cash is calculated"
                : "Shows why the projection has this status"
        )
    }

    private func selectedProjectionPoint(_ data: ProjectionData) -> CashPositionPoint? {
        guard let scrubbedProjectionDate else { return data.result.expectedLowPoint }
        let calendar = Calendar(identifier: .gregorian)
        let target = calendar.startOfDay(for: scrubbedProjectionDate)
        return data.result.expectedPoints.min { lhs, rhs in
            abs(calendar.startOfDay(for: lhs.date).timeIntervalSince(target))
                < abs(calendar.startOfDay(for: rhs.date).timeIntervalSince(target))
        }
    }

    private func timeline(_ data: ProjectionData) -> some View {
        let visibleEvents = showingAllUpcomingActivity
            ? data.result.events
            : Array(data.result.events.prefix(3))
        let hasExpectedPaycheck = data.expectedTodayPaycheckAmount != nil
        return VStack(alignment: .leading, spacing: NwSpacing.md) {
            Text("Next Cash Activity")
                .font(NwTypography.titleSmall)
            if data.result.events.isEmpty && !hasExpectedPaycheck {
                NwInlineNotice(
                    "No known events",
                    message: "Add recurring income and bills in Settings.",
                    tone: .info
                )
            } else {
                NwCard(style: .primary, padding: NwSpacing.md) {
                    VStack(spacing: 0) {
                        if case .detected(let paycheck) = data.paycheckDetection,
                           let amount = data.expectedTodayPaycheckAmount {
                            expectedPaycheckRow(
                                paycheck: paycheck,
                                amount: amount,
                                isLast: visibleEvents.isEmpty
                            )
                        }

                        ForEach(
                            Array(visibleEvents.enumerated()),
                            id: \.element.id
                        ) { index, event in
                            eventRow(
                                event,
                                data: data,
                                isLast: index == visibleEvents.count - 1
                            )
                        }

                        if data.result.events.count > 3 {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showingAllUpcomingActivity.toggle()
                                }
                            } label: {
                                HStack {
                                    Text(showingAllUpcomingActivity ? "Show fewer" : "Show all \(data.result.events.count)")
                                        .font(NwTypography.bodyEmphasis)
                                    Spacer()
                                    Image(systemName: showingAllUpcomingActivity ? "chevron.up" : "chevron.down")
                                        .font(NwTypography.footnoteEm)
                                }
                                .foregroundStyle(NwAppColors.primary)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .padding(.horizontal, NwSpacing.sm)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func eventRow(
        _ event: CashProjectionEvent,
        data: ProjectionData,
        isLast: Bool
    ) -> some View {
        let payment = event.kind == .cardPayment
            ? data.paymentEstimates.first { $0.id == event.id }
            : nil
        let row = timelineEventContent(
            event,
            data: data,
            showsInfo: payment != nil,
            isLast: isLast
        )

        if let payment {
            Button {
                selectedPayment = CardPaymentDetailSelection(
                    payment: payment,
                    transactions: data.cardActivityByPaymentID[payment.id]
                        ?? [],
                    bankCandidates:
                        data.overdueCandidatesByPaymentID[payment.id] ?? []
                )
            } label: { row }
                .buttonStyle(.plain)
                .accessibilityHint("Shows autopay details")
        } else if event.source == .detectedPaycheck {
            Button {
                showingPaycheckSchedule = true
            } label: { row }
                .buttonStyle(.plain)
                .accessibilityHint("Adjusts the detected paycheck schedule")
        } else if event.source == .recurringExpectation,
                  let sourceID = event.sourceID,
                  let expectationID = UUID(uuidString: sourceID),
                  let expectation = recurringExpectations.first(where: {
                      $0.id == expectationID
                  }) {
            Button {
                editingRecurringIncome = expectation
            } label: { row }
                .buttonStyle(.plain)
                .accessibilityHint("Edits recurring income")
        } else {
            row
        }
    }

    private func expectedPaycheckRow(
        paycheck: DetectedPaycheck,
        amount: Money,
        isLast: Bool
    ) -> some View {
        Button {
            showingPaycheckSchedule = true
        } label: {
            HStack(alignment: .top, spacing: NwSpacing.md) {
                timelineMarker(
                    icon: .awaiting,
                    color: NwAppColors.caution,
                    isLast: isLast
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text("TODAY · AWAITING")
                        .font(NwTypography.caption)
                        .foregroundStyle(NwAppColors.caution)
                    Text(paycheck.displayName)
                        .font(NwTypography.bodyEmphasis)
                        .foregroundStyle(NwAppColors.textPrimary)
                        .lineLimit(1)
                }
                Spacer(minLength: NwSpacing.sm)
                NwAmountText(
                    amount,
                    variant: .body,
                    color: NwAppColors.textSecondary
                )
            }
            .padding(.vertical, NwSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Adjusts the detected paycheck schedule")
    }

    private func timelineEventContent(
        _ event: CashProjectionEvent,
        data: ProjectionData,
        showsInfo: Bool,
        isLast: Bool
    ) -> some View {
        let color = event.amount.isNegative
            ? NwAppColors.liability
            : NwAppColors.positive
        // A card payment dated today is a past-due debit being held against
        // cash until it clears the paying account.
        let awaitingClearance = event.kind == .cardPayment
            && event.date <= Calendar.current.startOfDay(for: .now)
        return HStack(alignment: .top, spacing: NwSpacing.md) {
            timelineMarker(
                icon: timelineIcon(event),
                color: awaitingClearance ? NwAppColors.caution : color,
                isLast: isLast
            )
            VStack(alignment: .leading, spacing: 2) {
                if awaitingClearance {
                    Text("Waiting to clear")
                        .font(NwTypography.caption)
                        .foregroundStyle(NwAppColors.caution)
                } else {
                    Text(
                        event.date,
                        format: .dateTime.month(.abbreviated).day()
                            .weekday(.abbreviated)
                    )
                    .font(NwTypography.caption)
                    .foregroundStyle(NwAppColors.textSecondary)
                }
                HStack(spacing: NwSpacing.xs) {
                    Text(event.title)
                        .font(NwTypography.bodyEmphasis)
                        .foregroundStyle(NwAppColors.textPrimary)
                        .lineLimit(1)
                    if showsInfo {
                        NwIcon.info.image
                            .font(NwTypography.footnote)
                            .foregroundStyle(NwAppColors.primary)
                    }
                }
                if let label = eventSourceLabel(event, data: data) {
                    Text(label)
                        .font(NwTypography.caption)
                        .foregroundStyle(NwAppColors.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: NwSpacing.sm)
            NwAmountText(event.amount, variant: .body, color: color)
        }
        .padding(.vertical, NwSpacing.sm)
        .contentShape(Rectangle())
    }

    private func timelineMarker(
        icon: NwIcon,
        color: Color,
        isLast: Bool
    ) -> some View {
        VStack(spacing: NwSpacing.xs) {
            ZStack {
                Circle().fill(color.opacity(0.14))
                icon.image
                    .font(NwTypography.footnoteEm)
                    .foregroundStyle(color)
            }
            .frame(width: 34, height: 34)
            if !isLast {
                Rectangle()
                    .fill(NwAppColors.strokeSubtle)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: 34)
        .accessibilityHidden(true)
    }

    private func timelineIcon(_ event: CashProjectionEvent) -> NwIcon {
        switch event.kind {
        case .scheduledIncome, .transferIn:
            return .cashIn
        case .cardPayment:
            return .creditCard
        case .scheduledExpense, .transferOut:
            return .cashOut
        }
    }

    private func eventSourceLabel(
        _ event: CashProjectionEvent,
        data: ProjectionData
    ) -> String? {
        switch event.source {
        case .detectedPaycheck:
            return data.paycheckScheduleOverride == nil
                ? "Detected paycheck"
                : "Adjusted paycheck"
        case .recurringExpectation:
            return event.amount > .zero ? "Recurring income" : nil
        case nil:
            return nil
        }
    }

    private func activePaycheckOverride(
        for paycheck: DetectedPaycheck
    ) -> DurableIncomePatternOverride? {
        incomePatternOverrides
            .filter {
                $0.scheduleOverrideEnabled
                    && $0.payeeKey == paycheck.payeeKey
                    && $0.nextPaydayAt != nil
            }
            .max { $0.updatedAt < $1.updatedAt }
    }

    // MARK: - Data

    fileprivate struct ProjectionData: Sendable {
        let result: CashPositionProjector.Result
        let paymentEstimates: [UpcomingCardPayment]
        let cardActivityByPaymentID: [String: [TransactionSummary]]
        /// Paying-account outflows a user can pick as the actual debit for
        /// an overdue, still-unsettled payment, keyed by payment id.
        let overdueCandidatesByPaymentID: [String: [TransactionSummary]]
        let selectedCashAccounts: [AccountSnapshot]
        let missingCardNames: [String]
        let unfundedCardNames: [String]
        let excludedCategoryNames: [String]
        let limitedHistory: Bool
        /// The detected paycheck source, when available.
        let paycheckDetection: PaycheckDetection?
        /// Payee of the manual recurring-income entry that overrides the
        /// detected paycheck, when one matched.
        let paycheckManualOverridePayee: String?
        let hasManualIncome: Bool
        let paycheckScheduleOverride: PaycheckScheduleOverride?
        let expectedTodayPaycheckAmount: Money?

        var setupIncomplete: Bool {
            !missingCardNames.isEmpty || !unfundedCardNames.isEmpty
        }

        /// Shown when the projection includes no future paychecks at all:
        /// nothing detected and no manual recurring income to fall back on.
        var incomeWarning: (title: String, message: String)? {
            guard !hasManualIncome, let paycheckDetection else { return nil }
            switch paycheckDetection {
            case .detected:
                return nil
            case .staleHistory(let payeeName, let lastDepositDate):
                return (
                    "Income not projected",
                    "No confirmed deposit from \(payeeName) since \(lastDepositDate.formatted(.dateTime.month(.abbreviated).day())). Confirm recent deposits or add recurring income in Settings."
                )
            case .depositsExcluded(let payeeName):
                return (
                    "Income not projected",
                    "\(payeeName) deposits go to accounts left out of projections. Include that account or add recurring income in Settings."
                )
            case .insufficientHistory(let payeeName, let depositCount):
                let source = payeeName.map { " from \($0)" } ?? ""
                return (
                    "Income not projected",
                    "Only \(depositCount) confirmed deposit\(depositCount == 1 ? "" : "s")\(source) so far. Add recurring income in Settings or keep confirming deposits."
                )
            case .unstableCadence(let payeeName, _):
                return (
                    "Income not projected",
                    "\(payeeName) deposits don't follow a steady schedule. Add recurring income in Settings."
                )
            case .noConfirmedIncome:
                return (
                    "Income not projected",
                    "No confirmed income deposits yet. Add recurring income in Settings."
                )
            }
        }

        var canShowSpendingRoomDetails: Bool {
            !setupIncomplete
                && !limitedHistory
                && result.accountShortfalls.isEmpty
                && result.safeToSpend != nil
        }

        var canLeadWithSpendingRoom: Bool {
            guard canShowSpendingRoomDetails,
                  result.status == .covered,
                  let estimate = result.safeToSpend else { return false }
            return estimate.amount > .zero
        }

        var primaryPaymentAccountShortfall: CashAccountProjection? {
            result.paymentAccountShortfalls.first
        }

        var primaryOtherAccountShortfall: CashAccountProjection? {
            result.accountShortfalls.first { !$0.fundsCardPayments }
        }

        var aggregateCashShortfall: Bool {
            if limitedHistory { return result.knownLowPoint?.balance.isNegative == true }
            return result.status == .shortfall
        }

        var showsPaymentFundingHeadline: Bool {
            primaryPaymentAccountShortfall != nil && !aggregateCashShortfall
        }

        var showsTightBufferHeadline: Bool {
            !setupIncomplete
                && !showsPaymentFundingHeadline
                && result.status == .tight
        }

        var protectsSpendingReserves: Bool {
            (result.safeToSpend?.spendingReserve ?? .zero) > .zero
        }

        var protectionGapLabel: String {
            protectsSpendingReserves ? "Protected cash gap" : "Buffer gap"
        }

        var firstBufferBreachPoint: CashPositionPoint? {
            guard let protectedCash = result.safeToSpend?
                .protectedCashMinimum else { return nil }
            return result.expectedPoints.first {
                $0.balance < protectedCash
            }
        }

        var startsBelowBuffer: Bool {
            guard let firstPoint = result.expectedPoints.first,
                  let breachPoint = firstBufferBreachPoint else { return false }
            return firstPoint.date == breachPoint.date
        }

        var headlineAmount: Money? {
            if setupIncomplete { return nil }
            if showsPaymentFundingHeadline { return primaryPaymentAccountShortfall?.fundingNeeded }
            if result.status == .tight {
                return result.safeToSpend?.protectedCashGap
            }
            return aggregateHeadlinePoint?.balance
        }

        var headlineAmountLabel: String {
            if showsPaymentFundingHeadline { return "Transfer needed" }
            if result.status == .tight { return protectionGapLabel }
            if aggregateCashShortfall { return "Projected balance" }
            return "Projected low"
        }

        var headlineSubtitle: String? {
            if setupIncomplete { return nil }
            if showsPaymentFundingHeadline, let account = primaryPaymentAccountShortfall {
                guard let lowPoint = account.projectedShortfallLowPoint else { return nil }
                return "\(account.accountName) reaches \(CurrencyFormatter.compact(lowPoint.balance)) on \(lowPoint.date.formatted(.dateTime.month(.abbreviated).day()))."
            }
            guard let point = aggregateHeadlinePoint else { return nil }
            if aggregateCashShortfall {
                return "First negative projected balance on \(point.date.formatted(.dateTime.month(.abbreviated).day()))"
            }
            if result.status == .tight {
                let gap = result.safeToSpend?.protectedCashGap ?? .zero
                return "Falls as much as \(CurrencyFormatter.compact(gap)) below on \(point.date.formatted(.dateTime.month(.abbreviated).day()))"
            }
            return "Lowest projected total \(point.date.formatted(.dateTime.month(.abbreviated).day()))"
        }

        var headlineExplanation: String? {
            if setupIncomplete {
                return "Finish card timing and payment accounts first."
            }
            if showsPaymentFundingHeadline, let account = primaryPaymentAccountShortfall {
                let cause = account.lowPointEvent.map {
                    "After \($0.title) of \(CurrencyFormatter.compact($0.amount.absolute)). "
                } ?? ""
                return "\(cause)Total selected cash can cover known commitments, but at least \(CurrencyFormatter.compact(account.fundingNeeded)) must be in \(account.accountName) before then."
            }
            if limitedHistory {
                if aggregateCashShortfall,
                   let cause = result.knownFirstShortfallEvent {
                    return "Based on known commitments only. After \(cause.title) of \(CurrencyFormatter.compact(cause.amount.absolute)), selected cash turns negative. At least 30 days of spending history is required to add everyday spending."
                }
                return "Only known commitments are included. At least 30 days of spending history is required to add everyday spending."
            }
            let firstShortfallCause = result.expectedFirstShortfallEvent
            if aggregateCashShortfall, let cause = firstShortfallCause {
                return "After \(cause.title) of \(CurrencyFormatter.compact(cause.amount.absolute)), selected cash turns negative."
            }
            if aggregateCashShortfall {
                return "Expected commitments and everyday spending bring selected cash below zero."
            }
            if let cause = result.lowPointEvent {
                return "After \(cause.title) of \(CurrencyFormatter.compact(cause.amount.absolute)), selected cash reaches its projected low."
            }
            if result.status == .tight {
                return protectsSpendingReserves
                    ? "Expected commitments and everyday spending bring selected cash below the amount protecting your cash buffer and Spending Reserves."
                    : "Expected commitments and everyday spending bring selected cash below your cash buffer."
            }
            return nil
        }

        var headlineTitle: String {
            if showsPaymentFundingHeadline, let account = primaryPaymentAccountShortfall,
               let date = account.firstShortfallPoint?.date {
                return "Move \(CurrencyFormatter.compact(account.fundingNeeded)) to \(account.accountName) by \(date.formatted(.dateTime.month(.abbreviated).day()))"
            }
            if setupIncomplete { return "Cash outlook needs setup" }
            if limitedHistory {
                guard result.knownLowPoint != nil else { return "Known commitments only" }
                if let firstShortfall = result.knownFirstShortfallPoint {
                    return "Known cash turns negative on \(firstShortfall.date.formatted(.dateTime.month(.abbreviated).day()))"
                }
                return "Known commitments covered through \(result.horizonEnd.formatted(.dateTime.month(.abbreviated).day()))"
            }
            guard let low = result.expectedLowPoint else { return "No outlook available" }
            switch result.status {
            case .covered:
                return "Covered through \(result.horizonEnd.formatted(.dateTime.month(.abbreviated).day()))"
            case .tight:
                let protectedCash = result.safeToSpend.map {
                    CurrencyFormatter.compact($0.protectedCashMinimum)
                } ?? "your"
                let label = protectsSpendingReserves
                    ? "protected cash" : "buffer"
                if startsBelowBuffer {
                    return "Below \(protectedCash) \(label) now"
                }
                if let breach = firstBufferBreachPoint {
                    return "Below \(protectedCash) \(label) on \(breach.date.formatted(.dateTime.month(.abbreviated).day()))"
                }
                return "Below \(protectedCash) \(label)"
            case .shortfall:
                let date = result.expectedFirstShortfallPoint?.date ?? low.date
                return "Cash turns negative on \(date.formatted(.dateTime.month(.abbreviated).day()))"
            }
        }

        private var aggregateHeadlinePoint: CashPositionPoint? {
            if limitedHistory {
                return result.knownFirstShortfallPoint ?? result.knownLowPoint
            }
            if result.status == .shortfall {
                return result.expectedFirstShortfallPoint ?? result.expectedLowPoint
            }
            return result.expectedLowPoint
        }

        var statusColor: Color {
            if showsPaymentFundingHeadline { return NwAppColors.caution }
            if setupIncomplete || limitedHistory { return NwAppColors.caution }
            switch result.status {
            case .covered: return NwAppColors.positive
            case .tight: return NwAppColors.caution
            case .shortfall: return NwAppColors.liability
            }
        }

    }

    private var availableAccountSnapshots: [AccountSnapshot] {
        financialAccounts
            .filter { !$0.deleted }
            .map { $0.toAccountSnapshot() }
    }

    /// Display-only: the buffer amount referenced by chart labels. The
    /// forecast itself reads this from settings inside the data actor.
    private var minimumCashBuffer: Money {
        Money(milliunits: userSettings.first?.dipThresholdMilliunits ?? 500_000)
    }

    private var isStale: Bool {
        guard let date = userSettings.first?.lastSyncedAt else { return false }
        return Date.now.timeIntervalSince(date) > 24 * 60 * 60
    }
    private var lastUpdatedText: String {
        guard let date = userSettings.first?.lastSyncedAt else { return "never" }
        return date.formatted(.relative(presentation: .named))
    }
}

private struct SafeToSpendDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppContainerController.self) private var container
    @Query private var categoryGroups: [DurableCategoryGroup]
    @Query private var canonicalCategories: [DurableCanonicalCategory]
    @Query private var statementAssignmentRows: [DurableCardStatementAssignment]
    let data: ProjectionsView.ProjectionData
    let estimate: SafeToSpendEstimate

    private enum Segment: String, CaseIterable, Identifiable {
        case drivers
        case cycle
        case ledger

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    private enum LockedKind: Hashable {
        case cardAutopays
        case bills
        case income
    }

    @State private var segment: Segment = .drivers
    @State private var expandedLocked: Set<LockedKind> = []

    private let calendar = Calendar.current

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NwSpacing.lg) {
                    hero
                    NwSegmentedSelector(
                        options: Segment.allCases,
                        selection: $segment,
                        title: { $0.title }
                    )
                    .accessibilityLabel("Spending Room view")
                    switch segment {
                    case .drivers: driversSegment
                    case .cycle: cycleSegment
                    case .ledger: ledgerSegment
                    }
                }
                .padding(.horizontal, NwSpacing.screenPadding)
                .padding(.vertical, NwSpacing.lg)
            }
            .nwFrostedFieldBackground()
            .navigationTitle("Spending Room")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(
                for: SpendingRoomDrivers.GroupSpending.self
            ) { group in
                SpendingRoomGroupDetail(
                    title: group.name,
                    categories: SpendingRoomDrivers.categoryAverages(
                        groupId: group.id,
                        samples: data.result.expectedSpend.monthlySamples,
                        groupIdForCategory: groupIdForCategory(context: groupContext)
                    ),
                    currentMonth: data.result.expectedSpend.currentMonth
                )
            }
            .navigationDestination(
                for: SpendingRoomDrivers.CategorySpending.self
            ) { category in
                SpendingRoomCategoryDetail(
                    title: category.name,
                    monthCount: data.result.expectedSpend.monthlySamples.count,
                    average: category.monthlyAverage,
                    thisMonth: SpendingRoomDrivers.currentMonthTotal(
                        categoryId: category.id,
                        currentMonth: data.result.expectedSpend.currentMonth
                    ),
                    payees: SpendingRoomDrivers.payeeSummaries(
                        categoryId: category.id,
                        samples: data.result.expectedSpend.monthlySamples
                    )
                )
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        NwIcon.close.image.foregroundStyle(NwAppColors.liability)
                    }
                }
            }
        }
        .nwGlassSheet()
    }

    // MARK: Hero

    private var hero: some View {
        NwCard(style: .primary) {
            HStack(alignment: .center) {
                NwAmountText(
                    estimate.amount,
                    variant: .hero,
                    showCents: false,
                    color: estimate.amount.isZero
                        ? NwAppColors.caution
                        : NwAppColors.positive
                )
                Spacer()
                VStack(spacing: 0) {
                    Text("Through:")
                        .font(NwTypography.caption)
                        .foregroundStyle(NwAppColors.textSecondary)
                    Text(lowPointDateText)
                        .font(NwTypography.display)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Spending Room \(CurrencyFormatter.compact(estimate.amount)) through \(lowPointDateText)"
        )
    }

    // MARK: Drivers

    private var driversSegment: some View {
        VStack(alignment: .leading, spacing: NwSpacing.lg) {
            spendingSection
            lockedInSection
        }
    }

    private var groupContext: SpendingEntryPipeline.Context {
        SpendingEntryPipeline.Context(
            groups: categoryGroups,
            categories: canonicalCategories,
            accounts: []
        )
    }

    private func groupIdForCategory(
        context: SpendingEntryPipeline.Context
    ) -> (String) -> String? {
        { categoryId in
            let resolved = context.resolvedGroup(
                categoryCanonicalId: categoryId
            )
            return resolved.identity == SpendingGroupSetup.unassignedIdentity
                ? nil
                : resolved.identity
        }
    }

    private var groupSpending: [SpendingRoomDrivers.GroupSpending] {
        let context = groupContext
        return SpendingRoomDrivers.groupAverages(
            samples: data.result.expectedSpend.monthlySamples,
            groupIdForCategory: groupIdForCategory(context: context),
            nameForGroup: { identity in
                context.groupByIdentity[identity]?.name ?? "Group"
            }
        )
    }

    private var spendingSection: some View {
        let groups = groupSpending
        let total = groups.map(\.monthlyAverage).sum()
        let maxAverage = groups.first?.monthlyAverage ?? .zero
        return VStack(alignment: .leading, spacing: NwSpacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your Spending")
                    .font(NwTypography.titleSmall)
                Spacer()
                if !groups.isEmpty {
                    Text("\(CurrencyFormatter.compact(total))/mo average")
                        .font(NwTypography.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if groups.isEmpty {
                NwInlineNotice("No everyday spending sampled yet", tone: .info)
            } else {
                NwCard(style: .primary, padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(groups) { group in
                            NavigationLink(value: group) {
                                groupRow(group, maxAverage: maxAverage)
                            }
                            .buttonStyle(.plain)
                            if group.id != groups.last?.id {
                                Divider().padding(.leading, NwSpacing.md)
                            }
                        }
                    }
                }
            }
        }
    }

    private func groupRow(
        _ group: SpendingRoomDrivers.GroupSpending,
        maxAverage: Money
    ) -> some View {
        HStack(spacing: NwSpacing.md) {
            VStack(alignment: .leading, spacing: NwSpacing.xs) {
                Text(group.name)
                    .font(NwTypography.bodyEmphasis)
                GeometryReader { geometry in
                    Capsule()
                        .fill(NwAppColors.primary)
                        .frame(width: geometry.size.width * shareOfLargest(
                            group.monthlyAverage,
                            largest: maxAverage
                        ))
                }
                .frame(height: 5)
            }
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                NwAmountText(
                    group.monthlyAverage,
                    variant: .body,
                    showCents: false
                )
                Text("/mo")
                    .font(NwTypography.caption)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(NwTypography.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(NwSpacing.md)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows sampled transactions for this group")
    }

    private func shareOfLargest(_ amount: Money, largest: Money) -> CGFloat {
        guard largest > .zero else { return 0 }
        return CGFloat(max(0, min(1, amount.doubleValue / largest.doubleValue)))
    }

    private var lockedInSection: some View {
        VStack(alignment: .leading, spacing: NwSpacing.md) {
            Text("Locked In")
                .font(NwTypography.titleSmall)
            lockedCard(kinds: lockedKinds)
        }
    }

    private var lockedKinds: [LockedKind] {
        var kinds: [LockedKind] = []
        if !estimate.cardPaymentOutflows.isZero { kinds.append(.cardAutopays) }
        if !estimate.scheduledOutflows.isZero { kinds.append(.bills) }
        if !estimate.knownInflows.isZero { kinds.append(.income) }
        return kinds
    }

    @ViewBuilder
    private func lockedCard(kinds: [LockedKind]) -> some View {
        if kinds.isEmpty {
            NwInlineNotice("No dated activity before the low", tone: .info)
        } else {
            NwCard(style: .primary, padding: 0) {
                VStack(spacing: 0) {
                    ForEach(kinds, id: \.self) { kind in
                        lockedRow(kind)
                        if kind != kinds.last {
                            Divider().padding(.leading, NwSpacing.md)
                        }
                    }
                }
            }
        }
    }

    private func lockedEvents(_ kind: LockedKind) -> [CashProjectionEvent] {
        switch kind {
        case .cardAutopays:
            return estimate.contributingEvents
                .filter { $0.kind == .cardPayment }
        case .bills:
            return estimate.contributingEvents
                .filter { $0.amount.isNegative && $0.kind != .cardPayment }
        case .income:
            return estimate.contributingEvents.filter { $0.amount > .zero }
        }
    }

    private func lockedTitle(_ kind: LockedKind) -> String {
        switch kind {
        case .cardAutopays: return "Card autopays"
        case .bills: return "Bills"
        case .income:
            let events = lockedEvents(.income)
            return events.count == 1 ? events[0].title : "Income"
        }
    }

    private func lockedSubtitle(_ kind: LockedKind) -> String {
        let events = lockedEvents(kind)
        switch kind {
        case .cardAutopays, .bills:
            return events.count == 1
                ? "1 payment"
                : "\(events.count) payments"
        case .income:
            if events.count == 1 {
                return events[0].date.formatted(
                    .dateTime.weekday(.abbreviated).month(.abbreviated).day()
                )
            }
            return "\(events.count) deposits"
        }
    }

    private func lockedAmount(_ kind: LockedKind) -> Money {
        switch kind {
        case .cardAutopays: return -estimate.cardPaymentOutflows
        case .bills: return -estimate.scheduledOutflows
        case .income: return estimate.knownInflows
        }
    }

    private func lockedRow(_ kind: LockedKind) -> some View {
        let isExpanded = expandedLocked.contains(kind)
        let amount = lockedAmount(kind)
        return VStack(spacing: 0) {
            Button {
                withAnimation(.snappy) {
                    if isExpanded {
                        expandedLocked.remove(kind)
                    } else {
                        expandedLocked.insert(kind)
                    }
                }
            } label: {
                HStack(spacing: NwSpacing.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lockedTitle(kind))
                            .font(NwTypography.bodyEmphasis)
                        Text(lockedSubtitle(kind))
                            .font(NwTypography.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    NwAmountText(
                        amount,
                        variant: .body,
                        showCents: false,
                        color: amount.isNegative
                            ? NwAppColors.liability
                            : NwAppColors.positive
                    )
                    Image(systemName: "chevron.right")
                        .font(NwTypography.caption)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(NwSpacing.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the individual dated amounts")
            if isExpanded {
                ForEach(lockedEvents(kind)) { event in
                    Divider().padding(.leading, NwSpacing.lg)
                    HStack(spacing: NwSpacing.md) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.title)
                                .font(NwTypography.callout)
                            Text(
                                event.date,
                                format: .dateTime.weekday(.abbreviated)
                                    .month(.abbreviated).day()
                            )
                            .font(NwTypography.footnote)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        NwAmountText(event.amount, variant: .signed)
                    }
                    .padding(.vertical, NwSpacing.sm)
                    .padding(.leading, NwSpacing.lg)
                    .padding(.trailing, NwSpacing.md)
                }
            }
        }
    }

    // MARK: Cycle

    private var cycleSegment: some View {
        VStack(alignment: .leading, spacing: NwSpacing.lg) {
            creditCardsSection
            cashSection
        }
    }

    private var cycleSummary: SpendingRoomCardCycle.Summary? {
        let assignments = statementAssignmentRows.map(\.coreAssignment)
        let forecaster = CCPaymentForecaster(calendar: calendar)
        var openCharges: [String: Money] = [:]
        for payment in data.paymentEstimates
        where payment.basis == .closedStatementEstimate {
            let reconciliation = forecaster.reconciliation(
                for: payment,
                transactions: data.cardActivityByPaymentID[payment.id] ?? [],
                statementAssignments: assignments,
                asOf: .now
            )
            openCharges[payment.cardAccountId, default: .zero]
                += reconciliation.newPurchases
        }
        return SpendingRoomCardCycle.summarize(
            payments: data.paymentEstimates,
            openChargesByCardId: openCharges,
            asOf: .now,
            calendar: calendar
        )
    }

    private var creditCardsSection: some View {
        VStack(alignment: .leading, spacing: NwSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Credit Cards")
                    .font(NwTypography.titleSmall)
                Text("Spend now, pay next month")
                    .font(NwTypography.footnote)
                    .foregroundStyle(.secondary)
            }
            if let summary = cycleSummary {
                NwCard(style: .primary, padding: 0) {
                    VStack(spacing: 0) {
                        if summary.hasClosed {
                            cycleClosedRow(summary)
                        }
                        if summary.openEarliestCloseDate != nil {
                            if summary.hasClosed {
                                Divider().padding(.leading, NwSpacing.md)
                            }
                            cycleOpenRow(summary)
                        }
                        if summary.hasNext {
                            Divider().padding(.leading, NwSpacing.md)
                            cycleNextRow(summary)
                        }
                    }
                }
            } else {
                NwInlineNotice("No card payments projected", tone: .info)
            }
        }
    }

    private func cycleClosedRow(
        _ summary: SpendingRoomCardCycle.Summary
    ) -> some View {
        HStack(spacing: NwSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Closed statements")
                    .font(NwTypography.bodyEmphasis)
                Text(cycleClosedSubtitle(summary))
                    .font(NwTypography.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            NwAmountText(
                -summary.closedTotal,
                variant: .body,
                showCents: false,
                color: NwAppColors.liability
            )
        }
        .padding(NwSpacing.md)
    }

    private func cycleClosedSubtitle(
        _ summary: SpendingRoomCardCycle.Summary
    ) -> String {
        let count = summary.closedCount == 1
            ? "1 statement"
            : "\(summary.closedCount) statements"
        guard let due = summary.closedLatestDueDate else { return count }
        return "\(count) · autopay by \(shortDate(due))"
    }

    private func cycleOpenRow(
        _ summary: SpendingRoomCardCycle.Summary
    ) -> some View {
        let typical = data.result.expectedSpend.unscheduledMonthlyAmount
        return HStack(alignment: .top, spacing: NwSpacing.md) {
            VStack(alignment: .leading, spacing: NwSpacing.xs) {
                Text("Open statements")
                    .font(NwTypography.bodyEmphasis)
                if let close = summary.openLatestCloseDate {
                    Text("Close by \(shortDate(close))")
                        .font(NwTypography.footnote)
                        .foregroundStyle(.secondary)
                }
                if typical > .zero {
                    cyclePaceBar(
                        soFar: summary.openChargesSoFar,
                        typical: typical,
                        elapsed: summary.cycleElapsedFraction
                    )
                }
            }
            Spacer()
            NwAmountText(
                summary.openChargesSoFar,
                variant: .body,
                showCents: false
            )
        }
        .padding(NwSpacing.md)
    }

    private func cyclePaceBar(
        soFar: Money,
        typical: Money,
        elapsed: Double?
    ) -> some View {
        HStack(spacing: NwSpacing.sm) {
            NwPaceBar(
                fillFraction: typical > .zero
                    ? soFar.doubleValue / typical.doubleValue
                    : 0,
                markerFraction: elapsed
            )
            .frame(width: 120, height: 6)
            Text("typical \(CurrencyFormatter.compact(typical))")
                .font(NwTypography.micro)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(CurrencyFormatter.compact(soFar)) so far against a typical month of \(CurrencyFormatter.compact(typical))"
        )
    }

    private func cycleNextRow(
        _ summary: SpendingRoomCardCycle.Summary
    ) -> some View {
        HStack(spacing: NwSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Next payments")
                    .font(NwTypography.bodyEmphasis)
                Text(cycleNextSubtitle(summary))
                    .font(NwTypography.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            NwAmountText(
                -summary.nextPaymentsTotal,
                variant: .body,
                showCents: false,
                color: NwAppColors.caution
            )
        }
        .padding(NwSpacing.md)
    }

    private func cycleNextSubtitle(
        _ summary: SpendingRoomCardCycle.Summary
    ) -> String {
        guard let due = summary.nextPaymentsLatestDueDate else {
            return "Estimate"
        }
        return "Due by \(shortDate(due)) · estimate"
    }

    private var cashSection: some View {
        VStack(alignment: .leading, spacing: NwSpacing.md) {
            Text("Cash")
                .font(NwTypography.titleSmall)
            lockedCard(kinds: lockedKinds.filter { $0 != .cardAutopays })
        }
    }

    // MARK: Ledger

    private var ledgerSegment: some View {
        VStack(alignment: .leading, spacing: NwSpacing.lg) {
            cashFlowSection
            spendableSection
        }
    }

    private var ledgerEntries: [SpendingRoomLedger.Entry] {
        SpendingRoomLedger.cashFlowEntries(from: estimate)
    }

    private var cashFlowSection: some View {
        let entries = ledgerEntries
        return VStack(alignment: .leading, spacing: NwSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Cash Flow")
                    .font(NwTypography.titleSmall)
                Text("Through \(lowPointDateText)")
                    .font(NwTypography.footnote)
                    .foregroundStyle(.secondary)
            }
            NwCard(style: .primary) {
                ledgerChart(entries)
            }
            NwCard(style: .primary, padding: 0) {
                VStack(spacing: 0) {
                    ForEach(entries) { entry in
                        ledgerRow(entry)
                        if entry.id != entries.last?.id {
                            Divider().padding(.leading, NwSpacing.lg)
                        }
                    }
                }
            }
        }
    }

    private func ledgerChart(
        _ entries: [SpendingRoomLedger.Entry]
    ) -> some View {
        let maxY = entries.map { $0.barEnd.doubleValue }.max() ?? 1
        let minY = min(entries.map { $0.barStart.doubleValue }.min() ?? 0, 0)
        return Chart(entries) { entry in
            BarMark(
                x: .value("Step", entry.kind.rawValue),
                yStart: .value("From", entry.barStart.doubleValue),
                yEnd: .value("To", entry.barEnd.doubleValue),
                width: .ratio(0.62)
            )
            .foregroundStyle(ledgerColor(entry.kind))
            .cornerRadius(4)
            .annotation(position: .top, spacing: 3) {
                Text(ledgerBarLabel(entry))
                    .font(NwTypography.micro)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .chartXScale(domain: entries.map(\.kind.rawValue))
        .chartYScale(domain: minY...(maxY * 1.14))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 190)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Cash flow from starting cash to the projected low on \(lowPointDateText)"
        )
    }

    private func ledgerBarLabel(_ entry: SpendingRoomLedger.Entry) -> String {
        if entry.isLevel {
            return CurrencyFormatter.compact(entry.amount)
        }
        let sign = entry.amount.isNegative ? "−" : "+"
        return sign + CurrencyFormatter.compact(entry.amount.absolute)
    }

    private func ledgerColor(
        _ kind: SpendingRoomLedger.Entry.Kind
    ) -> Color {
        switch kind {
        case .startingCash, .projectedLow: return NwAppColors.primary
        case .inflows: return NwAppColors.positive
        case .bills, .cardAutopays: return NwAppColors.liability
        case .everydaySpending: return NwAppColors.caution
        }
    }

    private func ledgerLabel(_ kind: SpendingRoomLedger.Entry.Kind) -> String {
        switch kind {
        case .startingCash: return "Starting cash"
        case .inflows: return lockedTitle(.income)
        case .bills: return "Bills"
        case .cardAutopays: return "Card autopays"
        case .everydaySpending:
            return "Everyday spending · \(daysToLow) days"
        case .projectedLow: return "Projected low · \(lowPointDateText)"
        }
    }

    private func ledgerRow(_ entry: SpendingRoomLedger.Entry) -> some View {
        HStack(spacing: NwSpacing.md) {
            Capsule()
                .fill(ledgerColor(entry.kind))
                .frame(width: 4, height: 20)
            Text(ledgerLabel(entry.kind))
                .font(
                    entry.kind == .projectedLow
                        ? NwTypography.bodyEmphasis
                        : NwTypography.callout
                )
            Spacer()
            NwAmountText(
                entry.amount,
                variant: .body,
                showCents: false,
                color: entry.isLevel
                    ? nil
                    : ledgerColor(entry.kind)
            )
        }
        .padding(NwSpacing.md)
        .background(
            entry.kind == .projectedLow
                ? NwAppColors.primary.opacity(0.06)
                : Color.clear
        )
    }

    private var spendableSection: some View {
        let spendable = SpendingRoomLedger.spendable(from: estimate)
        return VStack(alignment: .leading, spacing: NwSpacing.md) {
            Text("Spendable")
                .font(NwTypography.titleSmall)
            NwCard(style: .primary, padding: 0) {
                VStack(spacing: 0) {
                    spendableBar(spendable)
                        .padding(.horizontal, NwSpacing.md)
                        .padding(.top, NwSpacing.md)
                        .padding(.bottom, NwSpacing.sm)
                    spendableRow(
                        "Cash buffer",
                        amount: spendable.cashBuffer,
                        color: NwAppColors.protected
                    )
                    if spendable.reserves > .zero {
                        Divider().padding(.leading, NwSpacing.lg)
                        spendableRow(
                            "Reserves",
                            amount: spendable.reserves,
                            color: NwAppColors.gold
                        )
                    }
                    Divider().padding(.leading, NwSpacing.lg)
                    if spendable.isCovered {
                        spendableRow(
                            "Spending Room",
                            amount: spendable.room,
                            color: NwAppColors.positive,
                            emphasized: true
                        )
                    } else {
                        spendableRow(
                            "Protected cash gap",
                            amount: -spendable.protectedCashGap,
                            color: NwAppColors.liability,
                            emphasized: true
                        )
                    }
                }
            }
        }
    }

    private func spendableBar(
        _ spendable: SpendingRoomLedger.Spendable
    ) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            if spendable.isCovered {
                let total = max(spendable.projectedLowBalance.doubleValue, 0.01)
                HStack(spacing: 2) {
                    Capsule()
                        .fill(NwAppColors.protected)
                        .frame(width: width * segmentShare(
                            spendable.cashBuffer,
                            of: total
                        ))
                    if spendable.reserves > .zero {
                        Capsule()
                            .fill(NwAppColors.gold)
                            .frame(width: width * segmentShare(
                                spendable.reserves,
                                of: total
                            ))
                    }
                    if spendable.room > .zero {
                        Capsule()
                            .fill(NwAppColors.positive)
                            .frame(width: width * segmentShare(
                                spendable.room,
                                of: total
                            ))
                    }
                }
            } else {
                let target = max(
                    (spendable.cashBuffer + spendable.reserves).doubleValue,
                    0.01
                )
                let covered = max(spendable.projectedLowBalance.doubleValue, 0)
                ZStack(alignment: .leading) {
                    Capsule().fill(NwAppColors.liability.opacity(0.2))
                    Capsule()
                        .fill(NwAppColors.caution)
                        .frame(width: width * min(covered / target, 1))
                }
            }
        }
        .frame(height: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spendableBarLabel)
    }

    private var spendableBarLabel: String {
        if estimate.protectedCashGap.isZero {
            return estimate.spendingReserve > .zero
                ? "Cash buffer and Reserves protected"
                : "Cash buffer protected"
        }
        return "\(CurrencyFormatter.compact(estimate.protectedCashGap)) below protected cash"
    }

    private func segmentShare(_ amount: Money, of total: Double) -> CGFloat {
        CGFloat(max(0, min(1, amount.doubleValue / total)))
    }

    private func spendableRow(
        _ label: String,
        amount: Money,
        color: Color,
        emphasized: Bool = false
    ) -> some View {
        HStack(spacing: NwSpacing.md) {
            Capsule()
                .fill(color)
                .frame(width: 4, height: 20)
            Text(label)
                .font(
                    emphasized
                        ? NwTypography.bodyEmphasis
                        : NwTypography.callout
                )
            Spacer()
            NwAmountText(
                amount,
                variant: .body,
                showCents: false,
                color: emphasized ? color : nil
            )
        }
        .padding(NwSpacing.md)
        .background(
            emphasized
                ? color.opacity(0.06)
                : Color.clear
        )
    }

    // MARK: Shared

    private var lowPointDateText: String {
        estimate.lowPointDate.formatted(.dateTime.month(.abbreviated).day())
    }

    private var daysToLow: Int {
        max(
            calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: .now),
                to: calendar.startOfDay(for: estimate.lowPointDate)
            ).day ?? 0,
            0
        )
    }

    private func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// One Spending group's categories: this month's spend against the sampled
/// monthly average.
private struct SpendingRoomGroupDetail: View {
    let title: String
    let categories: [SpendingRoomDrivers.CategorySpending]
    let currentMonth: MonthlySpendSample?

    var body: some View {
        List {
            if categories.isEmpty {
                Text("No spending sampled")
                    .foregroundStyle(.secondary)
            }
            ForEach(categories) { category in
                NavigationLink(value: category) {
                    HStack {
                        Text(category.name)
                        Spacer()
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            NwAmountText(
                                SpendingRoomDrivers.currentMonthTotal(
                                    categoryId: category.id,
                                    currentMonth: currentMonth
                                ),
                                variant: .body,
                                showCents: false
                            )
                            Text("/")
                                .font(NwTypography.caption)
                                .foregroundStyle(.secondary)
                            NwAmountText(
                                category.monthlyAverage,
                                variant: .body,
                                showCents: false,
                                color: NwAppColors.textSecondary
                            )
                        }
                    }
                }
                .accessibilityHint("Shows payees for this category")
            }
        }
        .nwScreenBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One category's payees, one summed line per payee, expandable to the
/// sampled purchases with the shared include/exclude control.
private struct SpendingRoomCategoryDetail: View {
    @Environment(AppContainerController.self) private var container
    @Query private var exclusions: [DurableExcludedSpendTransaction]
    let title: String
    let monthCount: Int
    let average: Money
    let thisMonth: Money
    let payees: [SpendingRoomDrivers.PayeeSpending]

    private var excludedIds: Set<String> {
        Set(exclusions.map(\.transactionId))
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: NwSpacing.sm) {
                    HStack {
                        Text("This month")
                            .font(NwTypography.bodyEmphasis)
                        Spacer()
                        NwAmountText(thisMonth, variant: .body, showCents: false)
                    }
                    if average > .zero {
                        HStack(spacing: NwSpacing.sm) {
                            NwPaceBar(
                                fillFraction: thisMonth.doubleValue
                                    / average.doubleValue,
                                markerFraction: monthElapsedFraction,
                                markerLabel: "\(dayOfMonthToday)",
                                leadingLabel: "1",
                                trailingLabel: "\(daysInCurrentMonth)"
                            )
                            .frame(height: 6)
                            Text("avg \(CurrencyFormatter.compact(average))/mo")
                                .font(NwTypography.micro)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.bottom, 16)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            "\(CurrencyFormatter.compact(thisMonth)) spent this month against an average of \(CurrencyFormatter.compact(average)), on day \(dayOfMonthToday) of \(daysInCurrentMonth)"
                        )
                    }
                }
            }
            if payees.isEmpty {
                Text("No spending sampled")
                    .foregroundStyle(.secondary)
            }
            ForEach(payees) { payee in
                DisclosureGroup {
                    ForEach(payee.transactions) { transaction in
                        row(transaction)
                            .swipeActions(
                                edge: .trailing,
                                allowsFullSwipe: true
                            ) {
                                Button {
                                    toggleSpendExclusion(
                                        transaction,
                                        container: container
                                    )
                                } label: {
                                    Label(
                                        isExcluded(transaction)
                                            ? "Include" : "Exclude",
                                        systemImage: isExcluded(transaction)
                                            ? "arrow.uturn.backward"
                                            : "minus.circle"
                                    )
                                }
                                .tint(
                                    isExcluded(transaction)
                                        ? NwAppColors.positive
                                        : NwAppColors.liability
                                )
                            }
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(payee.name)
                                .font(NwTypography.bodyEmphasis)
                            Text(purchasesLabel(payee))
                                .font(NwTypography.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            NwAmountText(
                                liveAverage(payee),
                                variant: .body,
                                showCents: false
                            )
                            Text("/mo")
                                .font(NwTypography.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .nwScreenBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func isExcluded(_ transaction: MonthlySpendTransaction) -> Bool {
        transaction.excluded || excludedIds.contains(transaction.id)
    }

    private var dayOfMonthToday: Int {
        Calendar.current.component(.day, from: .now)
    }

    private var daysInCurrentMonth: Int {
        Calendar.current.range(of: .day, in: .month, for: .now)?.count ?? 30
    }

    private var monthElapsedFraction: Double? {
        Double(dayOfMonthToday) / Double(daysInCurrentMonth)
    }

    /// Average recomputed against the live exclusion set so a swipe updates
    /// the payee line immediately, before the projection refreshes.
    private func liveAverage(
        _ payee: SpendingRoomDrivers.PayeeSpending
    ) -> Money {
        guard monthCount > 0 else { return .zero }
        let total = payee.transactions
            .filter { !isExcluded($0) }
            .map(\.amount)
            .sum()
        return Money(milliunits: total.milliunits / Int64(monthCount))
    }

    private func purchasesLabel(
        _ payee: SpendingRoomDrivers.PayeeSpending
    ) -> String {
        let count = payee.transactions.filter { !isExcluded($0) }.count
        return count == 1 ? "1 purchase" : "\(count) purchases"
    }

    private func row(_ transaction: MonthlySpendTransaction) -> some View {
        HStack(spacing: NwSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.payeeName)
                    .foregroundStyle(
                        isExcluded(transaction)
                            ? NwAppColors.textSecondary
                            : NwAppColors.textPrimary
                    )
                    .strikethrough(isExcluded(transaction))
                Text(
                    transaction.date,
                    format: .dateTime.month(.abbreviated).day().year()
                )
                .font(NwTypography.footnote)
                .foregroundStyle(.secondary)
            }
            Spacer()
            NwAmountText(
                transaction.amount,
                variant: .body,
                color: isExcluded(transaction)
                    ? NwAppColors.textSecondary
                    : nil
            )
        }
    }
}

/// Toggles a durable everyday-spending exclusion for one transaction line.
@MainActor
private func toggleSpendExclusion(
    _ transaction: MonthlySpendTransaction,
    container: AppContainerController
) {
    let ctx = container.modelContainer.mainContext
    let transactionId = transaction.id
    let descriptor = FetchDescriptor<DurableExcludedSpendTransaction>(
        predicate: #Predicate { $0.transactionId == transactionId }
    )
    let existing = (try? ctx.fetch(descriptor)) ?? []
    if existing.isEmpty {
        ctx.insert(DurableExcludedSpendTransaction(
            transactionId: transaction.id,
            payeeName: transaction.payeeName,
            transactionDate: transaction.date,
            amountMilliunits: transaction.amount.milliunits
        ))
    } else {
        existing.forEach(ctx.delete)
    }
    if !ctx.safeSave(source: "projection.transactionExclusion.toggle") {
        ctx.rollback()
    }
}

private struct ProjectionAssumptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let data: ProjectionsView.ProjectionData
    let onAdjustPaycheck: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Outlook") {
                    VStack(alignment: .leading, spacing: NwSpacing.sm) {
                        Text(data.headlineTitle)
                            .font(NwTypography.bodyEmphasis)
                            .foregroundStyle(data.statusColor)
                        if let subtitle = data.headlineSubtitle {
                            Text(subtitle)
                                .font(NwTypography.footnote)
                                .foregroundStyle(NwAppColors.textSecondary)
                        }
                        if let explanation = data.headlineExplanation {
                            Text(explanation)
                                .font(NwTypography.callout)
                                .foregroundStyle(NwAppColors.textPrimary)
                        }
                    }
                    .padding(.vertical, NwSpacing.xs)

                    if let amount = data.headlineAmount {
                        detail(data.headlineAmountLabel, CurrencyFormatter.compact(amount))
                    }
                }
                Section("Cash included") {
                    ForEach(data.selectedCashAccounts) { account in
                        HStack {
                            Text(account.name)
                            Spacer()
                            NwAmountText(account.balance, variant: .body)
                        }
                    }
                }
                incomeSection
                Section("Everyday spending estimate") {
                    detail(
                        "Method",
                        data.result.expectedSpend.sampleMonthCount > 0 ? "Average of complete months" : "Daily average fallback"
                    )
                    detail("History used", data.result.expectedSpend.historyDays == 0 ? "Not enough data" : "\(data.result.expectedSpend.historyDays) days")
                    if data.result.expectedSpend.sampleMonthCount > 0 {
                        detail("Complete months", "\(data.result.expectedSpend.sampleMonthCount)")
                    }
                    detail("Estimated month", CurrencyFormatter.compact(data.result.expectedSpend.estimatedMonthlyAmount))
                    if let higherMonth = data.result.expectedSpend.higherSpendMonthlyAmount {
                        detail("Higher-spending month", CurrencyFormatter.compact(higherMonth))
                    }
                    detail("Scheduled portion", CurrencyFormatter.compact(data.result.expectedSpend.scheduledMonthlyAmount))
                    detail("Everyday spending reserve", CurrencyFormatter.compact(data.result.expectedSpend.unscheduledMonthlyAmount))
                    detail("Spending observed", CurrencyFormatter.compact(data.result.expectedSpend.historicalOutflows))
                    if !data.result.expectedSpend.historicalRefunds.isZero {
                        detail("Refunds netted", CurrencyFormatter.compact(data.result.expectedSpend.historicalRefunds))
                    }
                    detail("Overlap removed from reserve", CurrencyFormatter.compact(data.result.expectedSpend.scheduledOutflows))
                    detail("Average per day", CurrencyFormatter.compact(data.result.expectedSpend.dailyAmount))
                }
                if !data.result.expectedSpend.monthlySamples.isEmpty {
                    Section("Monthly samples") {
                        ForEach(data.result.expectedSpend.monthlySamples.reversed()) { sample in
                            NavigationLink {
                                MonthlySpendSampleDetail(sample: sample)
                            } label: {
                                HStack {
                                    Text(sample.month, format: .dateTime.month(.wide).year())
                                    Spacer()
                                    NwAmountText(sample.totalAmount, variant: .body)
                                }
                            }
                        }
                    }
                }
                if !data.excludedCategoryNames.isEmpty {
                    Section("Excluded categories") {
                        ForEach(data.excludedCategoryNames, id: \.self) { name in
                            Text(name)
                        }
                    }
                }
                Section("Known account lows") {
                    ForEach(data.result.accountProjections) { account in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.accountName)
                                Text(account.lowPoint.date, format: .dateTime.month(.abbreviated).day())
                                    .font(NwTypography.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            NwAmountText(
                                account.lowPoint.balance,
                                variant: .body,
                                color: account.lowPoint.balance.isNegative ? NwAppColors.liability : nil
                            )
                        }
                    }
                }
                Section("Method") {
                    Text("Average of complete months · Scheduled outflows separate · Income excluded")
                        .font(NwTypography.callout)
                }
            }
            .nwScreenBackground()
            .navigationTitle("Projection Details")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { NwIcon.close.image.foregroundStyle(NwAppColors.liability) }
                }
            }
        }
        .nwGlassSheet()
    }

    @ViewBuilder
    private var incomeSection: some View {
        if let detection = data.paycheckDetection {
            Section("Income") {
                if let payee = data.paycheckManualOverridePayee {
                    Text("Your recurring income entry for \(payee) overrides the detected paycheck.")
                        .font(NwTypography.callout)
                } else {
                    switch detection {
                    case .detected(let paycheck):
                        let nextDeposit = data.paycheckScheduleOverride?
                            .nextOccurrence(after: .now)
                            ?? paycheck.nextDate
                        detail("Payer", paycheck.displayName)
                        detail(
                            "Cadence",
                            (data.paycheckScheduleOverride?.cadence
                                ?? paycheck.cadence).displayName
                        )
                        detail("Next paycheck", CurrencyFormatter.compact(paycheck.nextAmount))
                        if paycheck.portions.count > 1 {
                            let month = BudgetMonth(containing: paycheck.nextDate)
                            ForEach(paycheck.portions, id: \.accountId) { portion in
                                detail(
                                    accountName(portion.accountId),
                                    CurrencyFormatter.compact(
                                        paycheck.amount(for: portion, in: month)
                                    )
                                )
                            }
                        }
                        detail(
                            "Next deposit",
                            nextDeposit.formatted(
                                .dateTime.month(.abbreviated).day()
                            )
                        )
                        detail("Confirmed deposits", "\(paycheck.confirmedDepositCount)")
                        Button {
                            onAdjustPaycheck()
                        } label: {
                            Label(
                                data.paycheckScheduleOverride == nil
                                    ? "Adjust Schedule"
                                    : "Edit Adjusted Schedule",
                                systemImage: "calendar.badge.clock"
                            )
                        }
                    case .staleHistory(let payeeName, let lastDepositDate):
                        incomeWarningText(
                            "No confirmed deposit from \(payeeName) since \(lastDepositDate.formatted(.dateTime.month(.abbreviated).day())) — paychecks aren't projected until deposits resume."
                        )
                    case .depositsExcluded(let payeeName):
                        incomeWarningText(
                            "\(payeeName) deposits go to accounts left out of projections, so paychecks aren't projected."
                        )
                    case .insufficientHistory(let payeeName, let depositCount):
                        incomeWarningText(
                            "Only \(depositCount) confirmed deposit\(depositCount == 1 ? "" : "s")\(payeeName.map { " from \($0)" } ?? "") — not enough to project paychecks automatically."
                        )
                    case .unstableCadence(let payeeName, _):
                        incomeWarningText(
                            "\(payeeName) deposits don't follow a steady schedule, so paychecks aren't projected automatically."
                        )
                    case .noConfirmedIncome:
                        incomeWarningText(
                            "No confirmed income deposits yet, so paychecks aren't projected."
                        )
                    }
                    if data.hasManualIncome {
                        Text("Projections use your recurring income entries.")
                            .font(NwTypography.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func incomeWarningText(_ message: String) -> some View {
        Text(message)
            .font(NwTypography.callout)
            .foregroundStyle(NwAppColors.caution)
    }

    private func accountName(_ accountId: String) -> String {
        data.selectedCashAccounts.first { $0.id == accountId }?.name
            ?? "Account"
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text(value).foregroundStyle(.secondary) }
    }
}

private struct MonthlySpendSampleDetail: View {
    let sample: MonthlySpendSample

    var body: some View {
        List {
            Section("Summary") {
                detail("Total spending", sample.totalAmount)
                detail("Scheduled portion", sample.scheduledAmount)
                detail("Unscheduled portion", sample.unscheduledAmount)
            }
            Section("Included categories") {
                if sample.categories.isEmpty {
                    Text("No included spending")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sample.categories) { category in
                        NavigationLink {
                            MonthlySpendCategoryDetail(category: category)
                        } label: {
                            HStack {
                                Text(category.categoryName)
                                Spacer()
                                NwAmountText(category.amount, variant: .body)
                            }
                        }
                    }
                }
            }
        }
        .nwScreenBackground()
        .navigationTitle(sample.month.formatted(.dateTime.month(.wide).year()))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func detail(_ label: String, _ amount: Money) -> some View {
        HStack {
            Text(label)
            Spacer()
            NwAmountText(amount, variant: .body)
        }
    }
}

private struct MonthlySpendCategoryDetail: View {
    @Environment(AppContainerController.self) private var container
    @Query private var exclusions: [DurableExcludedSpendTransaction]
    let category: MonthlySpendCategory

    private var excludedIds: Set<String> {
        Set(exclusions.map(\.transactionId))
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Included total")
                    Spacer()
                    NwAmountText(includedTotal, variant: .body)
                }
            }
            Section("Transactions") {
                ForEach(category.transactions) { transaction in
                    if transaction.recurring {
                        transactionRow(transaction)
                    } else {
                        transactionRow(transaction)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button {
                                    toggle(transaction)
                                } label: {
                                    Label(
                                        isExcluded(transaction) ? "Include" : "Exclude",
                                        systemImage: isExcluded(transaction) ? "arrow.uturn.backward" : "minus.circle"
                                    )
                                }
                                .tint(isExcluded(transaction) ? NwAppColors.positive : NwAppColors.liability)
                            }
                    }
                }
            }
        }
        .nwScreenBackground()
        .navigationTitle(category.categoryName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var includedTotal: Money {
        category.transactions
            .filter { !isExcluded($0) }
            .map(\.amount)
            .sum()
    }

    private func isExcluded(_ transaction: MonthlySpendTransaction) -> Bool {
        !transaction.recurring
            && (transaction.excluded || excludedIds.contains(transaction.id))
    }

    private func transactionRow(_ transaction: MonthlySpendTransaction) -> some View {
        HStack(spacing: NwSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.payeeName)
                    .foregroundStyle(isExcluded(transaction) ? NwAppColors.textSecondary : NwAppColors.textPrimary)
                    .strikethrough(isExcluded(transaction))
                Text(transaction.date, format: .dateTime.month(.abbreviated).day())
                    .font(NwTypography.footnote)
                    .foregroundStyle(.secondary)
                    if transaction.recurring {
                    Text("Recurring · removed from everyday reserve")
                        .font(NwTypography.footnote)
                        .foregroundStyle(NwAppColors.accent)
                }
            }
            Spacer()
            NwAmountText(
                transaction.amount,
                variant: .body,
                color: isExcluded(transaction) ? NwAppColors.textSecondary : nil
            )
        }
    }

    private func toggle(_ transaction: MonthlySpendTransaction) {
        toggleSpendExclusion(transaction, container: container)
    }
}

private struct CardPaymentDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppContainerController.self) private var container
    @Query private var confirmationRows: [DurableCardPaymentConfirmation]
    @Query private var statementAssignmentRows:
        [DurableCardStatementAssignment]
    @Query private var settlementRows: [DurableCardPaymentSettlement]
    let payment: UpcomingCardPayment
    let transactions: [TransactionSummary]
    let bankCandidates: [TransactionSummary]

    @State private var showingEditor = false
    @State private var showingUseEstimateConfirmation = false
    @State private var selectedBoundaryTransaction: TransactionSummary?
    @State private var persistenceError: String?

    private let calendar = Calendar.current

    var body: some View {
        NwModalLayout(
            title: payment.cardName,
            onClose: { dismiss() }
        ) {
            NwCard(style: .primary) {
                VStack(spacing: NwSpacing.md) {
                    amountRow(
                        resolved.isConfirmed
                            ? "Scheduled payment"
                            : "Estimated autopay",
                        resolved.amount,
                        color: NwAppColors.liability
                    )
                    Divider()
                    detail(
                        "Payment date",
                        resolved.paymentDate.formatted(
                            date: .abbreviated,
                            time: .omitted
                        )
                    )
                    Divider()
                    detail(
                        "Statement closed",
                        payment.closeDate.formatted(
                            date: .abbreviated,
                            time: .omitted
                        )
                    )
                }
            }

            if isAwaitingClearance {
                if cycleSettlements.isEmpty {
                    Text("Waiting to Clear")
                        .font(NwTypography.titleSmall)

                    if !displayedCandidates.isEmpty {
                        candidatesCard
                    }

                    Button {
                        saveSettlement(transactionId: nil)
                    } label: {
                        Text("Paid from Another Account")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(NwAppColors.primary)
                } else {
                    Text("Marked Paid")
                        .font(NwTypography.titleSmall)

                    Button {
                        removeSettlement()
                    } label: {
                        Text("Not Paid Yet")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(NwAppColors.liability)
                }
            }

            if payment.basis == .closedStatementEstimate {
                if !boundaryTransactions.isEmpty {
                    Text("Around Statement Close")
                        .font(NwTypography.titleSmall)

                    boundaryActivityCard
                }

                Text("Reconciliation")
                    .font(NwTypography.titleSmall)

                NwCard(style: .primary) {
                    VStack(spacing: NwSpacing.md) {
                        amountRow("Current balance", payment.startingBalanceOwed)
                        Divider()
                        amountRow(
                            "New purchases",
                            Money(
                                milliunits:
                                    -reconciliation.newPurchases.milliunits
                            ),
                            color: NwAppColors.textSecondary
                        )
                        if !reconciliation.currentBalanceCredits.isZero {
                            Divider()
                            amountRow(
                                "Current-cycle credits",
                                reconciliation.currentBalanceCredits,
                                color: NwAppColors.textSecondary
                            )
                        }
                        Divider()
                        amountRow("Estimated autopay", payment.amount)
                    }
                }

                Text(
                    "Since \(payment.closeDate.formatted(.dateTime.month(.abbreviated).day()))"
                )
                .font(NwTypography.titleSmall)

                activityCard
            }

            if resolved.isConfirmed {
                Button {
                    showingEditor = true
                } label: {
                    Text("Edit Scheduled Payment")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(NwAppColors.primary)

                Button {
                    showingUseEstimateConfirmation = true
                } label: {
                    Text("Use Estimate")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(NwAppColors.liability)
            } else {
                Button {
                    showingEditor = true
                } label: {
                    Text("Enter Scheduled Payment")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(NwAppColors.primary)
            }
        }
        .sheet(isPresented: $showingEditor) {
            CardPaymentConfirmationSheet(
                initialAmount: resolved.amount,
                initialDate: resolved.paymentDate,
                onSave: saveConfirmation
            )
        }
        .alert(
            "Use Estimate?",
            isPresented: $showingUseEstimateConfirmation
        ) {
            Button("Use Estimate", role: .destructive) {
                removeConfirmation()
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Couldn’t Save Payment",
            isPresented: Binding(
                get: { persistenceError != nil },
                set: { if !$0 { persistenceError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { persistenceError = nil }
        } message: {
            Text(persistenceError ?? "Please try again.")
        }
        .confirmationDialog(
            "Statement Cycle",
            isPresented: Binding(
                get: { selectedBoundaryTransaction != nil },
                set: { if !$0 { selectedBoundaryTransaction = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let transaction = selectedBoundaryTransaction {
                Button(
                    "Statement Closed \(shortDate(payment.closeDate))"
                ) {
                    assign(
                        transaction,
                        to: payment.closeDate
                    )
                }
                Button(
                    "Next Statement \(shortDate(nextStatementCloseDate))"
                ) {
                    assign(
                        transaction,
                        to: nextStatementCloseDate
                    )
                }
                if assignment(for: transaction) != nil {
                    Button("Use Posted Date", role: .destructive) {
                        removeAssignment(for: transaction)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(NwAppColors.textSecondary)
        }
    }

    private func amountRow(
        _ label: String,
        _ amount: Money,
        color: Color = NwAppColors.textPrimary
    ) -> some View {
        HStack {
            Text(label)
            Spacer()
            NwAmountText(
                amount,
                variant: .body,
                showCents: true,
                color: color
            )
        }
    }

    @ViewBuilder
    private var activityCard: some View {
        if reconciliation.activity.isEmpty {
            NwCard(style: .primary) {
                Text("No activity")
                    .foregroundStyle(NwAppColors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            NwCard(style: .primary, padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(reconciliation.activity.enumerated()),
                            id: \.element.id) { index, activity in
                        let transaction = activity.transaction
                        HStack(spacing: NwSpacing.md) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(
                                    transaction.payeeName
                                        ?? transaction.categoryName
                                        ?? "Transaction"
                                )
                                .font(NwTypography.body)
                                .foregroundStyle(NwAppColors.textPrimary)
                                Text(
                                    activityLabel(activity.effect)
                                )
                                .font(NwTypography.caption)
                                .foregroundStyle(NwAppColors.textSecondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                NwAmountText(
                                    transaction.amount,
                                    variant: .body,
                                    showCents: true,
                                    color: transaction.amount.isNegative
                                        ? NwAppColors.liability
                                        : NwAppColors.positive
                                )
                                Text(
                                    transaction.date.formatted(
                                        .dateTime.month(.abbreviated).day()
                                    )
                                )
                                .font(NwTypography.caption)
                                .foregroundStyle(NwAppColors.textSecondary)
                            }
                        }
                        .padding(NwSpacing.md)
                        if index < reconciliation.activity.count - 1 {
                            Divider().padding(.leading, NwSpacing.md)
                        }
                    }
                }
            }
        }
    }

    /// The projected debit date has arrived but no matching outflow settled
    /// on the paying account. Settled payments never reach this sheet — the
    /// projection retires their timeline event.
    private var isAwaitingClearance: Bool {
        calendar.startOfDay(for: resolved.paymentDate)
            <= calendar.startOfDay(for: .now)
    }

    private var displayedCandidates: [TransactionSummary] {
        Array(bankCandidates.prefix(5))
    }

    private var candidatesCard: some View {
        NwCard(style: .primary, padding: 0) {
            VStack(spacing: 0) {
                ForEach(Array(displayedCandidates.enumerated()),
                        id: \.element.id) { index, transaction in
                    Button {
                        saveSettlement(transactionId: transaction.id)
                    } label: {
                        HStack(spacing: NwSpacing.md) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(
                                    transaction.payeeName
                                        ?? transaction.categoryName
                                        ?? "Transaction"
                                )
                                .font(NwTypography.body)
                                .foregroundStyle(NwAppColors.textPrimary)
                                Text("Mark as this payment")
                                    .font(NwTypography.caption)
                                    .foregroundStyle(NwAppColors.accent)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                NwAmountText(
                                    transaction.amount,
                                    variant: .body,
                                    showCents: true,
                                    color: NwAppColors.liability
                                )
                                Text(
                                    transaction.date.formatted(
                                        .dateTime.month(.abbreviated).day()
                                    )
                                )
                                .font(NwTypography.caption)
                                .foregroundStyle(NwAppColors.textSecondary)
                            }
                        }
                        .padding(NwSpacing.md)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < displayedCandidates.count - 1 {
                        Divider().padding(.leading, NwSpacing.md)
                    }
                }
            }
        }
    }

    private var boundaryActivityCard: some View {
        NwCard(style: .primary, padding: 0) {
            VStack(spacing: 0) {
                ForEach(Array(boundaryTransactions.enumerated()),
                        id: \.element.id) { index, transaction in
                    Button {
                        selectedBoundaryTransaction = transaction
                    } label: {
                        HStack(spacing: NwSpacing.md) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(
                                    transaction.payeeName
                                        ?? transaction.categoryName
                                        ?? "Transaction"
                                )
                                .font(NwTypography.body)
                                .foregroundStyle(NwAppColors.textPrimary)
                                Text(boundaryDateLabel(transaction))
                                    .font(NwTypography.caption)
                                    .foregroundStyle(
                                        NwAppColors.textSecondary
                                    )
                                if let label = assignmentLabel(for: transaction) {
                                    Text(label)
                                        .font(NwTypography.caption)
                                        .foregroundStyle(NwAppColors.accent)
                                }
                            }
                            Spacer()
                            NwAmountText(
                                transaction.amount,
                                variant: .body,
                                showCents: true,
                                color: transaction.amount.isNegative
                                    ? NwAppColors.liability
                                    : NwAppColors.positive
                            )
                        }
                        .padding(NwSpacing.md)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < boundaryTransactions.count - 1 {
                        Divider().padding(.leading, NwSpacing.md)
                    }
                }
            }
        }
    }

    private func activityLabel(
        _ effect: CardPaymentActivityEffect
    ) -> String {
        switch effect {
        case .nextStatement: "Next statement"
        case .reducesPayment: "Reduces payment"
        case .increasesPayment: "Increases payment"
        case .currentBalanceOnly: "Current balance only"
        }
    }

    private var resolved: ResolvedUpcomingCardPayment {
        CardPaymentConfirmationResolver(calendar: calendar).resolve(
            payment,
            confirmations: confirmationRows.map(\.coreConfirmation)
        )
    }

    private var reconciliation: CardPaymentReconciliation {
        CCPaymentForecaster(calendar: calendar).reconciliation(
            for: payment,
            transactions: transactions,
            statementAssignments: statementAssignmentRows.map(
                \.coreAssignment
            ),
            asOf: .now
        )
    }

    private var boundaryTransactions: [TransactionSummary] {
        CCPaymentForecaster(calendar: calendar).statementBoundaryTransactions(
            for: payment,
            transactions: transactions
        )
    }

    private var nextStatementCloseDate: Date {
        CCPaymentForecaster(calendar: calendar)
            .followingStatementCloseDate(
                after: payment.closeDate,
                cycleDay: payment.statementCycleDay
            )
    }

    private func assignment(
        for transaction: TransactionSummary
    ) -> DurableCardStatementAssignment? {
        statementAssignmentRows.filter {
            $0.transactionId == transaction.id
                && $0.cardAccountId == payment.cardAccountId
        }.max { $0.updatedAt < $1.updatedAt }
    }

    private func assignmentLabel(for transaction: TransactionSummary) -> String? {
        guard let assignment = assignment(for: transaction) else { return nil }
        return calendar.isDate(
            assignment.statementCloseDate,
            inSameDayAs: payment.closeDate
        ) ? "Assigned to this statement" : "Assigned to next statement"
    }

    private func boundaryDateLabel(_ transaction: TransactionSummary) -> String {
        var parts = ["Posted \(shortDate(transaction.date))"]
        if let authorized = transaction.authorizedDate,
           !calendar.isDate(authorized, inSameDayAs: transaction.date) {
            parts.append("Authorized \(shortDate(authorized))")
        }
        return parts.joined(separator: " · ")
    }

    private func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    private var cycleSettlements: [DurableCardPaymentSettlement] {
        settlementRows.filter {
            $0.cardAccountId == payment.cardAccountId
                && calendar.isDate(
                    $0.statementCloseDate,
                    inSameDayAs: payment.closeDate
                )
        }
    }

    private func saveSettlement(transactionId: String?) {
        let context = container.modelContainer.mainContext
        let now = Date.now
        let previousPickedIds = Set(
            cycleSettlements.map(\.transactionId).filter { !$0.isEmpty }
        )
        if cycleSettlements.isEmpty {
            context.insert(DurableCardPaymentSettlement(
                cardAccountId: payment.cardAccountId,
                statementCloseDate: payment.closeDate,
                transactionId: transactionId ?? "",
                createdAt: now,
                updatedAt: now
            ))
        } else {
            for row in cycleSettlements {
                row.transactionId = transactionId ?? ""
                row.updatedAt = now
            }
        }
        guard context.safeSave(source: "projection.cardPayment.settle")
        else {
            persistenceError = "Your payment confirmation wasn’t saved."
            return
        }
        // The pick identifies the debit, so the review queue follows: the
        // picked transaction confirms as a card payment to this card, and
        // a previously picked debit returns to review.
        for previousId in previousPickedIds where previousId != transactionId {
            container.requeuePlaidSettledCardPayment(
                transactionId: previousId
            )
        }
        if let transactionId,
           !container.confirmPlaidCardPaymentSettlement(
               transactionId: transactionId,
               cardAccountId: payment.cardAccountId
           ) {
            persistenceError =
                "Marked paid, but the transaction couldn’t be updated in review."
        }
    }

    private func removeSettlement() {
        let context = container.modelContainer.mainContext
        let pickedIds = Set(
            cycleSettlements.map(\.transactionId).filter { !$0.isEmpty }
        )
        for row in cycleSettlements { context.delete(row) }
        guard context.safeSave(source: "projection.cardPayment.unsettle")
        else {
            context.rollback()
            persistenceError = "Your change wasn’t saved."
            return
        }
        for pickedId in pickedIds {
            container.requeuePlaidSettledCardPayment(transactionId: pickedId)
        }
    }

    private var matchingRows: [DurableCardPaymentConfirmation] {
        confirmationRows.filter {
            $0.cardAccountId == payment.cardAccountId
                && calendar.isDate(
                    $0.statementCloseDate,
                    inSameDayAs: payment.closeDate
                )
        }
    }

    private func saveConfirmation(_ amount: Money, _ date: Date) -> Bool {
        let context = container.modelContainer.mainContext
        let now = Date.now
        if matchingRows.isEmpty {
            context.insert(DurableCardPaymentConfirmation(
                cardAccountId: payment.cardAccountId,
                statementCloseDate: payment.closeDate,
                amountMilliunits: amount.milliunits,
                paymentDate: date,
                createdAt: now,
                updatedAt: now
            ))
        } else {
            for row in matchingRows {
                row.amountMilliunits = amount.milliunits
                row.paymentDate = date
                row.updatedAt = now
            }
        }
        guard context.safeSave(source: "projection.cardPayment.confirm") else {
            persistenceError = "Your scheduled payment wasn’t saved."
            return false
        }
        return true
    }

    private func removeConfirmation() {
        let context = container.modelContainer.mainContext
        for row in matchingRows { context.delete(row) }
        guard context.safeSave(source: "projection.cardPayment.useEstimate")
        else {
            context.rollback()
            persistenceError = "Your scheduled payment wasn’t removed."
            return
        }
    }

    private func assign(
        _ transaction: TransactionSummary,
        to closeDate: Date
    ) {
        let context = container.modelContainer.mainContext
        let now = Date.now
        let matches = statementAssignmentRows.filter {
            $0.transactionId == transaction.id
                && $0.cardAccountId == payment.cardAccountId
        }
        if matches.isEmpty {
            context.insert(DurableCardStatementAssignment(
                transactionId: transaction.id,
                cardAccountId: payment.cardAccountId,
                statementCloseDate: calendar.startOfDay(for: closeDate),
                createdAt: now,
                updatedAt: now
            ))
        } else {
            for row in matches {
                row.statementCloseDate = calendar.startOfDay(for: closeDate)
                row.updatedAt = now
            }
        }
        guard context.safeSave(source: "projection.cardStatement.assign")
        else {
            context.rollback()
            persistenceError = "Your statement assignment wasn’t saved."
            return
        }
        selectedBoundaryTransaction = nil
        dismiss()
    }

    private func removeAssignment(for transaction: TransactionSummary) {
        let context = container.modelContainer.mainContext
        let matches = statementAssignmentRows.filter {
            $0.transactionId == transaction.id
                && $0.cardAccountId == payment.cardAccountId
        }
        for row in matches { context.delete(row) }
        guard context.safeSave(source: "projection.cardStatement.usePostedDate")
        else {
            context.rollback()
            persistenceError = "Your statement assignment wasn’t removed."
            return
        }
        selectedBoundaryTransaction = nil
        dismiss()
    }
}

private struct CardPaymentConfirmationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (Money, Date) -> Bool

    @State private var amountText: String
    @State private var paymentDate: Date

    init(
        initialAmount: Money,
        initialDate: Date,
        onSave: @escaping (Money, Date) -> Bool
    ) {
        self.onSave = onSave
        _amountText = State(
            initialValue: CurrencyInputFormatter.text(for: initialAmount)
        )
        _paymentDate = State(initialValue: initialDate)
    }

    var body: some View {
        NwModalLayout(
            title: "Enter Scheduled Payment",
            onClose: { dismiss() },
            onConfirm: save,
            confirmDisabled: amount == nil
        ) {
            NwCard(style: .primary) {
                VStack(spacing: NwSpacing.md) {
                    HStack(spacing: NwSpacing.md) {
                        Text("Amount")
                        Spacer()
                        TextField("0.00", text: $amountText)
                            .multilineTextAlignment(.trailing)
                            .nwCurrencyInput(text: $amountText)
                            .frame(width: 140, height: 44)
                    }
                    Divider()
                    DatePicker(
                        "Payment date",
                        selection: $paymentDate,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.compact)
                }
            }
        }
    }

    private var amount: Money? {
        guard let amount = CurrencyInputFormatter.money(from: amountText),
              amount > .zero else { return nil }
        return amount
    }

    private func save() {
        guard let amount, onSave(amount, paymentDate) else { return }
        dismiss()
    }
}

private struct PaycheckScheduleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppContainerController.self) private var container

    let paycheck: DetectedPaycheck
    let existingOverride: DurableIncomePatternOverride?

    @State private var cadence: CommitmentCadence
    @State private var nextPayday: Date
    @State private var showingResetConfirmation = false
    @State private var persistenceError: String?

    init(
        paycheck: DetectedPaycheck,
        existingOverride: DurableIncomePatternOverride?
    ) {
        self.paycheck = paycheck
        self.existingOverride = existingOverride
        _cadence = State(
            initialValue: existingOverride?.cadence ?? paycheck.cadence
        )
        _nextPayday = State(
            initialValue: existingOverride?.nextPaydayAt ?? paycheck.nextDate
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Paycheck") {
                    LabeledContent("Payer", value: paycheck.displayName)
                    Picker("Repeats", selection: $cadence) {
                        ForEach(CommitmentCadence.allCases) { cadence in
                            Text(cadence.displayName).tag(cadence)
                        }
                    }
                    DatePicker(
                        "Next payday",
                        selection: $nextPayday,
                        in: Calendar.current.startOfDay(for: .now)...,
                        displayedComponents: .date
                    )
                }

                if existingOverride != nil {
                    Section {
                        Button("Use Detected Schedule", role: .destructive) {
                            showingResetConfirmation = true
                        }
                    }
                }

                if let persistenceError {
                    Section {
                        Text(persistenceError)
                            .foregroundStyle(NwAppColors.caution)
                    }
                }
            }
            .nwScreenBackground()
            .navigationTitle("Paycheck Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        NwIcon.close.image
                            .foregroundStyle(NwAppColors.liability)
                    }
                    .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) {
                        NwIcon.confirm.image
                            .foregroundStyle(NwAppColors.positive)
                    }
                    .accessibilityLabel("Save")
                }
            }
            .alert(
                "Use Detected Schedule?",
                isPresented: $showingResetConfirmation
            ) {
                Button("Use Detected Schedule", role: .destructive) {
                    reset()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .nwGlassSheet()
    }

    private func save() {
        let context = container.modelContainer.mainContext
        let rows = (try? context.fetch(
            FetchDescriptor<DurableIncomePatternOverride>()
        )) ?? []
        let target = rows
            .filter { $0.payeeKey == paycheck.payeeKey || $0.id == "singleton" }
            .max { $0.updatedAt < $1.updatedAt }
            ?? {
                let row = DurableIncomePatternOverride()
                context.insert(row)
                return row
            }()
        target.payeeKey = paycheck.payeeKey
        target.displayName = paycheck.displayName
        target.cadence = cadence
        target.nextPaydayAt = Calendar.current.startOfDay(for: nextPayday)
        target.scheduleOverrideEnabled = true
        target.confirmed = true
        target.confirmedAt = target.confirmedAt ?? .now
        target.updatedAt = .now
        guard context.safeSave(source: "projection.paycheckSchedule.save")
        else {
            persistenceError = "Your paycheck schedule wasn’t saved."
            return
        }
        dismiss()
    }

    private func reset() {
        let context = container.modelContainer.mainContext
        let rows = (try? context.fetch(
            FetchDescriptor<DurableIncomePatternOverride>()
        )) ?? []
        let matching = rows.filter {
            $0.payeeKey == paycheck.payeeKey && $0.scheduleOverrideEnabled
        }
        for row in matching {
            row.scheduleOverrideEnabled = false
            row.nextPaydayAt = nil
            row.updatedAt = .now
        }
        guard context.safeSave(source: "projection.paycheckSchedule.reset")
        else {
            context.rollback()
            persistenceError = "Your detected schedule wasn’t restored."
            return
        }
        dismiss()
    }
}

/// Off-main assembly of the full projection: the only implementation of the
/// forecast pipeline. Owns its own ModelContext; the view renders only
/// finished results.
@ModelActor
private actor ProjectionsDataActor {
    func build() -> ProjectionsView.ProjectionData {
        let context = modelContext
        let settings = try? context
            .fetch(FetchDescriptor<DurableUserSettings>()).first
        let horizonDays = settings?.projectionHorizonDays ?? 90
        let minimumCashBuffer = Money(
            milliunits: settings?.dipThresholdMilliunits ?? 500_000
        )
        let cutoff = Calendar(identifier: .gregorian)
            .date(byAdding: .day, value: -370, to: .now) ?? .distantPast

        let financialRows = (try? context.fetch(
            FetchDescriptor<CachedFinancialAccount>(
                predicate: #Predicate { !$0.deleted }
            )
        )) ?? []
        let accountNicknames = (try? context.fetch(
            FetchDescriptor<DurableAccountNickname>()
        )) ?? []
        let accountNameResolver = AccountDisplayNameResolver(
            nicknames: accountNicknames
        )
        let availableAccounts = financialRows.map {
            $0.toAccountSnapshot(
                displayName: accountNameResolver.name(for: $0)
            )
        }
        let cashAccountOverrides = (try? context.fetch(
            FetchDescriptor<DurableProjectionCashAccountOverride>()
        )) ?? []
        let cardSettings = (try? context.fetch(
            FetchDescriptor<DurableCardSettings>()
        )) ?? []
        let confirmationRows = (try? context.fetch(
            FetchDescriptor<DurableCardPaymentConfirmation>()
        )) ?? []
        let settlementRows = (try? context.fetch(
            FetchDescriptor<DurableCardPaymentSettlement>()
        )) ?? []
        let statementAssignmentRows = (try? context.fetch(
            FetchDescriptor<DurableCardStatementAssignment>()
        )) ?? []
        let incomeOverrideRows = (try? context.fetch(
            FetchDescriptor<DurableIncomePatternOverride>()
        )) ?? []
        let financialTransactions = (try? context.fetch(
            FetchDescriptor<CachedFinancialTransaction>(
                predicate: #Predicate {
                    $0.postedDate >= cutoff && !$0.deleted && !$0.pending
                }
            )
        )) ?? []
        let categories = (try? context.fetch(
            FetchDescriptor<DurableCanonicalCategory>()
        )) ?? []
        let exclusions = (try? context.fetch(
            FetchDescriptor<DurableExcludedSpendCategory>()
        )) ?? []
        let transactionExclusions = (try? context.fetch(
            FetchDescriptor<DurableExcludedSpendTransaction>()
        )) ?? []
        let spendingReserveFunds = (try? context.fetch(
            FetchDescriptor<DurableSpendingSinkingFund>()
        )) ?? []
        let spendingReserveContributions = (try? context.fetch(
            FetchDescriptor<DurableSpendingSinkingFundContribution>()
        )) ?? []
        let spendingReserveExpenses = (try? context.fetch(
            FetchDescriptor<DurableSpendingSinkingFundExpense>()
        )) ?? []
        let excludedCategoryIds = Set(exclusions.map(\.categoryId))
        let hiddenInternalCategoryIds: Set<String> = []
        let spendingReserveAdjustment = SpendingReserveProjectionResolver
            .resolve(
                funds: spendingReserveFunds.map(\.coreFund),
                contributions: spendingReserveContributions.map(
                    \.coreContribution
                ),
                expenses: spendingReserveExpenses.map(\.coreExpense),
                through: BudgetMonth(containing: .now)
            )

        let openCash = availableAccounts.filter { !$0.deleted && !$0.closed && $0.kind.isCashLike }
        var overrideMap: [String: Bool] = [:]
        cashAccountOverrides.forEach {
            let id = $0.canonicalAccountId ?? $0.accountId
            overrideMap[id] = $0.included
        }
        let goalReserveIds = Set(((try? context.fetch(
            FetchDescriptor<DurableGoalReserveAccount>()
        )) ?? []).filter(\.active).map(\.canonicalAccountId))
        let selectedCash = ProjectionCashSelection.selectedAccounts(
            openCash: openCash,
            overrideMap: overrideMap,
            goalReserveIds: goalReserveIds
        )
        let selectedIds = Set(selectedCash.map(\.id))

        let openCards = availableAccounts.filter { !$0.deleted && !$0.closed && $0.kind.isCreditCardLike }
        let configured: [(AccountSnapshot, CardStatementSettings)] = openCards.compactMap { card in
            guard let stored = cardSettings.first(where: {
                ($0.canonicalAccountId ?? $0.accountId) == card.id
            }),
                  let paymentAccountID = stored.canonicalPaymentAccountId
                    ?? stored.paymentAccountId,
                  stored.statementCycleDay >= 1,
                  stored.paymentDueDay >= 1,
                  !paymentAccountID.isEmpty else { return nil }
            let setting = CardStatementSettings(
                accountId: card.id,
                statementCycleDay: stored.statementCycleDay,
                paymentDueDay: stored.paymentDueDay,
                paymentAccountId: paymentAccountID,
                minimumPaymentPercent: stored.minimumPaymentPercent,
                minimumPaymentFloor: stored.minimumPaymentFloor
            )
            return (card, setting)
        }
        let configuredIds = Set(configured.map { $0.0.id })
        let missingCards = openCards.filter { !configuredIds.contains($0.id) }.map(\.name)
        let unfundedCards = configured.compactMap { card, setting -> String? in
            guard let paymentAccountId = setting.paymentAccountId,
                  !selectedIds.contains(paymentAccountId) else { return nil }
            return card.name
        }
        let history = financialTransactions.compactMap {
            $0.toProjectionSummary()
        }
        let cardActivityHistory: [TransactionSummary] = financialTransactions.map {
            TransactionSummary(
                id: $0.id,
                accountId: $0.canonicalAccountId,
                date: $0.postedDate,
                authorizedDate: $0.authorizedDate,
                amount: Money(milliunits: $0.amountMilliunits),
                cleared: true,
                approved: !$0.requiresReview,
                payeeName: $0.displayName,
                categoryName: $0.categoryDisplayName,
                forecastTreatment: $0.forecastTreatment,
                memo: nil,
                deleted: $0.deleted
            )
        }
        // User-authored recurring expectations are the only authoritative
        // dated future events. Expectations on card accounts raise that
        // card's projected statement; only the generated autopay reaches
        // the pool.
        let expectations = ((try? context.fetch(
            FetchDescriptor<DurableRecurringExpectation>(
                predicate: #Predicate { !$0.archived }
            )
        )) ?? []).map { $0.toCore() }
        var scheduledSummaries = expectations.map { $0.toScheduledSummary() }
        // Detected paycheck: confirmed Plaid income history projects future
        // paydays as exact dated inflows (phase-priced, pool-scoped). A
        // manual recurring-income expectation for the same payer always
        // wins; the detection then only reports.
        var paycheckDetection: PaycheckDetection?
        var paycheckManualOverridePayee: String?
        var paycheckScheduleOverride: PaycheckScheduleOverride?
        var expectedTodayPaycheckAmount: Money?
        do {
            let detection = IncomeAnalyzer().detectPaycheck(
                confirmedTransactions: history,
                selectedAccountIds: selectedIds,
                asOf: .now
            )
            paycheckDetection = detection
            if case .detected(let paycheck) = detection {
                let storedSchedule = incomeOverrideRows
                    .filter {
                        $0.scheduleOverrideEnabled
                            && $0.payeeKey == paycheck.payeeKey
                            && $0.nextPaydayAt != nil
                    }
                    .max { $0.updatedAt < $1.updatedAt }
                if let storedSchedule,
                   let nextPayday = storedSchedule.nextPaydayAt {
                    paycheckScheduleOverride = PaycheckScheduleOverride(
                        payeeKey: paycheck.payeeKey,
                        cadence: storedSchedule.cadence,
                        nextPayday: nextPayday
                    )
                }
                if let manual = IncomeAnalyzer.manualIncomeOverride(
                    for: paycheck, expectations: expectations
                ) {
                    paycheckManualOverridePayee = manual.payeeName
                } else {
                    scheduledSummaries.append(contentsOf: paycheck.scheduledSummaries(
                        asOf: .now,
                        horizonDays: horizonDays,
                        scheduleOverride: paycheckScheduleOverride
                    ))
                    if let schedule = paycheckScheduleOverride {
                        let calendar = Calendar.current
                        let today = calendar.startOfDay(for: .now)
                        let scheduledToday = schedule.occurrence(
                            onOrAfter: today,
                            calendar: calendar
                        ).map {
                            calendar.isDate($0, inSameDayAs: today)
                        } == true
                        let alreadyConfirmed = paycheck.pattern
                            .observedPaycheckDates.contains {
                                calendar.isDate($0, inSameDayAs: today)
                            }
                        if scheduledToday && !alreadyConfirmed {
                            let month = BudgetMonth(
                                containing: today,
                                calendar: calendar
                            )
                            expectedTodayPaycheckAmount = paycheck.portions.map {
                                paycheck.amount(
                                    for: $0,
                                    in: month,
                                    calendar: calendar
                                )
                            }.sum()
                        }
                    } else {
                        expectedTodayPaycheckAmount = paycheck.expectedTodayAmount
                    }
                }
            }
        }
        // Exactly-once is id-based: historical actuals matched to an active
        // expectation are excluded from the ordinary-spending estimate (at
        // their real amounts), and EVERY expectation is exempt from the
        // theoretical scheduled-occurrence subtraction — a new expectation
        // must never invent past occurrences that erase unrelated spending.
        let estimateExemptIds = Set(scheduledSummaries.map(\.id))
        let expectationMatchedIds = RecurringExpectations.matchedHistoricalIds(
            transactions: history,
            expectations: expectations
        )
        let spendIds = Set(availableAccounts.filter { !$0.deleted && $0.kind.isSpendAccount }.map(\.id))

        let forecaster = CCPaymentForecaster()
        let statementAssignments = statementAssignmentRows.map(\.coreAssignment)
        let paymentEstimates = configured.flatMap { card, setting in
            forecaster.upcomingPayments(
                card: card,
                settings: setting,
                scheduled: scheduledSummaries,
                historicalTransactions: cardActivityHistory,
                statementAssignments: statementAssignments,
                spendAccountIds: spendIds,
                asOf: .now,
                horizonDays: horizonDays
            )
        }.sorted { $0.dueDate < $1.dueDate }
        let confirmationResolver = CardPaymentConfirmationResolver()
        let confirmations = confirmationRows.map(\.coreConfirmation)
        let resolvedPayments = paymentEstimates.map {
            confirmationResolver.resolve($0, confirmations: confirmations)
        }
        let projectedPayments = resolvedPayments.map(\.projectedPayment)
        // A payment past its due date stays projected until its debit
        // settles on the paying account or the user resolves it in the
        // autopay detail sheet. Settled cycles drop out here; the
        // forecaster itself stays settlement-blind.
        let settlementMatcher = CardPaymentSettlementMatcher()
        let settledPaymentIds = settlementMatcher.settledPaymentIds(
            payments: projectedPayments,
            transactions: cardActivityHistory,
            settlements: settlementRows.map(\.coreSettlement),
            asOf: .now
        )
        let activePayments = projectedPayments.filter {
            !settledPaymentIds.contains($0.id)
        }
        let startOfToday = Calendar.current.startOfDay(for: .now)
        let overdueCandidatesByPaymentID = Dictionary(
            uniqueKeysWithValues: activePayments
                .filter {
                    Calendar.current.startOfDay(for: $0.dueDate)
                        <= startOfToday
                }
                .map { payment in
                    (
                        payment.id,
                        settlementMatcher.candidateTransactions(
                            for: payment,
                            transactions: cardActivityHistory,
                            asOf: .now
                        )
                    )
                }
        )
        let cardActivityByPaymentID = Dictionary(uniqueKeysWithValues:
            paymentEstimates.map { payment in
                (
                    payment.id,
                    cardActivityHistory.filter {
                        $0.accountId == payment.cardAccountId
                    }
                )
            }
        )

        let fundedCardIds: Set<String> = Set(configured.compactMap { pair -> String? in
            let (card, setting) = pair
            guard let source = setting.paymentAccountId, selectedIds.contains(source) else { return nil }
            return card.id
        })
        let result = CashPositionProjector().project(
            cashAccounts: openCash,
            selectedCashAccountIds: selectedIds,
            cardAccountIds: Set(openCards.map(\.id)),
            fundedCardAccountIds: fundedCardIds,
            cardPayments: activePayments,
            scheduled: scheduledSummaries,
            estimateExemptScheduledIds: estimateExemptIds,
            historicalTransactions: history,
            excludedCategoryIds: excludedCategoryIds,
            excludedTransactionIds: Set(transactionExclusions.map(\.transactionId))
                .union(expectationMatchedIds)
                .union(
                    spendingReserveAdjustment.excludedHistoricalLineIDs
                ),
            recurringMatchedTransactionIds: expectationMatchedIds,
            outflowOnlyExcludedCategoryIds: hiddenInternalCategoryIds,
            spendAccountIds: spendIds,
            lookbackDays: 365,
            asOf: .now,
            horizonDays: horizonDays,
            minimumCashBuffer: minimumCashBuffer,
            spendingReserve: spendingReserveAdjustment.balance
        )
        return ProjectionsView.ProjectionData(
            result: result,
            paymentEstimates: paymentEstimates,
            cardActivityByPaymentID: cardActivityByPaymentID,
            overdueCandidatesByPaymentID: overdueCandidatesByPaymentID,
            selectedCashAccounts: selectedCash,
            missingCardNames: missingCards,
            unfundedCardNames: unfundedCards,
            excludedCategoryNames: categories
                .filter {
                    !$0.deletedAtSource
                        && excludedCategoryIds.contains($0.canonicalId)
                }
                .map(\.name)
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
            limitedHistory: result.expectedSpend.historyDays < 30,
            paycheckDetection: paycheckDetection,
            paycheckManualOverridePayee: paycheckManualOverridePayee,
            hasManualIncome: expectations.contains {
                $0.treatment == .income && $0.amount.milliunits > 0
            },
            paycheckScheduleOverride: paycheckScheduleOverride,
            expectedTodayPaycheckAmount: expectedTodayPaycheckAmount
        )
    }
}

/// Cash-pool membership for projections. Split out of the actor so the
/// derived rule — an account actively backing Goals leaves the spendable
/// pool, and the user's stored override survives untouched for when it
/// stops backing goals — is unit-testable.
enum ProjectionCashSelection {
    static func selectedAccounts(
        openCash: [AccountSnapshot],
        overrideMap: [String: Bool],
        goalReserveIds: Set<String>
    ) -> [AccountSnapshot] {
        openCash.filter {
            !goalReserveIds.contains($0.id)
                && (overrideMap[$0.id] ?? $0.onBudget)
        }
    }
}
