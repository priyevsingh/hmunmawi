import AppKit
import HmunmawiCore
import SwiftUI

/// Today > Share: the card with every option beside it. Periods appear only when the stored history covers them.
struct ShareWeekSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("HMCardShape") private var shape: CardShape = .square
    @AppStorage("HMCardLook") private var look: CardLook = .night
    @AppStorage("HMCardExact") private var exact = false
    @AppStorage("HMCardCurrency") private var currency: CardCurrency = .local
    @AppStorage("HMCardApps") private var showApps = true
    @AppStorage("HMCardHero") private var hero: CardHero = .auto
    @AppStorage("HMCardPeriod") private var period: SharePeriod = .week
    /// The apps the card covers; empty = all apps (the combined card).
    @State private var chosen: Set<String> = []
    @State private var icons: [String: NSImage] = [:]
    @State private var note: String?
    @State private var anchor = ShareAnchor()
    /// History read once when the window opens (one sender per app and day), and what's worked out from it.
    @State private var daily: [StoredEvent] = []
    @State private var mrr: MRRSummary?
    @State private var bounds: (Date, Date)?
    @State private var allApps: [String] = []              // most downloads first
    @State private var periods: [SharePeriod] = []
    @State private var stats: PeriodStats?
    @State private var quietApps: Set<String> = []          // nothing in the chosen period
    @State private var loaded = false
    /// A website or business project's own numbers (a tour site: WhatsApp taps, Google clicks, posts live).
    @State private var site: [ShareMetric] = []
    @State private var source: ShareSource = .sales
    @AppStorage("HMCardSiteHero") private var siteHero = "auto"

    private var ratesReady: Bool { Money.shared.convert(1, from: "USD") != nil }
    private var options: CardOptions { CardOptions(shape: shape, look: look, exact: exact, currency: ratesReady ? currency : .usd, showApps: showApps, hero: hero) }
    private var current: SharePeriod { periods.contains(period) ? period : (periods.first ?? .week) }
    private var appColor: NSColor? { stats?.best.flatMap { icons[$0.name] }.flatMap(NSColor.average(of:)) }

    /// What the card can be about for the picked project: apps keep sales, websites their own numbers, All projects both.
    private var sources: [ShareSource] {
        ShareSource.offered(hasSales: stats != nil, hasSite: !site.isEmpty, project: ProjectStore.shared.selected?.kind)
    }
    private var shown: ShareSource { sources.contains(source) ? source : (sources.first ?? .sales) }
    private var siteName: String {
        if let p = ProjectStore.shared.selected { return p.name }
        return shown == .everything ? "My projects" : (ProjectStore.shared.projects.first { $0.kind != .apps }?.name ?? "My website")
    }
    /// The website card's numbers; Everything adds the apps' downloads (and earnings, only with exact amounts).
    private var siteMetrics: [ShareMetric] {
        guard shown == .everything, let s = stats else { return site }
        return ShareSource.salesMetrics(s, exact: exact, currency: Money.shared.target, convert: { Money.shared.convert($0, from: "USD") }) + site
    }
    private var siteHeroMetric: ShareMetric? { ProjectShare.hero(siteMetrics, choice: siteHero) }
    private var hasCard: Bool { shown == .sales ? stats != nil : siteHeroMetric != nil }
    /// Money controls only when the card can show money.
    private var showsMoney: Bool { stats != nil && shown != .site }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            preview.frame(width: 520, height: 520)
            controls.frame(width: 320)
        }
        .padding(24)
        .task { await load() }
        .onChange(of: period) { recompute() }
        .onChange(of: chosen) { recompute() }
    }

    @ViewBuilder private var preview: some View {
        if shown != .sales, let h = siteHeroMetric {
            let size = shape.size
            let scale = min(520 / size.width, 520 / size.height)
            ProjectShareCard(name: siteName, metrics: siteMetrics, hero: h, options: options)
                .scaleEffect(scale)
                .frame(width: size.width * scale, height: size.height * scale)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
                .frame(width: 520, height: 520)
        } else if let s = stats {
            let size = shape.size
            let scale = min(520 / size.width, 520 / size.height)
            ShareCard(stats: s, options: options, icons: icons, appColor: appColor)
                .scaleEffect(scale)
                .frame(width: size.width * scale, height: size.height * scale)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
                .frame(width: 520, height: 520)
        } else if loaded, !chosen.isEmpty {
            ContentUnavailableView("Nothing to share for \(chosenLabel) yet", systemImage: "chart.bar",
                                   description: Text("No sales, downloads or subscriptions in this period. Try another period or app."))
        } else if !loaded {
            ProgressView()
        } else {
            let notApps = ProjectStore.shared.selected.map { $0.kind != .apps } ?? false
            ContentUnavailableView("Nothing to share yet", systemImage: "chart.bar",
                                   description: Text(notApps
                                       ? "This card uses the project's own numbers on Today (WhatsApp taps, Google Search, blog posts). They appear once one of its sources has reported."
                                       : "Apple's daily sales reports fill this in once App Store Connect is connected."))
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Share").font(.title2.bold())
            // Only the periods the history covers (Quarter and Year appear once there's enough of it).
            if sources.count > 1 {
                Picker("Card", selection: Binding(get: { shown }, set: { source = $0 })) {
                    ForEach(sources) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
            }
            if shown == .sales {
                Picker("Period", selection: $period) { ForEach(periods) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
                if allApps.count > 1 { appsMenu }
            }
            Picker("Shape", selection: $shape) { ForEach(CardShape.allCases) { Text($0.rawValue).tag($0) } }
            Text(shape.hint).font(.caption).foregroundStyle(.secondary)
            Picker("Look", selection: $look) { ForEach(CardLook.allCases) { Text($0.rawValue).tag($0) } }
            if shown == .sales {
                Picker("Big number", selection: $hero) { ForEach(CardHero.allCases) { Text($0.rawValue).tag($0) } }
            } else {
                Picker("Big number", selection: $siteHero) {
                    Text("Automatic").tag("auto")
                    ForEach(siteMetrics) { Text($0.label).tag($0.id) }
                }
            }
            if showsMoney {
                Picker("Money", selection: $exact) {
                    Text("Growth only").tag(false)
                    Text("Exact amounts").tag(true)
                }.pickerStyle(.segmented)
            }
            // Only when your currency isn't already the dollar; yours (and both) wait for exchange rates.
            if showsMoney, shown == .sales, exact, Money.shared.target != "USD" {
                let t = Money.shared.target
                Picker("Amounts in", selection: $currency) {
                    Text("\(CardText.flag(t)) \(t) · yours").tag(CardCurrency.local)
                    Text("🇺🇸 USD · as Apple reports it").tag(CardCurrency.usd)
                    Text("Both").tag(CardCurrency.both)
                }
                .disabled(!ratesReady)
                if !ratesReady { Text("Exchange rates loading: showing US dollars for now.").font(.caption).foregroundStyle(.secondary) }
                else if currency != .usd { Text("Your currency is converted at today's rate, so it's marked ≈.").font(.caption).foregroundStyle(.secondary) }
            }
            Toggle(shown == .sales ? "Show app names and icons" : "Show the project name", isOn: $showApps)
            Spacer(minLength: 8)
            if let note { Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            actions
        }
    }

    /// The actions: three equal secondary buttons with icons, then Share as the main one, then Done.
    private var actions: some View {
        VStack(spacing: 10) {
            Grid(horizontalSpacing: 8) {
                GridRow {
                    Button { copyImage() } label: { action("Copy", "doc.on.doc") }
                    Button { save() } label: { action("Save PNG", "square.and.arrow.down") }
                    Button { copyCaption() } label: { action("Caption", "text.quote") }
                }
            }
            .buttonStyle(.bordered).controlSize(.large).disabled(!hasCard)
            Button { if let img = render() { anchor.share(img) } } label: {
                Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).disabled(!hasCard)
            .background(ShareAnchorView(anchor: anchor).frame(width: 1, height: 1), alignment: .bottom)
            Button { dismiss() } label: { Text("Done").frame(maxWidth: .infinity) }.keyboardShortcut(.cancelAction).buttonStyle(.bordered).controlSize(.large)
        }
    }

    private var chosenLabel: String {
        switch chosen.count { case 0: "All apps"; case 1: chosen.first!; default: "\(chosen.count) apps" }
    }

    /// All apps (the combined card), one app, or a few. Apps with nothing in the period are shown but can't be picked.
    private var appsMenu: some View {
        LabeledContent("Card covers") {
            Menu {
                Toggle("All apps", isOn: Binding(get: { chosen.isEmpty }, set: { if $0 { chosen = [] } }))
                Divider()
                ForEach(allApps, id: \.self) { name in
                    let quiet = quietApps.contains(name) && !chosen.contains(name)
                    let title = quiet ? "\(name) · nothing this \(current == .week ? "week" : "period")" : name
                    Toggle(title, isOn: Binding(get: { chosen.contains(name) }, set: { on in
                        if on { chosen.insert(name) } else { chosen.remove(name) }
                        if chosen.count == allApps.count { chosen = [] }   // every app ticked = the combined card
                    }))
                    .disabled(quiet)
                }
            } label: {
                HStack(spacing: 6) {
                    if chosen.count == 1, let n = chosen.first, let img = icons[n] {
                        Image(nsImage: img).resizable().frame(width: 16, height: 16).clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    Text(chosenLabel).lineLimit(1)
                }
            }
            .menuStyle(.button).fixedSize()
        }
    }

    private func action(_ title: String, _ symbol: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.title3)
            Text(title).font(.caption).lineLimit(1).fixedSize()
        }
        .frame(maxWidth: .infinity).padding(.vertical, 6)
    }

    private func load() async {
        guard let store = model.liveStore else { return }
        let since = Millis(Date.now.addingTimeInterval(-800 * 86_400).timeIntervalSince1970 * 1000)
        // The picked project only, like every other number on screen (all projects when none is picked).
        let rows = ((try? await store.events(kind: "revenue.daily", since: since)) ?? []).filter { ProjectStore.shared.shows($0.app) }
        let mrrRows = ((try? await store.events(kind: "subscription.mrr", since: since)) ?? []).filter { ProjectStore.shared.shows($0.app) }
        daily = AppModel.oneSourcePerDay(rows)
        mrr = MRRSummary(mrrRows)
        bounds = PeriodStats.coverage(daily, nil)
        var totals: [String: (Double, Double)] = [:]
        for e in daily {
            let n = e.app ?? "Your app"; var v = totals[n] ?? (0, 0)
            v.0 += e.payload[path: "units"]?.number ?? 0; v.1 += e.payload[path: "proceeds_usd"]?.number ?? 0; totals[n] = v
        }
        site = ProjectShare.metrics(model)
        allApps = totals.sorted { ($0.value.0, $0.value.1, $1.key) > ($1.value.0, $1.value.1, $0.key) }.map(\.key)
        loaded = true
        recompute()
        await loadIcons()
    }

    /// Works the card out again; only when the period or the apps change (the looks don't touch the numbers).
    private func recompute() {
        let rows = chosen.isEmpty ? daily : daily.filter { chosen.contains($0.app ?? "Your app") }
        let b = chosen.isEmpty ? nil : bounds
        periods = PeriodStats.available(daily: rows, bounds: b)
        let points: [MRRModel.Point]
        if chosen.isEmpty { points = mrr?.total.points ?? [] }
        else { points = MRRModel.total(chosen.compactMap { mrr?.apps[$0]?.points }) }
        var s = PeriodStats.make(current, daily: rows, mrr: points, bounds: b)
        if !chosen.isEmpty { s?.subject = allApps.filter(chosen.contains) }
        stats = (s?.isEmpty ?? true) && !chosen.isEmpty ? nil : s
        // Which apps had nothing in this period (judged on the account's own dates).
        quietApps = Set(allApps.filter { name in
            let one = daily.filter { ($0.app ?? "Your app") == name }
            guard let st = PeriodStats.make(current, daily: one, mrr: mrr?.apps[name]?.points ?? [], bounds: bounds) else { return true }
            return st.isEmpty
        })
    }

    // MARK: Rendering and sharing

    /// The card at its exact pixel size.
    func render() -> NSImage? {
        if shown != .sales {
            guard let h = siteHeroMetric else { return nil }
            let r = ImageRenderer(content: ProjectShareCard(name: siteName, metrics: siteMetrics, hero: h, options: options))
            r.scale = 1
            return r.nsImage
        }
        guard let s = stats else { return nil }
        let r = ImageRenderer(content: ShareCard(stats: s, options: options, icons: icons, appColor: appColor))
        r.scale = 1
        return r.nsImage
    }

    private func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func copyImage() {
        guard let img = render() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
        note = "Copied: paste it into your post."
    }

    private func save() {
        guard let img = render(), let data = png(img) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = shown != .sales ? "\(siteName) \(shape.rawValue).png" : "My \(stats?.title ?? "week") \(stats.map { CardText.span($0) } ?? "") \(shape.rawValue).png".replacingOccurrences(of: " – ", with: "-")
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url); note = "Saved \(url.lastPathComponent)" } catch { note = "Couldn't save: \(error.localizedDescription)" }
    }

    private func copyCaption() {
        if shown != .sales {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ProjectShare.caption(name: showApps ? siteName : "My website", metrics: siteMetrics), forType: .string)
            note = "Caption copied."
            return
        }
        guard let s = stats else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(CardText.caption(s, options), forType: .string)
        note = "Caption copied."
    }

    private func loadIcons() async {
        for a in allApps {
            if let url = model.iconURL(for: a), let img = await IconCache.shared.image(for: url) { icons[a] = img }
        }
    }
}

/// Where the system Share menu (Messages, Mail, AirDrop, Notes…) opens: behind the Share button.
@MainActor final class ShareAnchor {
    weak var view: NSView?
    func share(_ image: NSImage) {
        guard let v = view else { return }
        NSSharingServicePicker(items: [image]).show(relativeTo: v.bounds, of: v, preferredEdge: .minY)
    }
}

private struct ShareAnchorView: NSViewRepresentable {
    let anchor: ShareAnchor
    func makeNSView(context: Context) -> NSView { let v = NSView(); anchor.view = v; return v }
    func updateNSView(_ v: NSView, context: Context) { anchor.view = v }
}

/// What a share card is about.
enum ShareSource: String, CaseIterable, Identifiable {
    case sales, site, everything
    var id: String { rawValue }
    var title: String { switch self { case .sales: "App sales"; case .site: "Website"; case .everything: "Everything" } }

    /// Apps projects keep sales; a website or business project its own numbers; All projects (none picked) offers
    /// both and the two combined. Only cards with data are offered.
    static func offered(hasSales: Bool, hasSite: Bool, project: Project.Kind?) -> [ShareSource] {
        switch project {
        case .apps?: return hasSales ? [.sales] : (hasSite ? [.site] : [])
        case nil:
            if hasSales && hasSite { return [.everything, .sales, .site] }
            return hasSales ? [.sales] : (hasSite ? [.site] : [])
        default:
            if hasSite && hasSales { return [.site, .sales] }
            return hasSite ? [.site] : (hasSales ? [.sales] : [])
        }
    }

    /// The apps' side of the combined card: downloads always (a count), earnings only with exact amounts and a rate.
    static func salesMetrics(_ s: PeriodStats, exact: Bool, currency: String, convert: (Double) -> Double?) -> [ShareMetric] {
        var out: [ShareMetric] = []
        if s.downloads > 0 { out.append(ShareMetric(id: "downloads", label: "App downloads", value: s.downloads, window: "this \(s.title)", change: s.downloadsChange)) }
        if exact, s.earnedUSD > 0 {
            if currency != "USD", let v = convert(s.earnedUSD) {
                out.append(ShareMetric(id: "earned", label: "Earned", value: v, window: "this \(s.title)", change: s.earnedChange, format: .money(currency)))
            } else {
                out.append(ShareMetric(id: "earned", label: "Earned", value: s.earnedUSD, window: "this \(s.title)", change: s.earnedChange, format: .money("USD")))
            }
        }
        return out
    }
}
