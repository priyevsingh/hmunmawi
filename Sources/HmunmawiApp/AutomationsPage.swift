import HmunmawiCore
import SwiftUI

/// Automations: the living flow (where data comes from → who works on it → where it lands), then the day's
/// heatmap. On arrival the day replays as light travelling along each line in the order jobs ran; after that
/// a line only moves when a real run changes. Hover a node to light its paths; click a worker to open it.
struct AutomationsPage: View {
    let model: AppModel
    @State private var scrolling = false   // true while the page is being scrolled: the map's moving light waits

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What runs by itself, and where it goes").font(.callout).foregroundStyle(.secondary)
                    Kit.glow(FlowModel.cached(model).headline, tint: FlowModel.cached(model).headline.contains("need") ? Brand.caution : Brand.good)
                        .font(.largeTitle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LivingFlow(model: model, scrolling: scrolling)
                AutomationDay(model: model)
                AutomationExtras(model: model)
            }
            .readableWidth()
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .onScrollPhaseChange { _, phase in scrolling = phase != .idle }
    }
}

/// The map's data: each job as a worker, with a source and a destination worked out from its words
/// (or given by the feed as "from"/"to"), coloured by who runs it.
@MainActor struct FlowModel {
    struct Node: Hashable, Identifiable { let id: String; let title: String; let symbol: String }
    struct Worker: Identifiable {
        let id: String
        let title: String
        let who: String          // mac, bot, cloud, you
        let from: Node
        let to: Node
        let status: String       // ran, failed, missed, due, later, untracked
        let firstMinute: Int
        let run: AutomationDay.Run?
    }
    let workers: [Worker]

    private static var memo: (key: Int, project: String?, flow: FlowModel)?

    /// What the cached map depends on, the picked project included.
    static func memoKey(day: Int, live: Bool, mode: String?, project: String?) -> Int {
        var h = Hasher()
        h.combine(day); h.combine(live); h.combine(mode); h.combine(project)
        return h.finalize()
    }

    /// The same map, built once and reused until what it is made of changes (the page asks for it for every node).
    private static var checkedAt = Date.distantPast

    static func cached(_ model: AppModel) -> FlowModel {
        // Read the picked project first: it makes the page redraw on a project switch, and it is part of the key, so
        // "2 of 2 jobs" from Hill Trails never stays on screen after switching back to All projects.
        let project = ProjectStore.shared.selectedID
        if let m = memo, Date.now.timeIntervalSince(checkedAt) < 1, m.project == project { return m.flow }
        checkedAt = .now
        let key = memoKey(day: AutomationDay.cacheKey(model), live: LivePurchases.shared.deployed,
                          mode: UserDefaults.standard.string(forKey: "HMLiveMode"), project: project)
        if let m = memo, m.key == key { return m.flow }
        let flow = FlowModel(model)
        memo = (key, project, flow)
        return flow
    }

    init(_ model: AppModel) {
        let runs = AutomationDay.runs(model)
        var seen = Set<String>()
        var out: [Worker] = []
        for r in runs where seen.insert(r.title).inserted {
            let mine = runs.filter { $0.title == r.title }
            let status = mine.contains { $0.status == "failed" } ? "failed" : mine.contains { $0.status == "missed" } ? "missed"
                : mine.contains { $0.status == "ran" } ? "ran" : mine.first?.status ?? "later"
            let text = r.title + " " + r.detail
            // The title decides first (its description often lists several sources), then the description.
            let from = Self.source(r.title).id == "store" ? Self.source(text) : Self.source(r.title)
            let to = Self.destination(r.title).id == "report" ? Self.destination(text) : Self.destination(r.title)
            out.append(Worker(id: r.title, title: r.title, who: r.bot ? "bot" : "mac", from: r.title.lowercased().contains("refresh") ? Self.source("") : from, to: to,
                              status: status, firstMinute: r.minute, run: r))
        }
        // Live sales are about your apps: not shown under a website or other project.
        let appsInScope = ProjectStore.shared.selected.map { $0.kind == .apps } ?? true
        if appsInScope, LivePurchases.shared.deployed || UserDefaults.standard.string(forKey: "HMLiveMode") == "history" {
            out.append(Worker(id: "live", title: "Live sales", who: "cloud", from: Node(id: "apple", title: "Apple sales", symbol: "storefront"),
                              to: Node(id: "mac", title: "This Mac", symbol: "desktopcomputer"), status: "ran", firstMinute: 0, run: nil))
        }
        if !model.waiting.isEmpty {
            out.append(Worker(id: "you", title: "Waiting for your OK", who: "you", from: Node(id: "rules", title: "Your rules", symbol: "bolt.badge.automatic"),
                              to: Node(id: "log", title: "Log", symbol: "tray.full.fill"), status: "due", firstMinute: 0, run: nil))
        }
        // Fewer crossings: group jobs by where their data comes from, then by where it lands.
        let order = Dictionary(grouping: out, by: \.from.id).keys.sorted()
        workers = out.sorted { (order.firstIndex(of: $0.from.id) ?? 0, $0.to.title, $0.firstMinute) < (order.firstIndex(of: $1.from.id) ?? 0, $1.to.title, $1.firstMinute) }
    }

    /// Sources and destinations in the order their jobs appear, so lines run mostly straight across.
    var sources: [Node] { workers.map(\.from).reduce(into: [Node]()) { if !$0.contains($1) { $0.append($1) } } }
    var destinations: [Node] {
        // Each destination sits near the middle of the jobs that feed it.
        let idx = Dictionary(grouping: workers.indices, by: { workers[$0].to })
        return idx.keys.sorted { Double(idx[$0]!.reduce(0, +)) / Double(idx[$0]!.count) < Double(idx[$1]!.reduce(0, +)) / Double(idx[$1]!.count) }
    }

    var headline: String {
        let failed = workers.filter { $0.status == "failed" || $0.status == "missed" }.count
        let ran = workers.filter { $0.status == "ran" }.count
        if failed > 0 { return "\(failed) \(failed == 1 ? "routine needs" : "routines need") a look; \(ran) ran fine today." }
        return workers.isEmpty ? "No scheduled routines yet." : "\(ran) of \(workers.count) routines have run today, all fine."
    }

    static func source(_ t: String) -> Node {
        let s = t.lowercased()
        // A job about one of your website projects (its name, a member, or the name's first word, e.g. "Sunny" for "Sunny Trips").
        if let site = ProjectStore.shared.projects.first(where: { p in
            guard p.kind == .website else { return false }
            let first = p.name.split(separator: " ").first.map(String.init) ?? ""
            return ([p.name, first.count >= 4 ? first : ""] + p.members).contains { !$0.isEmpty && s.contains($0.lowercased()) }
        }) { return Node(id: "site-\(site.id)", title: "\(site.name) site", symbol: "globe") }
        if s.contains("youtube") { return Node(id: "yt", title: "YouTube", symbol: "play.rectangle.fill") }
        if s.contains(" x ") || s.hasPrefix("x ") || s.contains("x reply") || s.contains("x post") || s.contains("x draft") { return Node(id: "x", title: "X", symbol: "bubble.left.and.text.bubble.right.fill") }
        if s.contains("google") || s.contains("bing") || s.contains("search") || s.contains("seo") { return Node(id: "search", title: "Search", symbol: "magnifyingglass") }
        if s.contains("mail") || s.contains("press contact") { return Node(id: "mail", title: "Mail", symbol: "envelope.fill") }
        if s.contains("python") || s.contains("homebrew") { return Node(id: "mac", title: "This Mac", symbol: "desktopcomputer") }
        if s.contains("site") || s.contains("article") || s.contains("page") { return Node(id: "site", title: "Your website", symbol: "globe") }
        return Node(id: "store", title: "App Store & numbers", symbol: "chart.bar.fill")
    }

    static func destination(_ t: String) -> Node {
        let s = t.lowercased()
        if s.contains("imessage") || s.contains("reminder") || s.contains("phone") || s.contains("to xor") { return Node(id: "phone", title: "iPhone", symbol: "iphone") }
        if s.contains("pr ") || s.contains("pr.") || s.contains("prs") || s.contains("merge") { return Node(id: "github", title: "Website PRs", symbol: "arrow.triangle.pull") }
        if s.contains("caption") || s.contains("instagram") || s.contains("short") || s.contains("post") { return Node(id: "social", title: "Social posts", symbol: "person.2.wave.2.fill") }
        if s.contains("calendar") { return Node(id: "cal", title: "Calendar", symbol: "calendar") }
        if s.contains("portal") || s.contains("card") || s.contains("refresh") { return Node(id: "portal", title: "Dashboards", symbol: "rectangle.3.group.fill") }
        if s.contains("python") || s.contains("fixes") { return Node(id: "mac", title: "This Mac", symbol: "desktopcomputer") }
        return Node(id: "report", title: "Reports", symbol: "doc.text.fill")
    }

    static func tint(_ who: String) -> Color {
        switch who {
        case "bot": Brand.Category.users
        case "cloud": Brand.Category.money
        case "you": Brand.Category.video   // its own colour: amber means "didn't run"
        default: Brand.Category.web
        }
    }
}

/// The flow itself: three columns of glass nodes joined by curved lines, with travelling light.
struct LivingFlow: View {
    let model: AppModel
    var scrolling = false
    @State private var frames: [String: CGRect] = [:]
    @State private var hoverTask: Task<Void, Never>?
    @State private var hovered: String?
    @State private var replay: Date?          // set on arrival: the day plays back for a few seconds
    @State private var replaying = false      // true only while that playback runs (a real state, so the
                                              // timeline below is told to pause when it ends)
    @Environment(DetailPresenter.self) private var presenter: DetailPresenter?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let replaySeconds = 12.0     // the day plays back slowly, like a calm breath
    private static let glide = 2.6               // seconds for one dot to cross one line

    var body: some View {
        let flow = FlowModel.cached(model)
        KitCard {
            CardHeader(symbol: "point.3.connected.trianglepath.dotted", title: "Who runs what", tint: Brand.Category.web,
                       caption: "Mac · \(BotName.current) · Cloud · You")
            HStack(alignment: .top, spacing: 0) {
                column("Comes from", flow.sources.map { ($0.id, $0.title, $0.symbol, Brand.secondaryText, nil as String?) })
                    .frame(minWidth: 210, maxWidth: .infinity)
                Spacer(minLength: 90)
                column("Who works on it", flow.workers.map { ("w:" + $0.id, $0.title, symbol(for: $0), FlowModel.tint($0.who), $0.status) }, workers: flow.workers)
                    .frame(minWidth: 260, maxWidth: .infinity)
                Spacer(minLength: 90)
                column("Lands in", flow.destinations.map { ($0.id + ":to", $0.title, $0.symbol, Brand.secondaryText, nil as String?) })
                    .frame(minWidth: 210, maxWidth: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
            .coordinateSpace(name: "flow")
            .background { lines(flow) }
            legend
        }
        .onAppear { if !reduceMotion { replay = .now; replaying = true } }
        // Scrolling ends the arrival playback and any hover glow at once: the moving-light layer leaves the view tree, so
        // a scroll only ever moves finished pictures (the playback otherwise redrew a card-sized canvas 30 times a second).
        .onChange(of: scrolling) { _, now in if now { replaying = false; hovered = nil } }
        // End the playback with a state change: the timeline's "paused" is only re-read when the view
        // updates, so a clock comparison alone left it drawing 30 times a second forever (~45% CPU idle).
        .task(id: replay) {
            guard replay != nil else { return }
            try? await Task.sleep(for: .seconds(Self.replaySeconds + Self.glide + 0.2))
            if !Task.isCancelled { replaying = false }
        }
    }

    // MARK: Columns and nodes

    private func column(_ title: String, _ nodes: [(String, String, String, Color, String?)], workers: [FlowModel.Worker] = []) -> some View {
        let spread = workers.isEmpty   // sources and destinations spread down the full height, beside their jobs
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            ForEach(Array(nodes.enumerated()), id: \.element.0) { i, n in
                if spread && i > 0 { Spacer(minLength: 6) }
                node(id: n.0, label: n.1, symbol: n.2, tint: n.3, status: n.4, worker: workers.first { "w:" + $0.id == n.0 })
            }
            if spread { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, maxHeight: spread ? .infinity : nil, alignment: .topLeading)
    }

    private func node(id: String, label: String, symbol: String, tint: Color, status: String?, worker: FlowModel.Worker?) -> some View {
        let dim = hovered != nil && !related(id, to: hovered!, model: FlowModel.cached(model))
        return HStack(spacing: 10) {
            IconBadge(symbol: symbol, tint: tint, size: 26, flat: true)
            Text(label).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let status {
                Circle().fill(Self.statusColor(status)).frame(width: 8, height: 8)
                    .ripple(Self.statusColor(status), trigger: status)
                    .help(Self.statusText(status))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        // A flat tint, not a live-blur material: a map of 25 nodes with a blur behind each was the page's biggest drawing cost.
        .background(Color.primary.opacity(0.045), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(hovered == id ? 0.8 : 0.18), lineWidth: hovered == id ? 2 : 1))
        .opacity(dim ? 0.35 : 1)
        .animation(.smooth(duration: 0.25), value: hovered)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("flow")) } action: { frames[id] = $0 }
        // Hover takes effect after 0.1 s of staying put (leaving is instant): while you scroll, the map slides under a
        // resting pointer, and without this every node it passes flips the whole map's hover state on every tick.
        .onHover { inside in
            hoverTask?.cancel()
            if inside && ScrollGate.active { return }
            if inside {
                hoverTask = Task { try? await Task.sleep(for: .milliseconds(100)); if !Task.isCancelled { hovered = id } }
            } else if hovered == id { hovered = nil }
        }
        .onTapGesture { if let worker { open(worker, id: id) } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label)\(status.map { ", " + Self.statusText($0) } ?? "")")
    }

    private func symbol(for w: FlowModel.Worker) -> String {
        switch w.who { case "bot": "sparkles"; case "cloud": "cloud.fill"; case "you": "hand.raised.fill"; default: "gearshape.2.fill" }
    }

    private func related(_ id: String, to h: String, model flow: FlowModel) -> Bool {
        if id == h { return true }
        for w in flow.workers {
            let ids = [w.from.id, "w:" + w.id, w.to.id + ":to"]
            if ids.contains(h) && ids.contains(id) { return true }
        }
        return false
    }

    // MARK: Lines and light

    private func lines(_ flow: FlowModel) -> some View {
        // Worked out once per change here, not inside the 30-per-second drawing.
        let ordered = flow.workers.sorted { $0.firstMinute < $1.firstMinute }
        let litIDs: Set<String>? = hovered.map { h in Set(ordered.filter { related("w:" + $0.id, to: h, model: flow) }.map(\.id)) }
        struct Seg { let order: Int; let worker: FlowModel.Worker; let p: CGPoint; let q: CGPoint; let tint: Color; let lit: Bool }
        var segs: [Seg] = []
        for (i, w) in ordered.enumerated() {
            guard let a = frames[w.from.id], let m = frames["w:" + w.id], let b = frames[w.to.id + ":to"] else { continue }
            let lit = litIDs?.contains(w.id) ?? true
            let tint = w.status == "failed" ? Brand.bad : w.status == "missed" ? Brand.caution : FlowModel.tint(w.who)
            for (p, q) in [(CGPoint(x: a.maxX, y: a.midY), CGPoint(x: m.minX, y: m.midY)), (CGPoint(x: m.maxX, y: m.midY), CGPoint(x: b.minX, y: b.midY))] {
                segs.append(Seg(order: i, worker: w, p: p, q: q, tint: tint, lit: lit))
            }
        }
        let count = max(ordered.count, 1)
        return ZStack {
            // The lines themselves: drawn when the map or the hover changes, not every frame.
            Canvas { g, _ in
                for s in segs {
                    var path = Path()
                    path.move(to: s.p)
                    path.addCurve(to: s.q, control1: CGPoint(x: (s.p.x + s.q.x) / 2, y: s.p.y), control2: CGPoint(x: (s.p.x + s.q.x) / 2, y: s.q.y))
                    g.stroke(path, with: .color(s.tint.opacity(s.lit ? 0.45 : 0.08)),
                             style: StrokeStyle(lineWidth: s.lit ? 2 : 1, dash: s.worker.status == "untracked" || s.worker.status == "later" ? [4, 5] : []))
                }
            }
            // Flattened into one bitmap, redrawn only when the map or the hover changes: the 50 curves are no longer
            // re-rasterised while the page scrolls (measured: the lines were the flow map's whole scroll cost).
            .drawingGroup()
            // The travelling light: a few small dots, the only thing that moves each frame. Moves along the paths you're
            // hovering, or during the arrival replay; otherwise it is paused.
            // Not in the view tree at all while nothing moves, so an idle map has no timeline or second layer.
            if hovered != nil || replaying {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: scrolling)) { ctx in
                Canvas { g, _ in
                    let elapsed = replay.map { ctx.date.timeIntervalSince($0) } ?? 99
                    for s in segs {
                        let start = Double(s.order) / Double(count) * (Self.replaySeconds - Self.glide)
                        var t = (elapsed - start) / Self.glide
                        // While a path is hovered, its dots keep gliding slowly round.
                        if hovered != nil, litIDs?.contains(s.worker.id) == true {
                            t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.glide + 0.8) / Self.glide
                        }
                        if (0...1).contains(t), s.worker.status != "later" {
                            let e = t * t * (3 - 2 * t)          // ease in and out
                            let pt = Self.point(on: s.p, s.q, e)
                            let fade = sin(.pi * t)              // appears and fades softly
                            g.fill(Path(ellipseIn: CGRect(x: pt.x - 10, y: pt.y - 10, width: 20, height: 20)), with: .color(s.tint.opacity(0.12 * fade)))
                            g.fill(Path(ellipseIn: CGRect(x: pt.x - 3, y: pt.y - 3, width: 6, height: 6)), with: .color(s.tint.opacity(0.85 * fade)))
                        }
                    }
                }
            }
            }
        }
        .allowsHitTesting(false)
    }

    /// A point along the same curve the line uses.
    static func point(on p: CGPoint, _ q: CGPoint, _ t: Double) -> CGPoint {
        let c1 = CGPoint(x: (p.x + q.x) / 2, y: p.y), c2 = CGPoint(x: (p.x + q.x) / 2, y: q.y)
        let u = 1 - t
        let x = u*u*u*p.x + 3*u*u*t*c1.x + 3*u*t*t*c2.x + t*t*t*q.x
        let y = u*u*u*p.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*q.y
        return CGPoint(x: x, y: y)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                Text("Lines: who runs it").font(.callout.weight(.semibold))
                ForEach([("Mac", "mac"), (BotName.current, "bot"), ("Cloud", "cloud"), ("You", "you")], id: \.0) { name, who in
                    Label { Text(name) } icon: { Capsule().fill(FlowModel.tint(who)).frame(width: 16, height: 3) }
                }
                Label { Text("Later or not tracked") } icon: { Capsule().stroke(Brand.secondaryText, style: StrokeStyle(lineWidth: 2, dash: [3, 3])).frame(width: 16, height: 2) }
                Spacer()
                Text("Hover to follow a path · click a routine to open it")
            }
            HStack(spacing: 8) {
                Text("Dots: what happened today").font(.callout.weight(.semibold))
                DotKey()
            }
        }
        .font(.callout).foregroundStyle(.secondary)
    }

    // MARK: Opening a job

    private func open(_ w: FlowModel.Worker, id: String) {
        guard let presenter, let rect = frames[id] else { return }
        let window = NSApp.keyWindow?.frame ?? .zero
        presenter.show(view: AnyView(JobDetail(worker: w, model: model)), from: CGRect(x: window.width / 2, y: rect.minY + 200, width: rect.width, height: rect.height), width: 560)
    }

    static func statusColor(_ s: String) -> Color {
        switch s { case "ran": Brand.good; case "failed": Brand.bad; case "missed": Brand.caution; case "due": Brand.Category.web; default: Brand.secondaryText.opacity(0.5) }
    }

    static func statusText(_ s: String) -> String {
        switch s { case "ran": "ran today"; case "failed": "failed"; case "missed": "didn't run"; case "due": "due now"; case "untracked": "not tracked"; default: "later today" }
    }
}

/// One job, zoomed open: what it does, where it goes, today's result, and its controls.
private struct JobDetail: View {
    let worker: FlowModel.Worker
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(symbol: worker.who == "bot" ? "sparkles" : "gearshape.2.fill", title: worker.title, tint: FlowModel.tint(worker.who),
                       caption: worker.who == "bot" ? BotName.current : worker.who == "cloud" ? "Cloud" : worker.who == "you" ? "You" : "Mac")
            if let r = worker.run {
                Text(r.detail).font(.callout).fixedSize(horizontal: false, vertical: true)
                Label("\(worker.from.title) → \(worker.to.title)", systemImage: "arrow.right").font(.callout.weight(.semibold))
                HStack {
                    Label(LivingFlow.statusText(worker.status).capitalized, systemImage: "circle.fill")
                        .foregroundStyle(LivingFlow.statusColor(worker.status)).font(.callout.weight(.semibold))
                    if let d = r.statusDetail { Text("· " + d).font(.callout).foregroundStyle(.secondary) }
                    Spacer()
                    JobMenu(run: r, model: model)
                }
            }
        }
        .padding(24)
    }
}
