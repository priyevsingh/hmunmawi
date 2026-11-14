import Foundation

/// Sample data for two made-up apps, so the Today card works before anything is connected.
public enum DemoData {
    public static let rules: [Rule] = [
        Rule(id: "refund-watch", name: "Tell me about refunds", when: "revenue.refund",
             actions: [RuleAction(action: "notify", resource: "imessage")],
             priority: 2, cooldownSeconds: 6 * 3600, approval: .ask, dryRun: false),
        Rule(id: "low-review", name: "Alert on low reviews", when: "review.new",
             conditions: [Condition(field: "rating", op: .lte, value: .number(2))],
             actions: [RuleAction(action: "notify", resource: "ntfy")],
             priority: 3, approval: .auto, dryRun: true),
    ]

    public static func seedIfEmpty(_ store: Store, now: Millis = Store.systemNow()) async throws {
        guard try await store.eventCount() == 0 else { return }
        var events: [Event] = []
        func add(_ kind: String, _ app: String, hoursAgo: Double, _ payload: JSONValue = .object([:])) {
            events.append(Event(source: "demo", kind: kind, app: app, payload: payload,
                                occurredAt: now - Millis(hoursAgo * 3_600_000), dedupeKey: "demo-\(events.count)"))
        }

        for day in 1...7 {
            let base = Double(day * 24)
            for i in 0..<5 { add("revenue.purchase", "Pocket Garden", hoursAgo: base + Double(i * 3) + 1) }
            for i in 0..<4 { add("revenue.purchase", "Night Owl Timer", hoursAgo: base + Double(i * 4) + 2) }
            if day == 5 { add("revenue.refund", "Night Owl Timer", hoursAgo: base + 5) }
        }
        for i in 0..<8 { add("revenue.purchase", "Pocket Garden", hoursAgo: Double(i) * 2.5 + 0.5) }
        for i in 0..<4 { add("revenue.purchase", "Night Owl Timer", hoursAgo: Double(i) * 5 + 1) }
        // Reviews the way a healthy indie app gets them: mostly glowing, one useful suggestion.
        for (app, hours, stars, title) in [
            ("Pocket Garden", 2.0, 5, "Finally I remember to water my plants"),
            ("Night Owl Timer", 5.0, 5, "The gentlest alarm I've ever used"),
            ("Pocket Garden", 20.0, 5, "Beautiful and calm, my favourite daily app"),
            ("Night Owl Timer", 30.0, 4, "Love it, a widget would make it perfect"),
            ("Pocket Garden", 44.0, 5, "Worth every penny"),
        ] { add("review.new", app, hoursAgo: hours, .object(["rating": .number(Double(stars)), "title": .string(title)])) }

        // Numbers for the Money, Reach and Health cards (all invented), in the shapes the real connections send.
        let dayFormat = Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
        let today = Date(timeIntervalSince1970: Double(now) / 1000)
        let days = (0..<28).reversed().map { today.addingTimeInterval(-Double($0) * 86_400) }
        for (app, base, growth) in [("Pocket Garden", 30.0, 0.6), ("Night Owl Timer", 12.0, 0.2)] {
            let active = days.indices.map { JSONValue.number((base + Double($0) * growth).rounded()) }
            var total = 400.0
            let downloads = days.indices.map { i -> JSONValue in total += 8 + Double((i * 7) % 11); return .number(total) }
            var subs = 0.0
            let newSubs = days.indices.map { i -> JSONValue in subs += (i % 3 == 0 ? 2 : 1) * growth * 2; return .number(subs.rounded()) }
            add("history.series", app, hoursAgo: 1, .object([
                "days": .array(days.map { .string($0.formatted(dayFormat)) }),
                "active": .array(active), "paying": .array(active), "downloads": .array(downloads), "new_subs": .array(newSubs),
                "additive": .array([.string("active"), .string("paying"), .string("downloads"), .string("new_subs")]),
                "labels": .object(["active": .string("Active subscribers"), "paying": .string("Paying subscribers"),
                                   "downloads": .string("First downloads"), "new_subs": .string("New subscribers")]),
                "better": .object(["active": .string("up"), "paying": .string("up"), "downloads": .string("up")])]))
            // Apple's daily sales report (downloads and proceeds per day), subscribers and the newest version: the
            // same shapes the App Store Connect connection sends, so each sample app gets its own page.
            for (i, d) in days.enumerated() where i < days.count - 1 {
                let units = Double(Int(base / 6) + (i * 5) % 7)
                add("revenue.daily", app, hoursAgo: Double(days.count - i) * 24, .object([
                    "day": .string(d.formatted(dayFormat)), "units": .number(units),
                    "proceeds_usd": .number((units * (app == "Pocket Garden" ? 1.4 : 0.9) * 100).rounded() / 100)]))
            }
            add("subscription.mrr", app, hoursAgo: 2, .object([
                "day": .string(today.addingTimeInterval(-86_400).formatted(dayFormat)),
                "active_paid": .number((base + 27 * growth).rounded()),
                "mrr_usd": .number(((base + 27 * growth) * (app == "Pocket Garden" ? 2.9 : 1.9)).rounded()),
                "mrr_gross_usd": .number(((base + 27 * growth) * (app == "Pocket Garden" ? 3.4 : 2.2)).rounded())]))
            // The App Store part of the journey (product page views → downloads → earned), 28 days.
            let (views, dls, earned) = app == "Pocket Garden" ? (1880, 412, 301) : (620, 168, 111)
            add("section.snapshot", app, hoursAgo: 3, .object([
                "id": .string("funnel"), "title": .string("From App Store page to paid"), "page": .string("overview"),
                "order": .number(50), "symbol": .string("arrow.down.right"), "color": .string("users"),
                "outcome": .string("\(dls) downloads from \(views) product page views in 28 days"),
                "steps": .array([
                    .object(["label": .string("Product page"), "value": .number(Double(views)), "note": .string("views")]),
                    .object(["label": .string("Downloads"), "value": .number(Double(dls)), "note": .string("first downloads")]),
                    .object(["label": .string("Earned"), "value": .number(Double(earned)), "note": .string("USD after Apple's cut")])])]))
            // Live on the App Store with its public rating (what the App Store connection reads from Apple's listing).
            add("release.snapshot", app, hoursAgo: 3, .object(["live": .bool(true), "live_version": .string(app == "Pocket Garden" ? "2.3" : "1.8")]))
            add("rating.snapshot", app, hoursAgo: 3, .object([
                "rating": .number(app == "Pocket Garden" ? 4.8 : 4.6), "ratings_count": .number(app == "Pocket Garden" ? 1240 : 386)]))
            add("versions.snapshot", app, hoursAgo: 3, .object(["versions": .array([
                .object(["version": .string(app == "Pocket Garden" ? "2.4" : "1.8"),
                         "state": .string(app == "Pocket Garden" ? "WAITING_FOR_REVIEW" : "READY_FOR_DISTRIBUTION")]),
                .object(["version": .string(app == "Pocket Garden" ? "2.3" : "1.7"), "state": .string("READY_FOR_DISTRIBUTION")])])]))
            for d in 1...14 {
                // A quiet fortnight with one small blip for Night Owl Timer (1 crash in 180 sessions).
                let rate = app == "Night Owl Timer" && d == 3 ? 99.4 : 100.0
                add("crash.daily", app, hoursAgo: Double(d * 24), .object([
                    "day": .string(today.addingTimeInterval(-Double(d) * 86_400).formatted(dayFormat)),
                    "crash_free_rate": .number(rate), "sessions": .number(180), "crashed": .number(rate < 100 ? 1 : 0)]))
            }
        }
        add("money.portal", "", hoursAgo: 1, .object([
            "proceeds_usd": .number(412.6), "window": .string("USD · 14 days"),
            "shares": .array([.object(["name": .string("Pocket Garden"), "usd": .number(301.2)]),
                              .object(["name": .string("Night Owl Timer"), "usd": .number(111.4)])])]))
        add("flow.snapshot", "", hoursAgo: 1, .object([
            "window": .string("28 days"), "website_visitors": .number(1240),
            "sources": .array([.object(["label": .string("Google"), "domain": .string("google.com"), "value": .number(6120)]),
                               .object(["label": .string("YouTube"), "domain": .string("youtube.com"), "value": .number(840)]),
                               .object(["label": .string("Bing"), "domain": .string("bing.com"), "value": .number(390)])])]))
        add("growth.search", "", hoursAgo: 1, .object([
            "clicks_28d": .number(214), "clicks_7d": .number(71), "impressions_28d": .number(6120),
            "impressions_7d": .number(1830), "position_28d": .number(14.2)]))

        for event in events.sorted(by: { $0.occurredAt < $1.occurredAt }) {
            // Sample events are stored without rules: sample data never queues an alert or something to approve.
            _ = try await store.ingest(event, rules: [])
        }
    }
}
