import SwiftUI
import SwiftData
import UIKit
import NetworthCore

/// Goals are named allocations backed by user-selected accounts. Headline
/// question: "what is this money for?"
///
/// Funding is pure envelope allocation: the reserve pool is the real savings
/// balance (interest and every transfer already in it), and goals divide that
/// total. Deposits and withdrawals in the real account are never traced to a
/// goal — they only change how much is available to allocate. The one
/// Goal Spend and Goal Refund are explicit transaction types selected during
/// transaction review; the Goals screen never creates shadow transactions.
struct GoalsView: View {
    @SwiftUI.Environment(AppContainerController.self) private var container

    @State private var model: GoalsModel?
    @State private var rebuildTask: Task<Void, Never>?
    @State private var editorTarget: GoalEditorTarget?
    @State private var detailGoalId: UUID?
    @State private var showingReservePicker = false
    @State private var showingAllocate = false
    @State private var transferRequestId: UUID?

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
                    .accessibilityLabel("Goal accounts")
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
                pool: model?.pool.pool ?? .zero,
                goals: model?.activeGoals ?? []
            )
            .environment(container)
        }
        .sheet(item: $transferRequestId) { requestId in
            GoalTransferRequestSheet(requestId: requestId)
                .environment(container)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: NwSpacing.lg) {
            NwEmptyState(
                title: "Save for the big things",
                message: "Pick the accounts that back your goals, "
                    + "then create goals to divide that money by purpose.",
                icon: .goals
            )
            Button {
                showingReservePicker = true
            } label: {
                Label("Choose Goal Accounts",
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
                VStack(alignment: .leading, spacing: NwSpacing.xs) {
                    Text("Available for Goals")
                        .font(NwTypography.headline)
                        .foregroundStyle(NwAppColors.textPrimary)
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
                        message: "This account is excluded or disconnected; "
                            + "it counts as $0 until you re-attach or remove it.",
                        tone: .caution
                    )
                }
                if !model.activeGoals.isEmpty {
                    Button {
                        showingAllocate = true
                    } label: {
                        Label("Edit Allocations",
                              systemImage: "slider.horizontal.3")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(NwAppColors.accent)
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

            ForEach(model.pendingTransfers) { transfer in
                plainRow {
                    GoalTransferRequestCard(transfer: transfer) {
                        transferRequestId = transfer.id
                    }
                }
            }

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
    }
}

// MARK: - Model

/// Sendable snapshot the view renders. Built off-main by `GoalsBuildActor`.
struct GoalsModel: Sendable {
    struct GoalItem: Sendable, Identifiable {
        let goal: Goal
        let goalUUID: UUID
        let balance: Money
        let isResidual: Bool
        let progress: Double?
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

    struct PendingTransferItem: Sendable, Identifiable {
        let id: UUID
        let amount: Money
    }

    let pool: ReservePoolSummary
    let liveReserveBalance: Money
    let pendingTransferAdjustment: Money
    let reserves: [ReserveItem]
    let pendingTransfers: [PendingTransferItem]
    let activeGoals: [GoalItem]
    let archivedGoals: [GoalItem]

    var unavailableReserves: [ReserveItem] {
        reserves.filter { $0.balance == nil }
    }
}

// MARK: - Build actor

/// Off-main aggregation for the Goals tab.
@ModelActor
actor GoalsBuildActor {
    func build(now: Date) throws -> GoalsModel {
        _ = now
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
        let plaidTreatments = try modelContext.fetch(
            FetchDescriptor<DurablePlaidAccountTreatment>()
        )
        let transferRequests = try modelContext.fetch(
            FetchDescriptor<DurableGoalTransferRequest>()
        ).filter { $0.active && $0.completedAt == nil }
        let allTransactionRows = try modelContext.fetch(
            FetchDescriptor<CachedFinancialTransaction>(
                predicate: #Predicate { !$0.deleted }
            )
        )
        let transactionRows = allTransactionRows.filter {
            !$0.pending && !$0.requiresReview
        }

        let financialById = Dictionary(
            accounts
                .filter(GoalReserveAccountEligibility.canBackGoals)
                .map { ($0.canonicalAccountId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let plaidById = Dictionary(
            GoalReserveAccountEligibility.eligiblePlaidAccounts(
                plaidAccounts,
                treatments: plaidTreatments
            )
                .map { ($0.id, $0) },
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

        let liveReserveBalance = Money(milliunits: poolMilliunits)
        let pendingTransferAdjustment = transferRequests
            .map(\.pendingPoolAdjustment).sum()
        let reserveBalance = max(
            .zero,
            liveReserveBalance + pendingTransferAdjustment
        )
        let balances = GoalBalanceCalculator.effectiveBalances(
            goals: goalRows,
            ledgerEntries: ledgerRows,
            transactions: transactionRows,
            reserveBalance: reserveBalance
        )
        func item(for row: DurableGoal) -> GoalsModel.GoalItem {
            let balance = balances[row.id] ?? .zero
            let goal = row.toCore()
            return GoalsModel.GoalItem(
                goal: goal,
                goalUUID: row.id,
                balance: balance,
                isResidual: row.isResidual && goal.isActive,
                progress: GoalMath.progressFraction(
                    balance: balance, target: goal.target
                )
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
            reserveBalance: reserveBalance,
            activeGoalBalances: active.map(\.balance)
        )
        let pendingTransfers = transferRequests.map { request in
            GoalsModel.PendingTransferItem(
                id: request.id,
                amount: Money(milliunits: request.amountMilliunits)
            )
        }.sorted { $0.amount > $1.amount }

        return GoalsModel(
            pool: pool,
            liveReserveBalance: liveReserveBalance,
            pendingTransferAdjustment: pendingTransferAdjustment,
            reserves: reserveItems,
            pendingTransfers: pendingTransfers,
            activeGoals: active,
            archivedGoals: archived
        )
    }
}

// MARK: - Identifiable helpers

extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}
