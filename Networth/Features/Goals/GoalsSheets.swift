import SwiftUI
import SwiftData
import NetworthCore

// MARK: - Goal card

/// One goal: current allocation and optional target progress.
struct GoalCard: View {
    let item: GoalsModel.GoalItem
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            NwCard(style: .primary) {
                VStack(alignment: .leading, spacing: NwSpacing.sm) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.goal.name)
                            .font(NwTypography.headline)
                            .foregroundStyle(NwAppColors.textPrimary)
                        if item.goal.completedAt != nil {
                            NwStatusBadge("Completed", style: .positive)
                        } else if item.goal.archived {
                            NwStatusBadge("Archived", style: .neutral)
                        }
                        Spacer()
                        NwAmountText(
                            item.balance, variant: .compact, showCents: false
                        )
                    }
                    if let progress = item.progress {
                        ProgressView(value: progress)
                            .tint(progress >= 1
                                ? NwAppColors.positive
                                : NwAppColors.accent)
                        HStack {
                            HStack(spacing: 2) {
                                Text("of")
                                    .font(NwTypography.caption)
                                    .foregroundStyle(.secondary)
                                NwAmountText(
                                    item.goal.target,
                                    variant: .body, showCents: false,
                                    color: NwAppColors.textSecondary
                                )
                            }
                            Spacer()
                            if progress >= 1 {
                                Text("Funded")
                                    .font(NwTypography.caption)
                                    .foregroundStyle(NwAppColors.positive)
                            }
                        }
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

}

// MARK: - Sheet shell

struct GoalSheetShell<Content: View>: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        NavigationStack {
            List { content }
                .nwScreenBackground()
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

private struct GoalAmountRow: View {
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

// MARK: - Goal detail

struct GoalDetailSheet: View {
    @SwiftUI.Environment(AppContainerController.self) private var container
    @Query private var goalRows: [DurableGoal]
    let goalId: UUID
    let model: GoalsModel?

    @State private var editing = false

    private var goalRow: DurableGoal? {
        goalRows.first { $0.id == goalId }
    }
    private var item: GoalsModel.GoalItem? {
        (model?.activeGoals ?? []).first { $0.goalUUID == goalId }
            ?? (model?.archivedGoals ?? []).first { $0.goalUUID == goalId }
    }
    var body: some View {
        GoalSheetShell(title: goalRow?.name ?? "Goal") {
            if let item {
                Section {
                    GoalAmountRow(
                        title: "Set aside", amount: item.balance,
                        color: NwAppColors.accent
                    )
                    if item.goal.target.milliunits > 0 {
                        GoalAmountRow(
                            title: "Target", amount: item.goal.target
                        )
                    }
                    if let targetDate = item.goal.targetDate {
                        LabeledContent("Target date") {
                            Text(DateDisplay.shortDate(targetDate))
                        }
                    }
                    if item.isResidual {
                        NwInlineNotice(
                            "Gets all unallocated money",
                            message: "Its amount follows the live balance of your selected goal accounts after every other goal.",
                            tone: .info
                        )
                    }
                }
            }
            if goalRow?.archived == false
                && goalRow?.completedAt == nil {
                Section {
                    Button {
                        editing = true
                    } label: {
                        Label("Edit Goal", systemImage: NwIcon.edit.rawValue)
                    }
                }
            }
        }
        .sheet(isPresented: $editing) {
            GoalEditorSheet(target: .edit(goalId), model: model)
                .environment(container)
        }
    }
}

// MARK: - Editor

enum GoalEditorTarget: Identifiable {
    case create
    case edit(UUID)

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let id): id.uuidString
        }
    }
}

/// Create/edit the goal's name and optional target. Allocation is edited in
/// one staged sheet from the Goals screen, never as a stream of events here.
struct GoalEditorSheet: View {
    @SwiftUI.Environment(\.modelContext) private var context
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @Query private var goalRows: [DurableGoal]
    let target: GoalEditorTarget
    let model: GoalsModel?

    @State private var name = ""
    @State private var hasTargetAmount = false
    @State private var targetText = ""
    @State private var hasTargetDate = false
    @State private var targetDate = Date.now
    @State private var seeded = false
    @State private var showingArchiveConfirmation = false
    @State private var failure: String?

    private var editedRow: DurableGoal? {
        guard case .edit(let id) = target else { return nil }
        return goalRows.first { $0.id == id }
    }

    private var editedItem: GoalsModel.GoalItem? {
        guard case .edit(let id) = target else { return nil }
        return (model?.activeGoals ?? []).first { $0.goalUUID == id }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                }
                targetSection
                if editedRow != nil {
                    closeSection
                }
                if let failure {
                    Section {
                        NwInlineNotice(
                            "Can't save", message: failure,
                            tone: .caution
                        )
                    }
                }
            }
            .nwScreenBackground()
            .navigationTitle(editedRow == nil ? "New Goal" : "Edit Goal")
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
                        name.trimmingCharacters(in: .whitespaces).isEmpty
                    )
                    .accessibilityLabel("Save")
                }
            }
            .onAppear(perform: seedFromEditedRow)
            .confirmationDialog(
                closingTitle,
                isPresented: $showingArchiveConfirmation,
                titleVisibility: .visible
            ) {
                closingButtons
            }
        }
    }

    @ViewBuilder
    private var targetSection: some View {
        Section {
            Toggle("Target amount", isOn: $hasTargetAmount)
            if hasTargetAmount {
                TextField("Target amount", text: $targetText)
                    .nwCurrencyInput(text: $targetText)
            }
            Toggle("Target date", isOn: $hasTargetDate)
                .disabled(!hasTargetAmount)
            if hasTargetAmount && hasTargetDate {
                DatePicker(
                    "By", selection: $targetDate,
                    displayedComponents: .date
                )
            }
        }
    }

    private var closeSection: some View {
        Section {
            Button("Archive Goal", role: .destructive) {
                showingArchiveConfirmation = true
            }
        }
    }

    private var closingTitle: String {
        guard let item = editedItem, item.balance.milliunits > 0 else {
            return "Close this goal?"
        }
        return "This goal still holds "
            + CurrencyFormatter.currency(item.balance, showCents: false)
            + ". Where should it go?"
    }

    @ViewBuilder
    private var closingButtons: some View {
        let hasBalance = (editedItem?.balance.milliunits ?? 0) > 0
        if hasBalance {
            Button("Release to Unallocated") {
                performClose(remainder: .release)
            }
            ForEach(transferTargets) { candidate in
                Button("Move to \(candidate.goal.name)") {
                    if let row = goalRows.first(
                        where: { $0.id == candidate.goalUUID }
                    ) {
                        performClose(remainder: .transfer(to: row))
                    }
                }
            }
        } else {
            Button("Archive", role: .destructive) {
                performClose(remainder: nil)
            }
        }
        Button("Cancel", role: .cancel) {}
    }

    private var transferTargets: [GoalsModel.GoalItem] {
        guard case .edit(let id) = target else { return [] }
        return (model?.activeGoals ?? []).filter { $0.goalUUID != id }
    }

    private func performClose(
        remainder: GoalLedgerService.RemainderDisposition?
    ) {
        guard let row = editedRow else { return }
        do {
            let service = GoalLedgerService(context: context)
            try service.archiveGoal(row, remainder: remainder)
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
        showingArchiveConfirmation = false
    }

    private func seedFromEditedRow() {
        guard !seeded, let row = editedRow else { return }
        seeded = true
        name = row.name
        hasTargetAmount = row.targetMilliunits > 0
        targetText = row.targetMilliunits > 0
            ? CurrencyInputFormatter.text(
                for: Money(milliunits: row.targetMilliunits)
            ) : ""
        hasTargetDate = row.targetDate != nil
        targetDate = row.targetDate ?? .now
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }
        let fixedTarget = hasTargetAmount
            ? CurrencyInputFormatter.money(from: targetText) ?? .zero
            : .zero
        do {
            let service = GoalLedgerService(context: context)
            if let row = editedRow {
                try service.updateGoal(
                    row,
                    name: trimmedName,
                    kind: .refillable,
                    targetMode: .fixed,
                    target: fixedTarget,
                    targetDate: hasTargetAmount && hasTargetDate
                        ? targetDate : nil,
                    plannedMonthly: .zero,
                    emergencyMonths: 0,
                    emergencyReductionPercent: 100
                )
            } else {
                try service.createGoal(
                    name: trimmedName,
                    kind: .refillable,
                    targetMode: .fixed,
                    target: fixedTarget,
                    targetDate: hasTargetAmount && hasTargetDate
                        ? targetDate : nil,
                    plannedMonthly: .zero,
                    emergencyMonths: 0,
                    emergencyReductionPercent: 100
                )
            }
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}

// MARK: - Reserve picker

/// Choose which accounts back goals. Selection is explicit and independent
/// of provider account type. It is derived state for
/// Projections: while an account actively backs goals it leaves the
/// safe-to-spend cash pool automatically, and returns when deselected.
struct GoalReservePickerSheet: View {
    @SwiftUI.Environment(\.modelContext) private var context
    @Query private var accounts: [CachedFinancialAccount]
    @Query private var plaidAccounts: [CachedPlaidAccount]
    @Query private var plaidTreatments: [DurablePlaidAccountTreatment]
    @Query private var accountNicknames: [DurableAccountNickname]
    @Query(sort: \DurableManualAsset.name)
    private var manualAssets: [DurableManualAsset]
    @Query private var reserveRows: [DurableGoalReserveAccount]
    @State private var failure: String?

    /// Investment accounts use the dedicated Plaid investments cache.
    private var eligibleInvestmentAccounts: [CachedPlaidAccount] {
        GoalReserveAccountEligibility.eligiblePlaidAccounts(
            plaidAccounts,
            treatments: plaidTreatments
        )
            .filter {
                if activeReserveIds.contains($0.id) { return true }
                guard let balance = $0.currentBalanceMilliunits,
                      balance != 0 else { return false }
                return ($0.isoCurrencyCode ?? "USD") == "USD"
            }
            .sorted {
                ($0.currentBalanceMilliunits ?? 0)
                    > ($1.currentBalanceMilliunits ?? 0)
            }
    }

    /// Any connected asset account can back goals; debts never can.
    private var eligibleAccounts: [CachedFinancialAccount] {
        accounts
            .filter {
                GoalReserveAccountEligibility.canBackGoals($0)
                    && !$0.deleted && $0.currentBalanceMilliunits != nil
                    && ($0.isoCurrencyCode ?? "USD") == "USD"
            }
            .sorted {
                return accountNameResolver.name(for: $0)
                    .localizedCaseInsensitiveCompare(
                        accountNameResolver.name(for: $1)
                    ) == .orderedAscending
            }
    }

    private var activeReserveIds: Set<String> {
        Set(reserveRows.filter(\.active).map(\.canonicalAccountId))
    }

    private var accountNameResolver: AccountDisplayNameResolver {
        AccountDisplayNameResolver(nicknames: accountNicknames)
    }

    private var manualResolver: PlaidContributionResolver {
        PlaidContributionResolver(
            plaidAccounts: plaidAccounts,
            treatments: plaidTreatments,
            manualAssets: manualAssets
        )
    }

    private var eligibleManualAccounts: [DurableManualAsset] {
        manualAssets.filter {
            GoalReserveAccountEligibility.canBackGoals($0)
                && (activeReserveIds.contains(
                    GoalReserveAccountEligibility.reserveID(for: $0)
                ) || manualResolver.effectiveValue(for: $0).milliunits > 0)
        }
    }

    var body: some View {
        GoalSheetShell(title: "Goal Accounts") {
            Section {
                Text("Choose the accounts whose balances back goals. "
                     + "While an account backs goals it won't count toward "
                     + "safe-to-spend in Projections.")
                    .font(NwTypography.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Accounts") {
                if eligibleAccounts.isEmpty {
                    Text("No USD accounts with balances are connected.")
                        .font(NwTypography.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(eligibleAccounts, id: \.canonicalAccountId) {
                    account in
                    accountRow(account)
                }
            }
            if !eligibleInvestmentAccounts.isEmpty {
                Section {
                    ForEach(eligibleInvestmentAccounts, id: \.id) { account in
                        investmentRow(account)
                    }
                } header: {
                    Text("Investments")
                } footer: {
                    Text("Changing balances automatically update the amount "
                         + "available to goals.")
                }
            }
            if !eligibleManualAccounts.isEmpty {
                Section("Manual Accounts") {
                    ForEach(eligibleManualAccounts) { asset in
                        manualAccountRow(asset)
                    }
                }
            }
            unavailableSection
            if let failure {
                Section {
                    NwInlineNotice(
                        "Can't save", message: failure,
                        tone: .caution
                    )
                }
            }
        }
    }

    private func accountRow(
        _ account: CachedFinancialAccount
    ) -> some View {
        let isReserve = activeReserveIds.contains(account.canonicalAccountId)
        return Button {
            toggle(account, isReserve: isReserve)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(accountNameResolver.name(for: account))
                        .font(NwTypography.body)
                        .foregroundStyle(NwAppColors.textPrimary)
                    HStack(spacing: NwSpacing.xs) {
                        if let institution = account.institutionName {
                            Text(institution)
                                .font(NwTypography.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let mask = account.mask {
                            Text("···\(mask)")
                                .font(NwTypography.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(typeLabel(account))
                            .font(NwTypography.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                NwAmountText(
                    account.balance, variant: .body, showCents: false,
                    color: NwAppColors.textSecondary
                )
                Image(systemName: isReserve
                    ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isReserve
                        ? NwAppColors.positive : NwAppColors.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func investmentRow(
        _ account: CachedPlaidAccount
    ) -> some View {
        let isReserve = activeReserveIds.contains(account.id)
        return Button {
            toggleInvestment(account, isReserve: isReserve)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(accountNameResolver.name(for: account))
                        .font(NwTypography.body)
                        .foregroundStyle(NwAppColors.textPrimary)
                    HStack(spacing: NwSpacing.xs) {
                        Text(account.institutionName)
                            .font(NwTypography.caption)
                            .foregroundStyle(.secondary)
                        if let mask = account.mask {
                            Text("···\(mask)")
                                .font(NwTypography.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text((account.subtype ?? "Brokerage").capitalized)
                            .font(NwTypography.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                NwAmountText(
                    account.currentBalance ?? .zero, variant: .body,
                    showCents: false, color: NwAppColors.textSecondary
                )
                Image(systemName: isReserve
                    ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isReserve
                        ? NwAppColors.positive : NwAppColors.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func manualAccountRow(
        _ asset: DurableManualAsset
    ) -> some View {
        let reserveID = GoalReserveAccountEligibility.reserveID(for: asset)
        let isReserve = activeReserveIds.contains(reserveID)
        return Button {
            toggleManualAccount(asset, isReserve: isReserve)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(asset.name.isEmpty ? "Untitled" : asset.name)
                        .font(NwTypography.body)
                        .foregroundStyle(NwAppColors.textPrimary)
                    Text("Manual · Other")
                        .font(NwTypography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                NwAmountText(
                    manualResolver.effectiveValue(for: asset),
                    variant: .body,
                    showCents: false,
                    color: NwAppColors.textSecondary
                )
                Image(systemName: isReserve
                    ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isReserve
                        ? NwAppColors.positive : NwAppColors.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var unavailableSection: some View {
        let availableIDs = Set(eligibleAccounts.map(\.canonicalAccountId))
            .union(eligibleInvestmentAccounts.map(\.id))
            .union(eligibleManualAccounts.map {
                GoalReserveAccountEligibility.reserveID(for: $0)
            })
        let unavailable = reserveRows.filter {
            $0.active && !availableIDs.contains($0.canonicalAccountId)
        }
        if !unavailable.isEmpty {
            Section("Unavailable") {
                ForEach(unavailable) { reserve in
                    unavailableRow(reserve)
                }
            }
        }
    }

    private func unavailableRow(
        _ reserve: DurableGoalReserveAccount
    ) -> some View {
        // Re-attach suggestions: same institution+mask among connected
        // accounts not already backing goals. User-confirmed, never
        // automatic — these fields aren't guaranteed unique.
        let candidates = eligibleAccounts.filter {
            !activeReserveIds.contains($0.canonicalAccountId)
                && ($0.institutionName ?? "") == reserve.institutionName
                && ($0.mask ?? "") == reserve.mask
        }
        return VStack(alignment: .leading, spacing: NwSpacing.xs) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        reserve.accountName.isEmpty
                            ? "Account" : reserve.accountName
                    )
                        .font(NwTypography.body)
                    Text("Unavailable · counted as $0")
                        .font(NwTypography.caption)
                        .foregroundStyle(NwAppColors.caution)
                }
                Spacer()
                Button("Remove") { remove(reserve) }
                    .font(NwTypography.footnote)
                    .foregroundStyle(NwAppColors.liability)
            }
            ForEach(candidates, id: \.canonicalAccountId) { candidate in
                Button {
                    reattach(reserve, to: candidate)
                } label: {
                    Label(
                        "Re-attach to \(accountNameResolver.name(for: candidate))",
                        systemImage: "link"
                    )
                    .font(NwTypography.footnote)
                }
            }
        }
    }

    private func typeLabel(_ account: CachedFinancialAccount) -> String {
        // Plaid's subtype (money market, CD, …) is more recognizable than
        // the app's broad `.cash` bucket when it's present.
        if let subtype = account.subtype?.capitalized, !subtype.isEmpty {
            return subtype
        }
        switch account.type {
        case .checking: return "Checking"
        case .savings: return "Savings"
        case .cash: return "Cash"
        default: return account.type.rawValue.capitalized
        }
    }

    private func toggle(
        _ account: CachedFinancialAccount,
        isReserve: Bool
    ) {
        failure = nil
        do {
            let service = GoalLedgerService(context: context)
            if isReserve {
                if let row = reserveRows.first(where: {
                    $0.active && $0.canonicalAccountId
                        == account.canonicalAccountId
                }) {
                    try service.removeReserveAccount(row)
                }
            } else if account.currentBalanceMilliunits == nil {
                failure = "\(accountNameResolver.name(for: account)) has no reported balance yet."
            } else {
                try service.addReserveAccount(
                    canonicalAccountId: account.canonicalAccountId,
                    accountName: accountNameResolver.name(for: account),
                    institutionName: account.institutionName ?? "",
                    mask: account.mask ?? ""
                )
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    private func toggleInvestment(
        _ account: CachedPlaidAccount,
        isReserve: Bool
    ) {
        failure = nil
        do {
            let service = GoalLedgerService(context: context)
            if isReserve {
                if let row = reserveRows.first(where: {
                    $0.active && $0.canonicalAccountId == account.id
                }) {
                    try service.removeReserveAccount(row)
                }
            } else {
                // The Plaid account id is the reserve key for investments.
                try service.addReserveAccount(
                    canonicalAccountId: account.id,
                    accountName: accountNameResolver.name(for: account),
                    institutionName: account.institutionName,
                    mask: account.mask ?? ""
                )
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    private func toggleManualAccount(
        _ asset: DurableManualAsset,
        isReserve: Bool
    ) {
        failure = nil
        do {
            let service = GoalLedgerService(context: context)
            let reserveID = GoalReserveAccountEligibility.reserveID(for: asset)
            if isReserve {
                if let row = reserveRows.first(where: {
                    $0.active && $0.canonicalAccountId == reserveID
                }) {
                    try service.removeReserveAccount(row)
                }
            } else {
                try service.addReserveAccount(asset)
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    private func remove(_ reserve: DurableGoalReserveAccount) {
        do {
            try GoalLedgerService(context: context)
                .removeReserveAccount(reserve)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func reattach(
        _ reserve: DurableGoalReserveAccount,
        to account: CachedFinancialAccount
    ) {
        do {
            try GoalLedgerService(context: context)
                .reattachReserveAccount(reserve, to: account)
        } catch {
            failure = error.localizedDescription
        }
    }
}

// MARK: - Allocate

private struct GoalAllocationAmountTarget: Identifiable {
    let id: UUID
    let name: String
    let amount: Money
}

/// Compact allocation editor. Every change remains staged until Apply; one
/// optional goal can receive the live remainder automatically.
struct GoalAllocateSheet: View {
    @SwiftUI.Environment(\.modelContext) private var context
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let pool: Money
    let goals: [GoalsModel.GoalItem]

    @State private var allocationText: [UUID: String] = [:]
    @State private var residualGoalId: UUID?
    @State private var seeded = false
    @State private var failure: String?
    @State private var amountTarget: GoalAllocationAmountTarget?

    var body: some View {
        NavigationStack {
            Form {
                Section("Summary") {
                    LabeledContent("Available") {
                        NwAmountText(
                            pool, variant: .body, showCents: false
                        )
                    }
                    LabeledContent("Allocated") {
                        NwAmountText(
                            stagedAllocated,
                            variant: .body,
                            showCents: false,
                            color: overage.isZero
                                ? NwAppColors.textPrimary
                                : NwAppColors.liability
                        )
                    }
                    LabeledContent("Remaining") {
                        NwAmountText(
                            unallocated,
                            variant: .body,
                            showCents: false,
                            color: overage.isZero
                                ? NwAppColors.textPrimary
                                : NwAppColors.liability
                        )
                    }
                }
                Section("Allocations") {
                    ForEach(goals) { item in
                        if residualGoalId == item.goalUUID {
                            HStack(spacing: NwSpacing.md) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.goal.name)
                                        .foregroundStyle(
                                            NwAppColors.textPrimary
                                        )
                                    Label(
                                        "Automatic",
                                        systemImage: "lock.fill"
                                    )
                                    .font(NwTypography.caption)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                                NwAmountText(
                                    remaining,
                                    variant: .body,
                                    showCents: false,
                                    color: NwAppColors.accent
                                )
                            }
                        } else {
                            Button {
                                amountTarget = GoalAllocationAmountTarget(
                                    id: item.goalUUID,
                                    name: item.goal.name,
                                    amount: allocation(for: item.goalUUID)
                                )
                            } label: {
                                HStack(spacing: NwSpacing.md) {
                                    Text(item.goal.name)
                                        .foregroundStyle(
                                            NwAppColors.textPrimary
                                        )
                                    Spacer()
                                    NwAmountText(
                                        allocation(for: item.goalUUID),
                                        variant: .body,
                                        showCents: false,
                                        color: NwAppColors.textSecondary
                                    )
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                "Edit \(item.goal.name) allocation"
                            )
                        }
                    }
                }

                Section {
                    Picker(
                        "Automatic remainder",
                        selection: $residualGoalId
                    ) {
                        Text("None").tag(UUID?.none)
                        ForEach(goals) { item in
                            Text(item.goal.name)
                                .tag(Optional(item.goalUUID))
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(NwAppColors.textSecondary)
                }
                if !overage.isZero {
                    Section {
                        NwInlineNotice(
                            "Allocations exceed the accounts",
                            message: "Reduce allocations by "
                                + CurrencyFormatter.currency(
                                    overage, showCents: false
                                ) + ".",
                            tone: .caution
                        )
                    }
                }
                if let failure {
                    Section {
                        NwInlineNotice(
                            "Can't save", message: failure, tone: .caution
                        )
                    }
                }
            }
            .nwScreenBackground()
            .navigationTitle("Goal Allocations")
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
                    .disabled(!overage.isZero)
                    .accessibilityLabel("Apply")
                }
            }
            .onAppear {
                guard !seeded else { return }
                seeded = true
                residualGoalId = goals.first(where: \.isResidual)?.goalUUID
                for goal in goals {
                    allocationText[goal.goalUUID] =
                        CurrencyInputFormatter.text(
                            for: max(goal.balance, .zero)
                        )
                }
            }
            .sheet(item: $amountTarget) { target in
                GoalAllocationAmountSheet(target: target) { amount in
                    allocationText[target.id] =
                        CurrencyInputFormatter.text(for: amount)
                    failure = nil
                }
                .presentationDetents([.medium])
            }
        }
        .presentationDetents([.large])
    }

    private func allocation(for goalId: UUID) -> Money {
        CurrencyInputFormatter.money(
            from: allocationText[goalId] ?? ""
        ) ?? .zero
    }

    private var allocations: [UUID: Money] {
        Dictionary(uniqueKeysWithValues: goals.map { goal in
            (goal.goalUUID, allocation(for: goal.goalUUID))
        })
    }

    private var explicitTotal: Money {
        allocations.reduce(.zero) { total, pair in
            pair.key == residualGoalId ? total : total + pair.value
        }
    }

    private var remaining: Money {
        max(pool - explicitTotal, .zero)
    }

    private var unallocated: Money {
        residualGoalId == nil ? remaining : .zero
    }

    private var stagedAllocated: Money {
        overage.isZero ? pool - unallocated : explicitTotal
    }

    private var overage: Money {
        max(explicitTotal - pool, .zero)
    }

    private func save() {
        do {
            try GoalLedgerService(context: context).applyAllocations(
                allocations,
                residualGoalId: residualGoalId
            )
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}

private struct GoalAllocationAmountSheet: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let target: GoalAllocationAmountTarget
    let onApply: (Money) -> Void

    @State private var amountText: String

    init(
        target: GoalAllocationAmountTarget,
        onApply: @escaping (Money) -> Void
    ) {
        self.target = target
        self.onApply = onApply
        _amountText = State(
            initialValue: CurrencyInputFormatter.text(for: target.amount)
        )
    }

    var body: some View {
        NwModalLayout(
            title: target.name,
            onClose: { dismiss() },
            onConfirm: apply,
            confirmDisabled: amount == nil
        ) {
            NwCard(style: .primary) {
                HStack(spacing: NwSpacing.md) {
                    Text("Amount allocated")
                    Spacer()
                    TextField("0.00", text: $amountText)
                        .multilineTextAlignment(.trailing)
                        .nwCurrencyInput(text: $amountText)
                    .frame(width: 140, height: 44)
                }
            }
        }
    }

    private var amount: Money? {
        CurrencyInputFormatter.money(from: amountText)
    }

    private func apply() {
        guard let amount else { return }
        onApply(amount)
        dismiss()
    }
}

// MARK: - Pending goal transfers

struct GoalTransferRequestCard: View {
    let transfer: GoalsModel.PendingTransferItem
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            NwCard(style: .secondary) {
                HStack(spacing: NwSpacing.md) {
                    NwIcon.warning.image
                        .foregroundStyle(NwAppColors.caution)
                    Text("Transfer needed")
                        .font(NwTypography.headline)
                        .foregroundStyle(NwAppColors.textPrimary)
                    Spacer()
                    NwAmountText(
                        transfer.amount,
                        variant: .body,
                        showCents: false,
                        color: NwAppColors.caution
                    )
                    NwIcon.chevron.image.foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }
}

struct GoalTransferRequestSheet: View {
    @SwiftUI.Environment(\.modelContext) private var context
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @Query private var requests: [DurableGoalTransferRequest]
    @Query private var reserves: [DurableGoalReserveAccount]
    @Query private var transactions: [CachedFinancialTransaction]
    @Query private var financialAccounts: [CachedFinancialAccount]
    @Query private var accountNicknames: [DurableAccountNickname]
    let requestId: UUID

    @State private var matchCandidateId: String?
    @State private var editingOriginal = false
    @State private var failure: String?

    private var request: DurableGoalTransferRequest? {
        requests.first { $0.id == requestId && $0.active }
    }

    private var activeReserves: [DurableGoalReserveAccount] {
        reserves.filter(\.active).sorted {
            $0.accountName.localizedCaseInsensitiveCompare($1.accountName)
                == .orderedAscending
        }
    }

    private var candidates: [CachedFinancialTransaction] {
        guard let request, !request.cashflowAccountId.isEmpty else {
            return []
        }
        let expected = request.direction == .fundSpend
            ? request.amountMilliunits : -request.amountMilliunits
        return transactions.filter {
            !$0.deleted && !$0.pending
                && $0.id != request.transactionId
                && $0.canonicalAccountId == request.cashflowAccountId
                && $0.amountMilliunits == expected
                && $0.postedDate >= request.transactionDate
        }.sorted { $0.postedDate > $1.postedDate }
    }

    private var cashflowAccounts: [CachedFinancialAccount] {
        financialAccounts.filter {
            !$0.deleted && $0.type.isCashLike
                && $0.currentBalanceMilliunits != nil
                && ($0.isoCurrencyCode ?? "USD") == "USD"
        }.sorted {
            accountNameResolver.name(for: $0)
                .localizedCaseInsensitiveCompare(
                    accountNameResolver.name(for: $1)
                ) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let request {
                    Section("Transfer") {
                        LabeledContent("Amount") {
                            NwAmountText(
                                Money(milliunits: request.amountMilliunits),
                                variant: .body,
                                showCents: true
                            )
                        }
                        LabeledContent(
                            "Purchase account",
                            value: request.transactionAccountName
                        )
                    }
                    Section("Accounts") {
                        Picker(
                            request.direction == .fundSpend
                                ? "Transfer from" : "Transfer into",
                            selection: goalAccountBinding(request)
                        ) {
                            Text("Select Account").tag(String?.none)
                            ForEach(activeReserves) { reserve in
                                Text(reserve.accountName)
                                    .tag(String?.some(
                                        reserve.canonicalAccountId
                                    ))
                            }
                        }
                        Picker(
                            request.direction == .fundSpend
                                ? "Transfer into" : "Transfer from",
                            selection: cashflowAccountBinding(request)
                        ) {
                            Text("Select Account").tag(String?.none)
                            ForEach(cashflowAccounts) { account in
                                Text(accountNameResolver.name(for: account))
                                    .tag(String?.some(
                                    account.canonicalAccountId
                                ))
                            }
                        }
                    }
                    if request.goalAccountId != nil
                        && !request.cashflowAccountId.isEmpty {
                        Section {
                            if candidates.isEmpty {
                                Text("No exact transfer has arrived yet.")
                                    .font(NwTypography.footnote)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(candidates) { candidate in
                                    Button {
                                        matchCandidateId = candidate.id
                                    } label: {
                                        LabeledContent(
                                            candidate.postedDate.formatted(
                                                date: .abbreviated,
                                                time: .omitted
                                            )
                                        ) {
                                            NwAmountText(
                                                Money(milliunits:
                                                    candidate.amountMilliunits
                                                ).absolute,
                                                variant: .body,
                                                showCents: true
                                            )
                                        }
                                    }
                                }
                            }
                        } header: {
                            Text("Plaid matches")
                        } footer: {
                            Text("A match is never accepted automatically.")
                        }
                    }
                    Section {
                        Button("Change Transaction Type") {
                            editingOriginal = true
                        }
                    } footer: {
                        Text("Open the original transaction from its account "
                             + "history to change its type.")
                    }
                }
                if let failure {
                    Section {
                        NwInlineNotice(
                            "Can't save", message: failure, tone: .caution
                        )
                    }
                }
            }
            .nwScreenBackground()
            .navigationTitle("Pending Transfer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        NwIcon.close.image
                            .foregroundStyle(NwAppColors.liability)
                    }
                }
            }
            .alert(
                "Confirm Plaid Match?",
                isPresented: Binding(
                    get: { matchCandidateId != nil },
                    set: { if !$0 { matchCandidateId = nil } }
                )
            ) {
                Button("Cancel", role: .cancel) {
                    matchCandidateId = nil
                }
                Button("Confirm") { confirmMatch() }
            } message: {
                Text("Confirm that this is the internal transfer you made.")
            }
            .sheet(isPresented: $editingOriginal) {
                if let original = transactions.first(where: {
                    $0.id == request?.transactionId
                }) {
                    NavigationStack {
                        PlaidTransactionReviewEditor(
                            transaction: original,
                            dismissAfterSave: true,
                            onSaved: { dismiss() }
                        )
                    }
                }
            }
        }
    }

    private var accountNameResolver: AccountDisplayNameResolver {
        AccountDisplayNameResolver(nicknames: accountNicknames)
    }

    private func goalAccountBinding(
        _ request: DurableGoalTransferRequest
    ) -> Binding<String?> {
        Binding(
            get: { request.goalAccountId },
            set: { accountId in
                request.goalAccountId = accountId
                request.goalAccountName = activeReserves.first {
                    $0.canonicalAccountId == accountId
                }?.accountName
                request.updatedAt = .now
                save(source: "goals.transferSource")
            }
        )
    }

    private func cashflowAccountBinding(
        _ request: DurableGoalTransferRequest
    ) -> Binding<String?> {
        Binding(
            get: {
                request.cashflowAccountId.isEmpty
                    ? nil : request.cashflowAccountId
            },
            set: { accountId in
                request.cashflowAccountId = accountId ?? ""
                request.cashflowAccountName = cashflowAccounts.first {
                    $0.canonicalAccountId == accountId
                }?.name ?? ""
                request.updatedAt = .now
                save(source: "goals.transferCashflowAccount")
            }
        )
    }

    private func confirmMatch() {
        guard let request, let matchCandidateId else { return }
        request.matchedTransactionId = matchCandidateId
        request.completedAt = .now
        request.updatedAt = .now
        if save(source: "goals.transferMatch") { dismiss() }
    }

    @discardableResult
    private func save(source: String) -> Bool {
        if context.safeSave(source: source) {
            failure = nil
            return true
        }
        context.rollback()
        failure = "The transfer could not be saved."
        return false
    }
}
