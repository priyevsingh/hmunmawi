import Foundation
import HmunmawiCore

extension StoredEvent {
    /// The calendar day this event describes, as a local midnight. Daily reports say their day ("day":
    /// "2026-11-01"), but senders stamp it differently: App Store Connect, Sentry and PostHog stamp 23:59:59 UTC,
    /// which is the next morning in India, so bucketing by the stamp showed each day one day late. The stated day
    /// wins; events without one (live purchases) use their own time.
    var reportDay: Date {
        if let s = payload[path: "day"]?.string, s.count == 10 {
            let p = s.split(separator: "-").compactMap { Int($0) }
            if p.count == 3, let d = Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2])) { return d }
        }
        return Calendar.current.startOfDay(for: Date(timeIntervalSince1970: Double(occurredAt) / 1000))
    }
}
