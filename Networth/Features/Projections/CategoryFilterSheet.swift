import SwiftUI
import SwiftData
import NetworthCore

/// Multi-select picker for the Spending-by-Category filter.
///
/// Reads/writes `DurableExcludedSpendCategory` directly so this sheet shares a
/// single source of truth with Settings → Excluded Categories. Toggling a row
/// here also affects the cash-position spend math, since the cash projector
/// already consumes the same exclusion list.
///
/// Categories already excluded are hidden from this sheet — re-inclusion is
/// handled by Settings → Excluded Categories. This sheet's only action is to
/// remove additional categories from the projections breakdown.
struct CategoryFilterSheet: View {
    typealias Row = CategorySpendingRow

    @Environment(\.dismiss) private var dismiss
    @Environment(AppContainerController.self) private var container
    @Query private var exclusions: [DurableExcludedSpendCategory]
    let rows: [Row]

    private var excludedIds: Set<String> {
        Set(exclusions.map { $0.categoryId })
    }

    private var visibleRows: [Row] {
        rows.filter { !excludedIds.contains($0.id) }
    }

    private var grouped: [(group: String, items: [Row])] {
        Dictionary(grouping: visibleRows, by: { $0.groupName })
            .map { (group: $0.key, items: $0.value.sorted { $0.total.milliunits > $1.total.milliunits }) }
            .sorted { $0.group < $1.group }
    }

    var body: some View {
        NwModalLayout(
            title: "Filter Categories",
            onClose: { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: NwSpacing.lg) {
                NwInlineNotice(
                    "Tap a category to exclude it",
                    message: "Excluded categories vanish from the breakdown and stop counting toward the daily-drain math. Re-include them from Settings → Excluded Categories.",
                    tone: .info
                )

                if !visibleRows.isEmpty {
                    HStack(spacing: NwSpacing.sm) {
                        Button("Exclude all visible") {
                            excludeAllVisible()
                        }
                        .buttonStyle(NwSecondaryButtonStyle())
                    }
                }

                if visibleRows.isEmpty {
                    NwEmptyState(
                        title: "Nothing left to filter",
                        message: "Every category in this window has been excluded. Re-include from Settings → Excluded Categories.",
                        icon: .empty
                    )
                } else {
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
    }

    private func rowView(_ row: Row) -> some View {
        Button {
            exclude(row)
        } label: {
            HStack(spacing: NwSpacing.sm) {
                Image(systemName: "checkmark.square.fill")
                    .foregroundStyle(NwAppColors.primary)
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

    private func exclude(_ row: Row) {
        let ctx = container.modelContainer.mainContext
        ctx.insert(DurableExcludedSpendCategory(
            categoryId: row.id,
            categoryName: row.name,
            groupName: row.groupName
        ))
        ctx.safeSave(source: "projections.filter.exclude")
    }

    /// Add a `DurableExcludedSpendCategory` for every visible row that isn't
    /// already excluded. Categories outside `rows` (no activity in the current
    /// window) are left alone.
    private func excludeAllVisible() {
        let ctx = container.modelContainer.mainContext
        for row in visibleRows {
            ctx.insert(DurableExcludedSpendCategory(
                categoryId: row.id,
                categoryName: row.name,
                groupName: row.groupName
            ))
        }
        ctx.safeSave(source: "projections.filter.bulkExclude")
    }
}
