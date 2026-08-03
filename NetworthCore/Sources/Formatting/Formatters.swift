import Foundation
import Money

public enum CurrencyFormatter {
    public static func currency(_ amount: Money, code: String = "USD", showCents: Bool = true) -> String {
        amount.decimalValue.formatted(
            .currency(code: code)
                .precision(.fractionLength(showCents ? 2 : 0))
        )
    }

    /// Compact display, e.g. "$12.3K", "$1.2M". Used for big metric capsules.
    public static func compact(_ amount: Money, code: String = "USD") -> String {
        let value = amount.doubleValue
        let abs = Swift.abs(value)
        let sign = value < 0 ? "-" : ""
        let symbol = currencySymbol(for: code)
        switch abs {
        case 0..<1_000:
            return "\(sign)\(symbol)\(Int(abs.rounded()))"
        case 1_000..<1_000_000:
            return "\(sign)\(symbol)\(String(format: "%.1f", abs / 1_000))K"
        case 1_000_000..<1_000_000_000:
            return "\(sign)\(symbol)\(String(format: "%.2f", abs / 1_000_000))M"
        default:
            return "\(sign)\(symbol)\(String(format: "%.2f", abs / 1_000_000_000))B"
        }
    }

    public static func signedDelta(_ amount: Money, code: String = "USD") -> String {
        let base = currency(amount.absolute, code: code, showCents: true)
        return amount.isNegative ? "−\(base)" : "+\(base)"
    }

    /// Symbol lookup is cached — NumberFormatter construction is expensive
    /// and `compact` runs inside row rendering across the app.
    private static let symbolCacheLock = NSLock()
    nonisolated(unsafe) private static var symbolCache: [String: String] = [:]

    private static func currencySymbol(for code: String) -> String {
        symbolCacheLock.lock()
        defer { symbolCacheLock.unlock() }
        if let cached = symbolCache[code] { return cached }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        let symbol = formatter.currencySymbol ?? "$"
        symbolCache[code] = symbol
        return symbol
    }
}

/// Formats payment-terminal-style currency entry where every typed digit
/// shifts the decimal two places. For example, `83898` becomes `838.98`.
public enum CurrencyInputFormatter {
    public static func formatted(_ proposedText: String) -> String {
        let digits = proposedText.compactMap(\.wholeNumberValue)
            .map(String.init)
            .joined()
        guard !digits.isEmpty else { return "" }

        let significantDigits = digits.drop(while: { $0 == "0" })
        let normalized = significantDigits.isEmpty
            ? "0"
            : String(significantDigits)
        let padded = String(
            repeating: "0",
            count: max(0, 3 - normalized.count)
        ) + normalized
        let decimalIndex = padded.index(padded.endIndex, offsetBy: -2)
        return "\(padded[..<decimalIndex]).\(padded[decimalIndex...])"
    }

    public static func text(for amount: Money) -> String {
        var cents = amount.absolute.decimalValue * 100
        var roundedCents = Decimal()
        NSDecimalRound(&roundedCents, &cents, 0, .plain)
        return formatted(NSDecimalNumber(decimal: roundedCents).stringValue)
    }

    public static func money(from text: String) -> Money? {
        guard !text.isEmpty, let decimal = Decimal(string: text) else {
            return nil
        }
        return Money.dollars(decimal)
    }
}

public enum DateDisplay {
    // DateFormatter is expensive to build and thread-safe to *use* on modern
    // OS releases, so each style is built once.
    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private static let monthYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f
    }()

    public static func shortDate(_ date: Date) -> String {
        shortDateFormatter.string(from: date)
    }

    public static func monthYear(_ date: Date) -> String {
        monthYearFormatter.string(from: date)
    }

    public static func relativeDay(_ date: Date, relativeTo reference: Date) -> String {
        let cal = Calendar(identifier: .gregorian)
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: reference), to: cal.startOfDay(for: date)).day ?? 0
        switch days {
        case 0:   return "Today"
        case 1:   return "Tomorrow"
        case -1:  return "Yesterday"
        case 2...6:
            return weekdayFormatter.string(from: date)
        default:  return shortDate(date)
        }
    }
}
