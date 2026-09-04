import SwiftUI
import NetworthCore

/// Standardized currency-amount label. Uses NetworthCore's formatter so views
/// never reach for raw milliunits.
public struct NwAmountText: View {
    public enum Variant {
        case hero, large, metricSmall, body, compact, signed
    }

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
        case .metricSmall: return NwTypography.metricSmall
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

private enum NwCurrencyInputPrecision {
    case cents
    case wholeDollars

    func formatted(_ text: String) -> String {
        switch self {
        case .cents:
            return CurrencyInputFormatter.formatted(text)
        case .wholeDollars:
            return CurrencyInputFormatter.formattedWholeDollars(text)
        }
    }

    var zeroDisplay: String {
        switch self {
        case .cents: return "0.00"
        case .wholeDollars: return "0"
        }
    }
}

private struct NwCurrencyInputModifier: ViewModifier {
    @Binding var text: String
    let title: String
    let precision: NwCurrencyInputPrecision
    let onFocusChange: (Bool) -> Void
    @State private var showingKeypad = false

    func body(content: Content) -> some View {
        ZStack {
            content
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            Button {
                onFocusChange(true)
                showingKeypad = true
            } label: {
                Color.clear
                    .contentShape(Rectangle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(text.isEmpty ? "Not set" : text)
        }
        .onChange(of: text) { _, proposedText in
            let formatted = precision.formatted(proposedText)
            if formatted != proposedText {
                text = formatted
            }
        }
        .sheet(isPresented: $showingKeypad, onDismiss: {
            onFocusChange(false)
        }) {
            NwCurrencyEntryPadSheet(
                title: title,
                value: $text,
                precision: precision
            )
        }
    }
}

private struct NwCurrencyEntryPadSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    @Binding var value: String
    let precision: NwCurrencyInputPrecision

    @State private var draft = ""
    @State private var replaceOnNextNumber = false
    @State private var cancelled = false

    private let keys = [
        "1", "2", "3",
        "4", "5", "6",
        "7", "8", "9",
        "Clear", "0", "⌫"
    ]

    var body: some View {
        VStack(spacing: NwSpacing.md) {
            Text(title)
                .font(NwTypography.titleSmall)
                .frame(maxWidth: .infinity, alignment: .center)

            Text(draft.isEmpty ? precision.zeroDisplay : draft)
                .font(NwTypography.displayLarge)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, NwSpacing.md)
                .nwCardStyle(.secondary, padding: 0)

            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: NwSpacing.sm),
                    count: 3
                ),
                spacing: NwSpacing.sm
            ) {
                ForEach(keys, id: \.self) { key in
                    Button {
                        handleKey(key)
                    } label: {
                        Text(key)
                            .font(NwTypography.headline)
                            .foregroundStyle(NwAppColors.textPrimary)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(
                                RoundedRectangle(
                                    cornerRadius: NwCornerRadius.md,
                                    style: .continuous
                                )
                                .fill(NwAppColors.cardSurface)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(key == "⌫" ? "Delete" : key)
                }
            }

            HStack(spacing: NwSpacing.md) {
                Button {
                    cancelled = true
                    dismiss()
                } label: {
                    Label("Cancel", systemImage: "xmark")
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(NwDestructiveButtonStyle())

                Button {
                    dismiss()
                } label: {
                    Label("Done", systemImage: "checkmark")
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(NwPrimaryButtonStyle())
            }
            .padding(.top, NwSpacing.xs)
        }
        .padding(.horizontal, NwSpacing.screenPadding)
        .padding(.top, NwSpacing.xxl)
        .padding(.bottom, NwSpacing.md)
        .background(NwAppColors.background.ignoresSafeArea())
        .onAppear {
            draft = precision.formatted(value)
            replaceOnNextNumber = !draft.isEmpty
            cancelled = false
        }
        .onDisappear {
            if !cancelled {
                value = draft
            }
        }
        .presentationDetents([.height(480)])
        .presentationDragIndicator(.visible)
    }

    private func handleKey(_ key: String) {
        switch key {
        case "Clear":
            draft = ""
            replaceOnNextNumber = false
        case "⌫":
            let digits = draft.compactMap(\.wholeNumberValue)
                .dropLast()
                .map(String.init)
                .joined()
            draft = precision.formatted(digits)
            replaceOnNextNumber = false
        default:
            guard key.allSatisfy(\.isNumber) else { return }
            let proposedText = replaceOnNextNumber ? key : draft + key
            draft = precision.formatted(proposedText)
            replaceOnNextNumber = false
        }
    }
}

extension View {
    /// Currency entry with an implied two-digit decimal. The first tap clears
    /// any existing value so the first number typed starts a replacement.
    func nwCurrencyInput(
        text: Binding<String>,
        title: String = "Amount",
        onFocusChange: @escaping (Bool) -> Void = { _ in }
    ) -> some View {
        modifier(NwCurrencyInputModifier(
            text: text,
            title: title,
            precision: .cents,
            onFocusChange: onFocusChange
        ))
    }

    /// Whole-dollar entry for planning values that intentionally exclude
    /// cents. The first number typed replaces any existing value.
    func nwWholeDollarInput(
        text: Binding<String>,
        title: String = "Amount",
        onFocusChange: @escaping (Bool) -> Void = { _ in }
    ) -> some View {
        modifier(NwCurrencyInputModifier(
            text: text,
            title: title,
            precision: .wholeDollars,
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
    public let showCents: Bool

    public init(
        title: String,
        subtitle: String,
        amount: Money,
        showCents: Bool = true
    ) {
        self.title = title
        self.subtitle = subtitle
        self.amount = amount
        self.showCents = showCents
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
                showCents: showCents,
                color: amount.isNegative
                    ? NwAppColors.liability
                    : NwAppColors.positive
            )
        }
        .contentShape(Rectangle())
    }
}
