import Foundation

/// The numbers for a shareable card over a week, month, quarter or the year so far, compared with the period
/// before. A period is offered only when the stored history covers it (Apple sends no daily report on days without
/// sales, so "covered" means the history starts on or before the period's first day, not "every day has a row").
public enum SharePeriod: String, CaseIterable, Sendable, Identifiable {
    case week = "Week", month = "Month", quarter = "Quarter", year = "Year so far"
    public var id: String { rawValue }
}

public struct PeriodStats: Sendable, Equatable {
    public struct App: Sendable, Equatable { public let name: String; public let downloads: Double; public let earnedUSD: Double }
    public struct Bucket: Sendable, Equatable { public let label: String; public let start: Date; public let earnedUSD: Double; public let downloads: Double }

    public let period: SharePeriod
    public let title: String                  // "week", "October", "Q3 2026", "2026 so far"
    public let span: (String, String)         // first and last day ("2026-10-01", "2026-10-31")
    public let earnedUSD: Double, downloads: Double
    public let earnedBeforeUSD: Double?, downloadsBefore: Double?   // nil when the period before isn't covered
    public let buckets: [Bucket]               // the chart: days, weeks or months
    public let apps: [App]
    public let mrrUSD: Double?, mrrBeforeUSD: Double?, paying: Int?, payingBefore: Int?
    /// The apps the card is about when it isn't all of them (shown in the heading and caption).
    public var subject: [String]? = nil
    public var isEmpty: Bool { earnedUSD == 0 && downloads == 0 && (mrrUSD ?? 0) == 0 }
    /// The busiest chart bucket (most downloads, then most earned); nil when nothing happened.
    public var peak: Bucket? {
        buckets.filter { $0.downloads > 0 || $0.earnedUSD > 0 }.max { ($0.downloads, $0.earnedUSD) < ($1.downloads, $1.earnedUSD) }
    }

    public static func == (a: PeriodStats, b: PeriodStats) -> Bool {
        a.period == b.period && a.subject == b.subject && a.title == b.title && a.span == b.span && a.earnedUSD == b.earnedUSD && a.downloads == b.downloads
    }

    public static func change(_ now: Double, _ before: Double?) -> Double? { before.flatMap { $0 > 0 ? (now - $0) / $0 : nil } }
    public var earnedChange: Double? { Self.change(earnedUSD, earnedBeforeUSD) }
    public var downloadsChange: Double? { Self.change(downloads, downloadsBefore) }
    public var mrrChange: Double? { mrrUSD.flatMap { Self.change($0, mrrBeforeUSD) } }
    public var best: App? { apps.first { $0.downloads > 0 || $0.earnedUSD > 0 } }

    static let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    static func day(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = utc.timeZone; f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }
    static func date(_ s: String) -> Date? { MRRModel.date(s) }

    /// The period's days (first, last) and the period before's, or nil when the history doesn't cover it.
    /// `latest`: the newest reported day; `earliest`: the oldest stored day.
    static func ranges(_ p: SharePeriod, latest: Date, earliest: Date) -> (cur: (Date, Date), prev: (Date, Date)?, title: String)? {
        let cal = utc
        func add(_ c: Calendar.Component, _ n: Int, _ d: Date) -> Date { cal.date(byAdding: c, value: n, to: d)! }
        var cur: (Date, Date), prev: (Date, Date), title: String
        switch p {
        case .week:
            cur = (add(.day, -6, latest), latest); prev = (add(.day, -13, latest), add(.day, -7, latest)); title = "week"
        case .month:
            // The last full calendar month (the current one isn't over).
            let thisStart = cal.date(from: cal.dateComponents([.year, .month], from: latest))!
            let lastDayOfMonth = add(.day, -1, add(.month, 1, thisStart))
            let start = latest >= lastDayOfMonth ? thisStart : add(.month, -1, thisStart)
            cur = (start, add(.day, -1, add(.month, 1, start))); prev = (add(.month, -1, start), add(.day, -1, start))
            title = start.formatted(Date.FormatStyle(timeZone: cal.timeZone).month(.wide))
        case .quarter:
            let m = cal.component(.month, from: latest), y = cal.component(.year, from: latest)
            let qStart = cal.date(from: DateComponents(year: y, month: (m - 1) / 3 * 3 + 1, day: 1))!
            let qEnd = add(.day, -1, add(.month, 3, qStart))
            let start = latest >= qEnd ? qStart : add(.month, -3, qStart)
            cur = (start, add(.day, -1, add(.month, 3, start))); prev = (add(.month, -3, start), add(.day, -1, start))
            let q = (cal.component(.month, from: start) - 1) / 3 + 1
            title = "Q\(q) \(cal.component(.year, from: start))"
        case .year:
            let y = cal.component(.year, from: latest)
            let start = cal.date(from: DateComponents(year: y, month: 1, day: 1))!
            cur = (start, latest)
            prev = (cal.date(from: DateComponents(year: y - 1, month: 1, day: 1))!, add(.year, -1, latest))
            title = "\(y) so far"
        }
        guard earliest <= cur.0 else { return nil }
        return (cur, earliest <= prev.0 ? prev : nil, title)
    }

    /// Which periods the history covers (in order).
    /// `bounds`: the account's first and last report day, when `daily` is only some apps' rows (an app's own
    /// history starts at its first sale, but every card ends on the account's latest day).
    public static func available(daily: [StoredEvent], bounds: (Date, Date)? = nil) -> [SharePeriod] {
        guard let (lo, hi) = coverage(daily, bounds) else { return [] }
        return SharePeriod.allCases.filter { ranges($0, latest: hi, earliest: lo) != nil }
    }

    /// `daily`: revenue.daily rows, one sender per app and day. `mrr`: daily MRR points, oldest first.
    /// The first and last day covered: the rows' own span, or (with `bounds`) from the later of the account's first
    /// day and the rows' first day, to the account's last day.
    public static func coverage(_ daily: [StoredEvent], _ bounds: (Date, Date)?) -> (Date, Date)? {
        let days = daily.filter { $0.kind == "revenue.daily" }.compactMap { $0.payload[path: "day"]?.string }.compactMap(date)
        guard let lo = days.min(), let hi = days.max() else { return nil }
        guard let b = bounds else { return (lo, hi) }
        return (max(lo, b.0), b.1)
    }

    public static func make(_ p: SharePeriod, daily: [StoredEvent], mrr: [MRRModel.Point], bounds: (Date, Date)? = nil) -> PeriodStats? {
        let rows = daily.filter { $0.kind == "revenue.daily" }
        let dated = rows.compactMap { r -> (Date, StoredEvent)? in r.payload[path: "day"]?.string.flatMap(date).map { ($0, r) } }
        guard let (lo, hi) = coverage(rows, bounds), let r = ranges(p, latest: hi, earliest: lo) else { return nil }
        func inRange(_ d: Date, _ x: (Date, Date)) -> Bool { d >= x.0 && d <= x.1 }
        let cur = dated.filter { inRange($0.0, r.cur) }
        func sum(_ list: [(Date, StoredEvent)], _ f: String) -> Double { list.compactMap { $0.1.payload[path: f]?.number }.reduce(0, +) }
        let prev = r.prev.map { pr in dated.filter { inRange($0.0, pr) } }
        // Chart buckets: days (week, month), weeks (quarter), months (year).
        var buckets: [Bucket] = []
        let cal = utc
        var b = r.cur.0
        while b <= r.cur.1 {
            let next: Date, label: String
            switch p {
            case .week, .month:
                next = cal.date(byAdding: .day, value: 1, to: b)!
                label = p == .week ? String(b.formatted(Date.FormatStyle(timeZone: cal.timeZone).weekday(.abbreviated)).prefix(2))
                    : (cal.component(.day, from: b) % 7 == 1 ? "\(cal.component(.day, from: b))" : "")
            case .quarter:
                next = cal.date(byAdding: .day, value: 7, to: b)!
                label = cal.component(.day, from: b) <= 7 ? String(b.formatted(Date.FormatStyle(timeZone: cal.timeZone).month(.abbreviated))) : ""
            case .year:
                next = cal.date(byAdding: .month, value: 1, to: b)!
                label = String(b.formatted(Date.FormatStyle(timeZone: cal.timeZone).month(.narrow)))
            }
            // A quarter's weeks leave a day or few at the end (13 weeks = 91 days, quarters are 90-92): those join
            // the last full week instead of drawing a sliver that looks like a collapse.
            var end = next
            if p == .quarter, let after = cal.date(byAdding: .day, value: 7, to: next), after > cal.date(byAdding: .day, value: 1, to: r.cur.1)!,
               next <= r.cur.1 { end = cal.date(byAdding: .day, value: 1, to: r.cur.1)! }
            let inB = cur.filter { $0.0 >= b && $0.0 < end }
            buckets.append(Bucket(label: label, start: b, earnedUSD: sum(inB, "proceeds_usd"), downloads: sum(inB, "units")))
            b = end
        }
        var byApp: [String: (Double, Double)] = [:]
        for (_, e) in cur {
            var v = byApp[e.app ?? "Your app"] ?? (0, 0)
            v.0 += e.payload[path: "units"]?.number ?? 0; v.1 += e.payload[path: "proceeds_usd"]?.number ?? 0
            byApp[e.app ?? "Your app"] = v
        }
        let apps = byApp.map { App(name: $0.key, downloads: $0.value.0, earnedUSD: $0.value.1) }
            .sorted { ($0.downloads, $0.earnedUSD, $0.name) > ($1.downloads, $1.earnedUSD, $1.name) }
        let endDay = day(r.cur.1), startDay = day(r.cur.0)
        let atEnd = mrr.last { $0.day <= endDay }
        // MRR before: at the period's start (only if MRR history reaches back that far).
        let atStart = mrr.first.flatMap { $0.day <= startDay ? mrr.last { $0.day <= startDay } : nil }
        return PeriodStats(period: p, title: r.title, span: (startDay, endDay),
                           earnedUSD: sum(cur, "proceeds_usd"), downloads: sum(cur, "units"),
                           earnedBeforeUSD: prev.map { sum($0, "proceeds_usd") }, downloadsBefore: prev.map { sum($0, "units") },
                           buckets: buckets, apps: apps, mrrUSD: atEnd?.mrr, mrrBeforeUSD: atStart?.mrr,
                           paying: atEnd?.active, payingBefore: atStart?.active)
    }
}
