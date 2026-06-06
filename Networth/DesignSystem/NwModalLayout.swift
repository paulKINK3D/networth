import SwiftUI

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
        .background(NwAppColors.background.ignoresSafeArea())
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
        .background(NwAppColors.background)
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
        .background(NwAppColors.background)
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
