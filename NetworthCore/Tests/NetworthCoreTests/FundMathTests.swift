import Foundation
import Testing
@testable import Models
@testable import Money
@testable import Projections

@Suite("Sinking fund math")
struct FundMathTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func fund(
        target: Money = .dollars(2_000),
        targetDate: Date? = nil,
        plannedMonthly: Money = .zero,
        spendMode: FundSpendMode = .saveToSpend
    ) -> SinkingFund {
        SinkingFund(
            id: "travel", name: "Travel", target: target,
            targetDate: targetDate, plannedMonthly: plannedMonthly,
            spendMode: spendMode, linkedCategoryKeys: ["travel"],
            startDate: date(2026, 1, 1)
        )
    }

    private func entry(_ amount: Money, day: Int = 1) -> FundLedgerEntry {
        FundLedgerEntry(
            id: UUID().uuidString, fundId: "travel",
            date: date(2026, 1, day), amount: amount
        )
    }

    @Test("Balance is manual entries net of linked spending")
    func balanceMath() {
        let balance = FundMath.balance(
            manualEntries: [entry(.dollars(500)), entry(.dollars(500)),
                            entry(.dollars(-100))],
            linkedSpending: .dollars(300)
        )
        #expect(balance == .dollars(600))
    }

    @Test("Progress caps at 1 and is nil without a target")
    func progress() {
        #expect(FundMath.progressFraction(
            balance: .dollars(500), target: .dollars(2_000)
        ) == 0.25)
        #expect(FundMath.progressFraction(
            balance: .dollars(3_000), target: .dollars(2_000)
        ) == 1)
        #expect(FundMath.progressFraction(
            balance: .dollars(500), target: .zero
        ) == nil)
    }

    @Test("Required monthly spreads the shortfall over remaining months")
    func requiredMonthly() {
        let required = FundMath.requiredMonthly(
            balance: .dollars(800),
            target: .dollars(2_000),
            targetDate: date(2026, 12, 1),
            asOf: date(2026, 8, 2),
            calendar: utc
        )
        // $1,200 shortfall over 3 whole months.
        #expect(required == .dollars(400))
    }

    @Test("Status reflects funded, on-track, behind, and open-ended")
    func statuses() {
        let openEnded = FundMath.status(
            fund: fund(target: .zero), balance: .dollars(100),
            asOf: date(2026, 8, 2), calendar: utc
        )
        #expect(openEnded == .openEnded)

        let funded = FundMath.status(
            fund: fund(), balance: .dollars(2_500),
            asOf: date(2026, 8, 2), calendar: utc
        )
        #expect(funded == .funded)

        let dated = fund(
            targetDate: date(2026, 12, 1), plannedMonthly: .dollars(400)
        )
        #expect(FundMath.status(
            fund: dated, balance: .dollars(800),
            asOf: date(2026, 8, 2), calendar: utc
        ) == .onTrack(requiredMonthly: .dollars(400)))
        #expect(FundMath.status(
            fund: dated, balance: .dollars(200),
            asOf: date(2026, 8, 2), calendar: utc
        ) == .behind(requiredMonthly: .dollars(600)))

        let undated = fund(plannedMonthly: .dollars(100))
        #expect(FundMath.status(
            fund: undated, balance: .dollars(500),
            asOf: date(2026, 8, 2), calendar: utc
        ) == .saving)
    }

    @Test("A past target date demands the full shortfall now")
    func pastTargetDate() {
        let required = FundMath.requiredMonthly(
            balance: .dollars(500),
            target: .dollars(2_000),
            targetDate: date(2026, 6, 1),
            asOf: date(2026, 8, 2),
            calendar: utc
        )
        #expect(required == .dollars(1_500))
    }
}
