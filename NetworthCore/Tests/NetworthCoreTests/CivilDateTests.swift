import Foundation
import Testing
@testable import NetworthCore

@Suite("Civil date anchoring")
struct CivilDateTests {
    @Test func plaidDateParsesToLocalCalendarDay() throws {
        let dto = PlaidTransactionDTO(
            id: "transaction-1",
            accountId: "plaid-account",
            date: "2026-08-02",
            amount: 12.34,
            name: "Merchant"
        )
        let summary = try #require(
            dto.financialSummary(canonicalAccountId: "canonical-account")
        )
        let parts = Calendar.current.dateComponents(
            [.year, .month, .day],
            from: summary.postedDate
        )
        #expect(parts.year == 2026)
        #expect(parts.month == 8)
        #expect(parts.day == 2)
    }

    @Test func ynabDateParsesToLocalCalendarDay() throws {
        let parsed = try #require(
            YNABTransactionDTO.dateParser.date(from: "2026-08-02")
        )
        let parts = Calendar.current.dateComponents(
            [.year, .month, .day],
            from: parsed
        )
        #expect(parts.year == 2026)
        #expect(parts.month == 8)
        #expect(parts.day == 2)
    }

    @Test func reanchorMovesUTCMidnightToSameCivilDayLocally() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let legacy = utc.date(
            from: DateComponents(year: 2026, month: 8, day: 2)
        )!

        let reanchored = CivilDate.reanchoredFromUTCMidnight(legacy)
        // In a UTC-equivalent zone there is nothing to shift; elsewhere the
        // result must be local midnight of the same civil day.
        let expected = Calendar.current.date(
            from: DateComponents(year: 2026, month: 8, day: 2)
        )!
        if expected == legacy {
            #expect(reanchored == nil)
        } else {
            #expect(reanchored == expected)
        }
    }

    @Test func reanchorIsIdempotent() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let legacy = utc.date(
            from: DateComponents(year: 2026, month: 8, day: 2)
        )!
        guard let once = CivilDate.reanchoredFromUTCMidnight(legacy) else {
            return  // UTC-equivalent zone: nothing shifts, nothing to re-run.
        }
        #expect(CivilDate.reanchoredFromUTCMidnight(once) == nil)
    }

    @Test func reanchorIgnoresRealInstants() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let instant = utc.date(
            from: DateComponents(
                year: 2026, month: 8, day: 2, hour: 14, minute: 30, second: 5
            )
        )!
        #expect(CivilDate.reanchoredFromUTCMidnight(instant) == nil)
    }
}
