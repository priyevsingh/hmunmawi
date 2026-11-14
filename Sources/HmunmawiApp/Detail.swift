import AppKit
import HmunmawiCore
import SwiftUI

/// What a detail card shows. Every clickable item builds one of these; the card looks the same everywhere,
/// like the purchase card: header, one fact per line with a symbol, a dated chart, why it matters, next step.
struct InfoModel {
    enum Icon { case app(String?), site(String), symbol(String) }
    struct Fact { let symbol: String; let label: String; let value: String }

    var icon: Icon
    var tint: Color
    var title: String
    var subtitle: String?
    var facts: [Fact] = []
    var points: [(Date, Double)] = []
    var paragraphs: [String] = []
    var next: String?
    var source: String?
    /// Facts under small headings (e.g. one group per data source).
    var groups: [(title: String, facts: [Fact])] = []

    /// Drops facts whose value is empty, so the card never shows a blank or a dash.
    func fact(_ symbol: String, _ label: String, _ value: String?) -> Fact? {
        guard let value, !value.isEmpty, value != "–", value != "None" else { return nil }
        return Fact(symbol: symbol, label: label, value: value)
    }
}

struct InfoCard: View {
    let model: InfoModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                switch model.icon {
                case .app(let app): AppIcon(app: app, size: 40)
                case .site(let domain): SiteIcon(domain: domain, size: 40, tint: model.tint)
                case .symbol(let s):
                    IconBadge(symbol: s, tint: model.tint, size: 40)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(Plain.readable(model.title)).font(.headline).fixedSize(horizontal: false, vertical: true)
                    if let subtitle = model.subtitle {
                        Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            if !model.facts.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    ForEach(model.facts.indices, id: \.self) { i in
                        let f = model.facts[i]
                        GridRow {
                            IconBadge(symbol: f.symbol, tint: model.tint, size: 20)
                            Text(f.label).font(.callout).foregroundStyle(.secondary)
                            Text(f.value).font(.callout.weight(.medium)).monospacedDigit().textSelection(.enabled)
                                .lineLimit(1...3).minimumScaleFactor(0.9).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            ForEach(model.groups.indices, id: \.self) { gi in
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.groups[gi].title).font(.callout.weight(.bold)).foregroundStyle(model.tint)
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                        ForEach(model.groups[gi].facts.indices, id: \.self) { i in
                            let f = model.groups[gi].facts[i]
                            GridRow {
                                IconBadge(symbol: f.symbol, tint: model.tint, size: 20)
                                Text(f.label).font(.callout).foregroundStyle(.secondary)
                                Text(f.value).font(.callout.weight(.semibold)).monospacedDigit().lineLimit(1...3).minimumScaleFactor(0.9)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .gridColumnAlignment(.trailing)
                            }
                        }
                    }
                }
            }
            if model.points.count > 1 {
                TrendChart(title: model.title, points: model.points, tint: model.tint, height: 110, showAxis: true, showHeader: false)
            }
            ForEach(model.paragraphs.indices, id: \.self) { i in
                Text(Plain.readable(model.paragraphs[i])).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if let next = model.next {
                Label(Plain.readable(next), systemImage: "arrow.right.circle.fill")
                    .font(.callout.weight(.semibold)).symbolRenderingMode(.hierarchical)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let source = model.source {
                Text(source).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: model.groups.isEmpty ? 400 : 460, alignment: .leading)
    }
}

extension InfoModel {
    /// Any source's details as one glass card: every number and text field as a fact line under its source's
    /// heading, and the first day-by-day series as the chart. Nothing a source sends is hidden.
    @MainActor static func from(_ request: DetailRequest) -> InfoModel {
        var m = InfoModel(icon: .symbol(request.symbol), tint: request.tint == Brand.accent ? Brand.data : request.tint, title: request.title)
        for section in request.sections {
            guard case .object(let fields) = section.payload else { continue }
            var facts: [Fact] = []
            let days = section.payload[path: "days"]?.array?.compactMap(\.string) ?? []
            for (key, value) in fields.sorted(by: { $0.key < $1.key }) where key != "days" && key != "better" && key != "labels" && key != "additive" {
                let label = Self.fieldName(key)
                if let n = value.number {
                    facts.append(Fact(symbol: symbol(for: key), label: label, value: format(n, key)))
                } else if let s = value.string, !s.isEmpty {
                    facts.append(Fact(symbol: symbol(for: key), label: label, value: Labels.readable(s)))
                } else if let arr = value.array {
                    if !days.isEmpty, arr.count == days.count, m.points.isEmpty {
                        m.points = zip(days, arr).compactMap { d, v in
                            guard let n = v.number, let date = try? Date(String(d.prefix(10)) + "T12:00:00Z", strategy: .iso8601) else { return nil }
                            return (date, n)
                        }
                    } else if !arr.isEmpty, arr.first?.number == nil {
                        facts.append(Fact(symbol: "list.bullet", label: label, value: "\(arr.count) item\(arr.count == 1 ? "" : "s")"))
                    }
                }
            }
            if !facts.isEmpty { m.groups.append((section.title, facts)) }
        }
        return m
    }

    /// "subs_net_28d" -> "Subscribers gained, 28 days"; "views_7d" -> "Views, 7 days".
    static func fieldName(_ key: String) -> String {
        var words = key.split(separator: "_").map(String.init)
        var window = ""
        if let last = words.last, last.wholeMatch(of: /\d+d/) != nil { window = ", \(last.dropLast()) days"; words.removeLast() }
        let swaps = ["subs": "subscribers", "net": "gained", "pct": "%", "usd": "(USD)", "inr": "(INR)", "avg": "average"]
        let text = words.map { swaps[$0] ?? $0 }.joined(separator: " ")
        return text.prefix(1).uppercased() + text.dropFirst() + window
    }

    static func symbol(for key: String) -> String {
        let k = key.lowercased()
        let table: [(String, String)] = [("view", "eye"), ("impression", "eye"), ("subscri", "person.2"), ("follower", "person.2"),
            ("video", "play.rectangle"), ("watch", "clock"), ("minute", "clock"), ("click", "cursorarrow.click"),
            ("position", "list.number"), ("usd", "banknote"), ("revenue", "banknote"), ("earn", "banknote"), ("proceed", "banknote"),
            ("rating", "star"), ("review", "text.bubble"), ("date", "calendar"), ("through", "calendar"), ("day", "calendar"),
            ("download", "arrow.down.circle"), ("crash", "bolt"), ("post", "square.and.pencil"), ("engag", "hand.thumbsup"),
            ("version", "number"), ("country", "globe"), ("approved", "checkmark.seal"), ("review", "hourglass")]
        return table.first { k.contains($0.0) }?.1 ?? "circle.fill"
    }

    @MainActor static func format(_ n: Double, _ key: String) -> String {
        let k = key.lowercased()
        if k.contains("usd") { return Money.shared.format(n, from: "USD", decimals: n < 100 ? 2 : 0) }
        if k.contains("inr") { return Money.shared.format(n, from: "INR", decimals: 0) }
        if k.contains("pct") || k.contains("rate") || k.contains("conversion") { return "\(n.formatted(.number.precision(.fractionLength(0...2))))%" }
        return n.formatted(.number.notation(n >= 100_000 ? .compactName : .automatic).precision(.fractionLength(0...2)))
    }
}

/// Opens detail cards with a zoom from the clicked item (one presenter per window).
@Observable @MainActor
final class DetailPresenter {
    var model: InfoModel?
    /// A whole view to zoom open instead of a fact card (e.g. today's story).
    var custom: AnyView?
    /// The width a custom view asks for (nil: as wide as the window allows, up to 1000).
    var customWidth: CGFloat?
    var source: CGRect = .zero
    var expanded = false
    /// Bumped on every show, so a card opened from inside another one animates in, and a late close can't clear it.
    var generation = 0
    /// Esc closes the open card wherever keyboard focus is; listening only while a card is open.
    @ObservationIgnored private var escape: Any?

    var isOpen: Bool { model != nil || custom != nil }

    /// Cards opened from inside an open card stack on top of it: clicking outside (or Esc) goes back one level,
    /// so a detail opened from today's story returns to the story, and only the story's own close leaves.
    private struct Level { let model: InfoModel?; let custom: AnyView?; let width: CGFloat?; let source: CGRect }
    @ObservationIgnored private var below: [Level] = []
    var depth: Int { isOpen ? below.count + 1 : 0 }

    private func pushCurrent() {
        guard isOpen, expanded else { return }   // a card still closing isn't a level to return to
        below.append(Level(model: model, custom: custom, width: customWidth, source: source))
    }

    func show(_ model: InfoModel, from rect: CGRect) {
        pushCurrent()
        source = rect
        custom = nil
        self.model = model
        expanded = false
        generation += 1
        listenForEscape()
    }

    func show(view: AnyView, from rect: CGRect, width: CGFloat? = nil) {
        pushCurrent()
        source = rect
        customWidth = width
        model = nil
        custom = view
        expanded = false
        generation += 1
        listenForEscape()
    }

    private func listenForEscape() {
        guard escape == nil else { return }
        escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.isOpen else { return event }
            self.close()
            return nil
        }
    }

    /// Back one level: to the card underneath when there is one, otherwise closed.
    func close() {
        guard isOpen else { return }
        if let previous = below.popLast() {
            source = previous.source
            customWidth = previous.width
            model = previous.model
            custom = previous.custom
            expanded = false
            generation += 1   // zooms the previous card back in
            return
        }
        closeAll()
    }

    /// Closes every level at once (switching spaces, or opening a fresh story from the toolbar).
    func closeAll() {
        below.removeAll()
        guard isOpen else { return }
        if let escape { NSEvent.removeMonitor(escape); self.escape = nil }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) { expanded = false }
        let closing = generation
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            if !self.expanded && self.generation == closing { self.model = nil; self.custom = nil }
        }
    }
}

/// The open detail card: grows from where it was clicked to the centre over a dimmed backdrop.
/// Only scale, position and opacity animate, so the GPU composites it without redrawing.
struct ZoomedDetail: View {
    let presenter: DetailPresenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { g in
            if presenter.isOpen {
                let frame = g.frame(in: .global)
                let delta = presenter.source == .zero ? .zero : CGSize(width: presenter.source.midX - frame.midX, height: presenter.source.midY - frame.midY)
                let startScale = max(0.25, min(1, presenter.source.width / 400))
                ZStack {
                    Color.black.opacity(presenter.expanded ? 0.28 : 0)
                        .ignoresSafeArea()
                        .contentShape(.rect)
                        .onTapGesture { presenter.close() }
                    Group {
                        if let custom = presenter.custom {
                            if let w = presenter.customWidth { custom.frame(width: w) }
                            else {
                                // A whole story opened in place: as wide as fits, scrolling inside when taller than the window.
                                let w = min(1180, g.size.width - 80), h = g.size.height - 60
                                // ViewThatFits takes the size of the version it picks, so a short story stays short.
                                ViewThatFits(in: .vertical) {
                                    custom.padding(28).frame(width: w)
                                    ScrollView { custom.padding(28) }.frame(width: w, height: h)
                                }
                            }
                        }
                        else if let model = presenter.model {
                            ViewThatFits(in: .vertical) {
                                InfoCard(model: model)
                                ScrollView { InfoCard(model: model) }.frame(height: min(720, g.size.height - 80))
                            }
                        }
                    }
                        .background(Color(nsColor: .windowBackgroundColor), in: .rect(cornerRadius: 22))
                        // Not fixed vertically: the height offered is the window's, so tall stories pick the scrolling version.
                        .fixedSize(horizontal: true, vertical: false)
                        .clipShape(.rect(cornerRadius: 22))
                        // No big blurred shadow: it is recomputed for every frame of the zoom, and the dimmed window behind already
                        // separates the card. A thin edge keeps it crisp.
                        .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 1) }
                        .scaleEffect(presenter.expanded || reduceMotion ? 1 : startScale)
                        .offset(presenter.expanded || reduceMotion ? .zero : delta)
                        .opacity(presenter.expanded ? 1 : 0)
                }
                .frame(width: g.size.width, height: g.size.height)
                .task(id: presenter.generation) {
                    withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.86)) {
                        presenter.expanded = true
                    }
                }

            }
        }
        .allowsHitTesting(presenter.isOpen)
    }
}

/// Click anywhere on the item to open its detail card (zooming from the item; a popover where no presenter exists).
private struct ClickForDetail: ViewModifier {
    let model: InfoModel?
    @Environment(DetailPresenter.self) private var presenter: DetailPresenter?
    @State private var box = FrameBox()
    @State private var open = false

    func body(content: Content) -> some View {
        if let model {
            content
                .contentShape(.rect)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { box.rect = $0 }
                .onTapGesture {
                    if let presenter { presenter.show(model, from: box.rect) } else { open = true }
                }
                .popover(isPresented: $open, arrowEdge: .bottom) { InfoCard(model: model) }
                .help("Click for details")
        } else {
            content
        }
    }
}

extension View {
    func clickForDetail(_ model: InfoModel?) -> some View { modifier(ClickForDetail(model: model)) }
}

extension Date {
    var dayText: String { formatted(.dateTime.day().month(.abbreviated).year()) }
}
