import SwiftUI
import SwiftData
import NetworthCore

/// Multi-select sheet for categories the user wants kept *out* of the
/// variable-spend daily drain (e.g. investments, transfers to savings).
struct ExcludedCategoriesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppContainerController.self) private var container
    @Query(sort: \CachedCategory.groupName) private var categories: [CachedCategory]
    @Query private var exclusions: [DurableExcludedSpendCategory]

    private var excludedIds: Set<String> {
        Set(exclusions.map { $0.categoryId })
    }

    private func displayGroupName(_ raw: String) -> String {
        raw == "Internal Master Category" ? "Income" : raw
    }

    private var grouped: [(group: String, items: [CachedCategory])] {
        let visible = categories.filter { !$0.deleted && !$0.name.isEmpty }
        return Dictionary(grouping: visible, by: { displayGroupName($0.groupName) })
            .map { (group: $0.key, items: $0.value.sorted { $0.name < $1.name }) }
            .sorted { lhs, rhs in
                // Active groups first, "hidden master" groups at the bottom.
                let lhsHasVisible = lhs.items.contains { !$0.hidden }
                let rhsHasVisible = rhs.items.contains { !$0.hidden }
                if lhsHasVisible != rhsHasVisible { return lhsHasVisible }
                return lhs.group < rhs.group
            }
    }

    var body: some View {
        NwModalLayout(
            title: "Excluded Categories",
            onClose: { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: NwSpacing.md) {
                NwInlineNotice(
                    "Skipped from variable-spend",
                    message: "Tap a category to keep it out of the daily-drain calculation. Useful for transfers to investments or other non-spending categories.",
                    tone: .info
                )

                if grouped.isEmpty {
                    NwEmptyState(
                        title: "No categories yet",
                        message: "Run Sync Now from Settings — categories arrive with your YNAB sync.",
                        icon: .empty
                    )
                } else {
                    ForEach(grouped, id: \.group) { group in
                        VStack(alignment: .leading, spacing: NwSpacing.sm) {
                            Text(group.group.uppercased())
                                .font(NwTypography.caption)
                                .foregroundStyle(.secondary)
                            VStack(spacing: 0) {
                                ForEach(group.items) { category in
                                    row(category)
                                    if category.id != group.items.last?.id {
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

    private func row(_ category: CachedCategory) -> some View {
        let isExcluded = excludedIds.contains(category.id)
        return Button {
            toggle(category)
        } label: {
            HStack(spacing: NwSpacing.sm) {
                Image(systemName: isExcluded ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isExcluded ? NwAppColors.primary : NwAppColors.strokeSubtle)
                Text(category.name)
                    .font(NwTypography.body)
                    .foregroundStyle(category.hidden ? NwAppColors.textSecondary : NwAppColors.textPrimary)
                if category.hidden {
                    Text("hidden")
                        .font(NwTypography.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, NwSpacing.xs)
                        .padding(.vertical, 1)
                        .background(NwAppColors.strokeSubtle)
                        .clipShape(Capsule())
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.vertical, NwSpacing.xs)
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ category: CachedCategory) {
        let ctx = container.modelContainer.mainContext
        let cid = category.id
        let descriptor = FetchDescriptor<DurableExcludedSpendCategory>(
            predicate: #Predicate { $0.categoryId == cid }
        )
        if let existing = try? ctx.fetch(descriptor).first {
            ctx.delete(existing)
        } else {
            ctx.insert(DurableExcludedSpendCategory(
                categoryId: category.id,
                categoryName: category.name,
                groupName: category.groupName
            ))
        }
        ctx.safeSave(source: "exclusions.toggle")
    }
}
