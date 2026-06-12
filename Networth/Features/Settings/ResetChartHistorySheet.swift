import SwiftUI
import SwiftData
import NetworthCore

/// Lets the user pick a date and wipe every net-worth snapshot older than it.
/// The picked date is also stored as `DurableUserSettings.chartStartDate` so
/// the chart, backfill, and Trend Detail diagnostic all clamp to it going
/// forward. Bumping `historyBackfillVersion` back to 0 triggers a fresh
/// backfill over the new (shorter) window on the next sync.
struct ResetChartHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppContainerController.self) private var container
    @Query private var settingsList: [DurableUserSettings]

    @State private var pickedDate: Date = Calendar(identifier: .gregorian).startOfDay(for: .now)
    @State private var isResetting = false
    @State private var errorMessage: String?

    private var settings: DurableUserSettings? { settingsList.first }

    var body: some View {
        NwModalLayout(
            title: "Reset Chart History",
            onClose: { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: NwSpacing.lg) {
                NwInlineNotice(
                    "Start the trend chart from a fresh date",
                    message: "Every daily net-worth snapshot older than the picked date is deleted. The chart, the Trend diagnostic, and the 5-year backfill all clamp to this date going forward. Your accounts, manual assets, and category settings are not touched.",
                    tone: .warning
                )

                if let errorMessage {
                    NwInlineNotice(
                        "Save failed",
                        message: errorMessage,
                        tone: .warning
                    )
                }

                VStack(alignment: .leading, spacing: NwSpacing.sm) {
                    Text("Start date")
                        .font(NwTypography.caption)
                        .foregroundStyle(.secondary)
                    DatePicker(
                        "Start date",
                        selection: $pickedDate,
                        in: dateRange,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                }
                .padding(NwSpacing.md)
                .background(NwAppColors.cardSurface)
                .clipShape(RoundedRectangle(cornerRadius: NwCornerRadius.md, style: .continuous))

                Button(role: .destructive) {
                    Task { await performReset() }
                } label: {
                    HStack {
                        if isResetting {
                            ProgressView().controlSize(.small)
                        }
                        Text(isResetting ? "Resetting…" : "Wipe & Reset")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(NwDestructiveButtonStyle())
                .disabled(isResetting)
            }
        }
    }

    private var dateRange: ClosedRange<Date> {
        let cal = Calendar(identifier: .gregorian)
        let today = cal.startOfDay(for: .now)
        let fiveYearsAgo = cal.date(byAdding: .year, value: -5, to: today) ?? today
        return fiveYearsAgo...today
    }

    private func performReset() async {
        guard !isResetting else { return }
        isResetting = true
        errorMessage = nil
        defer { isResetting = false }

        let ctx = container.modelContainer.mainContext
        let cal = Calendar(identifier: .gregorian)
        let floor = cal.startOfDay(for: pickedDate)

        // Wipe every snapshot strictly before the floor — both .live and
        // .backfill. .live rows from before the floor were written by the
        // daily scheduler in the past and reflect breakdown numbers the user
        // has explicitly disavowed. .backfill rows would just regenerate
        // anyway, but deleting them here keeps the on-disk state tidy.
        let snapshotDescriptor = FetchDescriptor<DurableNetWorthSnapshot>(
            predicate: #Predicate { $0.date < floor }
        )
        if let stale = try? ctx.fetch(snapshotDescriptor) {
            for row in stale { ctx.delete(row) }
        }

        let target: DurableUserSettings
        if let existing = settings {
            target = existing
        } else {
            target = DurableUserSettings()
            ctx.insert(target)
        }
        target.chartStartDate = floor
        // Force the next sync to re-run the backfill against the new (smaller)
        // window. Without this, the marker would stay at the current version
        // and the chart between `floor` and today would be empty until a
        // daily .live snapshot fills each day organically.
        target.historyBackfillVersion = 0

        guard ctx.safeSave(source: "settings.resetChartHistory") else {
            // Roll back the in-memory deletes + mutations so the sheet
            // reflects on-disk state again and the user can retry cleanly.
            ctx.rollback()
            errorMessage = "Couldn't save the reset. Try again in a moment."
            return
        }
        dismiss()
        await container.syncNow()
    }
}
