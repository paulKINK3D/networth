import Foundation
import Money

public enum CurrencyFormatter {
    public static func currency(_ amount: Money, code: String = "USD", showCents: Bool = true) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.maximumFractionDigits = showCents ? 2 : 0
        formatter.minimumFractionDigits = showCents ? 2 : 0
        return formatter.string(from: NSDecimalNumber(decimal: amount.decimalValue)) ?? "$0"
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

    private static func currencySymbol(for code: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        return formatter.currencySymbol ?? "$"
    }
}

public enum DateDisplay {
    public static func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }

    public static func monthYear(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        return f.string(from: date)
    }

    public static func relativeDay(_ date: Date, relativeTo reference: Date) -> String {
        let cal = Calendar(identifier: .gregorian)
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: reference), to: cal.startOfDay(for: date)).day ?? 0
        switch days {
        case 0:   return "Today"
        case 1:   return "Tomorrow"
        case -1:  return "Yesterday"
        case 2...6:
            let f = DateFormatter(); f.dateFormat = "EEEE"; return f.string(from: date)
        default:  return shortDate(date)
        }
    }
}
