import Foundation
import HmunmawiCore

/// A made-up install with NO script feed, for looking at what a regular user sees. It only runs in a test profile
/// (HMUNMAWI_PROFILE) with HMUNMAWI_FIXTURE=nohub, never in the real app, and it fills only that profile's own database.
enum Fixtures {
    static var noHub: Bool { TestProfile.name != nil && ProcessInfo.processInfo.environment["HMUNMAWI_FIXTURE"] == "nohub" }

    static func seedNoHub(_ store: Store) async {
        guard noHub else { return }
        let now = Date.now
        func ms(_ daysAgo: Double) -> Millis { Millis(now.addingTimeInterval(-daysAgo * 86_400).timeIntervalSince1970 * 1000) }
        func event(_ kind: String, _ app: String, _ p: [String: JSONValue], _ daysAgo: Double, _ key: String) -> Event {
            Event(source: "fixture", kind: kind, app: app, payload: .object(p), occurredAt: ms(daysAgo), dedupeKey: "fx-\(kind)-\(key)")
        }
        let fit = "Fixture Fit: Workout Timer", notes = "Fixture Notes: Daily Journal"
        var events: [Event] = [
            event("icon.snapshot", fit, ["appID": .string("111")], 0.1, "fit-icon"),
            event("icon.snapshot", notes, ["appID": .string("222")], 0.1, "notes-icon"),
            // Fit: version 2.0 live ten days ago, 2.1 went live four days ago (seen as a change).
            event("release.snapshot", fit, ["live": .bool(true), "live_version": .string("2.0")], 10, "fit-rel-1"),
            event("release.snapshot", fit, ["live": .bool(true), "live_version": .string("2.0")], 6, "fit-rel-2"),
            event("release.snapshot", fit, ["live": .bool(true), "live_version": .string("2.1")], 4, "fit-rel-3"),
            event("release.snapshot", fit, ["live": .bool(true), "live_version": .string("2.1")], 0.1, "fit-rel-4"),
            event("versions.snapshot", fit, ["app_id": .string("111"), "versions": .array([
                .object(["id": .string("v21"), "version": .string("2.1"), "state": .string("READY_FOR_DISTRIBUTION"), "created": .string(ISO8601DateFormatter().string(from: now.addingTimeInterval(-6 * 86_400)))]),
                .object(["id": .string("v20"), "version": .string("2.0"), "state": .string("READY_FOR_DISTRIBUTION"), "created": .string(ISO8601DateFormatter().string(from: now.addingTimeInterval(-20 * 86_400)))])])], 0.1, "fit-vers"),
            event("rating.snapshot", fit, ["app_id": .string("111"), "rating": .number(4.2), "ratings_count": .number(20), "coverage": .number(2),
                                           "ratings_by_country": .object(["US": .number(4.0), "GB": .number(4.6)]), "ratings_count_by_country": .object(["US": .number(15), "GB": .number(5)])], 0.1, "fit-rating"),
            event("reviews.snapshot", fit, ["app_id": .string("111"), "count": .number(2), "more": .bool(false), "reviews": .array([
                .object(["review_id": .string("r1"), "rating": .number(2), "title": .string("Timer drifts"), "body": .string("The rest timer is off by a few seconds."), "territory": .string("USA"), "created": .number(Double(ms(3)))]),
                .object(["review_id": .string("r2"), "rating": .number(5), "title": .string("Love it"), "body": .string("Simple and fast."), "territory": .string("GBR"), "created": .number(Double(ms(1)))])])], 0.1, "fit-open"),
            // Notes is not on the App Store yet: only a version in preparation.
            event("release.snapshot", notes, ["live": .bool(false)], 0.1, "notes-rel"),
            event("versions.snapshot", notes, ["app_id": .string("222"), "versions": .array([
                .object(["id": .string("n1"), "version": .string("1.0"), "state": .string("PREPARE_FOR_SUBMISSION"), "created": .string(ISO8601DateFormatter().string(from: now.addingTimeInterval(-2 * 86_400)))])])], 0.1, "notes-vers"),
        ]
        events.append(event("money.portal", fit, ["meaning": .string("Money Apple estimates you keep over the last 7 days, in US dollars."), "window": .string("USD · 7 days"),
                                                  "proceeds_usd": .number(7 * 4.2), "shares": .array([.object(["name": .string("Fixture Fit"), "usd": .number(7 * 4.2)])])], 0.05, "fit-money"))
        // Twenty days of sales: a little growth after 2.1 went live.
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        for d in 1...20 {
            let day = f.string(from: now.addingTimeInterval(-Double(d) * 86_400))
            let units = d <= 4 ? 7.0 : 4.0
            events.append(event("revenue.daily", fit, ["day": .string(day), "units": .number(units), "proceeds_usd": .number(units * 0.6)], Double(d) - 0.01, "fit-day-\(day)"))
        }
        for e in events { _ = try? await store.ingest(e, rules: []) }
    }
}
