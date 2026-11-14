import Foundation

/// One week's numbers, shared by the weekly digest and the shareable card so the two never disagree. The week is
/// Apple's last 7 reported days (daily reports arrive a day or two late), compared with the 7 before.
public struct WeeklyStats: Sendable, Equatable {
    public struct App: Sendable, Equatable {
        public let name: String
        public let downloads: Double
        public let earnedUSD: Double
    }
    public let days: [String]                 // the 7 report days, oldest first ("2026-10-27"…)
    public let earnedUSD: Double, earnedBeforeUSD: Double
    public let downloads: Double, downloadsBefore: Double
    public let dailyEarnedUSD: [Double]       // per day, same order as `days`
    public let dailyDownloads: [Double]
    public let apps: [App]                    // this week, most downloads first
    public let mrrUSD: Double?, mrrWeekAgoUSD: Double?
    public let paying: Int?, payingWeekAgo: Int?

    /// Change as a fraction (0.12 = +12%); nil when there's nothing to compare with.
    public static func change(_ now: Double, _ before: Double) -> Double? { before > 0 ? (now - before) / before : nil }
    public var earnedChange: Double? { Self.change(earnedUSD, earnedBeforeUSD) }
    public var downloadsChange: Double? { Self.change(downloads, downloadsBefore) }
    public var mrrChange: Double? { mrrWeekAgoUSD.flatMap { Self.change(mrrUSD ?? 0, $0) } }
    public var best: App? { apps.first { $0.downloads > 0 || $0.earnedUSD > 0 } }

    /// `daily`: revenue.daily rows, one sender per app and day (DailyEvents.oneSourcePerDay). `mrr`: the account's
    /// daily MRR points (all apps or the chosen ones), oldest first. `weeksBack`: 0 = the latest week, 1 = the one before.
    public static func make(daily: [StoredEvent], mrr: [MRRModel.Point], weeksBack: Int = 0) -> WeeklyStats? {
        let rows = daily.filter { $0.kind == "revenue.daily" }
        let all = Array(Set(rows.compactMap { $0.payload[path: "day"]?.string })).sorted()
        let end = all.count - 7 * max(0, weeksBack)
        guard end > 0 else { return nil }
        let days = Array(all[max(0, end - 7)..<end])
        let before = Set(all[max(0, end - 14)..<max(0, end - 7)])
        let week = Set(days)
        func sum(_ set: Set<String>, _ field: String) -> Double {
            rows.filter { set.contains($0.payload[path: "day"]?.string ?? "") }.compactMap { $0.payload[path: field]?.number }.reduce(0, +)
        }
        func perDay(_ field: String) -> [Double] {
            days.map { d in rows.filter { $0.payload[path: "day"]?.string == d }.compactMap { $0.payload[path: field]?.number }.reduce(0, +) }
        }
        var byApp: [String: (Double, Double)] = [:]
        for r in rows where week.contains(r.payload[path: "day"]?.string ?? "") {
            let name = r.app ?? "Your app"
            var v = byApp[name] ?? (0, 0)
            v.0 += r.payload[path: "units"]?.number ?? 0
            v.1 += r.payload[path: "proceeds_usd"]?.number ?? 0
            byApp[name] = v
        }
        let apps = byApp.map { App(name: $0.key, downloads: $0.value.0, earnedUSD: $0.value.1) }
            .sorted { ($0.downloads, $0.earnedUSD, $0.name) > ($1.downloads, $1.earnedUSD, $1.name) }
        // MRR at the week's last day and 7 days before it.
        let lastDay = days.last ?? ""
        let weekAgoDay: String = {
            guard let d = MRRModel.date(lastDay), let w = Calendar(identifier: .gregorian).date(byAdding: .day, value: -7, to: d) else { return "" }
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
            return f.string(from: w)
        }()
        let atEnd = mrr.last { $0.day <= lastDay }, atStart = mrr.last { $0.day <= weekAgoDay }
        return WeeklyStats(days: days, earnedUSD: sum(week, "proceeds_usd"), earnedBeforeUSD: sum(before, "proceeds_usd"),
                           downloads: sum(week, "units"), downloadsBefore: sum(before, "units"),
                           dailyEarnedUSD: perDay("proceeds_usd"), dailyDownloads: perDay("units"), apps: apps,
                           mrrUSD: atEnd?.mrr, mrrWeekAgoUSD: atStart?.mrr, paying: atEnd?.active, payingWeekAgo: atStart?.active)
    }
}
