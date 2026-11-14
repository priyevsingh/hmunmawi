import HmunmawiCore
import SwiftUI

/// Today's story: the engine's strongest wins and worries, and the next steps, three of each.
struct StoryBoard: View {
    let model: AppModel

    var body: some View {
        let wins = Array(model.findings.filter { $0.lane == .win }.prefix(3))
        // Worries: the engine's findings plus the problems the data itself declares (urgent and important).
        let declared = AttentionItem.all(model).filter { $0.severityRank <= 1 }.map { item in
            Finding(id: "declared|" + item.id, lane: .worry, detector: .declared, app: item.app,
                    title: item.app + ": " + (item.outcome ?? item.title), evidence: item.feedFigure ?? item.severityText,
                    why: item.detail, score: item.severityRank == 0 ? 2.5 : 1.5)
        }
        let worries = Array((model.findings.filter { $0.lane == .worry } + declared).sorted { $0.score > $1.score }.prefix(3))
        // The same action for several apps becomes one line naming them all.
        let sectionTodos = model.snapshots("section.snapshot").compactMap(CustomSection.init).filter { !model.replacedByApp($0) }.flatMap(\.items)
            .map { item -> AttentionItem in var i = item; if i.action == nil { i.action = i.outcome ?? i.title }; return i }
        let next = Array(Dictionary(grouping: (AttentionItem.all(model) + sectionTodos).filter { $0.action != nil }, by: { $0.action! })
            .compactMap { _, items -> AttentionItem? in
                guard var first = items.first else { return nil }
                if items.count > 1 { first.outcome = (first.outcome ?? first.title) + " · " + items.map(\.app).joined(separator: ", ") }
                return first
            }
            .sorted { ($0.severityRank, $0.app) < ($1.severityRank, $1.app) }.prefix(3))
        VStack(alignment: .leading, spacing: 14) {
            EqualRowsGrid(minWidth: 300, spacing: 20) {
                Lane(title: "WIN", symbol: "sparkles", tint: Brand.good, empty: "Flatline, the good kind. No fireworks today") {
                    ForEach(Array(wins.enumerated()), id: \.element.id) { i, f in FindingRow(finding: f, rank: i + 1) }
                }
                Lane(title: "WORRY", symbol: "exclamationmark.triangle.fill", tint: Brand.bad, empty: "Zero worries. Your numbers are suspiciously well-behaved") {
                    ForEach(Array(worries.enumerated()), id: \.element.id) { i, f in FindingRow(finding: f, rank: i + 1) }
                }
                Lane(title: "NEXT", symbol: "arrow.right.circle.fill", tint: .primary, empty: "Nothing needs you. Go touch grass, it's handled") {
                    ForEach(Array(next.enumerated()), id: \.element.id) { i, item in NextRow(item: item, rank: i + 1) }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentCard(cornerRadius: 22)
    }
}

private struct Lane<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    let empty: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) { IconBadge(symbol: symbol, tint: tint, size: 18); Text(title).font(.callout.weight(.bold)).foregroundStyle(tint) }
            Group(subviews: content) { rows in
                if rows.isEmpty {
                    Text(empty).font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { $0 }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct FindingRow: View {
    let finding: Finding
    let rank: Int
    @State private var open = false

    private var model: InfoModel {
        let tint = finding.lane == .win ? Brand.good : finding.lane == .worry ? Brand.bad : Brand.secondaryText
        var m = InfoModel(icon: finding.app.map { .app($0) } ?? .symbol("chart.line.uptrend.xyaxis"), tint: tint,
                          title: sentence, subtitle: finding.app ?? "All apps")
        let how = ["unusual": "Unusual against its own normal", "newLevel": "Settled at a new level",
                   "trend": "A steady trend", "record": "A record", "declared": "Flagged by your data"][finding.detector.rawValue]
        m.facts = [m.fact(finding.lane == .win ? "sparkles" : "exclamationmark.triangle", finding.lane == .win ? "Win" : "Worry", finding.evidence),
                   m.fact("arrow.triangle.branch", "Driven by", finding.driver.map { String($0.dropFirst("mostly ".count)) }),
                   m.fact("waveform.path.ecg", "How it was found", how),
                   m.fact("calendar", "Data through", finding.points.last.map { $0.day.dayText })].compactMap { $0 }
        m.points = finding.points.map { ($0.day, $0.value) }
        m.paragraphs = [finding.why]
        m.source = "Judged against this number's own last 28 days"
        return m
    }

    static func num(_ v: Double) -> String {
        v.rounded() == v || abs(v) >= 10 ? Int(safe: v.rounded()).formatted() : v.formatted(.number.precision(.fractionLength(1)))
    }

    private var sentence: String {
        guard let app = finding.app, finding.title.hasPrefix(app + ": ") else { return finding.title }
        return String(finding.title.dropFirst(app.count + 2))
    }

    var body: some View {
        let tint = finding.lane == .win ? Brand.good : Brand.bad
        HStack(alignment: .center, spacing: 10) {
            if finding.app != nil {
                AppIcon(app: finding.app, size: 28)
            } else {
                IconBadge(symbol: "chart.line.uptrend.xyaxis", tint: tint, size: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                // The figure leads, big and glowing; the sentence underneath in full (no cut-off).
                Text(finding.evidence).font(.title3.bold()).monospacedDigit().foregroundStyle(Kit.vibrant(tint))
                    .fixedSize(horizontal: false, vertical: true)
                Text([sentence, finding.driver].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            // Only for slow moves (a trend or a new level): for a one-day spike or a record, a three-week
            // average can point the other way and contradict the sentence.
            if finding.points.count >= 14, [.trend, .newLevel].contains(finding.detector) {
                // Before -> now as daily averages (a week three weeks ago vs this week), so it agrees with the
                // sentence and isn't thrown by one odd day. Click the row for the full chart.
                let recent = finding.points.suffix(21).map(\.value)
                let before = recent.prefix(7).reduce(0, +) / Double(min(7, recent.count))
                let now = recent.suffix(7).reduce(0, +) / Double(min(7, recent.count))
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(Self.num(before)) → \(Self.num(now))")
                        .font(.callout.bold()).monospacedDigit().foregroundStyle(Kit.vibrant(tint))
                    Text("3 weeks ago → now").font(.caption).foregroundStyle(.secondary)
                }
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("About \(Self.num(before)) three weeks ago, \(Self.num(now)) now")
            }

        }
        .clickForDetail(model)
        .arrival(rank)
    }
}

private struct NextRow: View {
    let item: AttentionItem
    let rank: Int

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(app: item.app, size: 28, badge: item.symbol, badgeTint: item.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(Plain.readable(item.action ?? item.title)).font(.body).fixedSize(horizontal: false, vertical: true)
                Text(Plain.readable(item.outcome ?? item.title)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .clickForDetail(item.infoModel)
        .arrival(rank)
    }
}
