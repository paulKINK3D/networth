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
