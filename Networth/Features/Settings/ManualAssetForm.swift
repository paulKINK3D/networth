import SwiftUI
import SwiftData
import NetworthCore

struct ManualAssetForm: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppContainerController.self) private var container

    let asset: DurableManualAsset?

    @State private var name: String = ""
    @State private var kind: ManualAssetKind = .other
    @State private var amountText: String = ""
    @State private var note: String = ""

    var body: some View {
        NwModalLayout(
            title: asset == nil ? "New Manual Asset" : "Edit Asset",
            onClose: { dismiss() },
            onConfirm: save,
            confirmDisabled: name.isEmpty || amountValue == nil
        ) {
            VStack(alignment: .leading, spacing: NwSpacing.lg) {
                field("Name") {
                    TextField("e.g. Primary Home", text: $name)
                        .textInputAutocapitalization(.words)
                        .padding(NwSpacing.md)
                        .background(NwAppColors.cardSurface)
                        .clipShape(RoundedRectangle(cornerRadius: NwCornerRadius.md, style: .continuous))
                }
                field("Kind") {
                    Picker("Kind", selection: $kind) {
                        ForEach(ManualAssetKind.allCases, id: \.self) { k in
                            Text(k.displayName).tag(k)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                field("Current Value") {
                    TextField("0.00", text: $amountText)
                        .keyboardType(.decimalPad)
                        .font(NwTypography.monoMetric)
                        .padding(NwSpacing.md)
                        .background(NwAppColors.cardSurface)
                        .clipShape(RoundedRectangle(cornerRadius: NwCornerRadius.md, style: .continuous))
                        .onAppear { selectAllOnFirstTap() }
                }
                field("Note (optional)") {
                    TextField("Bull market valuation, recent appraisal, …", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                        .padding(NwSpacing.md)
                        .background(NwAppColors.cardSurface)
                        .clipShape(RoundedRectangle(cornerRadius: NwCornerRadius.md, style: .continuous))
                }

                if let asset, !asset.sortedValues.isEmpty {
                    NwSectionHeader("History")
                        .padding(.horizontal, 0)
                    VStack(spacing: NwSpacing.sm) {
                        ForEach(asset.sortedValues.reversed().prefix(10)) { entry in
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
        .onAppear(perform: prefill)
    }

    @ViewBuilder
    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: NwSpacing.xs) {
            Text(label)
                .font(NwTypography.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    private var amountValue: Money? {
        let trimmed = amountText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let decimal = Decimal(string: trimmed) else { return nil }
        return Money.dollars(decimal)
    }

    private func prefill() {
        guard let asset else { return }
        name = asset.name
        kind = asset.kind
        amountText = String(describing: asset.currentValue.decimalValue)
        note = asset.notes ?? ""
    }

    private func selectAllOnFirstTap() {
        // Stub for the documented "first numeric tap replaces existing value" pattern.
        // In practice we'd hook a UIResponder coordinator; deferring to v1.1 polish.
    }

    private func save() {
        guard let amount = amountValue else { return }
        let ctx = container.modelContainer.mainContext

        let working: DurableManualAsset
        if let asset {
            working = asset
        } else {
            working = DurableManualAsset(name: name, kind: kind)
            ctx.insert(working)
        }

        working.name = name
        working.kindRaw = kind.rawValue
        working.notes = note.isEmpty ? nil : note
        working.lastUpdatedAt = .now

        let entry = DurableManualAssetValue(
            recordedAt: .now,
            amountMilliunits: amount.milliunits,
            note: note.isEmpty ? nil : note,
            asset: working
        )
        ctx.insert(entry)
        if working.values == nil {
            working.values = [entry]
        } else {
            working.values?.append(entry)
        }

        ctx.safeSave(source: "manualAsset.save")
        container.recordDailySnapshot()
        dismiss()
    }
}
