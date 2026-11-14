import Foundation

/// Monthly recurring revenue and where it's heading, from the daily `subscription.mrr` rows
/// (active full-price subscriptions and their monthly value, per app and report day).
public enum MRRModel {
    public struct Point: Sendable, Equatable {
        public let day: String          // "2026-11-01"
        public let mrr: Double          // per month, after Apple's cut (USD)
        public let gross: Double        // per month, customer prices (USD)
        public let active: Int
        public init(day: String, mrr: Double, gross: Double, active: Int) {
            self.day = day; self.mrr = mrr; self.gross = gross; self.active = active
        }
    }

    public struct Projection: Sendable, Equatable {
        public let now: Double
        public let in30: ClosedRange<Double>
        public let in90: ClosedRange<Double>
        /// Per month, from the history: new paid subscriptions, lost ones, and the share lost.
        public let gainsPerMonth: Double
        public let lossesPerMonth: Double
        public let churnRate: Double
        /// Under 30 active subscriptions one cancellation moves everything: say the projection is rough.
        public let rough: Bool
        public let historyDays: Int
    }

    /// Days of history needed before projecting at all.
    public static let minimumDays = 14

    /// One app's (or all apps') daily points, oldest first, one per day.
    public static func series(_ rows: [(day: String, mrr: Double, gross: Double, active: Int)]) -> [Point] {
        var byDay: [String: Point] = [:]
        for r in rows { byDay[r.day] = Point(day: r.day, mrr: r.mrr, gross: r.gross, active: r.active) }
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// Adds apps together per day. Apple's Subscription report covers the whole account, so on a day any app
    /// reported, an app without a row had no subscriptions that day: it counts as 0.
    public static func total(_ perApp: [[Point]]) -> [Point] {
        let apps = perApp.filter { !$0.isEmpty }
        guard !apps.isEmpty else { return [] }
        return Set(apps.flatMap { $0.map(\.day) }).sorted().map { day in
            let pts = apps.compactMap { $0.first { $0.day == day } }
            return Point(day: day, mrr: pts.map(\.mrr).reduce(0, +), gross: pts.map(\.gross).reduce(0, +),
                         active: pts.map(\.active).reduce(0, +))
        }
    }

    /// Fills the days an app has no row on (within the account's reported days) with 0.
    public static func filled(_ points: [Point], days: [String]) -> [Point] {
        let have = Dictionary(points.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        return days.map { have[$0] ?? Point(day: $0, mrr: 0, gross: 0, active: 0) }
    }

    static func date(_ day: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: day)
    }

    /// Where MRR is heading: each month it keeps (1 − churn) of itself and adds the new subscriptions' value.
    /// Gains and losses come from changes in active subscriptions, smoothed over a week so daily wobble doesn't
    /// count as churn (a day with both shows only the net); the range is the projection from the last 30 days and from the last 60.
    public static func project(_ points: [Point]) -> Projection? {
        guard let last = points.last, points.count >= minimumDays else { return nil }
        func run(_ window: ArraySlice<Point>) -> (in30: Double, in90: Double, gains: Double, losses: Double, churn: Double)? {
            let w = Array(window)
            guard w.count >= minimumDays else { return nil }
            // Apple's daily count wobbles (15 -> 12 -> 14 -> 15 is no change, not 3 lost and 3 won): gains and losses
            // are counted on a 7-day running median, so only lasting moves count.
            let active = w.map { Double($0.active) }
            let smooth = active.indices.map { i -> Double in
                let s = active[max(0, i - 6)...i].sorted()
                return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
            }
            var gains = 0.0, losses = 0.0
            for (a, b) in zip(smooth, smooth.dropFirst()) {
                let d = b - a
                if d > 0 { gains += d } else { losses -= d }
            }
            // Time from the dates themselves (a day never fetched is a gap, not a shorter month).
            var span = Double(w.count - 1)
            if let a = w.first.flatMap({ date($0.day) }), let b = w.last.flatMap({ date($0.day) }) { span = b.timeIntervalSince(a) / 86_400 }
            let months = max(1, span) / 30.4375
            let avgActive = w.map { Double($0.active) }.reduce(0, +) / Double(w.count)
            let gainsPM = gains / months, lossesPM = losses / months
            let churn = avgActive > 0 ? min(1, lossesPM / avgActive) : 0
            let arpu = last.active > 0 ? last.mrr / Double(last.active)
                : (w.last { $0.active > 0 }.map { $0.mrr / Double($0.active) } ?? 0)
            let newPM = gainsPM * arpu
            func after(_ m: Double) -> Double {
                // Month by month (fractional last step), never below zero.
                var v = last.mrr, left = m
                while left > 0 { let step = min(1, left); v = max(0, v * (1 - churn * step) + newPM * step); left -= step }
                return v
            }
            return (after(1), after(90 / 30.4375), gainsPM, lossesPM, churn)
        }
        let n = points.count
        guard let long = run(points.suffix(min(n, 61))) else { return nil }
        let short = run(points.suffix(min(n, 31))) ?? long
        func range(_ a: Double, _ b: Double) -> ClosedRange<Double> { min(a, b)...max(a, b) }
        return Projection(now: last.mrr, in30: range(long.in30, short.in30), in90: range(long.in90, short.in90),
                          gainsPerMonth: long.gains, lossesPerMonth: long.losses, churnRate: long.churn,
                          rough: last.active < 30, historyDays: min(n, 61))
    }
}
