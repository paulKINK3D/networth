import SwiftUI
import SwiftData
import NetworthCore

struct SettingsView: View {
    @Environment(AppContainerController.self) private var container
    @Query private var settingsList: [DurableUserSettings]
    @Query(sort: \DurableManualAsset.name) private var manualAssets: [DurableManualAsset]
    @Query(sort: \CachedAccount.name) private var accounts: [CachedAccount]
    @Query(sort: \DurableCardSettings.accountId) private var cardSettings: [DurableCardSettings]

    @State private var showingTokenSheet = false
    @State private var showingAssetForm: DurableManualAsset? = nil
    @State private var showingNewAsset = false
    @State private var showingCardSheet: CachedAccount? = nil

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

                Section("Sync") {
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
                    Button("Sync Now") {
                        Task { await container.syncNow() }
                    }
                    .disabled(!container.hasYNABToken)
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
                        Text("Cash-dip threshold")
                        Spacer()
                        Text(CurrencyFormatter.compact(Money(milliunits: settings?.dipThresholdMilliunits ?? 500_000)))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Projections")
                } footer: {
                    Text("Heads-up alerts fire when your forecast cash position dips below the threshold.")
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
