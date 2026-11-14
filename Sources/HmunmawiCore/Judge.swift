import Foundation

/// A change you made (a new title, a price, screenshots, a language) and the number that should show whether it
/// helped. After `days`, the judge compares the average day before the change with the average day after.
public struct WatchedChange: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var what: String
    public var metric: String          // a Metric key ("history.series|My App|downloads")
    public var metricName: String?     // shown to people ("Downloads · My App")
    public var date: String            // the day the change went live, YYYY-MM-DD
    public var days: Int               // how long to wait before judging (and how far back to compare)
    public var better: String?         // "up" or "down"; nil = the metric's own direction
    public var verdict: String?        // keep | improve | undo | unclear (nil while watching)
    public var note: String?
    public var judgedOn: String?
    /// The average day before the change and how many days it covers, saved when the change is registered:
    /// some numbers keep only a month of history, so by judging time the "before" days may be gone.
    public var before: Double?
    public var beforeDays: Int?
    public init(id: String, what: String, metric: String, metricName: String? = nil, date: String, days: Int = 28, better: String? = nil) {
        self.id = id; self.what = what; self.metric = metric; self.metricName = metricName; self.date = date; self.days = days; self.better = better
    }

    /// The day it can be judged: the day after its last "after" day, so a partial today is never counted.
    public var dueDay: Int? { DayNumber.of(date).map { $0 + days + 1 } }
}

public enum Judge {
    public enum Verdict: String, Sendable { case keep, improve, undo, unclear }

    public struct Result: Sendable, Equatable {
        public let verdict: Verdict
        public let before: Double      // average per day before
        public let after: Double       // average per day after
        public let change: Double      // after vs before, as a fraction (+0.12 = 12% more)
        public let daysBefore: Int
        public let daysAfter: Int
    }

    /// The average of the days in `from..<to` (day numbers) and how many there were.
    public static func average(_ points: [(day: Date, value: Double)], from: Int, to: Int, calendar: Calendar) -> (avg: Double, days: Int) {
        var v: [Double] = []
        for p in points {
            let c = calendar.dateComponents([.year, .month, .day], from: p.day)
            guard let d = DayNumber.of(String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)), d >= from, d < to else { continue }
            v.append(p.value)
        }
        return (v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count), v.count)
    }

    /// Keep when it moved the good way by at least `keepAt` (default 5%), undo when it moved the bad way by at
    /// least `undoAt` (10%), improve in between ("no clear effect: try a stronger version"). Unclear when either
    /// side has fewer than half the days, or the "before" average is zero (no base to compare with).
    /// The change day itself counts in neither side.
    public static func judge(_ points: [(day: Date, value: Double)], changeDay: String, days: Int, betterUp: Bool,
                             calendar: Calendar, saved: (avg: Double, days: Int)? = nil,
                             keepAt: Double = 0.05, undoAt: Double = 0.10) -> Result {
        guard let c = DayNumber.of(changeDay) else { return Result(verdict: .unclear, before: 0, after: 0, change: 0, daysBefore: 0, daysAfter: 0) }
        var before = average(points, from: c - days, to: c, calendar: calendar)
        // The saved "before" wins when the history no longer holds as many of those days.
        if let saved, saved.days > before.days { before = saved }
        let after = average(points, from: c + 1, to: c + days + 1, calendar: calendar)
        let b = before.avg, a = after.avg
        let enough = before.days * 2 >= days && after.days * 2 >= days && b != 0
        let change = b == 0 ? 0 : (a - b) / abs(b)
        let good = betterUp ? change : -change
        let verdict: Verdict = !enough ? .unclear : good >= keepAt ? .keep : good <= -undoAt ? .undo : .improve
        return Result(verdict: verdict, before: b, after: a, change: change, daysBefore: before.days, daysAfter: after.days)
    }
}
