import SwiftUI
import UIKit
import NetworthCore

/// Standardized currency-amount label. Uses NetworthCore's formatter so views
/// never reach for raw milliunits.
public struct NwAmountText: View {
    public enum Variant { case hero, large, body, compact, signed }

    public let amount: Money
    public let variant: Variant
    public let showCents: Bool
    public let color: Color?

    public init(_ amount: Money, variant: Variant = .body, showCents: Bool = true, color: Color? = nil) {
        self.amount = amount
        self.variant = variant
        self.showCents = showCents
        self.color = color
    }

    public var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color ?? defaultColor)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }

    private var text: String {
        switch variant {
        case .signed:  return CurrencyFormatter.signedDelta(amount)
        case .compact: return CurrencyFormatter.compact(amount)
        default:       return CurrencyFormatter.currency(amount, showCents: showCents)
        }
    }

    private var font: Font {
        switch variant {
        case .hero:    return NwTypography.displayLarge
        case .large:   return NwTypography.display
        case .body:    return NwTypography.bodyEmphasis
        case .compact: return NwTypography.headline
        case .signed:  return NwTypography.bodyEmphasis
        }
    }

    private var defaultColor: Color {
        switch variant {
        case .signed:
            return amount.isNegative ? NwAppColors.liability : NwAppColors.positive
        default:
            return NwAppColors.textPrimary
        }
    }
}

private struct NwCurrencyInputModifier: ViewModifier {
    @Binding var text: String
    @State private var hasStartedEditing = false

    func body(content: Content) -> some View {
        content
            .keyboardType(.numberPad)
            .onChange(of: text) { _, proposedText in
                let formatted = CurrencyInputFormatter.formatted(proposedText)
                if formatted != proposedText {
                    text = formatted
                }
            }
            .simultaneousGesture(
                TapGesture().onEnded {
                    guard !hasStartedEditing else { return }
                    hasStartedEditing = true
                    text = ""
                }
            )
    }
}

extension View {
    /// Currency entry with an implied two-digit decimal. The first tap clears
    /// any existing value so the first number typed starts a replacement.
    func nwCurrencyInput(text: Binding<String>) -> some View {
        modifier(NwCurrencyInputModifier(text: text))
    }
}

/// UIKit-backed currency field for forms that need the compact native digit
/// keypad plus a reliable system input-accessory Done button.
struct NwAccessoryCurrencyTextField: UIViewRepresentable {
    @Binding private var text: String
    private let placeholder: String
    private let onFocusChange: (Bool) -> Void

    init(
        text: Binding<String>,
        placeholder: String = "0.00",
        onFocusChange: @escaping (Bool) -> Void
    ) {
        _text = text
        self.placeholder = placeholder
        self.onFocusChange = onFocusChange
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.keyboardType = .numberPad
        field.textAlignment = .right
        field.placeholder = placeholder
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textChanged(_:)),
            for: .editingChanged
        )

        let toolbar = UIToolbar()
        toolbar.sizeToFit()
        toolbar.items = [
            UIBarButtonItem(systemItem: .flexibleSpace),
            UIBarButtonItem(
                barButtonSystemItem: .done,
                target: context.coordinator,
                action: #selector(Coordinator.doneTapped)
            )
        ]
        field.inputAccessoryView = toolbar
        context.coordinator.textField = field
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text {
            field.text = text
        }
        if field.placeholder != placeholder {
            field.placeholder = placeholder
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: NwAccessoryCurrencyTextField
        weak var textField: UITextField?
        private var hasStartedEditing = false

        init(parent: NwAccessoryCurrencyTextField) {
            self.parent = parent
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            if !hasStartedEditing {
                hasStartedEditing = true
                textField.text = ""
                parent.text = ""
            }
            parent.onFocusChange(true)
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.onFocusChange(false)
        }

        @objc func textChanged(_ textField: UITextField) {
            let formatted = CurrencyInputFormatter.formatted(
                textField.text ?? ""
            )
            if textField.text != formatted {
                textField.text = formatted
            }
            parent.text = formatted
        }

        @objc func doneTapped() {
            textField?.resignFirstResponder()
        }
    }
}

/// Shared compact transaction presentation used in recent and paged history.
/// Navigation and loading behavior remain owned by the containing screen.
public struct NwTransactionRow: View {
    public let title: String
    public let subtitle: String
    public let amount: Money

    public init(title: String, subtitle: String, amount: Money) {
        self.title = title
        self.subtitle = subtitle
        self.amount = amount
    }

    public var body: some View {
        HStack(spacing: NwSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(NwTypography.body)
                    .foregroundStyle(NwAppColors.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(NwTypography.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: NwSpacing.sm)
            NwAmountText(
                amount,
                variant: .body,
                color: amount.isNegative
                    ? NwAppColors.liability
                    : NwAppColors.positive
            )
        }
        .contentShape(Rectangle())
    }
}
