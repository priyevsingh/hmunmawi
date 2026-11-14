import AppKit
import HmunmawiCore
import SwiftUI

/// One number a share card can show, straight from Today's own data (never invented: a number the source doesn't
/// give is simply left out, never shown as 0).
struct ShareMetric: Identifiable, Equatable {
    enum Format: Equatable { case count, position, money(String) }
    let id: String
    let label: String          // "WhatsApp taps"
    let value: Double
    var window: String? = nil  // "7 days", "28 days", "1–7 Nov"
    var change: Double? = nil  // 0.12 = up 12% on the period before
    var format: Format = .count

    var text: String {
        switch format {
        case .count: Int(value.rounded()).formatted()
        case .position: String(format: "%.1f", value)
        case .money(let code): Money.text(value, code, decimals: 0)
        }
    }
    /// "WhatsApp taps · 7 days"
    var caption: String { [label, window].compactMap { $0 }.joined(separator: " · ") }
}

/// What a website or business project (a tour company's site) can share: the numbers its Today page shows.
enum ProjectShare {
    /// Big number order when you pick "Automatic": what people did first, then how they found you.
    static let heroOrder = ["taps", "clicks", "visitors", "postClicks", "seen", "posts", "position"]

    /// The section figure whose label starts with one of `prefixes` ("WhatsApp taps, 7 days" → value, "7 days").
    static func figure(_ sections: [JSONValue], _ prefixes: [String]) -> (value: Double, window: String?, change: Double?)? {
        for s in sections {
            for f in s[path: "figures"]?.array ?? [] {
                let label = f[path: "label"]?.string ?? ""
                guard prefixes.contains(where: { label.hasPrefix($0) }), let v = f[path: "value"]?.number else { continue }
                let window = label.split(separator: ",", maxSplits: 1).dropFirst().first.map { $0.trimmingCharacters(in: .whitespaces) }
                return (v, window, f[path: "change"]?.number)
            }
        }
        return nil
    }

    /// Every number available for the project, from its search payload (Search Console / site feed) and sections.
    static func metrics(search: JSONValue?, sections: [JSONValue]) -> [ShareMetric] {
        var out: [ShareMetric] = []
        if let t = figure(sections, ["WhatsApp", "Contact", "Enquir"]) {
            out.append(ShareMetric(id: "taps", label: "WhatsApp taps", value: t.value, window: t.window, change: t.change))
        }
        let searchWindow: String? = {
            if search?[path: "clicks_28d"]?.number != nil { return "28 days" }
            if let w = search?[path: "window"]?.string { return w }
            return search?[path: "window_days"]?.number.map { "\(Int($0)) days" }
        }()
        if let c = search?[path: "clicks_28d"]?.number ?? search?[path: "clicks"]?.number {
            let before = search?[path: "clicks_prev"]?.number
            out.append(ShareMetric(id: "clicks", label: "Google clicks", value: c, window: searchWindow,
                                   change: before.flatMap { $0 > 0 ? (c - $0) / $0 : nil }))
        }
        if let v = figure(sections, ["Visitors"]) {
            out.append(ShareMetric(id: "visitors", label: "Visitors", value: v.value, window: v.window, change: v.change))
        }
        if let s = search?[path: "impressions_28d"]?.number ?? search?[path: "impressions"]?.number {
            out.append(ShareMetric(id: "seen", label: "Seen on Google", value: s, window: searchWindow))
        }
        if let p = search?[path: "position_28d"]?.number ?? search?[path: "position"]?.number, p > 0 {
            out.append(ShareMetric(id: "position", label: "Average Google position", value: p, window: searchWindow, format: .position))
        }
        if let posts = figure(sections, ["Posts live"])?.value ?? search?[path: "posts"]?.number {
            out.append(ShareMetric(id: "posts", label: "Blog posts live", value: posts))
        }
        if let pc = figure(sections, ["Google clicks from posts"]) {
            out.append(ShareMetric(id: "postClicks", label: "Google clicks from posts", value: pc.value, window: pc.window))
        }
        return out
    }

    @MainActor static func metrics(_ model: AppModel) -> [ShareMetric] {
        let search = SearchSites.merge(model.snapshots("growth.search").map(\.payload)) ?? SiteFeed.current(model)?.payload
        return metrics(search: search, sections: model.snapshots("section.snapshot").map(\.payload))
    }

    static func hero(_ metrics: [ShareMetric], choice: String) -> ShareMetric? {
        metrics.first { $0.id == choice } ?? heroOrder.lazy.compactMap { id in metrics.first { $0.id == id } }.first
    }

    /// "Hill Tours lately: 4 WhatsApp taps, 30 Google clicks (average position 6.4) and 31 visitors. 12 blog posts live."
    static func caption(name: String, metrics: [ShareMetric]) -> String {
        func m(_ id: String) -> ShareMetric? { metrics.first { $0.id == id } }
        var did: [String] = []
        if let t = m("taps") { did.append("\(t.text) WhatsApp \(t.value == 1 ? "tap" : "taps")") }
        if let c = m("clicks") {
            did.append("\(c.text) Google \(c.value == 1 ? "click" : "clicks")" + (m("position").map { " (average position \($0.text))" } ?? ""))
        }
        if let v = m("visitors") { did.append("\(v.text) \(v.value == 1 ? "visitor" : "visitors")") }
        var text = "\(name)"
        if !did.isEmpty {
            let list = did.count > 1 ? did.dropLast().joined(separator: ", ") + " and " + did.last! : did[0]
            text += " lately: " + list + "."
        } else { text += "." }
        if let p = m("posts") { text += " \(p.text) blog \(p.value == 1 ? "post" : "posts") live" + (m("postClicks").map { ", \($0.text) Google clicks from them" } ?? "") + "." }
        return text + " #buildinpublic"
    }
}

/// The share card for a website or business project: one big number and the rest as tiles, in the same looks
/// and shapes as the sales card.
struct ProjectShareCard: View {
    let name: String
    let metrics: [ShareMetric]
    let hero: ShareMetric
    let options: CardOptions

    var body: some View {
        let size = options.shape.size
        let u = min(size.width, size.height) / 1080
        let p = CardPalette.of(options.look, appColor: nil)
        let rest = metrics.filter { $0.id != hero.id }.prefix(options.shape == .wide ? 4 : 6)
        ZStack {
            CardBackground(look: options.look, appColor: nil)
            VStack(alignment: .leading, spacing: 28 * u) {
                Text(options.showApps ? name : "My website").font(.system(size: 52 * u, weight: .bold)).foregroundStyle(p.text)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 6 * u) {
                    Text(hero.text).font(.system(size: 230 * u, weight: .heavy, design: .rounded)).monospacedDigit()
                        .foregroundStyle(LinearGradient(colors: p.accent, startPoint: .leading, endPoint: .trailing))
                        .minimumScaleFactor(0.5).lineLimit(1)
                    Text(hero.caption).font(.system(size: 40 * u, weight: .semibold)).foregroundStyle(p.soft)
                    if let c = hero.change, abs(c) >= 0.01 {
                        Text("\(c > 0 ? "▲" : "▼") \(Int((abs(c) * 100).rounded()))% on the period before")
                            .font(.system(size: 30 * u, weight: .medium)).foregroundStyle(p.soft)
                    }
                }
                Spacer(minLength: 0)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18 * u), count: options.shape == .story ? 2 : 3), spacing: 18 * u) {
                    ForEach(Array(rest)) { m in
                        VStack(alignment: .leading, spacing: 6 * u) {
                            Text(m.text).font(.system(size: 60 * u, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(p.text)
                            Text(m.caption).font(.system(size: 24 * u, weight: .medium)).foregroundStyle(p.soft).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(22 * u)
                        .background(RoundedRectangle(cornerRadius: 26 * u, style: .continuous).fill(p.tile))
                    }
                }
                Text("made with Hmunmawi").font(.system(size: 22 * u, weight: .semibold)).foregroundStyle(p.soft)
            }
            .padding(72 * u)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, p.dark ? .dark : .light)
    }
}
