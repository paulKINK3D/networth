import SwiftUI
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
    let onFocusChange: (Bool) -> Void
    @State private var hasStartedEditing = false
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .keyboardType(.numberPad)
            .focused($isFocused)
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
            .onChange(of: isFocused) { _, focused in
                onFocusChange(focused)
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    if isFocused {
                        Spacer()
                        Button("Done") {
                            isFocused = false
                        }
                        .tint(NwAppColors.primary)
                        .accessibilityLabel("Dismiss keyboard")
                    }
                }
            }
    }
}

extension View {
    /// Currency entry with an implied two-digit decimal. The first tap clears
    /// any existing value so the first number typed starts a replacement.
    func nwCurrencyInput(
        text: Binding<String>,
        onFocusChange: @escaping (Bool) -> Void = { _ in }
    ) -> some View {
        modifier(NwCurrencyInputModifier(
            text: text,
            onFocusChange: onFocusChange
        ))
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
