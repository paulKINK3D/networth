import SwiftUI
import SwiftData
import Charts
import NetworthCore

/// Spending awareness + sinking funds. Two jobs, zero judgment:
/// see what was spent per category each month, and earmark money for big
/// future purchases so spending it later reads as the plan succeeding.
/// No budget targets, no coaching. (Type keeps its historical name; the tab
/// label is "Spending".)
struct BudgetView: View {
    @Environment(AppContainerController.self) private var container
    @Query private var userSettings: [DurableUserSettings]
    @Query private var assignmentRows: [DurableBudgetCategoryAssignment]
    @Query(sort: \DurableSinkingFund.name)
    private var fundRows: [DurableSinkingFund]
    @Query private var fundEventRows: [DurableFundEvent]

    /// Selected month relative to today: previous 12 months through current.
    @State private var monthOffset = 0
    @State private var report: SpendingReportModel?
    @State private var activeCategory: SpendingCategorySelection?
    @State private var activeFundId: FundSelection?
    @State private var fundEditorTarget: FundEditorTarget?
    @State private var showingExclusions = false

    private var settings: DurableUserSettings? { userSettings.first }
    private var currentMonth: BudgetMonth { BudgetMonth(containing: .now) }
    private var selectedMonth: BudgetMonth {
        currentMonth.advanced(by: monthOffset)
    }
    private var monthTitle: String {
        selectedMonth.startDate()
            .formatted(.dateTime.month(.wide).year())
    }
    /// Coarse invalidation key: any durable input change rebuilds. Month
    /// navigation is deliberately absent — the report covers every month, so
    /// switching months is a pure lookup, never a refetch.
    private var rebuildKey: String {
        let fundStamp = fundRows.map(\.updatedAt).max() ?? .distantPast
        let assignmentStamp = assignmentRows.map(\.updatedAt).max()
            ?? .distantPast
        return [
            "\(fundRows.count):\(fundStamp.timeIntervalSince1970)",
            "\(fundEventRows.count)",
            "\(assignmentRows.count):\(assignmentStamp.timeIntervalSince1970)",
            "\(settings?.primaryFinancialDataSource.rawValue ?? "")"
        ].joined(separator: "|")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NwSpacing.lg) {
                    if let report {
                        let summary = report.summary(for: selectedMonth)
                        let available = report.available(for: selectedMonth)
                        SpendingTotalCard(
                            summary: summary,
                            isCurrentMonth: monthOffset == 0
                        )
                        GroupsCard(
                            summary: summary,
                            availableByCategoryKey: available,
                            groupNameByCategoryKey:
                                report.groupNameByCategoryKey
                        )
                        CategoryListCard(
                            summary: summary,
                            availableByCategoryKey: available,
                            fundNameByCategoryKey:
                                report.fundNameByCategoryKey
                        ) { line in
                            activeCategory = SpendingCategorySelection(
                                key: line.id, name: line.name
                            )
                        }
                        fundsSection(report)
                    } else {
                        NwLoadingState("Loading spending…")
                            .frame(maxWidth: .infinity)
                            .padding(.top, NwSpacing.xxl)
                    }
                }
                .padding(.horizontal, NwSpacing.screenPadding)
                .padding(.vertical, NwSpacing.lg)
            }
            .background(NwAppColors.background.ignoresSafeArea())
            .navigationTitle(monthTitle)
            .toolbar { spendingToolbar }
            .sheet(item: $activeCategory) { selection in
                CategoryDetailSheet(
                    selection: selection,
                    month: selectedMonth
                )
                .environment(container)
            }
            .sheet(item: $activeFundId) { selection in
                FundDetailSheet(
                    fundId: selection.id,
                    report: report
                ) { target in
                    fundEditorTarget = target
                }
                .environment(container)
            }
            .sheet(item: $fundEditorTarget) { target in
                FundEditorSheet(target: target)
                    .environment(container)
            }
            .sheet(isPresented: $showingExclusions) {
                SpendingExclusionsSheet()
                    .environment(container)
            }
            .task(id: rebuildKey) { await rebuild() }
        }
    }

    // MARK: - Funds section

    @ViewBuilder
    private func fundsSection(_ report: SpendingReportModel) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Funds")
                .font(NwTypography.title)
            Spacer()
            if report.setAsideTotal.milliunits > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    NwAmountText(
                        report.setAsideTotal, variant: .compact,
                        showCents: false, color: NwAppColors.accent
                    )
                    Text("set aside")
                        .font(NwTypography.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, NwSpacing.sm)

        if report.fundSnapshots.isEmpty {
            NwCard(style: .secondary) {
                VStack(alignment: .leading, spacing: NwSpacing.sm) {
                    Text("Set money aside for something big")
                        .font(NwTypography.bodyEmphasis)
                    Text("Travel, furniture, a car — fund it over time, then spend it as planned.")
                        .font(NwTypography.footnote)
                        .foregroundStyle(.secondary)
                    Button {
                        fundEditorTarget = .new
                    } label: {
                        Text("New Fund")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(NwPrimaryButtonStyle())
                }
            }
        } else {
            ForEach(report.fundSnapshots) { snapshot in
                FundCard(snapshot: snapshot) {
                    if let id = UUID(uuidString: snapshot.fund.id) {
                        activeFundId = FundSelection(id: id)
                    }
                }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var spendingToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                monthOffset -= 1
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(monthOffset <= -12)
            .accessibilityLabel("Previous month")

            Button {
                monthOffset += 1
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(monthOffset >= 0)
            .accessibilityLabel("Next month")

            Menu {
                Button {
                    fundEditorTarget = .new
                } label: {
                    Label("New Fund", systemImage: NwIcon.add.rawValue)
                }
                Button {
                    showingExclusions = true
                } label: {
                    Label(
                        "Excluded Categories",
                        systemImage: NwIcon.settings.rawValue
                    )
                }
                if monthOffset != 0 {
                    Button {
                        monthOffset = 0
                    } label: {
                        Label(
                            "Today",
                            systemImage: "arrow.uturn.backward"
                        )
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: - Data

    private func rebuild() async {
        let request = SpendingReportRequest(
            usesPlaid: settings?.primaryFinancialDataSource == .plaid,
            assignments: SpendingReportBuilder.assignments(
                from: assignmentRows
            ),
            funds: fundRows.filter { !$0.archived }.map { $0.toCore() },
            manualEntries: fundEventRows.map { $0.toCore() },
            asOf: .now
        )
        // @ModelActor inherits the executor of the thread that creates it —
        // built on the main actor it would run the whole aggregation ON main.
        // Detach so the actor (and its ModelContext) live off-main.
        let modelContainer = container.modelContainer
        let built = await Task.detached(priority: .userInitiated) {
            let dataActor = BudgetDataActor(modelContainer: modelContainer)
            return await dataActor.spendingReport(request)
        }.value
        guard !Task.isCancelled else { return }
        report = built
    }
}

// MARK: - Selections

private struct SpendingCategorySelection: Identifiable {
    let key: String
    let name: String
    var id: String { key }
}

private struct FundSelection: Identifiable {
    let id: UUID
}

enum FundEditorTarget: Identifiable {
    case new
    case edit(UUID)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let id): id.uuidString
        }
    }
}

// MARK: - Report model + builder

/// One category's YNAB envelope state for a month. `available` is the true
/// envelope balance — carryover from prior months included — not merely what
/// was assigned this month.
struct EnvelopeCategory: Sendable {
    let name: String
    let availableMilliunits: Int64
}

struct SpendingReportModel: Sendable {
    /// Every month at once — navigation is a lookup, never a refetch.
    let summariesByMonth: [BudgetMonth: MonthlySpendingSummary]
    /// Month id → category key → envelope state (YNAB import; empty on Plaid).
    let availableByMonthId: [String: [String: EnvelopeCategory]]
    /// Category key → YNAB group name.
    let groupNameByCategoryKey: [String: String]
    let fundSnapshots: [FundSnapshot]
    /// Category key → fund name, for the quiet "from <Fund>" row tag.
    let fundNameByCategoryKey: [String: String]
    /// Sum of positive fund balances.
    let setAsideTotal: Money

    func summary(for month: BudgetMonth) -> MonthlySpendingSummary {
        summariesByMonth[month] ?? MonthlySpendingSummary(
            month: month, total: .zero, categories: []
        )
    }

    func available(for month: BudgetMonth) -> [String: EnvelopeCategory] {
        availableByMonthId[month.id] ?? [:]
    }
}

struct SpendingReportRequest: Sendable {
    let usesPlaid: Bool
    let assignments: BudgetBucketAssignments
    let funds: [SinkingFund]
    let manualEntries: [FundLedgerEntry]
    let asOf: Date
}

struct CategoryDetailRequest: Sendable {
    let categoryKey: String
    let month: BudgetMonth
    let usesPlaid: Bool
    let assignments: BudgetBucketAssignments
    let asOf: Date
}

struct CategoryDetailModel: Sendable {
    let items: [BudgetSpendItem]
    let history: [(month: BudgetMonth, amount: Money)]
}

/// Background executor for report assembly. Owns its own ModelContext so the
/// multi-month transaction fetch never blocks the UI.
@ModelActor
actor BudgetDataActor {
    func spendingReport(
        _ request: SpendingReportRequest
    ) -> SpendingReportModel {
        SpendingReportBuilder.build(request: request, context: modelContext)
    }

    func categoryDetail(
        _ request: CategoryDetailRequest
    ) -> CategoryDetailModel {
        SpendingReportBuilder.categoryDetail(
            request: request, context: modelContext
        )
    }
}

enum SpendingReportBuilder {
    @MainActor
    static func assignments(
        from rows: [DurableBudgetCategoryAssignment]
    ) -> BudgetBucketAssignments {
        var result = BudgetBucketAssignments()
        for row in rows where !row.categoryKey.isEmpty {
            result.assign(row.bucket, categoryKey: row.categoryKey)
            if !row.categoryName.isEmpty {
                result.assign(row.bucket, categoryName: row.categoryName)
            }
        }
        return result
    }

    static func build(
        request: SpendingReportRequest,
        context: ModelContext,
        calendar: Calendar = .current
    ) -> SpendingReportModel {
        let transactions = fetchTransactions(
            context: context,
            usesPlaid: request.usesPlaid,
            monthsBack: 26,
            asOf: request.asOf,
            calendar: calendar
        )
        let aggregator = BudgetTransactionAggregator()
        let summaries = aggregator.spendingSummaries(
            transactions: transactions,
            assignments: request.assignments,
            calendar: calendar
        )

        // Group + budgeted maps from the YNAB category cache.
        let cachedCategories = (try? context.fetch(
            FetchDescriptor<CachedCategory>()
        )) ?? []
        var groupByKey: [String: String] = [:]
        var nameByCategoryId: [String: String] = [:]
        for category in cachedCategories where !category.deleted {
            let key = BudgetBucketAssignments.normalizedName(category.name)
            groupByKey[key] = category.groupName
            nameByCategoryId[category.id] = category.name
        }
        let canonicalRows = (try? context.fetch(
            FetchDescriptor<DurableCanonicalCategory>()
        )) ?? []
        for row in canonicalRows where !row.deletedAtSource {
            let key = BudgetBucketAssignments.normalizedName(row.name)
            if groupByKey[key] == nil, !row.groupName.isEmpty {
                groupByKey[key] = row.groupName
            }
        }

        var availableByMonthId: [String: [String: EnvelopeCategory]] = [:]
        let monthRows = (try? context.fetch(
            FetchDescriptor<CachedCategoryMonth>()
        )) ?? []
        for row in monthRows {
            guard let name = nameByCategoryId[row.categoryId] else { continue }
            let key = BudgetBucketAssignments.normalizedName(name)
            let resolved = request.assignments.bucket(
                categoryCanonicalId: nil,
                categoryId: row.categoryId,
                categoryName: name
            ) ?? BudgetBucketDefaults.bucket(
                forCategoryName: name, groupName: groupByKey[key] ?? ""
            )
            if resolved == .income || resolved == .excluded { continue }
            availableByMonthId[
                String(row.month.prefix(7)), default: [:]
            ][key] = EnvelopeCategory(
                name: name, availableMilliunits: row.balanceMilliunits
            )
        }

        let linked = aggregator.linkedSpending(
            for: request.funds,
            transactions: transactions,
            assignments: request.assignments,
            calendar: calendar
        )
        let snapshots = request.funds
            .map { fund in
                FundMath.snapshot(
                    fund: fund,
                    manualEntries: request.manualEntries.filter {
                        $0.fundId == fund.id
                    },
                    linkedSpending: linked[fund.id] ?? .zero,
                    asOf: request.asOf,
                    calendar: calendar
                )
            }
            .sorted {
                $0.fund.name.localizedCaseInsensitiveCompare($1.fund.name)
                    == .orderedAscending
            }
        var fundNames: [String: String] = [:]
        for fund in request.funds where fund.spendMode == .saveToSpend {
            for key in fund.linkedCategoryKeys {
                fundNames[key] = fund.name
            }
        }
        return SpendingReportModel(
            summariesByMonth: summaries,
            availableByMonthId: availableByMonthId,
            groupNameByCategoryKey: groupByKey,
            fundSnapshots: snapshots,
            fundNameByCategoryKey: fundNames,
            setAsideTotal: snapshots
                .map { Money(milliunits: max(0, $0.balance.milliunits)) }
                .sum()
        )
    }

    static func categoryDetail(
        request: CategoryDetailRequest,
        context: ModelContext,
        calendar: Calendar = .current
    ) -> CategoryDetailModel {
        let transactions = fetchTransactions(
            context: context,
            usesPlaid: request.usesPlaid,
            monthsBack: 14,
            asOf: request.asOf,
            calendar: calendar
        )
        let aggregator = BudgetTransactionAggregator()
        let items = aggregator.categoryItems(
            categoryKey: request.categoryKey,
            in: request.month,
            transactions: transactions,
            assignments: request.assignments,
            calendar: calendar
        )
        let summaries = aggregator.spendingSummaries(
            transactions: transactions,
            assignments: request.assignments,
            calendar: calendar
        )
        let history: [(BudgetMonth, Money)] = (0..<12)
            .map { request.month.advanced(by: -$0) }
            .map { month in
                (
                    month,
                    summaries[month]?.categories
                        .first { $0.id == request.categoryKey }?
                        .amount ?? .zero
                )
            }
        return CategoryDetailModel(items: items, history: history)
    }

    private static func fetchTransactions(
        context: ModelContext,
        usesPlaid: Bool,
        monthsBack: Int,
        asOf: Date,
        calendar: Calendar
    ) -> [TransactionSummary] {
        let cutoff = calendar.date(
            byAdding: .month, value: -monthsBack, to: asOf
        ) ?? asOf
        if usesPlaid {
            let descriptor = FetchDescriptor<CachedFinancialTransaction>(
                predicate: #Predicate { $0.postedDate >= cutoff }
            )
            let rows = (try? context.fetch(descriptor)) ?? []
            return rows.compactMap { $0.toProjectionSummary() }
        }
        let payees = (try? context.fetch(
            FetchDescriptor<DurableCanonicalPayee>()
        )) ?? []
        let categories = (try? context.fetch(
            FetchDescriptor<DurableCanonicalCategory>()
        )) ?? []
        let payeeMap = Dictionary(
            payees.compactMap { payee in
                payee.ynabPayeeId.map { ($0, payee.canonicalId) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let categoryMap = Dictionary(
            categories.compactMap { category in
                category.ynabCategoryId.map { ($0, category.canonicalId) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let descriptor = FetchDescriptor<CachedTransaction>(
            predicate: #Predicate { $0.date >= cutoff && !$0.deleted }
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        return rows.map {
            $0.toSummary(
                payeeCanonicalIdByYnabId: payeeMap,
                categoryCanonicalIdByYnabId: categoryMap
            )
        }
    }
}

// MARK: - Spending cards

private struct SpendingTotalCard: View {
    let summary: MonthlySpendingSummary
    let isCurrentMonth: Bool

    var body: some View {
        NwCard(style: .primary) {
            VStack(alignment: .leading, spacing: NwSpacing.sm) {
                Text(isCurrentMonth ? "Spent So Far" : "Spent")
                    .font(NwTypography.footnoteEm)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                NwAmountText(
                    summary.total, variant: .hero, showCents: false
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Category-group roll-up for the selected month: budgeted vs spent per
/// group, with a subtle proportion bar for glanceability.
private struct GroupsCard: View {
    let summary: MonthlySpendingSummary
    let availableByCategoryKey: [String: EnvelopeCategory]
    let groupNameByCategoryKey: [String: String]

    private struct GroupLine: Identifiable {
        let id: String
        let name: String
        let spent: Money
        let available: Money
    }

    private var lines: [GroupLine] {
        var spentByGroup: [String: Int64] = [:]
        var availableByGroup: [String: Int64] = [:]
        for line in summary.categories {
            let group = groupNameByCategoryKey[line.id] ?? "Other"
            spentByGroup[group, default: 0] += line.amount.milliunits
        }
        for (key, envelope) in availableByCategoryKey
        where envelope.availableMilliunits != 0 {
            let group = groupNameByCategoryKey[key] ?? "Other"
            availableByGroup[group, default: 0]
                += envelope.availableMilliunits
            if spentByGroup[group] == nil { spentByGroup[group] = 0 }
        }
        return spentByGroup
            .map { group, spent in
                GroupLine(
                    id: group,
                    name: group,
                    spent: Money(milliunits: spent),
                    available: Money(
                        milliunits: availableByGroup[group] ?? 0
                    )
                )
            }
            .sorted {
                if $0.spent != $1.spent { return $0.spent > $1.spent }
                return $0.name.localizedCaseInsensitiveCompare($1.name)
                    == .orderedAscending
            }
    }

    var body: some View {
        let lines = self.lines
        let maxSpent = max(1, lines.map(\.spent.milliunits).max() ?? 1)
        NwCard(style: .primary) {
            VStack(alignment: .leading, spacing: NwSpacing.sm) {
                HStack {
                    Text("Groups")
                        .font(NwTypography.headline)
                    Spacer()
                    Text("Available")
                        .font(NwTypography.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 84, alignment: .trailing)
                    Text("Spent")
                        .font(NwTypography.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 84, alignment: .trailing)
                }
                if lines.isEmpty {
                    Text("No activity")
                        .font(NwTypography.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, NwSpacing.sm)
                }
                ForEach(lines) { line in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(line.name)
                                .font(NwTypography.body)
                                .lineLimit(1)
                            Spacer()
                            NwAmountText(
                                line.available, variant: .body,
                                showCents: false,
                                color: line.available.isNegative
                                    ? NwAppColors.liability
                                    : NwAppColors.textSecondary
                            )
                            .frame(width: 84, alignment: .trailing)
                            NwAmountText(
                                line.spent, variant: .compact,
                                showCents: false
                            )
                            .frame(width: 84, alignment: .trailing)
                        }
                        GeometryReader { proxy in
                            Capsule()
                                .fill(NwAppColors.primary.opacity(0.55))
                                .frame(
                                    width: proxy.size.width
                                        * CGFloat(max(0, line.spent.milliunits))
                                        / CGFloat(maxSpent)
                                )
                        }
                        .frame(height: 3)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

private struct CategoryListCard: View {
    let summary: MonthlySpendingSummary
    let availableByCategoryKey: [String: EnvelopeCategory]
    let fundNameByCategoryKey: [String: String]
    let onTap: (BudgetCategorySpendLine) -> Void

    private struct Row: Identifiable {
        let id: String
        let name: String
        let available: Money?
        let spent: Money
    }

    /// Union of spent and funded categories: an envelope holding money with
    /// no spending still shows, and spending with no envelope still shows.
    private var rows: [Row] {
        var byKey: [String: Row] = [:]
        for line in summary.categories {
            byKey[line.id] = Row(
                id: line.id,
                name: line.name,
                available: availableByCategoryKey[line.id].map {
                    Money(milliunits: $0.availableMilliunits)
                },
                spent: line.amount
            )
        }
        for (key, envelope) in availableByCategoryKey
        where byKey[key] == nil && envelope.availableMilliunits != 0 {
            byKey[key] = Row(
                id: key,
                name: envelope.name,
                available: Money(milliunits: envelope.availableMilliunits),
                spent: .zero
            )
        }
        return byKey.values.sorted { lhs, rhs in
            if lhs.spent != rhs.spent { return lhs.spent > rhs.spent }
            let lhsAvailable = lhs.available ?? .zero
            let rhsAvailable = rhs.available ?? .zero
            if lhsAvailable != rhsAvailable {
                return lhsAvailable > rhsAvailable
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                == .orderedAscending
        }
    }

    var body: some View {
        let rows = self.rows
        NwCard(style: .primary) {
            VStack(alignment: .leading, spacing: NwSpacing.sm) {
                HStack {
                    Text("Categories")
                        .font(NwTypography.headline)
                    Spacer()
                    Text("Available")
                        .font(NwTypography.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 84, alignment: .trailing)
                    Text("Spent")
                        .font(NwTypography.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 84, alignment: .trailing)
                }
                if rows.isEmpty {
                    Text("No spending recorded")
                        .font(NwTypography.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, NwSpacing.sm)
                }
                ForEach(rows) { row in
                    Button {
                        onTap(BudgetCategorySpendLine(
                            id: row.id, name: row.name, amount: row.spent
                        ))
                    } label: {
                        HStack(spacing: NwSpacing.sm) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name)
                                    .font(NwTypography.body)
                                    .foregroundStyle(NwAppColors.textPrimary)
                                    .lineLimit(1)
                                if let fund =
                                    fundNameByCategoryKey[row.id],
                                    row.spent.milliunits > 0 {
                                    Text("from \(fund)")
                                        .font(NwTypography.caption)
                                        .foregroundStyle(NwAppColors.accent)
                                }
                            }
                            Spacer()
                            Group {
                                if let available = row.available {
                                    NwAmountText(
                                        available, variant: .body,
                                        showCents: false,
                                        color: available.isNegative
                                            ? NwAppColors.liability
                                            : NwAppColors.textSecondary
                                    )
                                } else {
                                    Text("—")
                                        .font(NwTypography.body)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 84, alignment: .trailing)
                            NwAmountText(
                                row.spent, variant: .compact,
                                showCents: false
                            )
                            .frame(width: 84, alignment: .trailing)
                        }
                        .padding(.vertical, NwSpacing.xs)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if row.id != rows.last?.id {
                        Divider()
                    }
                }
            }
        }
    }
}

// MARK: - Fund cards

private struct FundCard: View {
    let snapshot: FundSnapshot
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            NwCard(style: .primary) {
                VStack(alignment: .leading, spacing: NwSpacing.sm) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(snapshot.fund.name)
                            .font(NwTypography.headline)
                            .foregroundStyle(NwAppColors.textPrimary)
                        Spacer()
                        NwAmountText(
                            snapshot.balance, variant: .compact,
                            showCents: false,
                            color: snapshot.balance.isNegative
                                ? NwAppColors.liability
                                : NwAppColors.textPrimary
                        )
                    }
                    if let progress = snapshot.progressFraction {
                        ProgressView(value: progress)
                            .tint(
                                snapshot.status == .funded
                                    ? NwAppColors.positive
                                    : NwAppColors.accent
                            )
                        HStack {
                            Text(statusLine)
                                .font(NwTypography.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            HStack(spacing: 2) {
                                Text("of")
                                    .font(NwTypography.caption)
                                    .foregroundStyle(.secondary)
                                NwAmountText(
                                    snapshot.fund.target,
                                    variant: .body, showCents: false,
                                    color: NwAppColors.textSecondary
                                )
                            }
                        }
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var statusLine: String {
        switch snapshot.status {
        case .openEnded:
            return ""
        case .funded:
            return "Funded"
        case .saving:
            return "Saving"
        case .onTrack(let required):
            return "On track · needs \(CurrencyFormatter.compact(required))/mo"
        case .behind(let required):
            return "Needs \(CurrencyFormatter.compact(required))/mo"
        }
    }
}

// MARK: - Sheet shell + shared rows

private struct BudgetSheetShell<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        NavigationStack {
            List { content }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { dismiss() } label: {
                            NwIcon.close.image
                                .foregroundStyle(NwAppColors.liability)
                        }
                        .accessibilityLabel("Close")
                    }
                }
        }
    }
}

private struct BudgetAmountRow: View {
    let title: String
    let amount: Money
    var color: Color? = nil

    var body: some View {
        HStack {
            Text(title).font(NwTypography.body)
            Spacer()
            NwAmountText(
                amount, variant: .compact, showCents: false, color: color
            )
        }
    }
}

private extension BudgetMonth {
    var sheetTitle: String {
        startDate().formatted(.dateTime.month(.abbreviated).year())
    }
}

// MARK: - Category detail

private struct CategoryDetailSheet: View {
    @Environment(AppContainerController.self) private var container
    @Query private var userSettings: [DurableUserSettings]
    @Query private var assignmentRows: [DurableBudgetCategoryAssignment]
    let selection: SpendingCategorySelection
    let month: BudgetMonth
    @State private var detail: CategoryDetailModel?

    var body: some View {
        BudgetSheetShell(
            title: "\(selection.name) · \(month.sheetTitle)"
        ) {
            if let detail {
                Section {
                    BudgetAmountRow(
                        title: "Total",
                        amount: detail.items.map(\.amount).sum()
                    )
                }
                Section("Transactions") {
                    if detail.items.isEmpty {
                        Text("No activity")
                            .font(NwTypography.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(detail.items) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.payeeName)
                                    .font(NwTypography.body)
                                Text(item.date.formatted(
                                    .dateTime.month(.abbreviated).day()
                                ))
                                .font(NwTypography.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            NwAmountText(
                                item.amount, variant: .compact,
                                showCents: false
                            )
                        }
                    }
                }
                Section("History") {
                    ForEach(detail.history, id: \.month) { entry in
                        HStack {
                            Text(entry.month.startDate().formatted(
                                .dateTime.month(.wide).year()
                            ))
                            .font(NwTypography.body)
                            Spacer()
                            NwAmountText(
                                entry.amount, variant: .compact,
                                showCents: false
                            )
                        }
                    }
                }
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading…")
                        .font(NwTypography.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        let request = CategoryDetailRequest(
            categoryKey: selection.key,
            month: month,
            usesPlaid: userSettings.first?.primaryFinancialDataSource
                == .plaid,
            assignments: SpendingReportBuilder.assignments(
                from: assignmentRows
            ),
            asOf: .now
        )
        // See rebuild(): detach so the model actor runs off-main.
        let modelContainer = container.modelContainer
        detail = await Task.detached(priority: .userInitiated) {
            let dataActor = BudgetDataActor(modelContainer: modelContainer)
            return await dataActor.categoryDetail(request)
        }.value
    }
}

// MARK: - Fund detail

private struct FundDetailSheet: View {
    @Environment(AppContainerController.self) private var container
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var fundRows: [DurableSinkingFund]
    @Query(sort: \DurableFundEvent.date, order: .reverse)
    private var eventRows: [DurableFundEvent]
    let fundId: UUID
    let report: SpendingReportModel?
    let onEdit: (FundEditorTarget) -> Void
    @State private var entrySign: FundEntrySign?

    private var fundRow: DurableSinkingFund? {
        fundRows.first { $0.id == fundId }
    }
    private var snapshot: FundSnapshot? {
        report?.fundSnapshots.first { $0.fund.id == fundId.uuidString }
    }
    private var events: [DurableFundEvent] {
        eventRows.filter { $0.fundId == fundId }
    }

    var body: some View {
        BudgetSheetShell(title: fundRow?.name ?? "Fund") {
            if let snapshot {
                Section {
                    BudgetAmountRow(
                        title: "Set aside", amount: snapshot.balance,
                        color: snapshot.balance.isNegative
                            ? NwAppColors.liability : NwAppColors.accent
                    )
                    if snapshot.fund.target.milliunits > 0 {
                        BudgetAmountRow(
                            title: "Target", amount: snapshot.fund.target
                        )
                    }
                    if snapshot.linkedSpending.milliunits != 0 {
                        BudgetAmountRow(
                            title: "Spent from fund",
                            amount: snapshot.linkedSpending
                        )
                    }
                    if case .onTrack(let required) = snapshot.status {
                        BudgetAmountRow(
                            title: "Needed monthly", amount: required,
                            color: NwAppColors.positive
                        )
                    }
                    if case .behind(let required) = snapshot.status {
                        BudgetAmountRow(
                            title: "Needed monthly", amount: required,
                            color: NwAppColors.caution
                        )
                    }
                }
            }
            Section {
                Button {
                    entrySign = .contribution
                } label: {
                    Label("Add Money", systemImage: NwIcon.add.rawValue)
                }
                Button {
                    entrySign = .withdrawal
                } label: {
                    Label("Withdraw", systemImage: "minus")
                }
                Button {
                    if let fundRow {
                        dismiss()
                        onEdit(.edit(fundRow.id))
                    }
                } label: {
                    Label("Edit Fund", systemImage: NwIcon.edit.rawValue)
                }
            }
            Section("Ledger") {
                if events.isEmpty {
                    Text("No entries yet")
                        .font(NwTypography.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(events) { event in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(
                                event.amountMilliunits >= 0
                                    ? (event.note ?? "Contribution")
                                    : (event.note ?? "Withdrawal")
                            )
                            .font(NwTypography.body)
                            Text(event.date.formatted(
                                .dateTime.month(.abbreviated).day().year()
                            ))
                            .font(NwTypography.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        NwAmountText(
                            Money(milliunits: event.amountMilliunits),
                            variant: .compact, showCents: false
                        )
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", role: .destructive) {
                            context.delete(event)
                            context.safeSave(source: "fundEventDelete")
                        }
                    }
                }
            }
        }
        .sheet(item: $entrySign) { sign in
            FundEntrySheet(fundId: fundId, sign: sign)
                .environment(container)
        }
    }
}

private enum FundEntrySign: String, Identifiable {
    case contribution
    case withdrawal
    var id: String { rawValue }
}

/// Quick manual entry: whole dollars, optional note, saves deterministically.
private struct FundEntrySheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let fundId: UUID
    let sign: FundEntrySign
    @State private var dollarsText = ""
    @State private var note = ""
    @State private var date = Date.now

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Amount", text: $dollarsText)
                        .keyboardType(.numberPad)
                    TextField("Note (optional)", text: $note)
                    DatePicker(
                        "Date", selection: $date, displayedComponents: .date
                    )
                }
            }
            .navigationTitle(
                sign == .contribution ? "Add Money" : "Withdraw"
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        NwIcon.close.image
                            .foregroundStyle(NwAppColors.liability)
                    }
                    .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { save() } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(NwAppColors.positive)
                    }
                    .disabled((Int64(dollarsText) ?? 0) <= 0)
                    .accessibilityLabel("Save")
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        guard let dollars = Int64(dollarsText), dollars > 0 else { return }
        let signed = sign == .contribution ? dollars : -dollars
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        context.insert(DurableFundEvent(
            fundId: fundId,
            date: date,
            amountMilliunits: signed * 1_000,
            note: trimmedNote.isEmpty ? nil : trimmedNote
        ))
        context.safeSave(source: "fundEventSave")
        dismiss()
    }
}

// MARK: - Fund editor

private struct FundEditorSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var fundRows: [DurableSinkingFund]
    @Query(sort: \DurableCanonicalCategory.name)
    private var canonicalCategories: [DurableCanonicalCategory]
    @Query(sort: \CachedCategory.name)
    private var cachedCategories: [CachedCategory]
    let target: FundEditorTarget

    @State private var name = ""
    @State private var targetDollarsText = ""
    @State private var hasTargetDate = false
    @State private var targetDate = Date.now
    @State private var plannedDollarsText = ""
    @State private var spendMode: FundSpendMode = .saveToSpend
    @State private var linkedKeys: Set<String> = []
    @State private var seeded = false
    @State private var confirmingArchive = false

    private var editedRow: DurableSinkingFund? {
        guard case .edit(let id) = target else { return nil }
        return fundRows.first { $0.id == id }
    }

    private var categoryOptions: [DiscretionaryCategoryOption] {
        DiscretionaryCategoryResolver.options(
            canonical: canonicalCategories,
            cached: cachedCategories,
            activeOnly: true
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Target amount", text: $targetDollarsText)
                        .keyboardType(.numberPad)
                    Toggle("Target date", isOn: $hasTargetDate)
                    if hasTargetDate {
                        DatePicker(
                            "By", selection: $targetDate,
                            displayedComponents: .date
                        )
                    }
                    TextField(
                        "Planned monthly (optional)",
                        text: $plannedDollarsText
                    )
                    .keyboardType(.numberPad)
                }
                Section {
                    Picker("When spent", selection: $spendMode) {
                        ForEach(FundSpendMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(spendMode == .saveToSpend
                        ? "Spending drains the fund — that's the plan working."
                        : "Spending drains the fund and it quietly asks for a refill.")
                }
                Section("Linked Categories") {
                    if categoryOptions.isEmpty {
                        Text("No categories yet")
                            .font(NwTypography.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(categoryOptions) { option in
                        let key = BudgetBucketAssignments.normalizedName(
                            option.name
                        )
                        Button {
                            if linkedKeys.contains(key) {
                                linkedKeys.remove(key)
                            } else {
                                linkedKeys.insert(key)
                            }
                        } label: {
                            HStack {
                                Text(option.name)
                                    .font(NwTypography.body)
                                    .foregroundStyle(NwAppColors.textPrimary)
                                Spacer()
                                if linkedKeys.contains(key) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(NwAppColors.positive)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if editedRow != nil {
                    Section {
                        Button("Archive Fund", role: .destructive) {
                            confirmingArchive = true
                        }
                    }
                }
            }
            .navigationTitle(editedRow == nil ? "New Fund" : "Edit Fund")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        NwIcon.close.image
                            .foregroundStyle(NwAppColors.liability)
                    }
                    .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { save() } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(NwAppColors.positive)
                    }
                    .disabled(
                        name.trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty
                    )
                    .accessibilityLabel("Save")
                }
            }
            .alert("Archive this fund?", isPresented: $confirmingArchive) {
                Button("Cancel", role: .cancel) {}
                Button("Archive", role: .destructive) { archive() }
            } message: {
                Text("The fund and its ledger stay in your data; it just leaves the screen.")
            }
            .onAppear { seedIfNeeded() }
        }
    }

    private func seedIfNeeded() {
        guard !seeded else { return }
        seeded = true
        guard let row = editedRow else { return }
        name = row.name
        targetDollarsText = row.targetMilliunits > 0
            ? String(row.targetMilliunits / 1_000) : ""
        if let date = row.targetDate {
            hasTargetDate = true
            targetDate = date
        }
        plannedDollarsText = row.plannedMonthlyMilliunits > 0
            ? String(row.plannedMonthlyMilliunits / 1_000) : ""
        spendMode = row.spendMode
        linkedKeys = Set(row.linkedCategoryKeys)
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let row = editedRow ?? {
            let created = DurableSinkingFund()
            context.insert(created)
            return created
        }()
        row.name = trimmedName
        row.targetMilliunits = (Int64(targetDollarsText) ?? 0) * 1_000
        row.targetDate = hasTargetDate ? targetDate : nil
        row.plannedMonthlyMilliunits =
            (Int64(plannedDollarsText) ?? 0) * 1_000
        row.spendMode = spendMode
        row.linkedCategoryKeys = Array(linkedKeys).sorted()
        row.updatedAt = .now
        context.safeSave(source: "fundSave")
        dismiss()
    }

    private func archive() {
        guard let row = editedRow else { return }
        row.archived = true
        row.updatedAt = .now
        context.safeSave(source: "fundArchive")
        dismiss()
    }
}

// MARK: - Excluded categories

/// The one remaining piece of configuration: categories that should never
/// appear in the spending report. Everything else counts automatically.
private struct SpendingExclusionsSheet: View {
    @Environment(\.modelContext) private var context
    @Query private var assignmentRows: [DurableBudgetCategoryAssignment]
    @Query(sort: \DurableCanonicalCategory.name)
    private var canonicalCategories: [DurableCanonicalCategory]
    @Query(sort: \CachedCategory.name)
    private var cachedCategories: [CachedCategory]

    private var categoryOptions: [DiscretionaryCategoryOption] {
        DiscretionaryCategoryResolver.options(
            canonical: canonicalCategories,
            cached: cachedCategories,
            activeOnly: true
        )
    }

    var body: some View {
        BudgetSheetShell(title: "Excluded Categories") {
            Section {
                ForEach(categoryOptions) { option in
                    Toggle(
                        option.name,
                        isOn: excludedBinding(for: option)
                    )
                    .font(NwTypography.body)
                }
            } footer: {
                Text("Excluded categories never appear in spending. Transfers, card payments, and reimbursements are always excluded automatically.")
            }
        }
    }

    private func excludedBinding(
        for option: DiscretionaryCategoryOption
    ) -> Binding<Bool> {
        Binding(
            get: {
                assignmentRows.contains {
                    $0.categoryKey == option.id && $0.bucket == .excluded
                }
            },
            set: { excluded in
                let existing = assignmentRows.first {
                    $0.categoryKey == option.id
                }
                if excluded {
                    if let existing {
                        existing.bucket = .excluded
                        existing.updatedAt = .now
                    } else {
                        context.insert(DurableBudgetCategoryAssignment(
                            categoryKey: option.id,
                            categoryName: option.name,
                            bucket: .excluded
                        ))
                    }
                } else if let existing, existing.bucket == .excluded {
                    context.delete(existing)
                }
                context.safeSave(source: "spendingExclusions")
            }
        )
    }
}
