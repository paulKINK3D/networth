import SwiftUI
import SwiftData
import NetworthCore

struct SettingsView: View {
    @Environment(AppContainerController.self) private var container
    @Query private var settingsList: [DurableUserSettings]
    @Query(sort: \DurableManualAsset.name) private var manualAssets: [DurableManualAsset]
    @Query(sort: \CachedAccount.name) private var accounts: [CachedAccount]
    @Query(sort: \DurableCardSettings.accountId) private var cardSettings: [DurableCardSettings]
    @Query private var exclusions: [DurableExcludedSpendCategory]
    @Query private var transactionExclusions: [DurableExcludedSpendTransaction]
    @Query private var includedClosed: [DurableIncludedClosedAccount]
    @Query private var cashAccountOverrides: [DurableProjectionCashAccountOverride]

    @State private var showingTokenSheet = false
    @State private var showingAssetForm: DurableManualAsset? = nil
    @State private var showingNewAsset = false
    @State private var showingCardSheet: CachedAccount? = nil
    @State private var showingExclusionsSheet = false
    @State private var showingForceResyncConfirm = false
    @State private var showingResetChartHistory = false
    @State private var showingIncludedClosed = false
    @State private var showingCashAccounts = false
    @State private var showingCashBuffer = false

    private var settings: DurableUserSettings? { settingsList.first }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showingTokenSheet = true
                    } label: {
                        HStack {
                            Label {
                                Text(container.hasYNABToken ? "YNAB Token" : "Add YNAB Token")
                            } icon: {
                                NwIcon.keychain.image.foregroundStyle(NwAppColors.primary)
                            }
                            Spacer()
                            if container.hasYNABToken {
                                NwStatusBadge("Stored", style: .positive, icon: .success)
                            } else {
                                NwIcon.chevron.image.foregroundStyle(.secondary)
                            }
                        }
                    }
                    Toggle(isOn: faceIDBinding) {
                        Label {
                            Text("Require \(container.biometricGate.displayName)")
                        } icon: {
                            NwIcon.faceID.image.foregroundStyle(NwAppColors.primary)
                        }
                    }
                    .disabled(!container.biometricGate.isAvailable)
                    HStack {
                        Text("Re-lock after")
                        Spacer()
                        Picker("", selection: graceBinding) {
                            ForEach(Self.graceOptions, id: \.self) { mins in
                                Text(graceLabel(mins)).tag(mins)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(NwAppColors.textPrimary)
                        .labelsHidden()
                    }
                    .disabled(!container.biometricGate.isAvailable || !(settings?.faceIDEnabled ?? false))
                } header: {
                    Text("Authentication")
                } footer: {
                    Text("YNAB access is read-only. Re-lock after sets the background grace period.")
                }

                Section {
                    HStack {
                        Label {
                            Text("Last synced")
                        } icon: {
                            NwIcon.sync.image.foregroundStyle(NwAppColors.primary)
                        }
                        Spacer()
                        Text(settings?.lastSyncedAt.map { DateDisplay.shortDate($0) } ?? "Never")
                            .foregroundStyle(.secondary)
                    }
                    if let phaseLabel = syncPhaseLabel {
                        HStack(spacing: NwSpacing.sm) {
                            ProgressView().controlSize(.small)
                            Text(phaseLabel)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("Sync Now") {
                        Task { await container.syncNow() }
                    }
                    .disabled(!container.hasYNABToken || isSyncing)
                    Button("Force Full Resync") {
                        showingForceResyncConfirm = true
                    }
                    .disabled(!container.hasYNABToken || isSyncing)
                    .foregroundStyle(NwAppColors.liability)
                    Button {
                        showingResetChartHistory = true
                    } label: {
                        HStack {
                            Text("Reset Chart History…")
                            Spacer()
                            if let floor = settings?.chartStartDate {
                                Text("From \(DateDisplay.shortDate(floor))")
                                    .font(NwTypography.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(isSyncing)
                    .foregroundStyle(NwAppColors.liability)
                    Button {
                        showingIncludedClosed = true
                    } label: {
                        HStack {
                            Label {
                                Text("Include Closed Accounts…")
                                    .foregroundStyle(NwAppColors.textPrimary)
                            } icon: {
                                NwIcon.netWorth.image.foregroundStyle(NwAppColors.primary)
                            }
                            Spacer()
                            Text("\(includedClosed.count)")
                                .foregroundStyle(.secondary)
                            NwIcon.chevron.image.foregroundStyle(.secondary)
                        }
                    }
                    .disabled(isSyncing)
                } header: {
                    Text("Sync")
                } footer: {
                    Text("Full resync rebuilds chart data. Reset history changes the chart's start date.")
                }

                Section {
                    HStack {
                        Text("Projection horizon")
                        Spacer()
                        Stepper("\(settings?.projectionHorizonDays ?? 90) days",
                                value: horizonBinding, in: 30...180, step: 15)
                            .labelsHidden()
                        Text("\(settings?.projectionHorizonDays ?? 90)d")
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        showingCashAccounts = true
                    } label: {
                        HStack {
                            Label {
                                Text("Cash Accounts")
                                    .foregroundStyle(NwAppColors.textPrimary)
                            } icon: {
                                NwIcon.accounts.image.foregroundStyle(NwAppColors.primary)
                            }
                            Spacer()
                            Text("\(selectedCashAccountCount)")
                                .foregroundStyle(.secondary)
                            NwIcon.chevron.image.foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        showingCashBuffer = true
                    } label: {
                        HStack {
                            Text("Minimum Cash Buffer")
                                .foregroundStyle(NwAppColors.textPrimary)
                            Spacer()
                            Text(CurrencyFormatter.compact(Money(milliunits: settings?.dipThresholdMilliunits ?? 500_000)))
                                .foregroundStyle(.secondary)
                            NwIcon.chevron.image.foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        showingExclusionsSheet = true
                    } label: {
                        HStack {
                            Label {
                                Text("Spending Exclusions")
                                    .foregroundStyle(NwAppColors.textPrimary)
                            } icon: {
                                NwIcon.netWorth.image.foregroundStyle(NwAppColors.primary)
                            }
                            Spacer()
                            Text("\(excludedCount)")
                                .foregroundStyle(.secondary)
                            NwIcon.chevron.image.foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Projections")
                }

                Section("Manual Assets") {
                    Button {
                        showingNewAsset = true
                    } label: {
                        Label("Add Manual Asset", systemImage: "plus")
                    }
                    ForEach(manualAssets.filter { !$0.deleted }) { asset in
                        Button {
                            showingAssetForm = asset
                        } label: {
                            HStack {
                                Label {
                                    Text(asset.name.isEmpty ? "Untitled" : asset.name)
                                        .foregroundStyle(NwAppColors.textPrimary)
                                } icon: {
                                    icon(for: asset.kind).image.foregroundStyle(NwAppColors.accent)
                                }
                                Spacer()
                                NwAmountText(asset.currentValue, variant: .body)
                            }
                        }
                        .swipeActions(allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                asset.deleted = true
                                container.modelContainer.mainContext.safeSave(source: "settings.deleteAsset")
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }

                Section {
                    ForEach(creditCardAccounts) { acct in
                        let setting = cardSettings.first { $0.accountId == acct.id }
                        Button {
                            showingCardSheet = acct
                        } label: {
                            HStack {
                                Label {
                                    Text(acct.name)
                                        .foregroundStyle(NwAppColors.textPrimary)
                                } icon: {
                                    NwIcon.creditCard.image.foregroundStyle(NwAppColors.accent)
                                }
                                Spacer()
                                Text(cardSettingsSummary(setting))
                                    .foregroundStyle(.secondary)
                                    .font(NwTypography.footnote)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    }
                } header: {
                    Text("Credit Card Statements")
                } footer: {
                    Text("Projections assumes full-statement autopay.")
                }

                Section {
                    Button {
                        NotificationCenter.default.post(name: .showTutorial, object: nil)
                    } label: {
                        HStack {
                            Label {
                                Text("Show Tutorial")
                                    .foregroundStyle(NwAppColors.textPrimary)
                            } icon: {
                                NwIcon.info.image.foregroundStyle(NwAppColors.primary)
                            }
                            Spacer()
                            NwIcon.chevron.image.foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showingTokenSheet) {
                PATEntrySheet().environment(container)
            }
            .sheet(isPresented: $showingNewAsset) {
                ManualAssetForm(asset: nil)
                    .environment(container)
            }
            .sheet(item: $showingAssetForm) { asset in
                ManualAssetForm(asset: asset).environment(container)
            }
            .sheet(item: $showingCardSheet) { account in
                CardSettingsForm(account: account).environment(container)
            }
            .sheet(isPresented: $showingExclusionsSheet) {
                ExcludedCategoriesSheet().environment(container)
            }
            .sheet(isPresented: $showingResetChartHistory) {
                ResetChartHistorySheet().environment(container)
            }
            .sheet(isPresented: $showingIncludedClosed) {
                IncludedClosedAccountsSheet().environment(container)
            }
            .sheet(isPresented: $showingCashAccounts) {
                ProjectionCashAccountsSheet().environment(container)
            }
            .sheet(isPresented: $showingCashBuffer) {
                MinimumCashBufferSheet().environment(container)
            }
            .alert("Force Full Resync?", isPresented: $showingForceResyncConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Wipe & Rebuild", role: .destructive) {
                    Task { await container.forceFullResync() }
                }
            } message: {
                Text("This deletes every daily net-worth snapshot from iCloud and rebuilds the chart from scratch by re-fetching YNAB. Manual assets and settings are preserved.")
            }
        }
    }

    private var isSyncing: Bool {
        if case .syncing = container.syncCoordinator.phase { return true }
        return false
    }

    private var syncPhaseLabel: String? {
        if case .syncing(let label) = container.syncCoordinator.phase { return label }
        return nil
    }

    private var horizonBinding: Binding<Int> {
        Binding(
            get: { settings?.projectionHorizonDays ?? 90 },
            set: { newValue in
                let ctx = container.modelContainer.mainContext
                let current: DurableUserSettings
                if let existing = settings {
                    current = existing
                } else {
                    current = DurableUserSettings()
                    ctx.insert(current)
                }
                current.projectionHorizonDays = newValue
                ctx.safeSave(source: "settings.horizon")
            }
        )
    }

    private var excludedCount: Int { exclusions.count + transactionExclusions.count }

    private var selectedCashAccountCount: Int {
        var overrides: [String: Bool] = [:]
        cashAccountOverrides.forEach { overrides[$0.accountId] = $0.included }
        return accounts.filter { account in
            guard !account.deleted, !account.closed, account.kind.isCashLike else { return false }
            return overrides[account.id] ?? account.onBudget
        }.count
    }

    private static let graceOptions: [Int] = [0, 5, 15, 30, 60, 120, 240]

    private func graceLabel(_ mins: Int) -> String {
        switch mins {
        case 0:   return "Immediately"
        case 60:  return "1 hour"
        case 120: return "2 hours"
        case 240: return "4 hours"
        default:  return "\(mins) min"
        }
    }

    private var graceBinding: Binding<Int> {
        Binding(
            get: { settings?.biometricGraceMinutes ?? 30 },
            set: { newValue in
                let ctx = container.modelContainer.mainContext
                let current: DurableUserSettings
                if let existing = settings {
                    current = existing
                } else {
                    current = DurableUserSettings()
                    ctx.insert(current)
                }
                current.biometricGraceMinutes = newValue
                ctx.safeSave(source: "settings.biometricGrace")
            }
        )
    }

    private var faceIDBinding: Binding<Bool> {
        Binding(
            get: { settings?.faceIDEnabled ?? false },
            set: { newValue in
                let ctx = container.modelContainer.mainContext
                let current: DurableUserSettings
                if let existing = settings {
                    current = existing
                } else {
                    current = DurableUserSettings()
                    ctx.insert(current)
                }
                current.faceIDEnabled = newValue
                ctx.safeSave(source: "settings.faceID")
            }
        )
    }

    private var creditCardAccounts: [CachedAccount] {
        accounts.filter { !$0.deleted && !$0.closed && $0.kind.isCreditCardLike }
    }

    private func cardSettingsSummary(_ setting: DurableCardSettings?) -> String {
        guard let setting,
              setting.paymentDueDay >= 1,
              let paymentId = setting.paymentAccountId,
              let paymentName = accounts.first(where: { $0.id == paymentId })?.name else {
            return "Finish setup"
        }
        return "Closes \(setting.statementCycleDay) · pays \(setting.paymentDueDay)\n\(paymentName)"
    }

    private func icon(for kind: ManualAssetKind) -> NwIcon {
        switch kind {
        case .realEstate:  return .realEstate
        case .vehicle:     return .vehicle
        case .brokerage:   return .brokerage
        case .retirement:  return .retirement
        case .crypto:      return .crypto
        case .collectible: return .collectible
        case .other:       return .otherAsset
        }
    }
}

private struct ProjectionCashAccountsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppContainerController.self) private var container
    @Query(sort: \CachedAccount.name) private var accounts: [CachedAccount]
    @Query private var overrides: [DurableProjectionCashAccountOverride]

    private var cashAccounts: [CachedAccount] {
        accounts.filter { !$0.deleted && !$0.closed && $0.kind.isCashLike }
    }

    var body: some View {
        NwModalLayout(title: "Cash Accounts", onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: NwSpacing.lg) {
                Text("Select cash available for projections. On-budget accounts start included.")
                    .font(NwTypography.footnote)
                    .foregroundStyle(.secondary)
                if cashAccounts.isEmpty {
                    NwEmptyState(
                        title: "No cash accounts",
                        message: "Sync YNAB to load checking, savings, and cash accounts.",
                        icon: .accounts
                    )
                } else {
                    VStack(spacing: 0) {
                        ForEach(cashAccounts) { account in
                            HStack(spacing: NwSpacing.sm) {
                                NwIcon.forAccountKind(account.typeRaw).image
                                    .foregroundStyle(NwAppColors.primary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.name).foregroundStyle(NwAppColors.textPrimary)
                                    Text(account.onBudget ? "On budget" : "Off budget")
                                        .font(NwTypography.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Toggle("", isOn: binding(for: account))
                                    .labelsHidden()
                            }
                            .padding(.vertical, NwSpacing.sm)
                            if account.id != cashAccounts.last?.id { Divider() }
                        }
                    }
                    .padding(.horizontal, NwSpacing.md)
                    .background(NwAppColors.cardSurface)
                    .clipShape(RoundedRectangle(cornerRadius: NwCornerRadius.md, style: .continuous))
                }
            }
        }
    }

    private func binding(for account: CachedAccount) -> Binding<Bool> {
        Binding(
            get: { overrides.first(where: { $0.accountId == account.id })?.included ?? account.onBudget },
            set: { set(account: account, included: $0) }
        )
    }

    private func set(account: CachedAccount, included: Bool) {
        let ctx = container.modelContainer.mainContext
        let existing = overrides.filter { $0.accountId == account.id }
        if included == account.onBudget {
            existing.forEach(ctx.delete)
        } else if let first = existing.first {
            first.included = included
            existing.dropFirst().forEach(ctx.delete)
        } else {
            ctx.insert(DurableProjectionCashAccountOverride(accountId: account.id, included: included))
        }
        if !ctx.safeSave(source: "settings.cashAccounts.toggle") { ctx.rollback() }
    }
}

private struct MinimumCashBufferSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppContainerController.self) private var container
    @Query private var settingsList: [DurableUserSettings]
    @State private var amountText = ""
    @State private var saveError: String?
    @FocusState private var amountFocused: Bool
    @State private var replacedOnFirstFocus = false

    var body: some View {
        NwModalLayout(title: "Minimum Cash Buffer", onClose: { dismiss() }, onConfirm: save) {
            VStack(alignment: .leading, spacing: NwSpacing.lg) {
                if let saveError {
                    NwInlineNotice("Couldn't save", message: saveError, tone: .warning)
                }
                Text("Cash below this amount is marked tight.")
                    .font(NwTypography.footnote)
                    .foregroundStyle(.secondary)
                TextField("500", text: $amountText)
                    .keyboardType(.decimalPad)
                    .font(NwTypography.display)
                    .focused($amountFocused)
                    .onChange(of: amountFocused) { _, focused in
                        if focused && !replacedOnFirstFocus {
                            amountText = ""
                            replacedOnFirstFocus = true
                        }
                    }
                    .padding(NwSpacing.md)
                    .background(NwAppColors.cardSurface)
                    .clipShape(RoundedRectangle(cornerRadius: NwCornerRadius.md, style: .continuous))
            }
        }
        .onAppear {
            let amount = Money(milliunits: settingsList.first?.dipThresholdMilliunits ?? 500_000)
            amountText = NSDecimalNumber(decimal: amount.decimalValue).stringValue
        }
    }

    private func save() {
        let normalized = amountText.replacingOccurrences(of: ",", with: "")
        guard let value = Decimal(string: normalized), value >= 0 else {
            saveError = "Enter a valid amount of zero or more."
            return
        }
        let ctx = container.modelContainer.mainContext
        let settings = settingsList.first ?? {
            let value = DurableUserSettings()
            ctx.insert(value)
            return value
        }()
        let prior = settings.dipThresholdMilliunits
        settings.dipThresholdMilliunits = Money.dollars(value).milliunits
        guard ctx.safeSave(source: "settings.minimumCashBuffer") else {
            settings.dipThresholdMilliunits = prior
            saveError = "Saving the minimum cash buffer failed. Try again."
            return
        }
        dismiss()
    }
}
