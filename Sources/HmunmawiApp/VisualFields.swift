import Charts
import HmunmawiCore
import SwiftUI

/// Renders any source's data visually: big numbers as tiles, percentages as rings, groups of numbers as bars
/// or a donut, day-by-day series as charts, dates as calendar tiles, countries with flags, lists as cards.
struct VisualFields: View {
    let value: JSONValue
    let tint: Color

    var body: some View {
        if case .object(let fields) = value {
            let parts = Parts(fields)
            VStack(alignment: .leading, spacing: 18) {
                if !parts.gauges.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
                        ForEach(parts.gauges, id: \.0) { RingTile(label: Labels.label($0.0), percent: $0.1, tint: Labels.health($0.0, $0.1)) }
                    }
                }
                if !parts.numbers.isEmpty || !parts.dates.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        ForEach(parts.numbers, id: \.0) { NumberTile(label: Labels.label($0.0), value: $0.1, tint: tint) }
                        ForEach(parts.dates, id: \.0) { DateTile(label: Labels.label($0.0), date: $0.1, tint: tint) }
                    }
                }
                ForEach(parts.series, id: \.0) { key, points in
                    TrendChart(title: Labels.label(key), points: points, tint: tint)
                        .padding(14)
                        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 16))
                }
                ForEach(parts.groups, id: \.0) { key, entries in
                    GroupChart(title: Labels.label(key), entries: entries, tint: tint)
                }
                if !parts.texts.isEmpty {
                    FlowChips(items: parts.texts.map { (Labels.label($0.0), Labels.readable($0.1)) }, tint: tint)
                }
                ForEach(parts.lists, id: \.0) { key, items in
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(Labels.label(key)) · \(items.count)").font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12, alignment: .top)], spacing: 12) {
                            ForEach(Array(items.prefix(40).enumerated()), id: \.offset) { _, item in
                                VisualFields(value: item, tint: tint)
                                    .padding(14)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                    .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 16))
                            }
                        }
                    }
                }
                ForEach(parts.nested, id: \.0) { key, nested in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(Labels.label(key)).font(.headline)
                        VisualFields(value: nested, tint: tint)
                    }
                }
            }
        } else {
            Text(Labels.readable(Labels.text(value)))
        }
    }

    /// Sorts a source's fields by how they're best shown.
    private struct Parts {
        var gauges: [(String, Double)] = []
        var numbers: [(String, Double)] = []
        var dates: [(String, Date)] = []
        var texts: [(String, String)] = []
        var series: [(String, [(Date, Double)])] = []
        var groups: [(String, [(String, Double)])] = []
        var lists: [(String, [JSONValue])] = []
        var nested: [(String, JSONValue)] = []

        init(_ fields: [String: JSONValue]) {
            let days = fields["days"]?.array
            for key in fields.keys.sorted() where key != "days" {
                let field = fields[key] ?? .null
                switch field {
                case .number(let n):
                    if Labels.isPercent(key), n >= 0, n <= 100 { gauges.append((key, n <= 1 ? n * 100 : n)) } else { numbers.append((key, n)) }
                case .string(let s):
                    if let date = Labels.date(s) { dates.append((key, date)) } else if !s.isEmpty { texts.append((key, s)) }
                case .array(let items):
                    if let days, items.count == days.count, items.contains(where: { $0.number != nil }) {
                        series.append((key, TrendChart.points(.object(["days": .array(days), "v": field]), "v")))
                    } else if items.contains(where: { if case .object = $0 { true } else { false } }) {
                        lists.append((key, items))
                    } else if !items.isEmpty {
                        texts.append((key, items.map(Labels.text).joined(separator: ", ")))
                    }
                case .object(let o) where !o.isEmpty:
                    let numeric = o.compactMap { k, v in v.number.map { (k, $0) } }
                    if numeric.count == o.count, numeric.count >= 2 {
                        groups.append((key, numeric.sorted { $0.1 > $1.1 }))
                    } else if let perCountry = Labels.countryRatings(o) {
                        groups.append((key, perCountry))
                    } else {
                        nested.append((key, field))
                    }
                default:
                    break
                }
            }
        }
    }
}

// MARK: Tiles

private struct NumberTile: View {
    let label: String
    let value: Double
    let tint: Color
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let current = shown || reduceMotion ? value : 0
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(current.formatted(.number.notation(.compactName).precision(.fractionLength(0...2))))
                .contentTransition(.numericText(value: current))
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
        .background(.quaternary.opacity(0.28), in: .rect(cornerRadius: 16))
        .onAppear { withAnimation(.smooth(duration: 0.9)) { shown = true } }
    }
}

private struct RingTile: View {
    let label: String
    let percent: Double
    let tint: Color
    @State private var filled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 8) {
            Gauge(value: filled || reduceMotion ? percent : 0, in: 0...100) {
                EmptyView()
            } currentValueLabel: {
                Text(percent.formatted(.number.precision(.fractionLength(0...1))) + "%")
                    .font(.system(.callout, weight: .bold))
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(tint)
            .scaleEffect(1.25)
            .frame(height: 64)
            Text(label).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.28), in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(Int(percent.rounded())) percent")
        .onAppear { withAnimation(.smooth(duration: 1.0)) { filled = true } }
    }
}

private struct DateTile: View {
    let label: String
    let date: Date
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 0) {
                Text(date.formatted(.dateTime.month(.abbreviated)).uppercased())
                    .font(.callout.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
                    .background(tint)
                Text(date.formatted(.dateTime.day()))
                    .font(.system(.title2, weight: .bold))
                    .padding(.vertical, 2)
            }
            .frame(width: 48)
            .background(.background, in: .rect(cornerRadius: 9))
            .clipShape(.rect(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(date.formatted(.dateTime.year())).font(.headline)
                Text(Ago.text(date)).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
        .background(.quaternary.opacity(0.28), in: .rect(cornerRadius: 16))
    }
}

/// A group of numbers: a donut for shares of a whole (up to 6 parts), bars otherwise. Countries get flags.
private struct GroupChart: View {
    let title: String
    let entries: [(String, Double)]
    let tint: Color
    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let scale = grown || reduceMotion ? 1.0 : 0.0
        let shown = Array(entries.prefix(12))
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if shown.count <= 6, shown.allSatisfy({ $0.1 >= 0 }), !shown.contains(where: { Labels.isCountry($0.0) }) {
                HStack(spacing: 24) {
                    Chart(shown, id: \.0) { entry in
                        SectorMark(angle: .value(entry.0, max(entry.1 * scale, 0.0001)), innerRadius: .ratio(0.6), angularInset: 2)
                            .foregroundStyle(Brand.data.opacity(0.9 - 0.1 * Double(shown.firstIndex { $0.0 == entry.0 } ?? 0)))
                            .cornerRadius(4)
                    }
                    .chartLegend(.hidden)
                    .frame(width: 130, height: 130)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(shown, id: \.0) { entry in
                            HStack {
                                Text(Labels.label(entry.0))
                                Spacer()
                                Text(entry.1.formatted(.number.precision(.fractionLength(0...2)))).font(.headline).monospacedDigit()
                            }
                        }
                    }
                }
            } else {
                Chart(shown, id: \.0) { entry in
                    BarMark(x: .value("Value", entry.1 * scale), y: .value("Name", Labels.withFlag(entry.0)))
                        .foregroundStyle(Color.primary.opacity(entry.0 == shown.first?.0 ? 0.7 : 0.3))
                        .cornerRadius(5)
                        .annotation(position: .trailing) {
                            Text(entry.1.formatted(.number.precision(.fractionLength(0...2)))).font(.callout).monospacedDigit()
                        }
                }
                .chartXAxis(.hidden)
                .frame(height: CGFloat(shown.count) * 28 + 10)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 16))
        .onAppear { withAnimation(.smooth(duration: 0.9)) { grown = true } }
    }
}

/// Short text values as labelled chips that wrap.
struct FlowChips: View {
    let items: [(String, String)]
    let tint: Color

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10, alignment: .topLeading)], alignment: .leading, spacing: 10) {
            ForEach(items, id: \.0) { label, text in
                VStack(alignment: .leading, spacing: 3) {
                    Text(label).font(.callout).foregroundStyle(.secondary)
                    Text(Labels.withFlag(text)).font(.callout.weight(.medium)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(.quaternary.opacity(0.22), in: .rect(cornerRadius: 14))
            }
        }
    }
}

// MARK: Labels, dates and flags

enum Labels {
    static let percentHints = ["rate", "conversion", "crash_free", "churn", "pct", "percent", "retention",
                               "first_to_second", "second_to_third", "trial_to_paid", "survival", "ctr"]

    /// Ring colour against a sensible benchmark; grey when there's no fair one.
    static func health(_ key: String, _ percent: Double) -> Color {
        let k = key.lowercased()
        func higher(_ good: Double, _ ok: Double) -> Color { percent >= good ? Brand.good : percent >= ok ? Brand.caution : Brand.bad }
        func lower(_ good: Double, _ ok: Double) -> Color { percent <= good ? Brand.good : percent <= ok ? Brand.caution : Brand.bad }
        if k.contains("crash_free") || k == "crash free" { return higher(99.5, 98) }
        if k.contains("churn") { return lower(10, 25) }
        if k.contains("first_to_second") || k.contains("second_to_third") { return higher(50, 30) }
        if k.contains("trial_to_paid") { return higher(40, 20) }
        if k == "d1" { return higher(40, 25) }
        if k == "d7" { return higher(20, 10) }
        if k == "d28" { return higher(10, 5) }
        return .secondary
    }

    static func isPercent(_ key: String) -> Bool {
        let k = key.lowercased()
        return percentHints.contains { k.contains($0) } || ["d1", "d7", "d28"].contains(k)
    }

    /// "downloads_14d" -> "Downloads 14d"; country codes become "🇺🇸 United States".
    static func label(_ key: String) -> String {
        if isCountry(key) { return withFlag(key) }
        let spaced = key.replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    static func date(_ s: String) -> Date? {
        guard s.count >= 10, s.prefix(10).wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil else { return nil }
        return try? Date(String(s.prefix(10)) + "T12:00:00Z", strategy: .iso8601)
    }

    static func isCountry(_ code: String) -> Bool {
        code.count == 2 && code.allSatisfy(\.isUppercase) && Locale.current.localizedString(forRegionCode: code) != nil
    }

    /// "US" -> "🇺🇸 United States"; anything else unchanged.
    static func withFlag(_ code: String) -> String {
        guard isCountry(code) else { return code }
        let flag = code.unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }.map(String.init).joined()
        return "\(flag) \(Locale.current.localizedString(forRegionCode: code) ?? code)"
    }

    /// Per-country objects like {"US": {"average": 4.6, "count": 12}} become country -> average.
    static func countryRatings(_ object: [String: JSONValue]) -> [(String, Double)]? {
        guard object.keys.allSatisfy(isCountry) else { return nil }
        let pairs = object.compactMap { code, value -> (String, Double)? in
            if let n = value.number { return (code, n) }
            for key in ["average", "rating", "average_rating", "count", "value"] {
                if let n = value[path: key]?.number { return (code, n) }
            }
            return nil
        }
        return pairs.isEmpty ? nil : pairs.sorted { $0.1 > $1.1 }
    }

    /// Codes like READY_FOR_SALE as words ("Ready for sale").
    static func readable(_ s: String) -> String {
        if s.isEmpty { return "None" }
        if let d = date(s) { return d.formatted(.dateTime.day().month(.abbreviated).year()) }
        if s.wholeMatch(of: /[A-Z][A-Z0-9_]+/) != nil, s.contains("_") {
            let words = s.lowercased().replacingOccurrences(of: "_", with: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        }
        return s
    }

    static func text(_ value: JSONValue) -> String {
        switch value {
        case .null: "None"
        case .bool(let b): b ? "Yes" : "No"
        case .number(let n): n.rounded() == n && abs(n) < 1e15 ? String(Int(n)) : String(format: "%.3g", n)
        case .string(let s): s
        case .array(let items): items.map(text).joined(separator: ", ")
        case .object(let o): "\(o.count) fields"
        }
    }
}
