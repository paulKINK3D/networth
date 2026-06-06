import Testing
import Foundation
@testable import Money

@Suite("Money milliunit math")
struct MoneyTests {
    @Test func dollarsFromDecimalRoundsToMilliunits() {
        let m = Money.dollars(Decimal(string: "12.345")!)
        #expect(m.milliunits == 12_345)
    }

    @Test func dollarsFromInteger() {
        #expect(Money.dollars(integer: 10).milliunits == 10_000)
        #expect(Money.dollars(integer: -3).milliunits == -3_000)
    }

    @Test func arithmeticPreservesSign() {
        let owed = Money(milliunits: -150_000)
        let payment = Money(milliunits: 50_000)
        #expect((owed + payment).milliunits == -100_000)
        #expect((-owed).milliunits == 150_000)
    }

    @Test func sumOfSequence() {
        let items = [Money(milliunits: 100), Money(milliunits: 200), Money(milliunits: -50)]
        #expect(items.sum().milliunits == 250)
    }

    @Test func scaledByDecimalUsesBankersRounding() {
        let balance = Money.dollars(1_234.56)
        let result = balance.scaled(by: Decimal(string: "0.02")!)
        #expect(result.milliunits == Int64(Double(balance.milliunits) * 0.02))
    }

    @Test func comparableAndAbsolute() {
        #expect(Money.dollars(-5) < Money.dollars(-1))
        #expect(Money.dollars(-5).absolute == Money.dollars(5))
    }
}
