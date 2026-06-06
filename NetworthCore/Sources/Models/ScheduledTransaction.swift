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
    public let memo: String?
    public let deleted: Bool

    public init(
        id: String,
        accountId: String,
        nextDate: Date,
        frequency: ScheduleFrequency,
        amount: Money,
        payeeName: String? = nil,
        memo: String? = nil,
        deleted: Bool = false
    ) {
        self.id = id
        self.accountId = accountId
        self.nextDate = nextDate
        self.frequency = frequency
        self.amount = amount
        self.payeeName = payeeName
        self.memo = memo
        self.deleted = deleted
    }
}

extension ScheduledTransactionSummary {
    /// Expand recurring occurrences out to `end`, using a Gregorian calendar.
    public func occurrences(
        from start: Date,
        through end: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> [Date] {
        guard start <= end else { return [] }
        var dates: [Date] = []
        var cursor = nextDate
        // Skip occurrences strictly before `start`.
        while cursor < start, let next = step(cursor, calendar: calendar) {
            cursor = next
        }
        while cursor <= end {
            dates.append(cursor)
            if frequency == .never { break }
            guard let next = step(cursor, calendar: calendar) else { break }
            cursor = next
        }
        return dates
    }

    private func step(_ date: Date, calendar: Calendar) -> Date? {
        switch frequency {
        case .never:           return nil
        case .daily:           return calendar.date(byAdding: .day,   value: 1,  to: date)
        case .weekly:          return calendar.date(byAdding: .day,   value: 7,  to: date)
        case .everyOtherWeek:  return calendar.date(byAdding: .day,   value: 14, to: date)
        case .twiceAMonth:     return calendar.date(byAdding: .day,   value: 15, to: date)
        case .every4Weeks:     return calendar.date(byAdding: .day,   value: 28, to: date)
        case .monthly:         return calendar.date(byAdding: .month, value: 1,  to: date)
        case .everyOtherMonth: return calendar.date(byAdding: .month, value: 2,  to: date)
        case .every3Months:    return calendar.date(byAdding: .month, value: 3,  to: date)
        case .every4Months:    return calendar.date(byAdding: .month, value: 4,  to: date)
        case .twiceAYear:      return calendar.date(byAdding: .month, value: 6,  to: date)
        case .yearly:          return calendar.date(byAdding: .year,  value: 1,  to: date)
        case .everyOtherYear:  return calendar.date(byAdding: .year,  value: 2,  to: date)
        }
    }
}
