import SwiftUI
import SwiftData
import NetworthCore

struct CardSettingsForm: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppContainerController.self) private var container
    let account: CachedAccount

    @State private var cycleDay: Int = 1
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
                NwInlineNotice(
                    "Statement cycle day",
                    message: "Enter the day of the month your statement closes. We use this for projections.",
                    tone: .info
                )

                VStack(alignment: .leading, spacing: NwSpacing.sm) {
                    Text("Statement closes on day").font(NwTypography.caption)
                        .foregroundStyle(.secondary).textCase(.uppercase)
                    Picker("Day", selection: $cycleDay) {
                        ForEach(1...31, id: \.self) { day in
                            Text("\(day)").tag(day)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(maxHeight: 160)
                    Text("For cards that close on day 29-31, short months fall back to the last day automatically.")
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
        }
    }

    private func save() {
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
        // Snapshot prior day so a save failure rolls back only this form's
        // mutation. Context-wide rollback would also discard any unrelated
        // pending changes in the shared main context.
        let priorDay = setting.statementCycleDay
        setting.statementCycleDay = max(1, min(31, cycleDay))
        let succeeded = ctx.safeSave(source: "cardSettings.save")
        guard succeeded else {
            if isNew {
                ctx.delete(setting)
            } else {
                setting.statementCycleDay = priorDay
            }
            saveError = "Saving card settings failed. Your selection is still here — try again."
            return
        }
        dismiss()
    }
}
