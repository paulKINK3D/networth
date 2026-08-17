import SwiftUI
import SwiftData
import NetworthCore

/// Identity for a configurable card: canonical Plaid account id after the
/// clean start, legacy YNAB account id before it.
struct CardSettingsTarget: Identifiable, Hashable {
    let id: String
    let name: String
    let isCanonical: Bool
}

struct CardSettingsForm: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppContainerController.self) private var container
    let target: CardSettingsTarget
    @Query(sort: \CachedAccount.name) private var accounts: [CachedAccount]
    @Query(sort: \CachedFinancialAccount.name)
    private var financialAccounts: [CachedFinancialAccount]
    @Query private var canonicalBindings: [DurableCanonicalAccountBinding]
    @Query private var accountNicknames: [DurableAccountNickname]

    @State private var cycleDay: Int = 1
    @State private var dueDay: Int = 1
    @State private var paymentAccountId: String = ""
    @State private var saveError: String?

    var body: some View {
        NwModalLayout(
            title: target.name,
            onClose: { dismiss() },
            onConfirm: save
        ) {
            VStack(alignment: .leading, spacing: NwSpacing.lg) {
                if let saveError {
                    NwInlineNotice("Couldn't save", message: saveError, tone: .warning)
                }
                VStack(alignment: .leading, spacing: NwSpacing.sm) {
                    Text("Statement closes on day").font(NwTypography.caption)
                        .foregroundStyle(.secondary).textCase(.uppercase)
                    Picker("Close day", selection: $cycleDay) {
                        ForEach(1...31, id: \.self) { day in
                            Text("\(day)").tag(day)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(maxHeight: 160)
                }

                VStack(alignment: .leading, spacing: NwSpacing.sm) {
                    Text("Autopay debits on day").font(NwTypography.caption)
                        .foregroundStyle(.secondary).textCase(.uppercase)
                    Picker("Due day", selection: $dueDay) {
                        ForEach(1...31, id: \.self) { day in
                            Text("\(day)").tag(day)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(maxHeight: 160)
                    Text("Days 29-31 use the month's final day when needed.")
                        .font(NwTypography.footnote)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: NwSpacing.sm) {
                    Text("Payment account").font(NwTypography.caption)
                        .foregroundStyle(.secondary).textCase(.uppercase)
                    Picker("Payment account", selection: $paymentAccountId) {
                        Text("Select account").tag("")
                        ForEach(cashAccountOptions, id: \.id) { option in
                            Text(option.name).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(NwAppColors.textPrimary)
                }
            }
        }
        .onAppear(perform: prefill)
    }

    private func prefill() {
        if let existing = existingSetting() {
            cycleDay = existing.statementCycleDay
            if existing.paymentDueDay >= 1 {
                dueDay = existing.paymentDueDay
            }
            paymentAccountId = target.isCanonical
                ? (existing.canonicalPaymentAccountId
                    ?? existing.paymentAccountId ?? "")
                : (existing.paymentAccountId ?? "")
        }
    }

    private func existingSetting() -> DurableCardSettings? {
        let rows = (try? container.modelContainer.mainContext.fetch(
            FetchDescriptor<DurableCardSettings>()
        )) ?? []
        return rows.first {
            ($0.canonicalAccountId ?? $0.accountId) == target.id
                || $0.accountId == target.id
        }
    }

    private func save() {
        guard !paymentAccountId.isEmpty else {
            saveError = "Choose the cash account that pays this card."
            return
        }
        let ctx = container.modelContainer.mainContext
        let isNew: Bool
        let setting: DurableCardSettings
        if let existing = existingSetting() {
            setting = existing
            isNew = false
        } else {
            setting = DurableCardSettings(accountId: target.id)
            ctx.insert(setting)
            isNew = true
        }
        // Snapshot prior values so a save failure rolls back only this form's
        // mutation. Context-wide rollback would also discard any unrelated
        // pending changes in the shared main context.
        let priorCycleDay = setting.statementCycleDay
        let priorDueDay = setting.paymentDueDay
        let priorPaymentAccountId = setting.paymentAccountId
        let priorCanonicalAccountId = setting.canonicalAccountId
        let priorCanonicalPaymentAccountId = setting.canonicalPaymentAccountId
        setting.statementCycleDay = max(1, min(31, cycleDay))
        setting.paymentDueDay = max(1, min(31, dueDay))
        setting.paymentAccountId = paymentAccountId
        if target.isCanonical {
            // Post-clean-start path: card and payment ids are canonical.
            setting.canonicalAccountId = target.id
            setting.canonicalPaymentAccountId = paymentAccountId
        } else {
            setting.canonicalAccountId = canonicalBindings.first {
                $0.ynabAccountId == target.id
            }?.canonicalAccountId
            setting.canonicalPaymentAccountId = canonicalBindings.first {
                $0.ynabAccountId == paymentAccountId
            }?.canonicalAccountId
        }
        let succeeded = ctx.safeSave(source: "cardSettings.save")
        guard succeeded else {
            if isNew {
                ctx.delete(setting)
            } else {
                setting.statementCycleDay = priorCycleDay
                setting.paymentDueDay = priorDueDay
                setting.paymentAccountId = priorPaymentAccountId
                setting.canonicalAccountId = priorCanonicalAccountId
                setting.canonicalPaymentAccountId = priorCanonicalPaymentAccountId
            }
            saveError = "Saving card settings failed. Your selection is still here — try again."
            return
        }
        dismiss()
    }

    private var cashAccountOptions: [(id: String, name: String)] {
        if target.isCanonical {
            return financialAccounts
                .filter { !$0.deleted && $0.type.isCashLike }
                .map {
                    (
                        $0.canonicalAccountId,
                        AccountDisplayNameResolver(
                            nicknames: accountNicknames
                        ).name(for: $0)
                    )
                }
        }
        return accounts
            .filter { !$0.deleted && !$0.closed && $0.kind.isCashLike }
            .map { ($0.id, $0.name) }
    }
}
