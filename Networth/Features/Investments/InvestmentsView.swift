import SwiftUI
import SwiftData
import NetworthCore

/// Aggregated view of investment holdings — YNAB-tracked investment-type
/// accounts plus manual assets of brokerage / retirement / crypto kinds.
struct InvestmentsView: View {
    @Environment(AppContainerController.self) private var container
    @Query(sort: \CachedAccount.name) private var accounts: [CachedAccount]
    @Query(sort: \DurableManualAsset.name) private var manualAssets: [DurableManualAsset]

    private static let investmentManualKinds: Set<ManualAssetKind> = [.brokerage, .retirement, .crypto]

    private var ynabInvestments: [CachedAccount] {
        accounts.filter { !$0.deleted && !$0.closed && $0.kind == .investment }
    }

    private var manualInvestments: [DurableManualAsset] {
        manualAssets.filter { !$0.deleted && Self.investmentManualKinds.contains($0.kind) }
    }

    private var totalValueMU: Int64 {
        let ynabTotal = ynabInvestments.reduce(Int64(0)) { $0 + $1.balanceMilliunits }
        let manualTotal = manualInvestments.reduce(Int64(0)) { $0 + $1.currentValueMilliunits }
        return ynabTotal + manualTotal
    }

    private var totalValue: Money { Money(milliunits: totalValueMU) }

    private var isEmpty: Bool {
        ynabInvestments.isEmpty && manualInvestments.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NwSpacing.lg) {
                    if isEmpty {
                        NwEmptyState(
                            title: "No investments yet",
                            message: "Add an investment account in YNAB or add a brokerage / retirement / crypto manual asset in Settings.",
                            icon: .investment
                        )
                        .frame(minHeight: 320)
                    } else {
                        heroCard
                        if !ynabInvestments.isEmpty {
                            NwSectionHeader("YNAB Investments")
                            ForEach(ynabInvestments) { account in
                                investmentRow(name: account.name,
                                              subtitle: "Investment",
                                              icon: .investment,
                                              value: Money(milliunits: account.balanceMilliunits))
                            }
                        }
                        if !manualInvestments.isEmpty {
                            NwSectionHeader("Manual Investments")
                            ForEach(manualInvestments) { asset in
                                investmentRow(name: asset.name,
                                              subtitle: asset.kind.displayName,
                                              icon: icon(for: asset.kind),
                                              value: asset.currentValue)
                            }
                        }
                    }
                }
                .padding(.horizontal, NwSpacing.screenPadding)
                .padding(.vertical, NwSpacing.lg)
            }
            .background(NwAppColors.background.ignoresSafeArea())
            .navigationTitle("Investments")
        }
    }

    private var heroCard: some View {
        NwCard(style: .primary) {
            VStack(alignment: .leading, spacing: NwSpacing.xs) {
                Text("Total Investments")
                    .font(NwTypography.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                NwAmountText(totalValue, variant: .hero, showCents: false)
                Text("\(ynabInvestments.count + manualInvestments.count) holding\(ynabInvestments.count + manualInvestments.count == 1 ? "" : "s")")
                    .font(NwTypography.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func investmentRow(name: String, subtitle: String, icon: NwIcon, value: Money) -> some View {
        NwCard(style: .primary) {
            HStack(spacing: NwSpacing.md) {
                icon.image
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(NwAppColors.accent)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(NwTypography.body)
                        .foregroundStyle(NwAppColors.textPrimary)
                    Text(subtitle).font(NwTypography.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                NwAmountText(value, variant: .body)
            }
        }
    }

    private func icon(for kind: ManualAssetKind) -> NwIcon {
        switch kind {
        case .brokerage:   return .brokerage
        case .retirement:  return .retirement
        case .crypto:      return .crypto
        case .realEstate:  return .realEstate
        case .vehicle:     return .vehicle
        case .collectible: return .collectible
        case .other:       return .otherAsset
        }
    }
}
