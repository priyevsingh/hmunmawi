import Foundation

/// When a routine is due. A routine runs at a time of day ("08:37") on some weekdays (none listed = every day), or
/// every N minutes counted from midnight. A run is due when its scheduled time has passed and it's still inside its
/// catch-up window (the Mac was asleep or the app closed at the time); older ones count as missed.
public enum RoutineSchedule {
    public static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]   // Calendar weekday 1...7

    /// "08:37" -> (8, 37); nil for anything that isn't a valid 24-hour time.
    public static func time(_ s: String?) -> (hour: Int, minute: Int)? {
        guard let s else { return nil }
        let p = s.split(separator: ":", omittingEmptySubsequences: false)
        guard p.count == 2, p[0].count <= 2, p[1].count == 2, let h = Int(p[0]), let m = Int(p[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return (h, m)
    }

    /// "04:00,10:00, 16:00" → the valid times, sorted and without repeats (at most 24).
    public static func times(_ s: String?) -> [(hour: Int, minute: Int)] {
        guard let s else { return [] }
        let all = s.split(separator: ",").compactMap { time($0.trimmingCharacters(in: .whitespaces)) }
        var seen = Set<Int>()
        return all.filter { seen.insert($0.hour * 60 + $0.minute).inserted }.sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }.prefix(24).map { $0 }
    }

    /// Scheduled times after `after` and up to `upTo` (both in the calendar's time zone), oldest first.
    /// `days` uses "Mon"…"Sun"; empty means every day. At most `limit` times.
    public static func slots(at: String?, everyMinutes: Int?, days: [String], after: Date, upTo: Date,
                             calendar: Calendar, limit: Int = 500) -> [Date] {
        guard upTo > after else { return [] }
        let allowed = Set(days.map { String($0.prefix(3)) })
        func dayOK(_ d: Date) -> Bool {
            allowed.isEmpty || allowed.contains(weekdays[calendar.component(.weekday, from: d) - 1])
        }
        var out: [Date] = []
        var day = calendar.startOfDay(for: after)
        let lastDay = calendar.startOfDay(for: upTo)
        while day <= lastDay, out.count < limit {
            if dayOK(day) {
                if let every = everyMinutes, every > 0 {
                    var m = 0
                    while m < 24 * 60, out.count < limit {
                        // Built from hour and minute (not seconds since midnight), so daylight-saving days keep their clock times.
                        if let t = calendar.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: day),
                           calendar.isDate(t, inSameDayAs: day), t > after, t <= upTo { out.append(t) }
                        m += every
                    }
                } else {
                    // One time ("08:37") or several, comma-separated ("04:00,10:00,16:00,22:00").
                    for (h, m) in times(at) {
                        if let t = calendar.date(bySettingHour: h, minute: m, second: 0, of: day), t > after, t <= upTo { out.append(t) }
                    }
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return out
    }

    /// The newest scheduled time inside the catch-up window ending `now`, or nil. `catchUpMinutes` 0 means only
    /// the current minute counts.
    public static func due(at: String?, everyMinutes: Int?, days: [String], now: Date, catchUpMinutes: Int,
                           calendar: Calendar) -> Date? {
        let window = TimeInterval(max(1, catchUpMinutes) * 60)
        return slots(at: at, everyMinutes: everyMinutes, days: days, after: now.addingTimeInterval(-window), upTo: now,
                     calendar: calendar).last
    }

    /// When a job's result is overdue today: its time today plus `lateMinutes`, once `now` has passed it, on one
    /// of its days. A deadline that would fall on the next day is never reported (a late-night job isn't chased).
    public static func overdue(at: String, days: [String], lateMinutes: Int, now: Date, calendar: Calendar) -> Date? {
        guard lateMinutes > 0, let t = time(at) else { return nil }
        let wd = weekdays[calendar.component(.weekday, from: now) - 1]
        guard days.isEmpty || days.contains(wd),
              let start = calendar.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: now) else { return nil }
        let due = start.addingTimeInterval(Double(lateMinutes) * 60)
        return now >= due && calendar.isDate(due, inSameDayAs: start) ? due : nil
    }

    /// A stable key for one scheduled run ("site-watch@2026-11-03T08:30"), used to store each run once.
    public static func key(_ id: String, _ slot: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: slot)
        return String(format: "%@@%04d-%02d-%02dT%02d:%02d", id, c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }
}
