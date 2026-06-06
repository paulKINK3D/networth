import SwiftUI
import SwiftData
import Charts
import NetworthCore

struct ProjectionsView: View {
    @Environment(AppContainerController.self) private var container
    @Query(sort: \CachedAccount.name) private var accounts: [CachedAccount]
    @Query(sort: \CachedScheduledTransaction.nextDate) private var scheduled: [CachedScheduledTransaction]
    @Query(sort: \DurableCardSettings.accountId) private var cardSettings: [DurableCardSettings]
    @Query private var userSettings: [DurableUserSettings]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NwSpacing.lg) {
                    if cardProjections.isEmpty && cashPoints.isEmpty {
                        NwEmptyState(
                            title: "Nothing to project yet",
                            message: "Add your YNAB token in Settings and set statement-close days on your credit cards.",
                            icon: .projections
                        )
                        .frame(minHeight: 320)
                    } else {
                        if !cardProjections.isEmpty {
                            NwSectionHeader("Credit Card Forecast")
                                .padding(.horizontal, 0)
                            ForEach(cardProjections) { projection in
                                CCForecastCard(projection: projection)
                            }
                        }
                        if !cashPoints.isEmpty {
                            cashCard
                        }
                        if !alerts.isEmpty {
                            alertsCard
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

    private var cardProjections: [StatementProjection] {
        let forecaster = CCPaymentForecaster()
        let scheduledSummaries = scheduled.filter { !$0.deleted }.map { $0.toSummary() }
        return accounts.filter { !$0.deleted && !$0.closed && $0.kind.isCreditCardLike }
            .compactMap { card in
                guard let setting = cardSettings.first(where: { $0.accountId == card.id }) else {
                    return nil
                }
                return forecaster.forecast(
                    card: card.toSnapshot(),
                    settings: setting.toCore(),
                    scheduled: scheduledSummaries,
                    asOf: .now
                )
            }
    }

    private var cashProjection: CashPositionProjector.Result {
        let projector = CashPositionProjector()
        let cashAccounts = accounts
            .filter { !$0.deleted && !$0.closed && $0.kind.isCashLike }
            .map { $0.toSnapshot() }
        let scheduledSummaries = scheduled.filter { !$0.deleted }.map { $0.toSummary() }
        return projector.project(
            cashAccounts: cashAccounts,
            scheduled: scheduledSummaries,
            asOf: .now,
            horizonDays: horizon,
            dipThreshold: dipThreshold
        )
    }

    private var cashPoints: [CashPositionPoint] { cashProjection.points }
    private var alerts: [CashPositionProjector.AlertPoint] { cashProjection.alerts }

    private var cashCard: some View {
        NwCard(style: .primary) {
            VStack(alignment: .leading, spacing: NwSpacing.md) {
                Text("Cash Position — Next \(horizon) Days")
                    .font(NwTypography.headline)
                Chart(cashPoints) { point in
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
                        y: .value("Balance", point.balance.doubleValue)
                    )
                    .foregroundStyle(NwAppColors.accent)
                }
                .frame(height: 200)
            }
        }
    }

    private var alertsCard: some View {
        NwCard(style: .primary) {
            VStack(alignment: .leading, spacing: NwSpacing.md) {
                Text("Heads-up")
                    .font(NwTypography.headline)
                ForEach(alerts.prefix(6)) { alert in
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
                    if alert.id != alerts.prefix(6).last?.id { Divider() }
                }
            }
        }
    }
}

private struct CCForecastCard: View {
    let projection: StatementProjection

    var body: some View {
        NwCard(style: .primary) {
            VStack(alignment: .leading, spacing: NwSpacing.md) {
                HStack {
                    NwIcon.creditCard.image.foregroundStyle(NwAppColors.accent)
                    Text(projection.cardName).font(NwTypography.headline)
                    Spacer()
                    NwStatusBadge("Closes \(DateDisplay.relativeDay(projection.nextCloseDate, relativeTo: projection.asOf))",
                                  style: .info, icon: nil)
                }

                VStack(alignment: .leading, spacing: NwSpacing.xs) {
                    Text("Projected statement")
                        .font(NwTypography.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    NwAmountText(projection.projectedStatementBalance, variant: .large)
                }

                Divider()

                HStack {
                    detail("Current owed", value: projection.currentBalanceOwed)
                    Spacer()
                    detail("Charges before close", value: projection.scheduledChargesBeforeClose,
                           color: NwAppColors.liability)
                    Spacer()
                    detail("Payments before close", value: projection.scheduledPaymentsBeforeClose,
                           color: NwAppColors.positive)
                }
            }
        }
    }

    @ViewBuilder
    private func detail(_ label: String, value: Money, color: Color = NwAppColors.textSecondary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(NwTypography.caption)
                .foregroundStyle(.secondary)
            Text(CurrencyFormatter.compact(value))
                .font(NwTypography.footnoteEm)
                .foregroundStyle(color)
        }
    }
}
