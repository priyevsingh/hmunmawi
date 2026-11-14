import Foundation

public struct AppSummary: Sendable, Equatable, Identifiable {
    public var name: String
    /// "Downloads" (Apple's daily report units), "Sales" (live purchases) or "Daily users", whichever it has.
    public var metric: String
    /// Seven daily values, oldest first.
    public var daily: [Double]
    /// The most recent day that has data (daily sales reports lag a day or two).
    public var latest: Double
    public var caption: String
    public var reviewCount: Int
    public var averageRating: Double?
    public var id: String { name }
}

public enum SummaryBuilder {
    public static func apps(events: [StoredEvent], now: Millis) -> [AppSummary] {
        let day = TodayBuilder.day
        let weekStart = now - 7 * day
        // One row per app and day (two senders report the same day, stamped at different hours).
        let week = DailyEvents.oneSourcePerDay(events.filter { $0.occurredAt > weekStart && $0.occurredAt <= now })
        let names = Set(week.compactMap(\.app))

        func dayIndex(_ t: Millis) -> Int { max(0, min(6, Int((t - weekStart - 1) / day))) }
        // Daily figures go in the slot of the day they describe (their "day"), never by the hour they were stamped:
        // by hour, one day landed twice and the day before vanished for part of each day.
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let today = utc.startOfDay(for: Date(timeIntervalSince1970: Double(now) / 1000))
        func slot(_ e: StoredEvent) -> Int {
            guard let d = e.payload[path: "day"]?.string, let date = try? Date(String(d.prefix(10)) + "T00:00:00Z", strategy: .iso8601) else {
                return dayIndex(e.occurredAt)
            }
            // A label that doesn't fall in these 7 days (a sender's own day naming) keeps the time slot it was stamped in.
            guard let back = utc.dateComponents([.day], from: utc.startOfDay(for: date), to: today).day, (0...6).contains(back) else {
                return dayIndex(e.occurredAt)
            }
            return 6 - back
        }

        return names.compactMap { name -> AppSummary? in
            let mine = week.filter { $0.app == name }
            var reported = [Double?](repeating: nil, count: 7)
            var live = [Double](repeating: 0, count: 7)
            var users = [Double?](repeating: nil, count: 7)
            var reportedDay: String?
            for event in mine {
                let i = dayIndex(event.occurredAt)
                switch event.kind {
                case "revenue.daily":
                    let i = slot(event)
                    reported[i] = event.payload[path: "units"]?.number ?? 0
                    reportedDay = event.payload[path: "day"]?.string ?? reportedDay
                case "revenue.purchase", "revenue.renewal":
                    live[i] += 1
                case "analytics.daily_users":
                    let i = slot(event)
                    users[i] = event.payload[path: "users"]?.number ?? 0
                default:
                    break
                }
            }
            let ratings = mine.filter { $0.kind == "review.new" }.compactMap { $0.payload[path: "rating"]?.number }
            let rating = ratings.isEmpty ? nil : ratings.reduce(0, +) / Double(ratings.count)

            func summary(_ metric: String, _ series: [Double], _ latest: Double, _ caption: String) -> AppSummary {
                AppSummary(name: name, metric: metric, daily: series, latest: latest, caption: caption,
                           reviewCount: ratings.count, averageRating: rating)
            }
            if let last = reported.lastIndex(where: { $0 != nil }), let value = reported[last] {
                return summary("Downloads", reported.map { $0 ?? 0 }, value, "downloads on \(Self.shortDay(reportedDay))")
            }
            if live.contains(where: { $0 > 0 }) {
                return summary("Sales", live, live[6], "sales today")
            }
            if let last = users.lastIndex(where: { $0 != nil }), let value = users[last] {
                return summary("Daily users", users.map { $0 ?? 0 }, value, "users yesterday")
            }
            guard !ratings.isEmpty else { return nil }
            return summary("Sales", live, 0, "no sales data")
        }
        .sorted { ($0.daily.reduce(0, +), $0.name) > ($1.daily.reduce(0, +), $1.name) }
    }

    private static func shortDay(_ day: String?) -> String {
        guard let day, let date = try? Date(day + "T12:00:00Z", strategy: .iso8601) else { return "the latest day" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

extension Store {
    public func appSummaries() throws -> [AppSummary] {
        appSummaries(recent: try events(since: now() - 8 * TodayBuilder.day))
    }

    /// The same summaries from events already in memory (at least the last 8 days, oldest first).
    public func appSummaries(recent: [StoredEvent]) -> [AppSummary] {
        let t = now()
        return SummaryBuilder.apps(events: recent.filter { $0.occurredAt > t - 8 * TodayBuilder.day }, now: t)
    }
}
