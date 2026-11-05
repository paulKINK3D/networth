import SwiftUI

/// Stages inclusive calendar dates and commits a half-open interval on Apply.
struct NwDateRangeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var from: Date
    @State private var to: Date
    let onApply: (DateInterval?) -> Void

    init(selection: DateInterval?, onApply: @escaping (DateInterval?) -> Void) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        _from = State(initialValue: selection?.start
            ?? calendar.dateInterval(of: .month, for: today)?.start ?? today)
        _to = State(initialValue: selection.map {
            calendar.date(byAdding: .day, value: -1, to: $0.end) ?? $0.start
        } ?? today)
        self.onApply = onApply
    }

    var body: some View {
        NwModalLayout(title: "Date range", onClose: { dismiss() }) {
            NwCard {
                VStack(spacing: NwSpacing.md) {
                    DatePicker("From", selection: $from, in: ...to,
                               displayedComponents: .date)
                    Divider()
                    DatePicker("To", selection: $to, in: from...,
                               displayedComponents: .date)
                }
                .datePickerStyle(.compact)
            }
            Button("Apply") {
                let calendar = Calendar.current
                let start = calendar.startOfDay(for: from)
                guard let end = calendar.date(byAdding: .day, value: 1,
                                              to: calendar.startOfDay(for: to)) else { return }
                onApply(DateInterval(start: start, end: end))
                dismiss()
            }
            .buttonStyle(NwPrimaryButtonStyle())
            Button("Clear") {
                onApply(nil)
                dismiss()
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .presentationDetents([.medium, .large])
    }
}

/// Standard modal-sheet scaffold: header bar with close/confirm icons + scrollable content.
public struct NwModalLayout<Content: View>: View {
    public let title: String
    public let onClose: (() -> Void)?
    public let onConfirm: (() -> Void)?
    public let confirmDisabled: Bool
    public let content: () -> Content

    public init(
        title: String,
        onClose: (() -> Void)? = nil,
        onConfirm: (() -> Void)? = nil,
        confirmDisabled: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.onClose = onClose
        self.onConfirm = onConfirm
        self.confirmDisabled = confirmDisabled
        self.content = content
    }

    public var body: some View {
        VStack(spacing: 0) {
            NwModalHeaderView(title: title, onClose: onClose, onConfirm: onConfirm, confirmDisabled: confirmDisabled)
            ScrollView {
                VStack(alignment: .leading, spacing: NwSpacing.lg) {
                    content()
                }
                .padding(NwSpacing.screenPadding)
            }
        }
        .nwGlassSheet()
    }
}

public struct NwModalHeaderView: View {
    public let title: String
    public let onClose: (() -> Void)?
    public let onConfirm: (() -> Void)?
    public let confirmDisabled: Bool

    public init(
        title: String,
        onClose: (() -> Void)? = nil,
        onConfirm: (() -> Void)? = nil,
        confirmDisabled: Bool = false
    ) {
        self.title = title
        self.onClose = onClose
        self.onConfirm = onConfirm
        self.confirmDisabled = confirmDisabled
    }

    public var body: some View {
        HStack {
            if let onClose {
                NwCircularIconButton(icon: .close, tint: NwAppColors.liability, action: onClose)
                    .accessibilityLabel("Close")
            } else {
                Spacer().frame(width: 32)
            }
            Spacer()
            Text(title)
                .font(NwTypography.headline)
                .lineLimit(1)
            Spacer()
            if let onConfirm {
                NwCircularIconButton(icon: .success, tint: NwAppColors.positive, action: onConfirm)
                    .accessibilityLabel("Confirm")
                    .opacity(confirmDisabled ? 0.4 : 1)
                    .disabled(confirmDisabled)
            } else {
                Spacer().frame(width: 32)
            }
        }
        .padding(.horizontal, NwSpacing.screenPadding)
        .padding(.vertical, NwSpacing.md)
    }
}

public struct NwModalActionBar<Leading: View, Trailing: View>: View {
    public let leading: () -> Leading
    public let trailing: () -> Trailing

    public init(@ViewBuilder leading: @escaping () -> Leading, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.leading = leading
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: NwSpacing.md) {
            leading()
            trailing()
        }
        .padding(.horizontal, NwSpacing.screenPadding)
        .padding(.vertical, NwSpacing.md)
    }
}

public struct NwCircularIconButton: View {
    public let icon: NwIcon
    public let tint: Color
    public let action: () -> Void

    public init(icon: NwIcon, tint: Color = NwAppColors.primary, action: @escaping () -> Void) {
        self.icon = icon
        self.tint = tint
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            icon.image
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }
}
