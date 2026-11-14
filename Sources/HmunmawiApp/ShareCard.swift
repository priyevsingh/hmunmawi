import AppKit
import HmunmawiCore
import SwiftUI

// MARK: Options

enum CardShape: String, CaseIterable, Identifiable {
    case square = "Square", story = "Story", wide = "Wide"
    var id: String { rawValue }
    /// Pixel size of the exported image.
    var size: CGSize {
        switch self { case .square: CGSize(width: 1080, height: 1080); case .story: CGSize(width: 1080, height: 1920); case .wide: CGSize(width: 1600, height: 900) }
    }
    var hint: String {
        switch self { case .square: "X, Threads, LinkedIn, Instagram"; case .story: "Instagram and WhatsApp stories"; case .wide: "Full width in X and LinkedIn" }
    }
}

enum CardLook: String, CaseIterable, Identifiable {
    case night = "Night sky", light = "Clean light", hills = "Mizoram hills", sunrise = "Sunrise", mono = "Mono", app = "App colour"
    var id: String { rawValue }
}

enum CardHero: String, CaseIterable, Identifiable {
    case auto = "Automatic", earned = "Earnings", mrr = "MRR", downloads = "Downloads", paying = "Paying"
    var id: String { rawValue }
}

/// Which currency exact amounts use: yours (Settings > Show money in, by default your Mac's region), US dollars
/// (what Apple reports), or both (yours big, dollars small).
enum CardCurrency: String, CaseIterable, Identifiable {
    case local, usd, both
    var id: String { rawValue }
}

struct CardOptions: Equatable {
    var shape: CardShape = .square
    var look: CardLook = .night
    var exact = false              // exact amounts, or growth and counts only
    var currency: CardCurrency = .local
    var showApps = true            // app names and icons
    var hero: CardHero = .auto
}

// MARK: Look

/// Colours and background of one look.
struct CardPalette {
    var text: Color, soft: Color, accent: [Color], tile: Color, dark: Bool
    static func of(_ look: CardLook, appColor: NSColor?) -> CardPalette {
        switch look {
        case .night: return CardPalette(text: .white, soft: .white.opacity(0.62), accent: [Color(hex: 0xA78BFA), Color(hex: 0x60A5FA), Color(hex: 0x34D399)], tile: .white.opacity(0.07), dark: true)
        case .light: return CardPalette(text: Color(hex: 0x111114), soft: Color(hex: 0x111114).opacity(0.55), accent: [Color(hex: 0x2563EB), Color(hex: 0x7C3AED)], tile: Color.black.opacity(0.045), dark: false)
        case .hills: return CardPalette(text: .white, soft: .white.opacity(0.72), accent: [Color(hex: 0xFDE68A), Color(hex: 0xA7F3D0)], tile: .white.opacity(0.10), dark: true)
        case .sunrise: return CardPalette(text: .white, soft: .white.opacity(0.80), accent: [.white, Color(hex: 0xFFF1D6)], tile: .white.opacity(0.16), dark: true)
        case .mono: return CardPalette(text: .white, soft: .white.opacity(0.55), accent: [.white, .white], tile: .white.opacity(0.08), dark: true)
        case .app:
            let base = Color(nsColor: CardBackground.vivid(appColor ?? NSColor(hex: 0x3B82F6)))
            return CardPalette(text: .white, soft: .white.opacity(0.75), accent: [.white, base.opacity(0.35).mix(with: .white, by: 0.7)], tile: .white.opacity(0.12), dark: true)
        }
    }
}

struct CardBackground: View {
    let look: CardLook
    let appColor: NSColor?
    var body: some View {
        switch look {
        case .night:
            ZStack {
                LinearGradient(colors: [Color(hex: 0x0B1026), Color(hex: 0x05060F)], startPoint: .top, endPoint: .bottom)
                Circle().fill(Color(hex: 0x7C3AED).opacity(0.45)).frame(width: 700).blur(radius: 160).offset(x: -180, y: -220)
                Circle().fill(Color(hex: 0x0EA5E9).opacity(0.35)).frame(width: 600).blur(radius: 170).offset(x: 260, y: 240)
                Stars()
            }
        case .light:
            ZStack {
                Color(hex: 0xF7F7FA)
                Circle().fill(Color(hex: 0x93C5FD).opacity(0.35)).frame(width: 800).blur(radius: 200).offset(x: 300, y: -300)
            }
        case .hills:
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [Color(hex: 0x0F2A44), Color(hex: 0x2E6F8E), Color(hex: 0xF4B57A)], startPoint: .top, endPoint: .bottom)
                CardHills(seed: 0.0, height: 0.42).fill(Color(hex: 0x3D7A86).opacity(0.75))
                CardHills(seed: 1.7, height: 0.32).fill(Color(hex: 0x245C63).opacity(0.9))
                CardHills(seed: 3.1, height: 0.22).fill(Color(hex: 0x123B40))
            }
        case .sunrise:
            LinearGradient(colors: [Color(hex: 0xFF5F6D), Color(hex: 0xFF9966), Color(hex: 0xFFC371)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .mono:
            Color(hex: 0x0A0A0A)
        case .app:
            let base = Color(nsColor: CardBackground.vivid(appColor ?? NSColor(hex: 0x3B82F6)))
            ZStack {
                LinearGradient(colors: [base.mix(with: .black, by: 0.25), base.mix(with: .black, by: 0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(base.mix(with: .white, by: 0.3).opacity(0.5)).frame(width: 760).blur(radius: 180).offset(x: -220, y: -260)
            }
        }
    }
}

extension CardBackground {
    /// An icon's average colour is often muddy (dark, grey): lift its saturation and brightness so the card glows.
    static func vivid(_ c: NSColor) -> NSColor {
        guard let rgb = c.usingColorSpace(.sRGB) else { return c }
        var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: max(sat, 0.55), brightness: max(b, 0.62), alpha: 1)
    }
}

/// Layered hill silhouettes (the Mizo hills the app is named after).
struct CardHills: Shape {
    let seed: Double, height: Double
    func path(in r: CGRect) -> Path {
        var p = Path()
        let top = r.height * (1 - height)
        p.move(to: CGPoint(x: 0, y: r.height))
        p.addLine(to: CGPoint(x: 0, y: top))
        let steps = 60
        for i in 0...steps {
            let x = r.width * Double(i) / Double(steps)
            let t = Double(i) / Double(steps) * .pi * 2
            let y = top + r.height * 0.05 * sin(t * 1.3 + seed) + r.height * 0.03 * sin(t * 3.1 + seed * 2)
            p.addLine(to: CGPoint(x: x, y: y))
        }
        p.addLine(to: CGPoint(x: r.width, y: r.height))
        p.closeSubpath()
        return p
    }
}

/// A sprinkle of fixed stars (deterministic, so every export is the same).
struct Stars: View {
    var body: some View {
        Canvas { ctx, size in
            // A small integer generator (fixed seed): scattered, and the same on every export.
            var state: UInt64 = 0x9E3779B97F4A7C15
            func next() -> Double { state = state &* 6364136223846793005 &+ 1442695040888963407; return Double(state >> 11) / Double(1 << 53) }
            for _ in 0..<80 {
                let x = next(), y = next(), r = 1.2 + next() * 2.2
                ctx.fill(Path(ellipseIn: CGRect(x: x * size.width, y: y * size.height * 0.75, width: r, height: r)),
                         with: .color(.white.opacity(0.25 + 0.5 * next())))
            }
        }
    }
}

// MARK: Card

/// The shareable card: drawn for real at its export size (ImageRenderer), and scaled down for the preview.
struct ShareCard: View {
    let stats: PeriodStats
    let options: CardOptions
    let icons: [String: NSImage]
    let appColor: NSColor?

    private var pal: CardPalette { .of(options.look, appColor: appColor) }
    private var size: CGSize { options.shape.size }
    /// One unit at the square's scale; stories run 20% larger so the tall canvas doesn't look empty.
    /// One unit at the square's scale; stories and wide cards a bit larger so they fill their canvas.
    private var u: Double { min(size.width, size.height) / 1080 * (options.shape == .story ? 1.22 : options.shape == .wide ? 1.15 : 1) }

    var body: some View {
        ZStack {
            CardBackground(look: options.look, appColor: appColor)
            Group {
                switch options.shape {
                case .wide:
                    HStack(alignment: .center, spacing: 70 * u) {
                        VStack(alignment: .leading, spacing: 34 * u) { header; heroBlock; Spacer(minLength: 0); footer }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 30 * u) { chart; tiles; bestRow }
                            .frame(width: size.width * 0.44)
                    }
                case .story:
                    VStack(alignment: .leading, spacing: 56 * u) { header; Spacer(minLength: 0); heroBlock; chart; tiles; bestRow; Spacer(minLength: 0); footer }
                case .square:
                    VStack(alignment: .leading, spacing: 40 * u) { header; heroBlock; chart; tiles; Spacer(minLength: 0); HStack { bestRow; Spacer(); }; footer }
                }
            }
            .padding(options.shape == .wide ? 80 * u : 84 * u)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    // Header: the week, and (optionally) the apps.
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6 * u) {
                Text(CardText.heading(stats)).lineLimit(1).minimumScaleFactor(0.6).font(.system(size: 26 * u, weight: .heavy)).tracking(6 * u).foregroundStyle(pal.soft)
                Text(CardText.span(stats)).font(.system(size: 34 * u, weight: .semibold)).foregroundStyle(pal.text)
            }
            Spacer()
            if options.showApps { iconCluster }
        }
    }

    private var iconCluster: some View {
        HStack(spacing: -22 * u) {
            ForEach(Array(stats.apps.prefix(4).enumerated()), id: \.offset) { _, a in
                if let img = icons[a.name] {
                    let side = (stats.subject?.count == 1 ? 112 : 84) * u
                    Image(nsImage: img).resizable().interpolation(.high).frame(width: side, height: side)
                        .clipShape(RoundedRectangle(cornerRadius: 19 * u, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 19 * u, style: .continuous).strokeBorder(pal.dark ? .white.opacity(0.25) : .black.opacity(0.08), lineWidth: 3 * u))
                        .shadow(color: .black.opacity(0.25), radius: 10 * u, y: 4 * u)
                }
            }
        }
    }

    // The one big number.
    private var heroBlock: some View {
        let h = CardText.hero(stats, options)
        return VStack(alignment: .leading, spacing: 10 * u) {
            Text(h.value)
                .font(.system(size: (options.shape == .story ? 230 : 200) * u, weight: .black, design: .rounded))
                .minimumScaleFactor(0.4).lineLimit(1)
                .foregroundStyle(LinearGradient(colors: pal.accent, startPoint: .leading, endPoint: .trailing))
            if let note = CardText.heroUSD(stats, options).flatMap({ CardText.dollarNote($0, options) }) {
                Text(note).font(.system(size: 34 * u, weight: .semibold, design: .rounded)).foregroundStyle(pal.soft)
            }
            Text(h.label).font(.system(size: 40 * u, weight: .semibold)).foregroundStyle(pal.text)
            Text(CardText.line(stats)).font(.system(size: 32 * u, weight: .medium)).foregroundStyle(pal.soft)
        }
    }

    // Seven days of downloads (or earnings when that's the hero in exact mode).
    private var chart: some View {
        let earned = CardText.chartShowsEarnings(stats, options)
        let values = stats.buckets.map { earned ? $0.earnedUSD : $0.downloads }
        let top = max(values.max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 16 * u) {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                VStack(spacing: 10 * u) {
                    RoundedRectangle(cornerRadius: 12 * u, style: .continuous)
                        .fill(LinearGradient(colors: pal.accent.reversed(), startPoint: .bottom, endPoint: .top))
                        .opacity(i == values.count - 1 ? 1 : 0.55)
                        .frame(height: max(10 * u, 150 * u * v / top))
                    Text(stats.buckets[i].label).font(.system(size: 22 * u, weight: .semibold)).foregroundStyle(pal.soft)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 190 * u)
    }

    private var tiles: some View {
        HStack(spacing: 20 * u) {
            ForEach(CardText.tiles(stats, options), id: \.label) { t in
                VStack(alignment: .leading, spacing: 8 * u) {
                    Text(t.value).font(.system(size: 52 * u, weight: .bold, design: .rounded)).foregroundStyle(pal.text)
                        .minimumScaleFactor(0.5).lineLimit(1)
                    Text(t.label).font(.system(size: 24 * u, weight: .semibold)).foregroundStyle(pal.soft).lineLimit(1)
                }
                .padding(26 * u).frame(maxWidth: .infinity, alignment: .leading)
                .background(pal.tile, in: RoundedRectangle(cornerRadius: 28 * u, style: .continuous))
            }
        }
    }

    @ViewBuilder private var bestRow: some View {
        if let one = stats.subject, one.count == 1 {
            if let line = CardText.peakLine(stats, options) {
                Text(line).font(.system(size: 30 * u, weight: .semibold)).foregroundStyle(pal.text).lineLimit(1).minimumScaleFactor(0.6)
            }
        } else if options.showApps, let b = stats.best {
            HStack(spacing: 18 * u) {
                if let img = icons[b.name] {
                    Image(nsImage: img).resizable().frame(width: 56 * u, height: 56 * u).clipShape(RoundedRectangle(cornerRadius: 13 * u, style: .continuous))
                }
                Text("\(b.name) led the \(CardText.unit(stats))" + (b.downloads > 0 ? " · \(Int(safe: b.downloads)) downloads" : ""))
                    .font(.system(size: 30 * u, weight: .semibold)).foregroundStyle(pal.text).lineLimit(1).minimumScaleFactor(0.6)
            }
        }
    }

    // Small and tasteful.
    private var footer: some View {
        HStack(spacing: 10 * u) {
            Image(systemName: "mountain.2.fill").font(.system(size: 22 * u))
            Text("made with Hmunmawi").font(.system(size: 22 * u, weight: .semibold))
        }
        .foregroundStyle(pal.soft.opacity(0.85))
    }
}

// MARK: Words and numbers on the card

@MainActor enum CardText {
    static func pct(_ c: Double?) -> String? {
        c.map { v in let p = Int((v * 100).rounded()); return (p > 0 ? "+" : p < 0 ? "−" : "") + "\(abs(p))%" }
    }
    static func money(_ usd: Double, _ o: CardOptions) -> String {
        let m = Money.shared
        let dollars = Money.text(usd, "USD", decimals: usd < 100 ? 2 : 0)
        // Converted at today's rate, so marked "≈"; Apple's own dollar figure isn't.
        guard o.currency != .usd, m.target != "USD", let local = m.convert(usd, from: "USD") else { return dollars }
        return "≈" + m.format(local, from: m.target, decimals: 0)
    }
    /// Under the big number when showing both: the dollar figure Apple reports.
    static func dollarNote(_ usd: Double, _ o: CardOptions) -> String? {
        guard o.exact, o.currency == .both, Money.shared.target != "USD", Money.shared.convert(usd, from: "USD") != nil else { return nil }
        return Money.text(usd, "USD", decimals: usd < 100 ? 2 : 0) + " as Apple reports it"
    }
    /// The amount in a caption: "≈₹7,283 (≈ $76.73)" when showing both.
    static func captionMoney(_ usd: Double, _ o: CardOptions) -> String {
        let main = money(usd, o)
        guard o.currency == .both, main.hasPrefix("≈") else { return main }
        return main + " (" + Money.text(usd, "USD", decimals: usd < 100 ? 2 : 0) + ")"
    }
    /// A currency's flag (its country, or the EU's), for the picker.
    static func flag(_ code: String) -> String {
        let region = code == "EUR" ? "EU" : String(code.prefix(2))
        return region.unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }.map(String.init).joined()
    }
    /// "week", "month", "quarter", "year".
    static func unit(_ s: PeriodStats) -> String {
        switch s.period { case .week: "week"; case .month: "month"; case .quarter: "quarter"; case .year: "year" }
    }
    /// The card's heading: "MY WEEK", "MY OCTOBER", "MY Q3 2026", "MY 2026 SO FAR".
    static func heading(_ s: PeriodStats) -> String {
        if let one = s.subject, one.count == 1 { return (one[0] + " · my " + s.title).uppercased() }
        return ("My " + s.title).uppercased()
    }
    /// "with My App", "across My App and Other App", "across 3 apps"; "" for all apps.
    static func about(_ s: PeriodStats) -> String {
        guard let a = s.subject, !a.isEmpty else { return "" }
        switch a.count { case 1: return " with \(a[0])"; case 2: return " across \(a[0]) and \(a[1])"; default: return " across \(a.count) apps" }
    }
    /// A single app's busiest day, week or month in the period.
    /// The chart shows earnings when the big number is exact earnings, downloads otherwise.
    static func chartShowsEarnings(_ s: PeriodStats, _ o: CardOptions) -> Bool { o.exact && heroKind(s, o) == .earned }

    /// The best bucket by the same measure the chart draws, so the line and the tallest bar always agree.
    static func peakLine(_ s: PeriodStats, _ o: CardOptions) -> String? {
        let earned = chartShowsEarnings(s, o)
        let value: (PeriodStats.Bucket) -> Double = { earned ? $0.earnedUSD : $0.downloads }
        guard let b = s.buckets.filter({ value($0) > 0 }).max(by: { value($0) < value($1) }) else { return nil }
        let tz = TimeZone(identifier: "UTC")!
        let what: String
        switch s.period {
        case .week: what = "Best day: " + b.start.formatted(Date.FormatStyle(timeZone: tz).weekday(.wide))
        case .month: what = "Best day: " + b.start.formatted(Date.FormatStyle(timeZone: tz).day().month(.abbreviated))
        case .quarter: what = "Best week: from " + b.start.formatted(Date.FormatStyle(timeZone: tz).day().month(.abbreviated))
        case .year: what = "Best month: " + b.start.formatted(Date.FormatStyle(timeZone: tz).month(.wide))
        }
        if earned { return what + " · " + money(b.earnedUSD, o) }
        let n = Int(safe: b.downloads)
        return what + " · \(n.formatted()) download\(n == 1 ? "" : "s")"
    }
    static func span(_ s: PeriodStats) -> String {
        [s.span.0, s.span.1].compactMap { try? Date($0 + "T12:00:00Z", strategy: .iso8601) }
            .map { $0.formatted(.dateTime.day().month(.abbreviated)) }.joined(separator: " – ")
    }
    static func weekday(_ day: String) -> String {
        (try? Date(day + "T12:00:00Z", strategy: .iso8601)).map { String($0.formatted(.dateTime.weekday(.abbreviated)).prefix(2)) } ?? ""
    }

    /// Which number leads: what you chose, or (automatic) the most telling one this week.
    static func heroKind(_ s: PeriodStats, _ o: CardOptions) -> CardHero {
        if o.hero != .auto { return o.hero }
        if o.exact, s.earnedUSD > 0 { return .earned }
        if let c = s.mrrChange, abs(c) >= 0.01 { return .mrr }
        if s.earnedChange != nil, !o.exact, (s.earnedChange ?? 0) > 0 { return .earned }
        return .downloads
    }

    static func hero(_ s: PeriodStats, _ o: CardOptions) -> (value: String, label: String) {
        switch heroKind(s, o) {
        case .earned:
            return o.exact ? (money(s.earnedUSD, o), "earned this \(unit(s))") : (pct(s.earnedChange) ?? "New", pct(s.earnedChange) == nil ? "earnings this \(unit(s))" : "earnings vs last \(unit(s))")
        case .mrr:
            return o.exact ? (money(s.mrrUSD ?? 0, o), "monthly recurring revenue") : (pct(s.mrrChange) ?? "New", "MRR this \(unit(s))")
        case .downloads:
            return (Int(safe: s.downloads).formatted(), "downloads this \(unit(s))")
        case .paying:
            return (s.paying.map { $0.formatted() } ?? "None yet", "paying subscribers")
        case .auto:
            return ("", "")
        }
    }

    /// The hero's amount in dollars, when the hero is money.
    static func heroUSD(_ s: PeriodStats, _ o: CardOptions) -> Double? {
        switch heroKind(s, o) { case .earned: s.earnedUSD; case .mrr: s.mrrUSD; default: nil }
    }

    /// One honest, upbeat line about the period ("Quiet quarter. Still shipping.").
    static func line(_ s: PeriodStats) -> String {
        let c = s.downloadsChange ?? s.earnedChange
        guard let c else { return "First \(unit(s)) on the board." }
        switch c {
        case 0.25...: return "Best \(unit(s)) in a while. Up and to the right."
        case 0.05..<0.25: return "Steady climb."
        case -0.05..<0.05: return "Holding steady."
        default: return "Quiet \(unit(s)). Still shipping."
        }
    }

    struct Tile { let value: String; let label: String }
    static func tiles(_ s: PeriodStats, _ o: CardOptions) -> [Tile] {
        let hero = heroKind(s, o)
        var t: [Tile] = []
        if hero != .mrr, s.mrrUSD != nil {
            t.append(Tile(value: o.exact ? money(s.mrrUSD ?? 0, o) : (pct(s.mrrChange) ?? "steady"), label: "MRR"))
        }
        if hero != .paying, let p = s.paying {
            let d = s.payingBefore.map { p - $0 } ?? 0
            t.append(Tile(value: "\(p)" + (d != 0 ? " (\(d > 0 ? "+" : "−")\(abs(d)))" : ""), label: "paying"))
        }
        if hero != .downloads {
            t.append(Tile(value: Int(safe: s.downloads).formatted() + (pct(s.downloadsChange).map { " (\($0))" } ?? ""), label: "downloads"))
        }
        if hero != .earned, t.count < 3, s.earnedUSD > 0, o.exact || pct(s.earnedChange) != nil {
            t.append(Tile(value: o.exact ? money(s.earnedUSD, o) : (pct(s.earnedChange) ?? ""), label: "earnings"))
        }
        return Array(t.prefix(3))
    }

    /// Ready-to-post text for X (matches the card's money choice).
    static func caption(_ s: PeriodStats, _ o: CardOptions) -> String {
        var parts: [String] = []
        if let mrr = s.mrrUSD { parts.append("MRR " + (o.exact ? captionMoney(mrr, o) + (pct(s.mrrChange).map { " (\($0))" } ?? "") : (pct(s.mrrChange) ?? "steady"))) }
        parts.append("\(Int(safe: s.downloads).formatted()) downloads" + (pct(s.downloadsChange).map { " (\($0))" } ?? ""))
        if let p = s.paying { parts.append("\(p) paying") }
        if o.exact, s.earnedUSD > 0 { parts.append(captionMoney(s.earnedUSD, o) + " earned") }
        return "My \(s.title)\(about(s)) (\(span(s))): " + parts.joined(separator: ", ") + ". Building in public with Hmunmawi 🏔"
    }
}

// MARK: Colour helpers

extension Color {
    init(hex: UInt32) { self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255) }
}

extension NSColor {
    convenience init(hex: UInt32) { self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1) }

    /// The average colour of an image (an app icon), for the "App colour" look.
    static func average(of image: NSImage) -> NSColor? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return NSColor(srgbRed: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
    }
}
