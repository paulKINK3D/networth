import SwiftUI
import SwiftData
import NetworthCore

struct ManualAssetForm: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppContainerController.self) private var container

    let asset: DurableManualAsset?

    @Query(sort: \DurableManualAsset.name) private var allManualAssets: [DurableManualAsset]

    @State private var name: String = ""
    @State private var kind: ManualAssetKind = .other
    @State private var amountText: String = ""
    @State private var note: String = ""
    @State private var groupName: String = ""
    @State private var recordedAt: Date = .now
    @State private var saveError: String?

    /// Distinct, non-empty group names across all manual assets (sorted) so the
    /// user can pick an existing label instead of retyping it.
    private var existingGroups: [String] {
        let raws = allManualAssets
            .compactMap { $0.deleted ? nil : $0.groupName?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(Set(raws)).sorted()
    }

    var body: some View {
        NwModalLayout(
            title: asset == nil ? "New Manual Asset" : "Edit Asset",
            onClose: { dismiss() },
            onConfirm: save,
            confirmDisabled: name.isEmpty || amountValue == nil
        ) {
            VStack(alignment: .leading, spacing: NwSpacing.md) {
                if let saveError {
                    NwInlineNotice("Couldn't save", message: saveError, tone: .warning)
                }
                TextField("Name", text: $name, prompt: Text("Name").foregroundStyle(.secondary))
                    .textInputAutocapitalization(.words)
                    .padding(NwSpacing.md)
                    .background(NwAppColors.cardSurface)
                    .clipShape(RoundedRectangle(cornerRadius: NwCornerRadius.md, style: .continuous))

                HStack {
                    Text("Type of Asset")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $kind) {
                        ForEach(ManualAssetKind.allCases, id: \.self) { k in
                            Text(k.displayName).tag(k)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(NwAppColors.textPrimary)
                    .labelsHidden()
                }
                .padding(NwSpacing.md)
                .background(NwAppColors.cardSurface)
                .clipShape(RoundedRectangle(cornerRadius: NwCornerRadius.md, style: .continuous))

                HStack(spacing: NwSpacing.sm) {
                    TextField("Group (optional)", text: $groupName, prompt: Text("Group (optional)").foregroundStyle(.secondary))
                        .textInputAutocapitalization(.words)
                    if !existingGroups.isEmpty {
                        Menu {
                            ForEach(existingGroups, id: \.self) { g in
                                Button(g) { groupName = g }
                            }
                            if !groupName.isEmpty {
                                Divider()
                                Button("Clear", role: .destructive) { groupName = "" }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(NwSpacing.md)
                .background(NwAppColors.cardSurface)
                .clipShape(RoundedRectangle(cornerRadius: NwCornerRadius.md, style: .continuous))

                TextField("Current Value", text: $amountText, prompt: Text("Current Value").foregroundStyle(.secondary))
                    .keyboardType(.decimalPad)
                    .padding(NwSpacing.md)
                    .background(NwAppColors.cardSurface)
                    .clipShape(RoundedRectangle(cornerRadius: NwCornerRadius.md, style: .continuous))
                    .onAppear { selectAllOnFirstTap() }

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
                    .lineLimit(3...6)
                    .padding(NwSpacing.md)
                    .background(NwAppColors.cardSurface)
                    .clipShape(RoundedRectangle(cornerRadius: NwCornerRadius.md, style: .continuous))

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
        groupName = asset.groupName ?? ""
    }

    private func selectAllOnFirstTap() {
        // Stub for the documented "first numeric tap replaces existing value" pattern.
        // In practice we'd hook a UIResponder coordinator; deferring to v1.1 polish.
    }

    private func save() {
        guard let amount = amountValue else { return }
        let ctx = container.modelContainer.mainContext

        let isNew = (asset == nil)
        let working: DurableManualAsset
        if let asset {
            working = asset
        } else {
            working = DurableManualAsset(name: name, kind: kind)
            ctx.insert(working)
        }

        // Snapshot prior state so we can roll back only this form's
        // mutations on save failure. ctx.rollback() would discard ALL
        // pending changes in the shared main context, including any
        // unrelated edits from elsewhere.
        let priorName = working.name
        let priorKindRaw = working.kindRaw
        let priorNotes = working.notes
        let priorLastUpdatedAt = working.lastUpdatedAt
        let priorValues = working.values
        let priorGroupName = working.groupName

        let trimmedGroup = groupName.trimmingCharacters(in: .whitespaces)
        working.name = name
        working.kindRaw = kind.rawValue
        working.notes = note.isEmpty ? nil : note
        working.groupName = trimmedGroup.isEmpty ? nil : trimmedGroup
        working.lastUpdatedAt = .now

        let entry = DurableManualAssetValue(
            recordedAt: recordedAt,
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

        let succeeded = ctx.safeSave(source: "manualAsset.save")
        guard succeeded else {
            ctx.delete(entry)
            if isNew {
                ctx.delete(working)
            } else {
                working.values = priorValues
                working.name = priorName
                working.kindRaw = priorKindRaw
                working.notes = priorNotes
                working.groupName = priorGroupName
                working.lastUpdatedAt = priorLastUpdatedAt
            }
            saveError = "Saving the asset failed. Your changes are still here — try again or close and re-open the sheet."
            return
        }
        container.recordDailySnapshot()
        // Rebuild .backfill rows so historical chart points pick up this
        // asset's new/changed value entry. Doesn't hit YNAB.
        Task { await container.rebuildChartHistory() }
        dismiss()
    }
}
