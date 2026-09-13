import Testing
import Foundation
@testable import Money
@testable import Models

@Suite("Spending history averages")
struct SpendingHistoryAveragesTests {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        return utc.date(from: comps)!
    }

    private func month(
        _ y: Int, _ m: Int,
        groups: [SpendingHistoryGroupTotal]
    ) -> SpendingHistoryMonth {
        SpendingHistoryMonth(
            month: date(y, m, 1),
            incomeMilliunits: 0,
            totalMilliunits: groups.map(\.spentMilliunits).reduce(0, +),
            ordinaryTotalMilliunits: groups.map(\.spentMilliunits)
                .reduce(0, +),
            groups: groups
        )
    }

    private func category(
        _ id: String,
        spent: Int64,
        lines: [(String, Int64)] = []
    ) -> SpendingHistoryCategoryTotal {
        SpendingHistoryCategoryTotal(
            id: id,
            name: id.capitalized,
            spentMilliunits: spent,
            transactionIds: lines.map(\.0),
            lineAmountsByTransactionId: Dictionary(
                uniqueKeysWithValues: lines
            )
        )
    }

    private func group(
        _ id: String,
        categories: [SpendingHistoryCategoryTotal]
    ) -> SpendingHistoryGroupTotal {
        SpendingHistoryGroupTotal(
            id: id,
            name: id.capitalized,
            spentMilliunits: categories.map(\.spentMilliunits).reduce(0, +),
            categories: categories
        )
    }

    @Test func windowExcludesCurrentMonthAndCaps() {
        let spread = [
            month(2025, 8, groups: []),
            month(2026, 6, groups: []),
            month(2026, 7, groups: []),
            month(2026, 8, groups: []),
            month(2026, 9, groups: [])
        ]
        let window = SpendingHistoryAverages.averageWindow(
            months: spread,
            asOf: date(2026, 9, 12),
            monthsBack: 3,
            calendar: utc
        )
        #expect(window.map(\.month) == [
            date(2026, 8, 1), date(2026, 7, 1), date(2026, 6, 1)
        ])
    }

    @Test func categoryAveragesSpanTheWindow() {
        let window = [
            month(2026, 8, groups: [
                group("surplus", categories: [
                    category("travel", spent: 900_000),
                    category("books", spent: 100_000)
                ])
            ]),
            month(2026, 7, groups: [
                group("surplus", categories: [
                    category("travel", spent: 300_000)
                ]),
                group("other", categories: [
                    category("misc", spent: 999_000)
                ])
            ])
        ]
        let averages = SpendingHistoryAverages.categoryAverages(
            groupId: "surplus",
            window: window
        )
        #expect(averages.map(\.id) == ["travel", "books"])
        #expect(averages[0].monthlyAverage == Money(milliunits: 600_000))
        #expect(averages[1].monthlyAverage == Money(milliunits: 50_000))
    }

    @Test func payeeRollupsSumSelectedAgainstWindow() {
        let august = month(2026, 8, groups: [
            group("surplus", categories: [
                category("travel", spent: 500_000, lines: [
                    ("t1", -300_000), ("t2", -200_000)
                ])
            ])
        ])
        let july = month(2026, 7, groups: [
            group("surplus", categories: [
                category("travel", spent: 100_000, lines: [
                    ("t3", -100_000)
                ])
            ])
        ])
        let selected = category("travel", spent: 250_000, lines: [
            ("t4", -250_000)
        ])
        let payeeById = [
            "t1": "Delta", "t2": "Hilton", "t3": "Delta", "t4": "Delta"
        ]
        let rollups = SpendingHistoryAverages.payeeRollups(
            groupId: "surplus",
            categoryId: "travel",
            window: [august, july],
            selected: selected,
            payeeName: { payeeById[$0] }
        )
        #expect(rollups.map(\.name) == ["Delta", "Hilton"])
        let delta = rollups[0]
        // Window: 300 + 100 over 2 months; selected month adds t4 only.
        #expect(delta.monthlyAverage == Money(milliunits: 200_000))
        #expect(delta.selectedTotal == Money(milliunits: 250_000))
        #expect(delta.purchaseCount == 2)
        #expect(delta.selectedCount == 1)
        #expect(Set(delta.transactionIds) == ["t1", "t3", "t4"])
        let hilton = rollups[1]
        #expect(hilton.monthlyAverage == Money(milliunits: 100_000))
        #expect(hilton.selectedTotal == .zero)
    }

    @Test func payeeRollupsDoNotDoubleCountSelectedMonthInsideWindow() {
        let august = month(2026, 8, groups: [
            group("surplus", categories: [
                category("travel", spent: 300_000, lines: [
                    ("t1", -300_000)
                ])
            ])
        ])
        let selected = category("travel", spent: 300_000, lines: [
            ("t1", -300_000)
        ])
        let rollups = SpendingHistoryAverages.payeeRollups(
            groupId: "surplus",
            categoryId: "travel",
            window: [august],
            selected: selected,
            payeeName: { _ in "Delta" }
        )
        #expect(rollups.count == 1)
        #expect(rollups[0].monthlyAverage == Money(milliunits: 300_000))
        #expect(rollups[0].selectedTotal == Money(milliunits: 300_000))
        #expect(rollups[0].transactionIds == ["t1"])
    }
}
