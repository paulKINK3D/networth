import SwiftUI
import SwiftData
import UIKit
import NetworthCore

/// Goals — long-term savings targets and sinking funds backed by a shared
/// reserve pool of dedicated savings accounts. Headline question: "how am I
/// doing?"
///
/// Funding is pure envelope allocation: the reserve pool is the real savings
/// balance (interest and every transfer already in it), and goals divide that
/// total. Deposits and withdrawals in the real account are never traced to a
/// goal — they only change how much is available to allocate. The one
/// transaction-linked action is "spent from goal," which also pulls the
/// purchase out of Spending.
struct GoalsView: View {
    @SwiftUI.Environment(AppContainerController.self) private var container
    @SwiftUI.Environment(\.modelContext) private var context

    @State private var model: GoalsModel?
    @State private var rebuildTask: Task<Void, Never>?
    @State private var editorTarget: GoalEditorTarget?
    @State private var detailGoalId: UUID?
    @State private var showingReservePicker = false
    @State private var showingAllocate = false
    @State private var serviceError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    if model.reserves.isEmpty
                        && model.activeGoals.isEmpty
                        && model.archivedGoals.isEmpty {
                        ScrollView {
                            emptyState
                                .padding(.horizontal, NwSpacing.screenPadding)
                                .padding(.vertical, NwSpacing.md)
                        }
                    } else {
                        goalsList(model)
                    }
                } else {
                    NwLoadingState("Loading goals…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(NwAppColors.background.ignoresSafeArea())
            .navigationTitle("Goals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingReservePicker = true
                    } label: {
                        Image(systemName: NwIcon.savings.rawValue)
                    }
                    .accessibilityLabel("Reserve accounts")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editorTarget = .create
                    } label: {
                        Image(systemName: NwIcon.add.rawValue)
                    }
                    .accessibilityLabel("New goal")
                }
            }
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
            // Month rollover re-derives the emergency target and MTD sums.
            rebuildTask?.cancel()
            rebuildTask = Task { await rebuild() }
        }
        .sheet(item: $editorTarget) { target in
            GoalEditorSheet(target: target, model: model)
                .environment(container)
        }
        .sheet(item: $detailGoalId) { goalId in
            GoalDetailSheet(goalId: goalId, model: model)
                .environment(container)
        }
        .sheet(isPresented: $showingReservePicker) {
            GoalReservePickerSheet(model: model)
                .environment(container)
        }
        .sheet(isPresented: $showingAllocate) {
            GoalAllocateSheet(
                unallocated: model?.pool.unallocated ?? .zero,
                goals: model?.activeGoals ?? []
            )
            .environment(container)
        }
        .alert(
            "Couldn't Save",
            isPresented: .init(
                get: { serviceError != nil },
                set: { if !$0 { serviceError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(serviceError ?? "")
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: NwSpacing.lg) {
            NwEmptyState(
                title: "Save for the big things",
                message: "Pick the savings accounts that back your goals, "
                    + "then create goals to divide that money by purpose.",
                icon: .goals
            )
            Button {
                showingReservePicker = true
            } label: {
                Label("Choose Reserve Accounts",
                      systemImage: NwIcon.savings.rawValue)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(NwAppColors.accent)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    // MARK: - Reserve pool header

    private func reserveCard(_ model: GoalsModel) -> some View {
        NwCard(style: .primary) {
            VStack(alignment: .leading, spacing: NwSpacing.sm) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Reserve")
                        .font(NwTypography.headline)
                        .foregroundStyle(NwAppColors.textPrimary)
                    Spacer()
                    NwAmountText(
                        model.pool.pool, variant: .large, showCents: false
                    )
                }
                HStack(spacing: NwSpacing.md) {
                    NwMetricCapsule(
                        label: "Allocated",
                        value: CurrencyFormatter.compact(model.pool.allocated)
                    )
                    NwMetricCapsule(
                        label: "Unallocated",
                        value: CurrencyFormatter.compact(
                            model.pool.unallocated
                        )
                    )
                }
                if model.pool.shortfall.milliunits > 0 {
                    NwInlineNotice(
                        "Reserve is short",
                        message: shortfallMessage(model),
                        tone: .caution
                    )
                }
                ForEach(model.unavailableReserves) { reserve in
                    NwInlineNotice(
                        "\(reserve.displayName) unavailable",
                        message: "This account is disconnected; it counts "
                            + "as $0 until you re-attach or remove it.",
                        tone: .caution
                    )
                }
                if !model.activeGoals.isEmpty {
                    Button {
                        showingAllocate = true
                    } label: {
                        Label("Allocate to a Goal",
                              systemImage: "arrow.left.arrow.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(NwAppColors.accent)
                    .disabled(model.pool.unallocated.isZero
                        && model.pool.shortfall.isZero)
                    .padding(.top, NwSpacing.xs)
                }
            }
        }
    }

    private func shortfallMessage(_ model: GoalsModel) -> String {
        "Your reserve balance is "
            + CurrencyFormatter.currency(
                model.pool.shortfall, showCents: false
            )
            + " below what goals have allocated — usually because money left "
            + "the account. Lower an allocation to match."
    }

    // MARK: - List

    private func goalsList(_ model: GoalsModel) -> some View {
        List {
            plainRow { reserveCard(model) }

            if model.activeGoals.isEmpty {
                plainRow {
                    NwCard(style: .secondary) {
                        VStack(spacing: NwSpacing.sm) {
                            Text("No goals yet")
                                .font(NwTypography.body)
                                .foregroundStyle(.secondary)
                            Button("Create a Goal") {
                                editorTarget = .create
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(NwAppColors.accent)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            } else {
                ForEach(model.activeGoals) { item in
                    plainRow {
                        GoalCard(item: item) { detailGoalId = item.goalUUID }
                    }
                }
            }

            if !model.archivedGoals.isEmpty {
                Section("Archived") {
                    ForEach(model.archivedGoals) { item in
                        plainRow {
                            GoalCard(item: item) {
                                detailGoalId = item.goalUUID
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    /// A card row that keeps the card look inside a List: clear background,
    /// no separators, edge-to-edge insets matching the screen padding.
    private func plainRow<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        content()
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(
                top: NwSpacing.xs, leading: NwSpacing.screenPadding,
                bottom: NwSpacing.xs, trailing: NwSpacing.screenPadding
            ))
    }

    // MARK: - Build

    private func rebuild() async {
        // Detached so the full-table fetch and aggregation never run on the
        // UI executor.
        let modelContainer = container.modelContainer
        let built = await Task.detached(priority: .userInitiated) {
            () -> GoalsModel? in
            let actor = GoalsBuildActor(modelContainer: modelContainer)
            return try? await actor.build(now: .now)
        }.value
        guard let built, !Task.isCancelled else { return }
        model = built
        adoptDerivedTargetsIfNeeded(built)
    }

    /// Emergency targets self-adjust with hysteresis. Adoption is a real
    /// write, so it flows through the service; the resulting save triggers
    /// one more rebuild, after which `shouldAdopt` is false and this settles.
    private func adoptDerivedTargetsIfNeeded(_ model: GoalsModel) {
        let adoptions = model.activeGoals.filter {
            $0.derivedEmergencyTarget != nil
        }
        guard !adoptions.isEmpty else { return }
        let service = GoalLedgerService(context: context)
        let goals = (try? context.fetch(
            FetchDescriptor<DurableGoal>()
        )) ?? []
        for item in adoptions {
            guard let target = item.derivedEmergencyTarget,
                  let row = goals.first(where: { $0.id == item.goalUUID })
            else { continue }
            try? service.adoptEmergencyTarget(row, target: target)
        }
    }
}

// MARK: - Model

/// Sendable snapshot the view renders. Built off-main by `GoalsBuildActor`.
struct GoalsModel: Sendable {
    struct GoalItem: Sendable, Identifiable {
        let goal: Goal
        let goalUUID: UUID
        let balance: Money
        let status: FundStatus
        let progress: Double?
        let mtdContributions: Money
        let orphanedEntryCount: Int
        /// Non-nil when a newly derived emergency target passed the
        /// hysteresis rule and should be adopted.
        let derivedEmergencyTarget: Money?
        var id: String { goal.id }
    }

    struct ReserveItem: Sendable, Identifiable {
        let rowId: UUID
        let canonicalAccountId: String
        let displayName: String
        let institutionName: String
        let mask: String
        /// Nil when the backing account is missing or deleted.
        let balance: Money?
        var id: UUID { rowId }
    }

    let pool: ReservePoolSummary
    let reserves: [ReserveItem]
    let activeGoals: [GoalItem]
    let archivedGoals: [GoalItem]
    /// Median monthly ordinary spend over complete months, when derivable.
    let emergencyMedian: Money?
    let sampleMonthCount: Int

    var unavailableReserves: [ReserveItem] {
        reserves.filter { $0.balance == nil }
    }
}

// MARK: - Build actor

/// Off-main aggregation for the Goals tab. Consumes the same shared spending
/// pipeline as Spending History, so the emergency-fund input is exactly the
/// ordinary total the user sees there.
@ModelActor
actor GoalsBuildActor {
    func build(now: Date) throws -> GoalsModel {
        let calendar = Calendar.current
        let goalRows = try modelContext.fetch(FetchDescriptor<DurableGoal>())
        let ledgerRows = try modelContext.fetch(
            FetchDescriptor<DurableGoalLedgerEntry>()
        )
        let reserveRows = try modelContext.fetch(
            FetchDescriptor<DurableGoalReserveAccount>()
        )
        let accounts = try modelContext.fetch(
            FetchDescriptor<CachedFinancialAccount>()
        )
        let plaidAccounts = try modelContext.fetch(
            FetchDescriptor<CachedPlaidAccount>()
        )

        let financialById = Dictionary(
            accounts.map { ($0.canonicalAccountId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let plaidById = Dictionary(
            plaidAccounts.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let activeReserves = reserveRows.filter(\.active)

        // Reserve items + conservative pool balance. Cash accounts resolve
        // from the source-neutral record; a taxable brokerage resolves from
        // the Plaid investments record. Unavailable accounts contribute zero.
        var poolMilliunits: Int64 = 0
        let reserveItems: [GoalsModel.ReserveItem] = activeReserves.map {
            reserve in
            let balance = ReserveBalance.conservative(
                canonicalAccountId: reserve.canonicalAccountId,
                financialById: financialById,
                plaidById: plaidById
            )
            poolMilliunits += balance?.milliunits ?? 0
            return GoalsModel.ReserveItem(
                rowId: reserve.id,
                canonicalAccountId: reserve.canonicalAccountId,
                displayName: reserve.accountName,
                institutionName: reserve.institutionName,
                mask: reserve.mask,
                balance: balance
            )
        }

        // Emergency median from the shared pipeline's ordinary totals,
        // complete months only — computed only when an emergency goal needs
        // it, since it runs the full spending aggregation.
        var emergencyMedian: Money?
        var sampleMonthCount = 0
        let needsMedian = goalRows.contains {
            !$0.archived && $0.completedAt == nil
                && $0.targetMode == .emergencyMonths
        }
        if needsMedian {
            let rows = try modelContext.fetch(
                FetchDescriptor<CachedFinancialTransaction>(
                    predicate: #Predicate {
                        !$0.deleted && !$0.pending && !$0.requiresReview
                    }
                )
            )
            let groups = try modelContext.fetch(
                FetchDescriptor<DurableCategoryGroup>()
            )
            let categories = try modelContext.fetch(
                FetchDescriptor<DurableCanonicalCategory>()
            )
            let pipelineContext = SpendingEntryPipeline.Context(
                groups: groups, categories: categories, accounts: accounts
            )
            let entries = SpendingEntryPipeline.adjustedEntries(
                rows: rows, ledgerEntries: ledgerRows,
                context: pipelineContext
            )
            let months = SpendingHistoryBuilder.build(
                entries: entries, monthsBack: 13, now: now,
                calendar: calendar
            )
            // Drop the in-progress current month; use up to 12 complete
            // months with any activity.
            let complete = months.dropLast()
                .filter { $0.ordinaryTotalMilliunits > 0 }
                .suffix(12)
                .map(\.ordinaryTotal)
            sampleMonthCount = complete.count
            emergencyMedian = EmergencyFundMath.medianOfCompleteMonths(
                Array(complete)
            )
        }

        // Goal items.
        let entriesByGoal = Dictionary(
            grouping: ledgerRows, by: \.goalId
        )
        let nonDeletedExternalIds = Set(
            try modelContext.fetch(
                FetchDescriptor<CachedFinancialTransaction>(
                    predicate: #Predicate { !$0.deleted }
                )
            ).map(\.externalId)
        )
        func item(for row: DurableGoal) -> GoalsModel.GoalItem {
            let entries = (entriesByGoal[row.id] ?? []).map { $0.toCore() }
            let balance = GoalMath.balance(entries: entries)
            let goal = row.toCore()
            var derived: Money?
            if goal.targetMode == .emergencyMonths, goal.isActive,
               let median = emergencyMedian {
                let target = EmergencyFundMath.target(
                    medianMonthly: median,
                    months: row.emergencyMonths,
                    reductionPercent: row.emergencyReductionPercent
                )
                if EmergencyFundMath.shouldAdopt(
                    current: goal.target, derived: target
                ) {
                    derived = target
                }
            }
            let orphaned = (entriesByGoal[row.id] ?? []).filter { entry in
                guard let externalId = entry.linkedTransactionExternalId
                else { return false }
                return !nonDeletedExternalIds.contains(externalId)
            }.count
            return GoalsModel.GoalItem(
                goal: goal,
                goalUUID: row.id,
                balance: balance,
                status: GoalMath.status(
                    goal: goal, balance: balance, asOf: now,
                    calendar: calendar
                ),
                progress: GoalMath.progressFraction(
                    balance: balance, target: goal.target
                ),
                mtdContributions: GoalMath.monthToDateContributions(
                    entries: entries, asOf: now, calendar: calendar
                ),
                orphanedEntryCount: orphaned,
                derivedEmergencyTarget: derived
            )
        }
        let active = goalRows
            .filter { !$0.archived && $0.completedAt == nil }
            .sorted { $0.createdAt < $1.createdAt }
            .map(item(for:))
        let archived = goalRows
            .filter { $0.archived || $0.completedAt != nil }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map(item(for:))

        let pool = ReservePoolMath.summary(
            reserveBalance: Money(milliunits: poolMilliunits),
            activeGoalBalances: active.map(\.balance)
        )

        return GoalsModel(
            pool: pool,
            reserves: reserveItems,
            activeGoals: active,
            archivedGoals: archived,
            emergencyMedian: emergencyMedian,
            sampleMonthCount: sampleMonthCount
        )
    }
}

// MARK: - Identifiable helpers

extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}
