import Testing
import Foundation
@testable import Money
@testable import Models

@Suite("Emergency fund target math")
struct EmergencyFundMathTests {
    @Test func medianRequiresMinimumSampleMonths() {
        #expect(EmergencyFundMath.medianOfCompleteMonths([]) == nil)
        #expect(EmergencyFundMath.medianOfCompleteMonths(
            [.dollars(integer: 4_000)]
        ) == nil)
    }

    @Test func medianOfOddAndEvenCounts() {
        let odd = EmergencyFundMath.medianOfCompleteMonths([
            .dollars(integer: 3_000),
            .dollars(integer: 9_000),
            .dollars(integer: 4_000)
        ])
        #expect(odd == .dollars(integer: 4_000))

        let even = EmergencyFundMath.medianOfCompleteMonths([
            .dollars(integer: 3_000),
            .dollars(integer: 5_000),
            .dollars(integer: 4_000),
            .dollars(integer: 20_000)
        ])
        // Median of middle two (4k, 5k); a spike month barely moves it.
        #expect(even == .dollars(integer: 4_500))
    }

    @Test func targetAppliesMonthsAndReductionThenRounds() {
        let target = EmergencyFundMath.target(
            medianMonthly: .dollars(integer: 5_150),
            months: 6,
            reductionPercent: 70
        )
        // 5150 × 6 × 0.70 = 21,630 → rounds to nearest $100 = 21,600.
        #expect(target == .dollars(integer: 21_600))
    }

    @Test func targetDegeneratesToZeroOnBadInputs() {
        #expect(EmergencyFundMath.target(
            medianMonthly: .zero, months: 6, reductionPercent: 100
        ) == .zero)
        #expect(EmergencyFundMath.target(
            medianMonthly: .dollars(integer: 4_000),
            months: 0, reductionPercent: 100
        ) == .zero)
    }

    @Test func firstDerivationAlwaysAdopts() {
        #expect(EmergencyFundMath.shouldAdopt(
            current: .zero, derived: .dollars(integer: 20_000)
        ))
    }

    @Test func smallDriftDoesNotAdopt() {
        // $100 move on a $20k target: under both $250 and 5% ($1k).
        #expect(!EmergencyFundMath.shouldAdopt(
            current: .dollars(integer: 20_000),
            derived: .dollars(integer: 20_100)
        ))
    }

    @Test func floorOrFractionThresholdAdopts() {
        // $300 ≥ $250 floor.
        #expect(EmergencyFundMath.shouldAdopt(
            current: .dollars(integer: 20_000),
            derived: .dollars(integer: 20_300)
        ))
        // 5% of $4,000 = $200 ≤ $250; $200 move adopts via the fraction.
        #expect(EmergencyFundMath.shouldAdopt(
            current: .dollars(integer: 4_000),
            derived: .dollars(integer: 4_200)
        ))
    }

    @Test func zeroDerivedNeverAdopts() {
        #expect(!EmergencyFundMath.shouldAdopt(
            current: .dollars(integer: 20_000), derived: .zero
        ))
    }
}
