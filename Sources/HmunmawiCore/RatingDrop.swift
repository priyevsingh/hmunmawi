import Foundation

/// A fall in an app's average star rating, found by comparing today's snapshot with the one about a week earlier.
public struct RatingDrop: Sendable, Equatable {
    public var app: String
    public var from: Double, to: Double
    public var days: Int
    public var newRatings: Int

    /// `snapshots`: the app's `app.snapshot` events (any order; payload has `rating` and `ratings_count`).
    /// A drop is reported when the average fell by at least `threshold` stars over about `window` days AND at least
    /// `minNew` ratings arrived in that time (one stray rating on a small count isn't a trend). Returns nil otherwise.
    public static func detect(app: String, snapshots: [StoredEvent], now: Date = .now, window: Int = 7,
                              threshold: Double = 0.2, minNew: Int = 2) -> RatingDrop? {
        let rows = snapshots.compactMap { e -> (at: Date, rating: Double, count: Int, coverage: Int?)? in
            guard let r = e.payload[path: "rating"]?.number, r > 0, r <= 5 else { return nil }
            return (Date(timeIntervalSince1970: Double(e.occurredAt) / 1000), r, Int(safe: e.payload[path: "ratings_count"]?.number ?? 0),
                    e.payload[path: "coverage"]?.number.map { Int(safe: $0) })
        }.sorted { $0.at < $1.at }
        guard let latest = rows.last, now.timeIntervalSince(latest.at) < 3 * 86_400 else { return nil }   // stale data says nothing about now
        // The snapshot closest to `window` days before the latest, at least window-2 days older.
        let target = latest.at.addingTimeInterval(-Double(window) * 86_400)
        // Readings made over a different set of storefronts (a `coverage` that differs) can't be compared with today's.
        guard let base = rows.filter({ latest.at.timeIntervalSince($0.at) >= Double(window - 2) * 86_400 && ($0.coverage == nil || latest.coverage == nil || $0.coverage == latest.coverage) })
            .min(by: { abs($0.at.timeIntervalSince(target)) < abs($1.at.timeIntervalSince(target)) }) else { return nil }
        let fell = ((base.rating - latest.rating) * 100).rounded() / 100
        let added = latest.count - base.count
        guard fell >= threshold - 0.0001, added >= minNew else { return nil }
        return RatingDrop(app: app, from: base.rating, to: latest.rating, days: Int((latest.at.timeIntervalSince(base.at) / 86_400).rounded()), newRatings: added)
    }

    /// "Pulse Diary: rating fell from 4.6 to 4.3 in 7 days (5 new ratings)".
    public var title: String {
        "\(app): rating fell from \(String(format: "%.1f", from)) to \(String(format: "%.1f", to)) in \(days) day\(days == 1 ? "" : "s") (\(newRatings) new rating\(newRatings == 1 ? "" : "s"))"
    }
}
