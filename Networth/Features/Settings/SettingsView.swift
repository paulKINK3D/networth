import SwiftUI
import SwiftData
import NetworthCore
import struct LinkKit.LinkTokenConfiguration
import struct LinkKit.Plaid
import class LinkKit.PlaidLinkSession
import UIKit

struct SettingsView: View {
    @SwiftUI.Environment(AppContainerController.self) private var container
    @Query private var settingsList: [DurableUserSettings]
    @Query(sort: \DurableManualAsset.name) private var manualAssets: [DurableManualAsset]
    @Query(sort: \CachedAccount.name) private var accounts: [CachedAccount]
    @Query(sort: \DurableCardSettings.accountId) private var cardSettings: [DurableCardSettings]
    @Query private var exclusions: [DurableExcludedSpendCategory]
    @Query private var transactionExclusions: [DurableExcludedSpendTransaction]
    @Query private var includedClosed: [DurableIncludedClosedAccount]
    @Query private var cashAccountOverrides: [DurableProjectionCashAccountOverride]
    @Query(sort: \CachedPlaidItem.institutionName) private var plaidItems: [CachedPlaidItem]
    @Query(sort: \CachedPlaidAccount.name) private var plaidAccounts: [CachedPlaidAccount]
    @Query private var plaidTreatments: [DurablePlaidAccountTreatment]

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
    @State private var showingPlaidConnection = false
    @State private var showingPlaidReview = false
    @State private var plaidItemToRemove: CachedPlaidItem?
    @State private var showingRemovePlaidConfirm = false
    @State private var plaidActionError: String?

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
                    Button {
                        showingPlaidConnection = true
                    } label: {
                        HStack {
                            Label {
                                Text(plaidItems.isEmpty ? "Connect Investment Account" : "Connect Another Account")
                                    .foregroundStyle(NwAppColors.textPrimary)
                            } icon: {
                                NwIcon.investment.image.foregroundStyle(NwAppColors.primary)
                            }
                            Spacer()
                            NwIcon.chevron.image.foregroundStyle(.secondary)
                        }
                    }

                    ForEach(plaidItems) { item in
                        HStack {
                            Text(item.institutionName)
                            Spacer()
                            NwStatusBadge(
                                item.status == "healthy" ? "Connected" : "Attention",
                                style: item.status == "healthy" ? .positive : .caution,
                                icon: item.status == "healthy" ? .success : .warning
                            )
                        }
                        .swipeActions(allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                plaidItemToRemove = item
                                showingRemovePlaidConfirm = true
                            } label: {
                                Label("Remove", systemImage: NwIcon.delete.rawValue)
                            }
                        }
                    }

                    if !plaidAccounts.isEmpty {
                        Button {
                            showingPlaidReview = true
                        } label: {
                            HStack {
                                Text("Review Connected Accounts")
                                    .foregroundStyle(NwAppColors.textPrimary)
                                Spacer()
                                if pendingPlaidReviewCount > 0 {
                                    NwStatusBadge("\(pendingPlaidReviewCount)", style: .caution, icon: .warning)
                                }
                                NwIcon.chevron.image.foregroundStyle(.secondary)
                            }
                        }
                    }

                    switch container.plaidSyncCoordinator.phase {
                    case .syncing:
                        HStack(spacing: NwSpacing.sm) {
                            ProgressView().controlSize(.small)
                            Text("Syncing investments")
                                .foregroundStyle(.secondary)
                        }
                    case .error(let message):
                        Text(message)
                            .font(NwTypography.footnote)
                            .foregroundStyle(NwAppColors.liability)
                    case .idle:
                        EmptyView()
                    }
                    if let plaidActionError {
                        Text(plaidActionError)
                            .font(NwTypography.footnote)
                            .foregroundStyle(NwAppColors.liability)
                    }
                } header: {
                    Text("Investment Connections")
                } footer: {
                    Text("Plaid is read-only. Connected accounts do not count until reviewed.")
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
            .sheet(isPresented: $showingPlaidConnection) {
                PlaidConnectionSheet().environment(container)
            }
            .sheet(isPresented: $showingPlaidReview) {
                PlaidAccountReviewSheet().environment(container)
            }
            .alert("Force Full Resync?", isPresented: $showingForceResyncConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Wipe & Rebuild", role: .destructive) {
                    Task { await container.forceFullResync() }
                }
            } message: {
                Text("This deletes every daily net-worth snapshot from iCloud and rebuilds the chart from scratch by re-fetching YNAB. Manual assets and settings are preserved.")
            }
            .alert("Remove Connection?", isPresented: $showingRemovePlaidConfirm, presenting: plaidItemToRemove) { item in
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive) {
                    Task {
                        do {
                            try await container.removePlaidItem(id: item.id)
                            plaidActionError = nil
                            plaidItemToRemove = nil
                        } catch {
                            plaidActionError = "The connection could not be removed. Try again."
                        }
                    }
                }
            } message: { item in
                Text("This disconnects \(item.institutionName) from Networth. It does not change the institution account.")
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

    private var pendingPlaidReviewCount: Int {
        return plaidAccounts.filter {
            let accountID = $0.id
            return (plaidTreatments.last(where: { $0.plaidAccountId == accountID })?.treatment
                ?? .pendingReview) == .pendingReview
        }.count
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
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(AppContainerController.self) private var container
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
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(AppContainerController.self) private var container
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

private struct PlaidConnectionSheet: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(AppContainerController.self) private var container

    @State private var backendToken = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var linkSession: PlaidLinkSession?

    var body: some View {
        NavigationStack {
            Form {
                if !container.hasPlaidBackendToken {
                    Section {
                        SecureField("Private app token", text: $backendToken)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text("Backend Access")
                    } footer: {
                        Text("Paste the private token generated with the Networth backend.")
                    }
                }

                if let errorMessage {
                    Section {
                        NwInlineNotice("Connection failed", message: errorMessage, tone: .warning)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }

                if container.hasPlaidBackendToken, errorMessage != nil {
                    Section {
                        Button("Replace Private Token", role: .destructive) {
                            replaceBackendToken()
                        }
                        .disabled(isWorking)
                    }
                }

                Section {
                    Button {
                        beginConnection()
                    } label: {
                        HStack {
                            if isWorking {
                                ProgressView().controlSize(.small)
                            }
                            Text(isWorking ? "Connecting" : "Continue")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(isWorking || (!container.hasPlaidBackendToken && backendToken.trimmed.isEmpty))
                }
            }
            .navigationTitle("Connect Investments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        NwIcon.close.image
                            .foregroundStyle(NwAppColors.liability)
                    }
                    .accessibilityLabel("Close")
                }
            }
            .interactiveDismissDisabled(isWorking)
        }
    }

    private func beginConnection() {
        errorMessage = nil
        isWorking = true
        Task { @MainActor in
            do {
                if !container.hasPlaidBackendToken {
                    try await container.savePlaidBackendToken(backendToken)
                }
                let linkToken = try await container.createPlaidLinkToken()
                isWorking = false
                linkSession = try PlaidLinkPresenter.present(
                    token: linkToken,
                    onSuccess: { publicToken in
                        Task { @MainActor in
                            linkSession = nil
                            await finishConnection(publicToken: publicToken)
                        }
                    },
                    onExit: { message in
                        Task { @MainActor in
                            linkSession = nil
                            isWorking = false
                            if let message { errorMessage = message }
                        }
                    }
                )
            } catch {
                isWorking = false
                errorMessage = connectionMessage(for: error)
            }
        }
    }

    @MainActor
    private func finishConnection(publicToken: String) async {
        isWorking = true
        do {
            _ = try await container.completePlaidLink(publicToken: publicToken)
            isWorking = false
            dismiss()
        } catch {
            isWorking = false
            errorMessage = connectionMessage(for: error)
        }
    }

    private func connectionMessage(for error: Error) -> String {
        switch error as? PlaidClientError {
        case .missingConfiguration:
            return "Backend setup is incomplete."
        case .unauthorized:
            return "The private app token was rejected."
        case .invalidResponse:
            return "The investment service rejected the request."
        case .decoding:
            return "The investment response could not be read."
        case .transport:
            return "The investment service could not be reached."
        case .cancelled:
            return "The connection was cancelled."
        case nil:
            return (error as? LocalizedError)?.errorDescription
                ?? "Try again in a moment."
        }
    }

    private func replaceBackendToken() {
        isWorking = true
        Task { @MainActor in
            do {
                try await container.clearPlaidBackendToken()
                backendToken = ""
                errorMessage = nil
            } catch {
                errorMessage = "The stored private token could not be cleared."
            }
            isWorking = false
        }
    }
}

@MainActor
private enum PlaidLinkPresenter {
    static func present(
        token: String,
        onSuccess: @escaping (String) -> Void,
        onExit: @escaping (String?) -> Void
    ) throws -> PlaidLinkSession {
        let configuration = LinkTokenConfiguration(
            token: token,
            onSuccess: { success in onSuccess(success.publicToken) },
            onExit: { exit in
                onExit(exit.error.map { String(describing: $0) })
            },
            onEvent: nil,
            onLoad: nil
        )
        let session = try Plaid.createPlaidLinkSession(configuration: configuration)
        guard let presenter = presentingViewController else {
            throw PlaidPresentationError.missingViewController
        }
        session.open(using: .viewController(presenter))
        return session
    }

    private static var presentingViewController: UIViewController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .windows.first { $0.isKeyWindow }?
            .rootViewController
        return topViewController(from: root)
    }

    private static func topViewController(from controller: UIViewController?) -> UIViewController? {
        if let presented = controller?.presentedViewController {
            return topViewController(from: presented)
        }
        if let navigation = controller as? UINavigationController {
            return topViewController(from: navigation.visibleViewController)
        }
        if let tab = controller as? UITabBarController {
            return topViewController(from: tab.selectedViewController)
        }
        return controller
    }
}

private enum PlaidPresentationError: LocalizedError {
    case missingViewController

    var errorDescription: String? {
        "The connection screen could not be presented."
    }
}

struct PlaidAccountReviewSheet: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(AppContainerController.self) private var container
    @Query(sort: \CachedPlaidAccount.institutionName) private var plaidAccounts: [CachedPlaidAccount]
    @Query(sort: \CachedAccount.name) private var ynabAccounts: [CachedAccount]
    @Query(sort: \DurableManualAsset.name) private var manualAssets: [DurableManualAsset]
    @Query private var treatments: [DurablePlaidAccountTreatment]

    var body: some View {
        NavigationStack {
            List {
                ForEach(plaidAccounts) { account in
                    Section {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.name)
                                    .font(NwTypography.bodyEmphasis)
                                Text(accountSubtitle(account))
                                    .font(NwTypography.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let balance = account.currentBalance {
                                NwAmountText(balance, variant: .body, showCents: false)
                            }
                        }

                        Picker("Count as", selection: treatmentBinding(for: account)) {
                            Text("Needs Review").tag(PlaidAccountTreatment.pendingReview)
                            if accountSupportsInclusion(account) {
                                Text("Separate Account").tag(PlaidAccountTreatment.included)
                            }
                            if !eligibleYNABAccounts.isEmpty {
                                Text("Already in YNAB").tag(PlaidAccountTreatment.duplicateYNAB)
                            }
                            if !eligibleManualAssets.isEmpty {
                                Text("Already a Manual Asset").tag(PlaidAccountTreatment.duplicateManualAsset)
                            }
                            Text("Exclude").tag(PlaidAccountTreatment.excluded)
                        }

                        if treatment(for: account).treatment == .duplicateYNAB {
                            Picker("Matches", selection: duplicateSourceBinding(for: account)) {
                                ForEach(eligibleYNABAccounts) { source in
                                    Text(source.name).tag(source.id)
                                }
                            }
                        } else if treatment(for: account).treatment == .duplicateManualAsset {
                            Picker("Matches", selection: duplicateSourceBinding(for: account)) {
                                ForEach(eligibleManualAssets) { source in
                                    Text(source.name.isEmpty ? "Untitled Asset" : source.name)
                                        .tag(source.id.uuidString)
                                }
                            }
                        }
                    } header: {
                        Text(account.institutionName)
                    }
                }
            }
            .navigationTitle("Review Accounts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        NwIcon.confirm.image
                            .foregroundStyle(NwAppColors.positive)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
    }

    private var eligibleYNABAccounts: [CachedAccount] {
        ynabAccounts.filter { !$0.deleted && !$0.closed && $0.kind == .investment }
    }

    private var eligibleManualAssets: [DurableManualAsset] {
        manualAssets.filter {
            !$0.deleted && [.brokerage, .retirement, .crypto].contains($0.kind)
        }
    }

    private func treatment(for account: CachedPlaidAccount) -> DurablePlaidAccountTreatment {
        treatments.first { $0.plaidAccountId == account.id }
            ?? DurablePlaidAccountTreatment(plaidAccountId: account.id)
    }

    private func treatmentBinding(for account: CachedPlaidAccount) -> Binding<PlaidAccountTreatment> {
        Binding(
            get: { treatment(for: account).treatment },
            set: { setTreatment($0, for: account) }
        )
    }

    private func duplicateSourceBinding(for account: CachedPlaidAccount) -> Binding<String> {
        Binding(
            get: {
                treatment(for: account).duplicateSourceId
                    ?? defaultSourceID(for: treatment(for: account).treatment)
                    ?? ""
            },
            set: { setDuplicateSource($0, for: account) }
        )
    }

    private func setTreatment(_ value: PlaidAccountTreatment, for account: CachedPlaidAccount) {
        let row = persistedTreatment(for: account)
        row.treatment = value
        row.duplicateSourceId = defaultSourceID(for: value)
        row.updatedAt = .now
        saveReviewChange(source: "settings.plaidTreatment")
    }

    private func setDuplicateSource(_ sourceID: String, for account: CachedPlaidAccount) {
        let row = persistedTreatment(for: account)
        row.duplicateSourceId = sourceID
        row.updatedAt = .now
        saveReviewChange(source: "settings.plaidDuplicateSource")
    }

    private func persistedTreatment(for account: CachedPlaidAccount) -> DurablePlaidAccountTreatment {
        if let existing = treatments.first(where: { $0.plaidAccountId == account.id }) {
            return existing
        }
        let row = DurablePlaidAccountTreatment(plaidAccountId: account.id)
        container.modelContainer.mainContext.insert(row)
        return row
    }

    private func defaultSourceID(for treatment: PlaidAccountTreatment) -> String? {
        switch treatment {
        case .duplicateYNAB:
            return eligibleYNABAccounts.first?.id
        case .duplicateManualAsset:
            return eligibleManualAssets.first?.id.uuidString
        case .pendingReview, .included, .excluded:
            return nil
        }
    }

    private func saveReviewChange(source: String) {
        let context = container.modelContainer.mainContext
        if context.safeSave(source: source) {
            container.recordDailySnapshot()
        } else {
            context.rollback()
        }
    }

    private func accountSupportsInclusion(_ account: CachedPlaidAccount) -> Bool {
        account.unofficialCurrencyCode == nil
            && account.isoCurrencyCode?.uppercased() == "USD"
            && account.currentBalance != nil
    }

    private func accountSubtitle(_ account: CachedPlaidAccount) -> String {
        var values: [String] = []
        if let subtype = account.subtype, !subtype.isEmpty {
            values.append(subtype.replacingOccurrences(of: "_", with: " ").capitalized)
        }
        if let mask = account.mask, !mask.isEmpty {
            values.append("•••• \(mask)")
        }
        if !accountSupportsInclusion(account) {
            values.append("Unsupported balance")
        }
        return values.joined(separator: " · ")
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
