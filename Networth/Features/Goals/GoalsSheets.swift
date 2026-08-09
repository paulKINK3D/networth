import SwiftUI
import SwiftData
import NetworthCore

// MARK: - Goal card

/// One goal: balance, progress toward target, plan-sufficiency status, and
/// this month's confirmed contributions vs plan. Revived from the retired
/// FundCard with the same status copy.
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
                            .tint(
                                item.status == .funded
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
                                    item.goal.target,
                                    variant: .body, showCents: false,
                                    color: NwAppColors.textSecondary
                                )
                            }
                        }
                    }
                    if item.goal.isActive,
                       item.goal.plannedMonthly.milliunits > 0
                        || item.mtdContributions.milliunits > 0 {
                        Text(monthLine)
                            .font(NwTypography.caption)
                            .foregroundStyle(.secondary)
                    }
                    if item.orphanedEntryCount > 0 {
                        Text("\(item.orphanedEntryCount) linked "
                             + "transaction(s) no longer exist — review "
                             + "the ledger.")
                            .font(NwTypography.caption)
                            .foregroundStyle(NwAppColors.caution)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Plan sufficiency, not measured pace: compares the configured monthly
    /// plan against the math needed to hit a dated target.
    private var statusLine: String {
        switch item.status {
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

    private var monthLine: String {
        let added = CurrencyFormatter.compact(item.mtdContributions)
        guard item.goal.plannedMonthly.milliunits > 0 else {
            return "\(added) added this month"
        }
        return "\(added) of "
            + CurrencyFormatter.compact(item.goal.plannedMonthly)
            + " planned this month"
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
    @SwiftUI.Environment(\.modelContext) private var context
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @Query private var goalRows: [DurableGoal]
    @Query(sort: \DurableGoalLedgerEntry.date, order: .reverse)
    private var ledgerRows: [DurableGoalLedgerEntry]
    let goalId: UUID
    let model: GoalsModel?

    @State private var entrySign: GoalEntrySign?
    @State private var showingPurchasePicker = false
    @State private var editing = false
    @State private var serviceError: String?

    private var goalRow: DurableGoal? {
        goalRows.first { $0.id == goalId }
    }
    private var item: GoalsModel.GoalItem? {
        (model?.activeGoals ?? []).first { $0.goalUUID == goalId }
            ?? (model?.archivedGoals ?? []).first { $0.goalUUID == goalId }
    }
    private var entries: [DurableGoalLedgerEntry] {
        ledgerRows.filter { $0.goalId == goalId }
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
                    if case .onTrack(let required) = item.status {
                        GoalAmountRow(
                            title: "Needed monthly", amount: required,
                            color: NwAppColors.positive
                        )
                    }
                    if case .behind(let required) = item.status {
                        GoalAmountRow(
                            title: "Needed monthly", amount: required,
                            color: NwAppColors.caution
                        )
                    }
                    if item.goal.targetMode == .emergencyMonths {
                        emergencyFooter(item)
                    }
                }
            }
            if goalRow?.archived == false
                && goalRow?.completedAt == nil {
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
                        showingPurchasePicker = true
                    } label: {
                        Label("Record Purchase",
                              systemImage: "cart")
                    }
                    Button {
                        editing = true
                    } label: {
                        Label("Edit Goal", systemImage: NwIcon.edit.rawValue)
                    }
                }
            }
            ledgerSection
        }
        .sheet(item: $entrySign) { sign in
            GoalEntrySheet(goalId: goalId, sign: sign)
                .environment(container)
        }
        .sheet(isPresented: $showingPurchasePicker) {
            GoalPurchasePickerSheet(goalId: goalId)
                .environment(container)
        }
        .sheet(isPresented: $editing) {
            GoalEditorSheet(target: .edit(goalId), model: model)
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

    @ViewBuilder
    private func emergencyFooter(_ item: GoalsModel.GoalItem) -> some View {
        let months = item.goal.emergencyMonths
        let percent = item.goal.emergencyReductionPercent
        VStack(alignment: .leading, spacing: 2) {
            Text("Target = \(months) months × median monthly spending"
                 + (percent < 100 ? " × \(percent)%" : ""))
                .font(NwTypography.caption)
                .foregroundStyle(.secondary)
            if let adoptedAt = goalRow?.adoptedAt {
                Text("Last updated "
                     + DateDisplay.shortDate(adoptedAt))
                    .font(NwTypography.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var ledgerSection: some View {
        Section("Ledger") {
            if entries.isEmpty {
                Text("No entries yet")
                    .font(NwTypography.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                ledgerRow(entry)
                    .swipeActions(edge: .trailing) {
                        Button("Delete", role: .destructive) {
                            delete(entry)
                        }
                    }
            }
        }
    }

    private func ledgerRow(_ entry: DurableGoalLedgerEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: NwSpacing.xs) {
                    Text(entry.note ?? kindLabel(entry.kind))
                        .font(NwTypography.body)
                    if let externalId = entry.linkedTransactionExternalId,
                       isOrphaned(externalId) {
                        NwStatusBadge("Missing", style: .caution)
                    }
                }
                Text(entry.date.formatted(
                    .dateTime.month(.abbreviated).day().year()
                ))
                .font(NwTypography.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            NwAmountText(
                Money(milliunits: entry.amountMilliunits),
                variant: .compact, showCents: false
            )
        }
    }

    private func kindLabel(_ kind: GoalLedgerKind) -> String {
        switch kind {
        case .manual:
            "Adjustment"
        case .contribution:
            "Contribution"
        case .purchase:
            "Purchase"
        case .purchaseRefund:
            "Refund"
        case .withdrawal:
            "Withdrawal"
        case .reallocationOut:
            "Moved to another goal"
        case .reallocationIn:
            "Moved from another goal"
        }
    }

    private func isOrphaned(_ externalId: String) -> Bool {
        guard let model else { return false }
        _ = model
        // The build actor computes the count; per-row lookup here would need
        // a cached-row fetch. Cheap approach: only flag when the goal item
        // reports orphans and this entry's row can't be fetched.
        let descriptor = FetchDescriptor<CachedFinancialTransaction>(
            predicate: #Predicate {
                $0.externalId == externalId && !$0.deleted
            }
        )
        return ((try? context.fetchCount(descriptor)) ?? 0) == 0
    }

    private func delete(_ entry: DurableGoalLedgerEntry) {
        do {
            try GoalLedgerService(context: context).deleteEntry(entry)
        } catch {
            serviceError = error.localizedDescription
        }
    }
}

private enum GoalEntrySign: String, Identifiable {
    case contribution
    case withdrawal
    var id: String { rawValue }
}

// MARK: - Manual entry

/// Manual contribution or withdrawal, validated by the service (pool
/// capacity for contributions, nonnegative balance for withdrawals). The
/// sheet stays open on failure so the entry isn't lost.
private struct GoalEntrySheet: View {
    @SwiftUI.Environment(\.modelContext) private var context
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @Query private var goalRows: [DurableGoal]
    let goalId: UUID
    let sign: GoalEntrySign

    @State private var amountText = ""
    @State private var note = ""
    @State private var date = Date.now
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Amount", text: $amountText)
                        .keyboardType(.decimalPad)
                        .onChange(of: amountText) { _, newValue in
                            amountText = CurrencyInputFormatter.formatted(
                                newValue
                            )
                        }
                    TextField("Note (optional)", text: $note)
                    DatePicker(
                        "Date", selection: $date, displayedComponents: .date
                    )
                }
                if let failure {
                    Section {
                        NwInlineNotice(
                            "Can't save",
                            message: failure,
                            tone: .caution
                        )
                    }
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
                    .disabled(parsedAmount == nil)
                    .accessibilityLabel("Save")
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var parsedAmount: Money? {
        guard let amount = CurrencyInputFormatter.money(from: amountText),
              amount.milliunits > 0 else { return nil }
        return amount
    }

    private func save() {
        guard let amount = parsedAmount,
              let goal = goalRows.first(where: { $0.id == goalId }) else {
            return
        }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try GoalLedgerService(context: context).addManualEntry(
                goal: goal,
                amount: sign == .contribution ? amount : -amount,
                date: date,
                note: trimmedNote.isEmpty ? nil : trimmedNote
            )
            dismiss()
        } catch {
            failure = error.localizedDescription
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

/// Create/edit a goal: kind, fixed target or emergency months × reduction,
/// optional target date, planned monthly. Archive/complete live here, with
/// the explicit remainder disposition the invariants require.
struct GoalEditorSheet: View {
    @SwiftUI.Environment(\.modelContext) private var context
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @Query private var goalRows: [DurableGoal]
    let target: GoalEditorTarget
    let model: GoalsModel?

    @State private var name = ""
    @State private var kind: GoalKind = .refillable
    @State private var targetMode: GoalTargetMode = .fixed
    @State private var targetText = ""
    @State private var hasTargetDate = false
    @State private var targetDate = Date.now
    @State private var plannedText = ""
    @State private var emergencyMonths = 6
    @State private var reductionPercent = 100
    @State private var seeded = false
    @State private var closing: CloseAction?
    @State private var failure: String?

    private enum CloseAction: String, Identifiable {
        case archive
        case complete
        var id: String { rawValue }
    }

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
                    Picker("Kind", selection: $kind) {
                        Text("One-time").tag(GoalKind.oneTime)
                        Text("Refillable").tag(GoalKind.refillable)
                        Text("Floor").tag(GoalKind.floor)
                    }
                } footer: {
                    Text(kindFooter)
                }
                targetSection
                Section {
                    TextField(
                        "Planned monthly (optional)", text: $plannedText
                    )
                    .keyboardType(.decimalPad)
                    .onChange(of: plannedText) { _, newValue in
                        plannedText = CurrencyInputFormatter.formatted(
                            newValue
                        )
                    }
                } footer: {
                    Text("Used only to judge whether your plan keeps "
                         + "pace. Money never moves automatically.")
                }
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
                isPresented: .init(
                    get: { closing != nil },
                    set: { if !$0 { closing = nil } }
                ),
                titleVisibility: .visible
            ) {
                closingButtons
            }
        }
    }

    private var kindFooter: String {
        switch kind {
        case .oneTime:
            "Completes explicitly when the purpose is fulfilled."
        case .refillable:
            "Stays active after spending — travel, replacements."
        case .floor:
            "A level to maintain, like an emergency fund."
        }
    }

    @ViewBuilder
    private var targetSection: some View {
        Section {
            Picker("Target", selection: $targetMode) {
                Text("Fixed amount").tag(GoalTargetMode.fixed)
                Text("Months of spending")
                    .tag(GoalTargetMode.emergencyMonths)
            }
            .pickerStyle(.segmented)
            if targetMode == .fixed {
                TextField("Target amount", text: $targetText)
                    .keyboardType(.decimalPad)
                    .onChange(of: targetText) { _, newValue in
                        targetText = CurrencyInputFormatter.formatted(
                            newValue
                        )
                    }
                Toggle("Target date", isOn: $hasTargetDate)
                if hasTargetDate {
                    DatePicker(
                        "By", selection: $targetDate,
                        displayedComponents: .date
                    )
                }
            } else {
                Stepper(
                    "\(emergencyMonths) months",
                    value: $emergencyMonths, in: 1...24
                )
                Stepper(
                    "Spending reduction: \(reductionPercent)%",
                    value: $reductionPercent, in: 10...100, step: 5
                )
            }
        } footer: {
            if targetMode == .emergencyMonths {
                Text(emergencyFooter)
            }
        }
    }

    private var emergencyFooter: String {
        guard let model else { return "" }
        if let median = model.emergencyMedian {
            let target = EmergencyFundMath.target(
                medianMonthly: median,
                months: emergencyMonths,
                reductionPercent: reductionPercent
            )
            return "Median monthly spending over "
                + "\(model.sampleMonthCount) complete months is "
                + CurrencyFormatter.currency(median, showCents: false)
                + " → target "
                + CurrencyFormatter.currency(target, showCents: false)
                + ". It self-adjusts as your spending changes."
        }
        return "Not enough spending history yet (needs 2 complete months)."
            + " Use a fixed amount for now."
    }

    private var closeSection: some View {
        Section {
            if kind == .oneTime {
                Button("Mark Completed") { closing = .complete }
            }
            Button("Archive Goal", role: .destructive) {
                closing = .archive
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
            Button(
                closing == .complete ? "Mark Completed" : "Archive",
                role: closing == .archive ? .destructive : nil
            ) {
                performClose(remainder: nil)
            }
        }
        Button("Cancel", role: .cancel) { closing = nil }
    }

    private var transferTargets: [GoalsModel.GoalItem] {
        guard case .edit(let id) = target else { return [] }
        return (model?.activeGoals ?? []).filter { $0.goalUUID != id }
    }

    private func performClose(
        remainder: GoalLedgerService.RemainderDisposition?
    ) {
        guard let row = editedRow, let closing else { return }
        do {
            let service = GoalLedgerService(context: context)
            switch closing {
            case .archive:
                try service.archiveGoal(row, remainder: remainder)
            case .complete:
                try service.completeGoal(row, remainder: remainder)
            }
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
        self.closing = nil
    }

    private func seedFromEditedRow() {
        guard !seeded, let row = editedRow else { return }
        seeded = true
        name = row.name
        kind = row.kind
        targetMode = row.targetMode
        targetText = row.targetMilliunits > 0
            ? CurrencyInputFormatter.text(
                for: Money(milliunits: row.targetMilliunits)
            ) : ""
        hasTargetDate = row.targetDate != nil
        targetDate = row.targetDate ?? .now
        plannedText = row.plannedMonthlyMilliunits > 0
            ? CurrencyInputFormatter.text(
                for: Money(milliunits: row.plannedMonthlyMilliunits)
            ) : ""
        emergencyMonths = max(1, row.emergencyMonths == 0
            ? 6 : row.emergencyMonths)
        reductionPercent = row.emergencyReductionPercent
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }
        let fixedTarget = CurrencyInputFormatter.money(from: targetText)
            ?? .zero
        let planned = CurrencyInputFormatter.money(from: plannedText)
            ?? .zero
        do {
            let service = GoalLedgerService(context: context)
            if let row = editedRow {
                try service.updateGoal(
                    row,
                    name: trimmedName,
                    kind: kind,
                    targetMode: targetMode,
                    target: targetMode == .fixed
                        ? fixedTarget
                        : Money(milliunits: row.targetMilliunits),
                    targetDate: targetMode == .fixed && hasTargetDate
                        ? targetDate : nil,
                    plannedMonthly: planned,
                    emergencyMonths: emergencyMonths,
                    emergencyReductionPercent: reductionPercent
                )
            } else {
                try service.createGoal(
                    name: trimmedName,
                    kind: kind,
                    targetMode: targetMode,
                    target: targetMode == .fixed ? fixedTarget : .zero,
                    targetDate: targetMode == .fixed && hasTargetDate
                        ? targetDate : nil,
                    plannedMonthly: planned,
                    emergencyMonths: targetMode == .emergencyMonths
                        ? emergencyMonths : 0,
                    emergencyReductionPercent: reductionPercent
                )
            }
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}

// MARK: - Reserve picker

/// Choose which savings accounts back goals. Selection is derived state for
/// Projections: while an account actively backs goals it leaves the
/// safe-to-spend cash pool automatically, and returns when deselected.
struct GoalReservePickerSheet: View {
    @SwiftUI.Environment(\.modelContext) private var context
    @Query private var accounts: [CachedFinancialAccount]
    @Query private var plaidAccounts: [CachedPlaidAccount]
    @Query private var reserveRows: [DurableGoalReserveAccount]
    @Query private var cardSettings: [DurableCardSettings]
    let model: GoalsModel?

    @State private var failure: String?

    /// Taxable brokerage accounts (Plaid investments path). Retirement
    /// subtypes are excluded — they can't fund a near-term goal without a
    /// penalty, so backing one would falsely report the goal as funded.
    private var eligibleInvestmentAccounts: [CachedPlaidAccount] {
        let retirement: Set<String> = [
            "ira", "roth", "roth 401k", "401k", "401a", "403b", "457b",
            "sep ira", "simple ira", "rollover", "pension", "hsa",
            "keogh", "sarsep", "thrift savings plan", "ugma", "utma",
            "education savings account", "529"
        ]
        return plaidAccounts
            .filter {
                let subtype = ($0.subtype ?? "").lowercased()
                return $0.currentBalanceMilliunits != nil
                    && ($0.isoCurrencyCode ?? "USD") == "USD"
                    && !retirement.contains(subtype)
                    // Investment/brokerage container only — never depository
                    // (those already appear under Cash Accounts).
                    && (($0.typeRaw ?? "").lowercased() == "investment"
                        || subtype == "brokerage")
            }
            .sorted {
                ($0.currentBalanceMilliunits ?? 0)
                    > ($1.currentBalanceMilliunits ?? 0)
            }
    }

    /// Any cash-like depository account can back goals — Plaid maps money
    /// market, CD, and cash-management products to `.cash`, not `.savings`,
    /// so filtering on savings alone hides most dedicated savings accounts.
    /// Savings sort first; the cashflow checking account is listed but the
    /// user simply doesn't select it.
    private var eligibleAccounts: [CachedFinancialAccount] {
        accounts
            .filter {
                !$0.deleted && $0.type.isCashLike
                    && ($0.isoCurrencyCode ?? "USD") == "USD"
            }
            .sorted {
                if ($0.type == .savings) != ($1.type == .savings) {
                    return $0.type == .savings
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name)
                    == .orderedAscending
            }
    }

    private var activeReserveIds: Set<String> {
        Set(reserveRows.filter(\.active).map(\.canonicalAccountId))
    }

    /// Accounts funding a card's autopay: projections treat those balances
    /// specially, so backing goals with one is blocked.
    private var cardFundingIds: Set<String> {
        Set(cardSettings.compactMap {
            $0.canonicalPaymentAccountId ?? $0.paymentAccountId
        })
    }

    var body: some View {
        GoalSheetShell(title: "Reserve Accounts") {
            Section {
                Text("Money in reserve accounts is spoken for by goals. "
                     + "While an account backs goals it won't count toward "
                     + "safe-to-spend in Projections.")
                    .font(NwTypography.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Cash Accounts") {
                if eligibleAccounts.isEmpty {
                    Text("No USD cash accounts are connected.")
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
                    Text("Taxable Investments")
                } footer: {
                    Text("Balances move with the market — if an account "
                         + "drops below what goals have allocated, you'll "
                         + "see a shortfall to resolve.")
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
        let fundsCard = cardFundingIds.contains(account.canonicalAccountId)
        return Button {
            toggle(account, isReserve: isReserve, fundsCard: fundsCard)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name)
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
                        if fundsCard {
                            NwStatusBadge("Funds a card", style: .caution)
                        }
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
                    Text(account.name)
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

    @ViewBuilder
    private var unavailableSection: some View {
        let unavailable = model?.unavailableReserves ?? []
        if !unavailable.isEmpty {
            Section("Unavailable") {
                ForEach(unavailable) { reserve in
                    unavailableRow(reserve)
                }
            }
        }
    }

    private func unavailableRow(
        _ reserve: GoalsModel.ReserveItem
    ) -> some View {
        // Re-attach suggestions: same institution+mask among connected
        // savings accounts not already backing goals. User-confirmed, never
        // automatic — these fields aren't guaranteed unique.
        let candidates = eligibleAccounts.filter {
            !activeReserveIds.contains($0.canonicalAccountId)
                && ($0.institutionName ?? "") == reserve.institutionName
                && ($0.mask ?? "") == reserve.mask
        }
        return VStack(alignment: .leading, spacing: NwSpacing.xs) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(reserve.displayName)
                        .font(NwTypography.body)
                    Text("Disconnected · counted as $0")
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
                        "Re-attach to \(candidate.name)",
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
        default: return ""
        }
    }

    private func toggle(
        _ account: CachedFinancialAccount,
        isReserve: Bool,
        fundsCard: Bool
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
            } else if fundsCard {
                failure = "\(account.name) funds a card's autopay in "
                    + "Projections. Pick a different account, or change "
                    + "the card's funding account first."
            } else if account.currentBalanceMilliunits == nil {
                failure = "\(account.name) has no reported balance yet."
            } else {
                try service.addReserveAccount(account)
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
                    accountName: account.name,
                    institutionName: account.institutionName,
                    mask: account.mask ?? ""
                )
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    private func remove(_ reserve: GoalsModel.ReserveItem) {
        do {
            if let row = reserveRows.first(
                where: { $0.id == reserve.rowId }
            ) {
                try GoalLedgerService(context: context)
                    .removeReserveAccount(row)
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    private func reattach(
        _ reserve: GoalsModel.ReserveItem,
        to account: CachedFinancialAccount
    ) {
        do {
            if let row = reserveRows.first(
                where: { $0.id == reserve.rowId }
            ) {
                try GoalLedgerService(context: context)
                    .reattachReserveAccount(row, to: account)
            }
        } catch {
            failure = error.localizedDescription
        }
    }
}

// MARK: - Allocate

/// Divide the reserve's unallocated money among goals. Pure envelope
/// allocation — no transaction is involved; the service caps each allocation
/// at the unallocated remainder.
struct GoalAllocateSheet: View {
    @SwiftUI.Environment(\.modelContext) private var context
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @Query private var goalRows: [DurableGoal]
    let unallocated: Money
    let goals: [GoalsModel.GoalItem]

    @State private var selectedGoalId: UUID?
    @State private var amountText = ""
    @State private var seeded = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Unallocated") {
                        NwAmountText(
                            unallocated, variant: .body, showCents: false
                        )
                    }
                }
                Section("Allocate to") {
                    ForEach(goals) { item in
                        Button {
                            selectedGoalId = item.goalUUID
                        } label: {
                            HStack {
                                Text(item.goal.name)
                                    .font(NwTypography.body)
                                    .foregroundStyle(NwAppColors.textPrimary)
                                Spacer()
                                if selectedGoalId == item.goalUUID {
                                    Image(
                                        systemName: "checkmark.circle.fill"
                                    )
                                    .foregroundStyle(NwAppColors.positive)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section {
                    TextField("Amount", text: $amountText)
                        .keyboardType(.decimalPad)
                        .onChange(of: amountText) { _, newValue in
                            amountText = CurrencyInputFormatter.formatted(
                                newValue
                            )
                        }
                    Button("Allocate All Unallocated") {
                        amountText = CurrencyInputFormatter.text(
                            for: unallocated
                        )
                    }
                    .font(NwTypography.footnote)
                    .disabled(unallocated.isZero)
                } footer: {
                    Text("Moves money from unallocated into the goal. To "
                         + "move money the other way, use Withdraw in the "
                         + "goal.")
                }
                if let failure {
                    Section {
                        NwInlineNotice(
                            "Can't save", message: failure, tone: .caution
                        )
                    }
                }
            }
            .navigationTitle("Allocate")
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
                    .disabled(selectedGoalId == nil || parsedAmount == nil)
                    .accessibilityLabel("Save")
                }
            }
            .onAppear {
                guard !seeded else { return }
                seeded = true
                if goals.count == 1 {
                    selectedGoalId = goals.first?.goalUUID
                }
            }
        }
        .presentationDetents([.large])
    }

    private var parsedAmount: Money? {
        guard let amount = CurrencyInputFormatter.money(from: amountText),
              amount.milliunits > 0 else { return nil }
        return amount
    }

    private func save() {
        guard let amount = parsedAmount,
              let goalId = selectedGoalId,
              let goal = goalRows.first(where: { $0.id == goalId }) else {
            return
        }
        do {
            try GoalLedgerService(context: context).addManualEntry(
                goal: goal, amount: amount, date: .now, note: nil
            )
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}

// MARK: - Purchase picker

/// Mark a posted transaction (or part of one) as spent from this goal. The
/// amount defaults to the transaction's remaining adjustable spending and is
/// validated by the service against the same ceiling.
struct GoalPurchasePickerSheet: View {
    @SwiftUI.Environment(\.modelContext) private var context
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @Query private var goalRows: [DurableGoal]
    let goalId: UUID

    @State private var searchText = ""
    @State private var selected: CachedFinancialTransaction?
    @State private var amountText = ""
    @State private var failure: String?
    @State private var candidates: [CachedFinancialTransaction] = []
    @State private var pipelineContext: SpendingEntryPipeline.Context?
    @State private var ledgerEntries: [DurableGoalLedgerEntry] = []

    var body: some View {
        NavigationStack {
            Group {
                if let selected {
                    amountForm(selected)
                } else {
                    transactionList
                }
            }
            .navigationTitle("Record Purchase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        if selected != nil { selected = nil }
                        else { dismiss() }
                    } label: {
                        NwIcon.close.image
                            .foregroundStyle(NwAppColors.liability)
                    }
                    .accessibilityLabel("Cancel")
                }
                if selected != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { save() } label: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(NwAppColors.positive)
                        }
                        .disabled(parsedAmount == nil)
                        .accessibilityLabel("Save")
                    }
                }
            }
            .task { loadCandidates() }
        }
    }

    private var transactionList: some View {
        List {
            Section {
                Text("Pick the posted transaction this goal paid for. "
                     + "It moves out of ordinary spending into the Goal "
                     + "Purchases column.")
                    .font(NwTypography.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(filteredCandidates, id: \.id) { row in
                Button {
                    select(row)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rowTitle(row))
                                .font(NwTypography.body)
                                .foregroundStyle(NwAppColors.textPrimary)
                                .lineLimit(1)
                            Text(DateDisplay.shortDate(row.postedDate))
                                .font(NwTypography.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        NwAmountText(
                            Money(milliunits: row.amountMilliunits),
                            variant: .body, showCents: true
                        )
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .searchable(text: $searchText, prompt: "Search transactions")
    }

    private func amountForm(
        _ row: CachedFinancialTransaction
    ) -> some View {
        Form {
            Section {
                LabeledContent("Transaction") { Text(rowTitle(row)) }
                LabeledContent("Posted") {
                    Text(DateDisplay.shortDate(row.postedDate))
                }
                LabeledContent("Assignable") {
                    NwAmountText(
                        remainingAdjustable(row), variant: .body,
                        showCents: true
                    )
                }
            }
            Section {
                TextField("Amount from goal", text: $amountText)
                    .keyboardType(.decimalPad)
                    .onChange(of: amountText) { _, newValue in
                        amountText = CurrencyInputFormatter.formatted(
                            newValue
                        )
                    }
            } footer: {
                Text("Defaults to the full assignable spending. Lower it "
                     + "for a partial purchase — the remainder stays in "
                     + "ordinary spending.")
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
    }

    private var filteredCandidates: [CachedFinancialTransaction] {
        guard !searchText.isEmpty else { return candidates }
        return candidates.filter {
            rowTitle($0).localizedCaseInsensitiveContains(searchText)
        }
    }

    private func rowTitle(_ row: CachedFinancialTransaction) -> String {
        row.displayName
    }

    private func remainingAdjustable(
        _ row: CachedFinancialTransaction
    ) -> Money {
        guard let pipelineContext else { return .zero }
        return SpendingEntryPipeline.remainingAdjustableAmount(
            row: row,
            existingLedgerEntries: ledgerEntries,
            context: pipelineContext
        )
    }

    private var parsedAmount: Money? {
        guard let amount = CurrencyInputFormatter.money(from: amountText),
              amount.milliunits > 0 else { return nil }
        return amount
    }

    private func select(_ row: CachedFinancialTransaction) {
        selected = row
        amountText = CurrencyInputFormatter.text(
            for: remainingAdjustable(row)
        )
    }

    private func loadCandidates() {
        let groups = (try? context.fetch(
            FetchDescriptor<DurableCategoryGroup>()
        )) ?? []
        let categories = (try? context.fetch(
            FetchDescriptor<DurableCanonicalCategory>()
        )) ?? []
        let accounts = (try? context.fetch(
            FetchDescriptor<CachedFinancialAccount>()
        )) ?? []
        ledgerEntries = (try? context.fetch(
            FetchDescriptor<DurableGoalLedgerEntry>()
        )) ?? []
        let pipelineContext = SpendingEntryPipeline.Context(
            groups: groups, categories: categories, accounts: accounts
        )
        self.pipelineContext = pipelineContext

        var descriptor = FetchDescriptor<CachedFinancialTransaction>(
            predicate: #Predicate {
                !$0.deleted && !$0.pending && !$0.requiresReview
                    && $0.amountMilliunits < 0
            },
            sortBy: [SortDescriptor(\.postedDate, order: .reverse)]
        )
        descriptor.fetchLimit = 400
        let rows = (try? context.fetch(descriptor)) ?? []
        candidates = rows.filter { row in
            SpendingEntryPipeline.remainingAdjustableAmount(
                row: row,
                existingLedgerEntries: ledgerEntries,
                context: pipelineContext
            ).milliunits > 0
        }
    }

    private func save() {
        guard let amount = parsedAmount,
              let row = selected,
              let pipelineContext,
              let goal = goalRows.first(where: { $0.id == goalId }) else {
            return
        }
        do {
            try GoalLedgerService(context: context).recordPurchase(
                goal: goal,
                row: row,
                amount: amount,
                pipelineContext: pipelineContext
            )
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}
