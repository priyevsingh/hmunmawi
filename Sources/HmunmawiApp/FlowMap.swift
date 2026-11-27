import HmunmawiCore
import SwiftUI

/// The business as one journey, read left to right like a sentence, every step over the same 28 days:
/// Seen → Visited → Saw an app → Downloaded → Paid → Earned. Each step is a big number with one plain line;
/// between steps a chip says how many carried on. The weakest step glows amber with one line saying so.
/// When the scene arrives, the steps light up one after another and the line fills between them (one-shot,
/// GPU transforms only). Click a step for its breakdown.
struct FlowMap: View {
    let model: AppModel
    /// The front page's bottom strip: the steps only, smaller, without the notes.
    var compact = false
    @Environment(\.sceneActive) private var sceneActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(DetailPresenter.self) private var presenter: DetailPresenter?
    @State private var lit = 6.0

    struct Part { let name: String; let value: Double; let text: String; var icon: InfoModel.Icon }

    struct Step: Identifiable {
        let id: Int
        let title: String
        let line: String
        let symbol: String
        let tint: Color
        let value: Double
        let text: String
        var parts: [Part] = []
    }

    /// Between two steps: a share that carried on, or a note when the next step isn't the same people.
    struct Link { let text: String; let rate: Double?; let symbol: String? }

    @State private var pulse = 0
    @State private var shine = 0
    @Environment(\.controlActiveState) private var windowState

    var body: some View {
        let steps = build()
        let rates = rates(steps)
        let worst = rates.enumerated().compactMap { i, r in r.map { (i, $0) } }.min { $0.1 < $1.1 }?.0
        VStack(alignment: .leading, spacing: 16) {
            CardHeader(symbol: "point.topleft.down.to.point.bottomright.curvepath.fill", title: "Your journey", tint: Brand.Category.web,
                       caption: "Last \(model.snapshots("flow.snapshot").first?.payload[path: "window"]?.string ?? "28 days")")
            ViewThatFits(in: .horizontal) {
                row(steps, rates, worst, range: 0..<steps.count)
                VStack(alignment: .leading, spacing: 18) {
                    row(steps, rates, worst, range: 0..<min(3, steps.count))
                    if steps.count > 3 { row(steps, rates, worst, range: 3..<steps.count) }
                }
            }
            if !compact, let worst, let r = rates[worst] {
                Label {
                    Text("Biggest drop: only \(Self.pct(r)) \(dropText(worst))")
                } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                    .font(.callout.weight(.semibold)).foregroundStyle(Brand.caution)
                    .opacity(lit >= Double(steps.count) ? 1 : 0)
                    .animation(.smooth(duration: 0.5), value: lit)
            }
            if !compact, !note.isEmpty {
                Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { arrive() }
        .onChange(of: sceneActive) { _, on in if on { arrive() } }
        // A new sale: a pulse runs through Downloaded → Paid → Earned.
        .onChange(of: model.flash?.id) { _, id in if id != nil && !reduceMotion { pulse += 1 } }
        // A shine crosses the money number once when you arrive; after that only a new sale moves anything.
        .task(id: sceneActive) {
            guard sceneActive, !reduceMotion else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { shine += 1 }
        }
    }

    @ViewBuilder
    private func row(_ steps: [Step], _ rates: [Double?], _ worst: Int?, range: Range<Int>) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(range, id: \.self) { i in
                StepTile(step: steps[i], rate: rateLine(i, rates[i]), worst: worst == i, on: lit > Double(i), compact: compact,
                         pulse: i >= 3 ? pulse : 0, shine: i == steps.count - 1 ? shine : 0)
                    .clickForDetail(detail(steps[i]))
                if i < range.upperBound - 1 {
                    Path(tint: steps[i + 1].tint, filled: lit > Double(i) + 0.5, pulse: i >= 3 ? pulse : 0)
                        .padding(.top, compact ? 11 : 16)   // level with the step icons
                }
            }
        }
    }

    private func arrive() {
        guard !reduceMotion else { lit = 6; return }
        lit = 0
        for i in 1...6 {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82).delay(0.15 + Double(i - 1) * 0.32)) { lit = Double(i) }
        }
    }

    private var note: String {
        (model.snapshots("flow.snapshot").first?.payload[path: "notes"]?.array?.compactMap(\.string) ?? []).joined(separator: " ")
    }

    static func pct(_ r: Double) -> String {
        let p = r * 100
        return p < 10 ? String(format: "%.1f%%", p) : "\(Int(p.rounded()))%"
    }

    private func dropText(_ i: Int) -> String {
        switch i {
        case 1: "of people who see you visit your website"
        case 2: "of visitors open an app's page"
        case 4: "of downloads start paying"
        default: "carry on to the next step"
        }
    }

    /// "mostly App Store search (54%)", from where every app's first downloads came from.
    private var downloadSourceLine: String {
        var sums: [String: Double] = [:]
        for app in model.snapshots("app.snapshot") {
            for s in app.payload[path: "downloads_by_source"]?.array ?? [] {
                if let name = s[path: "source"]?.string, let n = s[path: "count"]?.number { sums[name, default: 0] += n }
            }
        }
        let total = sums.values.reduce(0, +)
        guard total > 0, let top = sums.max(by: { $0.value < $1.value }) else { return "incl. App Store search" }
        return "mostly \(top.key) (\(Int((top.value / total * 100).rounded()))%)"
    }

    /// The share of the step before that reached each step (nil where they aren't the same people).
    private func rates(_ s: [Step]) -> [Double?] {
        guard s.count == 6 else { return s.map { _ in nil } }
        func rate(_ a: Step, _ b: Step) -> Double? { a.value > 0 && b.value <= a.value ? b.value / a.value : nil }
        return [nil, rate(s[0], s[1]), rate(s[1], s[2]), nil, rate(s[3], s[4]), nil]
    }

    private func rateLine(_ i: Int, _ r: Double?) -> String? {
        switch i {
        case 1: r.map { "\(Self.pct($0)) of those who saw you" }
        case 2: r.map { "\(Self.pct($0)) of visitors" }
        case 3: downloadSourceLine
        case 4: r.map { "\(Self.pct($0)) of downloads" }
        default: nil
        }
    }

    private func build() -> [Step] {
        let flow = model.snapshots("flow.snapshot").first?.payload
        let sections = model.snapshots("section.snapshot").compactMap(CustomSection.init)
        let funnels = sections.filter { $0.key == "funnel" }
        let usd: (Double) -> String = { Money.shared.format($0, from: "USD", decimals: 0) }

        let sources: [Part] = (flow?[path: "sources"]?.array ?? []).compactMap { s in
            guard let label = s[path: "label"]?.string, let v = s[path: "value"]?.number else { return nil }
            return Part(name: label, value: v, text: CustomSection.format(v, "number"),
                        icon: s[path: "domain"]?.string.map { .site($0) } ?? .symbol("eye"))
        }
        let visitors = flow?[path: "website_visitors"]?.number ?? 0

        var pages: [Part] = [], downloads: [Part] = [], paying: [Part] = [], earned: [Part] = []
        for app in model.snapshots("app.snapshot") {
            guard let name = app.app else { continue }
            let f = funnels.first { $0.app == name }
            func num(_ l: String) -> Double {
                f?.steps.first { $0.label == l }.map { Double($0.value.filter { $0.isNumber || $0 == "." }) ?? 0 } ?? 0
            }
            let page = num("Product page"), dl = num("Downloads"), money = num("Earned")
            // New subscribers in the 28-day window: the rise of the script feed's running total over it. The snapshot's own
            // "new_subscribers" is the total since the feed started counting (about 72 days), not 28.
            let series = model.snapshots("history.series").first { $0.app == name }.map { TrendChart.points($0.payload, "new_subs") } ?? []
            let paid = series.count >= 2 ? max(0, (series.last?.1 ?? 0) - (series.first?.1 ?? 0)) : app.payload[path: "new_subscribers"]?.number ?? 0
            pages.append(Part(name: name, value: page, text: "\(Int(page))", icon: .app(name)))
            downloads.append(Part(name: name, value: dl, text: "\(Int(dl))", icon: .app(name)))
            paying.append(Part(name: name, value: paid, text: "\(Int(paid))", icon: .app(name)))
            earned.append(Part(name: name, value: money, text: usd(money), icon: .app(name)))
        }
        func total(_ p: [Part]) -> Double { p.map(\.value).reduce(0, +) }
        let seen = total(sources)
        return [
            Step(id: 0, title: "Seen", line: sources.prefix(3).map(\.name).joined(separator: " · "), symbol: "eye.fill",
                 tint: Brand.Category.web, value: seen, text: Int(seen).formatted(), parts: sources),
            Step(id: 1, title: "Visited", line: "your website", symbol: "globe",
                 tint: Brand.Category.web, value: visitors, text: Int(visitors).formatted()),
            Step(id: 2, title: "Saw an app", line: "its product page", symbol: "app.badge.fill",
                 tint: Brand.Category.web, value: total(pages), text: Int(total(pages)).formatted(), parts: pages),
            Step(id: 3, title: "Downloaded", line: "from anywhere", symbol: "arrow.down.circle.fill",
                 tint: Brand.Category.users, value: total(downloads), text: Int(total(downloads)).formatted(), parts: downloads),
            Step(id: 4, title: "Paid", line: "new subscribers", symbol: "person.2.fill",
                 tint: Brand.Category.users, value: total(paying), text: Int(total(paying)).formatted(), parts: paying),
            Step(id: 5, title: "Earned", line: "to you", symbol: "banknote.fill",
                 tint: Brand.Category.money, value: total(earned), text: usd(total(earned)), parts: earned),
        ]
    }

    /// Each step's detail, worked out at most once every 5 seconds: the row asks for all six every time it redraws
    /// (animations, hovering), and building them parses snapshots (Instruments, Nov 2026: a fifth of Today's time).
    private static var detailMemo: [String: (at: Date, info: InfoModel)] = [:]

    private func detail(_ s: Step) -> InfoModel {
        let key = "\(s.id)|\(s.title)|\(s.text)"
        if let m = Self.detailMemo[key], Date.now.timeIntervalSince(m.at) < 5 { return m.info }
        let info = buildDetail(s)
        Self.detailMemo[key] = (.now, info)
        return info
    }

    private func buildDetail(_ s: Step) -> InfoModel {
        var c = InfoModel(icon: .symbol(s.symbol), tint: s.tint, title: "\(s.title): \(s.text)", subtitle: "Last 28 days")
        c.facts = s.parts.map { InfoModel.Fact(symbol: s.symbol, label: $0.name, value: $0.text) }
        switch s.id {
        case 0: c.paragraphs = ["How often your apps and pages were shown in search and video."]
        case 1:
            let traffic = model.snapshots("section.snapshot").compactMap(CustomSection.init).first { $0.key == "traffic" }
            c.facts = (traffic?.figures ?? []).compactMap { c.fact("person.3", $0.label, CustomSection.format($0.value, $0.format)) }
                + (traffic?.bars ?? []).compactMap { c.fact($0.symbol ?? "globe", $0.label, CustomSection.format($0.value, "number")) }
            c.paragraphs = ["People who opened your website."]
        case 2: c.paragraphs = ["Website visitors who opened an app's product page."]
        case 3:
            c.paragraphs = ["All downloads, including people who found the app in App Store search, so this can be more than the step before."]
            if let e = model.snapshots("history.series").first { c.points = TrendChart.points(e.payload, "downloads") }
        case 4: c.paragraphs = ["People who started a subscription."]
        default: c.paragraphs = ["What Apple estimates you keep from these 28 days."]
        }
        if let f = model.findings.first(where: { $0.lane == .worry }), s.id == 3 || s.id == 4 { c.next = f.title }
        return c
    }
}

/// One step: a symbol, the big number (rolling up as the light reaches it), its name, and how many of the
/// step before made it here. The weakest step's rate glows amber.
private struct StepTile: View {
    let step: FlowMap.Step
    let rate: String?
    let worst: Bool
    let on: Bool
    var compact = false
    let pulse: Int
    let shine: Int

    var body: some View {
        VStack(spacing: 6) {
            IconBadge(symbol: step.symbol, tint: step.tint, size: compact ? 30 : 40)
                .keyframeAnimator(initialValue: 1.0, trigger: pulse) { v, s in v.scaleEffect(s) } keyframes: { _ in
                    SpringKeyframe(1.25, duration: 0.25); SpringKeyframe(1.0, duration: 0.5)
                }
            Text(step.text)
                .font(compact ? .system(size: 24, weight: .bold) : Kit.number).monospacedDigit()
                .foregroundStyle(step.tint.gradient)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .opacity(on ? 1 : 0.25)
                .animation(.smooth(duration: 0.45), value: on)
                .modifier(Shine(trigger: shine))
            Text(step.title).font(.callout.weight(.semibold)).fixedSize()
            Text(rate ?? step.line)
                .font(.callout.weight(rate == nil ? .regular : .semibold))
                .foregroundStyle(worst ? Brand.caution : rate == nil ? Brand.secondaryText : step.tint)
                .fixedSize()
        }
        .padding(.vertical, 4)
        .frame(minWidth: 116)
        .opacity(on ? 1 : 0.2)
        .scaleEffect(on ? 1 : 0.9)
        .hoverLift()
    }
}

/// A faint light that crosses the text once per trigger (never on its own).
private struct Shine: ViewModifier {
    let trigger: Int

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: -1.2, trigger: trigger) { view, x in
            view.overlay {
                GeometryReader { g in
                    LinearGradient(colors: [.clear, .white.opacity(0.75), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 0.45)
                        .offset(x: x * g.size.width)
                }
                .mask(view)
                .allowsHitTesting(false)
            }
        } keyframes: { _ in
            LinearKeyframe(-1.2, duration: 0.01)
            CubicKeyframe(1.4, duration: 1.3)
        }
    }
}

/// The path between two steps: a clean line that fills in the next step's colour, led by a small light.
private struct Path: View {
    let tint: Color
    let filled: Bool
    let pulse: Int

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Brand.secondaryText.opacity(0.14)).frame(height: 3)
                Capsule().fill(LinearGradient(colors: [tint.opacity(0.35), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(height: 3)
                    .scaleEffect(x: filled ? 1 : 0, anchor: .leading)
                    .animation(.easeInOut(duration: 0.32), value: filled)
                // The light: travels the path once when it fills, and again with every live pulse.
                Circle().fill(.white).frame(width: 8, height: 8)
                    .shadow(color: tint, radius: 6).shadow(color: tint.opacity(0.8), radius: 12)
                    .keyframeAnimator(initialValue: Light(), trigger: LightTrigger(filled: filled, pulse: pulse)) { [travel = g.size.width - 8] v, l in
                        v.offset(x: l.x * travel).opacity(l.alpha)
                    } keyframes: { _ in
                        KeyframeTrack(\.x) { LinearKeyframe(0, duration: 0.01); CubicKeyframe(1, duration: 0.42) }
                        KeyframeTrack(\.alpha) { LinearKeyframe(filled ? 1 : 0, duration: 0.05); LinearKeyframe(filled ? 1 : 0, duration: 0.32); LinearKeyframe(0, duration: 0.2) }
                    }
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .heavy)).foregroundStyle(tint.opacity(filled ? 0.9 : 0.2))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: g.size.height)
        }
        .frame(minWidth: 56, maxWidth: .infinity)
        .frame(height: 8)
        .padding(.horizontal, 6)
    }

    struct Light { var x = 0.0; var alpha = 0.0 }
    struct LightTrigger: Equatable { let filled: Bool; let pulse: Int }
}
