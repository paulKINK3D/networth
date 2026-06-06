import Foundation
import Money

/// YNAB scheduled-transaction repeat cadence. Drives projection horizon expansion.
public enum ScheduleFrequency: String, Sendable, Hashable, Codable {
    case never
    case daily
    case weekly
    case everyOtherWeek
    case twiceAMonth
    case every4Weeks
    case monthly
    case everyOtherMonth
    case every3Months
    case every4Months
    case twiceAYear
    case yearly
    case everyOtherYear
}

public struct ScheduledTransactionSummary: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let accountId: String
    public let nextDate: Date
    public let frequency: ScheduleFrequency
    public let amount: Money            // signed: + inflow, - outflow per YNAB
    public let payeeName: String?
    public let categoryId: String?
    public let transferAccountId: String?
    public let memo: String?
    public let deleted: Bool

    public init(
        id: String,
        accountId: String,
        nextDate: Date,
        frequency: ScheduleFrequency,
        amount: Money,
        payeeName: String? = nil,
        categoryId: String? = nil,
        transferAccountId: String? = nil,
        memo: String? = nil,
        deleted: Bool = false
    ) {
        self.id = id
        self.accountId = accountId
        self.nextDate = nextDate
        self.frequency = frequency
        self.amount = amount
        self.payeeName = payeeName
        self.categoryId = categoryId
        self.transferAccountId = transferAccountId
        self.memo = memo
        self.deleted = deleted
    }
}

extension ScheduledTransactionSummary {
    /// Enumerate every recurring occurrence within `[start, end]`. Walks both
    /// backward and forward from `nextDate` so callers asking for past
    /// occurrences (e.g. the variable-spend lookback subtracting scheduled
    /// activity already counted) get a complete list.
    public func occurrences(
        from start: Date,
        through end: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> [Date] {
        guard start <= end else { return [] }
        if frequency == .never {
            return (nextDate >= start && nextDate <= end) ? [nextDate] : []
        }
        var dates: [Date] = []

        // 1. Walk backward from nextDate (inclusive) collecting occurrences in range.
        var backCursor: Date? = nextDate
        while let c = backCursor, c >= start {
            if c <= end { dates.append(c) }
            backCursor = step(c, calendar: calendar, direction: -1)
        }

        // 2. Walk forward from the occurrence after nextDate.
        var fwdCursor: Date? = step(nextDate, calendar: calendar, direction: 1)
        while let c = fwdCursor, c <= end {
            if c >= start { dates.append(c) }
            fwdCursor = step(c, calendar: calendar, direction: 1)
        }

        return dates.sorted()
    }

    /// Step the schedule by one period in the given direction (+1 forward, -1 back).
    private func step(_ date: Date, calendar: Calendar, direction: Int = 1) -> Date? {
        precondition(direction == 1 || direction == -1, "step direction must be +1 or -1")
        switch frequency {
        case .never:           return nil
        case .daily:           return calendar.date(byAdding: .day,   value:  1  * direction, to: date)
        case .weekly:          return calendar.date(byAdding: .day,   value:  7  * direction, to: date)
        case .everyOtherWeek:  return calendar.date(byAdding: .day,   value:  14 * direction, to: date)
        case .twiceAMonth:     return calendar.date(byAdding: .day,   value:  15 * direction, to: date)
        case .every4Weeks:     return calendar.date(byAdding: .day,   value:  28 * direction, to: date)
        case .monthly:         return calendar.date(byAdding: .month, value:  1  * direction, to: date)
        case .everyOtherMonth: return calendar.date(byAdding: .month, value:  2  * direction, to: date)
        case .every3Months:    return calendar.date(byAdding: .month, value:  3  * direction, to: date)
        case .every4Months:    return calendar.date(byAdding: .month, value:  4  * direction, to: date)
        case .twiceAYear:      return calendar.date(byAdding: .month, value:  6  * direction, to: date)
        case .yearly:          return calendar.date(byAdding: .year,  value:  1  * direction, to: date)
        case .everyOtherYear:  return calendar.date(byAdding: .year,  value:  2  * direction, to: date)
        }
    }
}
