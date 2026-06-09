import SwiftUI
import SwiftData
import NetworthCore

/// Lets the user opt closed YNAB accounts back into the trend chart's
/// historical reconstruction. Default for any closed account is "off" —
/// stays hidden from the chart, matching the original behavior. Flip "on"
/// when the closed account's YNAB transaction history is the real source of
/// truth for what your net worth used to look like (brokerage staging
/// accounts, drained T-Bills, etc).
///
/// Each toggle writes a `DurableIncludedClosedAccount` row (or deletes it)
/// and resets `historyBackfillVersion` to 0 so the next sync rebuilds the
/// chart with the new account set.
struct IncludedClosedAccountsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppContainerController.self) private var container
    @Query(sort: \CachedAccount.name) private var allAccounts: [CachedAccount]
    @Query private var inclusions: [DurableIncludedClosedAccount]
    @Query private var settingsList: [DurableUserSettings]

    private var closedAccounts: [CachedAccount] {
        allAccounts.filter { !$0.deleted && $0.closed }
    }

    private var includedIds: Set<String> {
        Set(inclusions.map { $0.accountId })
    }

    var body: some View {
        NwModalLayout(
            title: "Include Closed Accounts",
            onClose: { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: NwSpacing.lg) {
                NwInlineNotice(
                    "Bring closed-account history into the chart",
                    message: "Toggle on the closed accounts whose YNAB transaction history reflects real net worth — brokerage staging accounts, drained savings buckets, etc. Toggling triggers a chart rebuild on the next sync.",
                    tone: .info
                )

                if closedAccounts.isEmpty {
                    NwEmptyState(
                        title: "No closed accounts",
                        message: "Nothing to include yet. Close an account in YNAB and sync.",
                        icon: .empty
                    )
                } else {
                    VStack(spacing: 0) {
                        ForEach(closedAccounts) { account in
                            row(account)
                            if account.id != closedAccounts.last?.id {
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

    private func row(_ account: CachedAccount) -> some View {
        let isOn = includedIds.contains(account.id)
        return HStack(spacing: NwSpacing.sm) {
            NwIcon.forAccountKind(account.typeRaw).image
                .foregroundStyle(NwAppColors.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .font(NwTypography.body)
                    .foregroundStyle(NwAppColors.textPrimary)
                Text(kindLabel(account.kind))
                    .font(NwTypography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { isOn },
                set: { newValue in toggle(account, on: newValue) }
            ))
            .labelsHidden()
        }
        .contentShape(Rectangle())
        .padding(.vertical, NwSpacing.xs)
    }

    private func toggle(_ account: CachedAccount, on: Bool) {
        let ctx = container.modelContainer.mainContext
        let cid = account.id
        let descriptor = FetchDescriptor<DurableIncludedClosedAccount>(
            predicate: #Predicate { $0.accountId == cid }
        )
        let existing = (try? ctx.fetch(descriptor).first)
        if on, existing == nil {
            ctx.insert(DurableIncludedClosedAccount(accountId: account.id))
        } else if !on, let row = existing {
            ctx.delete(row)
        }
        // Force a backfill re-run so the chart picks up the new account set.
        if let settings = settingsList.first {
            settings.historyBackfillVersion = 0
        } else {
            let new = DurableUserSettings()
            ctx.insert(new)
            new.historyBackfillVersion = 0
        }
        ctx.safeSave(source: "settings.includedClosedAccounts.toggle")
    }

    private func kindLabel(_ kind: AccountKind) -> String {
        switch kind {
        case .checking:        return "Checking (closed)"
        case .savings:         return "Savings (closed)"
        case .cash:            return "Cash (closed)"
        case .creditCard:      return "Credit Card (closed)"
        case .lineOfCredit:    return "Line of Credit (closed)"
        case .otherAsset:      return "Other Asset (closed)"
        case .otherLiability:  return "Other Liability (closed)"
        case .mortgage:        return "Mortgage (closed)"
        case .autoLoan:        return "Auto Loan (closed)"
        case .studentLoan:     return "Student Loan (closed)"
        case .personalLoan:    return "Personal Loan (closed)"
        case .medicalDebt:     return "Medical Debt (closed)"
        case .otherDebt:       return "Other Debt (closed)"
        case .investment:      return "Investment (closed)"
        case .unknown:         return "Closed account"
        }
    }
}
