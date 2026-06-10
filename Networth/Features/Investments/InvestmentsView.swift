import SwiftUI
import SwiftData
import NetworthCore

/// Aggregated view of investment holdings — YNAB-tracked investment-type
/// accounts plus manual assets of brokerage / retirement / crypto kinds.
struct InvestmentsView: View {
    @Environment(AppContainerController.self) private var container
    @Query(sort: \CachedAccount.name) private var accounts: [CachedAccount]
    @Query(sort: \DurableManualAsset.name) private var manualAssets: [DurableManualAsset]

    private static let investmentManualKinds: Set<ManualAssetKind> = [.brokerage, .retirement, .crypto, .other]
    /// Display order of the per-kind sub-sections inside the Investments tab.
    /// Empty sub-sections are hidden so the page stays tight when a user only
    /// has, say, brokerage and retirement.
    private static let kindOrder: [ManualAssetKind] = [.brokerage, .retirement, .crypto, .other]

    private func kindLabel(_ kind: ManualAssetKind) -> String {
        switch kind {
        case .brokerage:  return "Brokerage"
        case .retirement: return "Retirement"
        case .crypto:     return "Crypto"
        case .other:      return "Other"
        default:          return kind.displayName
        }
    }

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
                            ForEach(manualKindSections, id: \.kind) { section in
                                manualKindSection(section)
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

    private struct ManualGroup: Identifiable {
        /// Stable id used by ForEach.
        let title: String
        var id: String { title }
        /// What to render in the header. `nil` for the ungrouped section so it
        /// blends with the surrounding "Manual Investments" header.
        let displayHeader: String?
        let assets: [DurableManualAsset]
        var total: Money {
            Money(milliunits: assets.reduce(Int64(0)) { $0 + $1.currentValueMilliunits })
        }
    }

    private struct ManualKindSection {
        let kind: ManualAssetKind
        let groups: [ManualGroup]
        var total: Money {
            Money(milliunits: groups.reduce(Int64(0)) { sum, g in sum + g.total.milliunits })
        }
    }

    private var manualKindSections: [ManualKindSection] {
        Self.kindOrder.compactMap { kind in
            let assets = manualInvestments.filter { $0.kind == kind }
            guard !assets.isEmpty else { return nil }
            return ManualKindSection(kind: kind, groups: makeGroups(from: assets))
        }
    }

    private func makeGroups(from assets: [DurableManualAsset]) -> [ManualGroup] {
        let buckets = Dictionary(grouping: assets) {
            ($0.groupName ?? "").trimmingCharacters(in: .whitespaces)
        }
        return buckets.map { key, list in
            let sorted = list.sorted { $0.name.lowercased() < $1.name.lowercased() }
            return ManualGroup(
                title: key.isEmpty ? "" : key,
                displayHeader: key.isEmpty ? nil : key,
                assets: sorted
            )
        }
        .sorted { lhs, rhs in
            // Ungrouped goes last; named groups alphabetically.
            if lhs.title.isEmpty { return false }
            if rhs.title.isEmpty { return true }
            return lhs.title.lowercased() < rhs.title.lowercased()
        }
    }

    @ViewBuilder
    private func manualKindSection(_ section: ManualKindSection) -> some View {
        VStack(spacing: NwSpacing.sm) {
            HStack {
                Text(kindLabel(section.kind))
                    .font(NwTypography.headline)
                    .foregroundStyle(NwAppColors.textPrimary)
                Spacer()
                Text(CurrencyFormatter.compact(section.total))
                    .font(NwTypography.headline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, NwSpacing.sm)
            ForEach(section.groups) { group in
                manualGroupSection(group)
                    .padding(.leading, NwSpacing.md)
            }
        }
    }

    @ViewBuilder
    private func manualGroupSection(_ group: ManualGroup) -> some View {
        let isGrouped = group.displayHeader != nil
        VStack(spacing: NwSpacing.sm) {
            if let title = group.displayHeader {
                HStack {
                    Text(title)
                        .font(NwTypography.footnoteEm)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Spacer()
                    Text(CurrencyFormatter.compact(group.total))
                        .font(NwTypography.footnoteEm)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, NwSpacing.sm)
            }
            ForEach(group.assets) { asset in
                investmentRow(name: asset.name,
                              subtitle: asset.kind.displayName,
                              icon: icon(for: asset.kind),
                              value: asset.currentValue)
                    .padding(.leading, isGrouped ? NwSpacing.md : 0)
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
