import SwiftUI
import SwiftData
import NetworthCore

/// Quick update flow for a manual asset, surfaced from the Investments tab.
///
/// Two input modes:
/// - **Update Total** — enter the new absolute value as of a date.
/// - **Add Transaction** — enter a signed delta (+ deposit / − withdrawal),
///   and the sheet records `previousValue + delta` as the new total on the
///   picked date.
///
/// Both modes end up writing a `DurableManualAssetValue` row — the only
/// difference is whether the user thinks about the new balance or the
/// transaction that changed it.
struct ManualAssetUpdateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppContainerController.self) private var container

    let asset: DurableManualAsset

    enum Mode: String, CaseIterable, Identifiable {
        case updateTotal = "Update Total"
        case addTransaction = "Transaction"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .updateTotal
    @State private var totalText: String = ""
    @State private var deltaText: String = ""
    @State private var deltaSign: DeltaSign = .deposit
    @State private var recordedAt: Date = .now
    @State private var note: String = ""
    @State private var saveError: String?

    enum DeltaSign: String, CaseIterable, Identifiable {
        case deposit = "+ Deposit"
        case withdrawal = "− Withdrawal"
        var id: String { rawValue }
    }

    var body: some View {
        NwModalLayout(
            title: asset.name,
            onClose: { dismiss() },
            onConfirm: save,
            confirmDisabled: !isValid
        ) {
            VStack(alignment: .leading, spacing: NwSpacing.md) {
                if let saveError {
                    NwInlineNotice("Couldn't save", message: saveError, tone: .warning)
                }

                HStack {
                    Text("Current")
                        .foregroundStyle(.secondary)
                    Spacer()
                    NwAmountText(asset.currentValue, variant: .body)
                }
                .padding(NwSpacing.md)
                .background(NwAppColors.cardSurface)
                .clipShape(RoundedRectangle(cornerRadius: NwCornerRadius.md, style: .continuous))

                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)

                if mode == .updateTotal {
                    TextField("New Total", text: $totalText, prompt: Text("New Total").foregroundStyle(.secondary))
                        .keyboardType(.decimalPad)
                        .padding(NwSpacing.md)
                        .background(NwAppColors.cardSurface)
                        .clipShape(RoundedRectangle(cornerRadius: NwCornerRadius.md, style: .continuous))
                } else {
                    Picker("Sign", selection: $deltaSign) {
                        ForEach(DeltaSign.allCases) { s in
                            Text(s.rawValue).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextField("Amount", text: $deltaText, prompt: Text("Amount").foregroundStyle(.secondary))
                        .keyboardType(.decimalPad)
                        .padding(NwSpacing.md)
                        .background(NwAppColors.cardSurface)
                        .clipShape(RoundedRectangle(cornerRadius: NwCornerRadius.md, style: .continuous))

                    if let preview = transactionPreview {
                        HStack {
                            Text("New Total")
                                .foregroundStyle(.secondary)
                            Spacer()
                            NwAmountText(preview, variant: .body)
                        }
                        .padding(NwSpacing.md)
                        .background(NwAppColors.cardSurface)
                        .clipShape(RoundedRectangle(cornerRadius: NwCornerRadius.md, style: .continuous))
                    }
                }

                HStack {
                    Text("As of")
                        .foregroundStyle(.secondary)
                    Spacer()
                    DatePicker("", selection: $recordedAt, in: ...Date.now, displayedComponents: .date)
                        .labelsHidden()
                }
                .padding(NwSpacing.md)
                .background(NwAppColors.cardSurface)
                .clipShape(RoundedRectangle(cornerRadius: NwCornerRadius.md, style: .continuous))

                TextField("Note (optional)", text: $note, prompt: Text("Note (optional)").foregroundStyle(.secondary), axis: .vertical)
                    .lineLimit(2...5)
                    .padding(NwSpacing.md)
                    .background(NwAppColors.cardSurface)
                    .clipShape(RoundedRectangle(cornerRadius: NwCornerRadius.md, style: .continuous))

                if !asset.sortedValues.isEmpty {
                    NwSectionHeader("Recent History")
                    VStack(spacing: NwSpacing.sm) {
                        ForEach(asset.sortedValues.reversed().prefix(5)) { entry in
                            HStack {
                                Text(DateDisplay.shortDate(entry.recordedAt))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                NwAmountText(Money(milliunits: entry.amountMilliunits), variant: .body)
                            }
                            .padding(.vertical, NwSpacing.xs)
                        }
                    }
                    .padding(NwSpacing.cardPadding)
                    .background(NwAppColors.cardSurface)
                    .clipShape(RoundedRectangle(cornerRadius: NwCornerRadius.md, style: .continuous))
                }
            }
        }
    }

    private var totalValue: Money? {
        let trimmed = totalText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let decimal = Decimal(string: trimmed) else { return nil }
        return Money.dollars(decimal)
    }

    private var deltaValue: Money? {
        let trimmed = deltaText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let decimal = Decimal(string: trimmed) else { return nil }
        let unsigned = Money.dollars(decimal)
        return deltaSign == .deposit ? unsigned : Money(milliunits: -unsigned.milliunits)
    }

    private var transactionPreview: Money? {
        guard let delta = deltaValue else { return nil }
        return Money(milliunits: asset.currentValueMilliunits + delta.milliunits)
    }

    private var isValid: Bool {
        switch mode {
        case .updateTotal:    return totalValue != nil
        case .addTransaction: return deltaValue != nil
        }
    }

    private func save() {
        let ctx = container.modelContainer.mainContext
        let newAmount: Money
        switch mode {
        case .updateTotal:
            guard let v = totalValue else { return }
            newAmount = v
        case .addTransaction:
            guard let preview = transactionPreview else { return }
            newAmount = preview
        }

        let entry = DurableManualAssetValue(
            recordedAt: recordedAt,
            amountMilliunits: newAmount.milliunits,
            note: note.isEmpty ? nil : note,
            asset: asset
        )
        ctx.insert(entry)
        if asset.values == nil {
            asset.values = [entry]
        } else {
            asset.values?.append(entry)
        }
        asset.lastUpdatedAt = .now

        let succeeded = ctx.safeSave(source: "manualAsset.update")
        guard succeeded else {
            ctx.delete(entry)
            saveError = "Saving the update failed. Try again or close and re-open the sheet."
            return
        }
        container.recordDailySnapshot()
        Task { await container.rebuildChartHistory() }
        dismiss()
    }
}
