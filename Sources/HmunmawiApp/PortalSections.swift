import Charts
import HmunmawiCore
import SwiftUI

/// How the latest value compares with what came before: the average of up to 7 earlier points
/// (so one noisy day doesn't flip it). Green up, red down, grey when flat or unknown.
struct Direction {
    let change: Double?

    init(_ values: [Double]) {
        guard let last = values.last, values.count >= 2 else { change = nil; return }
        let before = values.dropLast().suffix(7)
        let base = before.reduce(0, +) / Double(before.count)
        change = base == 0 ? (last == 0 ? 0 : nil) : (last - base) / abs(base)
    }

    var color: Color {
        guard let change, abs(change) >= 0.005 else { return .secondary }
        return change > 0 ? Brand.good : Brand.bad
    }

    var symbol: String {
        guard let change, abs(change) >= 0.005 else { return "arrow.right" }
        return change > 0 ? "arrow.up.right" : "arrow.down.right"
    }

    var text: String {
        guard let change else { return "new" }
        return (change >= 0 ? "+" : "") + "\(Int((change * 100).rounded()))%"
    }
}

/// The house time chart: a calm grey line with a faint fill; the latest point and the change chip carry
/// the only colour (green up, red down).
struct TrendChart: View {
    let title: String
    let points: [(Date, Double)]
    var tint: Color = .primary
    var height: CGFloat = 44
    var showAxis = false
    var showHeader = true
    /// Small charts print their date range underneath unless this is off.
    var showsDates = true
    /// Inside a clickable card: the pointer still shows each bar's value, but clicks pass through to the card.
    var hoverOnly = false
    /// Percentages that sit near 100% (crash-free): start the scale just under the lowest day so small dips show.
    var zoomFlat = false
    var format: (Double) -> String = { $0.formatted(.number.precision(.fractionLength(0...1))) }
    @State private var picked: Date?
    @State private var grow = 1.0
    @Environment(\.sceneActive) private var sceneActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Bars for day-by-day or month-by-month numbers (up to 45 points); a line for long histories.
    private var useBars: Bool { points.count >= 2 && points.count <= 45 && height < 140 }
    /// Zoomed scale for near-flat percentages: from a little under the lowest value (at least 1 point of room) to the highest.
    private var zoomDomain: ClosedRange<Double>? {
        guard zoomFlat, let lo = points.map(\.1).min(), let hi = points.map(\.1).max(), lo > 0 else { return nil }
        return max(0, lo - max(1, (hi - lo) * 2))...max(hi, lo + 0.01)
    }
    private var barBase: Double { zoomDomain?.lowerBound ?? 0 }
    private var barColor: Color { tint == .primary ? Brand.data : tint }
    private var barUnit: Calendar.Component {
        guard points.count > 1 else { return .day }
        return points[1].0.timeIntervalSince(points[0].0) > 20 * 86_400 ? .month : .day
    }

    var body: some View {
        let direction = Direction(points.map(\.1))
        VStack(alignment: .leading, spacing: 4) {
            if showHeader { VStack(alignment: .leading, spacing: 2) {
                if !title.isEmpty {
                    Text(title).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let last = points.last {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(format(last.1)).font(.callout.weight(.semibold)).monospacedDigit().liveNumber(last.1)
                        Label(direction.text, systemImage: direction.symbol)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(direction.color)
                    }
                    .fixedSize()
                }
            } }
            Chart(Array(points.enumerated()), id: \.offset) { index, point in
                if useBars {
                    // Health-style capsule bars: the latest glows in colour, the rest in a gentle tint;
                    // the hovered one lifts and shows its value.
                    let isLast = index == points.count - 1
                    let isPicked = picked.map { Calendar.current.isDate($0, equalTo: point.0, toGranularity: barUnit) } ?? false
                    // Slim fixed-width capsules (as in Health), so short bars never turn into ovals.
                    BarMark(x: .value("Day", point.0, unit: barUnit), yStart: .value(title, barBase),
                            yEnd: .value(title, barBase + (point.1 - barBase) * grow), width: .fixed(height > 60 ? 10 : 7))
                        .cornerRadius(height > 60 ? 5 : 3.5)
                        .foregroundStyle(isLast || isPicked ? AnyShapeStyle(barColor.gradient) : AnyShapeStyle(barColor.opacity(0.28)))
                        .shadow(color: isLast ? barColor.opacity(0.45) : .clear, radius: 4)
                        // Kept inside the chart: a full-height bar's label slides down instead of being cut off at the top.
                        .annotation(position: .top, alignment: .center, spacing: 2,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            if isPicked {
                                VStack(spacing: 0) {
                                    Text(format(point.1)).font(.callout.weight(.bold)).foregroundStyle(barColor)
                                    Text(point.0, format: barUnit == .month ? .dateTime.month(.abbreviated) : .dateTime.day().month(.abbreviated))
                                        .font(.callout).foregroundStyle(.secondary)
                                }
                                .fixedSize()
                                // A backing so the label reads cleanly when it sits over a full-height bar.
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Brand.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                        }
                } else {
                    LineMark(x: .value("Day", point.0), y: .value(title, point.1))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(lineColor(direction))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    if index == points.count - 1 {
                        PointMark(x: .value("Day", point.0), y: .value(title, point.1))
                            .symbolSize(height > 60 ? 110 : 50)
                            .foregroundStyle(direction.color)
                    }
                }
            }
            .chartXSelection(value: hoverOnly ? .constant(nil) : $picked)
            .modifier(TrendYScale(zoom: zoomDomain, bars: useBars))
            .chartXAxis {
                if showAxis || height >= 100 {
                    AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                        AxisGridLine().foregroundStyle(Color(nsColor: .separatorColor))
                        // An explicit label colour: `.secondary` inside a chart picked up the accent (blue dates).
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated), centered: false)
                            .font(.callout)
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    }
                }
            }
            .chartYAxis(.hidden)
            .frame(height: height)
            // The latest point breathes like a live price in Stocks: "this is now".
            .chartOverlay { proxy in
                GeometryReader { g in
                    if let last = points.last, let plot = proxy.plotFrame,
                       let pos = proxy.position(for: (x: last.0, y: last.1)) {
                        let origin = g[plot].origin
                        Circle().fill(.clear)
                            .frame(width: height > 60 ? 11 : 7, height: height > 60 ? 11 : 7)
                            .ripple(direction.color, trigger: points.count)   // once when new data lands; no loop
                            .position(x: origin.x + pos.x, y: origin.y + pos.y)
                            .allowsHitTesting(false)
                    }
                }
            }
            // Hover-only: track the pointer without a gesture, so a click still reaches the card underneath.
            .chartOverlay { proxy in
                if hoverOnly {
                    GeometryReader { g in
                        Rectangle().fill(.clear).contentShape(.rect)
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let at):
                                    guard let plot = proxy.plotFrame else { return }
                                    picked = proxy.value(atX: at.x - g[plot].origin.x, as: Date.self)
                                case .ended: picked = nil
                                }
                            }
                    }
                }
            }
            .modifier(DrawIn())
            // (LineSheen removed: re-masking every chart each frame cost too much CPU.)
            .onChange(of: sceneActive) { _, on in
                guard on, useBars, !reduceMotion else { return }
                grow = 0
                withAnimation(.spring(response: 0.8, dampingFraction: 0.78).delay(0.15)) { grow = 1 }
            }
            // Small sparklines have no room for an axis; their date range sits underneath instead.
            if showsDates, !(showAxis || height >= 100), let first = points.first?.0, let last = points.last?.0 {
                HStack {
                    Text(first, format: .dateTime.day().month(.abbreviated))
                    Spacer()
                    Text(last, format: .dateTime.day().month(.abbreviated))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), latest \(points.last.map { format($0.1) } ?? "none"), \(direction.text)")
    }

    /// Only the page's hero chart wears its direction; every other chart is the same neutral line, so charts
    /// side by side look alike and the coloured end dot and chip carry the direction.
    private func lineColor(_ direction: Direction) -> Color {
        height >= 140 ? direction.color : (tint == .primary ? Brand.data : tint)
    }

    /// Pairs a payload's "days" array with one of its value arrays, skipping empty days.
    nonisolated static func points(_ payload: JSONValue?, _ field: String) -> [(Date, Double)] {
        guard let days = payload?[path: "days"]?.array, let values = payload?[path: field]?.array else { return [] }
        return zip(days, values).compactMap { day, value in
            guard let d = day.string, let v = value.number,
                  let date = try? Date(String(d.prefix(10)) + "T12:00:00Z", strategy: .iso8601) else { return nil }
            return (date, v)
        }
    }
}

/// The chart's vertical scale: an explicit range when zoomed, otherwise automatic (bars from zero).
private struct TrendYScale: ViewModifier {
    let zoom: ClosedRange<Double>?
    let bars: Bool
    func body(content: Content) -> some View {
        if let zoom { content.chartYScale(domain: zoom) }
        else { content.chartYScale(domain: bars ? .automatic(includesZero: true) : .automatic(includesZero: false)) }
    }
}

/// Everything per app beyond the headline numbers: trends, plans, retention and competitor moves.
struct AppExtras: View {
    let app: String?
    let model: AppModel

    var body: some View {
        let history = model.snapshot("history.series", app: app)?.payload
        let rating = model.snapshot("rating.series", app: app)?.payload
        let subs = model.snapshot("subs.snapshot", app: app)?.payload
        let competitors = model.snapshot("competitors.changes", app: app)?.payload

        VStack(alignment: .leading, spacing: 16) {
            let active = TrendChart.points(history, "active")
            let downloads = TrendChart.points(history, "downloads")
            let ratings = TrendChart.points(rating, "rating")
            if !active.isEmpty || !downloads.isEmpty || !ratings.isEmpty {
                HStack(spacing: 18) {
                    if !active.isEmpty { TrendChart(title: "Active subscribers", points: active, tint: Brand.Category.money) }
                    if !downloads.isEmpty { TrendChart(title: "First downloads", points: downloads, tint: Brand.Category.users) }
                    if !ratings.isEmpty {
                        TrendChart(title: "Rating", points: ratings, tint: Brand.caution, format: { String(format: "%.2f", $0) })
                    }
                }
            }
            // Apple's own subscription events, read by the app, replace the script feed's rough rates here (the plan mix stays).
            let truth = app.flatMap { model.subTruth[ComingSoon.shortName($0)] }
            if let subs {
                SubscriberRow(subs: subs, plansOnly: truth != nil || model.snapshots("section.snapshot")
                    .contains { $0.app == app && $0.payload[path: "id"]?.string == "retention" })
            }
            if let app { DownloadRetentionRow(app: app) }
            if let truth { StopPayingSection(truth: truth) }
            if let changes = competitors?[path: "changes"]?.array, !changes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Competitor changes").font(.callout).foregroundStyle(.secondary)
                    ForEach(Array(changes.prefix(4).enumerated()), id: \.offset) { _, change in
                        Text("\(change[path: "name"]?.string ?? "") \(change[path: "field"]?.string ?? ""): \(change[path: "from"]?.string ?? "") → \(change[path: "to"]?.string ?? "")")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

private struct SubscriberRow: View {
    let subs: JSONValue
    /// True when a Renewals section already shows these rates, so only the plan mix is shown here.
    var plansOnly = false

    var body: some View {
        let plans = subs[path: "plans"]
        let planOrder = ["weekly", "monthly", "yearly", "lifetime"]
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(planOrder, id: \.self) { plan in
                    if let n = plans?[path: plan]?.number, n > 0 {
                        Text("\(Int(n)) \(plan)")
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .glassCapsule()
                    }
                }
                if let trial = subs[path: "trial"]?.number, trial > 0 {
                    Text("\(Int(trial)) on trial").font(.callout.weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 4).glassCapsule()
                }
            }
            if !plansOnly { StatGrid(stats: Stat.known([
                Stat(label: "1st → 2nd payment", value: Format.percent(subs[path: "first_to_second"]),
                     detail: subs[path: "first_to_second"]?.number == nil ? "not enough data" : ""),
                Stat(label: "Churn, 28 days", value: Format.percent(subs[path: "churn_28d"]),
                     detail: subs[path: "churn_28d"]?.number == nil ? "not enough data" : ""),
                Stat(label: "Trial → paid", value: Format.percent(subs[path: "trial_to_paid"]),
                     detail: subs[path: "trial_to_paid"]?.number == nil ? "no trials yet" : ""),
            ])) }
        }
    }
}

/// Items your script feed flagged, across all apps, most severe first.
struct AttentionPanel: View {
    let model: AppModel

    var body: some View {
        let items = AttentionItem.all(model)
        if !items.isEmpty {
            GlassPanel(title: "Needs attention", count: items.count) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12, alignment: .top)], spacing: 12) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        AttentionTile(item: item, index: index)
                            .arrival(index)
                    }
                }
            }
        }
    }
}

/// One problem from your script feed, reduced to what the eye needs: topic, the number, how bad, and a meter when there is one.
struct AttentionItem: Identifiable {
    let app: String
    let severity: String
    let title: String
    let detail: String
    /// Plain-language fields from the script feed; older feeds leave them empty and the tile falls back to the title.
    var feedFigure: String?
    var outcome: String?
    var action: String?
    var meterValue: Double?
    var meterMax: Double?
    var meterLabel: String?
    var id: String { app + "|" + title }

    @MainActor static func all(_ model: AppModel) -> [AttentionItem] {
        let rank = ["critical": 0, "high": 1, "medium": 2, "low": 3]
        return model.snapshots("attention.items").flatMap { event in
            (event.payload[path: "items"]?.array ?? []).map {
                AttentionItem(app: event.app ?? "", severity: $0[path: "severity"]?.string ?? "low",
                              title: $0[path: "title"]?.string ?? "", detail: $0[path: "detail"]?.string ?? "",
                              feedFigure: $0[path: "figure"]?.string, outcome: $0[path: "outcome"]?.string,
                              action: $0[path: "action"]?.string, meterValue: $0[path: "meter.value"]?.number,
                              meterMax: $0[path: "meter.max"]?.number, meterLabel: $0[path: "meter.label"]?.string)
            }
        }
        // The script feed's "new subscribers cancel" alert repeats "Why people stop paying", which shows Apple's own counts on
        // the app's page: it's left out for apps that have them (one place per piece of information).
        .filter { item in !(model.subTruth[ComingSoon.shortName(item.app)] != nil
                            && ((item.outcome ?? "") + " " + item.title).lowercased().contains("cancel")) }
        .sorted { (rank[$0.severity] ?? 4) < (rank[$1.severity] ?? 4) }
    }

    var tint: Color {
        switch severity {
        case "critical", "high": Brand.bad
        case "medium": Brand.caution
        default: .secondary
        }
    }

    /// The detail card for this problem: what, how bad, the evidence, why it matters, the next step.
    var infoModel: InfoModel {
        var m = InfoModel(icon: app.isEmpty || app == "All apps" || app == "Website" ? .symbol(symbol) : .app(app),
                          tint: tint, title: outcome ?? title, subtitle: app.isEmpty ? nil : app)
        m.facts = [m.fact("exclamationmark.circle", "How serious", severityText), m.fact("number", "The number", figure),
                   m.fact("gauge.with.needle", "Measured", meter?.caption), m.fact("text.alignleft", "Found as", outcome == nil ? nil : title)]
            .compactMap { $0 }
        m.paragraphs = detail.isEmpty ? [] : [detail]
        m.next = action
        m.source = "From your script feed's own checks"
        return m
    }

    var severityRank: Int { ["critical": 0, "high": 1, "medium": 2, "low": 3][severity] ?? 4 }

    var severityText: String {
        switch severity {
        case "critical": "Urgent"
        case "high": "Important"
        case "medium": "Worth a look"
        default: "Minor"
        }
    }

    /// An SF Symbol for the topic, guessed from the words used.
    var symbol: String {
        let t = (title + " " + detail).lowercased()
        let topics: [(String, [String])] = [
            ("star.fill", ["rating", "storefront"]), ("text.bubble.fill", ["review"]),
            ("person.2.fill", ["subscri", "churn", "trial"]), ("dollarsign", ["revenue", "price", "$", "proceeds"]),
            ("magnifyingglass", ["keyword", "search"]), ("bolt.trianglebadge.exclamationmark.fill", ["crash", "hang"]),
            ("arrow.down.circle.fill", ["download", "install"]), ("globe", ["locale", "country"]),
        ]
        return topics.first { $0.1.contains { t.contains($0) } }?.0 ?? "exclamationmark"
    }

    /// The first number in the title ("$2.38", "13", "191 days"), shown large.
    var figure: String? {
        if outcome != nil { return feedFigure }
        guard let match = title.firstMatch(of: /\$?\d[\d,]*(\.\d+)?%?(\s(days?|active))?/) else { return nil }
        return String(match.output.0)
    }

    var label: String {
        // The full sentence, never a "…" stand-in for the figure.
        title
    }

    /// A 0…1 meter when the text carries one: "ratio 0.765", "3.667 … rating", "95 of 100".
    var meter: (value: Double, caption: String)? {
        if let v = meterValue, let max = meterMax, max > 0 {
            let shown = max == 1 ? "\(Int(safe: v * 100))%" : max == 100 ? "\(v.formatted(.number.precision(.fractionLength(0...1))))%" : "\(v.formatted(.number.precision(.fractionLength(0...1)))) of \(max.formatted())"
            return (min(v / max, 1), "\(shown) \(meterLabel ?? "")")
        }
        if outcome != nil { return nil }
        if let m = detail.firstMatch(of: /ratio (\d+(\.\d+)?)/), let v = Double(m.output.1) {
            return (min(v, 1), "Churn \(Int(v * 100))%")
        }
        if title.lowercased().contains("rating"), let m = detail.firstMatch(of: /(\d\.\d+)/), let v = Double(m.output.1) {
            return (v / 5, "\(v.formatted(.number.precision(.fractionLength(1)))) of 5 stars")
        }
        if let m = detail.firstMatch(of: /(\d+) of (\d+)/), let a = Double(m.output.1), let b = Double(m.output.2), b > 0 {
            return (a / b, "\(Int(a)) of \(Int(b))")
        }
        return nil
    }
}

struct AttentionTile: View {
    let item: AttentionItem
    let index: Int
    /// Off inside an app's own card, where the app is already obvious.
    var showsApp = true
    @Environment(AppModel.self) private var model: AppModel?
    @State private var open = false

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    if showsApp && model?.iconURL(for: item.app) != nil {
                        AppIcon(app: item.app, size: 30, badge: item.symbol, badgeTint: item.tint)
                            .arrivalBounce(index)
                        Text(item.app).font(.callout).foregroundStyle(.secondary)
                    } else {
                        IconBadge(symbol: item.symbol, tint: item.tint, size: 28)
                            .arrivalBounce(index)
                        if showsApp { Text(item.app).font(.callout).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 4)
                    Text(item.severityText).font(.callout.weight(.semibold))
                        .fixedSize()
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .foregroundStyle(item.tint)
                        .background(item.tint.opacity(0.14), in: Capsule())
                }
                if let figure = item.figure {
                    Text(figure).font(.system(size: 28, weight: .bold)).monospacedDigit()
                        .foregroundStyle(.primary).liveNumber(figure)
                }
                Text(Plain.readable(item.outcome ?? (item.figure == nil ? item.title : item.label)))
                    .font(.callout).foregroundStyle(.primary)
                    .lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 0)
                if let meter = item.meter {
                    VStack(alignment: .leading, spacing: 4) {
                        Gauge(value: meter.value) { EmptyView() }
                            .gaugeStyle(.accessoryLinearCapacity)
                            .tint(item.tint)
                        Text(meter.caption).font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let action = item.action {
                    Label(action, systemImage: "arrow.right.circle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .symbolRenderingMode(.hierarchical)
                        .lineLimit(1).minimumScaleFactor(0.75)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .labelColor).opacity(0.04), in: .rect(cornerRadius: 16))
            .contentShape(.rect(cornerRadius: 16))
        }
        .hoverLift()
        .clickForDetail(item.infoModel)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.severityText): \(item.app), \(item.title). \(item.detail)")
    }
}

/// One labelled bar chart per series: no legend to decode, one colour throughout.
struct SmallMultiples: View {
    struct Series: Identifiable {
        let name: String
        let points: [(Date, Double)]
        var total: Double { points.reduce(0) { $0 + $1.1 } }
        var id: String { name }
    }

    let series: [Series]
    var totalText: (Double) -> String = { $0.formatted(.number.precision(.fractionLength(0))) }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14, alignment: .top)], spacing: 14) {
            ForEach(series) { s in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(s.name).font(.headline)
                        Spacer()
                        Text(totalText(s.total)).font(.headline).monospacedDigit().liveNumber(s.total)
                    }
                    TrendChart(title: "Latest", points: s.points, height: 56, format: totalText)
                }
                .padding(14)
                .background(.quaternary.opacity(0.28), in: .rect(cornerRadius: 16))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(s.name), total \(totalText(s.total))")
            }
        }
    }
}

/// Estimated Apple earnings: the total per month, then one small labelled chart per app.
struct EarningsChart: View {
    let model: AppModel

    var body: some View {
        let months = model.snapshots("earnings.months").first?.payload[path: "months"]?.array ?? []
        let monthDate: (JSONValue) -> Date? = { month in
            guard let label = month[path: "label"]?.string else { return nil }
            let f = DateFormatter()
            f.dateFormat = "MMM yyyy"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f.date(from: label)
        }
        let totals: [(Date, Double)] = months.compactMap { m in monthDate(m).map { ($0, m[path: "usd"]?.number ?? 0) } }
        let appNames = Set(months.flatMap { month -> [String] in
            if case .object(let byApp)? = month[path: "by_app"] { return Array(byApp.keys) }
            return []
        }).sorted()
        let perApp = appNames.map { key in
            SmallMultiples.Series(name: APPName.pretty(key), points: months.compactMap { m in
                monthDate(m).map { ($0, m[path: "by_app.\(key)"]?.number ?? 0) }
            })
        }.sorted { $0.total > $1.total }
        let usd: (Double) -> String = { Money.shared.format($0, from: "USD", decimals: 0) }

        if !totals.isEmpty {
            GlassPanel(title: "Earnings by month · estimated") {
                TrendChart(title: "Total per month", points: totals, height: 170, showAxis: true, format: usd)
                if perApp.count > 1 {
                    SmallMultiples(series: perApp, totalText: usd)
                }
            }
        }
    }
}

@MainActor enum APPName {
    /// Your connected apps' names (from App Store Connect), so "myapp" reads "MyApp", not "Myapp".
    static var known: [String] = []

    /// A file or feed slug ("body_vitals", "my-app") as the app's own name when it is one of your apps;
    /// otherwise the words capitalised.
    static func pretty(_ slug: String) -> String {
        func squash(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        return known.first { squash($0) == squash(slug) }
            ?? slug.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized
    }
}

/// Shades of the one data colour, assigned only to the series a chart actually shows.
enum AppPalette {
    static let shades: [Double] = [1.0, 0.6, 0.34, 0.2]

    /// Apps in name order; "… / other" buckets and "All apps" come last.
    static func scale(for present: Set<String>) -> (domain: [String], range: [Color]) {
        func last(_ n: String) -> Int { n == "All apps" ? 2 : n.lowercased().hasSuffix("/ other") ? 1 : 0 }
        let names = present.sorted { (last($0), $0.lowercased()) < (last($1), $1.lowercased()) }
        return (names, names.indices.map { Brand.data.opacity(shades[min($0, shades.count - 1)]) })
    }
}

extension View {
    func appColors(_ present: Set<String>) -> some View {
        let scale = AppPalette.scale(for: present)
        return chartForegroundStyleScale(domain: scale.domain, range: scale.range)
    }
}

/// Charts draw in from the left once, over 0.8 s; with Reduce Motion they simply appear.
struct DrawIn: ViewModifier {
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sceneActive) private var sceneActive

    func body(content: Content) -> some View {
        content
            .mask(alignment: .leading) {
                GeometryReader { g in
                    Rectangle().frame(width: shown || reduceMotion ? g.size.width + 20 : 0)
                }
            }
            .onAppear { if sceneActive { withAnimation(.easeOut(duration: 0.8)) { shown = true } } }
            .onChange(of: sceneActive) { _, on in
                if on { shown = false; withAnimation(.easeOut(duration: 0.9).delay(0.2)) { shown = true } }
            }
    }
}
