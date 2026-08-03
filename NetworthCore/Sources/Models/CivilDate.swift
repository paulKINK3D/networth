import Foundation

/// Helpers for "civil" calendar dates — plain `yyyy-MM-dd` values from YNAB
/// and Plaid that carry no time or timezone. The app anchors them to local
/// midnight at parse time so device-calendar bucketing and display land on
/// the same day the provider reported.
public enum CivilDate {
    /// Re-anchors a date that was persisted under the old convention
    /// (parsed at midnight UTC) onto the same civil day at the target
    /// calendar's midnight. Returns `nil` when the value is not exactly
    /// midnight UTC — already re-anchored, or a real instant — which makes
    /// cache-repair passes idempotent.
    public static func reanchoredFromUTCMidnight(
        _ date: Date,
        to calendar: Calendar = .current
    ) -> Date? {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = utc.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: date
        )
        guard parts.hour == 0, parts.minute == 0, parts.second == 0,
              parts.nanosecond == 0 else { return nil }
        var civilDay = DateComponents()
        civilDay.year = parts.year
        civilDay.month = parts.month
        civilDay.day = parts.day
        guard let reanchored = calendar.date(from: civilDay),
              reanchored != date else { return nil }
        return reanchored
    }
}
