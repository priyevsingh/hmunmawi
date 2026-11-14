import Foundation

/// Builds the published portal: one self-contained HTML page
/// (same page structure and class names; the stylesheet is passed in). Pure: no files, no network.
/// A section with nothing to show is left out, so the page never shows empty cards or placeholder dashes.
public enum PortalBuilder {
    public struct Stat: Equatable, Sendable {
        public var value: String
        public var label: String
        public var meaning: String?
        /// A money amount: left out of a public-safe page.
        public var money: Bool
        public init(_ value: String, _ label: String, meaning: String? = nil, money: Bool = false) {
            self.value = value; self.label = label; self.meaning = meaning; self.money = money
        }
    }

    public struct Tile: Equatable, Sendable {
        public var name: String
        public var headline: String?
        public var unit: String?
        public var stats: [Stat]
        public init(name: String, headline: String? = nil, unit: String? = nil, stats: [Stat] = []) {
            self.name = name; self.headline = headline; self.unit = unit; self.stats = stats
        }
    }

    public struct Section: Equatable, Sendable {
        public var id: String
        public var title: String
        public var headline: String?
        public var unit: String?
        public var meaning: String?
        public var stats: [Stat]
        public var lines: [String]
        public var tiles: [Tile]
        public var footnote: String?
        public var spark: Spark?
        /// Label/value rows behind "See details" (folded, as in the portal).
        public var details: [(String, String)]
        /// X only: the glance rows and the last-24-hours feed, styled like the hub portal's X card.
        public var xRows: [XRow] = []
        public var feed: [FeedRow] = []
        public var feedTitle: String?
        /// Public-safe marks: the big number is money, the trend is money, the lines are private, or the whole
        /// section is (a list of sales with amounts and countries).
        public var moneyHeadline = false
        public var moneySpark = false
        public var privateLines = false
        public var privateSection = false
        public init(id: String, title: String, headline: String? = nil, unit: String? = nil, meaning: String? = nil,
                    stats: [Stat] = [], lines: [String] = [], tiles: [Tile] = [], footnote: String? = nil,
                    spark: Spark? = nil, details: [(String, String)] = []) {
            self.id = id; self.title = title; self.headline = headline; self.unit = unit; self.meaning = meaning
            self.stats = stats; self.lines = lines; self.tiles = tiles; self.footnote = footnote
            self.spark = spark; self.details = details
        }
        public static func == (a: Section, b: Section) -> Bool {
            a.id == b.id && a.title == b.title && a.headline == b.headline && a.unit == b.unit && a.meaning == b.meaning
                && a.stats == b.stats && a.lines == b.lines && a.tiles == b.tiles && a.footnote == b.footnote && a.spark == b.spark
                && a.details.map { $0.0 + "|" + $0.1 } == b.details.map { $0.0 + "|" + $0.1 }
                && a.xRows == b.xRows && a.feed == b.feed
        }
        /// True when there is something real to show.
        public var hasContent: Bool {
            headline != nil || meaning != nil || !stats.isEmpty || !lines.isEmpty || tiles.contains { $0.headline != nil || !$0.stats.isEmpty }
        }
    }

    /// A small trend line (the portal's sparkline): values oldest first, with the first and last day under it.
    /// One row of "your X at a glance" (the hub's coloured rows): kind is pinned, latest, off or replies.
    public struct XRow: Equatable, Sendable {
        public var kind: String, label: String, title: String, url: String?, views: Int?, likes: Int?
        /// For a reply: who it answered (left out of public copies).
        public var to: String?
        public init(kind: String, label: String, title: String, url: String? = nil, views: Int? = nil, likes: Int? = nil, to: String? = nil) {
            self.kind = kind; self.label = label; self.title = title; self.url = url; self.views = views; self.likes = likes; self.to = to
        }
    }
    /// One post or reply in the "Last 24 hours" feed.
    public struct FeedRow: Equatable, Sendable {
        public var reply: Bool, text: String, meta: String, url: String?
        public init(reply: Bool, text: String, meta: String, url: String? = nil) { self.reply = reply; self.text = text; self.meta = meta; self.url = url }
    }

    public struct Spark: Equatable, Sendable {
        public var caption: String
        public var values: [Double]
        public var start: String
        public var end: String
        public init(caption: String, values: [Double], start: String, end: String) {
            self.caption = caption; self.values = values; self.start = start; self.end = end
        }
    }

    public struct Page: Equatable, Sendable {
        public var product: String
        public var updated: String
        public var glance: [String]
        public var sections: [Section]
        /// Earlier copies kept next to the page: (label, relative link), newest first.
        public var earlier: [(String, String)]
        public init(product: String, updated: String, glance: [String] = [], sections: [Section], earlier: [(String, String)] = []) {
            self.product = product; self.updated = updated; self.glance = glance; self.sections = sections; self.earlier = earlier
        }
        public static func == (a: Page, b: Page) -> Bool {
            a.product == b.product && a.updated == b.updated && a.glance == b.glance && a.sections == b.sections
                && a.earlier.map { $0.0 + $0.1 } == b.earlier.map { $0.0 + $0.1 }
        }
    }

    public static func esc(_ s: String) -> String {
        var o = ""
        o.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": o += "&amp;"
            case "<": o += "&lt;"
            case ">": o += "&gt;"
            case "\"": o += "&quot;"
            case "'": o += "&#39;"
            default: o.append(c)
            }
        }
        return o
    }

    /// Only letters, digits and dashes in ids (they become anchors).
    public static func anchor(_ s: String) -> String {
        let a = s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(a).split(separator: "-").joined(separator: "-")
    }

    static func stats(_ stats: [Stat]) -> String {
        let items = stats.prefix(3).map { s in
            "<li><span class=\"sv\">\(esc(s.value))</span><span class=\"sl\">\(esc(s.label))</span>"
                + (s.meaning.map { "<span class=\"tagline\">\(esc($0))</span>" } ?? "") + "</li>"
        }
        return items.isEmpty ? "" : "<ul class=\"stats\">" + items.joined() + "</ul>"
    }

    static func hero(headline: String?, unit: String?, meaning: String?) -> String {
        var p: [String] = []
        if let h = headline { p.append("<p class=\"num\">\(esc(h))</p>") }
        if let u = unit { p.append("<p class=\"unit\">\(esc(u))</p>") }
        if let m = meaning { p.append("<p class=\"tagline\">\(esc(m))</p>") }
        return p.joined(separator: "\n")
    }

    static func spark(_ sp: Spark) -> String {
        let v = sp.values.filter(\.isFinite)
        guard v.count >= 2, let lo = v.min(), let hi = v.max() else { return "" }
        let w = 320.0, h = 36.0, span = (hi - lo) == 0 ? 1 : hi - lo
        let pts = v.enumerated().map { i, x in
            String(format: "%.1f,%.1f", 2 + Double(i) * (w - 4) / Double(v.count - 1), 4 + (1 - (x - lo) / span) * (h - 8))
        }
        let trend = v.last! > v.first! ? "up" : v.last! < v.first! ? "down" : "flat"
        let end = pts.last!.split(separator: ",")
        return "<div class=\"sparks\"><figure class=\"sparkline\"><figcaption>\(esc(sp.caption))</figcaption>"
            + "<svg viewBox=\"0 0 320 36\" role=\"img\" aria-label=\"\(esc(sp.start)) to \(esc(sp.end))\">"
            + "<path class=\"spark-line\" pathLength=\"1\" fill=\"none\" stroke=\"#0071e3\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\" d=\"M" + pts.joined(separator: " L") + "\"/>"
            + "<g class=\"spark-end \(trend)\"><circle cx=\"\(end[0])\" cy=\"\(end[1])\" r=\"3\"/></g></svg>"
            + "<div class=\"spark-ends\"><span>\(esc(sp.start))</span><span>\(esc(sp.end))</span></div></figure></div>"
    }

    static func details(_ rows: [(String, String)]) -> String {
        guard !rows.isEmpty else { return "" }
        return "<details class=\"more\"><summary>See details</summary><dl>"
            + rows.map { "<dt>\(esc($0.0))</dt><dd>\(esc($0.1))</dd>" }.joined() + "</dl></details>"
    }

    /// A colour family per section, from its id or title (the hub portal's look: money greens, reach blues,
    /// health purples, people oranges). Unknown sections get the default blue-purple.
    static func tone(_ s: Section) -> String {
        let k = (s.id + " " + s.title).lowercased()
        if ["money", "earn", "revenue", "proceed", "payout", "mrr", "subscri"].contains(where: k.contains) { return "tone-money" }
        if ["health", "crash", "stabil", "fail"].contains(where: k.contains) { return "tone-health" }
        if ["user", "message", "people", "audience"].contains(where: k.contains) { return "tone-people" }
        if ["download", "app", "store", "website", "search", "week", "reach", "seen"].contains(where: k.contains) { return "tone-reach" }
        return "tone-reach"
    }

    static func section(_ s: Section) -> String {
        var c = ["<p class=\"kicker\">\(esc(s.title))</p>"]
        if !s.tiles.isEmpty {
            let tiles = s.tiles.filter { $0.headline != nil || !$0.stats.isEmpty }.map { t in
                "<article class=\"tile\">\n<h3 class=\"tile-name\">\(esc(t.name))</h3>\n"
                    + [hero(headline: t.headline, unit: t.unit, meaning: nil), stats(t.stats)].filter { !$0.isEmpty }.joined(separator: "\n")
                    + "\n</article>"
            }
            c.append("<div class=\"tiles\">\n" + tiles.joined(separator: "\n") + "\n</div>")
        } else {
            let h = hero(headline: s.headline, unit: s.unit, meaning: s.meaning)
            if !h.isEmpty { c.append(h) }
            let st = stats(s.stats)
            if !st.isEmpty { c.append(st) }
            if let sp = s.spark { let x = spark(sp); if !x.isEmpty { c.append(x) } }
            if !s.lines.isEmpty {
                c.append("<ul class=\"plain-list\">" + s.lines.map { "<li>\(esc($0))</li>" }.joined() + "</ul>")
            }
            if !s.xRows.isEmpty { c.append(xGlance(s.xRows)) }
            if !s.feed.isEmpty { c.append(xFeed(s.feed, title: s.feedTitle)) }
        }
        let d = details(s.details)
        if !d.isEmpty { c.append(d) }
        if let f = s.footnote { c.append("<p class=\"footnote\">\(esc(f))</p>") }
        let inner = c.joined(separator: "\n")
        return s.tiles.isEmpty ? "<div class=\"sec-card \(tone(s))\">\n\(inner)\n</div>" : "<div class=\"\(tone(s))\">\n\(inner)\n</div>"
    }

    /// Only x.com post links are ever written into a page.
    static func xLink(_ u: String?) -> String? {
        guard let u, u.wholeMatch(of: /https:\/\/x\.com\/[A-Za-z0-9_]{1,15}\/status\/[0-9]{1,25}/) != nil else { return nil }
        return u
    }

    static func xGlance(_ rows: [XRow]) -> String {
        func n(_ v: Int?, _ w: String) -> String { v.map { "<span class=\"xg-n\"><b>\($0.formatted())</b> \(w)</span>" } ?? "" }
        let items = rows.map { r -> String in
            let title = xLink(r.url).map { "<a href=\"\(esc($0))\">\(esc(r.title))</a>" } ?? "<span>\(esc(r.title))</span>"
            let to = r.to.map { "<span class=\"xg-n\">to \(esc($0))</span>" } ?? ""
            return "<li class=\"xg-row \(esc(r.kind))\"><span class=\"xg-k\">\(esc(r.label))</span>\(title)\(to)\(n(r.views, "views"))\(n(r.likes, "likes"))</li>"
        }
        return "<div class=\"xglance\"><ul class=\"xg-list\">" + items.joined() + "</ul></div>"
    }

    static func xFeed(_ rows: [FeedRow], title: String?) -> String {
        let items = rows.enumerated().map { i, f -> String in
            let text = xLink(f.url).map { "<a href=\"\(esc($0))\">\(esc(f.text))</a>" } ?? esc(f.text)
            return "<li class=\"pf-row \(f.reply ? "reply" : "post")\" style=\"--i:\(i)\"><span class=\"pf-tag\">\(f.reply ? "Reply" : "Post")</span>"
                + "<span class=\"pf-text\">\(text)</span><span class=\"pf-meta\">\(esc(f.meta))</span></li>"
        }
        return "<p class=\"pulse-head\">\(esc(title ?? "Last 24 hours"))</p><ul class=\"pf-list\">" + items.joined() + "</ul>"
    }

    /// The hub portal's X card styles (glance rows and the last-24-hours feed), the same colours and type.
    static let xCSS = """
    @keyframes xg-in{from{opacity:0;transform:translateY(6px)}to{opacity:1;transform:none}}
    @keyframes xg-shift{from{background-position:0% 50%}to{background-position:100% 50%}}
    .xglance,.xg-list,.pf-list{max-width:none;width:100%}.xg-list{margin:12px 0 0;padding:0;list-style:none}
    .xg-row{display:flex;flex-wrap:wrap;align-items:baseline;gap:4px 12px;padding:8px 0;border-top:1px solid var(--line);font-size:14px;animation:xg-in .5s ease-out both;--xg-a:#8e8e93;--xg-b:#8e8e93}
    .xg-row.pinned{--xg-a:#af2bff;--xg-b:#ff2d95}.xg-row.latest{--xg-a:#0a6cff;--xg-b:#00c2ff}.xg-row.off{--xg-a:#ff6a00;--xg-b:#ff2d55}.xg-row.replies{--xg-a:#00b36b;--xg-b:#00c7d6}
    .xg-k{min-width:120px;font-size:14px;font-weight:800;letter-spacing:.01em;background:linear-gradient(90deg,var(--xg-a),var(--xg-b),var(--xg-a));background-size:200% 100%;-webkit-background-clip:text;background-clip:text;-webkit-text-fill-color:transparent;color:var(--xg-a);animation:xg-shift 9s ease-in-out infinite alternate}
    .xg-row a{font-weight:600;font-size:15px;color:var(--text);text-decoration:underline;text-decoration-color:var(--xg-a);text-underline-offset:3px}.xg-row>span:not([class]){font-size:14px;color:var(--muted);line-height:1.4}
    .xg-n{color:var(--muted);font-size:14px}.xg-n b{background:linear-gradient(90deg,var(--xg-a),var(--xg-b));-webkit-background-clip:text;background-clip:text;-webkit-text-fill-color:transparent;color:var(--xg-a);font-weight:700;font-variant-numeric:tabular-nums}
    .pulse-head{margin:18px 0 0;font-size:13px;font-weight:700;color:var(--muted);letter-spacing:.02em}
    .pf-list{margin:8px 0 0;padding:0;list-style:none}
    .pf-row{display:grid;grid-template-columns:64px minmax(0,1fr) auto;align-items:start;gap:12px;padding:10px 0;border-top:1px solid var(--line);font-size:15px;line-height:1.4;animation:xg-in .5s ease-out both;animation-delay:calc(var(--i)*.06s)}
    .pf-tag{justify-self:start;white-space:nowrap;padding:2px 9px;border-radius:999px;font-size:11.5px;font-weight:800;letter-spacing:.05em;text-transform:uppercase;color:#fff;line-height:1.5;margin-top:1px}
    .pf-row.post .pf-tag{background:linear-gradient(90deg,#af2bff,#ff2d95)}.pf-row.reply .pf-tag{background:linear-gradient(90deg,#0a6cff,#00a8e8)}
    .pf-text{min-width:0;color:var(--text);font-weight:500;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}.pf-text a{color:inherit;text-decoration:none}
    .pf-meta{color:var(--text);opacity:.7;font-size:13px;font-weight:600;white-space:nowrap;font-variant-numeric:tabular-nums}
    @media (max-width:560px){.pf-row{grid-template-columns:56px minmax(0,1fr)}.pf-meta{grid-column:2}.xg-k{flex-basis:100%;min-width:0}}
    @media (prefers-reduced-motion:reduce){.xg-row,.pf-row,.xg-k{animation:none}}
    """

    /// Colour on top of the shared stylesheet, so a published page has the hub portal's life: gradient hero figures
    /// and stats per colour family, tinted section titles, a soft glow on the glance card; light and dark variants.
    static let colorCSS = """
    .tone-money{--ga:#1fa35c;--gb:#0aa5b8}.tone-reach{--ga:#0a6cff;--gb:#8b3dff}.tone-health{--ga:#8b3dff;--gb:#ff2d95}.tone-people{--ga:#ff7a00;--gb:#ff2d6f}
    [class*=tone-] .num,[class*=tone-] .sv{background:linear-gradient(100deg,var(--ga),var(--gb));-webkit-background-clip:text;background-clip:text;-webkit-text-fill-color:transparent;color:var(--ga)}
    [class*=tone-] .kicker{color:var(--ga);font-weight:700;letter-spacing:.02em}
    [class*=tone-] .tile{box-shadow:inset 0 3px 0 0 var(--ga)}
    [class*=tone-] .spark-line{stroke:var(--ga)}
    .glance{box-shadow:0 0 0 1px rgba(10,108,255,.10),0 12px 40px -18px rgba(139,61,255,.35)}
    .glance h2{background:linear-gradient(90deg,#0a6cff,#af2bff,#ff2d55);-webkit-background-clip:text;background-clip:text;-webkit-text-fill-color:transparent}
    @media (prefers-color-scheme: dark){.tone-money{--ga:#3ddc84;--gb:#30d5e8}.tone-reach{--ga:#4da3ff;--gb:#b98bff}.tone-health{--ga:#c08bff;--gb:#ff6bb5}.tone-people{--ga:#ffa64d;--gb:#ff6b8f}
    .glance{box-shadow:0 0 0 1px rgba(77,163,255,.18),0 12px 40px -18px rgba(185,139,255,.45)}.glance h2{background-image:linear-gradient(90deg,#4da3ff,#d77bff,#ff6b88)}}
    """

    /// The whole page. `css` is the portal stylesheet, inlined so the page works from a folder or any host.
    /// A copy safe to show anyone: no money amounts (stats, big numbers, trends, details), no private lists, and no
    /// glance line that names an amount. Downloads, percentages and counts stay.
    public static func publicSafe(_ page: Page) -> Page {
        var p = page
        let currency = CharacterSet(charactersIn: "$₹€£¥₩₽₺₫₱")
        p.glance = page.glance.filter { $0.rangeOfCharacter(from: currency) == nil }
        p.sections = page.sections.filter { !$0.privateSection }.map { s in
            var s = s
            if s.moneyHeadline { s.headline = nil; s.unit = nil }
            if s.moneySpark { s.spark = nil }
            if s.privateLines { s.lines = [] }
            s.lines = s.lines.filter { $0.rangeOfCharacter(from: currency) == nil }   // e.g. "revenue per download is $2.47"
            s.stats = s.stats.filter { !$0.money }
            s.details = []
            s.feed = []                                              // posts can name other people
            s.xRows = s.xRows.map { r in var r = r; r.to = nil; return r }
            s.tiles = s.tiles.map { t in var t = t; t.stats = t.stats.filter { !$0.money }; return t }
            if let m = s.meaning, m.rangeOfCharacter(from: currency) != nil { s.meaning = nil }
            return s
        }
        return p
    }

    /// The portal's top bar and menu (same markup as the hub portal's), linking only to sections on this page.
    static func nav(_ product: String, _ sections: [Section]) -> String {
        let icon = "<span class=\"pnav-icon\" aria-hidden=\"true\"><span></span><span></span><span></span></span>"
        let links = sections.map { "<a href=\"#\(anchor($0.id))\">\(esc($0.title))</a>" }.joined()
        return "<div class=\"pnav\"><div class=\"pnav-in\"><a class=\"pnav-brand\" href=\"#glance\">\(esc(product))</a>"
            + "<span class=\"pnav-here\"></span>"
            + "<button type=\"button\" class=\"pnav-toggle\" aria-label=\"Open menu\" aria-expanded=\"false\" aria-controls=\"pnav-menu\">\(icon)</button></div></div>"
            + "<div id=\"pnav-overlay\" class=\"pnav-overlay\" aria-hidden=\"true\"><div class=\"pnav-overlay-head\"><span class=\"pnav-brand\">\(esc(product))</span>"
            + "<button type=\"button\" class=\"pnav-close\" aria-label=\"Close menu\">\(icon)</button></div>"
            + "<nav id=\"pnav-menu\" class=\"pnav-menu\" aria-label=\"Sections\">\(links)</nav></div>"
            + "<div class=\"pnav-jump\"><button type=\"button\" class=\"pnav-jump-top\" aria-label=\"Go to the top of the page\" title=\"Top\">↑</button>"
            + "<button type=\"button\" class=\"pnav-jump-end\" aria-label=\"Go to the bottom of the page\" title=\"Bottom\">↓</button></div>"
    }

    public static func html(_ page: Page, css: String, navCSS: String = "", navJS: String = "") -> String {
        let shown = page.sections.filter(\.hasContent)
        var parts: [String] = navJS.isEmpty ? [] : [nav(page.product, shown)]
        let mast = "<header class=\"mast\"><p class=\"product\">\(esc(page.product))</p><p class=\"asof\">\(esc(page.updated))</p></header>"
        let glance = page.glance.isEmpty ? "" :
            "\n<article class=\"glance\"><h2>At a glance</h2><ul>" + page.glance.map { "<li>\(esc($0))</li>" }.joined() + "</ul></article>"
        parts.append("<section class=\"band\" id=\"glance\">\n<div class=\"wrap glance-wrap\">\n\(mast)\(glance)\n</div>\n</section>")
        for (i, s) in shown.enumerated() {
            let band = (i + 1) % 2 == 1 ? "band alt" : "band"
            parts.append("<section class=\"\(band)\" id=\"\(anchor(s.id))\">\n<div class=\"wrap\">\n\(section(s))\n</div>\n</section>")
        }
        if !page.earlier.isEmpty {
            let band = (shown.count + 1) % 2 == 1 ? "band alt" : "band"
            let links = page.earlier.map { "<li><a href=\"\(esc($0.1))\">\(esc($0.0))</a></li>" }.joined()
            parts.append("<section class=\"\(band)\" id=\"earlier\">\n<div class=\"wrap\">\n<div class=\"sec-card\"><details class=\"more\"><summary>Earlier copies</summary><ul class=\"plain-list\">\(links)</ul></details></div>\n</div>\n</section>")
        }
        let extra = ".plain-list{margin:12px 0 0;padding-left:18px;font-size:15px;line-height:1.5}.plain-list li{margin:4px 0}" + colorCSS + xCSS
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <meta name="robots" content="noindex, nofollow">
        <title>\(esc(page.product))</title>
        <style>
        \(css)
        \(navCSS)
        \(extra)
        </style>
        </head>
        <body>
        \(parts.joined(separator: "\n"))
        \(navJS.isEmpty ? "" : "<script>\n" + navJS + "\n</script>")
        </body>
        </html>
        """
    }
}
