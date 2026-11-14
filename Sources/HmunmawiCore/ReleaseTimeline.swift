import Foundation

/// One app's versions, newest first, with what the numbers did around the moment each one went live.
/// Apple's version list has no go-live date, so Hmunmawi notes it itself: the time it first saw the live version change
/// (accurate to its check interval, an hour). Versions that went live before Hmunmawi was watching have no such time and
/// are shown without a "what moved" line, never with a guess.
public struct ReleaseEntry: Sendable, Equatable {
    public struct Effect: Sendable, Equatable {
        public var downloadsBefore: Double, downloadsAfter: Double      // per day
        public var proceedsBefore: Double, proceedsAfter: Double        // USD per day
        public var daysAfter: Int
        public var complete: Bool                                       // the full window has passed
    }
    public var version: String
    public var state: String?
    public var created: Date?
    public var liveSeenAt: Date?
    public var effect: Effect?

    /// "First-time downloads a day 3.1 → 4.6 · proceeds a day $1.20 → $2.10 (7 days after, Apple's sales report)". `money` formats a
    /// USD amount (the app passes its display currency).
    public func effectLine(money: (Double) -> String = { String(format: "$%.2f", $0) }) -> String? {
        guard let e = effect else { return nil }
        let d = String(format: "%.1f → %.1f", e.downloadsBefore, e.downloadsAfter)
        let p = "\(money(e.proceedsBefore)) → \(money(e.proceedsAfter))"
        return "First-time downloads a day \(d) · proceeds a day \(p) (\(e.complete ? "" : "so far, ")\(e.daysAfter) days after; Apple's sales report)"
    }
}

public enum ReleaseTimeline {
    private static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        return f.date(from: s) ?? { f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.date(from: s) }()
    }

    private static func dayDate(_ s: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f.date(from: s)
    }

    /// - versions: the newest `versions.snapshot` snapshot for this app.
    /// - history: this app's `release.snapshot` events (any order), each carrying `live_version`.
    /// - daily: this app's `revenue.daily` events (`day`, `units`, `proceeds_usd`).
    /// - publicLive: the version Apple's public App Store page says is live, with its release day ("2026-10-29"). It is the
    ///   real go-live day for that version, so it is used when Hmunmawi did not see the change itself.
    public static func build(versions: StoredEvent?, history: [StoredEvent], daily: [StoredEvent], now: Date = .now, window: Int = 7,
                             publicLive: (version: String, day: String)? = nil) -> [ReleaseEntry] {
        // When each version was first seen going live (not the first snapshot Hmunmawi ever took: that one only says what was live).
        var seen: [String: Date] = [:]
        var previous: String?
        for e in history.sorted(by: { $0.occurredAt < $1.occurredAt }) {
            guard let live = e.payload[path: "live_version"]?.string else { continue }
            if let p = previous, p != live, seen[live] == nil { seen[live] = Date(timeIntervalSince1970: Double(e.occurredAt) / 1000) }
            previous = live
        }
        // One reading per day (the newest wins).
        var days: [Date: (units: Double, usd: Double)] = [:]
        for e in daily.sorted(by: { $0.occurredAt < $1.occurredAt }) {
            guard let d = e.payload[path: "day"]?.string.flatMap(dayDate) else { continue }
            days[d] = (e.payload[path: "units"]?.number ?? 0, e.payload[path: "proceeds_usd"]?.number ?? 0)
        }
        func average(_ from: Date, _ to: Date) -> (n: Int, units: Double, usd: Double)? {
            let cal = Calendar(identifier: .gregorian)
            let picked = days.filter { $0.key >= cal.startOfDay(for: from) && $0.key < cal.startOfDay(for: to) }.values
            guard !picked.isEmpty else { return nil }
            return (picked.count, picked.map(\.units).reduce(0, +) / Double(picked.count), picked.map(\.usd).reduce(0, +) / Double(picked.count))
        }
        if let p = publicLive, seen[p.version] == nil, let d = dayDate(p.day) { seen[p.version] = d }
        let rows = versions?.payload[path: "versions"]?.array ?? []
        return rows.compactMap { v -> ReleaseEntry? in
            guard let number = v[path: "version"]?.string else { return nil }
            let live = seen[number]
            var effect: ReleaseEntry.Effect?
            if let live {
                let day = Double(86_400)
                let before = average(live.addingTimeInterval(-Double(window) * day), live)
                let end = min(now, live.addingTimeInterval(Double(window) * day))
                let after = average(live, end.addingTimeInterval(day))
                if let b = before, let a = after, b.n >= 3, a.n >= 3 {
                    effect = .init(downloadsBefore: b.units, downloadsAfter: a.units, proceedsBefore: b.usd, proceedsAfter: a.usd,
                                   daysAfter: min(window, max(1, Int(end.timeIntervalSince(live) / day))), complete: now >= live.addingTimeInterval(Double(window) * day))
                }
            }
            return ReleaseEntry(version: number, state: v[path: "state"]?.string, created: date(v[path: "created"]?.string), liveSeenAt: live, effect: effect)
        }.sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
    }
}
