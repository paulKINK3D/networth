import SwiftUI
import SwiftData
import NetworthCore

/// Manages category and one-off transaction exclusions from expected spending.
struct ExcludedCategoriesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppContainerController.self) private var container
    @Query(sort: \DurableCanonicalCategory.groupName)
    private var categories: [DurableCanonicalCategory]
    @Query private var exclusions: [DurableExcludedSpendCategory]
    @Query(sort: \DurableExcludedSpendTransaction.transactionDate, order: .reverse)
    private var transactionExclusions: [DurableExcludedSpendTransaction]

    private var excludedIds: Set<String> {
        Set(exclusions.map { $0.categoryId })
    }

    private func displayGroupName(_ raw: String) -> String {
        raw == "Internal Master Category" ? "Income" : raw
    }

    private var grouped: [(group: String, items: [DurableCanonicalCategory])] {
        let visible = categories.filter { !$0.deletedAtSource && !$0.name.isEmpty }
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
            title: "Spending Exclusions",
            onClose: { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: NwSpacing.md) {
                Text("Tap to exclude. Restore one-time exclusions below.")
                    .font(NwTypography.footnote)
                    .foregroundStyle(.secondary)

                if !transactionExclusions.isEmpty {
                    VStack(alignment: .leading, spacing: NwSpacing.sm) {
                        Text("ONE-TIME TRANSACTIONS")
                            .font(NwTypography.caption)
                            .foregroundStyle(.secondary)
                        VStack(spacing: 0) {
                            ForEach(transactionExclusions) { exclusion in
                                Button {
                                    restore(exclusion)
                                } label: {
                                    HStack(spacing: NwSpacing.sm) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(NwAppColors.primary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(exclusion.payeeName.isEmpty ? "Transaction" : exclusion.payeeName)
                                                .font(NwTypography.body)
                                                .foregroundStyle(NwAppColors.textPrimary)
                                            Text(exclusion.transactionDate, format: .dateTime.month(.abbreviated).day().year())
                                                .font(NwTypography.footnote)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        NwAmountText(
                                            Money(milliunits: exclusion.amountMilliunits),
                                            variant: .body,
                                            color: NwAppColors.textSecondary
                                        )
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.vertical, NwSpacing.xs)
                                }
                                .buttonStyle(.plain)
                                if exclusion.id != transactionExclusions.last?.id { Divider() }
                            }
                        }
                        .padding(NwSpacing.md)
                        .background(NwAppColors.cardSurface)
                        .clipShape(RoundedRectangle(cornerRadius: NwCornerRadius.md, style: .continuous))
                    }
                }

                if grouped.isEmpty {
                    NwEmptyState(
                        title: "No categories yet",
                        message: "No category-level exclusions are available.",
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

    private func row(_ category: DurableCanonicalCategory) -> some View {
        let isExcluded = excludedIds.contains(category.canonicalId)
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

    private func toggle(_ category: DurableCanonicalCategory) {
        let ctx = container.modelContainer.mainContext
        let cid = category.canonicalId
        let descriptor = FetchDescriptor<DurableExcludedSpendCategory>(
            predicate: #Predicate { $0.categoryId == cid }
        )
        if let existing = try? ctx.fetch(descriptor).first {
            ctx.delete(existing)
        } else {
            ctx.insert(DurableExcludedSpendCategory(
                categoryId: category.canonicalId,
                categoryName: category.name,
                groupName: category.groupName
            ))
        }
        ctx.safeSave(source: "exclusions.toggle")
    }

    private func restore(_ exclusion: DurableExcludedSpendTransaction) {
        let ctx = container.modelContainer.mainContext
        ctx.delete(exclusion)
        if !ctx.safeSave(source: "exclusions.restoreTransaction") {
            ctx.rollback()
        }
    }
}
