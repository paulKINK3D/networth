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
}
