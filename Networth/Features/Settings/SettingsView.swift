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

    @State private var showingTokenSheet = false
    @State private var showingAssetForm: DurableManualAsset? = nil
    @State private var showingNewAsset = false
    @State private var showingCardSheet: CachedAccount? = nil
    @State private var showingExclusionsSheet = false
    @State private var showingForceResyncConfirm = false

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
                                Text(container.hasYNABToken ? "YNAB Token Saved" : "Add YNAB Token")
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
                } header: {
                    Text("Authentication")
                } footer: {
                    Text("Token stored in iCloud-synced Keychain. Read-only access — Networth never writes to YNAB.")
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
                } header: {
                    Text("Sync")
                } footer: {
                    Text("Force Full Resync wipes every daily net-worth snapshot from iCloud and rebuilds the chart from scratch by re-fetching YNAB. Use it when the chart is showing accounts you've since closed, or when balances look stale. Manual assets and your settings are preserved.")
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
                    HStack {
                        Text("Variable-spend lookback")
                        Spacer()
                        Stepper("\(settings?.spendingLookbackDays ?? 60) days",
                                value: lookbackBinding, in: 14...180, step: 7)
                            .labelsHidden()
                        Text("\(settings?.spendingLookbackDays ?? 60)d")
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        showingExclusionsSheet = true
                    } label: {
                        HStack {
                            Label {
                                Text("Excluded Categories")
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
                    HStack {
                        Text("Cash-dip threshold")
                        Spacer()
                        Text(CurrencyFormatter.compact(Money(milliunits: settings?.dipThresholdMilliunits ?? 500_000)))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Projections")
                } footer: {
                    Text("Variable-spend uses the last N days of cash-account debits (minus scheduled outflows and excluded categories) to project a daily drain across the horizon.")
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
                                Text(setting.map { "Closes day \($0.statementCycleDay)" } ?? "Set close day")
                                    .foregroundStyle(.secondary)
                                    .font(NwTypography.footnote)
                            }
                        }
                    }
                } header: {
                    Text("Credit Card Statements")
                } footer: {
                    Text("Set each card's statement close day so projections know when to roll over.")
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
                } header: {
                    Text("Help")
                } footer: {
                    Text("Replay the quick tour any time.")
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

    private var lookbackBinding: Binding<Int> {
        Binding(
            get: { settings?.spendingLookbackDays ?? 60 },
            set: { newValue in
                let ctx = container.modelContainer.mainContext
                let current: DurableUserSettings
                if let existing = settings {
                    current = existing
                } else {
                    current = DurableUserSettings()
                    ctx.insert(current)
                }
                current.spendingLookbackDays = newValue
                ctx.safeSave(source: "settings.lookback")
            }
        )
    }

    private var excludedCount: Int { exclusions.count }

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
