import Charts
import HmunmawiCore
import SwiftUI

/// A section any add-on can send, drawn in the house style without app changes.
///
/// An add-on emits an event of kind `section.snapshot` whose payload is:
/// ```json
/// { "id": "users", "title": "Users", "page": "growth", "symbol": "person.2.fill", "order": 10,
///   "outcome": "Daily users are up 38% on last week",
///   "figures": [{ "label": "Daily users", "value": 16, "format": "number", "change": 0.38, "better": "up" }],
///   "series":  [{ "label": "Daily users", "days": ["2026-10-01", "..."], "values": [12, "..."], "format": "number" }],
///   "bars":    [{ "label": "🇺🇸 United States", "value": 41 }],
///   "barsFormat": "number",   // or "percent" when each bar is already a rate (no share-of-total shown)
///   "items":   [{ "title": "...", "outcome": "...", "action": "...", "severity": "high",
///                "figure": "3.7★", "meter": { "value": 3.7, "max": 5, "label": "stars" } }] }
/// ```
/// Every key except `id` and `title` is optional. `page` is one of overview, revenue, apps, growth, health
/// (default growth). `format` is number, usd, inr or percent. `better` says which direction is good (default up).
struct CustomSection: Identifiable {
    struct Figure: Identifiable {
        let label: String
        let value: Double
        let format: String
        let change: Double?
        let betterUp: Bool
        var id: String { label }
    }

    struct Series: Identifiable {
        let label: String
        let points: [(Date, Double)]
        let format: String
        var betterDown = false      // "better": "down" (churn, crashes): a rise is bad news
        var id: String { label }
    }

    let app: String
    let key: String
    let title: String
    let page: String
    let symbol: String
    let order: Int
    let outcome: String?
    let figures: [Figure]
    let series: [Series]
    let bars: [RankedBars.Bar]
    /// Rank bars largest first ("sortBars": true); otherwise keep the sender's order (weeks, steps).
    let sortBars: Bool
    /// How bar values read: "number" (counts, shown with their share of the whole) or "percent" (each bar is
    /// already a rate, e.g. renewal survival by week, so a share-of-total would be meaningless).
    let barsFormat: String
    /// A chain of steps ("Product page 38 → Tapped App Store 0 → ..."), each with a short note.
    let steps: [(label: String, value: String, note: String?)]
    /// Small grey chips, e.g. what the source is still waiting for.
    let chips: [String]
    /// Another section's id: this one is shown inside that one (its right half) instead of on its own.
    let into: String?
    /// The section's category colour: the sender's "color", else one chosen from its id.
    let tint: Color
    let items: [AttentionItem]
    /// A small table, e.g. users per version: { "title", "columns": [...], "rows": [{ "label", "values": [...], "highlight" }] }.
    let table: (title: String, columns: [String], rows: [(label: String, values: [String], highlight: Bool)])?
    /// One grey line under everything, e.g. where a sample comes from.
    let note: String?
    var id: String { app + "|" + key }

    init?(_ event: StoredEvent) {
        let p = event.payload
        guard let key = p[path: "id"]?.string, let title = p[path: "title"]?.string else { return nil }
        app = event.app ?? ""
        self.key = key
        self.title = title
        page = p[path: "page"]?.string ?? "growth"
        symbol = p[path: "symbol"]?.string ?? "square.grid.2x2.fill"
        order = Int(safe: p[path: "order"]?.number ?? 100)
        outcome = p[path: "outcome"]?.string
        figures = (p[path: "figures"]?.array ?? []).compactMap { f in
            guard let label = f[path: "label"]?.string, let value = f[path: "value"]?.number else { return nil }
            return Figure(label: label, value: value, format: f[path: "format"]?.string ?? "number",
                          change: f[path: "change"]?.number, betterUp: f[path: "better"]?.string != "down")
        }
        series = (p[path: "series"]?.array ?? []).compactMap { s in
            guard let label = s[path: "label"]?.string else { return nil }
            let points = TrendChart.points(s, "values")
            // A trend needs a few days before it means anything.
            return points.count >= 4 ? Series(label: label, points: points, format: s[path: "format"]?.string ?? "number",
                                                  betterDown: s[path: "better"]?.string == "down") : nil
        }
        bars = (p[path: "bars"]?.array ?? []).compactMap { b in
            guard let label = b[path: "label"]?.string, let value = b[path: "value"]?.number else { return nil }
            return RankedBars.Bar(label: Plain.pageTitle(label), value: value, domain: b[path: "domain"]?.string, symbol: b[path: "symbol"]?.string)
        }
        sortBars = p[path: "sortBars"] == .bool(true)
        barsFormat = p[path: "barsFormat"]?.string ?? (key == "retention" ? "percent" : "number")
        steps = (p[path: "steps"]?.array ?? []).compactMap { st in
            guard let label = st[path: "label"]?.string else { return nil }
            let v = st[path: "value"]
            let value = v?.number.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? v?.string ?? ""
            return (label, value, st[path: "note"]?.string)
        }
        chips = (p[path: "chips"]?.array ?? []).compactMap(\.string)
        into = p[path: "into"]?.string
        if let t = p[path: "table"], let rows = t[path: "rows"]?.array, !rows.isEmpty {
            let title = t[path: "title"]?.string ?? ""
            // A version's "Share" is of the week's users, and people move between versions, so the column can
            // add up past 100%; name it for what it is.
            table = (title, (t[path: "columns"]?.array ?? []).compactMap(\.string).map { title == "Versions" && $0 == "Share" ? "Of 7-day users" : $0 },
                     rows.map { ($0[path: "label"]?.string ?? "", ($0[path: "values"]?.array ?? []).compactMap(\.string), $0[path: "highlight"] == .bool(true)) })
        } else {
            table = nil
        }
        // Say why the version shares pass 100% instead of leaving it looking like an error.
        // Read from the sender's table: "columns" name each value in order (the row label isn't a column).
        let sharePast100: Bool = {
            guard p[path: "table.title"]?.string == "Versions",
                  let cols = p[path: "table.columns"]?.array?.compactMap(\.string), let col = cols.firstIndex(of: "Share") else { return false }
            let total = (p[path: "table.rows"]?.array ?? []).compactMap { r -> Double? in
                let v = r[path: "values"]?.array?.compactMap(\.string) ?? []
                return v.indices.contains(col) ? Double(v[col].replacingOccurrences(of: "%", with: "")) : nil
            }.reduce(0, +)
            return total > 100.5
        }()
        let base = p[path: "note"]?.string
        note = sharePast100 ? [base, "People who updated during the week count under both versions, so the last column adds up past 100%."]
            .compactMap { $0 }.joined(separator: " ") : base
        tint = Brand.Category.named(p[path: "color"]?.string) ?? Brand.Category.named(key) ?? Brand.data
        let app = self.app
        items = (p[path: "items"]?.array ?? []).map {
            AttentionItem(app: app, severity: $0[path: "severity"]?.string ?? "low",
                          title: $0[path: "title"]?.string ?? "", detail: $0[path: "detail"]?.string ?? "",
                          feedFigure: $0[path: "figure"]?.string, outcome: $0[path: "outcome"]?.string ?? $0[path: "title"]?.string,
                          action: $0[path: "action"]?.string, meterValue: $0[path: "meter.value"]?.number,
                          meterMax: $0[path: "meter.max"]?.number, meterLabel: $0[path: "meter.label"]?.string)
        }
    }

    @MainActor static func format(_ value: Double, _ format: String) -> String {
        switch format {
        case "usd": Money.shared.format(value, from: "USD")
        case "inr": Money.shared.format(value, from: "INR", decimals: 0)
        case "percent": "\(value.formatted(.number.precision(.fractionLength(0...1))))%"
        default: value.formatted(.number.notation(value >= 10_000 ? .compactName : .automatic).precision(.fractionLength(0...1)))
        }
    }
}

/// All custom sections meant for one page, each as a card.
struct CustomSections: View {
    let model: AppModel
    let page: String

    var body: some View {
        let sections = model.snapshots("section.snapshot").compactMap(CustomSection.init)
            .filter { $0.page == page && $0.into == nil }
            .filter { !model.replacedByApp($0) }
            .filter { page != "apps" || model.snapshot("app.snapshot", app: $0.app) == nil }
            // Each app's website-to-money funnel lives on its own Apps page, not on Growth.
            .filter { !(page == "growth" && $0.key == "funnel") }
            .sorted { ($0.order, $0.title, $0.app) < ($1.order, $1.title, $1.app) }
        if !sections.isEmpty {
            EqualRowsGrid {
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    SectionCard(section: section).arrival(index)
                }
            }
        }
    }
}

struct SectionCard: View {
    let section: CustomSection
    var inline = false
    @Environment(AppModel.self) private var model: AppModel?

    private var children: [CustomSection] {
        (model?.snapshots("section.snapshot") ?? []).compactMap(CustomSection.init).filter { $0.into == section.key }
            .sorted { $0.order < $1.order }
    }

    var body: some View {
        let kids = children
        Group {
            if kids.isEmpty || inline {
                main
            } else {
                // Children fill the right half; on a narrow window they stack beneath.
                ViewThatFits(in: .horizontal) {
                    // Children go into whichever column is shorter (estimated), so both halves end together.
                    let split = Self.balance(main: section, kids: kids)
                    HStack(alignment: .top, spacing: 28) {
                        VStack(alignment: .leading, spacing: 24) {
                            main
                            ForEach(split.left) { Divider(); SectionCard(section: $0, inline: true) }
                        }
                        .frame(minWidth: 460, maxWidth: .infinity, alignment: .topLeading)
                        Divider()
                        VStack(alignment: .leading, spacing: 24) {
                            ForEach(split.right) { SectionCard(section: $0, inline: true) }
                        }
                        .frame(minWidth: 460, maxWidth: .infinity, alignment: .topLeading)
                    }
                    VStack(alignment: .leading, spacing: 24) {
                        main
                        ForEach(kids) { Divider(); SectionCard(section: $0, inline: true) }
                    }
                }
            }
        }
        .padding(inline ? 0 : 20)
        .frame(maxWidth: .infinity, maxHeight: inline ? nil : .infinity, alignment: .topLeading)
        .background { if !inline { Color.clear.contentCard(cornerRadius: 22) } }
        .modifier(LiftIf(on: !inline))
    }

    /// A rough height for a section: header and outcome, figure rows, rings or bars, steps and chips.
    static func estimate(_ s: CustomSection) -> CGFloat {
        var h: CGFloat = 60 + (s.outcome == nil ? 0 : 40)
        if !s.figures.isEmpty { h += 90 * CGFloat((s.figures.count + 3) / 4) }
        if !s.bars.isEmpty { h += max(190, CGFloat(min(s.bars.count, 8)) * 42) }
        h += CGFloat(s.series.count) * 160 + (s.steps.isEmpty ? 0 : 110) + (s.chips.isEmpty ? 0 : 90)
        return h
    }

    static func balance(main: CustomSection, kids: [CustomSection]) -> (left: [CustomSection], right: [CustomSection]) {
        var left: [CustomSection] = [], right: [CustomSection] = []
        var lh = estimate(main), rh: CGFloat = 0
        for k in kids.sorted(by: { estimate($0) > estimate($1) }) {
            if rh <= lh { right.append(k); rh += estimate(k) } else { left.append(k); lh += estimate(k) }
        }
        return (left, right)
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if inline {
                    IconBadge(symbol: section.symbol, tint: section.tint, size: 24)
                } else {
                    SectionIcon(section: section)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(section.title).font(.headline).foregroundStyle(.primary)
                    if !inline && !section.app.isEmpty && section.app != "All apps" && !section.title.hasPrefix(section.app) {
                        Text(section.app).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            if let outcome = section.outcome {
                Kit.glow(Plain.readable(outcome), tint: section.tint).font(.title3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !section.figures.isEmpty {
                // One flexible column per figure (up to 4) so a short row spreads over the full width
                // instead of bunching up on the left of a wide window.
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 110), spacing: 10, alignment: .topLeading),
                                         count: min(section.figures.count, 4)), alignment: .leading, spacing: 10) {
                    ForEach(section.figures) { FigureView(figure: $0, tint: section.tint) }
                }
            }
            ForEach(section.series) { s in
                VStack(alignment: .leading, spacing: 4) {
                    // Today is still running, so judging it against whole days reads as a crash every morning;
                    // compare the last complete day instead.
                    let full = s.points.last.map { Calendar.current.isDateInToday($0.0) } == true ? Array(s.points.dropLast()) : s.points
                    let d = Direction(full.map(\.1))
                    HStack(alignment: .firstTextBaseline) {
                        Text(s.label).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        // Name the day: a series can lag (Apple's usage report is a couple of days behind), so
                        // "−100%" next to "1 person used it today" must say which day it is about.
                        let lastDay = full.last.map { Calendar.current.isDateInToday($0.0) ? "Today" : Calendar.current.isDateInYesterday($0.0) ? "Yesterday" : $0.0.formatted(.dateTime.day().month(.abbreviated)) }
                        Label((lastDay.map { "\($0): " } ?? "") + d.text + " vs 7-day average", systemImage: d.symbol)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(s.betterDown && d.color != .secondary ? (d.color == Brand.good ? Brand.bad : Brand.good) : d.color)
                    }
                    TrendChart(title: s.label, points: s.points, tint: section.tint, height: 120, showHeader: false,
                               format: { CustomSection.format($0, s.format) })
                }
            }
            if !section.bars.isEmpty { RankedBars(bars: section.bars, sorted: section.sortBars, tint: section.tint, format: section.barsFormat) }
            if let table = section.table { SectionTable(table: table, tint: section.tint) }
            if let note = section.note {
                Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !section.steps.isEmpty { StepChain(steps: section.steps.map(StepChain.local), tint: section.tint) }
            if !section.chips.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Waiting on").font(.callout).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                        ForEach(section.chips, id: \.self) { chip in
                            Label(chip, systemImage: "hourglass").font(.callout.weight(.medium))
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(.quaternary.opacity(0.5), in: Capsule())
                        }
                    }
                }
            }
        }
    }
}

private struct FigureView: View {
    let figure: CustomSection.Figure
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            CountUpText(text: CustomSection.format(figure.value, figure.format))
                .font(.system(size: 30, weight: .bold)).monospacedDigit()
                .foregroundStyle(tint == .primary ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Kit.vibrant(tint)))
                .minimumScaleFactor(0.7)
            Text(figure.label).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let change = figure.change, change.isFinite {
                let good = (change >= 0) == figure.betterUp
                Label("\(change >= 0 ? "+" : "")\(Int((change * 100).rounded()))%", systemImage: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(abs(change) < 0.005 ? Brand.secondaryText : good ? Brand.good : Brand.bad)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Sources as Apple Fitness-style activity rings: one ring per source (the five largest), each filled by its
/// share and swept closed with a soft glow when the scene arrives; beside them, every source with its icon,
/// number and share (click one for details). Rings only animate scale-free strokes, so the GPU does the work.
struct RankedBars: View {
    struct Bar { let label: String; let value: Double; var domain: String?; var symbol: String? }

    let bars: [Bar]
    var sorted = false
    var tint: Color = Brand.data
    var format = "number"
    @Environment(\.sceneActive) private var sceneActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = 0.0
    @State private var hovered: Int?
    @State private var breathe = false

    static let palette: [Color] = [Brand.Category.web, Brand.Category.video, Brand.Category.users, Brand.Category.money,
                                   Color(nsColor: .systemOrange), Color(nsColor: .systemIndigo), Color(nsColor: .systemBrown),
                                   Color(nsColor: .systemGray)]

    var body: some View {
        let top = Array((sorted ? bars.sorted { $0.value > $1.value } : bars).prefix(8))
        let total = max(top.map(\.value).reduce(0, +), 1)
        VStack(alignment: .leading, spacing: 10) {
            // Even rows, never one chip alone: up to 4 in a row, 5-6 as 3 + 3, 7-8 as 4 + 4. The widest layout that fits
            // the card wins, so a narrow card shows fewer per row instead of running past its edge.
            let want = evenColumns(top.count)
            ViewThatFits(in: .horizontal) {
                grid(top, total, want)
                grid(top, total, 3)
                grid(top, total, 2)
                grid(top, total, 1)
            }
        }
        .onAppear { animate() }
        .onChange(of: sceneActive) { _, on in if on { sweep = 0; animate() } }
    }

    private func grid(_ top: [Bar], _ total: Double, _ cols: Int) -> some View {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 200), spacing: 10, alignment: .leading), count: cols),
                  alignment: .leading, spacing: 10) {
                ForEach(top.indices, id: \.self) { i in
                    let bar = top[i]
                    // One colour for the whole group (the section's), so it reads at a glance.
                    let color = tint
                    HStack(spacing: 8) {
                        if let domain = bar.domain {
                            SiteIcon(domain: domain, size: 22, fallback: bar.symbol ?? "sparkles", tint: color).clipShape(Circle())
                        } else if let symbol = bar.symbol {
                            IconBadge(symbol: symbol, tint: color, size: 22)
                        }
                        Text(bar.label).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 6)
                        CountUpText(text: CustomSection.format(bar.value, format)).font(.callout.weight(.bold)).monospacedDigit()
                            .foregroundStyle(color.gradient)
                        if format != "percent" {
                            Text("\(Int((bar.value / total * 100).rounded()))%").font(.callout).foregroundStyle(.secondary)
                                .monospacedDigit().frame(width: 36, alignment: .trailing)
                        }
                    }
                    // A Mac-style pill: tinted capsule with a hairline, brighter under the pointer.
                    .padding(.leading, 6).padding(.trailing, 12).padding(.vertical, 6)
                    .background(color.opacity(hovered == i ? 0.20 : (i == 0 ? 0.14 : 0.07)), in: Capsule())
                    .overlay(Capsule().strokeBorder(color.opacity(0.25), lineWidth: 0.5))
                    .scaleEffect(hovered == i ? 1.03 : 1)
                    .modifier(Entrance(active: sceneActive, delay: 0.04 * Double(i)))
                    .onHover { if $0 && ScrollGate.active { return }; hovered = $0 ? i : (hovered == i ? nil : hovered) }
                    .clickForDetail({
                        var c = InfoModel(icon: bar.domain.map { .site($0) } ?? .symbol(bar.symbol ?? "chart.bar.fill"), tint: color, title: bar.label)
                        c.facts = [c.fact("number", format == "percent" ? "Rate" : "Count", CustomSection.format(bar.value, format)),
                                   format == "percent" ? nil : c.fact("chart.pie", "Share", "\(Int((bar.value / total * 100).rounded()))% of \(CustomSection.format(total, "number"))"),
                                   c.fact("list.number", "Rank", "\(i + 1) of \(top.count)")].compactMap { $0 }
                        return c
                    }())
                }
            }
    }

    private func animate() {
        guard !reduceMotion else { sweep = 1; return }
        withAnimation(.spring(response: 1.1, dampingFraction: 0.85).delay(0.15)) { sweep = 1 }
    }
}

/// A real app's icon (with the section's symbol as a badge), or just the symbol for site-wide sections.
private struct SectionIcon: View {
    let section: CustomSection
    @Environment(AppModel.self) private var model: AppModel?

    var body: some View {
        if model?.iconURL(for: section.app) != nil {
            AppIcon(app: section.app, size: 32, badge: section.symbol, badgeTint: section.tint)
        } else {
            IconBadge(symbol: section.symbol, tint: section.tint, size: 24)
        }
    }
}

/// Numbered steps in even rows (nothing scrolls away or gets cut): number big, label in colour, note beneath.
private struct StepChain: View {
    let steps: [(label: String, value: String, note: String?)]
    /// A sender's dollar figure ("$187", "28 days, est. USD") in your currency, like every other amount.
    @MainActor static func local(_ step: (label: String, value: String, note: String?)) -> (label: String, value: String, note: String?) {
        let raw = step.value.trimmingCharacters(in: .whitespaces)
        guard raw.hasPrefix("$"), let n = Double(raw.dropFirst().replacingOccurrences(of: ",", with: "")),
              Money.shared.target != "USD", Money.shared.convert(n, from: "USD") != nil else { return step }
        let note = step.note.map { $0.replacingOccurrences(of: " USD", with: "").replacingOccurrences(of: "est.", with: "est., converted") }
        return (step.label, "≈" + Money.shared.format(n, from: "USD", decimals: 0), note)
    }
    let tint: Color

    var body: some View {
        EqualRowsGrid(minWidth: 150, spacing: 8) {
            ForEach(steps.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(i + 1) · \(steps[i].label)").font(.callout.weight(.semibold)).foregroundStyle(tint)
                        .lineLimit(1).minimumScaleFactor(0.75)
                    Text(steps[i].value).font(.system(size: 22, weight: .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5).liveNumber(steps[i].value)
                        .foregroundStyle(Kit.vibrant(tint))
                    if let note = steps[i].note {
                        Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(tint.opacity(0.07), in: .rect(cornerRadius: 12))
                .clickForDetail({
                    var c = InfoModel(icon: .symbol("\(i + 1).circle.fill"), tint: tint, title: steps[i].label, subtitle: "Step \(i + 1) of \(steps.count)")
                    c.facts = [c.fact("number", "Value", steps[i].value), c.fact("calendar", "Window", steps[i].note),
                               c.fact("arrow.left", "Step before", i > 0 ? "\(steps[i - 1].label): \(steps[i - 1].value)" : nil),
                               c.fact("arrow.right", "Step after", i < steps.count - 1 ? "\(steps[i + 1].label): \(steps[i + 1].value)" : nil)].compactMap { $0 }
                    return c
                }())
                .arrival(i)
            }
        }
    }
}

private struct LiftIf: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View { if on { content.hoverLift() } else { content } }
}


/// A section's small table: a label column and a few number columns; the highlighted row (e.g. the version on
/// sale) is in the section colour.
struct SectionTable: View {
    let table: (title: String, columns: [String], rows: [(label: String, values: [String], highlight: Bool)])
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !table.title.isEmpty {
                Text(table.title).font(.callout).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                GridRow {
                    Text("")
                    ForEach(table.columns, id: \.self) {
                        Text($0).font(.callout).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    }
                }
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.label).font(.callout.weight(row.highlight ? .semibold : .regular))
                            .foregroundStyle(row.highlight ? tint : Color.primary)
                        ForEach(Array(row.values.enumerated()), id: \.offset) { _, v in
                            Text(v).font(.callout.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(row.highlight ? tint : Color.primary)
                        }
                        // A share column ("84%") gets a bar that fills the rest of the row, so the table uses the
                        // card's width instead of leaving it empty.
                        if showsBars, let f = Self.fraction(row.values.last) {
                            Capsule().fill(.quaternary).frame(height: 6).frame(maxWidth: .infinity)
                                .overlay(alignment: .leading) {
                                    GeometryReader { g in
                                        Capsule().fill(row.highlight ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(tint.opacity(0.45)))
                                            .frame(width: g.size.width * f)
                                    }
                                }
                                .frame(height: 6)
                        }
                    }
                }
            }
        }
    }

    private var showsBars: Bool { table.rows.contains { Self.fraction($0.values.last) != nil } }

    /// "84%" -> 0.84 (capped at 1); nil for anything that isn't a percentage.
    static func fraction(_ v: String?) -> Double? {
        guard let v, v.hasSuffix("%"), let n = Double(v.dropLast().trimmingCharacters(in: .whitespaces)) else { return nil }
        return min(1, max(0, n / 100))
    }
}
