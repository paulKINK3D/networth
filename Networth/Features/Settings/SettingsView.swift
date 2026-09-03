import SwiftUI
import SwiftData
import NetworthCore
import struct LinkKit.LinkTokenConfiguration
import struct LinkKit.Plaid
import class LinkKit.PlaidLinkSession
import UIKit

enum SettingsPage {
    case connections
    case budget
    case assets
    case privacy

    var title: String {
        switch self {
        case .connections: "Accounts & Sync"
        case .budget: "Projections"
        case .assets: "Manual Assets"
        case .privacy: "Privacy & App"
        }
    }
}

enum SettingsRouter {
    static func open(_ page: SettingsPage? = nil) {
        NotificationCenter.default.post(
            name: .openSettings,
            object: page
        )
    }
}

struct SettingsView: View {
    @SwiftUI.Environment(AppContainerController.self) private var container
    @Query private var settingsList: [DurableUserSettings]
    @Query(sort: \DurableManualAsset.name) private var manualAssets: [DurableManualAsset]
    @Query(sort: \DurableCardSettings.accountId) private var cardSettings: [DurableCardSettings]
    @Query private var exclusions: [DurableExcludedSpendCategory]
    @Query private var transactionExclusions: [DurableExcludedSpendTransaction]
    @Query private var cashAccountOverrides: [DurableProjectionCashAccountOverride]
    @Query(sort: \CachedPlaidItem.institutionName) private var plaidItems: [CachedPlaidItem]
    @Query(sort: \CachedPlaidAccount.name) private var plaidAccounts: [CachedPlaidAccount]
    @Query private var plaidTreatments: [DurablePlaidAccountTreatment]
    @Query(sort: \CachedFinancialAccount.name) private var financialAccounts: [CachedFinancialAccount]
    @Query private var accountNicknames: [DurableAccountNickname]
    @Query(sort: \DurableCanonicalPayee.name)
    private var canonicalPayees: [DurableCanonicalPayee]
    @Query(sort: \DurableCanonicalCategory.name)
    private var canonicalCategories: [DurableCanonicalCategory]
    @Query(sort: \DurableRecurringExpectation.nextOccurrenceAt)
    private var recurringExpectations: [DurableRecurringExpectation]

    @State private var showingAssetForm: DurableManualAsset? = nil
    @State private var showingNewAsset = false
    @State private var showingExpectationForm: DurableRecurringExpectation? = nil
    @State private var showingNewExpectation = false
    @State private var showingCardSheet: CardSettingsTarget? = nil
    @State private var showingExclusionsSheet = false
    @State private var showingForceResyncConfirm = false
    @State private var showingCashAccounts = false
    @State private var showingCashBuffer = false
    @State private var showingPlaidConnection = false
    @State private var showingPlaidReview = false
    @State private var showingPlaidBankingConnection = false
    @State private var showingPlaidBackendToken = false
    @State private var showingClaudeConsent = false
    @State private var plaidItemToRemove: CachedPlaidItem?
    @State private var plaidManagedManualAsset: DurableManualAsset?
    @State private var manualAssetToDelete: DurableManualAsset?
    @State private var showingRemovePlaidConfirm = false
    @State private var plaidActionError: String?

    private let page: SettingsPage?

    init(page: SettingsPage? = nil) {
        self.page = page
    }

    private var settings: DurableUserSettings? { settingsList.first }

    var body: some View {
        List {
            if page == nil {
                Section {
                    NavigationLink {
                        SettingsView(page: .connections)
                    } label: {
                        NwSettingsNavigationRow(
                            "Accounts & Sync",
                            subtitle: "Banking, investments, and data refresh",
                            icon: .accounts,
                            value: "Plaid"
                        )
                    }

                    NavigationLink {
                        SettingsView(page: .budget)
                    } label: {
                        NwSettingsNavigationRow(
                            "Projections",
                            subtitle: "Cash accounts and card timing",
                            icon: .projections,
                            value: "\(settings?.projectionHorizonDays ?? 90)d"
                        )
                    }

                    NavigationLink {
                        SettingsView(page: .assets)
                    } label: {
                        NwSettingsNavigationRow(
                            "Manual Assets",
                            subtitle: "Property and manually tracked values",
                            icon: .otherAsset,
                            value: "\(activeManualAssetCount)"
                        )
                    }

                    NavigationLink {
                        SettingsView(page: .privacy)
                    } label: {
                        NwSettingsNavigationRow(
                            "Privacy & App",
                            subtitle: "Face ID, Claude access, and tutorial",
                            icon: .faceID,
                            value: settings?.faceIDEnabled == true ? "Locked" : nil
                        )
                    }
                }
            }

            if page == .privacy {
                Section {
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
                }
            }

            if page == .connections {
                Section {
                    NavigationLink {
                        CanonicalPayeeListView()
                    } label: {
                        LabeledContent(
                            "Contacts",
                            value: "\(canonicalPayees.filter { !$0.archived }.count)"
                        )
                    }

                    NavigationLink {
                        CanonicalCategoryListView()
                    } label: {
                        LabeledContent(
                            "Categories",
                            value: "\(canonicalCategories.filter { !$0.hidden }.count)"
                        )
                    }
                } header: {
                    Text("Transaction Organization")
                }
            }

            if page == .connections {
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
                    .disabled(!canSync || isAnySyncing)
                    Button("Force Full Resync") {
                        showingForceResyncConfirm = true
                    }
                    .disabled(!container.hasPlaidBackendToken || isSyncing)
                    .foregroundStyle(NwAppColors.liability)
                } header: {
                    Text("Sync")
                }
            }

            if page == .connections {
                Section {
                    Button {
                        showingPlaidBankingConnection = true
                    } label: {
                        NwSettingsActionRow(
                            hasTransactionConnection
                                ? "Manage Banking Accounts"
                                : "Connect Banking Accounts",
                            subtitle: "Checking, savings, and credit cards",
                            icon: .accounts
                        )
                    }

                    ForEach(transactionItems) { item in
                        connectionItemRow(item)
                    }
                } header: {
                    Text("Banking Connections")
                } footer: {
                    Text("Transactions · Up to two years of history")
                }
            }

            if page == .connections, hasTransactionConnection {
                Section {
                    HStack {
                        Label {
                            Text("Primary source")
                        } icon: {
                            NwIcon.accounts.image.foregroundStyle(NwAppColors.primary)
                        }
                        Spacer()
                        Text("Plaid")
                            .foregroundStyle(.secondary)
                    }

                    Toggle(isOn: claudeFallbackBinding) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Claude fallback")
                            Text("Only for transactions the on-device model cannot classify confidently.")
                                .font(NwTypography.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Transaction Import")
                } footer: {
                    Text("Networth learns names and categories from reviewed history and future corrections.")
                }
            }

            if page == .privacy {
                Section {
                    NavigationLink {
                        ClaudeDataAccessView()
                    } label: {
                        HStack {
                            Label {
                                Text("Claude.ai Access")
                            } icon: {
                                NwIcon.cloud.image
                                    .foregroundStyle(NwAppColors.primary)
                            }
                            Spacer()
                            if settings?.claudeDataSyncEnabled == true {
                                NwStatusBadge(
                                    "On",
                                    style: .positive,
                                    icon: .success
                                )
                            }
                        }
                    }
                } header: {
                    Text("Claude.ai")
                } footer: {
                    Text("Optional read-only access to an encrypted financial copy. Separate from transaction classification.")
                }
            }

            if page == .connections {
                Section {
                    Button {
                        showingPlaidConnection = true
                    } label: {
                        NwSettingsActionRow(
                            investmentItems.isEmpty
                                ? "Connect Investment Accounts"
                                : "Connect Another Investment Account",
                            subtitle: "Brokerage and retirement accounts",
                            icon: .investment
                        )
                    }

                    ForEach(investmentItems) { item in
                        connectionItemRow(item)
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
                    Text("Read-only · Review before inclusion")
                }
            }

            if page == .connections, !plaidAccounts.isEmpty {
                Section {
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
                } header: {
                    Text("Investment Account Review")
                }
            }

            if page == .connections {
                Section {
                    Button {
                        showingPlaidBackendToken = true
                    } label: {
                        HStack(spacing: NwSpacing.md) {
                            NwIcon.keychain.image
                                .foregroundStyle(NwAppColors.primary)
                            Text(container.hasPlaidBackendToken
                                 ? "Replace Private Token"
                                 : "Set Private Token")
                                .foregroundStyle(NwAppColors.textPrimary)
                            Spacer()
                            NwStatusBadge(
                                container.hasPlaidBackendToken ? "Saved" : "Missing",
                                style: container.hasPlaidBackendToken ? .positive : .caution,
                                icon: container.hasPlaidBackendToken ? .success : .warning
                            )
                            NwIcon.chevron.image.foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Backend Access")
                } footer: {
                    Text("Stored securely in Keychain. Replacing it does not disconnect your accounts.")
                }
            }

            if page == .budget {
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
            }

            if page == .assets {
                Section("Manual Assets") {
                    Button {
                        showingNewAsset = true
                    } label: {
                        Label("Add Manual Asset", systemImage: "plus")
                    }
                    ForEach(manualAssets.filter { !$0.deleted }) { asset in
                        let replacementAccounts = plaidResolver.replacementAccounts(for: asset)
                        Button {
                            if replacementAccounts.isEmpty {
                                showingAssetForm = asset
                            } else {
                                plaidManagedManualAsset = asset
                            }
                        } label: {
                            HStack {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(asset.name.isEmpty ? "Untitled" : asset.name)
                                            .foregroundStyle(NwAppColors.textPrimary)
                                        Text(
                                            replacementAccounts.isEmpty
                                                ? asset.kind.displayName
                                                : "\(asset.kind.displayName) · Live from Plaid"
                                        )
                                        .font(NwTypography.footnote)
                                        .foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    icon(for: asset.kind).image.foregroundStyle(NwAppColors.accent)
                                }
                                Spacer()
                                NwAmountText(
                                    plaidResolver.effectiveValue(for: asset),
                                    variant: .body
                                )
                            }
                        }
                        .swipeActions(
                            edge: .leading,
                            allowsFullSwipe: false
                        ) {
                            if replacementAccounts.isEmpty {
                                Button {
                                    showingAssetForm = asset
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(NwAppColors.info)
                            }
                        }
                        .swipeActions(
                            edge: .trailing,
                            allowsFullSwipe: false
                        ) {
                            if replacementAccounts.isEmpty {
                                Button(role: .destructive) {
                                    manualAssetToDelete = asset
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(NwAppColors.liability)
                            }
                        }
                    }
                }
            }

            if page == .budget {
                Section {
                    ForEach(cardSettingsTargets) { target in
                        let setting = cardSettings.first {
                            ($0.canonicalAccountId ?? $0.accountId) == target.id
                                || $0.accountId == target.id
                        }
                        Button {
                            showingCardSheet = target
                        } label: {
                            HStack {
                                Label {
                                    Text(target.name)
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
                    Text("Full-statement autopay assumed.")
                }
            }

            if page == .budget {
                Section {
                    Button {
                        showingNewExpectation = true
                    } label: {
                        Label("Add Recurring Item", systemImage: "plus")
                    }
                    ForEach(activeExpectations) { expectation in
                        Button {
                            showingExpectationForm = expectation
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(expectation.payeeName)
                                        .foregroundStyle(NwAppColors.textPrimary)
                                    Text(expectationSubtitle(expectation))
                                        .font(NwTypography.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(CurrencyFormatter.currency(
                                    expectation.amount, showCents: false
                                ))
                                .foregroundStyle(
                                    expectation.amountMilliunits < 0
                                        ? NwAppColors.textPrimary
                                        : NwAppColors.positive
                                )
                            }
                            .contentShape(Rectangle())
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button {
                                let prior = expectation.nextOccurrenceAt
                                expectation.nextOccurrenceAt =
                                    RecurringExpectations.advance(
                                        expectation.nextOccurrenceAt,
                                        cadence: expectation.cadence,
                                        calendar: Calendar.current
                                    )
                                expectation.updatedAt = .now
                                if !container.modelContainer.mainContext
                                    .safeSave(source: "settings.skipExpectation") {
                                    expectation.nextOccurrenceAt = prior
                                }
                            } label: {
                                Label("Skip Next", systemImage: "arrow.uturn.forward")
                            }
                            .tint(NwAppColors.info)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                let prior = expectation.archived
                                expectation.archived = true
                                expectation.updatedAt = .now
                                if !container.modelContainer.mainContext
                                    .safeSave(source: "settings.archiveExpectation") {
                                    // Revert so the row doesn't look deleted
                                    // while the store still has it.
                                    expectation.archived = prior
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(NwAppColors.liability)
                        }
                    }
                } header: {
                    Text("Recurring")
                } footer: {
                    Text("Your authoritative upcoming bills, income, transfers, and investment contributions. An approved matching transaction advances the next date automatically.")
                }
            }

            if page == .privacy {
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
        }
            .navigationTitle(page?.title ?? "Settings")
            .navigationBarTitleDisplayMode(page == nil ? .large : .inline)
            .sheet(isPresented: $showingNewAsset) {
                ManualAssetForm(asset: nil)
                    .environment(container)
            }
            .sheet(item: $showingAssetForm) { asset in
                ManualAssetForm(asset: asset).environment(container)
            }
            .sheet(item: $showingExpectationForm) { expectation in
                RecurringExpectationForm(expectation: expectation)
                    .environment(container)
            }
            .sheet(isPresented: $showingNewExpectation) {
                RecurringExpectationForm(expectation: nil)
                    .environment(container)
            }
            .sheet(item: $showingCardSheet) { target in
                CardSettingsForm(target: target).environment(container)
            }
            .sheet(isPresented: $showingExclusionsSheet) {
                ExcludedCategoriesSheet().environment(container)
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
            .sheet(isPresented: $showingPlaidBankingConnection) {
                PlaidBankingConnectionSheet().environment(container)
            }
            .sheet(isPresented: $showingPlaidBackendToken) {
                PlaidBackendTokenSheet().environment(container)
            }
            .alert("Use Claude for Difficult Transactions?", isPresented: $showingClaudeConsent) {
                Button("Cancel", role: .cancel) {}
                Button("Allow") {
                    container.setClaudeFallbackEnabled(true)
                }
            } message: {
                Text("For low-confidence items only, Networth sends the transaction description, merchant/counterparty, Plaid category, payment channel, and direction through your private backend to Anthropic Claude. It never sends account numbers, balances, amounts, dates, or transaction history.")
            }
            .alert("Force Full Resync?", isPresented: $showingForceResyncConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Wipe & Rebuild", role: .destructive) {
                    Task { await container.forceFullResync() }
                }
            } message: {
                Text("Re-imports all banking transactions from Plaid. Chart history, assets, and settings stay intact.")
            }
            .alert(
                "Delete Manual Asset?",
                isPresented: Binding(
                    get: { manualAssetToDelete != nil },
                    set: { if !$0 { manualAssetToDelete = nil } }
                ),
                presenting: manualAssetToDelete
            ) { asset in
                Button("Cancel", role: .cancel) {
                    manualAssetToDelete = nil
                }
                Button("Delete", role: .destructive) {
                    deleteManualAsset(asset)
                }
            } message: { asset in
                Text(
                    "Removes \(asset.name.isEmpty ? "this manual asset" : asset.name) and its saved value history from Net Worth."
                )
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
                            plaidActionError = (error as? LocalizedError)?.errorDescription
                                ?? "The connection could not be removed. Try again."
                        }
                    }
                }
            } message: { item in
                Text("Disconnects \(item.institutionName) from Networth only.")
            }
            .alert(
                "Live Value Managed by Plaid",
                isPresented: Binding(
                    get: { plaidManagedManualAsset != nil },
                    set: { if !$0 { plaidManagedManualAsset = nil } }
                ),
                presenting: plaidManagedManualAsset
            ) { _ in
                Button("OK") { plaidManagedManualAsset = nil }
            } message: { asset in
                Text("Plaid supplies the current value for \(asset.name.isEmpty ? "this asset" : asset.name). Change its match before editing or deleting; manual history stays intact.")
            }
    }

    private func deleteManualAsset(_ asset: DurableManualAsset) {
        manualAssetToDelete = nil
        let context = container.modelContainer.mainContext
        let wasDeleted = asset.deleted
        asset.deleted = true
        guard context.safeSave(source: "settings.deleteAsset") else {
            asset.deleted = wasDeleted
            return
        }
        container.recordDailySnapshot()
    }

    private var isSyncing: Bool {
        if case .syncing = container.plaidTransactionSyncCoordinator.phase { return true }
        return false
    }

    private var isAnySyncing: Bool {
        if isSyncing { return true }
        if case .syncing = container.plaidSyncCoordinator.phase { return true }
        return false
    }

    private var canSync: Bool {
        container.hasPlaidBackendToken
    }

    private var investmentItems: [CachedPlaidItem] {
        plaidItems.filter { $0.products.contains("investments") }
    }

    private var transactionItems: [CachedPlaidItem] {
        plaidItems.filter { $0.products.contains("transactions") }
    }

    private var hasTransactionConnection: Bool {
        settings?.plaidTransactionsEnabled == true
            || plaidItems.contains { $0.products.contains("transactions") }
    }

    private var claudeFallbackBinding: Binding<Bool> {
        Binding(
            get: { settings?.claudeFallbackEnabled ?? false },
            set: { enabled in
                if enabled {
                    showingClaudeConsent = true
                } else {
                    container.setClaudeFallbackEnabled(false)
                }
            }
        )
    }

    private var plaidResolver: PlaidContributionResolver {
        PlaidContributionResolver(
            plaidAccounts: plaidAccounts,
            treatments: plaidTreatments,
            manualAssets: manualAssets
        )
    }

    private var syncPhaseLabel: String? {
        if case .syncing(let label) = container.plaidTransactionSyncCoordinator.phase {
            return label
        }
        return nil
    }

    private var pendingPlaidReviewCount: Int {
        return plaidAccounts.filter {
            let accountID = $0.id
            return (plaidTreatments.last(where: { $0.plaidAccountId == accountID })?.treatment
                ?? .pendingReview) == .pendingReview
        }.count
    }

    private func connectionItemRow(_ item: CachedPlaidItem) -> some View {
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
            .tint(NwAppColors.liability)
        }
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

    private var activeManualAssetCount: Int {
        manualAssets.filter { !$0.deleted }.count
    }

    private var activeExpectations: [DurableRecurringExpectation] {
        recurringExpectations.filter { !$0.archived }
    }

    private func expectationSubtitle(
        _ expectation: DurableRecurringExpectation
    ) -> String {
        let next = expectation.nextOccurrenceAt.formatted(
            date: .abbreviated, time: .omitted
        )
        return "\(expectation.cadence.displayName) · next \(next)"
    }

    private var selectedCashAccountCount: Int {
        var overridesByCanonicalID: [String: Bool] = [:]
        cashAccountOverrides.forEach {
            if let id = $0.canonicalAccountId {
                overridesByCanonicalID[id] = $0.included
            }
        }
        return financialAccounts.filter {
            !$0.deleted && $0.type.isCashLike
                && (overridesByCanonicalID[$0.canonicalAccountId] ?? true)
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

    private var cardSettingsTargets: [CardSettingsTarget] {
        financialAccounts
            .filter { !$0.deleted && $0.type == .creditCard }
            .map {
                CardSettingsTarget(
                    id: $0.canonicalAccountId,
                    name: accountNameResolver.name(for: $0)
                )
            }
    }

    private func cardSettingsSummary(_ setting: DurableCardSettings?) -> String {
        guard let setting, setting.paymentDueDay >= 1 else {
            return "Finish setup"
        }
        let paymentName = [
            setting.canonicalPaymentAccountId, setting.paymentAccountId
        ]
        .compactMap { id -> String? in
            guard let id else { return nil }
            if let financialAccount = financialAccounts.first(where: {
                $0.canonicalAccountId == id
            }) {
                return accountNameResolver.name(for: financialAccount)
            }
            return nil
        }
        .first
        guard let paymentName else { return "Finish setup" }
        return "Closes \(setting.statementCycleDay) · pays \(setting.paymentDueDay)\n\(paymentName)"
    }

    private var accountNameResolver: AccountDisplayNameResolver {
        AccountDisplayNameResolver(nicknames: accountNicknames)
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
    @Query(sort: \CachedFinancialAccount.name) private var financialAccounts: [CachedFinancialAccount]
    @Query private var overrides: [DurableProjectionCashAccountOverride]
    @Query private var goalReserves: [DurableGoalReserveAccount]
    @Query private var accountNicknames: [DurableAccountNickname]

    /// Accounts actively backing Goals are excluded from the pool by
    /// derivation; the toggle locks so the user changes this in Goals, not
    /// here, and their underlying preference is preserved for when the
    /// account stops backing goals.
    private var goalReserveIds: Set<String> {
        Set(goalReserves.filter(\.active).map(\.canonicalAccountId))
    }

    var body: some View {
        NwModalLayout(title: "Cash Accounts", onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: NwSpacing.lg) {
                Text("Choose cash available for projections.")
                    .font(NwTypography.footnote)
                    .foregroundStyle(.secondary)
                if plaidCashAccounts.isEmpty {
                    NwEmptyState(
                        title: "No cash accounts",
                        message: "Sync Plaid to load checking, savings, and cash accounts.",
                        icon: .accounts
                    )
                } else {
                    VStack(spacing: 0) {
                        ForEach(plaidCashAccounts) { account in
                            HStack(spacing: NwSpacing.sm) {
                                NwIcon.forAccountKind(account.kind.rawValue).image
                                    .foregroundStyle(NwAppColors.primary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(accountNameResolver.name(for: account))
                                        .foregroundStyle(NwAppColors.textPrimary)
                                    Text(isGoalReserve(account)
                                        ? "Backs goals — managed in Goals"
                                        : account.institutionName ?? "Plaid")
                                        .font(NwTypography.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if isGoalReserve(account) {
                                    Toggle("", isOn: .constant(false))
                                        .labelsHidden()
                                        .disabled(true)
                                } else {
                                    Toggle("", isOn: binding(for: account))
                                        .labelsHidden()
                                }
                            }
                            .padding(.vertical, NwSpacing.sm)
                            if account.canonicalAccountId != plaidCashAccounts.last?.canonicalAccountId {
                                Divider()
                            }
                        }
                    }
                    .padding(.horizontal, NwSpacing.md)
                    .background(NwAppColors.cardSurface)
                    .clipShape(RoundedRectangle(cornerRadius: NwCornerRadius.md, style: .continuous))
                }
            }
        }
    }

    private var plaidCashAccounts: [CachedFinancialAccount] {
        financialAccounts
            .filter { !$0.deleted && $0.type.isCashLike }
            .sorted {
                accountNameResolver.name(for: $0)
                    .localizedCaseInsensitiveCompare(
                        accountNameResolver.name(for: $1)
                    ) == .orderedAscending
            }
    }

    private var accountNameResolver: AccountDisplayNameResolver {
        AccountDisplayNameResolver(nicknames: accountNicknames)
    }

    private func isGoalReserve(_ account: CachedFinancialAccount) -> Bool {
        goalReserveIds.contains(account.canonicalAccountId)
    }

    private func binding(for account: CachedFinancialAccount) -> Binding<Bool> {
        Binding(
            get: {
                overrides.first {
                    $0.canonicalAccountId == account.canonicalAccountId
                }?.included ?? true
            },
            set: { set(account: account, included: $0) }
        )
    }

    private func set(account: CachedFinancialAccount, included: Bool) {
        let context = container.modelContainer.mainContext
        let existing = overrides.filter {
            $0.canonicalAccountId == account.canonicalAccountId
        }
        if included {
            existing.forEach(context.delete)
        } else if let first = existing.first {
            first.included = false
            existing.dropFirst().forEach(context.delete)
        } else {
            let row = DurableProjectionCashAccountOverride(
                accountId: "",
                included: false
            )
            row.canonicalAccountId = account.canonicalAccountId
            context.insert(row)
        }
        if !context.safeSave(source: "settings.cashAccounts.togglePlaid") {
            context.rollback()
        }
    }
}

private struct MinimumCashBufferSheet: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(AppContainerController.self) private var container
    @Query private var settingsList: [DurableUserSettings]
    @State private var amountText = ""
    @State private var saveError: String?

    var body: some View {
        NwModalLayout(title: "Minimum Cash Buffer", onClose: { dismiss() }, onConfirm: save) {
            VStack(alignment: .leading, spacing: NwSpacing.lg) {
                if let saveError {
                    NwInlineNotice("Couldn't save", message: saveError, tone: .warning)
                }
                Text("Balances below this are marked tight.")
                    .font(NwTypography.footnote)
                    .foregroundStyle(.secondary)
                TextField("500", text: $amountText)
                    .nwCurrencyInput(text: $amountText)
                    .font(NwTypography.display)
                    .padding(NwSpacing.md)
                    .background(NwAppColors.cardSurface)
                    .clipShape(RoundedRectangle(cornerRadius: NwCornerRadius.md, style: .continuous))
            }
        }
        .onAppear {
            let amount = Money(milliunits: settingsList.first?.dipThresholdMilliunits ?? 500_000)
            amountText = CurrencyInputFormatter.text(for: amount)
        }
    }

    private func save() {
        guard let amount = CurrencyInputFormatter.money(from: amountText),
              amount >= .zero else {
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
        settings.dipThresholdMilliunits = amount.milliunits
        guard ctx.safeSave(source: "settings.minimumCashBuffer") else {
            settings.dipThresholdMilliunits = prior
            saveError = "Saving the minimum cash buffer failed. Try again."
            return
        }
        dismiss()
    }
}

private struct PlaidBackendTokenSheet: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(AppContainerController.self) private var container

    @State private var token = ""
    @State private var saving = false
    @State private var saveError: String?

    var body: some View {
        NwModalLayout(
            title: container.hasPlaidBackendToken
                ? "Replace Private Token"
                : "Set Private Token",
            onClose: { dismiss() },
            onConfirm: save,
            confirmDisabled: trimmedToken.isEmpty || saving
        ) {
            VStack(alignment: .leading, spacing: NwSpacing.lg) {
                NwInlineNotice(
                    container.hasPlaidBackendToken
                        ? "Existing connections stay connected"
                        : "Backend access required",
                    message: container.hasPlaidBackendToken
                        ? "Saving replaces only the credential Networth uses for its private backend."
                        : "This token authorizes Networth to use your private Plaid and Claude services.",
                    tone: .info
                )

                VStack(alignment: .leading, spacing: NwSpacing.sm) {
                    Text("Private Token")
                        .font(NwTypography.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    SecureField(
                        "Paste the new token",
                        text: $token,
                        prompt: Text("Paste the new token")
                    )
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(NwTypography.body)
                    .padding(NwSpacing.md)
                    .background(NwAppColors.cardSurface)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: NwCornerRadius.md,
                            style: .continuous
                        )
                    )
                }

                if let saveError {
                    NwInlineNotice(
                        "Couldn't save",
                        message: saveError,
                        tone: .warning
                    )
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var trimmedToken: String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        saving = true
        saveError = nil
        Task { @MainActor in
            do {
                try await container.savePlaidBackendToken(trimmedToken)
                dismiss()
            } catch {
                saveError = error.localizedDescription
                saving = false
            }
        }
    }
}

private struct PlaidBankingConnectionSheet: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(AppContainerController.self) private var container
    @Query(sort: \CachedPlaidItem.institutionName) private var items: [CachedPlaidItem]

    @State private var backendToken = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var linkSession: PlaidLinkSession?
    @State private var itemToRemove: CachedPlaidItem?
    @State private var showingRemoveConfirm = false

    private var connectedItems: [CachedPlaidItem] {
        items.filter { $0.products.contains("transactions") }
    }

    private var upgradeableItems: [CachedPlaidItem] {
        items.filter { !$0.products.contains("transactions") }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Connect checking, savings, and credit-card accounts. Plaid will return posted and pending transactions plus up to two years of history.")
                        .font(NwTypography.footnote)
                        .foregroundStyle(.secondary)
                }

                if !container.hasPlaidBackendToken {
                    Section("Backend Access") {
                        SecureField("Private app token", text: $backendToken)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                if !connectedItems.isEmpty {
                    Section {
                        ForEach(connectedItems) { item in
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
                                    itemToRemove = item
                                    showingRemoveConfirm = true
                                } label: {
                                    Label("Remove", systemImage: NwIcon.delete.rawValue)
                                }
                                .tint(NwAppColors.liability)
                            }
                        }
                    } header: {
                        Text("Connected")
                    }
                }

                if !upgradeableItems.isEmpty {
                    Section {
                        ForEach(upgradeableItems) { item in
                            Button {
                                beginUpgrade(item)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.institutionName)
                                            .foregroundStyle(NwAppColors.textPrimary)
                                        Text("Add transaction access")
                                            .font(NwTypography.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    NwIcon.chevron.image.foregroundStyle(.secondary)
                                }
                            }
                            .disabled(isWorking)
                        }
                    } header: {
                        Text("Add Transaction Access")
                    } footer: {
                        Text("Updating an existing connection avoids creating a duplicate Plaid Item.")
                    }
                }

                Section {
                    Button {
                        beginNewConnection()
                    } label: {
                        HStack {
                            if isWorking { ProgressView().controlSize(.small) }
                            Text(isWorking ? "Connecting" : "Connect a New Institution")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(
                        isWorking
                            || (!container.hasPlaidBackendToken && backendToken.trimmed.isEmpty)
                    )
                }

                if let errorMessage {
                    Section {
                        NwInlineNotice("Connection failed", message: errorMessage, tone: .warning)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .navigationTitle("Banking Connections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        NwIcon.close.image.foregroundStyle(NwAppColors.liability)
                    }
                    .accessibilityLabel("Close")
                }
            }
            .interactiveDismissDisabled(isWorking)
            .alert("Remove Connection?", isPresented: $showingRemoveConfirm, presenting: itemToRemove) { item in
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive) {
                    Task { @MainActor in
                        do {
                            try await container.removePlaidItem(id: item.id)
                            itemToRemove = nil
                        } catch {
                            errorMessage = (error as? LocalizedError)?.errorDescription
                                ?? "The connection could not be removed. Try again."
                        }
                    }
                }
            } message: { item in
                Text("Disconnects \(item.institutionName) from Networth only.")
            }
        }
    }

    private func prepareBackendToken() async throws {
        if !container.hasPlaidBackendToken {
            try await container.savePlaidBackendToken(backendToken)
        }
    }

    private func beginNewConnection() {
        errorMessage = nil
        isWorking = true
        Task { @MainActor in
            do {
                try await prepareBackendToken()
                let token = try await container.createPlaidTransactionLinkToken()
                isWorking = false
                linkSession = try PlaidLinkPresenter.present(
                    token: token,
                    onSuccess: { publicToken in
                        Task { @MainActor in
                            linkSession = nil
                            isWorking = true
                            do {
                                _ = try await container.completePlaidTransactionLink(
                                    publicToken: publicToken
                                )
                                isWorking = false
                                dismiss()
                            } catch {
                                isWorking = false
                                errorMessage = message(for: error)
                            }
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
                errorMessage = message(for: error)
            }
        }
    }

    private func beginUpgrade(_ item: CachedPlaidItem) {
        errorMessage = nil
        isWorking = true
        Task { @MainActor in
            do {
                try await prepareBackendToken()
                let token = try await container.createPlaidTransactionUpdateLinkToken(itemId: item.id)
                isWorking = false
                linkSession = try PlaidLinkPresenter.present(
                    token: token,
                    onSuccess: { _ in
                        Task { @MainActor in
                            linkSession = nil
                            isWorking = true
                            do {
                                try await container.completePlaidTransactionUpgrade(itemId: item.id)
                                isWorking = false
                                dismiss()
                            } catch {
                                isWorking = false
                                errorMessage = message(for: error)
                            }
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
                errorMessage = message(for: error)
            }
        }
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? "The banking service could not complete the request."
    }
}

struct PlaidClassificationReviewSheet: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(\.modelContext) private var modelContext
    @Query(sort: \CachedFinancialAccount.name)
    private var financialAccounts: [CachedFinancialAccount]
    @Query private var accountNicknames: [DurableAccountNickname]
    @State private var transactions: [CachedFinancialTransaction] = []
    @State private var isLoading = false
    @State private var hasMore = true
    @State private var loadError: String?
    @State private var loadedInbox = false

    private static let pageSize = 50

    var body: some View {
        NavigationStack {
            Group {
                if !loadedInbox {
                    ProgressView()
                } else if transactions.isEmpty, loadError == nil {
                    NwEmptyState(
                        title: "All caught up",
                        message: "New posted transactions will appear here for confirmation.",
                        icon: .success
                    )
                    .padding(NwSpacing.screenPadding)
                } else {
                    reviewInbox
                }
            }
            .background(NwAppColors.background.ignoresSafeArea())
            .navigationTitle("Review Transactions")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                guard !loadedInbox else { return }
                loadInitialInbox()
                loadedInbox = true
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        NwIcon.close.image
                            .foregroundStyle(NwAppColors.liability)
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
    }

    private var reviewInbox: some View {
        List {
            let needsAttention = transactions.filter {
                reviewReadiness(for: $0) != .ready
            }
            let readyToConfirm = transactions.filter {
                reviewReadiness(for: $0) == .ready
            }

            if !needsAttention.isEmpty {
                Section("Needs Attention") {
                    ForEach(needsAttention) { transaction in
                        reviewRow(for: transaction)
                    }
                }
            }

            if !readyToConfirm.isEmpty {
                Section("Ready to Confirm") {
                    ForEach(readyToConfirm) { transaction in
                        reviewRow(for: transaction)
                    }
                }
            }

            Section {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                } else if let loadError {
                    VStack(alignment: .leading, spacing: NwSpacing.sm) {
                        Text(loadError)
                            .font(NwTypography.footnote)
                            .foregroundStyle(NwAppColors.liability)
                        Button("Retry") {
                            self.loadError = nil
                            loadNextPage()
                        }
                    }
                } else if hasMore {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .onAppear {
                        loadNextPage()
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func reviewRow(
        for transaction: CachedFinancialTransaction
    ) -> some View {
        let readiness = reviewReadiness(for: transaction)
        return NavigationLink {
            PlaidTransactionReviewEditor(
                transaction: transaction,
                dismissAfterSave: true,
                onSaved: {
                    removeCompletedReview(transaction.id)
                }
            )
        } label: {
            VStack(alignment: .leading, spacing: NwSpacing.sm) {
                HStack {
                    NwStatusBadge(
                        readiness.label,
                        style: readiness.badgeStyle,
                        icon: readiness.icon
                    )
                    Spacer(minLength: NwSpacing.sm)
                    Text(
                        transaction.postedDate.formatted(
                            date: .abbreviated,
                            time: .omitted
                        )
                    )
                    .font(NwTypography.footnote)
                    .foregroundStyle(.secondary)
                }

                NwTransactionRow(
                    title: transaction.displayName,
                    subtitle: reviewSubtitle(for: transaction),
                    amount: Money(
                        milliunits: transaction.amountMilliunits
                    )
                )
            }
            .padding(.vertical, NwSpacing.xs)
            .contentShape(Rectangle())
        }
    }

    private func loadInitialInbox() {
        transactions = []
        hasMore = true
        loadError = nil
        loadNextPage()
    }

    private func loadNextPage() {
        guard !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            var descriptor = FetchDescriptor<CachedFinancialTransaction>(
                predicate: #Predicate {
                    $0.requiresReview
                        && !$0.deleted
                        && !$0.pending
                },
                sortBy: [
                    SortDescriptor(
                        \.reviewOriginRaw,
                        order: .reverse
                    ),
                    SortDescriptor(\.postedDate, order: .reverse),
                    SortDescriptor(\.id, order: .forward)
                ]
            )
            descriptor.fetchLimit = Self.pageSize
            descriptor.fetchOffset = transactions.count
            let page = try modelContext.fetch(descriptor)
            let loadedIDs = Set(transactions.map(\.id))
            transactions.append(
                contentsOf: page.filter { !loadedIDs.contains($0.id) }
            )
            hasMore = page.count == Self.pageSize
        } catch {
            loadError = "More transactions could not be loaded."
        }
    }

    private func removeCompletedReview(_ id: String) {
        transactions.removeAll { $0.id == id }
        if transactions.count < Self.pageSize / 2, hasMore {
            loadNextPage()
        }
    }

    private func reviewReadiness(
        for transaction: CachedFinancialTransaction
    ) -> PlaidReviewReadiness {
        guard transaction.payeeCanonicalId != nil else {
            return .needsContact
        }
        if transaction.isSplit {
            let splits = transaction.subtransactions
            guard splits.count >= 2,
                  splits.map(\.amount).sum().milliunits
                    == transaction.amountMilliunits else {
                return .needsSplit
            }
            return .ready
        }
        if transaction.forecastTreatment.requiresCategory {
            let categoryName = transaction.categoryName?.trimmed ?? ""
            guard transaction.categoryCanonicalId != nil,
                  !categoryName.isEmpty else {
                return .needsCategory
            }
        }
        return .ready
    }

    private func reviewSubtitle(
        for transaction: CachedFinancialTransaction
    ) -> String {
        let classification = transaction.isSplit
            ? transaction.categoryDisplayName
            : transaction.forecastTreatment.requiresCategory
                ? transaction.categoryDisplayName
                : transaction.forecastTreatment.displayName
        let account = plaidTransactionAccountLabel(
            for: transaction,
            financialAccounts: financialAccounts,
            accountNicknames: accountNicknames
        )
        return "\(classification) · \(account)"
    }
}

private enum PlaidReviewReadiness: Equatable {
    case ready
    case needsContact
    case needsCategory
    case needsSplit

    var label: String {
        switch self {
        case .ready: "Ready"
        case .needsContact: "Needs contact"
        case .needsCategory: "Needs category"
        case .needsSplit: "Needs split"
        }
    }

    var badgeStyle: NwStatusBadgeStyle {
        self == .ready ? .positive : .caution
    }

    var icon: NwIcon {
        self == .ready ? .success : .warning
    }
}

private struct PlaidSplitDraft: Identifiable {
    let id: UUID
    var persistedID: String?
    var categoryID: String?
    var categoryName: String
    var treatment: ForecastTreatment?
    var goalId: UUID?
    var expenseFunding: ExpenseFundingChoice
    var amountText: String

    init(
        id: UUID = UUID(),
        persistedID: String? = nil,
        categoryID: String? = nil,
        categoryName: String = "",
        treatment: ForecastTreatment? = nil,
        goalId: UUID? = nil,
        expenseFunding: ExpenseFundingChoice = .monthlyBudget,
        amountText: String = ""
    ) {
        self.id = id
        self.persistedID = persistedID
        self.categoryID = categoryID
        self.categoryName = categoryName
        self.treatment = treatment
        self.goalId = goalId
        self.expenseFunding = expenseFunding
        self.amountText = amountText
    }
}

/// One cluster of unreviewed transactions sharing the same
/// suggested payee, category, and type. Approving writes an authoritative
/// user decision for every member in a single save.
struct HistoricalReviewCluster: Identifiable {
    let id: String
    let displayName: String
    let payeeCanonicalId: String?
    let categoryName: String?
    let categoryCanonicalId: String?
    let treatment: ForecastTreatment
    let transactionIDs: [String]
    let totalMilliunits: Int64
    /// Members carry their own suggested legs; approval preserves each
    /// transaction's split instead of writing one flat category.
    var isSplit: Bool = false

    var canBatchApprove: Bool {
        guard !displayName.isEmpty else { return false }
        guard treatment != .unknown,
              !TransactionTypeRules.requiresGoal(treatment) else {
            return false
        }
        guard treatment.requiresCategory else { return true }
        return categoryCanonicalId != nil
            || categoryName?.isEmpty == false
    }

    var canApproveAsShown: Bool {
        isSplit ? !displayName.isEmpty : canBatchApprove
    }

    var transactionCountText: String {
        transactionIDs.count == 1
            ? "1 transaction"
            : "\(transactionIDs.count) transactions"
    }

    var approvalRequirement: String? {
        guard !canApproveAsShown else { return nil }
        let needsPayee = displayName.isEmpty
        let needsCategory = treatment.requiresCategory
            && categoryCanonicalId == nil
            && categoryName?.isEmpty != false

        if needsPayee && needsCategory {
            return "Add a payee and choose a category to approve."
        }
        if needsPayee {
            return "Add a payee to approve."
        }
        if treatment == .unknown {
            return "Choose a transaction type to approve."
        }
        if TransactionTypeRules.requiresGoal(treatment) {
            return "Open each transaction to choose a goal."
        }
        if needsCategory {
            return "Choose a category to approve."
        }
        return "Edit the details before approving."
    }

    static func build(
        from rows: [CachedFinancialTransaction]
    ) -> [HistoricalReviewCluster] {
        let grouped = Dictionary(grouping: rows) { row -> String in
            let payeeKey = row.payeeCanonicalId
                ?? row.displayName.trimmed.lowercased()
            let categoryKey = row.categoryCanonicalId
                ?? row.categoryName?.trimmed.lowercased()
                ?? ""
            // Unit separator: user-visible names can contain any printable
            // delimiter, so a printable one could collide two clusters.
            return [payeeKey, categoryKey, row.forecastTreatmentRaw]
                .joined(separator: "\u{1F}")
        }
        return grouped.map { key, members in
            let sample = members[0]
            return HistoricalReviewCluster(
                id: key,
                displayName: sample.displayName.trimmed,
                payeeCanonicalId: sample.payeeCanonicalId,
                categoryName: sample.categoryName?.trimmed,
                categoryCanonicalId: sample.categoryCanonicalId,
                treatment: sample.forecastTreatment,
                transactionIDs: members.map(\.id),
                totalMilliunits: members.reduce(0) {
                    $0 + $1.amountMilliunits
                },
                isSplit: !sample.subtransactions.isEmpty
            )
        }
        .sorted {
            if $0.transactionIDs.count != $1.transactionIDs.count {
                return $0.transactionIDs.count > $1.transactionIDs.count
            }
            return $0.displayName.localizedCaseInsensitiveCompare(
                $1.displayName
            ) == .orderedAscending
        }
    }

    static func pending(in context: ModelContext) -> [HistoricalReviewCluster] {
        let descriptor = FetchDescriptor<CachedFinancialTransaction>(
            predicate: #Predicate {
                $0.requiresReview && !$0.deleted && !$0.pending
            }
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        return build(from: rows)
    }
}

/// Grouped review of pending transactions: one row per suggested payee/category
/// cluster with always-aligned edit and approval actions. Anything that needs
/// edits drills into the individual type-first editor, whose corrections
/// become new training evidence.
struct GroupedHistoricalReviewSheet: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(AppContainerController.self) private var container

    @State private var clusters: [HistoricalReviewCluster] = []
    @State private var approveError: String?
    @State private var loaded = false
    @State private var editingCluster: HistoricalReviewCluster?
    @State private var isSelecting = false
    @State private var selectedClusterIDs: Set<String> = []
    @State private var isBatchApproving = false
    @State private var batchProgress: String?

    var body: some View {
        NavigationStack {
            Group {
                if !loaded {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if clusters.isEmpty {
                    NwEmptyState(
                        title: "Transactions reviewed",
                        message: "Every pending transaction has been approved.",
                        icon: .success
                    )
                } else {
                    List {
                        if let approveError {
                            NwInlineNotice(
                                "Couldn't approve",
                                message: approveError,
                                tone: .warning
                            )
                            .listRowBackground(Color.clear)
                        }
                        if isSelecting {
                            Section {
                                Button(allApprovableSelected
                                    ? "Deselect All"
                                    : "Select All") {
                                    selectedClusterIDs = allApprovableSelected
                                        ? []
                                        : Set(approvableClusters.map(\.id))
                                }
                                if let batchProgress {
                                    HStack(spacing: NwSpacing.sm) {
                                        ProgressView().controlSize(.small)
                                        Text(batchProgress)
                                            .font(NwTypography.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            } footer: {
                                Text("Select groups to approve as shown. Groups with an editing instruction cannot be selected.")
                            }
                        }
                        ForEach(clusters) { cluster in
                            clusterRow(cluster)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Review Transactions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(NwAppColors.liability)
                    }
                    .accessibilityLabel("Close")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if isSelecting {
                        Button("Approve \(selectedClusterIDs.count)") {
                            approveSelected()
                        }
                        .disabled(selectedClusterIDs.isEmpty || isBatchApproving)
                        Button("Done") {
                            isSelecting = false
                            selectedClusterIDs = []
                        }
                        .disabled(isBatchApproving)
                    } else if !clusters.isEmpty {
                        Button("Select") { isSelecting = true }
                    }
                }
            }
            .interactiveDismissDisabled(isBatchApproving)
            .onAppear(perform: reload)
            .sheet(item: $editingCluster) { cluster in
                ClusterBatchEditSheet(cluster: cluster, onSaved: reload)
                    .environment(container)
            }
        }
    }

    private var approvableClusters: [HistoricalReviewCluster] {
        clusters.filter(\.canApproveAsShown)
    }

    private var allApprovableSelected: Bool {
        !approvableClusters.isEmpty
            && selectedClusterIDs.count == approvableClusters.count
    }

    @ViewBuilder
    private func clusterRow(_ cluster: HistoricalReviewCluster) -> some View {
        if isSelecting {
            let selectable = cluster.canApproveAsShown
            Button {
                guard selectable else { return }
                if selectedClusterIDs.contains(cluster.id) {
                    selectedClusterIDs.remove(cluster.id)
                } else {
                    selectedClusterIDs.insert(cluster.id)
                }
            } label: {
                HStack(spacing: NwSpacing.md) {
                    Image(systemName: selectedClusterIDs.contains(cluster.id)
                        ? "checkmark.circle.fill"
                        : "circle")
                        .font(.title3)
                        .foregroundStyle(
                            selectedClusterIDs.contains(cluster.id)
                                ? NwAppColors.positive
                                : Color.secondary
                        )
                    clusterLabel(cluster)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .opacity(selectable ? 1 : 0.65)
            }
            .buttonStyle(.plain)
        } else {
            standardClusterRow(cluster)
        }
    }

    @ViewBuilder
    private func standardClusterRow(
        _ cluster: HistoricalReviewCluster
    ) -> some View {
        NavigationLink {
            clusterDetail(cluster)
        } label: {
            clusterLabel(cluster)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            // Reclassify the whole group before approving — e.g. a payee
            // whose suggested type is wrong for every member.
            Button {
                editingCluster = cluster
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(NwAppColors.info)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if cluster.canApproveAsShown {
                Button {
                    approve(cluster)
                } label: {
                    Label("Approve", systemImage: "checkmark")
                }
                .tint(NwAppColors.positive)
            }
        }
    }

    private func clusterLabel(
        _ cluster: HistoricalReviewCluster
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(cluster.displayName.isEmpty
                ? "Unnamed merchant"
                : cluster.displayName)
                .font(NwTypography.body.weight(.semibold))
            Text(clusterSubtitle(cluster))
                .font(NwTypography.footnote)
                .foregroundStyle(.secondary)
            if let requirement = cluster.approvalRequirement {
                Label(
                    "Edit required: \(requirement)",
                    systemImage: "exclamationmark.circle.fill"
                )
                    .font(NwTypography.footnote)
                    .foregroundStyle(NwAppColors.caution)
            }
        }
    }

    private func clusterDetail(_ cluster: HistoricalReviewCluster) -> some View {
        ClusterTransactionsDetail(cluster: cluster, onChanged: reload)
            .environment(container)
    }

    /// The subtitle IS the approval preview: exactly the type (and
    /// category, when the type takes one) the green check will write.
    private func clusterSubtitle(_ cluster: HistoricalReviewCluster) -> String {
        var parts: [String] = [cluster.treatment.displayName]
        if cluster.treatment.requiresCategory,
           let categoryName = cluster.categoryName,
           !categoryName.isEmpty {
            parts.append(categoryName)
        }
        parts.append(cluster.transactionCountText)
        parts.append(
            CurrencyFormatter.currency(
                Money(milliunits: cluster.totalMilliunits).absolute
            )
        )
        return parts.joined(separator: " · ")
    }

    /// Approves every selected cluster as shown, sequentially with visible
    /// progress — each approval re-runs the classifier pass, so large
    /// selections take a moment.
    private func approveSelected() {
        guard !isBatchApproving else { return }
        approveError = nil
        isBatchApproving = true
        let targets = clusters.filter {
            selectedClusterIDs.contains($0.id)
        }
        Task { @MainActor in
            let coordinator = container.plaidTransactionSyncCoordinator
            var approvedTotal = 0
            for (index, cluster) in targets.enumerated() {
                batchProgress =
                    "Approving \(index + 1) of \(targets.count)…"
                await Task.yield()
                // Decisions only — the expensive classifier pass and save
                // run ONCE below, not per cluster.
                approvedTotal += cluster.isSplit
                    ? coordinator.approveSuggestedSplitTransactions(
                        ids: cluster.transactionIDs,
                        finalize: false
                    )
                    : coordinator.approveTransactions(
                        ids: cluster.transactionIDs,
                        displayName: cluster.displayName,
                        payeeCanonicalId: cluster.payeeCanonicalId,
                        categoryName: cluster.categoryName,
                        categoryCanonicalId: cluster.categoryCanonicalId,
                        treatment: cluster.treatment,
                        finalize: false
                    )
            }
            batchProgress = "Saving…"
            await Task.yield()
            if approvedTotal > 0, !coordinator.finalizeBatchApprovals() {
                approvedTotal = 0
            }
            batchProgress = nil
            isBatchApproving = false
            isSelecting = false
            selectedClusterIDs = []
            if approvedTotal == 0 {
                approveError = "None of the selected groups could be approved."
            }
            reload()
        }
    }

    private func approve(_ cluster: HistoricalReviewCluster) {
        approveError = nil
        // Split members are approved with their OWN suggested legs; flat
        // clusters share one classification.
        let approved = cluster.isSplit
            ? container.plaidTransactionSyncCoordinator
                .approveSuggestedSplitTransactions(
                    ids: cluster.transactionIDs
                )
            : container.approvePlaidTransactionCluster(
                ids: cluster.transactionIDs,
                displayName: cluster.displayName,
                payeeCanonicalId: cluster.payeeCanonicalId,
                categoryName: cluster.categoryName,
                categoryCanonicalId: cluster.categoryCanonicalId,
                treatment: cluster.treatment
            )
        if approved == 0 {
            approveError = "This group could not be approved. Open it and review a transaction to fix the details."
        } else if cluster.isSplit,
                  approved < cluster.transactionIDs.count {
            let remaining = cluster.transactionIDs.count - approved
            approveError = remaining == 1
                ? "\(approved) approved; 1 transaction needs individual review."
                : "\(approved) approved; \(remaining) transactions need individual review."
        }
        reload()
    }

    private func reload() {
        let ctx = container.modelContainer.mainContext
        clusters = HistoricalReviewCluster.pending(in: ctx)
        loaded = true
    }
}

/// Drill-down into one review group with multi-select: a "group" the
/// matcher built is sometimes several real types mixed together, so any
/// subset can be selected and batch-edited through the type-first editor.
/// Individual rows still open the full single-transaction editor.
struct ClusterTransactionsDetail: View {
    @SwiftUI.Environment(AppContainerController.self) private var container
    let cluster: HistoricalReviewCluster
    let onChanged: () -> Void

    @State private var rows: [CachedFinancialTransaction] = []
    @State private var accountNamesByID: [String: String] = [:]
    @State private var selectedIDs: Set<String> = []
    @State private var editingSelection: HistoricalReviewCluster?

    var body: some View {
        List {
            if rows.count > 1 {
                Section {
                    Text("Tap a circle to select transactions, then Edit to reclassify just those together.")
                        .font(NwTypography.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(rows, id: \.id) { row in
                HStack(spacing: NwSpacing.md) {
                    Button {
                        toggle(row.id)
                    } label: {
                        Image(systemName: selectedIDs.contains(row.id)
                            ? "checkmark.circle.fill"
                            : "circle")
                            .font(.title3)
                            .foregroundStyle(selectedIDs.contains(row.id)
                                ? NwAppColors.positive
                                : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    NavigationLink {
                        PlaidTransactionReviewEditor(
                            transaction: row,
                            dismissAfterSave: true,
                            onSaved: {
                                reloadRows()
                                onChanged()
                            }
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.displayName)
                            Text(
                                "\(row.postedDate.formatted(date: .abbreviated, time: .omitted)) · \(accountNamesByID[row.canonicalAccountId] ?? "Account") · \(CurrencyFormatter.currency(Money(milliunits: row.amountMilliunits)))"
                            )
                            .font(NwTypography.footnote)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(cluster.displayName.isEmpty
            ? "Transactions"
            : cluster.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Edit \(selectedIDs.count)") {
                    beginEdit()
                }
                .disabled(selectedIDs.isEmpty)
            }
        }
        .sheet(item: $editingSelection) { subset in
            ClusterBatchEditSheet(cluster: subset) {
                selectedIDs = []
                reloadRows()
                onChanged()
            }
            .environment(container)
        }
        .onAppear(perform: reloadRows)
    }

    private func toggle(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func beginEdit() {
        let selected = rows.filter { selectedIDs.contains($0.id) }
        guard let sample = selected.first else { return }
        editingSelection = HistoricalReviewCluster(
            id: "subset-\(cluster.id)",
            displayName: sample.displayName.trimmed,
            payeeCanonicalId: sample.payeeCanonicalId,
            categoryName: sample.categoryName?.trimmed,
            categoryCanonicalId: sample.categoryCanonicalId,
            treatment: sample.forecastTreatment,
            transactionIDs: selected.map(\.id),
            totalMilliunits: selected.reduce(0) { $0 + $1.amountMilliunits }
        )
    }

    private func reloadRows() {
        let ctx = container.modelContainer.mainContext
        let ids = cluster.transactionIDs
        let descriptor = FetchDescriptor<CachedFinancialTransaction>(
            predicate: #Predicate {
                ids.contains($0.id) && $0.requiresReview
                    && !$0.deleted && !$0.pending
            }
        )
        rows = ((try? ctx.fetch(descriptor)) ?? [])
            .sorted { $0.postedDate > $1.postedDate }
        selectedIDs = selectedIDs.intersection(rows.map(\.id))
        let accounts = (try? ctx.fetch(
            FetchDescriptor<CachedFinancialAccount>()
        )) ?? []
        accountNamesByID = Dictionary(
            accounts.map { ($0.canonicalAccountId, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}

/// Search every imported transaction — approved or not — select the ones to
/// fix, and batch-reclassify them through the same type-first editor. The
/// repair path for classifications approved in error.
struct TransactionSearchReclassifySheet: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(AppContainerController.self) private var container

    @State private var searchText = ""
    @State private var results: [CachedFinancialTransaction] = []
    @State private var selectedIDs: Set<String> = []
    @State private var editingSelection: HistoricalReviewCluster?

    private static let resultLimit = 300

    var body: some View {
        NavigationStack {
            List {
                if results.isEmpty {
                    Text(searchText.trimmed.isEmpty
                        ? "Search by payee or description."
                        : "No matching transactions.")
                        .font(NwTypography.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Section {
                        Button(allSelected ? "Deselect All" : "Select All") {
                            selectedIDs = allSelected
                                ? []
                                : Set(results.map(\.id))
                        }
                    }
                    ForEach(results, id: \.id) { row in
                        Button {
                            toggle(row.id)
                        } label: {
                            HStack(spacing: NwSpacing.md) {
                                Image(systemName:
                                    selectedIDs.contains(row.id)
                                        ? "checkmark.circle.fill"
                                        : "circle"
                                )
                                .foregroundStyle(
                                    selectedIDs.contains(row.id)
                                        ? NwAppColors.positive
                                        : Color.secondary
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.displayName)
                                        .foregroundStyle(NwAppColors.textPrimary)
                                    Text(resultSubtitle(row))
                                        .font(NwTypography.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(CurrencyFormatter.currency(
                                    Money(milliunits: row.amountMilliunits)
                                ))
                                .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Payee or description"
            )
            .onChange(of: searchText) { runSearch() }
            .navigationTitle("Find & Reclassify")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(NwAppColors.liability)
                    }
                    .accessibilityLabel("Close")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Reclassify \(selectedIDs.count)") {
                        beginReclassify()
                    }
                    .disabled(selectedIDs.isEmpty)
                }
            }
            .sheet(item: $editingSelection) { cluster in
                ClusterBatchEditSheet(cluster: cluster) {
                    selectedIDs = []
                    runSearch()
                }
                .environment(container)
            }
        }
    }

    private var allSelected: Bool {
        !results.isEmpty && selectedIDs.count == results.count
    }

    private func toggle(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func resultSubtitle(_ row: CachedFinancialTransaction) -> String {
        var parts = [
            row.postedDate.formatted(date: .abbreviated, time: .omitted)
        ]
        if let category = row.categoryName, !category.isEmpty {
            parts.append(category)
        }
        parts.append(
            row.isSplit
                ? row.categoryDisplayName
                : row.forecastTreatment.displayName
        )
        if row.requiresReview { parts.append("Unreviewed") }
        return parts.joined(separator: " · ")
    }

    private func beginReclassify() {
        let selected = results.filter { selectedIDs.contains($0.id) }
        guard let sample = selected.first else { return }
        editingSelection = HistoricalReviewCluster(
            id: "search-selection",
            displayName: sample.displayName.trimmed,
            payeeCanonicalId: sample.payeeCanonicalId,
            categoryName: sample.categoryName?.trimmed,
            categoryCanonicalId: sample.categoryCanonicalId,
            treatment: sample.forecastTreatment,
            transactionIDs: selected.map(\.id),
            totalMilliunits: selected.reduce(0) { $0 + $1.amountMilliunits }
        )
    }

    private func runSearch() {
        let query = searchText.trimmed
        guard !query.isEmpty else {
            results = []
            selectedIDs = []
            return
        }
        var descriptor = FetchDescriptor<CachedFinancialTransaction>(
            predicate: #Predicate {
                !$0.deleted && !$0.pending
                    && ($0.displayName.localizedStandardContains(query)
                        || $0.rawDescription.localizedStandardContains(query))
            },
            sortBy: [SortDescriptor(\.postedDate, order: .reverse)]
        )
        descriptor.fetchLimit = Self.resultLimit
        results = (try? container.modelContainer.mainContext.fetch(
            descriptor
        )) ?? []
        selectedIDs = selectedIDs.intersection(results.map(\.id))
    }
}

/// Type-first reclassification of a whole cluster, then one-tap approval of
/// every member: pick what these transactions ARE, then only valid fields
/// appear, and the batch writes one authoritative decision per transaction.
struct ClusterBatchEditSheet: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(AppContainerController.self) private var container
    @Query(sort: \DurableCanonicalCategory.name)
    private var canonicalCategories: [DurableCanonicalCategory]
    @Query private var durableCategoryGroups: [DurableCategoryGroup]
    let cluster: HistoricalReviewCluster
    let onSaved: () -> Void

    @State private var displayName: String = ""
    @State private var treatment: ForecastTreatment = .ordinarySpending
    @State private var categoryName: String = ""
    @State private var categoryCanonicalId: String?
    @State private var saveError: String?
    @State private var loaded = false
    @State private var isApproving = false
    /// Built once (and on treatment/category changes), never per keystroke:
    /// recomputing hundreds of options on every Payee character makes
    /// typing lag.
    @State private var categoryOptionsCache: [PlaidCategoryOption] = []
    @State private var visibleGroupsCache: [PlaidCategoryGroup] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Applies to \(cluster.transactionCountText) in this group.")
                        .font(NwTypography.footnote)
                        .foregroundStyle(.secondary)
                    if isApproving {
                        HStack(spacing: NwSpacing.sm) {
                            ProgressView().controlSize(.small)
                            Text("Approving \(cluster.transactionCountText)…")
                                .font(NwTypography.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let saveError {
                    Section {
                        Text(saveError)
                            .font(NwTypography.footnote)
                            .foregroundStyle(NwAppColors.caution)
                    }
                }
                Section {
                    Picker("Type", selection: $treatment) {
                        ForEach(
                            TransactionType.allCases.filter {
                                !TransactionTypeRules.requiresGoal($0)
                                    && TransactionTypeRules.isValidAmountSign(
                                        $0,
                                        amountMilliunits: cluster.totalMilliunits
                                    )
                            },
                            id: \.self
                        ) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    .onChange(of: treatment) {
                        // Keep the category only when its role provably fits
                        // the new type; a stale name-only prefill would pass
                        // the enable check but fail validation on save.
                        defer { rebuildVisibleGroups() }
                        guard let id = categoryCanonicalId,
                              let selected = categoryOptionsCache.first(where: {
                                  $0.categoryID == id
                              }),
                              TransactionTypeRules.isValidCombination(
                                  treatment: treatment,
                                  categoryRole: selected.role
                              ) else {
                            categoryCanonicalId = nil
                            categoryName = ""
                            return
                        }
                    }
                } header: {
                    Text("Type")
                }
                Section("Details") {
                    TextField("Payee", text: $displayName)
                    if treatment.requiresCategory {
                        NavigationLink {
                            PlaidCategoryPicker(
                                selection: $categoryName,
                                groups: visibleGroupsCache,
                                onSelect: { option in
                                    categoryCanonicalId = option.categoryID
                                }
                            )
                        } label: {
                            LabeledContent("Category") {
                                Text(categoryName.trimmed.isEmpty
                                    ? "Select category"
                                    : categoryName)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        LabeledContent("Category") {
                            Text(noCategoryLabel(for: treatment))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Edit Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(NwAppColors.liability)
                    }
                    .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        approveAll()
                    } label: {
                        // The hard-coded green previously masked the
                        // disabled state entirely.
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(
                                canApprove && !isApproving
                                    ? NwAppColors.positive
                                    : Color.secondary.opacity(0.35)
                            )
                    }
                    .accessibilityLabel(
                        "Approve all \(cluster.transactionCountText)"
                    )
                    .disabled(!canApprove || isApproving)
                }
            }
            .interactiveDismissDisabled(isApproving)
            .onAppear(perform: load)
            .onChange(of: canonicalCategories.count) {
                rebuildOptionCaches()
            }
        }
    }

    private var canApprove: Bool {
        !displayName.trimmed.isEmpty
            && treatment != .unknown
            && !TransactionTypeRules.requiresGoal(treatment)
            && (!treatment.requiresCategory
                || !categoryName.trimmed.isEmpty)
    }

    private func rebuildOptionCaches() {
        categoryOptionsCache = categoryOptions
        rebuildVisibleGroups()
    }

    private func rebuildVisibleGroups() {
        guard let allowed = TransactionTypeRules.allowedCategoryRoles(
            for: treatment
        ) else {
            visibleGroupsCache = []
            return
        }
        let options = categoryOptionsCache.filter { option in
            guard let role = option.role else { return true }
            return allowed.contains(role)
        }
        visibleGroupsCache = PlaidCategoryGroup.makeGroups(from: options)
    }

    private var categoryOptions: [PlaidCategoryOption] {
        let roleByIdentity = Dictionary(
            durableCategoryGroups.map {
                ($0.groupIdentity, $0.reportingRole)
            },
            uniquingKeysWith: { first, _ in first }
        )
        return canonicalCategories.compactMap { category in
            guard !category.hidden,
                  !category.deletedAtSource,
                  !category.name.trimmed.isEmpty else { return nil }
            return PlaidCategoryOption(
                categoryID: category.canonicalId,
                name: category.name.trimmed,
                groupName: category.groupName.trimmed.isEmpty
                    ? "Networth Categories"
                    : category.groupName.trimmed,
                role: category.categoryGroupIdentity
                    .flatMap { roleByIdentity[$0] }
            )
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        displayName = cluster.displayName
        treatment = cluster.treatment
        categoryName = cluster.categoryName ?? ""
        categoryCanonicalId = cluster.categoryCanonicalId
        rebuildOptionCaches()
    }

    private func approveAll() {
        guard !isApproving else { return }
        saveError = nil
        isApproving = true
        Task { @MainActor in
            // Let the progress row render before the heavy classifier pass
            // occupies the main thread.
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(50))
            let approved = container.approvePlaidTransactionCluster(
                ids: cluster.transactionIDs,
                displayName: displayName.trimmed,
                payeeCanonicalId: cluster.payeeCanonicalId,
                categoryName: treatment.requiresCategory
                    ? categoryName.trimmed
                    : nil,
                categoryCanonicalId: treatment.requiresCategory
                    ? categoryCanonicalId
                    : nil,
                treatment: treatment
            )
            isApproving = false
            guard approved > 0 else {
                saveError = "The group could not be approved. Check the type and category, then try again."
                return
            }
            onSaved()
            dismiss()
        }
    }
}

private enum ExpenseFundingChoice: Hashable {
    case monthlyBudget
    case reserve(UUID)
    case goal(UUID)
}

struct PlaidTransactionReviewEditor: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(AppContainerController.self) private var container
    @Query(sort: \DurableCanonicalPayee.name)
    private var canonicalPayees: [DurableCanonicalPayee]
    @Query(sort: \DurableCanonicalCategory.name)
    private var canonicalCategories: [DurableCanonicalCategory]
    @Query private var durableCategoryGroups: [DurableCategoryGroup]
    @Query(sort: \CachedFinancialAccount.name)
    private var financialAccounts: [CachedFinancialAccount]
    @Query private var accountNicknames: [DurableAccountNickname]
    @Query(sort: \DurableGoal.name)
    private var goalRows: [DurableGoal]
    @Query(sort: \DurableSpendingSinkingFund.name)
    private var reserveFundRows: [DurableSpendingSinkingFund]
    @Query private var reserveExpenseRows:
        [DurableSpendingSinkingFundExpense]
    let transaction: CachedFinancialTransaction
    let dismissAfterSave: Bool
    let canMovePrevious: Bool
    let canMoveNext: Bool
    let onPrevious: (() -> Void)?
    let onNext: (() -> Void)?
    let onSaved: () -> Void

    @State private var displayName: String
    @State private var payeeCanonicalId: String?
    @State private var categoryName: String
    @State private var categoryCanonicalId: String?
    @State private var treatment: ForecastTreatment
    @State private var goalId: UUID?
    @State private var expenseFunding: ExpenseFundingChoice
    @State private var cachedCategoryGroups: [PlaidCategoryGroup] = []
    @State private var payeeNameByID: [String: String] = [:]
    @State private var categoryNameByID: [String: String] = [:]
    @State private var activeCategoryByID: [String: PlaidCategoryOption] = [:]
    @State private var activeCategoryByName: [String: PlaidCategoryOption] = [:]
    @State private var isSplit: Bool
    @State private var splitDrafts: [PlaidSplitDraft]
    @State private var splitSaveError: String?
    @State private var splitAmountFocusedID: UUID?

    init(
        transaction: CachedFinancialTransaction,
        dismissAfterSave: Bool = false,
        canMovePrevious: Bool = false,
        canMoveNext: Bool = false,
        onPrevious: (() -> Void)? = nil,
        onNext: (() -> Void)? = nil,
        onSaved: @escaping () -> Void
    ) {
        self.transaction = transaction
        self.dismissAfterSave = dismissAfterSave
        self.canMovePrevious = canMovePrevious
        self.canMoveNext = canMoveNext
        self.onPrevious = onPrevious
        self.onNext = onNext
        self.onSaved = onSaved
        _displayName = State(initialValue: transaction.displayName)
        _payeeCanonicalId = State(
            initialValue: transaction.payeeCanonicalId
        )
        _categoryName = State(
            initialValue: transaction.categoryName?.trimmed ?? ""
        )
        _categoryCanonicalId = State(
            initialValue: transaction.categoryCanonicalId
        )
        let storedTreatment = transaction.forecastTreatment
        _treatment = State(
            initialValue: storedTreatment == .goalSpend
                ? .ordinarySpending : storedTreatment
        )
        _goalId = State(initialValue: transaction.goalId)
        let initialExpenseFunding: ExpenseFundingChoice
        if storedTreatment == .goalSpend,
           let goalId = transaction.goalId {
            initialExpenseFunding = .goal(goalId)
        } else {
            initialExpenseFunding = .monthlyBudget
        }
        _expenseFunding = State(initialValue: initialExpenseFunding)
        let existingDrafts = transaction.subtransactions.map {
            // Show exactly what's stored. A part with no explicit choice and
            // no recognizable name stays UNSET — silently prefilling it as
            // Reimbursement converted income on the next save.
            // Before Reimbursement became its own transaction type, both
            // reimbursable expenses and incoming repayments used the retired
            // Reimbursement(s) category. Preserve that meaning when editing.
            let splitTreatment: TransactionType? =
                LegacyReimbursementRepresentation.matches($0)
                    ? .reimbursement
                    : $0.forecastTreatment == .goalSpend
                        ? .ordinarySpending
                        : $0.forecastTreatment
            let splitFunding: ExpenseFundingChoice
            if $0.forecastTreatment == .goalSpend,
               let goalId = $0.goalId {
                splitFunding = .goal(goalId)
            } else {
                splitFunding = .monthlyBudget
            }
            return PlaidSplitDraft(
                persistedID: $0.id,
                categoryID: $0.categoryId,
                categoryName: $0.categoryName ?? "",
                treatment: splitTreatment,
                goalId: $0.goalId,
                expenseFunding: splitFunding,
                amountText: CurrencyInputFormatter.text(
                    for: $0.amount.absolute
                )
            )
        }
        let initialDrafts: [PlaidSplitDraft]
        if transaction.subtransactionsDecodeFailed {
            initialDrafts = []
        } else if existingDrafts.isEmpty {
            initialDrafts = transaction.amountMilliunits > 0
                ? [
                    PlaidSplitDraft(treatment: .income),
                    PlaidSplitDraft(treatment: .reimbursement)
                ]
                : [
                    PlaidSplitDraft(treatment: .ordinarySpending),
                    PlaidSplitDraft(treatment: .ordinarySpending),
                ]
        } else {
            initialDrafts = existingDrafts
        }
        _isSplit = State(initialValue: transaction.isSplit)
        _splitDrafts = State(initialValue: initialDrafts)
        _splitSaveError = State(
            initialValue: transaction.subtransactionsDecodeFailed
                ? "The saved split data could not be read. Rebuild every split before saving."
                : nil
        )
    }

    var body: some View {
        ScrollView {
            reviewControls
        }
        .scrollDismissesKeyboard(.interactively)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NwAppColors.background.ignoresSafeArea())
        .navigationTitle(
            transaction.requiresReview
                ? "Review Transaction"
                : "Edit Transaction"
        )
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            prepareDirectoryIndexes()
            resolveDisplayedSelections()
            resolveExistingExpenseFunding()
        }
        .onChange(of: canonicalPayees.count) {
            prepareDirectoryIndexes()
        }
        .onChange(of: canonicalCategories.count) {
            prepareDirectoryIndexes()
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    saveReview()
                } label: {
                    NwIcon.confirm.image.foregroundStyle(NwAppColors.positive)
                }
                .accessibilityLabel("Save")
                // Split validation explains an invalid draft when tapped.
                // Non-split reviews retain their normal disabled state until
                // every required selection is present.
                .disabled(!isSplit && !canSaveReview)
            }
        }
        .alert(
            "Couldn't Save Transaction",
            isPresented: Binding(
                get: { splitSaveError != nil },
                set: { presented in
                    if !presented { splitSaveError = nil }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(splitSaveError ?? "Check the transaction and try again.")
        }
    }

    private var reviewControls: some View {
        VStack(alignment: .leading, spacing: NwSpacing.md) {
            if let splitSaveError {
                NwInlineNotice(
                    "Couldn't save transaction",
                    message: splitSaveError,
                    tone: .warning
                )
            }

            // The facts of the transaction under review: without date,
            // account, and amount, a "potential transfer" is undecidable.
            NwCard(style: .primary) {
                VStack(alignment: .leading, spacing: NwSpacing.xs) {
                    HStack {
                        Text(transaction.postedDate.formatted(
                            date: .abbreviated, time: .omitted
                        ))
                        .font(NwTypography.bodyEmphasis)
                        Spacer()
                        NwAmountText(
                            Money(milliunits: transaction.amountMilliunits),
                            variant: .body
                        )
                    }
                    Text(accountLabel(for: transaction))
                        .font(NwTypography.footnote)
                        .foregroundStyle(.secondary)
                    if transaction.rawDescription != transaction.displayName {
                        Text(transaction.rawDescription)
                            .font(NwTypography.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Type-first: the user confirms what the transaction IS before
            // any classification fields appear; only fields valid for the
            // chosen type are shown below.
            VStack(alignment: .leading, spacing: NwSpacing.sm) {
                reviewSectionTitle("Type")
                typeControls
            }

            VStack(alignment: .leading, spacing: NwSpacing.sm) {
                reviewSectionTitle("Contact")
                NwCard(style: .primary, padding: 0) {
                    NavigationLink {
                        CanonicalPayeePicker(
                            selection: $payeeCanonicalId,
                            displayName: $displayName,
                            payees: canonicalPayees
                        )
                    } label: {
                        LabeledContent("Contact") {
                            Text(
                                selectedPayeeName
                                    ?? "Select contact"
                            )
                            .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(NwSpacing.md)
                }
                if payeeCanonicalId == nil,
                   !displayName.trimmed.isEmpty {
                    Text("Suggested: \(displayName.trimmed). Tap Contact to select or create it.")
                        .font(NwTypography.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if !isSplit {
                VStack(alignment: .leading, spacing: NwSpacing.sm) {
                    reviewSectionTitle("Category")
                    categoryControls
                }
            }

            if showsExpenseFunding {
                expenseFundingControls
            }

            splitControls
                .frame(height: isSplit ? nil : 0, alignment: .top)
                .clipped()
                .opacity(isSplit ? 1 : 0)
                .allowsHitTesting(isSplit)
                .accessibilityHidden(!isSplit)

            if onPrevious != nil || onNext != nil {
                reviewNavigationControls
            }
        }
        .padding(.horizontal, NwSpacing.screenPadding)
        .padding(.vertical, NwSpacing.md)
    }

    private var selectedPayeeName: String? {
        guard let payeeCanonicalId else { return nil }
        if let name = payeeNameByID[payeeCanonicalId] {
            return name
        }
        let fallback = displayName.trimmed
        return fallback.isEmpty ? nil : fallback
    }

    private var selectedCategoryName: String? {
        guard let categoryCanonicalId else { return nil }
        if let name = categoryNameByID[categoryCanonicalId] {
            return name
        }
        let fallback = categoryName.trimmed
        return fallback.isEmpty ? nil : fallback
    }

    private func resolveDisplayedSelections() {
        if payeeCanonicalId == nil {
            let suggestion = displayName.trimmed
            let matches = canonicalPayees.filter {
                !$0.archived
                    && !$0.deletedAtSource
                    && (
                        FinancialTransactionSummary.namesReferToSamePayee(
                            $0.name,
                            suggestion
                        )
                        || FinancialTransactionSummary.namesReferToSamePayee(
                            $0.sourceName,
                            suggestion
                        )
                    )
            }
            let canonicalIDs = Set(matches.map(\.canonicalId))
            if canonicalIDs.count == 1,
               let match = matches.first {
                payeeCanonicalId = match.canonicalId
                displayName = match.name
            }
        }

        if selectedCategoryName == nil {
            let suggestion = categoryName.trimmed
            let matches = canonicalCategories.filter {
                !$0.deletedAtSource
                    && $0.name.localizedCaseInsensitiveCompare(suggestion)
                        == .orderedSame
            }
            let canonicalIDs = Set(matches.map(\.canonicalId))
            if canonicalIDs.count == 1,
               let match = matches.first {
                categoryCanonicalId = match.canonicalId
                categoryName = match.name
            }
        }
    }

    private var typeControls: some View {
        NwCard(style: .primary, padding: 0) {
            VStack(spacing: 0) {
                if isSplit {
                    // Per-part classifications rule a split; the stored
                    // aggregate treatment for a mixed split reads as data
                    // loss if shown here.
                    HStack {
                        Text("Type")
                        Spacer()
                        Text("Split")
                            .foregroundStyle(.secondary)
                    }
                    .padding(NwSpacing.md)
                } else {
                    typePicker
                }

                Divider()
                Toggle("Split transaction", isOn: $isSplit)
                    .onChange(of: isSplit) {
                        splitSaveError = nil
                    }
                    .padding(NwSpacing.md)
            }
        }
    }

    private var typePicker: some View {
        HStack {
            Text("Type")
            Spacer()
            Picker("", selection: $treatment) {
                ForEach(TransactionType.allCases.filter {
                    TransactionTypeRules.isValidAmountSign(
                        $0,
                        amountMilliunits: transaction.amountMilliunits
                    )
                    && $0 != .goalSpend
                }, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(NwAppColors.textSecondary)
        }
        .padding(NwSpacing.md)
        .onChange(of: treatment) {
            // A type change invalidates a selected category whose
            // group role no longer fits the new type.
            if let id = categoryCanonicalId,
               let selected = activeCategoryByID[id],
               !TransactionTypeRules.isValidCombination(
                   treatment: treatment,
                   categoryRole: selected.role
               ) {
                categoryCanonicalId = nil
                categoryName = ""
            }
            if !TransactionTypeRules.requiresGoal(treatment) {
                goalId = nil
            }
            if treatment != .ordinarySpending {
                expenseFunding = .monthlyBudget
            }
        }
    }

    private var showsExpenseFunding: Bool {
        !isSplit && transaction.amountMilliunits < 0
            && treatment == .ordinarySpending
    }

    private var expenseFundingControls: some View {
        VStack(alignment: .leading, spacing: NwSpacing.sm) {
            reviewSectionTitle("Source")
            NwCard(style: .primary, padding: 0) {
                Picker("Source", selection: $expenseFunding) {
                    Text("Monthly budget")
                        .tag(ExpenseFundingChoice.monthlyBudget)
                    if !activeReserveFunds.isEmpty {
                        Section("Reserves") {
                            ForEach(activeReserveFunds) { fund in
                                Text(fund.name)
                                    .tag(ExpenseFundingChoice.reserve(fund.id))
                            }
                        }
                    }
                    if !activeGoals.isEmpty {
                        Section("Goals") {
                            ForEach(activeGoals) { goal in
                                Text(goal.name)
                                    .tag(ExpenseFundingChoice.goal(goal.id))
                            }
                        }
                    }
                }
                .pickerStyle(.menu)
                .tint(NwAppColors.textSecondary)
                .padding(NwSpacing.md)
            }
        }
    }

    /// Only the groups whose reporting role fits the chosen type. Groups
    /// without a role (not yet assigned to a Networth-owned group) stay
    /// visible for every category-taking type.
    private var visibleCategoryGroups: [PlaidCategoryGroup] {
        categoryGroups(allowedFor: treatment)
    }

    /// Outgoing split legs are ordinary spending, whatever the parent type.
    private var splitLegCategoryGroups: [PlaidCategoryGroup] {
        categoryGroups(allowedFor: .ordinarySpending)
    }

    private func categoryGroups(
        allowedFor treatment: ForecastTreatment
    ) -> [PlaidCategoryGroup] {
        guard let allowed = TransactionTypeRules.allowedCategoryRoles(
            for: treatment
        ) else { return [] }
        return cachedCategoryGroups.compactMap { group in
            let options = group.options.filter { option in
                guard let role = option.role else { return true }
                return allowed.contains(role)
            }
            guard !options.isEmpty else { return nil }
            return PlaidCategoryGroup(
                groupName: group.groupName, options: options
            )
        }
    }

    private var categoryControls: some View {
        NwCard(style: .primary, padding: 0) {
            VStack(spacing: 0) {
                if TransactionTypeRules.requiresGoal(treatment) {
                    Picker("Goal", selection: $goalId) {
                        Text("Select goal").tag(UUID?.none)
                        ForEach(activeGoals) { goal in
                            Text(goal.name).tag(Optional(goal.id))
                        }
                    }
                    .padding(NwSpacing.md)
                } else if treatment.requiresCategory {
                    NavigationLink {
                        PlaidCategoryPicker(
                            selection: $categoryName,
                            groups: visibleCategoryGroups,
                            onSelect: { option in
                                categoryCanonicalId =
                                    option.categoryID
                            }
                        )
                    } label: {
                        LabeledContent("Category") {
                            Text(
                                selectedCategoryName
                                    ?? "Select category"
                            )
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(NwSpacing.md)
                    if selectedCategoryName == nil,
                       !categoryName.trimmed.isEmpty {
                        Text(
                            "Suggested: \(categoryName.trimmed). Tap Category to select it."
                        )
                        .font(NwTypography.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, NwSpacing.md)
                        .padding(.bottom, NwSpacing.md)
                    }
                } else {
                    LabeledContent("Category") {
                        Text(noCategoryLabel(for: treatment))
                            .foregroundStyle(.secondary)
                    }
                    .padding(NwSpacing.md)
                }
            }
        }
    }

    private var activeGoals: [DurableGoal] {
        goalRows.filter { !$0.archived && $0.completedAt == nil }
    }

    private var activeReserveFunds: [DurableSpendingSinkingFund] {
        reserveFundRows.filter { !$0.archived }
    }

    private func resolveExistingExpenseFunding() {
        if isSplit {
            resolveExistingSplitExpenseFunding()
            return
        }
        guard transaction.forecastTreatment != .goalSpend,
              treatment == .ordinarySpending,
              !isSplit else { return }
        let activeFundIDs = Set(activeReserveFunds.map(\.id))
        let matchingAssignments = reserveExpenseRows.filter { assignment in
            assignment.transactionId == transaction.id
                && assignment.subtransactionId == nil
                && assignment.active
                && activeFundIDs.contains(assignment.fundId)
        }
        guard let assignment = matchingAssignments.max(by: {
            $0.updatedAt < $1.updatedAt
        }) else { return }
        expenseFunding = .reserve(assignment.fundId)
    }

    private func resolveExistingSplitExpenseFunding() {
        let activeFundIDs = Set(activeReserveFunds.map(\.id))
        let latest = Dictionary(
            grouping: reserveExpenseRows.filter {
                $0.transactionId == transaction.id
                    && $0.subtransactionId != nil
            },
            by: { $0.subtransactionId ?? "" }
        ).compactMapValues { rows in
            rows.max(by: { $0.updatedAt < $1.updatedAt })
        }
        for index in splitDrafts.indices {
            guard splitDrafts[index].treatment == .ordinarySpending,
                  let persistedID = splitDrafts[index].persistedID,
                  let assignment = latest[persistedID],
                  assignment.active,
                  activeFundIDs.contains(assignment.fundId) else {
                continue
            }
            splitDrafts[index].expenseFunding = .reserve(assignment.fundId)
        }
    }

    private var expenseFundingIsValid: Bool {
        guard showsExpenseFunding else { return true }
        return switch expenseFunding {
        case .monthlyBudget:
            true
        case .reserve(let id):
            activeReserveFunds.contains { $0.id == id }
        case .goal(let id):
            activeGoals.contains { $0.id == id }
        }
    }

    private var reviewNavigationControls: some View {
        HStack(spacing: NwSpacing.md) {
            Button {
                onPrevious?()
            } label: {
                Label("Previous", systemImage: "chevron.left")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!canMovePrevious)

            Button {
                onNext?()
            } label: {
                Label("Next", systemImage: "chevron.right")
                    .labelStyle(.titleAndIcon)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!canMoveNext)
        }
    }

    private var splitControls: some View {
        VStack(alignment: .leading, spacing: NwSpacing.sm) {
            reviewSectionTitle("Split details")
            ForEach($splitDrafts) { $draft in
                NwCard(style: .primary, padding: 0) {
                    VStack(spacing: 0) {
                        HStack {
                            Text("Split \(splitNumber(for: draft.id))")
                                .font(NwTypography.bodyEmphasis)
                            Spacer()
                            Button {
                                deleteSplitDraft(id: draft.id)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(NwAppColors.liability)
                            }
                            .buttonStyle(.plain)
                            .disabled(splitDrafts.count <= 2)
                            .accessibilityLabel("Remove split")
                        }
                        .padding(NwSpacing.md)

                        Divider()

                        HStack {
                            Text("Type")
                            Spacer()
                            Picker(
                                "",
                                selection: $draft.treatment
                            ) {
                                Text("Select")
                                    .tag(ForecastTreatment?.none)
                                ForEach(splitTypeChoices, id: \.self) {
                                    Text($0.displayName)
                                        .tag(Optional($0))
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .tint(NwAppColors.textSecondary)
                            .onChange(of: draft.treatment) {
                                if draft.treatment != .ordinarySpending {
                                    draft.expenseFunding = .monthlyBudget
                                }
                            }
                        }
                        .padding(NwSpacing.md)

                        Divider()

                        if draft.treatment?.requiresCategory == true {
                            NavigationLink {
                                PlaidCategoryPicker(
                                    selection: $draft.categoryName,
                                    groups: splitLegCategoryGroups,
                                    onSelect: { option in
                                        draft.categoryID = option.categoryID
                                    }
                                )
                            } label: {
                                LabeledContent("Category") {
                                    Text(
                                        draft.categoryName.isEmpty
                                            ? "Select category"
                                            : draft.categoryName
                                    )
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(NwSpacing.md)
                        } else if let splitType = draft.treatment,
                                  TransactionTypeRules.requiresGoal(
                                    splitType
                                  ) {
                            Picker("Goal", selection: $draft.goalId) {
                                Text("Select goal").tag(UUID?.none)
                                ForEach(activeGoals) { goal in
                                    Text(goal.name)
                                        .tag(Optional(goal.id))
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(NwAppColors.textSecondary)
                            .padding(NwSpacing.md)
                        } else {
                            LabeledContent("Category") {
                                Text(
                                    draft.treatment.map(
                                        noCategoryLabel(for:)
                                    ) ?? "Select type"
                                )
                                .foregroundStyle(.secondary)
                            }
                            .padding(NwSpacing.md)
                        }

                        if !isIncomingSplit,
                           draft.treatment == .ordinarySpending {
                            Divider()
                            HStack {
                                Text("Source")
                                Spacer()
                                Picker(
                                    "",
                                    selection: $draft.expenseFunding
                                ) {
                                    Text("Monthly budget")
                                        .tag(ExpenseFundingChoice.monthlyBudget)
                                    if !activeReserveFunds.isEmpty {
                                        Section("Reserves") {
                                            ForEach(activeReserveFunds) { fund in
                                                Text(fund.name).tag(
                                                    ExpenseFundingChoice.reserve(
                                                        fund.id
                                                    )
                                                )
                                            }
                                        }
                                    }
                                    if !activeGoals.isEmpty {
                                        Section("Goals") {
                                            ForEach(activeGoals) { goal in
                                                Text(goal.name).tag(
                                                    ExpenseFundingChoice.goal(
                                                        goal.id
                                                    )
                                                )
                                            }
                                        }
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .tint(NwAppColors.textSecondary)
                            }
                            .padding(NwSpacing.md)
                        }

                        Divider()

                        HStack(spacing: NwSpacing.md) {
                            Text("Amount")
                            Spacer()
                            if parsedSplitAmount(draft) == nil,
                               unallocatedAmount(excluding: draft.id) > .zero {
                                Button("Use Remaining") {
                                    useRemainingAmount(for: draft.id)
                                }
                                .font(NwTypography.footnoteEm)
                                .foregroundStyle(NwAppColors.primary)
                                .accessibilityLabel(
                                    "Use remaining amount for split "
                                        + "\(splitNumber(for: draft.id))"
                                )
                            }
                            TextField("0.00", text: $draft.amountText)
                                .multilineTextAlignment(.trailing)
                                .nwCurrencyInput(
                                    text: $draft.amountText,
                                    title: "Split \(splitNumber(for: draft.id)) Amount",
                                    onFocusChange: { focused in
                                        if focused {
                                            splitAmountFocusedID = draft.id
                                        } else if splitAmountFocusedID
                                            == draft.id {
                                            splitAmountFocusedID = nil
                                        }
                                    }
                                )
                                .accessibilityLabel("Split amount")
                                .frame(width: 110)
                                .onDisappear {
                                    if splitAmountFocusedID == draft.id {
                                        splitAmountFocusedID = nil
                                    }
                                }
                        }
                        .padding(NwSpacing.md)
                    }
                }
            }

            NwCard(style: .primary, padding: 0) {
                Button {
                    splitDrafts.append(PlaidSplitDraft(
                        treatment: isIncomingSplit
                            ? .income
                            : .ordinarySpending
                    ))
                } label: {
                    Label("Add Split", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(NwAppColors.primary)
                .padding(NwSpacing.md)
            }

            if splitAmountFocusedID == nil {
                HStack {
                    Text(splitBalanceLabel)
                    Spacer()
                    NwAmountText(
                        splitRemaining.absolute,
                        variant: .body,
                        color: splitRemaining.isZero
                            ? NwAppColors.positive
                            : NwAppColors.caution
                    )
                }
                .font(NwTypography.footnote)
            }
        }
    }

    private func reviewSectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(NwTypography.caption)
            .foregroundStyle(.secondary)
    }

    private var selectedSplitTransaction: CachedFinancialTransaction {
        transaction
    }

    private var isIncomingSplit: Bool {
        selectedSplitTransaction.amountMilliunits > 0
    }

    private var splitTypeChoices: [TransactionType] {
        if isIncomingSplit {
            [.income, .refund, .reimbursement, .goalRefund]
        } else {
            [.ordinarySpending, .reimbursement]
        }
    }

    private var enteredSplitTotal: Money {
        Money(milliunits: splitDrafts.reduce(Int64(0)) { total, draft in
            total + (parsedSplitAmount(draft)?.milliunits ?? 0)
        })
    }

    private var splitRemaining: Money {
        Money(
            milliunits: Swift.abs(selectedSplitTransaction.amountMilliunits)
                - enteredSplitTotal.milliunits
        )
    }

    private func unallocatedAmount(excluding draftID: UUID) -> Money {
        let allocatedElsewhere = splitDrafts.reduce(Int64(0)) {
            total, draft in
            guard draft.id != draftID else { return total }
            return total + (parsedSplitAmount(draft)?.milliunits ?? 0)
        }
        return Money(milliunits: max(
            0,
            Swift.abs(selectedSplitTransaction.amountMilliunits)
                - allocatedElsewhere
        ))
    }

    private func useRemainingAmount(for draftID: UUID) {
        guard let index = splitDrafts.firstIndex(where: { $0.id == draftID })
        else { return }
        let remaining = unallocatedAmount(excluding: draftID)
        guard remaining > .zero else { return }
        splitDrafts[index].amountText = CurrencyInputFormatter.text(
            for: remaining
        )
    }

    private var splitBalanceLabel: String {
        if splitRemaining.isZero { return "Balanced" }
        return splitRemaining.isNegative ? "Over by" : "Remaining"
    }

    private var reviewedSplitTransactions: [SubTransactionSummary]? {
        guard splitDrafts.count >= 2 else { return nil }
        let selected = selectedSplitTransaction
        let sign: Int64 = selected.amountMilliunits < 0 ? -1 : 1
        var result: [SubTransactionSummary] = []
        for draft in splitDrafts {
            guard let amount = parsedSplitAmount(draft),
                  let treatment = draft.treatment,
                  splitTypeChoices.contains(treatment) else { return nil }
            let category: (id: String, name: String)?
            if treatment.requiresCategory {
                guard let resolved = activeCategory(for: draft) else {
                    return nil
                }
                category = resolved
            } else {
                category = nil
            }
            let storedTreatment: ForecastTreatment
            let resolvedGoalId: UUID?
            if !isIncomingSplit, treatment == .ordinarySpending {
                switch draft.expenseFunding {
                case .monthlyBudget:
                    storedTreatment = .ordinarySpending
                    resolvedGoalId = nil
                case .reserve(let id):
                    guard activeReserveFunds.contains(where: {
                        $0.id == id
                    }) else { return nil }
                    storedTreatment = .ordinarySpending
                    resolvedGoalId = nil
                case .goal(let id):
                    guard activeGoals.contains(where: {
                        $0.id == id
                    }) else { return nil }
                    storedTreatment = .goalSpend
                    resolvedGoalId = id
                }
            } else if TransactionTypeRules.requiresGoal(treatment) {
                guard let goalId = draft.goalId,
                      activeGoals.contains(where: { $0.id == goalId }) else {
                    return nil
                }
                storedTreatment = treatment
                resolvedGoalId = goalId
            } else {
                storedTreatment = treatment
                resolvedGoalId = nil
            }
            result.append(SubTransactionSummary(
                id: splitPersistedID(for: draft),
                amount: Money(milliunits: amount.milliunits * sign),
                categoryId: category?.id,
                categoryName: category?.name,
                categoryCanonicalId: category?.id,
                goalId: resolvedGoalId,
                forecastTreatment: storedTreatment,
                payeeName: nil,
                memo: nil,
                deleted: false
            ))
        }
        guard result.map(\.amount).sum().milliunits
                == selected.amountMilliunits else {
            return nil
        }
        return result
    }

    private var reviewedSplitReserveFundIDs: [String: UUID] {
        splitDrafts.reduce(into: [:]) { result, draft in
            guard draft.treatment == .ordinarySpending,
                  case .reserve(let fundID) = draft.expenseFunding else {
                return
            }
            result[splitPersistedID(for: draft)] = fundID
        }
    }

    private func splitPersistedID(for draft: PlaidSplitDraft) -> String {
        draft.persistedID
            ?? "plaid-split:\(selectedSplitTransaction.externalId):\(draft.id.uuidString)"
    }

    private var canSaveReview: Bool {
        if isSplit {
            return payeeCanonicalId != nil
                && reviewedSplitTransactions != nil
        }
        return payeeCanonicalId != nil
            && treatment != .unknown
            && expenseFundingIsValid
            && (!TransactionTypeRules.requiresGoal(treatment)
                || goalId != nil)
            && (!treatment.requiresCategory
                || (categoryCanonicalId != nil
                    && !categoryName.trimmed.isEmpty))
    }

    private func parsedSplitAmount(_ draft: PlaidSplitDraft) -> Money? {
        guard let amount = CurrencyInputFormatter.money(
            from: draft.amountText
        ), amount > .zero else {
            return nil
        }
        return amount.absolute
    }

    private func activeCategory(
        for draft: PlaidSplitDraft
    ) -> (id: String, name: String)? {
        if let categoryID = draft.categoryID,
           let exact = activeCategoryByID[categoryID] {
            return (categoryID, exact.name)
        }
        if let exact = activeCategoryByName[
            directoryLookupKey(draft.categoryName)
        ], let categoryID = exact.categoryID {
            return (categoryID, exact.name)
        }
        return nil
    }

    private func splitNumber(for id: UUID) -> Int {
        (splitDrafts.firstIndex { $0.id == id } ?? 0) + 1
    }

    private func deleteSplitDraft(id: UUID) {
        guard splitDrafts.count > 2 else { return }
        splitDrafts.removeAll { $0.id == id }
    }

    private func splitTransactionLabel(
        _ item: CachedFinancialTransaction
    ) -> String {
        let date = item.postedDate.formatted(
            date: .abbreviated,
            time: .omitted
        )
        let amount = CurrencyFormatter.currency(
            Money(milliunits: item.amountMilliunits).absolute
        )
        return "\(date) · \(accountLabel(for: item)) · \(amount)"
    }

    private func saveReview() {
        let cleanedName = displayName.trimmed.isEmpty
            ? transaction.rawDescription
            : displayName.trimmed
        splitSaveError = nil
        if isSplit {
            guard let splitTransactions = reviewedSplitTransactions else {
                splitSaveError = "Complete every split with an amount and "
                    + "type, select its category and funding when required, and "
                    + "make sure the amounts equal the transaction total."
                return
            }
            let result = container.reviewPlaidSplitTransactionResult(
                id: selectedSplitTransaction.id,
                displayName: cleanedName,
                payeeCanonicalId: payeeCanonicalId,
                subtransactions: splitTransactions,
                reserveFundIdBySubtransactionId:
                    reviewedSplitReserveFundIDs
            )
            if case .failure(let failure) = result {
                splitSaveError = failure.localizedDescription
                return
            }
        } else {
            let storedTreatment: ForecastTreatment
            let storedGoalId: UUID?
            let reserveFundId: UUID?
            if treatment == .ordinarySpending {
                switch expenseFunding {
                case .monthlyBudget:
                    storedTreatment = .ordinarySpending
                    storedGoalId = nil
                    reserveFundId = nil
                case .reserve(let id):
                    storedTreatment = .ordinarySpending
                    storedGoalId = nil
                    reserveFundId = id
                case .goal(let id):
                    storedTreatment = .goalSpend
                    storedGoalId = id
                    reserveFundId = nil
                }
            } else {
                storedTreatment = treatment
                storedGoalId = TransactionTypeRules.requiresGoal(treatment)
                    ? goalId : nil
                reserveFundId = nil
            }
            guard container.confirmPlaidTransaction(
                id: transaction.id,
                displayName: cleanedName,
                payeeCanonicalId: payeeCanonicalId,
                categoryName: treatment.requiresCategory
                    ? categoryName.trimmed
                    : nil,
                treatment: storedTreatment,
                categoryCanonicalId: treatment.requiresCategory
                    ? categoryCanonicalId
                    : nil,
                goalId: storedGoalId,
                reserveFundId: reserveFundId
            ) else {
                splitSaveError =
                    "The transaction could not be saved. Check its classification, then try again."
                return
            }
        }
        onSaved()
        if dismissAfterSave {
            dismiss()
        }
    }

    private func accountLabel(
        for item: CachedFinancialTransaction
    ) -> String {
        plaidTransactionAccountLabel(
            for: item,
            financialAccounts: financialAccounts,
            accountNicknames: accountNicknames
        )
    }

    private func prepareDirectoryIndexes() {
        payeeNameByID = Dictionary(
            canonicalPayees.map { ($0.canonicalId, $0.name) },
            uniquingKeysWith: { _, newest in newest }
        )
        categoryNameByID = Dictionary(
            canonicalCategories.map { ($0.canonicalId, $0.name) },
            uniquingKeysWith: { _, newest in newest }
        )

        let roleByIdentity = Dictionary(
            durableCategoryGroups.map { ($0.groupIdentity, $0.reportingRole) },
            uniquingKeysWith: { first, _ in first }
        )
        var options: [PlaidCategoryOption] = []
        var byID: [String: PlaidCategoryOption] = [:]
        var byName: [String: PlaidCategoryOption] = [:]
        for category in canonicalCategories {
            guard !category.hidden,
                  !category.deletedAtSource,
                  !category.name.trimmed.isEmpty else { continue }
            let option = PlaidCategoryOption(
                categoryID: category.canonicalId,
                name: category.name.trimmed,
                groupName: category.groupName.trimmed.isEmpty
                    ? "Networth Categories"
                    : category.groupName.trimmed,
                role: category.categoryGroupIdentity
                    .flatMap { roleByIdentity[$0] }
            )
            options.append(option)
            byID[category.canonicalId] = option
            let nameKey = directoryLookupKey(category.name)
            if byName[nameKey] == nil {
                byName[nameKey] = option
            }
        }

        let sameNameCategories = canonicalCategories.filter {
            !$0.deletedAtSource
                && directoryLookupKey($0.name)
                    == directoryLookupKey(categoryName)
        }
        if !sameNameCategories.isEmpty,
           sameNameCategories.allSatisfy(\.hidden),
           let hiddenCategory = sameNameCategories.first {
            options.append(
                PlaidCategoryOption(
                    categoryID: hiddenCategory.canonicalId,
                    name: categoryName,
                    groupName: "Historical Category — Hidden"
                )
            )
        }
        cachedCategoryGroups = PlaidCategoryGroup.makeGroups(from: options)
        activeCategoryByID = byID
        activeCategoryByName = byName
    }

    private func directoryLookupKey(_ value: String) -> String {
        value.trimmed.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
    }
}

private func plaidTransactionAccountLabel(
    for item: CachedFinancialTransaction,
    financialAccounts: [CachedFinancialAccount],
    accountNicknames: [DurableAccountNickname]
) -> String {
    guard let account = financialAccounts.first(where: {
        $0.canonicalAccountId == item.canonicalAccountId
    }) else {
        return "Unknown account"
    }
    let mask = account.mask.map { " •••• \($0)" } ?? ""
    let name = AccountDisplayNameResolver(nicknames: accountNicknames)
        .name(for: account)
    return "\(name)\(mask)"
}

private struct CanonicalPayeePicker: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(AppContainerController.self) private var container
    @Binding var selection: String?
    @Binding var displayName: String
    let payees: [DurableCanonicalPayee]
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    init(
        selection: Binding<String?>,
        displayName: Binding<String>,
        payees: [DurableCanonicalPayee]
    ) {
        _selection = selection
        _displayName = displayName
        self.payees = payees
        _searchText = State(initialValue: displayName.wrappedValue)
    }

    var body: some View {
        List {
            ForEach(filteredPayees) { payee in
                Button {
                    selection = payee.canonicalId
                    displayName = payee.name
                    dismiss()
                } label: {
                    HStack {
                        Text(payee.name)
                            .foregroundStyle(NwAppColors.textPrimary)
                        Spacer()
                        if selection == payee.canonicalId {
                            NwIcon.confirm.image
                                .foregroundStyle(NwAppColors.positive)
                        }
                    }
                    .contentShape(Rectangle())
                }
            }
            let cleaned = searchText.trimmed
            if !cleaned.isEmpty && !hasExactMatch {
                Section {
                    Button {
                        guard let id =
                                container.createCanonicalPayeeReturningId(
                                    name: cleaned
                                ) else {
                            return
                        }
                        selection = id
                        displayName = cleaned
                        dismiss()
                    } label: {
                        Label(
                            "Create “\(cleaned)”",
                            systemImage: "plus.circle.fill"
                        )
                    }
                }
            }
        }
        .navigationTitle("Contact")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search contacts"
        )
        .searchFocused($searchFocused)
        .task {
            await Task.yield()
            searchFocused = true
        }
    }

    private var filteredPayees: [DurableCanonicalPayee] {
        let query = searchText.trimmed
        let active = payees.filter {
            !$0.archived && !$0.deletedAtSource
        }
        guard !query.isEmpty else { return active }
        return active.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.sourceName.localizedCaseInsensitiveContains(query)
                || FinancialTransactionSummary.namesReferToSamePayee(
                    $0.name,
                    query
                )
                || FinancialTransactionSummary.namesReferToSamePayee(
                    $0.sourceName,
                    query
                )
        }
    }

    private var hasExactMatch: Bool {
        let query = FinancialTransactionSummary.normalizedDescription(
            searchText
        )
        guard !query.isEmpty else { return false }
        return payees.contains {
            !$0.archived
                && !$0.deletedAtSource
                && FinancialTransactionSummary.normalizedDescription(
                    $0.name
                ) == query
        }
    }
}

private struct PlaidCategoryOption: Identifiable {
    let categoryID: String?
    let name: String
    let groupName: String
    /// Reporting role of the category's Networth-owned group; nil until the
    /// category is assigned to a group.
    let role: CategoryReportingRole?

    init(
        categoryID: String? = nil,
        name: String,
        groupName: String,
        role: CategoryReportingRole? = nil
    ) {
        self.categoryID = categoryID
        self.name = name
        self.groupName = groupName
        self.role = role
    }

    var id: String { "\(groupName.lowercased()):\(name.lowercased())" }
}

private struct PlaidCategoryGroup: Identifiable {
    let groupName: String
    let options: [PlaidCategoryOption]

    var id: String { groupName }

    static func makeGroups(
        from options: [PlaidCategoryOption]
    ) -> [PlaidCategoryGroup] {
        Dictionary(grouping: options, by: \.groupName)
            .map { groupName, options in
                PlaidCategoryGroup(
                    groupName: groupName,
                    options: options.sorted {
                        $0.name.localizedCaseInsensitiveCompare($1.name)
                            == .orderedAscending
                    }
                )
            }
            .sorted {
                $0.groupName.localizedCaseInsensitiveCompare($1.groupName)
                    == .orderedAscending
            }
    }
}

private struct PlaidCategoryPicker: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(AppContainerController.self) private var container
    @Binding var selection: String
    let groups: [PlaidCategoryGroup]
    let onSelect: ((PlaidCategoryOption) -> Void)?
    @State private var searchText = ""
    @State private var showingNewCategory = false
    @FocusState private var searchFocused: Bool

    init(
        selection: Binding<String>,
        groups: [PlaidCategoryGroup],
        onSelect: ((PlaidCategoryOption) -> Void)? = nil
    ) {
        _selection = selection
        self.groups = groups
        self.onSelect = onSelect
    }

    var body: some View {
        List {
            ForEach(filteredGroups) { group in
                Section(group.groupName) {
                    ForEach(group.options) { option in
                        Button {
                            selection = option.name
                            onSelect?(option)
                            dismiss()
                        } label: {
                            HStack {
                                Text(option.name)
                                    .foregroundStyle(NwAppColors.textPrimary)
                                Spacer()
                                if option.name.localizedCaseInsensitiveCompare(
                                    selection
                                ) == .orderedSame {
                                    NwIcon.confirm.image
                                        .foregroundStyle(NwAppColors.positive)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                    }
                }
            }
            Section {
                Button {
                    showingNewCategory = true
                } label: {
                    Label("New Networth Category", systemImage: "plus.circle.fill")
                }
            }
        }
        .navigationTitle("Category")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search categories"
        )
        .searchFocused($searchFocused)
        .task {
            await Task.yield()
            searchFocused = true
        }
        .sheet(isPresented: $showingNewCategory) {
            PlaidNewCategorySheet { name in
                createCategory(name)
            }
        }
    }

    private func createCategory(_ name: String) {
        let cleanedName = name.trimmed
        guard !cleanedName.isEmpty,
              let canonicalId =
                container.createCanonicalCategoryReturningId(
                    name: cleanedName,
                    groupName: "Networth Categories"
                ) else {
            return
        }
        let option = PlaidCategoryOption(
            categoryID: canonicalId,
            name: cleanedName,
            groupName: "Networth Categories"
        )
        selection = cleanedName
        onSelect?(option)
        Task { @MainActor in
            await Task.yield()
            dismiss()
        }
    }

    private var filteredGroups: [PlaidCategoryGroup] {
        let query = searchText.trimmed
        guard !query.isEmpty else { return groups }
        return groups.compactMap { group in
            let matches = group.options.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || group.groupName.localizedCaseInsensitiveContains(query)
            }
            guard !matches.isEmpty else { return nil }
            return PlaidCategoryGroup(
                groupName: group.groupName,
                options: matches
            )
        }
    }

}

private struct PlaidNewCategorySheet: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let onSave: (String) -> Void
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Category Name") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .focused($nameFocused)
                        .onSubmit(save)
                }
            }
            .navigationTitle("New Category")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                nameFocused = true
            }
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
                    .disabled(name.trimmed.isEmpty)
                    .accessibilityLabel("Save category")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button {
                        nameFocused = false
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                    }
                    .accessibilityLabel("Dismiss keyboard")
                }
            }
        }
    }

    private func save() {
        let cleanedName = name.trimmed
        guard !cleanedName.isEmpty else { return }
        dismiss()
        onSave(cleanedName)
    }
}

func noCategoryLabel(for treatment: ForecastTreatment) -> String {
    switch treatment {
    case .internalTransfer, .cardPayment: "Uses the account relationship"
    default: "Not needed for this type"
    }
}

extension ForecastTreatment {
    var requiresCategory: Bool {
        TransactionTypeRules.requiresCategory(self)
    }

    var displayName: String {
        switch self {
        case .income: "Income"
        case .ordinarySpending: "Expense"
        case .internalTransfer: "Internal transfer"
        case .cardPayment: "Credit-card payment"
        case .refund: "Refund"
        case .reimbursement: "Reimbursement"
        case .goalSpend: "Goal spend"
        case .goalRefund: "Goal refund"
        case .investmentContribution: "Investment contribution"
        case .excluded: "Exclude from forecast"
        case .unknown: "Needs review"
        }
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
                        Text("Your Networth backend token.")
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
    @Query(sort: \DurableManualAsset.name) private var manualAssets: [DurableManualAsset]
    @Query private var treatments: [DurablePlaidAccountTreatment]
    @Query private var accountNicknames: [DurableAccountNickname]
    @State private var matchRequest: PlaidMatchRequest?

    var body: some View {
        NavigationStack {
            List {
                ForEach(plaidAccounts) { account in
                    Section {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(accountNameResolver.name(for: account))
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
                            if !eligibleManualAssets.isEmpty {
                                Text("Already a Manual Asset").tag(PlaidAccountTreatment.duplicateManualAsset)
                            }
                            Text("Exclude").tag(PlaidAccountTreatment.excluded)
                        }

                        if treatment(for: account).treatment == .duplicateManualAsset {
                            matchSourceRow(for: account, sourceKind: .manualAsset)
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
            .sheet(item: $matchRequest) { request in
                PlaidMatchSourceSheet(
                    title: request.sourceKind.title,
                    options: matchOptions(for: request.sourceKind),
                    selectedSourceID: plaidAccounts
                        .first(where: { $0.id == request.plaidAccountID })
                        .flatMap { treatment(for: $0).duplicateSourceId },
                    onSelect: { sourceID in
                        guard let account = plaidAccounts.first(where: {
                            $0.id == request.plaidAccountID
                        }) else { return }
                        setDuplicateSource(sourceID, for: account)
                    }
                )
            }
        }
    }

    private var accountNameResolver: AccountDisplayNameResolver {
        AccountDisplayNameResolver(nicknames: accountNicknames)
    }

    private var eligibleManualAssets: [DurableManualAsset] {
        manualAssets.filter { !$0.deleted }
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

    private func setTreatment(_ value: PlaidAccountTreatment, for account: CachedPlaidAccount) {
        let row = persistedTreatment(for: account)
        let normalizedValue: PlaidAccountTreatment = value == .duplicateYNAB
            ? .included : value
        row.treatment = normalizedValue
        row.duplicateSourceId = nil
        row.updatedAt = .now
        saveReviewChange(source: "settings.plaidTreatment")

        switch normalizedValue {
        case .duplicateYNAB:
            break
        case .duplicateManualAsset:
            matchRequest = PlaidMatchRequest(
                plaidAccountID: account.id,
                sourceKind: .manualAsset
            )
        case .pendingReview, .included, .excluded:
            break
        }
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

    private func saveReviewChange(source: String) {
        let context = container.modelContainer.mainContext
        if context.safeSave(source: source) {
            container.recordPlaidBalanceSnapshot()
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

    private func matchOptions(for sourceKind: PlaidMatchSourceKind) -> [PlaidMatchOption] {
        switch sourceKind {
        case .manualAsset:
            return eligibleManualAssets.map { source in
                let group = source.groupName?.trimmingCharacters(in: .whitespacesAndNewlines)
                let description = ["Manual Asset", source.kind.displayName, group]
                    .compactMap { value in
                        guard let value, !value.isEmpty else { return nil }
                        return value
                    }
                    .joined(separator: " · ")
                return PlaidMatchOption(
                    id: source.id.uuidString,
                    name: source.name.isEmpty ? "Untitled Asset" : source.name,
                    sourceDescription: description,
                    balance: source.currentValue
                )
            }
        }
    }

    @ViewBuilder
    private func matchSourceRow(
        for account: CachedPlaidAccount,
        sourceKind: PlaidMatchSourceKind
    ) -> some View {
        let options = matchOptions(for: sourceKind)
        let selected = options.first { $0.id == treatment(for: account).duplicateSourceId }

        Button {
            matchRequest = PlaidMatchRequest(
                plaidAccountID: account.id,
                sourceKind: sourceKind
            )
        } label: {
            HStack(spacing: NwSpacing.md) {
                Text("Matches")
                    .foregroundStyle(NwAppColors.textPrimary)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(selected?.name ?? "Select Account")
                        .foregroundStyle(selected == nil ? NwAppColors.primary : .secondary)
                    if let selected {
                        Text(selected.sourceDescription)
                            .font(NwTypography.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                NwIcon.chevron.image
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
    }
}

private enum PlaidMatchSourceKind: String {
    case manualAsset

    var title: String {
        switch self {
        case .manualAsset: return "Match Manual Asset"
        }
    }
}

private struct PlaidMatchRequest: Identifiable {
    let plaidAccountID: String
    let sourceKind: PlaidMatchSourceKind

    var id: String { "\(plaidAccountID):\(sourceKind.rawValue)" }
}

private struct PlaidMatchOption: Identifiable {
    let id: String
    let name: String
    let sourceDescription: String
    let balance: Money
}

private struct PlaidMatchSourceSheet: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss

    let title: String
    let options: [PlaidMatchOption]
    let selectedSourceID: String?
    let onSelect: (String) -> Void

    var body: some View {
        NavigationStack {
            List(options) { option in
                Button {
                    onSelect(option.id)
                    dismiss()
                } label: {
                    HStack(spacing: NwSpacing.md) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.name)
                                .font(NwTypography.bodyEmphasis)
                                .foregroundStyle(NwAppColors.textPrimary)
                            Text(option.sourceDescription)
                                .font(NwTypography.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        NwAmountText(option.balance, variant: .body, showCents: false)
                        if option.id == selectedSourceID {
                            NwIcon.confirm.image
                                .foregroundStyle(NwAppColors.positive)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle(title)
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
        }
        .presentationDetents([.medium, .large])
    }
}

private struct ClaudeDataAccessView: View {
    @SwiftUI.Environment(AppContainerController.self)
    private var container
    @Query private var settingsList: [DurableUserSettings]

    @State private var showingEnableConsent = false
    @State private var showingDisableConfirm = false
    @State private var isWorking = false
    @State private var connectCode: ClaudeConnectCodeResponseDTO?
    @State private var errorMessage: String?

    private var settings: DurableUserSettings? {
        settingsList.first
    }

    private var isEnabled: Bool {
        settings?.claudeDataSyncEnabled == true
    }

    var body: some View {
        Form {
            Section {
                Toggle("Sync financial data", isOn: enabledBinding)
                    .disabled(
                        isWorking || !container.hasPlaidBackendToken
                    )

                if !container.hasPlaidBackendToken {
                    NwInlineNotice(
                        "Backend access required",
                        message: "Save the private backend token before enabling Claude.ai access.",
                        tone: .warning
                    )
                }
            } header: {
                Text("Data Access")
            } footer: {
                Text("Uploads account labels and balances, effective manual assets, holdings, confirmed transactions, and net-worth history. Credentials, account numbers, provider IDs, notes, raw bank descriptions, and unreviewed transactions stay out.")
            }

            if isEnabled {
                Section("Sync Status") {
                    syncStatus

                    Button {
                        Task {
                            await container.syncClaudeDataNow()
                        }
                    } label: {
                        Label("Sync Now", systemImage: NwIcon.sync.rawValue)
                    }
                    .disabled(isWorking || isSyncing)
                }

                Section {
                    Text("Add this custom connector URL in Claude.ai:")
                        .font(NwTypography.footnote)
                        .foregroundStyle(.secondary)
                    Text("https://networth-plaid.bluelava.me/mcp")
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)

                    Button {
                        generateConnectCode()
                    } label: {
                        HStack {
                            Text("Generate Connect Code")
                            if isWorking {
                                Spacer()
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .disabled(isWorking || isSyncing)

                    if let connectCode {
                        Text(connectCode.code)
                            .font(.system(.title2, design: .monospaced))
                            .textSelection(.enabled)
                        Text(
                            "Enter on the authorization page. Expires \(connectCode.expiresAt.formatted(.relative(presentation: .named)))."
                        )
                        .font(NwTypography.footnote)
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Connect Claude")
                } footer: {
                    Text("Claude receives read-only access. Turning sync off deletes the server copy and revokes every Claude.ai grant.")
                }
            }

            if let errorMessage {
                Section {
                    NwInlineNotice(
                        "Claude.ai access error",
                        message: errorMessage,
                        tone: .warning
                    )
                }
            }
        }
        .navigationTitle("Claude.ai Access")
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            "Sync Financial Data to Claude.ai?",
            isPresented: $showingEnableConsent
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Allow") {
                setEnabled(true)
            }
        } message: {
            Text("Networth will upload an encrypted read-only financial copy to your private Cloudflare Worker. Claude.ai may receive account labels, balances, holdings, confirmed transaction dates and amounts, contacts, categories, and net-worth history when you ask it questions.")
        }
        .alert(
            "Turn Off Claude.ai Access?",
            isPresented: $showingDisableConfirm
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Turn Off", role: .destructive) {
                setEnabled(false)
            }
        } message: {
            Text("Deletes the financial copy from the Worker and revokes all Claude.ai access tokens. Data on this iPhone and in CloudKit stays intact.")
        }
    }

    @ViewBuilder
    private var syncStatus: some View {
        switch container.claudeDataSyncCoordinator.phase {
        case .idle:
            if let lastSyncedAt = settings?.claudeDataLastSyncedAt {
                LabeledContent(
                    "Last synced",
                    value: lastSyncedAt.formatted(
                        date: .abbreviated,
                        time: .shortened
                    )
                )
            } else {
                Text("Waiting for the first sync.")
                    .foregroundStyle(.secondary)
            }
        case .syncing:
            HStack(spacing: NwSpacing.sm) {
                ProgressView().controlSize(.small)
                Text("Updating Claude.ai copy")
                    .foregroundStyle(.secondary)
            }
        case .success(let date):
            LabeledContent(
                "Last synced",
                value: date.formatted(
                    date: .abbreviated,
                    time: .shortened
                )
            )
        case .error(let message):
            Text(message)
                .foregroundStyle(NwAppColors.liability)
        }
    }

    private var isSyncing: Bool {
        if case .syncing = container.claudeDataSyncCoordinator.phase {
            return true
        }
        return false
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { isEnabled },
            set: { enabled in
                if enabled {
                    showingEnableConsent = true
                } else {
                    showingDisableConfirm = true
                }
            }
        )
    }

    private func setEnabled(_ enabled: Bool) {
        isWorking = true
        errorMessage = nil
        connectCode = nil
        Task { @MainActor in
            defer { isWorking = false }
            do {
                try await container.setClaudeDataSyncEnabled(enabled)
            } catch {
                errorMessage =
                    (error as? LocalizedError)?.errorDescription
                    ?? "The request could not be completed."
            }
        }
    }

    private func generateConnectCode() {
        isWorking = true
        errorMessage = nil
        connectCode = nil
        Task { @MainActor in
            defer { isWorking = false }
            do {
                connectCode =
                    try await container.generateClaudeConnectCode()
            } catch {
                errorMessage =
                    (error as? LocalizedError)?.errorDescription
                    ?? "A connect code could not be generated."
            }
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Create/edit a recurring expectation. Created manually or prefilled from a
/// recent approved transaction; the amount is the user's expected value.
struct RecurringExpectationForm: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(AppContainerController.self) private var container
    @Query(sort: \CachedFinancialAccount.name)
    private var financialAccounts: [CachedFinancialAccount]
    @Query(sort: \DurableCanonicalPayee.name)
    private var canonicalPayees: [DurableCanonicalPayee]
    @Query(sort: \DurableCanonicalCategory.name)
    private var canonicalCategories: [DurableCanonicalCategory]
    @Query private var durableCategoryGroups: [DurableCategoryGroup]
    let expectation: DurableRecurringExpectation?

    @State private var payeeName = ""
    @State private var payeeCanonicalId: String?
    @State private var treatment: ForecastTreatment = .ordinarySpending
    @State private var accountId = ""
    @State private var destinationId = ""
    @State private var categoryName = ""
    @State private var categoryCanonicalId: String?
    @State private var cadence: CommitmentCadence = .monthly
    // Projection events start tomorrow; a today-dated expectation would be
    // silently absent until its next cycle.
    @State private var nextDate = Calendar.current.date(
        byAdding: .day, value: 1, to: .now
    ) ?? .now
    @State private var amountText = ""
    @State private var saveError: String?
    @State private var recent: [CachedFinancialTransaction] = []
    @State private var loaded = false

    private var openAccounts: [CachedFinancialAccount] {
        financialAccounts.filter { !$0.deleted }
    }

    /// Bills may live on cash accounts or cards (an expected card purchase
    /// raises that card's projected statement); everything else is cash.
    private var sourceAccounts: [CachedFinancialAccount] {
        switch treatment {
        case .ordinarySpending:
            openAccounts.filter {
                $0.type == .checking || $0.type == .savings
                    || $0.type == .cash || $0.type == .creditCard
            }
        default:
            openAccounts.filter {
                $0.type == .checking || $0.type == .savings
                    || $0.type == .cash
            }
        }
    }

    /// Card destinations are card payments, which the statement/autopay
    /// forecaster owns — never a transfer expectation.
    private var transferDestinationAccounts: [CachedFinancialAccount] {
        openAccounts.filter {
            $0.canonicalAccountId != accountId && $0.type != .creditCard
        }
    }

    private var recurringCategoryGroups: [PlaidCategoryGroup] {
        let roleByIdentity = Dictionary(
            durableCategoryGroups.map {
                ($0.groupIdentity, $0.reportingRole)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let allowedRoles = TransactionTypeRules.allowedCategoryRoles(
            for: .ordinarySpending
        ) ?? []
        let options = canonicalCategories.compactMap {
            category -> PlaidCategoryOption? in
            guard !category.hidden,
                  !category.deletedAtSource,
                  !category.name.trimmed.isEmpty else { return nil }
            let role = category.categoryGroupIdentity.flatMap {
                roleByIdentity[$0]
            }
            guard role.map(allowedRoles.contains) ?? true else { return nil }
            return PlaidCategoryOption(
                categoryID: category.canonicalId,
                name: category.name.trimmed,
                groupName: category.groupName.trimmed.isEmpty
                    ? "Networth Categories"
                    : category.groupName.trimmed,
                role: role
            )
        }
        return PlaidCategoryGroup.makeGroups(from: options)
    }

    var body: some View {
        NavigationStack {
            Form {
                if expectation == nil, !recent.isEmpty {
                    Section {
                        Menu("Start from a recent transaction") {
                            ForEach(recent, id: \.id) { row in
                                Button(recentLabel(row)) { prefill(from: row) }
                            }
                        }
                    }
                }

                Section("Details") {
                    NavigationLink {
                        CanonicalPayeePicker(
                            selection: $payeeCanonicalId,
                            displayName: $payeeName,
                            payees: canonicalPayees
                        )
                    } label: {
                        LabeledContent("Payee") {
                            Text(
                                payeeName.trimmed.isEmpty
                                    ? "Select payee"
                                    : payeeName
                            )
                            .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    Picker("Type", selection: $treatment) {
                        ForEach(
                            RecurringExpectations.allowedTreatments,
                            id: \.self
                        ) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    .onChange(of: treatment) {
                        // A type change invalidates an account the new type
                        // cannot execute (e.g. income on a card).
                        if !sourceAccounts.contains(where: {
                            $0.canonicalAccountId == accountId
                        }) {
                            accountId = ""
                        }
                        if treatment != .internalTransfer {
                            destinationId = ""
                        }
                    }
                    Picker("Account", selection: $accountId) {
                        Text("Select account").tag("")
                        ForEach(sourceAccounts, id: \.canonicalAccountId) {
                            Text($0.name).tag($0.canonicalAccountId)
                        }
                    }
                    if treatment == .internalTransfer {
                        Picker("To account", selection: $destinationId) {
                            Text("Outside accounts").tag("")
                            ForEach(
                                transferDestinationAccounts,
                                id: \.canonicalAccountId
                            ) {
                                Text($0.name).tag($0.canonicalAccountId)
                            }
                        }
                    }
                    if treatment == .ordinarySpending {
                        NavigationLink {
                            PlaidCategoryPicker(
                                selection: $categoryName,
                                groups: recurringCategoryGroups,
                                onSelect: { option in
                                    categoryCanonicalId = option.categoryID
                                }
                            )
                        } label: {
                            LabeledContent("Category") {
                                Text(
                                    categoryName.trimmed.isEmpty
                                        ? "Optional"
                                        : categoryName
                                )
                                .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        if !categoryName.trimmed.isEmpty {
                            Button {
                                categoryName = ""
                                categoryCanonicalId = nil
                            } label: {
                                Label(
                                    "Remove category",
                                    systemImage: "xmark.circle"
                                )
                            }
                            .foregroundStyle(NwAppColors.liability)
                        }
                    }
                }

                Section("Schedule") {
                    Picker("Repeats", selection: $cadence) {
                        ForEach(CommitmentCadence.allCases) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    DatePicker(
                        "Next date",
                        selection: $nextDate,
                        displayedComponents: .date
                    )
                }

                Section("Expected Amount") {
                    TextField("Amount", text: $amountText)
                        .nwCurrencyInput(text: $amountText)
                }

                if let saveError {
                    Section {
                        Text(saveError)
                            .font(NwTypography.footnote)
                            .foregroundStyle(NwAppColors.caution)
                    }
                }
            }
            .navigationTitle(
                expectation == nil ? "New Recurring" : "Edit Recurring"
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(NwAppColors.liability)
                    }
                    .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(NwAppColors.positive)
                    }
                    .accessibilityLabel("Save")
                    .disabled(!canSave)
                }
            }
            .onAppear(perform: load)
        }
    }

    private var parsedAmount: Money? {
        CurrencyInputFormatter.money(from: amountText)
    }

    private var canSave: Bool {
        !payeeName.trimmed.isEmpty
            && sourceAccounts.contains {
                $0.canonicalAccountId == accountId
            }
            && (parsedAmount.map { $0 > .zero } ?? false)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let expectation {
            payeeName = expectation.payeeName
            payeeCanonicalId = expectation.payeeCanonicalId
            treatment = expectation.forecastTreatment
            accountId = expectation.accountCanonicalId
            destinationId = expectation.destinationAccountCanonicalId ?? ""
            categoryName = expectation.categoryName ?? ""
            categoryCanonicalId = expectation.categoryCanonicalId
            cadence = expectation.cadence
            nextDate = expectation.nextOccurrenceAt
            amountText = CurrencyInputFormatter.text(
                for: expectation.amount.absolute
            )
        } else {
            var descriptor = FetchDescriptor<CachedFinancialTransaction>(
                predicate: #Predicate {
                    !$0.deleted && !$0.pending && !$0.requiresReview
                },
                sortBy: [SortDescriptor(\.postedDate, order: .reverse)]
            )
            descriptor.fetchLimit = 15
            recent = (try? container.modelContainer.mainContext.fetch(
                descriptor
            )) ?? []
        }
    }

    private func recentLabel(_ row: CachedFinancialTransaction) -> String {
        let amount = CurrencyFormatter.currency(
            Money(milliunits: row.amountMilliunits).absolute,
            showCents: false
        )
        return "\(row.displayName) · \(amount)"
    }

    private func prefill(from row: CachedFinancialTransaction) {
        payeeName = row.displayName
        if RecurringExpectations.allowedTreatments
            .contains(row.forecastTreatment) {
            treatment = row.forecastTreatment
        }
        accountId = row.canonicalAccountId
        categoryName = row.categoryName ?? ""
        categoryCanonicalId = row.categoryCanonicalId
        amountText = CurrencyInputFormatter.text(
            for: Money(milliunits: row.amountMilliunits).absolute
        )
        nextDate = Calendar.current.date(
            byAdding: .month, value: 1, to: row.postedDate
        ) ?? .now
        payeeCanonicalId = row.payeeCanonicalId
    }

    private func save() {
        guard let amount = parsedAmount else { return }
        // Direction follows the type: income flows in, everything else out.
        let signed = treatment == .income ? amount : -amount
        let ctx = container.modelContainer.mainContext
        let target = expectation ?? {
            let created = DurableRecurringExpectation()
            ctx.insert(created)
            return created
        }()
        target.payeeName = payeeName.trimmed
        target.payeeCanonicalId = payeeCanonicalId
        target.forecastTreatment = treatment
        target.accountCanonicalId = accountId
        target.destinationAccountCanonicalId =
            treatment == .internalTransfer && !destinationId.isEmpty
                ? destinationId
                : nil
        target.categoryName = treatment != .ordinarySpending
            || categoryName.trimmed.isEmpty
            ? nil
            : categoryName.trimmed
        target.categoryCanonicalId = treatment != .ordinarySpending
            || categoryName.trimmed.isEmpty
            ? nil
            : categoryCanonicalId
        target.cadence = cadence
        target.nextOccurrenceAt = Calendar.current.startOfDay(for: nextDate)
        target.amountMilliunits = signed.milliunits
        target.updatedAt = .now
        guard ctx.safeSave(source: "settings.saveExpectation") else {
            saveError = "Saving failed. Your entries are still here — try again."
            return
        }
        dismiss()
    }
}
