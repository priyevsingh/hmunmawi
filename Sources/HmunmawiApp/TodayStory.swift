import HmunmawiCore
import SwiftUI

/// Every purchase, by day. The newest show at once; older ones load on demand, a page at a time.
/// The greeting for the time of day (midnight to 5 counts as evening).
enum TodayStory {
    static var greeting: String {
        let h = Calendar.current.component(.hour, from: .now)
        // Between 10 pm and 5 am it's neither evening nor morning.
        return (5..<12).contains(h) ? "Good morning" : (12..<17).contains(h) ? "Good afternoon" : (17..<22).contains(h) ? "Good evening" : "Up late"
    }
}

struct PurchasesCard: View {
    let model: AppModel
    @State private var limit = 8
    @State private var rows: [StoredEvent] = []

    var body: some View {
        let days = Dictionary(grouping: rows) { Calendar.current.startOfDay(for: Date(timeIntervalSince1970: Double($0.occurredAt) / 1000)) }
            .sorted { $0.key > $1.key }
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(symbol: "bag.fill", title: model.isDemo ? "Purchases · sample" : "Purchases", tint: Brand.Category.money)
            ForEach(days, id: \.key) { day, list in
                VStack(alignment: .leading, spacing: 10) {
                    Text(Calendar.current.isDateInToday(day) ? "Today" : Calendar.current.isDateInYesterday(day) ? "Yesterday" : day.dayText)
                        .font(.callout).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: 24, alignment: .top)], alignment: .leading, spacing: 10) {
                        ForEach(list) { PaymentRow(event: $0) }
                    }
                }
            }
            if rows.count >= limit {
                Button("Show earlier purchases") { limit += 20 }
                    .buttonStyle(.pill)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentCard(cornerRadius: 22)
        // Again on new purchases, a project switch, or sample <-> live data (not only "Show earlier").
        .task(id: "\(limit)|\(ProjectStore.shared.selectedID ?? "")|\(model.isDemo)|\(model.events.first?.id ?? 0)") {
            rows = await model.purchaseHistory(limit: limit)
        }
    }
}

/// Apps: each app is one full page; swipe (or use the arrows) to move between them.
struct AppsPager: View {
    let model: AppModel
    @State private var current: String?

    /// What Apps says when the picked project has no App Store app. A website project (Hill Trails) has none by design:
    /// say where its numbers are instead of suggesting an app name is missing.
    static func emptyState(_ project: Project) -> (title: String, detail: String) {
        if project.kind == .website {
            return ("\(project.name) is a website",
                    "It has no App Store apps, so there is nothing to show here. Its search, visitors and enquiries are on Today, and its routines on Automations. Pick All projects or an apps project to see apps.")
        }
        return ("No apps in this project",
                "Apps belong to the project whose members include their name. Pick another project, or add the app's name under Settings → Projects.")
    }

    /// What Apps says with no project picked and no app pages yet: how to get them, never a blank page.
    static func emptyState(ascConnected: Bool, isSample: Bool) -> (title: String, detail: String, action: String?) {
        if !ascConnected {
            return ("Your apps will appear here",
                    "Connect App Store Connect and each of your apps gets its own page: sales, reviews, ratings, versions and what Apple is reviewing." + (isSample ? " Today shows sample numbers until then." : ""),
                    "Connect App Store Connect")
        }
        return ("Reading your apps…", "App Store Connect is connected. The first read takes a few minutes; each app's page appears here when it's done.", nil)
    }

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let apps = model.snapshots("app.snapshot")
        let parts = AppPart.all(model: model, apps: apps)
        VStack(spacing: 12) {
            if apps.isEmpty, let project = ProjectStore.shared.selected {
                let empty = Self.emptyState(project)
                ContentUnavailableView(empty.title, systemImage: project.kind == .website ? "globe" : "app.badge",
                                       description: Text(empty.detail))
                    .padding(.top, 40)
            } else if apps.isEmpty, ComingSoon.releases(model).isEmpty {
                let empty = Self.emptyState(ascConnected: SetupState.ascConnected(model), isSample: model.isDemo)
                ContentUnavailableView {
                    Label(empty.title, systemImage: "app.badge")
                } description: {
                    Text(empty.detail)
                } actions: {
                    if let action = empty.action {
                        Button(action) {
                            UserDefaults.standard.set("connections", forKey: "HMSettingsTab")
                            openWindow(id: "settings")
                        }
                        .buttonStyle(.pillProminent)
                    }
                }
                .padding(.top, 40)
            }
            HStack(spacing: 10) {
                ForEach(apps) { app in
                    Button { withAnimation(.smooth) { current = app.app } } label: {
                        HStack(spacing: 8) {
                            AppIcon(app: app.app, size: 22)
                            Text(app.app ?? "").font(.callout.weight(current == app.app ? .semibold : .regular))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(current == app.app ? Color.primary.opacity(0.10) : .clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)   // fills the window (no fixed column)
            .padding(.horizontal, 28).padding(.top, 16)
            ReviewsInboxBanner(model: model).padding(.horizontal, 28)
            // Apps not on the App Store yet have no page of their own, so their launch track sits above.
            let paged = Set(apps.compactMap(\.app))
            ComingSoonStrip(model: model, only: { !paged.contains($0.app) })
                .frame(maxWidth: .infinity)   // fills the window (no fixed column)
                .zIndex(1)   // above the pages' scroll area, which would otherwise take its clicks
                .padding(.horizontal, 28)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(apps) { snapshot in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                // A new version on its way sits at the top of its own app's page.
                                ForEach(ComingSoon.releases(model).filter { $0.app == snapshot.app }) { r in
                                    CardHeader(symbol: "shippingbox.fill", title: "Next version", tint: Brand.Category.users)
                                    LaunchTrack(release: r)
                                    Divider()
                                }
                                ForEach(parts) { AppPartView(part: $0, snapshot: snapshot, model: model, onOpen: {}) }
                                if let name = snapshot.app { AppDiscovery(model: model, app: name) }
                                CompetitorsCard(model: model)
                            }
                            .padding(24)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .contentCard(cornerRadius: 26)
                            .frame(maxWidth: .infinity)   // fills the window (no fixed column)
                            .padding(.horizontal, 28).padding(.bottom, 28)
                        }
                        // `--args -HMScrollY 0.6` opens each app page scrolled that far down (for screenshots); top otherwise.
                        .defaultScrollAnchor(UnitPoint(x: 0.5, y: min(1, max(0, UserDefaults.standard.double(forKey: "HMScrollY")))))
                        .containerRelativeFrame(.horizontal)
                        .id(snapshot.app)
                    }
                }
                .scrollTargetLayout()
            }
            .clipped()
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $current)
            .scrollIndicators(.hidden)
        }
        .onAppear { if current == nil { current = apps.first?.app } }
    }
}

extension View {
    /// Content fills the window at any size, maximized included (no fixed-width column); only the
    /// margins grow a little with the window. Pass a `max` only for a view that must stay narrow.
    func readableWidth(max: CGFloat = .infinity) -> some View { modifier(ReadableWidth(maxWidth: max)) }
}

private struct ReadableWidth: ViewModifier {
    let maxWidth: CGFloat
    @State private var width: CGFloat = 1200

    func body(content: Content) -> some View {
        let margin = Swift.min(56, Swift.max(20, width * 0.03))
        content
            .frame(maxWidth: maxWidth, alignment: .topLeading)
            .padding(.horizontal, margin)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// The living backdrop: the window colour (so text always reads) with soft lights of the scene's colour
/// drifting behind it, drawn by a Metal shader. ~20 frames a second, paused when the window is not active,
/// still with Reduce Motion.
struct SceneBackdrop: View {
    let tint: Color
    /// Changes when a new sale or review arrives: the aura brightens once, then settles.
    var pulse: Int64?
    @State private var boost = 0.0
    /// The mist drifts for a short while after the window comes forward or something new arrives, then holds still,
    /// so an open window that nobody is touching uses no CPU.
    @State private var awake = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var active
    @Environment(\.colorScheme) private var colorScheme
    private var dark: Bool { colorScheme == .dark }
    @MainActor private static var heldT: Float = 0
    private static let library: ShaderLibrary? = Bundle.main.url(forResource: "Hmunmawi", withExtension: "metallib").map { ShaderLibrary(url: $0) }

    var body: some View {
        let paused = reduceMotion || active == .inactive || !awake
        TimelineView(.animation(minimumInterval: 1.0 / 6, paused: paused)) { context in
            // While the page is scrolling the mist holds still (same input = no redraw of the full-window shader);
            // it drifts on again 0.2 s after the scroll stops.
            let t: Float = ScrollGate.active ? Self.heldT : {
                let v = Float(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)); Self.heldT = v; return v }()
            GeometryReader { g in
                if let library = Self.library {
                    // A living backdrop: drifting mist and a glow in the scene's colour that slowly breathes,
                    // brighter for a moment after a new sale.
                    Rectangle().fill(Color(nsColor: .windowBackgroundColor))
                        .colorEffect(library.breathField(.float2(g.size), .float(t),
                                                         .color(Color(nsColor: .windowBackgroundColor)), .color(tint),
                                                         .float2(CGSize(width: g.size.width * 0.5, height: g.size.height * 0.12)),
                                                         .float(boost * 3), .float(0.5 + 0.5 * sin(Double(t) * 0.35)),
                                                         .float(dark ? 1 : 0)))
                        // Flattened to a bitmap that is redrawn only when its inputs change (6 times a second at most), so scrolling
                        // moves a picture instead of re-running the full-window shader on every frame.
                        .drawingGroup()
                } else {
                    Rectangle().fill(Color(nsColor: .windowBackgroundColor))
                }
            }
        }
        .ignoresSafeArea()
        .task(id: "\(active == .inactive)-\(pulse ?? 0)") {
            awake = true
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled { awake = false }
        }
        // (no animation keyed on tint: computed colours compare unequal each frame and restarted a spring)
        .onChange(of: pulse) { _, new in
            guard new != nil, !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.4)) { boost = 0.22 }
            Task { try? await Task.sleep(for: .seconds(1.2)); withAnimation(.easeInOut(duration: 2.5)) { boost = 0 } }
        }
    }
}

extension EnvironmentValues {
    /// True while the scene holding this view is on screen; tiles, numbers and charts animate in when it turns on.
    @Entry var sceneActive: Bool = true
}

/// Content rises in when its scene arrives (and again each time you return to it).
struct Entrance: ViewModifier {
    let active: Bool
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(active || reduceMotion ? 1 : 0)
            .offset(y: active || reduceMotion ? 0 : 26)
            .animation(.spring(response: 0.6, dampingFraction: 0.88).delay(active ? delay : 0), value: active)
    }
}

extension Chapter {
    /// Each scene's colour (category colours; green, orange and red stay for meaning).
    var tint: Color {
        switch self {
        case .pulse, .money: Brand.Category.money
        case .growth: Brand.Category.web
        }
    }
}

/// The day in one line: the top win, but the top worry (with the app named), and the counts.
@MainActor func storySummary(_ model: AppModel) -> (statement: String, number: String?, win: String?, worry: String?) {
        // A summary of the whole day (never a copy of one row): the top win, but the top worry.
        func short(_ f: Finding) -> String {
            let s = f.app.map { f.title.hasPrefix($0 + ": ") ? String(f.title.dropFirst($0.count + 2)) + " (" + $0 + ")" : f.title } ?? f.title
            return s.prefix(1).lowercased() + s.dropFirst()
        }
        let declared = AttentionItem.all(model).filter { $0.severityRank <= 1 }
        let wins = model.findings.filter { $0.lane == .win }
        let worries = model.findings.filter { $0.lane == .worry }
        let worryText = worries.first.map(short) ?? declared.first.map { ($0.outcome ?? $0.title).prefix(1).lowercased() + ($0.outcome ?? $0.title).dropFirst() }
        let statement: String
        switch (wins.first, worryText) {
        case let (w?, b?): statement = (short(w).prefix(1).uppercased() + short(w).dropFirst()) + ", but " + b
        case let (w?, nil): statement = short(w).prefix(1).uppercased() + short(w).dropFirst()
        case let (nil, b?): statement = b.prefix(1).uppercased() + b.dropFirst()
        default: statement = "A steady day: nothing out of the ordinary"
        }
        let counts = "\(min(wins.count, 3)) win\(wins.count == 1 ? "" : "s") · \(min(worries.count + declared.count, 3)) worr\(worries.count + declared.count == 1 ? "y" : "ies") · judged against each number's own normal"
        let winText = wins.first.map { short($0).prefix(1).uppercased() + short($0).dropFirst() }
        return (statement, counts, winText, worryText.map { wins.isEmpty ? $0.prefix(1).uppercased() + $0.dropFirst() : $0 })}
