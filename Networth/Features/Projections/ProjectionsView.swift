import SwiftUI
import SwiftData
import Charts
import NetworthCore

/// The app's daily decision surface: what cash is available, what will move,
/// and whether known obligations plus ordinary spending remain above buffer.
struct ProjectionsView: View {
    @Environment(AppContainerController.self) private var container
    @Query(sort: \CachedAccount.name) private var accounts: [CachedAccount]
    @Query(sort: \CachedScheduledTransaction.nextDate) private var scheduled: [CachedScheduledTransaction]
    @Query private var allTransactions: [CachedTransaction]
    @Query private var categories: [CachedCategory]
    @Query private var cardSettings: [DurableCardSettings]
    @Query private var userSettings: [DurableUserSettings]
    @Query private var exclusions: [DurableExcludedSpendCategory]
    @Query private var transactionExclusions: [DurableExcludedSpendTransaction]
    @Query private var cashAccountOverrides: [DurableProjectionCashAccountOverride]

    @State private var showingAssumptions = false
    @State private var showingSafeToSpendDetails = false
    @State private var selectedPayment: UpcomingCardPayment?

    init() {
        let cutoff = Calendar(identifier: .gregorian)
            .date(byAdding: .day, value: -370, to: .now) ?? .distantPast
        _allTransactions = Query(
            filter: #Predicate<CachedTransaction> { $0.date >= cutoff && !$0.deleted },
            sort: [SortDescriptor(\CachedTransaction.date, order: .reverse)]
        )
    }

    var body: some View {
        let data = makeProjectionData()
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NwSpacing.lg) {
                    syncNotice
                    setupNotice(data)

                    if data.selectedCashAccounts.isEmpty {
                        NwEmptyState(
                            title: accounts.isEmpty ? "Sync your accounts" : "Choose your cash accounts",
                            message: accounts.isEmpty
                                ? "Add your YNAB token in Settings and sync to build a cash outlook."
                                : "Select the checking, savings, and cash accounts that can support upcoming obligations.",
                            icon: .projections
                        )
                        .frame(minHeight: 300)
                    } else {
                        accountFundingNotice(data)
                        statusCard(data)
                        safeToSpendCard(data)
                        cashChart(data)
                        cashFlowBridge(data)
                        timeline(data)
                    }
                }
                .padding(.horizontal, NwSpacing.screenPadding)
                .padding(.vertical, NwSpacing.lg)
            }
            .background(NwAppColors.background.ignoresSafeArea())
            .navigationTitle("Projections")
            .refreshable { await container.syncNow() }
            .sheet(isPresented: $showingAssumptions) {
                ProjectionAssumptionsSheet(data: data)
            }
            .sheet(isPresented: $showingSafeToSpendDetails) {
                if let estimate = data.result.safeToSpend {
                    SafeToSpendDetailSheet(
                        estimate: estimate,
                        higherSpendEstimate: data.result.higherSpendSafeToSpend,
                        higherSpendMonthlyAmount: data.result.expectedSpend.higherSpendMonthlyAmount
                    )
                }
            }
            .sheet(item: $selectedPayment) { payment in
                CardPaymentDetailSheet(payment: payment)
            }
        }
    }

    @ViewBuilder
    private var syncNotice: some View {
        switch container.syncCoordinator.phase {
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
            if isStale {
                NwInlineNotice(
                    "Projection data is stale",
                    message: "Last successful update was \(lastUpdatedText). Pull down to retry.",
                    tone: .caution
                )
            }
        }
    }

    @ViewBuilder
    private func setupNotice(_ data: ProjectionData) -> some View {
        if !data.missingCardNames.isEmpty {
            Button {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            } label: {
                NwInlineNotice(
                    "Finish credit-card setup",
                    message: "Configure close day, autopay day, and payment account for \(data.missingCardNames.joined(separator: ", ")). Outlook is incomplete.",
                    tone: .caution
                )
            }
            .buttonStyle(.plain)
        }
        if !data.unfundedCardNames.isEmpty {
            Button {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            } label: {
                NwInlineNotice(
                    "Include card payment accounts",
                    message: "Add the payment account for \(data.unfundedCardNames.joined(separator: ", ")) to selected cash.",
                    tone: .caution
                )
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func accountFundingNotice(_ data: ProjectionData) -> some View {
        if let account = data.primaryPaymentAccountShortfall, !data.showsPaymentFundingHeadline {
            NwInlineNotice(
                "\(account.accountName) also needs funding",
                message: "Known commitments take this account to \(CurrencyFormatter.compact(account.projectedShortfallLowPoint?.balance ?? .zero)) on \(account.firstShortfallPoint?.date.formatted(.dateTime.month(.abbreviated).day()) ?? "the projected date").",
                tone: .warning
            )
        }
        if let account = data.primaryOtherAccountShortfall {
            NwInlineNotice(
                "Separate shortfall in \(account.accountName)",
                message: "Known activity takes this account to \(CurrencyFormatter.compact(account.projectedShortfallLowPoint?.balance ?? .zero)) on \(account.firstShortfallPoint?.date.formatted(.dateTime.month(.abbreviated).day()) ?? "the projected date").",
                tone: .warning
            )
        }
    }

    private func statusCard(_ data: ProjectionData) -> some View {
        return NwCard(style: .primary) {
            VStack(alignment: .leading, spacing: NwSpacing.md) {
                VStack(alignment: .leading, spacing: NwSpacing.xs) {
                    Text(data.headlineTitle)
                        .font(NwTypography.title)
                        .foregroundStyle(data.statusColor)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle = data.headlineSubtitle {
                        Text(subtitle)
                            .font(NwTypography.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let amount = data.headlineAmount {
                    NwAmountText(amount, variant: .large, showCents: false, color: data.statusColor)
                }

                if let explanation = data.headlineExplanation {
                    Text(explanation)
                        .font(NwTypography.callout)
                        .foregroundStyle(NwAppColors.textSecondary)
                }

                Divider()
                HStack(spacing: NwSpacing.sm) {
                    NwMetricCapsule(
                        label: "Total cash",
                        value: CurrencyFormatter.compact(data.result.startingBalance),
                        symbol: .cash
                    )
                    NwMetricCapsule(
                        label: "Projected low",
                        value: CurrencyFormatter.compact(data.result.expectedLowPoint?.balance ?? data.result.startingBalance),
                        symbol: .projections
                    )
                    NwMetricCapsule(
                        label: "Buffer",
                        value: CurrencyFormatter.compact(minimumCashBuffer),
                        symbol: .lock
                    )
                }
            }
        }
    }

    private func cashChart(_ data: ProjectionData) -> some View {
        NwCard(style: .primary) {
            VStack(alignment: .leading, spacing: NwSpacing.md) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cash Outlook")
                            .font(NwTypography.headline)
                        Text("\(horizonDays) days · \(CurrencyFormatter.compact(data.result.expectedSpend.estimatedMonthlyAmount))/month estimated spending")
                            .font(NwTypography.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        showingAssumptions = true
                    } label: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Projection assumptions")
                }

                Chart {
                    ForEach(data.result.expectedPoints) { point in
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("Projected cash", point.balance.doubleValue),
                            series: .value("Series", "Projected cash")
                        )
                        .foregroundStyle(NwAppColors.primary)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                    }
                    RuleMark(y: .value("Buffer", minimumCashBuffer.doubleValue))
                        .foregroundStyle(NwAppColors.caution.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                .frame(height: 220)
            }
        }
    }

    @ViewBuilder
    private func safeToSpendCard(_ data: ProjectionData) -> some View {
        if !data.setupIncomplete, !data.limitedHistory, data.result.safeToSpend != nil {
            Button {
                showingSafeToSpendDetails = true
            } label: {
                safeToSpendCardContent(data, showsDisclosure: true)
            }
            .buttonStyle(.plain)
        } else {
            safeToSpendCardContent(data, showsDisclosure: false)
        }
    }

    private func safeToSpendCardContent(
        _ data: ProjectionData,
        showsDisclosure: Bool
    ) -> some View {
        NwCard(style: .primary) {
            VStack(alignment: .leading, spacing: NwSpacing.md) {
                HStack {
                    Text("Safe to Spend")
                        .font(NwTypography.headline)
                    Spacer()
                    (showsDisclosure ? NwIcon.chevron : NwIcon.cash).image
                        .foregroundStyle(NwAppColors.primary)
                }

                if data.setupIncomplete {
                    Text("Unavailable until credit-card setup is complete")
                        .font(NwTypography.bodyEmphasis)
                        .foregroundStyle(NwAppColors.caution)
                    Text("A safe amount must include every upcoming card payment and its funding account.")
                        .font(NwTypography.footnote)
                        .foregroundStyle(.secondary)
                } else if data.limitedHistory {
                    Text("Unavailable with limited spending history")
                        .font(NwTypography.bodyEmphasis)
                        .foregroundStyle(NwAppColors.caution)
                    Text("At least 30 days of spending is needed before ordinary spending can be reserved reliably.")
                        .font(NwTypography.footnote)
                        .foregroundStyle(.secondary)
                } else if let estimate = data.result.safeToSpend {
                    NwAmountText(
                        estimate.amount,
                        variant: .large,
                        showCents: false,
                        color: estimate.amount.isZero ? NwAppColors.caution : NwAppColors.positive
                    )
                    Text(safeToSpendSummary(estimate))
                        .font(NwTypography.bodyEmphasis)
                        .foregroundStyle(estimate.amount.isZero ? NwAppColors.caution : NwAppColors.textPrimary)
                    Text(safeToSpendExplanation(estimate, data: data))
                        .font(NwTypography.footnote)
                        .foregroundStyle(.secondary)
                    if let higherEstimate = data.result.higherSpendSafeToSpend,
                       let higherMonthly = data.result.expectedSpend.higherSpendMonthlyAmount {
                        Divider()
                        HStack(alignment: .firstTextBaseline, spacing: NwSpacing.md) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("If spending runs high")
                                    .font(NwTypography.bodyEmphasis)
                                Text("Based on a \(CurrencyFormatter.compact(higherMonthly)) month")
                                    .font(NwTypography.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                NwAmountText(
                                    higherEstimate.amount,
                                    variant: .body,
                                    showCents: false,
                                    color: higherEstimate.amount.isZero
                                        ? NwAppColors.caution
                                        : NwAppColors.textPrimary
                                )
                                Text("safe to spend")
                                    .font(NwTypography.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Text("No projection available")
                        .font(NwTypography.bodyEmphasis)
                        .foregroundStyle(NwAppColors.caution)
                    Text("Sync your accounts to calculate an amount across the selected projection horizon.")
                        .font(NwTypography.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func safeToSpendSummary(_ estimate: SafeToSpendEstimate) -> String {
        if estimate.amount.isZero {
            return "No extra spending room"
        }
        return "Available now through \(estimate.lowPointDate.formatted(.dateTime.month(.abbreviated).day()))"
    }

    private func safeToSpendExplanation(
        _ estimate: SafeToSpendEstimate,
        data: ProjectionData
    ) -> String {
        if estimate.amount.isZero {
            return "After ordinary spending, cash reaches \(CurrencyFormatter.compact(estimate.projectedLowBalance)) on \(estimate.lowPointDate.formatted(.dateTime.month(.abbreviated).day())) with the \(CurrencyFormatter.compact(estimate.minimumCashBuffer)) buffer reserved."
        }
        let transferNote = data.result.accountShortfalls.isEmpty
            ? ""
            : " Complete the required account transfer first."
        return "After ordinary spending, the projected low is \(CurrencyFormatter.compact(estimate.projectedLowBalance)) on \(estimate.lowPointDate.formatted(.dateTime.month(.abbreviated).day())), with the \(CurrencyFormatter.compact(estimate.minimumCashBuffer)) buffer reserved.\(transferNote)"
    }

    private func cashFlowBridge(_ data: ProjectionData) -> some View {
        VStack(alignment: .leading, spacing: NwSpacing.md) {
            Text("\(horizonDays)-Day Cash Flow")
                .font(NwTypography.titleSmall)

            NwCard(style: .primary) {
                VStack(spacing: NwSpacing.sm) {
                    bridgeRow("Starting cash", amount: data.result.startingBalance)
                    bridgeRow("Income & transfers in", amount: data.result.knownInflows, signed: true)
                    bridgeRow("Scheduled outflows", amount: -data.result.scheduledOutflows, signed: true)
                    bridgeRow("Card payments", amount: -data.result.cardPaymentOutflows, signed: true)
                    bridgeRow("Unscheduled spending", amount: -data.result.expectedSpendingReserve, signed: true)
                    Divider()
                    bridgeRow(
                        "Projected ending cash",
                        amount: data.result.projectedEndingBalance,
                        emphasized: true
                    )
                }
            }
        }
    }

    private func bridgeRow(
        _ label: String,
        amount: Money,
        signed: Bool = false,
        emphasized: Bool = false
    ) -> some View {
        HStack(spacing: NwSpacing.md) {
            Text(label)
                .font(emphasized ? NwTypography.bodyEmphasis : NwTypography.body)
                .foregroundStyle(emphasized ? NwAppColors.textPrimary : NwAppColors.textSecondary)
            Spacer()
            NwAmountText(
                amount,
                variant: signed ? .signed : .body,
                showCents: false,
                color: emphasized ? NwAppColors.primary : nil
            )
        }
    }

    private func timeline(_ data: ProjectionData) -> some View {
        VStack(alignment: .leading, spacing: NwSpacing.md) {
            Text("Upcoming")
                .font(NwTypography.titleSmall)
            if data.result.events.isEmpty {
                NwInlineNotice(
                    "No known events",
                    message: "Add scheduled paychecks and bills in YNAB to make the outlook more complete.",
                    tone: .info
                )
            } else {
                NwCard(style: .primary, padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(data.result.events) { event in
                            eventRow(event, data: data)
                            if event.id != data.result.events.last?.id { Divider() }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func eventRow(_ event: CashProjectionEvent, data: ProjectionData) -> some View {
        let row = HStack(spacing: NwSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.date, format: .dateTime.month(.abbreviated).day().weekday(.abbreviated))
                    .font(NwTypography.caption)
                    .foregroundStyle(.secondary)
                Text(event.title)
                    .font(NwTypography.body)
                    .foregroundStyle(NwAppColors.textPrimary)
                if event.kind == .cardPayment,
                   let account = data.selectedCashAccounts.first(where: { $0.id == event.accountId }) {
                    Text("From \(account.name)")
                        .font(NwTypography.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            NwAmountText(event.amount, variant: .body,
                         color: event.amount.isNegative ? NwAppColors.liability : NwAppColors.positive)
            if event.kind == .cardPayment { NwIcon.chevron.image.foregroundStyle(.secondary) }
        }
        .padding(NwSpacing.md)
        .contentShape(Rectangle())

        if event.kind == .cardPayment,
           let payment = data.payments.first(where: { $0.id == event.id }) {
            Button { selectedPayment = payment } label: { row }
                .buttonStyle(.plain)
        } else {
            row
        }
    }

    // MARK: - Data

    fileprivate struct ProjectionData {
        let result: CashPositionProjector.Result
        let payments: [UpcomingCardPayment]
        let selectedCashAccounts: [AccountSnapshot]
        let missingCardNames: [String]
        let unfundedCardNames: [String]
        let excludedCategoryNames: [String]
        let limitedHistory: Bool

        var setupIncomplete: Bool {
            !missingCardNames.isEmpty || !unfundedCardNames.isEmpty
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

        var headlineAmount: Money? {
            if showsPaymentFundingHeadline { return primaryPaymentAccountShortfall?.fundingNeeded }
            return aggregateHeadlinePoint?.balance
        }

        var headlineSubtitle: String? {
            if showsPaymentFundingHeadline, let account = primaryPaymentAccountShortfall {
                guard let lowPoint = account.projectedShortfallLowPoint else { return nil }
                return "\(account.accountName) reaches \(CurrencyFormatter.compact(lowPoint.balance)) on \(lowPoint.date.formatted(.dateTime.month(.abbreviated).day()))."
            }
            guard let point = aggregateHeadlinePoint else { return nil }
            if aggregateCashShortfall {
                return "First negative projected balance on \(point.date.formatted(.dateTime.month(.abbreviated).day()))"
            }
            return "Lowest projected total \(point.date.formatted(.dateTime.month(.abbreviated).day()))"
        }

        var headlineExplanation: String? {
            if showsPaymentFundingHeadline, let account = primaryPaymentAccountShortfall {
                let cause = account.lowPointEvent.map {
                    "After \($0.title) of \(CurrencyFormatter.compact($0.amount.absolute)). "
                } ?? ""
                return "\(cause)Total selected cash can cover known commitments, but at least \(CurrencyFormatter.compact(account.fundingNeeded)) must be in \(account.accountName) before then."
            }
            let firstShortfallCause = limitedHistory
                ? result.knownFirstShortfallEvent
                : result.expectedFirstShortfallEvent
            if aggregateCashShortfall, let cause = firstShortfallCause {
                return "After \(cause.title) of \(CurrencyFormatter.compact(cause.amount.absolute))."
            }
            if let cause = result.lowPointEvent {
                return "After \(cause.title) of \(CurrencyFormatter.compact(cause.amount.absolute))."
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
                return "Cash gets tight on \(low.date.formatted(.dateTime.month(.abbreviated).day()))"
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

    private func makeProjectionData() -> ProjectionData {
        let openCash = accounts.filter { !$0.deleted && !$0.closed && $0.kind.isCashLike }
        var overrideMap: [String: Bool] = [:]
        cashAccountOverrides.forEach { overrideMap[$0.accountId] = $0.included }
        let selectedCash = openCash.filter { overrideMap[$0.id] ?? $0.onBudget }
        let selectedIds = Set(selectedCash.map(\.id))

        let openCards = accounts.filter { !$0.deleted && !$0.closed && $0.kind.isCreditCardLike }
        let configured: [(CachedAccount, DurableCardSettings)] = openCards.compactMap { card in
            guard let setting = cardSettings.first(where: { $0.accountId == card.id }),
                  setting.statementCycleDay >= 1,
                  setting.paymentDueDay >= 1,
                  setting.paymentAccountId?.isEmpty == false else { return nil }
            return (card, setting)
        }
        let configuredIds = Set(configured.map { $0.0.id })
        let missingCards = openCards.filter { !configuredIds.contains($0.id) }.map(\.name)
        let unfundedCards = configured.compactMap { card, setting -> String? in
            guard let paymentAccountId = setting.paymentAccountId,
                  !selectedIds.contains(paymentAccountId) else { return nil }
            return card.name
        }
        let history = allTransactions.map { $0.toSummary() }
        let scheduledSummaries = scheduled.filter { !$0.deleted }.map { $0.toSummary() }
        let spendIds = Set(accounts.filter { !$0.deleted && $0.kind.isSpendAccount }.map(\.id))

        let forecaster = CCPaymentForecaster()
        let payments = configured.flatMap { card, setting in
            forecaster.upcomingPayments(
                card: card.toSnapshot(),
                settings: setting.toCore(),
                scheduled: scheduledSummaries,
                historicalTransactions: history,
                spendAccountIds: spendIds,
                asOf: .now,
                horizonDays: horizonDays
            )
        }.sorted { $0.dueDate < $1.dueDate }

        let fundedCardIds: Set<String> = Set(configured.compactMap { pair -> String? in
            let (card, setting) = pair
            guard let source = setting.paymentAccountId, selectedIds.contains(source) else { return nil }
            return card.id
        })
        let result = CashPositionProjector().project(
            cashAccounts: openCash.map { $0.toSnapshot() },
            selectedCashAccountIds: selectedIds,
            cardAccountIds: Set(openCards.map(\.id)),
            fundedCardAccountIds: fundedCardIds,
            cardPayments: payments,
            scheduled: scheduledSummaries,
            historicalTransactions: history,
            excludedCategoryIds: excludedCategoryIds,
            excludedTransactionIds: Set(transactionExclusions.map(\.transactionId)),
            outflowOnlyExcludedCategoryIds: hiddenInternalCategoryIds,
            spendAccountIds: spendIds,
            lookbackDays: 365,
            asOf: .now,
            horizonDays: horizonDays,
            minimumCashBuffer: minimumCashBuffer
        )
        return ProjectionData(
            result: result,
            payments: payments,
            selectedCashAccounts: selectedCash.map { $0.toSnapshot() },
            missingCardNames: missingCards,
            unfundedCardNames: unfundedCards,
            excludedCategoryNames: categories
                .filter { !$0.deleted && excludedCategoryIds.contains($0.id) }
                .map(\.name)
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
            limitedHistory: result.expectedSpend.historyDays < 30
        )
    }

    private var horizonDays: Int { userSettings.first?.projectionHorizonDays ?? 90 }
    private var minimumCashBuffer: Money {
        Money(milliunits: userSettings.first?.dipThresholdMilliunits ?? 500_000)
    }
    private var excludedCategoryIds: Set<String> {
        let explicitlyExcluded = Set(exclusions.map(\.categoryId))
        let hidden = categories.filter {
            $0.hidden && !$0.deleted && $0.groupName != "Internal Master Category"
        }
        return explicitlyExcluded.union(hidden.map(\.id))
    }
    private var hiddenInternalCategoryIds: Set<String> {
        Set(categories.filter {
            $0.hidden && !$0.deleted && $0.groupName == "Internal Master Category"
        }.map(\.id))
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
    let estimate: SafeToSpendEstimate
    let higherSpendEstimate: SafeToSpendEstimate?
    let higherSpendMonthlyAmount: Money?

    var body: some View {
        NavigationStack {
            List {
                Section("Reconciliation Through \(lowPointDateText)") {
                    amountRow("Starting cash", estimate.startingBalance)
                    amountRow("Income & transfers in", estimate.knownInflows, signed: true)
                    amountRow("Scheduled outflows", -estimate.scheduledOutflows, signed: true)
                    amountRow("Card payments", -estimate.cardPaymentOutflows, signed: true)
                    amountRow("Expected ordinary spending", -estimate.expectedSpendingReserve, signed: true)
                    amountRow("Projected low", estimate.projectedLowBalance, emphasized: true)
                    amountRow("Cash buffer", -estimate.minimumCashBuffer, signed: true)
                    if !estimate.bufferGap.isZero {
                        amountRow(
                            "Below buffer",
                            -estimate.bufferGap,
                            signed: true,
                            color: NwAppColors.liability
                        )
                    }
                    amountRow(
                        "Safe to spend",
                        estimate.amount,
                        emphasized: true,
                        color: estimate.amount.isZero ? NwAppColors.caution : NwAppColors.positive
                    )
                }

                Section {
                    Text("This is one additional amount available through the projected low, not a recurring spending allowance.")
                        .font(NwTypography.callout)
                        .foregroundStyle(NwAppColors.textSecondary)
                }

                if let higherSpendEstimate, let higherSpendMonthlyAmount {
                    Section("If Spending Runs High") {
                        amountRow("Higher-spending month", higherSpendMonthlyAmount)
                        amountRow(
                            "Projected low",
                            higherSpendEstimate.projectedLowBalance
                        )
                        amountRow(
                            "Cash buffer",
                            -higherSpendEstimate.minimumCashBuffer,
                            signed: true
                        )
                        amountRow(
                            "Safe to spend",
                            higherSpendEstimate.amount,
                            emphasized: true,
                            color: higherSpendEstimate.amount.isZero
                                ? NwAppColors.caution
                                : NwAppColors.textPrimary
                        )
                    }
                }

                Section("Dated Activity Through \(lowPointDateText)") {
                    if estimate.contributingEvents.isEmpty {
                        Text("No scheduled activity before the projected low")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(estimate.contributingEvents) { event in
                            HStack(spacing: NwSpacing.md) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.title)
                                    Text(event.date, format: .dateTime.month(.abbreviated).day().weekday(.abbreviated))
                                        .font(NwTypography.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                NwAmountText(
                                    event.amount,
                                    variant: .signed,
                                    color: event.amount.isNegative
                                        ? NwAppColors.liability
                                        : NwAppColors.positive
                                )
                            }
                        }
                    }
                }
            }
            .navigationTitle("Safe to Spend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        NwIcon.close.image.foregroundStyle(NwAppColors.liability)
                    }
                }
            }
        }
    }

    private var lowPointDateText: String {
        estimate.lowPointDate.formatted(.dateTime.month(.abbreviated).day())
    }

    private func amountRow(
        _ label: String,
        _ amount: Money,
        signed: Bool = false,
        emphasized: Bool = false,
        color: Color? = nil
    ) -> some View {
        HStack(spacing: NwSpacing.md) {
            Text(label)
                .font(emphasized ? NwTypography.bodyEmphasis : NwTypography.body)
            Spacer()
            NwAmountText(
                amount,
                variant: signed ? .signed : .body,
                color: color
            )
        }
    }
}

private struct ProjectionAssumptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let data: ProjectionsView.ProjectionData

    var body: some View {
        NavigationStack {
            List {
                Section("Cash included") {
                    ForEach(data.selectedCashAccounts) { account in
                        HStack {
                            Text(account.name)
                            Spacer()
                            NwAmountText(account.balance, variant: .body)
                        }
                    }
                }
                Section("Expected spending") {
                    detail(
                        "Method",
                        data.result.expectedSpend.sampleMonthCount > 0 ? "Median monthly" : "Daily average fallback"
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
                    detail("Unscheduled reserve", CurrencyFormatter.compact(data.result.expectedSpend.unscheduledMonthlyAmount))
                    detail("External outflows", CurrencyFormatter.compact(data.result.expectedSpend.historicalOutflows))
                    detail("Scheduled removed", CurrencyFormatter.compact(data.result.expectedSpend.scheduledOutflows))
                    detail("Daily allowance", CurrencyFormatter.compact(data.result.expectedSpend.dailyAmount))
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
                    Text("Monthly spending is the median complete month. Scheduled outflows are modeled separately; only the unscheduled remainder is added. Income and refunds are not assumed.")
                        .font(NwTypography.callout)
                }
            }
            .navigationTitle("Projection Details")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { NwIcon.close.image.foregroundStyle(NwAppColors.liability) }
                }
            }
        }
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
        .navigationTitle(category.categoryName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var includedTotal: Money {
        category.transactions
            .filter { !excludedIds.contains($0.id) }
            .map(\.amount)
            .sum()
    }

    private func isExcluded(_ transaction: MonthlySpendTransaction) -> Bool {
        excludedIds.contains(transaction.id)
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
}

private struct CardPaymentDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let payment: UpcomingCardPayment

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("Expected autopay")
                        Spacer()
                        NwAmountText(payment.amount, variant: .body, color: NwAppColors.liability)
                    }
                    detail("Statement closes", payment.closeDate.formatted(date: .abbreviated, time: .omitted))
                    detail("Autopay date", payment.dueDate.formatted(date: .abbreviated, time: .omitted))
                }
                Section("Estimate") {
                    detail("Starting owed", CurrencyFormatter.compact(payment.startingBalanceOwed))
                    if !payment.priorStatementPaymentsApplied.isZero {
                        detail("Prior autopay removed", CurrencyFormatter.compact(payment.priorStatementPaymentsApplied))
                    }
                    if !payment.scheduledCharges.isZero {
                        detail("Scheduled charges", CurrencyFormatter.compact(payment.scheduledCharges))
                    }
                    if !payment.scheduledCredits.isZero {
                        detail("Scheduled credits", CurrencyFormatter.compact(payment.scheduledCredits))
                    }
                    Text(payment.basis == .closedStatementEstimate
                         ? "Estimated by reversing activity posted after the statement closed."
                         : "Uses today's balance, prior full-statement autopays, and scheduled card activity. Future ordinary purchases are reserved separately in Expected Spending.")
                        .font(NwTypography.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(payment.cardName)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { NwIcon.close.image.foregroundStyle(NwAppColors.liability) }
                }
            }
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text(value).foregroundStyle(.secondary) }
    }
}
