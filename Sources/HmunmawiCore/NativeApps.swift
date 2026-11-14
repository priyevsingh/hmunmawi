import Foundation

/// What Apple's public App Store listing says about an app in one storefront. (Apple's published Search API pages don't
/// list these fields or a country option for lookups; they are the fields the listing itself returns, checked live, and
/// the app treats a missing or odd answer as "no data", never as zero.)
public struct StoreListing: Sendable, Equatable {
    public var name: String?
    public var rating: Double
    public var count: Int
    public var version: String?

    public static func parse(_ data: Data) -> StoreListing? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (obj["results"] as? [[String: Any]])?.first,
              let rating = first["averageUserRating"] as? Double, rating > 0, rating <= 5,
              let count = first["userRatingCount"] as? Int, count > 0 else { return nil }
        return StoreListing(name: first["trackName"] as? String, rating: rating, count: count, version: first["version"] as? String)
    }
}

/// The app pages for people who have no script feed: an `app.snapshot` built here from what Hmunmawi's own add-ons
/// and public listing reads already produced. An app the feed already describes is left exactly as the feed has it.
public enum NativeApps {
    /// One `rating.snapshot` payload from per-storefront listings: the overall average (weighted by how many ratings each
    /// storefront has), the total, and the per-country figures the Reviews card shows.
    public static func ratingPayload(_ byCountry: [String: StoreListing], appID: String) -> JSONValue? {
        let total = byCountry.values.reduce(0) { $0 + $1.count }
        guard total > 0 else { return nil }
        let weighted = byCountry.values.reduce(0.0) { $0 + $1.rating * Double($1.count) } / Double(total)
        var ratings: [String: JSONValue] = [:], counts: [String: JSONValue] = [:]
        for (c, l) in byCountry { ratings[c.uppercased()] = .number(l.rating); counts[c.uppercased()] = .number(Double(l.count)) }
        var p: [String: JSONValue] = ["app_id": .string(appID), "rating": .number((weighted * 100).rounded() / 100), "ratings_count": .number(Double(total)),
                                      "ratings_by_country": .object(ratings), "ratings_count_by_country": .object(counts),
                                      // How many storefronts had ratings: a rating measured over a different set of storefronts is not comparable.
                                      "coverage": .number(Double(byCountry.count))]
        if let v = byCountry.values.compactMap(\.version).first { p["version"] = .string(v) }
        return .object(p)
    }

    public static func snapshots(events: [StoredEvent], short: (String) -> String, now: Date = .now) -> [StoredEvent] {
        let hub = Set(events.filter { $0.kind == "app.snapshot" }.compactMap { $0.app.map(short) })
        func latest(_ kind: String, _ app: String) -> StoredEvent? {
            events.filter { $0.kind == kind && $0.app.map(short) == app }.max { $0.occurredAt < $1.occurredAt }
        }
        let names = Set(events.filter { ["icon.snapshot", "versions.snapshot", "release.snapshot"].contains($0.kind) }.compactMap { $0.app.map(short) })
        let cal = Calendar(identifier: .gregorian)
        let cutoff = now.addingTimeInterval(-14 * 86_400)
        return names.subtracting(hub).sorted().compactMap { app -> StoredEvent? in
            var p: [String: JSONValue] = ["native": .bool(true)]
            if let live = events.filter({ $0.kind == "release.snapshot" && $0.app.map(short) == app })
                .sorted(by: { $0.occurredAt < $1.occurredAt }).compactMap({ $0.payload[path: "live_version"]?.string }).last { p["version"] = .string(live) }
            if let v = latest("versions.snapshot", app)?.payload[path: "versions"]?.array?.first {
                if p["version"] == nil, let n = v[path: "version"]?.string { p["version"] = .string(n) }
                if let s = v[path: "state"]?.string { p["version_state"] = .string(s) }
            }
            if let r = latest("rating.snapshot", app)?.payload {
                for k in ["rating", "ratings_count", "ratings_by_country", "ratings_count_by_country", "coverage"] { if let x = r[path: k] { p[k] = x } }
            }
            // Downloads: the sales add-on's daily units, one reading per day (newest wins), last 14 days.
            var days: [String: Double] = [:]
            for e in events.filter({ $0.kind == "revenue.daily" && $0.app.map(short) == app }).sorted(by: { $0.occurredAt < $1.occurredAt }) {
                if let d = e.payload[path: "day"]?.string { days[d] = e.payload[path: "units"]?.number ?? 0 }
            }
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
            let recent = days.filter { (f.date(from: $0.key) ?? .distantPast) >= cal.startOfDay(for: cutoff) }
            if !recent.isEmpty { p["downloads_14d"] = .number(recent.values.reduce(0, +)) }
            if let newest = days.keys.sorted().last { p["latest_sales_day"] = .string(newest); p["downloads_latest_day"] = .number(days[newest] ?? 0) }
            // An app that isn't on the App Store yet (no live version, no sales, no ratings) keeps its launch-track place
            // instead of becoming an empty page.
            let isLive = events.contains { $0.kind == "release.snapshot" && $0.app.map(short) == app && $0.payload[path: "live"] == .bool(true) }
            guard isLive || p["rating"] != nil || p["downloads_14d"] != nil else { return nil }
            // Each app needs its own id (screens tell apps apart by it; one shared id repeated one app's tab).
            // Negative and stable across launches, so it never meets a stored event's id.
            let stable = app.unicodeScalars.reduce(Int64(7)) { ($0 &* 31 &+ Int64($1.value)) % 1_000_000_007 }
            return StoredEvent(id: -stable - 1, source: "native", kind: "app.snapshot", app: app, payload: .object(p), occurredAt: Int64(now.timeIntervalSince1970 * 1000))
        }
    }
}
