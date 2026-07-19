import SwiftUI
import SwiftData
import NetworthCore

struct CardSettingsForm: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppContainerController.self) private var container
    let account: CachedAccount
    @Query(sort: \CachedAccount.name) private var accounts: [CachedAccount]

    @State private var cycleDay: Int = 1
    @State private var dueDay: Int = 1
    @State private var paymentAccountId: String = ""
    @State private var saveError: String?

    var body: some View {
        NwModalLayout(
            title: account.name,
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
                        ForEach(cashAccounts) { cashAccount in
                            Text(cashAccount.name).tag(cashAccount.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(NwAppColors.textPrimary)
                    Text("Account used for full-statement autopay.")
                        .font(NwTypography.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear(perform: prefill)
    }

    private func prefill() {
        let targetId = account.id
        let descriptor = FetchDescriptor<DurableCardSettings>(
            predicate: #Predicate { $0.accountId == targetId }
        )
        if let existing = try? container.modelContainer.mainContext.fetch(descriptor).first {
            cycleDay = existing.statementCycleDay
            if existing.paymentDueDay >= 1 {
                dueDay = existing.paymentDueDay
            }
            paymentAccountId = existing.paymentAccountId ?? ""
        }
    }

    private func save() {
        guard !paymentAccountId.isEmpty else {
            saveError = "Choose the cash account that pays this card."
            return
        }
        let ctx = container.modelContainer.mainContext
        let targetId = account.id
        let descriptor = FetchDescriptor<DurableCardSettings>(
            predicate: #Predicate { $0.accountId == targetId }
        )
        let isNew: Bool
        let setting: DurableCardSettings
        if let existing = try? ctx.fetch(descriptor).first {
            setting = existing
            isNew = false
        } else {
            setting = DurableCardSettings(accountId: account.id)
            ctx.insert(setting)
            isNew = true
        }
        // Snapshot prior values so a save failure rolls back only this form's
        // mutation. Context-wide rollback would also discard any unrelated
        // pending changes in the shared main context.
        let priorCycleDay = setting.statementCycleDay
        let priorDueDay = setting.paymentDueDay
        let priorPaymentAccountId = setting.paymentAccountId
        setting.statementCycleDay = max(1, min(31, cycleDay))
        setting.paymentDueDay = max(1, min(31, dueDay))
        setting.paymentAccountId = paymentAccountId
        let succeeded = ctx.safeSave(source: "cardSettings.save")
        guard succeeded else {
            if isNew {
                ctx.delete(setting)
            } else {
                setting.statementCycleDay = priorCycleDay
                setting.paymentDueDay = priorDueDay
                setting.paymentAccountId = priorPaymentAccountId
            }
            saveError = "Saving card settings failed. Your selection is still here — try again."
            return
        }
        dismiss()
    }

    private var cashAccounts: [CachedAccount] {
        accounts.filter { !$0.deleted && !$0.closed && $0.kind.isCashLike }
    }
}
