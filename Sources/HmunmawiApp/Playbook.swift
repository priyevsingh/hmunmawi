import HmunmawiCore
import SwiftUI

/// What to do next, worked out from the numbers already in the app (no AI needed): search gaps, the channel
/// that is pulling this week, App Store countries that look but don't download, countries whose subscribers pay
/// far less each, apps where subscribers leave early, and, only when the math clearly works, a note that paid ads
/// would pay for themselves.
/// You mark a suggestion Done or Not useful; 14 days after Done it checks whether the number moved and
/// ranks that kind of suggestion higher or lower next time.
struct Suggestion: Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable { case searchGap, channel, storePage, retention, ads, countryPrice }
    let id: String          // stable: the same advice keeps the same id across days
    let kind: Kind
    let app: String?
    let title: String
    let why: String
    let action: String
    let score: Double       // how much it matters, 0…1, before learning
    /// The number this advice should move, measured now (Done stores it) and again 14 days later.
    let metric: Double?
    let higherIsBetter: Bool

    var symbol: String {
        switch kind {
        case .searchGap: "magnifyingglass"
        case .channel: "chart.line.uptrend.xyaxis"
        case .storePage: "app.badge.fill"
        case .retention: "person.2.slash.fill"
        case .ads: "megaphone.fill"
        case .countryPrice: "globe.americas.fill"
        }
    }

    var tint: Color {
        switch kind {
        case .searchGap, .channel: Brand.Category.web
        case .storePage: Brand.Category.users
        case .retention, .ads, .countryPrice: Brand.Category.money
        }
    }
}

// MARK: Finding suggestions

@MainActor
enum Playbook {
    /// The cost per download you'd expect to pay for ads, in USD (your own assumption; Settings → General).
    static var adCostPerDownload: Double {
        let v = UserDefaults.standard.double(forKey: "HMAdCostPerDownload")
        return v > 0 ? v : 2.0
    }

    static func all(_ model: AppModel) -> [Suggestion] {
        searchGaps(model) + bestChannel(model) + storePages(model) + countryPrices(model) + retention(model) + ads(model)
    }

    /// Ranked by importance × what has worked for you before, without hidden ones (Not useful, or Done and
    /// still being measured).
    static func ranked(_ model: AppModel, limit: Int = 5) -> [Suggestion] {
        let store = PlaybookStore.shared
        return all(model)
            .filter { !store.isHidden($0.id) }
            .sorted { $0.score * store.weight($0.kind) > $1.score * store.weight($1.kind) }
            .prefix(limit).map { $0 }
    }

    private static func n(_ v: JSONValue?) -> Double { v?.number ?? 0 }

    /// Queries you show up for often but that rarely get a click: a page or a better title would catch them.
    static func searchGaps(_ model: AppModel) -> [Suggestion] {
        model.snapshots("growth.search").flatMap { e -> [Suggestion] in
            let site = e.app ?? "your site"
            return (e.payload[path: "top_queries_28d"]?.array ?? []).compactMap { q in
                guard let query = q[path: "query"]?.string else { return nil }
                let impressions = n(q[path: "impressions"]), clicks = n(q[path: "clicks"])
                guard impressions >= 40, clicks / impressions < 0.02 else { return nil }
                return Suggestion(
                    id: "search|\(site)|\(query)", kind: .searchGap, app: site,
                    title: "“\(query)”: seen \(Int(impressions)) times, clicked \(Int(clicks))",
                    why: "People search this and see \(site), but almost nobody clicks.",
                    action: "Answer it directly: a page or section titled for “\(query)”, or rewrite the title and description of the page that shows up.",
                    score: min(1, impressions / 400), metric: clicks, higherIsBetter: true)
            }
        }
    }

    /// The channel with the biggest share of its month in the last 7 days is pulling now; feed it.
    static func bestChannel(_ model: AppModel) -> [Suggestion] {
        var channels: [(String, Double, Double)] = []   // name, last 7 days, last 28 days
        if let g = SearchSites.merge(model.snapshots("growth.search").map(\.payload)) { channels.append(("Google", n(g[path: "impressions_7d"]), n(g[path: "impressions_28d"]))) }
        if let y = model.snapshots("growth.youtube").first?.payload, y[path: "views_28d"] != nil {
            channels.append(("YouTube", n(y[path: "views_7d"]), n(y[path: "views_28d"])))
        }
        if let b = model.snapshots("growth.bing").first?.payload { channels.append(("Bing", n(b[path: "impressions_7d"]), n(b[path: "impressions_28d"]))) }
        guard let best = channels.filter({ $0.2 >= 50 }).max(by: { $0.1 / $0.2 < $1.1 / $1.2 }) else { return [] }
        let share = best.1 / best.2
        guard share > 0.35 else { return [] }   // a quarter would be an ordinary week
        let action = switch best.0 {
        case "YouTube": "Post the next video in the next two days while the channel is being shown, on the same topic as this week's best one."
        case "Google": "Publish or refresh one page this week on the topic that's rising; Google is testing you more right now."
        default: "Make sure your site's newest pages are submitted in Bing Webmaster Tools this week."
        }
        // Stable per channel (not per week): "Not useful" stays hidden and "Done" can be measured 14 days on.
        return [Suggestion(id: "channel|\(best.0)", kind: .channel, app: nil,
                           title: "\(best.0) is pulling: \(Int((share * 100).rounded()))% of its month came this week",
                           why: "A normal week is about a quarter of the month; this is well above.",
                           action: action, score: min(1, share), metric: best.1, higherIsBetter: true)]
    }

    /// Countries where many people open the App Store page but few download: the page doesn't speak to them.
    static func storePages(_ model: AppModel) -> [Suggestion] {
        model.snapshots("store.signals").flatMap { e -> [Suggestion] in
            let app = e.app ?? "Your app"
            let overall = n(e.payload[path: "conversion"])
            guard overall > 0 else { return [] }
            return (e.payload[path: "countries"]?.array ?? []).compactMap { c in
                let code = c[path: "code"]?.string ?? ""
                let views = n(c[path: "page_views"]), firsts = n(c[path: "first_time"])
                guard views >= 50 else { return nil }
                let rate = firsts / views
                guard rate < overall * 0.6 else { return nil }
                let country = Locale.current.localizedString(forRegionCode: code) ?? code
                return Suggestion(
                    id: "store|\(app)|\(code)", kind: .storePage, app: app,
                    title: "\(country): \(Int(views)) opened \(app)'s page, \(Int(firsts)) downloaded",
                    why: "That's \(Int((rate * 100).rounded()))% against \(Int((overall * 100).rounded()))% everywhere else.",
                    action: "Localise the first two screenshots and the subtitle for \(country), or add a custom product page for it.",
                    score: min(1, views / 300), metric: rate, higherIsBetter: true)
            }
        }
    }

    /// Apps where most new subscribers turn renewal off in their first period: the first week isn't showing enough
    /// value. From Apple's subscription events when the app has them, else the script feed's figure.
    static func retention(_ model: AppModel) -> [Suggestion] {
        model.snapshots("app.snapshot").compactMap { e in
            let app = e.app ?? "Your app"
            let churn: Double, newSubs: Double, word: String
            if let t = model.subTruth[ComingSoon.shortName(app)] {
                newSubs = Double(t.starts)
                churn = t.starts > 0 ? Double(t.cancelsFirst) / Double(t.starts) : 0
                word = SubscriptionTruth.periodWord(t.mainPlan?.name)
            } else {
                churn = n(e.payload[path: "churn_ratio"]); newSubs = n(e.payload[path: "new_subscribers"]); word = "period"
            }
            // Five new subscribers at least: one person cancelling isn't "100% of subscribers".
            guard churn >= 0.5, newSubs >= 5 else { return nil }
            return Suggestion(
                id: "retention|\(app)", kind: .retention, app: app,
                title: "\(app): \(Int((churn * 100).rounded()))% of \(Int(newSubs)) new subscribers turn renewal off in their first \(word)",
                why: "They pay once, then leave before the first renewal.",
                action: "Show the main result in the first session, and remind people before the trial ends of what they'd lose; try a yearly plan with a clear saving.",
                score: min(1, churn * min(1, newSubs / 5)), metric: churn, higherIsBetter: false)
        }
    }

    /// Countries whose paying subscribers bring in under half of the app's usual amount each: Apple's local price
    /// there may be low. Advice only; prices stay yours to change in App Store Connect.
    static func countryPrices(_ model: AppModel) -> [Suggestion] {
        model.countryFlags.map { f in
            let country = Locale.current.localizedString(forRegionCode: f.country) ?? f.country
            let each = Money.shared.format(f.perSubUSD, from: "USD", decimals: 2), usual = Money.shared.format(f.appPerSubUSD, from: "USD", decimals: 2)
            var why = "That's under half of the \(usual) a month an average \(f.app) subscriber brings in."
            if let c = f.conversion, let all = f.appConversion {
                let pc = { (v: Double) in String(format: v < 0.1 ? "%.1f%%" : "%.0f%%", v * 100) }
                why += c >= all
                    ? " People there also subscribe at least as often (\(pc(c)) of downloads against \(pc(all))), so a higher price may still sell."
                    : " Fewer people there subscribe (\(pc(c)) of downloads against \(pc(all))), so price may not be what holds it back."
            }
            return Suggestion(
                id: "country|\(f.app)|\(f.country)", kind: .countryPrice, app: f.app,
                title: "\(country): \(f.active) subscribers to \(f.app) bring in \(each) a month each",
                why: why,
                action: "Compare \(country)'s price with what people there pay for similar apps (App Store Connect → Pricing and Availability). Hmunmawi never changes prices.",
                score: min(1, Double(f.active) / 10) * (1 - f.perSubUSD / f.appPerSubUSD), metric: f.perSubUSD, higherIsBetter: true)
        }
    }

    /// Paid ads only when each download clearly earns more than it would cost (your own cost assumption).
    static func ads(_ model: AppModel) -> [Suggestion] {
        var units: [String: Double] = [:], usd: [String: Double] = [:]
        for e in AppModel.oneSourcePerDay(model.events.filter { $0.kind == "revenue.daily" }) {
            guard let app = e.app else { continue }
            units[app, default: 0] += n(e.payload[path: "units"])
            usd[app, default: 0] += n(e.payload[path: "proceeds_usd"])
        }
        let cost = adCostPerDownload
        return units.compactMap { app, u in
            guard u >= 10 else { return nil }
            let perDownload = (usd[app] ?? 0) / u
            guard perDownload >= cost * 1.5 else { return nil }
            return Suggestion(
                id: "ads|\(app)", kind: .ads, app: app,
                title: "\(app) earns \(Money.shared.format(perDownload, from: "USD", decimals: 2)) per download",
                why: "That's over 1.5× the \(Money.shared.format(cost, from: "USD", decimals: 2)) you'd expect to pay per download, so ads would likely pay for themselves.",
                action: "Try a small Apple Search Ads test on your best keyword in your best country, with a daily cap you're fine losing.",
                score: min(1, perDownload / (cost * 3)), metric: nil, higherIsBetter: true)
        }
    }

    static func week() -> String {
        let c = Calendar(identifier: .iso8601)
        return "\(c.component(.yearForWeekOfYear, from: .now))-\(c.component(.weekOfYear, from: .now))"
    }
}

// MARK: What you said, and what worked

@MainActor @Observable
final class PlaybookStore {
    static let shared = PlaybookStore()

    struct Mark: Codable {
        var state: String          // "done" or "notUseful"
        var at: Date
        var kind: Suggestion.Kind
        var title: String
        var baseline: Double?
        var higherIsBetter: Bool
        var result: String?        // "worked" / "no change" once measured
        var after: Double?
    }

    private(set) var marks: [String: Mark] = [:]
    private(set) var weights: [String: Double] = [:]
    private let key = "HMPlaybook"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            marks = saved.marks
            weights = saved.weights
        }
    }

    private struct Saved: Codable { var marks: [String: Mark]; var weights: [String: Double] }
    private func persist() {
        if let data = try? JSONEncoder().encode(Saved(marks: marks, weights: weights)) { UserDefaults.standard.set(data, forKey: key) }
    }

    func weight(_ kind: Suggestion.Kind) -> Double { weights[kind.rawValue] ?? 1 }

    /// Not useful hides it for 30 days. Done hides it until its effect has been measured, and for at least 30
    /// days; if the same problem is still there after that, the tip comes back (on purpose: it still applies).
    func isHidden(_ id: String) -> Bool {
        guard let m = marks[id] else { return false }
        if m.state == "notUseful" { return Date.now.timeIntervalSince(m.at) < 30 * 86_400 }
        return m.result == nil || Date.now.timeIntervalSince(m.at) < 30 * 86_400
    }

    func done(_ s: Suggestion) {
        marks[s.id] = Mark(state: "done", at: .now, kind: s.kind, title: s.title, baseline: s.metric, higherIsBetter: s.higherIsBetter)
        persist()
    }

    func notUseful(_ s: Suggestion) {
        marks[s.id] = Mark(state: "notUseful", at: .now, kind: s.kind, title: s.title, baseline: nil, higherIsBetter: s.higherIsBetter)
        weights[s.kind.rawValue] = max(0.3, weight(s.kind) * 0.7)
        persist()
    }

    /// 14 days after Done, compares the number with today's and learns from it. `current` gives today's value
    /// of the same advice (nil when it can no longer be measured, e.g. the query left the top list).
    func measure(current: [String: Double]) {
        var changed = false
        for (id, m) in marks where m.state == "done" && m.result == nil && Date.now.timeIntervalSince(m.at) >= 14 * 86_400 {
            guard let before = m.baseline else { marks[id]?.result = "not measurable"; changed = true; continue }
            guard let now = current[id] else { continue }
            let better = m.higherIsBetter ? now > before * 1.1 : now < before * 0.9
            marks[id]?.result = better ? "worked" : "no change"
            marks[id]?.after = now
            weights[m.kind.rawValue] = min(2, max(0.3, weight(m.kind) * (better ? 1.2 : 0.9)))
            changed = true
        }
        if changed { persist() }
    }

    /// Measured results, newest first.
    var results: [(String, Mark)] {
        marks.filter { $0.value.result == "worked" || $0.value.result == "no change" }
            .sorted { $0.value.at > $1.value.at }.map { ($0.key, $0.value) }
    }
}

// MARK: The card

/// "Next steps" on the Log page: up to five suggestions, strongest first, each with Done / Not useful, and
/// below them what earlier advice did to the numbers.
struct NextSteps: View {
    let model: AppModel
    @State private var store = PlaybookStore.shared
    @State private var ai = AISettings.shared
    @State private var wording: [String: String] = [:]

    var body: some View {
        let list = Playbook.ranked(model)
        let results = store.results.prefix(3)
        if !list.isEmpty || !results.isEmpty {
            KitCard {
                CardHeader(symbol: "lightbulb.fill", title: "Next steps", tint: Brand.Category.web,
                           caption: ai.ready ? Byline.ai(ai.provider.name) : Byline.plain)
                ForEach(Array(list.enumerated()), id: \.element.id) { i, s in
                    if i > 0 { Divider() }
                    row(s)
                }
                if !results.isEmpty {
                    Divider()
                    Text("What earlier advice did").font(.callout).foregroundStyle(.secondary)
                    ForEach(Array(results), id: \.0) { _, m in
                        Label("\(m.title): \(m.result == "worked" ? "it worked" : "no clear change") after 14 days",
                              systemImage: m.result == "worked" ? "checkmark.seal.fill" : "minus.circle")
                            .font(.callout).foregroundStyle(m.result == "worked" ? Brand.good : Brand.secondaryText)
                    }
                }
            }
            // Keyed on the wording too, so new numbers get new AI wording (not last week's figures).
            .task(id: list.map { $0.id + $0.title }.joined() + "\(ai.ready)") {
                wording = await AIWriter.reword(list)
                measure()
            }
        }
    }

    private func row(_ s: Suggestion) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(symbol: s.symbol, tint: s.tint, size: 30)
            VStack(alignment: .leading, spacing: 4) {
                if let worded = wording[s.id] {
                    Kit.glow(worded, tint: Brand.caution).font(.body).fixedSize(horizontal: false, vertical: true)
                } else {
                    Kit.glow(s.title, tint: Brand.caution).font(.body).fixedSize(horizontal: false, vertical: true)
                    Text(s.why).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(s.action).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Button("Not useful") { withAnimation(.smooth) { store.notUseful(s) } }.buttonStyle(.pill)
                Button("Done") { withAnimation(.smooth) { store.done(s) } }.buttonStyle(.pillProminent)
            }
            .controlSize(.small)
            .help("Done: it checks the number again in 14 days. Not useful: hides it for 30 days and shows fewer like it.")
        }
    }

    /// Today's value of every piece of advice that is waiting to be measured.
    private func measure() {
        var current: [String: Double] = [:]
        for s in Playbook.all(model) { if let m = s.metric { current[s.id] = m } }
        store.measure(current: current)
    }
}


/// Who wrote the Next steps, said with a wink. One line per day (stable while you look), always naming the provider.
enum Byline {
    static let lines = [
        "Ghostwritten by", "Sweet-talked into English by", "Wordsmithed over coffee by", "Polished till it sparkled by",
        "Translated from spreadsheet by", "Pep talk courtesy of", "Numbers whispered, words by", "Turned nerdy into nice by",
    ]
    static let plainLines = ["Straight from your numbers, no fluff", "Raw numbers, zero sugar", "Just the math, served neat"]

    private static var day: Int { Calendar.current.ordinality(of: .day, in: .era, for: .now) ?? 0 }
    static func ai(_ provider: String) -> String { "\(lines[day % lines.count]) \(provider)" }
    static var plain: String { plainLines[day % plainLines.count] }
}
