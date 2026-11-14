import Foundation
import HmunmawiCore
import HmunmawiProtocol

/// The portal's fuller sections (14 Nov 2026), each built from data the app already stores, so a published page
/// covers what the maintainer's hub portal shows: earnings by month, lifetime access, the App Store, subscribers,
/// retention, trends, X, YouTube, outreach, attention, startup programs and the developer account. A section only
/// appears when its data exists; money is flagged so "Safe to show anyone" removes it.
extension PortalPublisher {
    typealias S = PortalBuilder.Section
    typealias St = PortalBuilder.Stat

    private static func num(_ v: JSONValue?) -> Double? { v?.number }
    private static func count(_ v: Double) -> String { Int(safe: v).formatted() }
    private static func pct(_ v: Double) -> String {
        (abs(v) <= 1 ? v * 100 : v).formatted(.number.precision(.fractionLength(0...1))) + "%"
    }
    /// "2026-12-10T15:44:49.000+00:00" or "2026-12-12" → "10 Dec 2026".
    private static func date(_ s: String) -> String {
        guard s.count >= 10, let d = try? Date(String(s.prefix(10)) + "T12:00:00Z", strategy: .iso8601) else { return s }
        return d.formatted(.dateTime.day().month(.abbreviated).year())
    }
    private static func apps(_ model: AppModel, _ kind: String) -> [StoredEvent] {
        model.snapshots(kind).filter { ($0.app ?? "").isEmpty == false }.sorted { ($0.app ?? "") < ($1.app ?? "") }
    }

    static func extraSections(_ model: AppModel) -> [S] {
        var out: [S] = []

        // Earnings: every month Apple paid (or will pay), newest last, from Apple's finance reports.
        if let months = model.snapshots("earnings.months").first?.payload[path: "months"]?.array, !months.isEmpty {
            let rows = months.compactMap { m -> (String, Double)? in
                guard let l = m[path: "label"]?.string, let u = num(m[path: "usd"]) else { return nil }
                return (l, u)
            }
            if !rows.isEmpty {
                let total = rows.reduce(0) { $0 + $1.1 }
                let best = rows.max { $0.1 < $1.1 }
                var s = S(id: "earnings", title: "Earnings", headline: money(total), unit: "earned since launch, after Apple's cut",
                          stats: [St(best.map { money($0.1) } ?? "", "Best month" + (best.map { " · \($0.0)" } ?? ""), money: true),
                                  St(rows.count.formatted(), "Months tracked")],
                          spark: PortalBuilder.Spark(caption: "Earned each month", values: rows.map(\.1),
                                                     start: rows.first?.0 ?? "", end: rows.last?.0 ?? ""),
                          details: rows.map { ($0.0, money($0.1)) })
                s.moneyHeadline = true; s.moneySpark = true
                out.append(s)
            }
        }

        // Lifetime access: people who own each app for good (lifetime plans), from Apple's subscription reports.
        let life = apps(model, "subs.snapshot").compactMap { e -> PortalBuilder.Tile? in
            guard let n = num(e.payload[path: "lifetime"]), n > 0 else { return nil }
            return PortalBuilder.Tile(name: e.app ?? "", headline: count(n), unit: "own it for life", stats: [])
        }
        if !life.isEmpty { out.append(S(id: "lifetime", title: "Lifetime access", tiles: life)) }

        // Store: product page conversion, top countries and where first downloads came from.
        for e in apps(model, "store.signals").prefix(6) {
            let p = e.payload
            var st: [St] = []
            if let c = num(p[path: "conversion"]) { st.append(St(pct(c), "Product page views that became a download")) }
            let countries = (p[path: "countries"]?.array ?? []).prefix(4).compactMap { c -> String? in
                guard let code = c[path: "code"]?.string else { return nil }
                return "\(code): \(count(num(c[path: "page_views"]) ?? 0)) page views, \(count(num(c[path: "first_time"]) ?? 0)) first downloads"
            }
            let sources = (p[path: "proceeds_by_source"]?.array ?? []).prefix(5).compactMap { s -> String? in
                guard let src = s[path: "source"]?.string else { return nil }
                return "\(src): \(count(num(s[path: "purchases"]) ?? 0)) purchases"
            }
            var s = S(id: "store-" + PortalBuilder.anchor(e.app ?? ""), title: "Store · \(e.app ?? "")",
                      meaning: p[path: "move"]?.string, stats: st, lines: countries + sources)
            s.footnote = "From App Store Connect analytics."
            out.append(s)
        }

        // Subscribers: paying now, plans, renewals and cancels in the first week, 28-day churn.
        for e in apps(model, "subs.snapshot") {
            let p = e.payload
            guard let paid = num(p[path: "active_paid"]), paid > 0 else { continue }
            var st = [St(count(paid), "Paying now")]
            if let c = num(p[path: "churn_28d"]) { st.append(St(count(c), "Stopped in 28 days")) }
            if let f = num(p[path: "first_to_second"]) { st.append(St(pct(f), "Renewed after the first period")) }
            let plans = ["weekly", "monthly", "yearly", "lifetime"].compactMap { k -> String? in
                guard let v = num(p[path: "plans.\(k)"]), v > 0 else { return nil }
                return "\(k.capitalized): \(count(v))"
            }
            out.append(S(id: "subs-" + PortalBuilder.anchor(e.app ?? ""), title: "Subscribers · \(e.app ?? "")",
                         stats: st, lines: plans))
        }

        // Retention: Day 1 / 7 / 28 from Apple's own sample of people who share analytics.
        let ret = apps(model, "subs.snapshot").compactMap { e -> PortalBuilder.Tile? in
            let d = ["d1", "d7", "d28"].map { num(e.payload[path: $0]) }
            guard d.contains(where: { $0 != nil }) else { return nil }
            let labels = ["Day 1", "Day 7", "Day 28"]
            let st = zip(labels, d).compactMap { l, v in v.map { St(pct($0), "came back on \(l)") } }
            return PortalBuilder.Tile(name: e.app ?? "", headline: st.first?.value, unit: st.first?.label, stats: Array(st.dropFirst()))
        }
        if !ret.isEmpty { out.append(S(id: "retention", title: "Retention", tiles: ret)) }

        // Trends: star rating over the last weeks, per app.
        for e in apps(model, "rating.series").prefix(6) {
            let vals = (e.payload[path: "rating"]?.array ?? []).compactMap(\.number)
            let days = (e.payload[path: "days"]?.array ?? []).compactMap(\.string)
            guard vals.count > 1, let last = vals.last else { continue }
            out.append(S(id: "trend-" + PortalBuilder.anchor(e.app ?? ""), title: "Trends · \(e.app ?? "")",
                         headline: last.formatted(.number.precision(.fractionLength(0...2))) + " ★", unit: "average rating",
                         spark: PortalBuilder.Spark(caption: "Rating each day", values: vals,
                                                    start: days.first.map(day) ?? "", end: days.last.map(day) ?? "")))
        }

        // X, like the hub portal's X card: followers with their trend, the week's numbers, your X at a glance
        // (pinned post, latest article, taking off, top replies) and the last 24 hours of posts and replies.
        if let x = model.snapshots("growth.x").first?.payload {
            var st: [St] = []
            if let i = num(x[path: "impressions_7d"]) { st.append(St(count(i), "Impressions, 7 days")) }
            if let g = num(x[path: "engagements_7d"]) { st.append(St(count(g), "Engagements, 7 days")) }
            if let p = num(x[path: "posts_7d"]) { st.append(St(count(p), "Posts, 7 days")) }
            let today = num(x[path: "followers_1d"]).map { d in d == 0 ? " · no change today" : " · \(d > 0 ? "+" : "")\(count(d)) today" } ?? ""
            var sec = S(id: "x", title: "X", headline: num(x[path: "followers"]).map(count), unit: "followers" + today, stats: st)
            if let series = model.snapshots("growth.series").first?.payload {
                let pts = TrendChart.points(series, "x_followers").suffix(28)
                if pts.count > 2 {
                    sec.spark = PortalBuilder.Spark(caption: "Followers each day", values: pts.map(\.1),
                                                    start: pts.first!.0.formatted(.dateTime.day().month(.abbreviated)),
                                                    end: pts.last!.0.formatted(.dateTime.day().month(.abbreviated)))
                }
            }
            sec.xRows = Self.xRows(model.snapshots("growth.x_glance").first?.payload)
            if let pulse = model.snapshots("growth.x_pulse").first?.payload, pulse[path: "fresh"] == .bool(true) {
                sec.feed = (pulse[path: "posts"]?.array ?? []).prefix(6).compactMap { p in
                    guard let t = p[path: "text"]?.string, !t.isEmpty else { return nil }
                    let views = p[path: "views"]?.number.map { "\(Int(safe: $0).formatted()) views" }
                    return PortalBuilder.FeedRow(reply: p[path: "kind"]?.string == "reply", text: String(t.prefix(200)),
                                                 meta: [views, p[path: "ago"]?.string].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                                                 url: p[path: "url"]?.string)
                }
                sec.feedTitle = "Last 24 hours" + (pulse[path: "as_of"]?.string.map { " · read \($0)" } ?? "")
            }
            if sec.hasContent || !sec.xRows.isEmpty { out.append(sec) }
        }

        // Website & search: Google Search Console and Bing, one card per site (the hub portal's "Website & search").
        // Counts only: the queries people typed are left out of a public copy.
        let history = model.snapshots("growth.series").first?.payload
        let searchSites = model.snapshots("growth.search")
        for e in searchSites {
            let p = e.payload
            guard let seen = num(p[path: "impressions_28d"]) else { continue }
            let site = e.app ?? "your site"
            var st: [St] = []
            if let c = num(p[path: "clicks_28d"]) { st.append(St(count(c), "Clicks, 28 days")) }
            if let c = num(p[path: "clicks_7d"]) { st.append(St(count(c), "Clicks, 7 days")) }
            if let pos = num(p[path: "position_28d"]), pos > 0 { st.append(St(String(format: "%.1f", pos), "Average position")) }
            var sec = S(id: "google-" + PortalBuilder.anchor(site), title: searchSites.count > 1 ? "Google Search · \(site)" : "Google Search",
                        headline: count(seen), unit: "times you were seen on Google, 28 days", stats: st)
            if searchSites.count == 1, let h = history {
                let pts = TrendChart.points(h, "google_impressions_7d").suffix(28)
                if pts.count > 2 {
                    sec.spark = PortalBuilder.Spark(caption: "Seen each week, over time", values: pts.map(\.1),
                                                    start: pts.first!.0.formatted(.dateTime.day().month(.abbreviated)),
                                                    end: pts.last!.0.formatted(.dateTime.day().month(.abbreviated)))
                }
            }
            sec.lines = (p[path: "top_queries_28d"]?.array ?? []).prefix(5).compactMap { q in
                guard let text = q[path: "query"]?.string, let i = num(q[path: "impressions"]) else { return nil }
                return "\u{201C}\(String(text.prefix(60)))\u{201D} · seen \(count(i)), clicked \(count(num(q[path: "clicks"]) ?? 0))"
            }
            sec.privateLines = true
            if let thru = p[path: "data_through"]?.string { sec.footnote = "Google's data runs up to \(date(thru))." }
            out.append(sec)
        }
        for e in model.snapshots("growth.bing") {
            let p = e.payload
            guard let seen = num(p[path: "impressions_28d"]) else { continue }
            var st: [St] = []
            if let c = num(p[path: "clicks_28d"]) { st.append(St(count(c), "Clicks, 28 days")) }
            if let c = num(p[path: "clicks_7d"]) { st.append(St(count(c), "Clicks, 7 days")) }
            var sec = S(id: "bing-" + PortalBuilder.anchor(e.app ?? "site"), title: "Bing" + (e.app.map { " · \($0)" } ?? ""),
                        headline: count(seen), unit: "times you were seen on Bing, 28 days", stats: st)
            if let thru = p[path: "data_through"]?.string { sec.footnote = "Bing's data runs up to \(date(thru))." }
            out.append(sec)
        }

        // YouTube: views, subscribers and uploads.
        let yt = model.snapshots("growth.youtube").compactMap { e -> PortalBuilder.Tile? in
            let p = e.payload
            guard let v = num(p[path: "views"]) else { return nil }
            var st: [St] = []
            if let s = num(p[path: "subscribers"]) { st.append(St(count(s), "Subscribers")) }
            if let u = num(p[path: "uploads_7d"]) { st.append(St(count(u), "Uploads, 7 days")) }
            return PortalBuilder.Tile(name: e.app ?? "YouTube", headline: count(v), unit: "views", stats: st)
        }
        if !yt.isEmpty { out.append(S(id: "youtube", title: "YouTube", tiles: yt)) }

        // Outreach: follow-ups that are due. Names of people and outlets are private.
        let due = model.snapshots("outreach.due")
        if !due.isEmpty {
            let overdue = due.filter { $0.payload[path: "overdue"] == JSONValue.bool(true) }.count
            var s = S(id: "outreach", title: "Outreach", headline: due.count.formatted(), unit: "follow-ups due",
                      stats: [St(overdue.formatted(), "Overdue")],
                      lines: due.prefix(8).compactMap { e in
                          e.payload[path: "outlet"]?.string.map { "\($0) · \(e.app ?? "") · due \(e.payload[path: "due"]?.string ?? "")" }
                      })
            s.privateLines = true
            out.append(s)
        }

        // Attention: what needs a look, per app, most severe first.
        let att = model.snapshots("attention.items").flatMap { e in
            (e.payload[path: "items"]?.array ?? []).map { (e.app ?? "", $0) }
        }
        if !att.isEmpty {
            let order = ["urgent": 0, "important": 1]
            let sorted = att.sorted { (order[$0.1[path: "severity"]?.string ?? ""] ?? 2) < (order[$1.1[path: "severity"]?.string ?? ""] ?? 2) }
            out.append(S(id: "attention", title: "Attention", headline: att.count.formatted(), unit: "things to look at",
                         lines: sorted.prefix(8).compactMap { app, i in
                             i[path: "title"]?.string.map { "\(app): \($0)" + (i[path: "action"]?.string.map { " → \($0)" } ?? "") }
                         }))
        }

        // Startup programs: credits approved and in review (sent by a script; see docs/SCRIPT-FEED.md).
        if let g = model.snapshots("growth.programs").first?.payload {
            let items = g[path: "items"]?.array ?? []
            var s = S(id: "programs", title: "Startup programs",
                      headline: num(g[path: "approved_value_usd"]).map { money($0) }, unit: "in free credits secured",
                      stats: [St(count(num(g[path: "approved"]) ?? 0), "Approved"), St(count(num(g[path: "in_review"]) ?? 0), "In review")],
                      lines: items.prefix(10).compactMap { i in
                          i[path: "name"]?.string.map { "\($0) · \(i[path: "status"]?.string ?? "")" + (i[path: "value_label"]?.string.map { " · \($0)" } ?? "") }
                      })
            s.moneyHeadline = true
            out.append(s)
        }

        // Developer account: membership renewal, devices, certificates and other end dates (no personal names).
        if let a = model.snapshots("account.snapshot").first?.payload {
            var st: [St] = []
            if let r = a[path: "renews"]?.string { st.append(St(date(r), "Membership renews")) }
            if let d = num(a[path: "devices"]) { st.append(St(count(d), "Test devices")) }
            if let n = a[path: "next_certificate_expiry"]?.string { st.append(St(date(n), "Next certificate expires")) }
            let ends = (model.snapshots("expiry.snapshot").first?.payload[path: "items"]?.array ?? []).prefix(6).compactMap { i -> String? in
                guard let k = i[path: "kind"]?.string ?? i[path: "type"]?.string, let x = i[path: "expires"]?.string else { return nil }
                return "\(k) · expires \(date(x))"
            }
            out.append(S(id: "account", title: "Developer account", stats: st, lines: ends))
        }
        return out
    }

    /// The glance event -> the hub-style rows (pinned, latest article, taking off, top replies).
    static func xRows(_ g: JSONValue?) -> [PortalBuilder.XRow] {
        guard let g, g != .null else { return [] }
        func int(_ v: JSONValue?) -> Int? { v?.number.map { Int(safe: $0) } }
        func row(_ kind: String, _ label: String, _ p: JSONValue) -> PortalBuilder.XRow {
            .init(kind: kind, label: label, title: p[path: "title"]?.string ?? "A post", url: p[path: "url"]?.string,
                  views: int(p[path: "views"]), likes: int(p[path: "likes"]))
        }
        var rows: [PortalBuilder.XRow] = []
        let pinned = g[path: "pinned"]
        if let p = pinned, p != .null { rows.append(row("pinned", p[path: "kind"]?.string == "article" ? "Pinned article" : "Pinned post", p)) }
        if let a = g[path: "latest_article"], a != .null, a[path: "url"] != pinned?[path: "url"] { rows.append(row("latest", "Latest article", a)) }
        if let t = g[path: "taking_off"], t != .null { rows.append(row("off", "Taking off", t)) }
        else if let why = g[path: "taking_off_reason"]?.string { rows.append(.init(kind: "off", label: "Taking off", title: why)) }
        for r in g[path: "top_replies"]?.array ?? [] {
            rows.append(.init(kind: "replies", label: "Top reply", title: "A reply", url: r[path: "url"]?.string,
                              views: int(r[path: "views"]), to: r[path: "to"]?.string))
        }
        return rows
    }
}
