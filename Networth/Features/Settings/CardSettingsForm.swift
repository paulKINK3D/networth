import SwiftUI
import SwiftData
import NetworthCore

struct CardSettingsForm: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppContainerController.self) private var container
    let account: CachedAccount

    @State private var cycleDay: Int = 1
    @State private var minPercent: Double = 2
    @State private var minFloor: String = "25"

    var body: some View {
        NwModalLayout(
            title: account.name,
            onClose: { dismiss() },
            onConfirm: save
        ) {
            VStack(alignment: .leading, spacing: NwSpacing.lg) {
                NwInlineNotice(
                    "Statement cycle day",
                    message: "Enter the day of the month your statement closes. We use this for projections.",
                    tone: .info
                )

                VStack(alignment: .leading, spacing: NwSpacing.sm) {
                    Text("Statement closes on day").font(NwTypography.caption)
                        .foregroundStyle(.secondary).textCase(.uppercase)
                    Stepper(value: $cycleDay, in: 1...28) {
                        Text("Day \(cycleDay)")
                            .font(NwTypography.bodyEmphasis)
                    }
                }

                VStack(alignment: .leading, spacing: NwSpacing.sm) {
                    Text("Minimum payment %").font(NwTypography.caption)
                        .foregroundStyle(.secondary).textCase(.uppercase)
                    HStack {
                        Slider(value: $minPercent, in: 1...10, step: 0.5)
                        Text("\(minPercent, specifier: "%.1f")%")
                            .font(NwTypography.bodyEmphasis)
                            .frame(width: 60, alignment: .trailing)
                    }
                }

                VStack(alignment: .leading, spacing: NwSpacing.sm) {
                    Text("Minimum payment floor").font(NwTypography.caption)
                        .foregroundStyle(.secondary).textCase(.uppercase)
                    TextField("25", text: $minFloor)
                        .keyboardType(.decimalPad)
                        .padding(NwSpacing.md)
                        .background(NwAppColors.cardSurface)
                        .clipShape(RoundedRectangle(cornerRadius: NwCornerRadius.md, style: .continuous))
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
            minPercent = Double(existing.minimumPaymentPercentNumerator) / Double(existing.minimumPaymentPercentDenominator) * 100
            minFloor = String(describing: existing.minimumPaymentFloor.decimalValue)
        }
    }

    private func save() {
        let ctx = container.modelContainer.mainContext
        let targetId = account.id
        let descriptor = FetchDescriptor<DurableCardSettings>(
            predicate: #Predicate { $0.accountId == targetId }
        )
        let setting: DurableCardSettings
        if let existing = try? ctx.fetch(descriptor).first {
            setting = existing
        } else {
            setting = DurableCardSettings(accountId: account.id)
            ctx.insert(setting)
        }
        setting.statementCycleDay = max(1, min(28, cycleDay))
        setting.minimumPaymentPercentNumerator = Int((minPercent * 10).rounded())
        setting.minimumPaymentPercentDenominator = 1_000
        let floorDecimal = Decimal(string: minFloor.trimmingCharacters(in: .whitespaces)) ?? Decimal(25)
        setting.minimumPaymentFloorMilliunits = Money.dollars(floorDecimal).milliunits
        ctx.safeSave(source: "cardSettings.save")
        dismiss()
    }
}
