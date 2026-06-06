import SwiftUI
import SwiftData
import NetworthCore

/// Drill-down sheet shown when a row in Spending-by-Category is tapped.
/// Lists every transaction in that category over the lookback window.
struct CategoryTransactionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppContainerController.self) private var container

    let categoryId: String
    let categoryName: String
    let lookbackDays: Int

    @Query private var transactions: [CachedTransaction]
    @Query(sort: \CachedAccount.name) private var accounts: [CachedAccount]

    init(categoryId: String, categoryName: String, lookbackDays: Int) {
        self.categoryId = categoryId
        self.categoryName = categoryName
        self.lookbackDays = lookbackDays

        let cutoff = Calendar(identifier: .gregorian)
            .date(byAdding: .day, value: -lookbackDays, to: .now) ?? .distantPast

        // We can't predicate against JSON-encoded sub categories at the store
        // layer, so pull the window and filter in code. Include positive
        // amounts too — refunds and inflows posted into a category should
        // appear alongside outflows in the drill-down.
        _transactions = Query(
            filter: #Predicate<CachedTransaction> {
                $0.date >= cutoff && !$0.deleted
            },
            sort: [SortDescriptor(\CachedTransaction.date, order: .reverse)]
        )
    }

    /// One row in the drill-down. For a non-split txn, this is just the txn.
    /// For a split, `displayAmount` is the matching sub's contribution.
    /// Signed: positive = inflow (refund / income), negative = outflow (spend).
    private struct Entry: Identifiable {
        let id: String
        let txn: CachedTransaction
        let displayAmount: Money  // signed
        let isSplitLeg: Bool
    }

    private var accountNameById: [String: String] {
        Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.name) })
    }

    /// Active accounts whose transactions we surface in the drill-down.
    private var activeSpendAccountIds: Set<String> {
        Set(accounts.filter { !$0.deleted && !$0.closed && $0.kind.isSpendAccount }.map { $0.id })
    }

    /// Wider set including closed accounts — used to detect internal transfers
    /// even when the destination is a YNAB-hidden (closed) account.
    private var internalAccountIds: Set<String> {
        Set(accounts.filter { !$0.deleted && $0.kind.isSpendAccount }.map { $0.id })
    }

    private var entries: [Entry] {
        let activeIds = activeSpendAccountIds
        let allInternalIds = internalAccountIds
        let target = categoryId
        var out: [Entry] = []
        for txn in transactions {
            guard activeIds.contains(txn.accountId) else { continue }
            let subs = txn.subtransactions
            if !subs.isEmpty {
                // Surface each matching sub as its own row (positive AND negative).
                for sub in subs where !sub.deleted {
                    let subCid = sub.categoryId ?? "uncategorized"
                    guard subCid == target else { continue }
                    guard sub.amount.milliunits != 0 else { continue }
                    if let xfer = sub.transferAccountId, allInternalIds.contains(xfer) { continue }
                    out.append(Entry(
                        id: "\(txn.id)#\(sub.id)",
                        txn: txn,
                        displayAmount: sub.amount,
                        isSplitLeg: true
                    ))
                }
            } else {
                let cid = txn.categoryId ?? "uncategorized"
                guard cid == target else { continue }
                guard txn.amountMilliunits != 0 else { continue }
                if let xfer = txn.transferAccountId, allInternalIds.contains(xfer) { continue }
                out.append(Entry(
                    id: txn.id,
                    txn: txn,
                    displayAmount: Money(milliunits: txn.amountMilliunits),
                    isSplitLeg: false
                ))
            }
        }
        return out
    }

    /// Signed total — outflows (negative) plus inflows (positive). When the
    /// category has more refunds than spend, this comes out positive.
    private var total: Money {
        Money(milliunits: entries.reduce(0) { $0 + $1.displayAmount.milliunits })
    }

    var body: some View {
        NwModalLayout(
            title: categoryName,
            onClose: { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: NwSpacing.lg) {
                NwCard(style: .primary) {
                    VStack(alignment: .leading, spacing: NwSpacing.xs) {
                        Text("Last \(lookbackDays) days · net")
                            .font(NwTypography.caption)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        // Negative net = net spend. Positive net = net refund.
                        let netColor: Color = total.milliunits > 0
                            ? NwAppColors.positive
                            : NwAppColors.liability
                        NwAmountText(total.absolute, variant: .large, color: netColor)
                        Text("\(entries.count) transactions")
                            .font(NwTypography.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                let list = entries
                if list.isEmpty {
                    NwEmptyState(
                        title: "No transactions",
                        message: "Nothing posted in this category during the window.",
                        icon: .empty
                    )
                } else {
                    NwCard(style: .primary) {
                        VStack(spacing: 0) {
                            ForEach(list) { entry in
                                row(entry)
                                if entry.id != list.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func row(_ entry: Entry) -> some View {
        let txn = entry.txn
        let isInflow = entry.displayAmount.milliunits > 0
        let displayColor: Color = isInflow ? NwAppColors.positive : NwAppColors.liability
        let prefix = isInflow ? "+" : "−"
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: NwSpacing.xs) {
                    Text(txn.payeeName ?? "Unknown payee")
                        .font(NwTypography.body)
                        .foregroundStyle(NwAppColors.textPrimary)
                        .lineLimit(1)
                    if entry.isSplitLeg {
                        Text("split")
                            .font(NwTypography.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, NwSpacing.xs)
                            .padding(.vertical, 1)
                            .background(NwAppColors.strokeSubtle)
                            .clipShape(Capsule())
                    }
                }
                HStack(spacing: NwSpacing.xs) {
                    Text(DateDisplay.shortDate(txn.date))
                    Text("·")
                    Text(accountNameById[txn.accountId] ?? "Unknown account")
                        .lineLimit(1)
                }
                .font(NwTypography.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(prefix)\(CurrencyFormatter.compact(entry.displayAmount.absolute))")
                .font(NwTypography.bodyEmphasis)
                .foregroundStyle(displayColor)
        }
        .padding(.vertical, NwSpacing.sm)
    }
}
