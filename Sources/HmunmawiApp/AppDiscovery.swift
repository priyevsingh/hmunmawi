import HmunmawiCore
import SwiftUI

/// How people find one app, from App Store Connect via a script feed: the App Store funnel (seen → opened the page →
/// downloaded), where first downloads came from, and how many new subscribers cancel. Lives on the app's page.
struct AppDiscovery: View {
    let model: AppModel
    let app: String

    static func symbol(_ source: String) -> String {
        switch source {
        case "App Store search": "magnifyingglass"
        case "App Store browse": "square.grid.2x2.fill"
        case "Web referrer": "globe"
        case "App referrer": "app.badge.fill"
        default: "arrow.down.circle.fill"
        }
    }

    var body: some View {
        if let p = model.snapshot("app.snapshot", app: app)?.payload {
            let impressions = p[path: "store_impressions"]?.number ?? 0
            let views = p[path: "store_page_views"]?.number ?? 0
            let firsts = p[path: "store_first_downloads"]?.number ?? 0
            let sources = (p[path: "downloads_by_source"]?.array ?? []).compactMap { s -> RankedBars.Bar? in
                guard let name = s[path: "source"]?.string, let n = s[path: "count"]?.number else { return nil }
                return RankedBars.Bar(label: name, value: n, symbol: Self.symbol(name))
            }
            // Sits inside the app's page, so it is a section of that card (a divider and a header), not a card of its own.
            // Cancellations already have their own section on the page.
            if impressions > 0 || !sources.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Divider()
                    CardHeader(symbol: "magnifyingglass", title: "How people find \(app)", tint: Brand.Category.users,
                               caption: p[path: "downloads_source_days"]?.number.map { "Last \(Int(safe: $0)) days" })
                    if impressions > 0 {
                        // Three equal columns across the card, so the row doesn't leave the right half empty.
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 24, alignment: .topLeading), count: 3),
                                  alignment: .leading, spacing: 12) {
                            KitFigure(value: Int(impressions).formatted(), label: "seen on the App Store", tint: Brand.Category.users)
                            KitFigure(value: Int(views).formatted(), label: ["opened the page", pct(views, impressions)].filter { !$0.isEmpty }.joined(separator: " · "),
                                      tint: Brand.Category.users)
                            // Some first downloads skip the product page (search "Get" buttons), so a share over 100% is left out.
                            KitFigure(value: Int(firsts).formatted(),
                                      label: firsts <= views && views > 0 ? "downloaded · \(pct(firsts, views)) of those" : "downloaded",
                                      tint: Brand.Category.users)
                        }
                    }
                    if let signals = model.snapshot("store.signals", app: app)?.payload { storeSignals(signals, figuresShown: impressions > 0) }
                    if !sources.isEmpty {
                        Text("Where first downloads came from").font(.callout).foregroundStyle(.secondary)
                        RankedBars(bars: sources, sorted: true, tint: Brand.Category.users)
                    }
                }
            }
        }
    }

    /// The portal's App Store signals: the product page's conversion and its weekly move, the top countries,
    /// and in-app event views.
    @ViewBuilder
    private func storeSignals(_ s: JSONValue, figuresShown: Bool) -> some View {
        // The script feed's conversion covers its own window, so beside the figures above (another window) it would
        // contradict them; it shows only when those figures aren't there.
        if let c = s[path: "conversion"]?.number, !figuresShown {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(String(format: c < 0.1 ? "%.1f" : "%.0f", c * 100))% of product-page visitors download it")
                    .font(Kit.outcome)
                if let move = s[path: "move"]?.string {
                    let good = s[path: "move_tone"]?.string == "good"
                    Label(move, systemImage: good ? "arrow.up.right" : "arrow.down.right")
                        .font(.callout.weight(.semibold)).foregroundStyle(good ? Brand.good : Brand.caution)
                }
            }
        }
        let countries = s[path: "countries"]?.array ?? []
        if !countries.isEmpty {
            Text("Top countries on the App Store").font(.callout).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 200), spacing: 10, alignment: .topLeading), count: evenColumns(countries.count)),
                      alignment: .leading, spacing: 10) {
                ForEach(Array(countries.enumerated()), id: \.offset) { _, c in
                    let code = c[path: "code"]?.string ?? ""
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(Self.flag(code)).font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Locale.current.localizedString(forRegionCode: code) ?? code).font(.callout.weight(.semibold))
                            Text(Format.parts(c, [("impressions", "seen"), ("page_views", "opened"), ("first_time", "downloaded")]))
                                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Brand.Category.users.opacity(0.07), in: .rect(cornerRadius: 12))
                }
            }
        }
        if let e = s[path: "in_app_event"], let seen = e[path: "impressions"]?.number {
            Label("In-app event: seen \(Int(safe: seen).formatted()) times, page opened \(Int(safe: e[path: "page_views"]?.number ?? 0).formatted()) times",
                  systemImage: "calendar.badge.clock")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    static func flag(_ code: String) -> String {
        String(code.uppercased().unicodeScalars.compactMap { UnicodeScalar(127_397 + $0.value) }.map(Character.init))
    }

    private func pct(_ a: Double, _ b: Double) -> String {
        guard b > 0 else { return "" }
        let v = a / b * 100
        return v < 10 ? String(format: "%.1f%%", v) : "\(Int(v.rounded()))%"
    }
}
