import Foundation
import Money
import Models

/// Forecasts a daily cash-position curve for the union of cash-like accounts
/// over a horizon (default 90 days), applying expanded scheduled transactions.
public struct CashPositionProjector: Sendable {
    public let calendar: Calendar

    public init(calendar: Calendar = Calendar(identifier: .gregorian)) {
        self.calendar = calendar
    }

    public struct AlertPoint: Sendable, Hashable, Identifiable {
        public var id: Date { date }
        public let date: Date
        public let balance: Money
        public let kind: Kind
        public enum Kind: String, Sendable, Hashable { case dip; case overdraft }
    }

    public struct Result: Sendable, Hashable {
        public let points: [CashPositionPoint]
        public let alerts: [AlertPoint]
    }

    public func project(
        cashAccounts: [AccountSnapshot],
        scheduled: [ScheduledTransactionSummary],
        asOf today: Date,
        horizonDays: Int = 90,
        dipThreshold: Money = Money.dollars(500)
    ) -> Result {
        let start = calendar.startOfDay(for: today)
        guard let end = calendar.date(byAdding: .day, value: horizonDays, to: start) else {
            return Result(points: [], alerts: [])
        }

        let cashIds = Set(cashAccounts.map(\.id))
        var balance = cashAccounts.map(\.balance).sum()

        var occurrencesByDay: [Date: Money] = [:]
        for sched in scheduled where !sched.deleted && cashIds.contains(sched.accountId) {
            for occ in sched.occurrences(from: start, through: end, calendar: calendar) {
                let day = calendar.startOfDay(for: occ)
                occurrencesByDay[day, default: .zero] += sched.amount
            }
        }

        var points: [CashPositionPoint] = []
        var alerts: [AlertPoint] = []
        var cursor = start
        while cursor <= end {
            if let delta = occurrencesByDay[cursor] {
                balance += delta
            }
            points.append(CashPositionPoint(date: cursor, balance: balance))
            if balance < .zero {
                alerts.append(AlertPoint(date: cursor, balance: balance, kind: .overdraft))
            } else if balance < dipThreshold {
                alerts.append(AlertPoint(date: cursor, balance: balance, kind: .dip))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        return Result(points: points, alerts: alerts)
    }
}
