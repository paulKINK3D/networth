import SwiftUI
import NetworthCore

/// Multi-select picker for the Spending-by-Category filter.
/// Bound to the same `selection: Set<String>?` shape used by CategorySpendingCard
/// (nil = all-selected sentinel; empty set = nothing selected).
struct CategoryFilterSheet: View {
    typealias Row = CategorySpendingRow

    @Environment(\.dismiss) private var dismiss
    let rows: [Row]
    @Binding var selection: Set<String>?

    private var grouped: [(group: String, items: [Row])] {
        Dictionary(grouping: rows, by: { $0.groupName })
            .map { (group: $0.key, items: $0.value.sorted { $0.total.milliunits > $1.total.milliunits }) }
            .sorted { $0.group < $1.group }
    }

    private var allSelected: Bool { selection == nil }

    var body: some View {
        NwModalLayout(
            title: "Filter Categories",
            onClose: { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: NwSpacing.lg) {
                HStack(spacing: NwSpacing.sm) {
                    Button(allSelected ? "Deselect all" : "Select all") {
                        if allSelected {
                            selection = []
                        } else {
                            selection = nil
                        }
                    }
                    .buttonStyle(NwSecondaryButtonStyle())
                }

                ForEach(grouped, id: \.group) { group in
                    VStack(alignment: .leading, spacing: NwSpacing.sm) {
                        Text(group.group.uppercased())
                            .font(NwTypography.caption)
                            .foregroundStyle(.secondary)
                        VStack(spacing: 0) {
                            ForEach(group.items) { row in
                                rowView(row)
                                if row.id != group.items.last?.id {
                                    Divider()
                                }
                            }
                        }
                        .padding(NwSpacing.md)
                        .background(NwAppColors.cardSurface)
                        .clipShape(RoundedRectangle(cornerRadius: NwCornerRadius.md, style: .continuous))
                    }
                }
            }
        }
    }

    private func rowView(_ row: Row) -> some View {
        let isSelected = selection?.contains(row.id) ?? true
        return Button {
            toggle(row.id)
        } label: {
            HStack(spacing: NwSpacing.sm) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? NwAppColors.primary : NwAppColors.strokeSubtle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name)
                        .font(NwTypography.body)
                        .foregroundStyle(NwAppColors.textPrimary)
                    Text("\(row.txnCount) txns")
                        .font(NwTypography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(CurrencyFormatter.compact(row.total))
                    .font(NwTypography.footnoteEm)
                    .foregroundStyle(NwAppColors.liability)
            }
            .contentShape(Rectangle())
            .padding(.vertical, NwSpacing.xs)
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ id: String) {
        // Collapse the nil-all sentinel into an explicit set first so the user
        // can toggle individual rows off.
        var current: Set<String>
        if let sel = selection {
            current = sel
        } else {
            current = Set(rows.map { $0.id })
        }
        if current.contains(id) {
            current.remove(id)
        } else {
            current.insert(id)
        }
        selection = current
    }
}
