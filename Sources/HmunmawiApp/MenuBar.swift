import AppKit
import HmunmawiCore
import SwiftUI

/// Opens the app's windows from AppKit (Dock menu, notification taps) with SwiftUI's own action, captured once.
@MainActor enum WindowOpener {
    static var open: OpenWindowAction?
    static func show(page: String? = nil) {
        if let page, let p = Page(rawValue: page.capitalized) { UserDefaults.standard.set(p.rawValue, forKey: "HMPage") }
        if page == "permissions" {
            UserDefaults.standard.set("permissions", forKey: "HMSettingsTab")
            open?(id: "settings")
        } else if page == "settings" {
            open?(id: "settings")
        } else {
            open?(id: "main")
        }
        NSApp.activate()
        // Opened from the menu bar panel: that panel closing hands focus back to the last app, so ask again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { NSApp.activate() }
    }
}

/// The menu bar icon: an "H" with a health dot (green all good, amber a look, red broken, grey not set up or
/// paused), and one optional number. It pulses once on a new purchase (not with Reduce Motion).
struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settings = MenuBarSettings.shared

    var body: some View {
        let counts = ["waiting": model.waiting.count,
                      "problems": model.truth.dot == .idle ? 0 : model.truth.problems.count]  // same list as the dot
        let badge = MenuBarFacts.badge(settings.number.rawValue, events: model.events, isSample: model.isDemo, counts: counts,
                                       hideZero: settings.hideZero, showSymbol: settings.numberSymbol,
                                       amount: { Money.shared.amount($0) }, money: { Money.shared.format($0, from: Money.shared.target, decimals: 0) })
        let pulse = model.flash.map { MenuBarFacts.saleKinds.contains($0.kind) ? $0.id : 0 } ?? 0
        HStack(spacing: 3) {
            // MenuBarExtra labels drop inline symbols in Text, so the symbol is drawn into the icon image.
            Image(nsImage: MenuBarIcon.image(model.truth.dot, symbol: badge?.symbol))
                .symbolEffect(.bounce, value: reduceMotion ? 0 : pulse)
            if let badge { Text(badge.text).monospacedDigit() }
        }
        .task(id: badge.map { "\(settings.number.title): \($0.text)" } ?? "Hmunmawi: \(model.truth.headline)") {
            // MenuBarExtra ignores .help, so the tooltip goes on the status item's own button.
            let tip = badge.map { "\(settings.number.title): \($0.text)" } ?? "Hmunmawi: \(model.truth.headline)"
            try? await Task.sleep(for: .milliseconds(300))
            MenuBarIcon.setTooltip(tip)
        }
        .accessibilityLabel("Hmunmawi, \(model.truth.headline)\(badge.map { ", \(settings.number.title): \($0.text)" } ?? "")")
        .onAppear { WindowOpener.open = openWindow }
    }
}

enum MenuBarIcon {
    /// Drawn at display time so the "H" follows the menu bar's light or dark look; the dot keeps its colour.
    @MainActor static func image(_ dot: HealthTruth.Dot, symbol: String? = nil) -> NSImage {
        let key = "\(dot)|\(symbol ?? "")"
        if let cached = cache[key] { return cached }
        let sym = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        let size = NSSize(width: 20 + (sym.map { $0.size.width + 4 } ?? 0), height: 16)
        let img = NSImage(size: size, flipped: false) { rect in
            if let sym {
                // Tint the template symbol with the menu bar's label colour at draw time.
                let s = sym.size
                let r = NSRect(x: rect.width - s.width, y: (rect.height - s.height) / 2, width: s.width, height: s.height)
                let tinted = NSImage(size: s, flipped: false) { tr in
                    sym.draw(in: tr); NSColor.labelColor.set(); tr.fill(using: .sourceAtop); return true
                }
                tinted.draw(in: r)
            }
            let font = NSFont.systemFont(ofSize: 14, weight: .heavy)
            let h = NSAttributedString(string: "H", attributes: [.font: font, .foregroundColor: NSColor.labelColor])
            let hs = h.size()
            h.draw(at: NSPoint(x: 1, y: (rect.height - hs.height) / 2))
            let color: NSColor = switch dot {
            case .good: .systemGreen
            case .attention: .systemOrange
            case .broken: .systemRed
            case .idle: .systemGray
            }
            let d = NSRect(x: 12.5, y: 1, width: 7, height: 7)
            NSColor.windowBackgroundColor.withAlphaComponent(0.9).setFill()
            NSBezierPath(ovalIn: d.insetBy(dx: -1, dy: -1)).fill()
            color.setFill()
            NSBezierPath(ovalIn: d).fill()
            return true
        }
        img.isTemplate = false
        img.accessibilityDescription = "Hmunmawi"
        cache[key] = img
        return img
    }
    @MainActor private static var cache: [String: NSImage] = [:]

    /// Puts the hover text on this app's menu bar button (found in the status bar windows; no private API).
    @MainActor static func setTooltip(_ tip: String) {
        func buttons(_ v: NSView) -> [NSStatusBarButton] {
            (v as? NSStatusBarButton).map { [$0] } ?? v.subviews.flatMap(buttons)
        }
        for w in NSApp.windows where String(describing: type(of: w)).contains("StatusBar") {
            if let v = w.contentView { buttons(v).forEach { $0.toolTip = tip } }
        }
    }
}

/// The panel under the icon: today, connections (problems first), the live feed, quick numbers, the AI pause
/// (view only), what waits for you, and Open / Check all / Pause / Settings / Quit.
struct MenuBarPanel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var settings = MenuBarSettings.shared
    @State private var checking = false
    @State private var policy = AIPolicyService.shared

    private func open(_ page: String) {
        WindowOpener.open = openWindow
        dismiss()   // the panel closes once it hands you to a window, instead of floating over it
        WindowOpener.show(page: page)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.isDemo {
                Label("Sample numbers until you connect App Store Connect", systemImage: "eye")
                    .font(.callout).foregroundStyle(.secondary)
            }
            // The number beside the icon leads: clicking "3 problems" opens on those problems, "2 waiting" on what waits.
            if settings.number == .problems { connections; needsALook }
            if settings.number == .waiting { waiting }
            let t = MenuBarFacts.today(model.events, amount: { Money.shared.amount($0) })
            section("Today") {
                Text(MenuBarFacts.headline(t, money: { Money.shared.format($0, from: Money.shared.target, decimals: 0) }))
                    .font(.headline)
            }
            if settings.number != .problems { connections; needsALook }
            feed
            if settings.showQuickNumbers { quickNumbers }
            aiPause
            macPermissions
            if settings.number != .waiting { waiting }
            if let p = settings.pauseText { Label(p, systemImage: "bell.slash").font(.callout).foregroundStyle(.secondary) }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: MenuBarIcon.image(model.truth.dot))
            Text("Hmunmawi").font(.headline)
            Spacer()
            Label(model.truth.headline, systemImage: model.truth.symbol)
                .font(.callout.weight(.medium)).foregroundStyle(model.truth.color)
        }
    }

    @ViewBuilder private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content()
        }
    }

    @ViewBuilder private var connections: some View {
        let rows = model.status.connections.sorted { (!$0.healthy ? 0 : 1, $0.name) < (!$1.healthy ? 0 : 1, $1.name) }
        if !rows.isEmpty {
            section("Connections") {
                if rows.allSatisfy(\.healthy) {
                    HStack(spacing: 4) {
                        ForEach(rows) { c in Circle().fill(Brand.good).frame(width: 7, height: 7).help(c.name) }
                        Text("All \(rows.count) working").font(.callout).foregroundStyle(.secondary).padding(.leading, 4)
                    }
                    .accessibilityElement(children: .ignore).accessibilityLabel("All \(rows.count) connections working")
                } else {
                    let broken = rows.filter { !$0.healthy }
                    Text("\(rows.count - broken.count) of \(rows.count) working").font(.callout).foregroundStyle(.secondary)
                    ForEach(broken.prefix(5)) { c in
                        Button { open("settings") } label: {
                            HStack(spacing: 6) {
                                Circle().fill(c.healthy ? Brand.good : Brand.bad).frame(width: 7, height: 7)
                                Text(c.name).font(.callout)
                                Spacer()
                                if !c.healthy { Text("Fix").font(.callout).foregroundStyle(.secondary) }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if broken.count > 5 { Text("and \(broken.count - 5) more in Settings").font(.caption).foregroundStyle(.secondary) }
                }
            }
        } else if !model.isDemo {
            EmptyView()
        }
    }

    /// What makes the dot amber or red, named (the header only counts it). Connections and permissions have their
    /// own rows, so only the rest is listed here.
    @ViewBuilder private var needsALook: some View {
        let shown = Set(model.status.connections.filter { !$0.healthy }.map(\.name))
        let rest = model.truth.dot == .attention || model.truth.dot == .broken
            ? model.truth.problems.filter { p in !shown.contains { p.hasPrefix($0) } } : []
        if !rest.isEmpty {
            section(model.truth.dot == .broken ? "Needs fixing" : "Needs a look") {
                ForEach(rest.prefix(3), id: \.self) { p in
                    Button { open("today") } label: {
                        Label(p, systemImage: "exclamationmark.circle").font(.callout).lineLimit(2)
                            .foregroundStyle(model.truth.color)
                    }
                    .buttonStyle(.plain)
                }
                if rest.count > 3 { Text("and \(rest.count - 3) more on Today").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder private var feed: some View {
        let items = MenuBarFacts.feed(model.events, limit: settings.feedCount)
        if !items.isEmpty {
            section(model.isDemo ? "Latest (sample)" : "Latest") {
                ForEach(items) { e in
                    Button { open(e.kind == "review.new" || e.kind == "asc.webhook" || e.kind == "ci.build" ? "apps" : "today") } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: icon(e.kind)).foregroundStyle(tint(e)).frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.app ?? "Hmunmawi").font(.callout.weight(.medium)).lineLimit(1)
                                Text(Self.line(e)).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Text(Date(timeIntervalSince1970: Double(e.occurredAt) / 1000), format: .relative(presentation: .named))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// The feed line without repeating the app name already shown above it; old raw ping titles read plainly.
    static func line(_ e: StoredEvent) -> String {
        var s = EventText.describe(e)
        if s.hasPrefix("webhookPingCreated") { return "Apple's test ping arrived: live updates work" }
        if let app = e.app, s.hasSuffix(" for \(app)") { s.removeLast(" for \(app)".count) }
        return s
    }

    private func icon(_ kind: String) -> String {
        switch kind {
        case "revenue.purchase": "bag.fill"
        case "revenue.renewal": "arrow.triangle.2.circlepath"
        case "revenue.refund", "revenue.cancelled": "arrow.uturn.backward"
        case "review.new": "star.fill"
        default: "shippingbox.fill"
        }
    }
    private func tint(_ e: StoredEvent) -> Color {
        if e.kind.hasPrefix("revenue.refund") || e.kind == "revenue.cancelled" || e.payload[path: "rejected"] == .bool(true) { return Brand.bad }
        if e.kind == "review.new" { return (e.payload[path: "rating"]?.number ?? 5) <= 2 ? Brand.caution : Brand.Category.users }
        return e.kind.hasPrefix("revenue.") ? Brand.good : .secondary
    }

    @ViewBuilder private var quickNumbers: some View {
        let ev = model.isDemo ? [] : model.events
        let x = OwnerConfig.current.usesXFileFeed || !XFileFeed.shared.path.isEmpty ? MenuBarFacts.latest(ev, kind: "growth.x", field: "followers") : nil
        let yt = MenuBarFacts.latest(ev, kind: "growth.youtube", field: "subscribers")
        let visitors = MenuBarFacts.latest(ev, kind: "analytics.daily_users", field: "users")
        let subs = model.isDemo ? nil : model.mrr?.total.latest.map { Double($0.active) }
        let items: [(String, String, Double)] = [("Subscribers", "creditcard", subs), ("On X", "person.2", x), ("On YouTube", "play.rectangle", yt),
                                                 ("Visitors, 1 day", "person.3", visitors)].compactMap { a in a.2.map { (a.0, a.1, $0) } }
        if !items.isEmpty {
            section("Numbers") {
                // Equal columns, so the gaps match whatever the numbers and labels are.
                HStack(alignment: .top, spacing: 8) {
                    ForEach(items, id: \.0) { i in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(MenuBarFacts.compact(i.2) ?? Int(i.2).formatted()).font(.headline).monospacedDigit()
                            Text(i.0).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    @ViewBuilder private var aiPause: some View {
        if OwnerConfig.current.showsAIPause {
            let snap = AIPolicyDisplay.parse(policy.statusJSON, loadFailed: policy.lastError != nil && policy.statusJSON.isEmpty)
            section("AI routines") {
                Text(AIPolicyDisplay.headline(snap)).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            .task { await policy.refresh() }
        }
    }

    @ViewBuilder private var macPermissions: some View {
        let missing = Permissions.shared.snapshot.requiredMissing
        if !missing.isEmpty {
            section("Needs permission") {
                ForEach(missing) { item in
                    Button { open("permissions") } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.shield").foregroundStyle(Brand.caution)
                            Text("Needs permission: \(item.title)").font(.callout).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Text("Fix").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private var waiting: some View {
        if !model.waiting.isEmpty {
            section("Waiting for you") {
                ForEach(model.waiting.prefix(3)) { w in
                    Button { open("log") } label: {
                        Label(w.title, systemImage: "hand.raised.fill").font(.callout).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(.plain)
                }
                if model.waiting.count > 3 { Text("and \(model.waiting.count - 3) more in Log").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Open") { open("today") }.keyboardShortcut("o")
            Button(checking ? "Checking…" : "Check all") {
                checking = true
                Task { await model.checkAll(); checking = false }
            }
            .disabled(checking || model.isDemo)
            Menu(settings.notificationsPaused ? "Paused" : "Pause") {
                if settings.notificationsPaused { Button("Resume notifications") { settings.resume(); model.updateTruth() } }
                Button("For 1 hour") { settings.pause(.hour); model.updateTruth() }
                Button("Until tomorrow") { settings.pause(.untilTomorrow, quiet: model.quietHours); model.updateTruth() }
                Button("Until I switch them on") { settings.pause(.untilOn); model.updateTruth() }
            }
            .fixedSize()
            Spacer()
            Button { open("settings") } label: { Image(systemName: "gearshape") }.help("Settings").accessibilityLabel("Settings")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Quit Hmunmawi").accessibilityLabel("Quit Hmunmawi")
        }
        .controlSize(.small)
    }
}
