import Testing
import Foundation
@testable import Money
@testable import Formatting

@Suite("Formatters")
struct FormattersTests {
    @Test func currencyShowsCents() {
        let s = CurrencyFormatter.currency(Money.dollars(12.34))
        #expect(s.contains("12.34"))
    }

    @Test func compactScalesByMagnitude() {
        #expect(CurrencyFormatter.compact(Money.dollars(450)).contains("450"))
        #expect(CurrencyFormatter.compact(Money.dollars(12_345)).contains("K"))
        #expect(CurrencyFormatter.compact(Money.dollars(2_500_000)).contains("M"))
    }

    @Test func signedDeltaAddsPrefix() {
        let positive = CurrencyFormatter.signedDelta(Money.dollars(50))
        let negative = CurrencyFormatter.signedDelta(Money.dollars(-50))
        #expect(positive.hasPrefix("+"))
        #expect(negative.hasPrefix("−"))
    }

    @Test func currencyInputShiftsDigitsIntoCents() {
        var text = ""
        for digit in "83898" {
            text = CurrencyInputFormatter.formatted(text + String(digit))
        }

        #expect(text == "838.98")
        #expect(CurrencyInputFormatter.money(from: text) == Money.dollars(838.98))
    }

    @Test func currencyInputSupportsDeletionAndPastedFormatting() {
        #expect(CurrencyInputFormatter.formatted("838.9") == "83.89")
        #expect(CurrencyInputFormatter.formatted("$1,234.56") == "1234.56")
        #expect(CurrencyInputFormatter.formatted("") == "")
    }

    @Test func wholeDollarInputNeverCreatesCents() {
        #expect(
            CurrencyInputFormatter.formattedWholeDollars("$1,500.00")
                == "1500"
        )
        #expect(
            CurrencyInputFormatter.wholeDollarText(
                for: Money.dollars(1500)
            ) == "1500"
        )
        #expect(
            CurrencyInputFormatter.wholeDollarMoney(from: "1500")
                == Money.dollars(1500)
        )
    }
}
