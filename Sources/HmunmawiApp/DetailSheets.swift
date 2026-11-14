import HmunmawiCore
import SwiftUI

/// A detail sheet's frame: a title bar with Done, and scrolling content on the aurora.
struct DetailSheet<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss
    @Environment(DetailPresenter.self) private var presenter: DetailPresenter?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 10) { IconBadge(symbol: symbol, tint: tint, size: 30); Text(title).font(.title2.weight(.bold)).foregroundStyle(tint) }
                Spacer()
                // Shown as a zoom card inside the window: close the card, never the window.
                Button("Close") { if let presenter, presenter.isOpen { presenter.close() } else { dismiss() } }
                    .buttonStyle(.pillProminent)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(24)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) { content }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 560, idealHeight: 720)
    }
}

// MARK: Everything a source sent

/// What a clicked card asks to show.
struct DetailRequest: Identifiable {
    let title: String
    let symbol: String
    let tint: Color
    let sections: [DataDetail.Section]
    var id: String { title }

    /// Every source of `kinds` for one app (or all apps when `app` is nil).
    @MainActor
    static func make(_ title: String, _ symbol: String, _ tint: Color, model: AppModel,
                     kinds: [(String, String)], app: String? = nil) -> DetailRequest {
        let sections = kinds.flatMap { kind, label in
            model.snapshots(kind).filter { app == nil || $0.app == app }
                .map { DataDetail.Section(title: app == nil && ($0.app ?? "").isEmpty == false ? "\(label) · \($0.app!)" : label,
                                          payload: $0.payload) }
        }
        return DetailRequest(title: title, symbol: symbol, tint: tint, sections: sections)
    }
}


/// Shows every field of one or more sources: numbers and text as labelled rows, day-by-day series as charts,
/// and lists as rows. Nothing a source sends is hidden.
struct DataDetail: View {
    struct Section: Identifiable {
        let title: String
        let payload: JSONValue
        var id: String { title }
    }

    let title: String
    let symbol: String
    let tint: Color
    let sections: [Section]

    var body: some View {
        DetailSheet(title: title, symbol: symbol, tint: tint) {
            if sections.isEmpty {
                Text("Waiting for the first numbers to land. Kettle's on").foregroundStyle(.secondary)
            }
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 12) {
                    Text(section.title).font(.headline)
                    VisualFields(value: section.payload, tint: Brand.data)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentCard(cornerRadius: 20)
            }
        }
    }
}

private struct JSONFields: View {
    let value: JSONValue
    let tint: Color

    var body: some View {
        if case .object(let fields) = value {
            let keys = fields.keys.sorted()
            let days = fields["days"]?.array
            VStack(alignment: .leading, spacing: 10) {
                ForEach(keys.filter { $0 != "days" }, id: \.self) { key in
                    let field = fields[key] ?? .null
                    if let days, let values = field.array, values.count == days.count, values.contains(where: { $0.number != nil }) {
                        TrendChart(title: Self.label(key), points: TrendChart.points(.object(["days": .array(days), "v": field]), "v"),
                                   tint: tint)
                    } else {
                        row(key, field)
                    }
                }
            }
        } else {
            Text(Self.text(value)).font(.callout)
        }
    }

    @ViewBuilder
    private func row(_ key: String, _ field: JSONValue) -> some View {
        switch field {
        case .object(let nested) where !nested.isEmpty:
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.label(key)).font(.subheadline.weight(.semibold))
                JSONFields(value: field, tint: tint).padding(.leading, 12)
            }
        case .array(let items) where items.contains(where: { if case .object = $0 { true } else { false } }):
            VStack(alignment: .leading, spacing: 8) {
                Text("\(Self.label(key)) · \(items.count)").font(.subheadline.weight(.semibold))
                ForEach(Array(items.prefix(40).enumerated()), id: \.offset) { _, item in
                    JSONFields(value: item, tint: tint)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
                }
            }
        default:
            HStack(alignment: .firstTextBaseline) {
                Text(Self.label(key)).foregroundStyle(.secondary)
                Spacer(minLength: 16)
                Text(Self.text(field)).multilineTextAlignment(.trailing).textSelection(.enabled)
            }
            .font(.callout)
        }
    }

    /// Dates with the year ("29 Oct 2026") and codes like READY_FOR_SALE as words ("Ready for sale").
    static func readable(_ s: String) -> String {
        if s.isEmpty { return "None" }
        if s.count >= 10, s.prefix(10).wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil {
            return Format.fullDay(.string(s))
        }
        if s.wholeMatch(of: /[A-Z][A-Z0-9_]+/) != nil, s.contains("_") {
            let words = s.lowercased().replacingOccurrences(of: "_", with: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        }
        return s
    }

    /// "downloads_14d" -> "Downloads 14d"
    static func label(_ key: String) -> String {
        let spaced = key.replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    static func text(_ value: JSONValue) -> String {
        switch value {
        case .null: "None"
        case .bool(let b): b ? "Yes" : "No"
        case .number(let n): n.rounded() == n && abs(n) < 1e15 ? String(Int(n)) : String(format: "%.3g", n)
        case .string(let s): readable(s)
        case .array(let items): items.isEmpty ? "None" : items.map(text).joined(separator: ", ")
        case .object(let o): o.isEmpty ? "None" : "\(o.count) fields"
        }
    }
}

// MARK: Startup programs

struct ProgramsDetail: View {
    let payload: JSONValue

    private static let groups: [(status: String, title: String, tint: Color)] = [
        ("approved", "Approved", Brand.good), ("review", "In review", Brand.caution),
        ("next", "Apply next", .primary), ("later", "Later", .secondary),
    ]

    var body: some View {
        let items = payload[path: "items"]?.array ?? []
        DetailSheet(title: "Startup programs", symbol: "gift.fill", tint: Brand.accent) {
            StatGrid(stats: [
                Stat(label: "Approved", value: Format.number(payload[path: "approved"])),
                Stat(label: "In review", value: Format.number(payload[path: "in_review"])),
            ])
            .padding(18)
            .contentCard(cornerRadius: 22)

            ForEach(Self.groups, id: \.status) { group in
                let programs = items.filter { $0[path: "status"]?.string == group.status }
                if !programs.isEmpty {
                    Text("\(group.title) · \(programs.count)")
                        .font(.headline)
                        .foregroundStyle(group.tint)
                        .padding(.top, 6)
                    ForEach(Array(programs.enumerated()), id: \.offset) { _, program in
                        ProgramCard(program: program, tint: group.tint)
                    }
                }
            }
        }
    }
}

private struct ProgramCard: View {
    let program: JSONValue
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(program[path: "name"]?.string ?? "Program").font(.title3.weight(.semibold))
                Spacer()
                Text(program[path: "value_label"]?.string ?? Format.usd(program[path: "value_usd"]))
                    .font(.headline)
                    .foregroundStyle(tint)
            }
            if let plan = program[path: "plan"], let name = plan[path: "name"]?.string {
                Label("\(name)\(plan[path: "seats"]?.string.map { " · \($0)" } ?? "")", systemImage: "checkmark.seal.fill")
                    .font(.callout)
                if plan[path: "from"]?.string != nil || plan[path: "until"]?.string != nil {
                    Text("\(Format.fullDay(plan[path: "from"])) → \(Format.fullDay(plan[path: "until"]))")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let perks = program[path: "perks"]?.array?.compactMap(\.string), !perks.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(perks.prefix(6), id: \.self) { perk in
                        Label(perk, systemImage: "sparkle").font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(spacing: 16) {
                dateChip("Applied", program[path: "applied"])
                dateChip("Decided", program[path: "decided"])
                dateChip("Expires", program[path: "expires"])
                if let by = program[path: "by"]?.string, !by.isEmpty {
                    Text("Next step by \(by)").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(cornerRadius: 20)
    }

    @ViewBuilder
    private func dateChip(_ label: String, _ value: JSONValue?) -> some View {
        if let s = value?.string, !s.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.callout).foregroundStyle(.secondary)
                Text(Format.fullDay(value)).font(.callout.weight(.semibold))
            }
        }
    }
}
