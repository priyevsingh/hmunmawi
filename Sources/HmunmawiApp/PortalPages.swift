import Charts
import HmunmawiCore
import SwiftUI

// MARK: Shared

struct Stat: Identifiable {
    let label: String
    let value: String
    var detail: String = ""
    /// The number's colour by meaning (people/downloads, money, health); nil = the card's colour.
    var tint: Color? = nil
    var id: String { label }

    /// Drops stats with no value, so a card never shows an empty "–".
    static func known(_ stats: [Stat]) -> [Stat] { stats.filter { $0.value != "–" && $0.value != "None" && !$0.value.isEmpty } }
}

/// Columns for a short row of tiles so no row ends with gaps or one lonely tile: up to 4 in a row, 5-6 as
/// 3 + 3, 7-8 as 4 + 4, more in fours.
func evenColumns(_ n: Int) -> Int { n <= 4 ? max(n, 1) : (n <= 6 ? 3 : 4) }

struct StatGrid: View {
    let stats: [Stat]
    var columns = 3
    /// The card's category colour for its numbers (labels stay grey).
    var tint: Color = .primary

    var body: some View {
        // No lonely last row: up to 5 stats sit in one row; more take 3, 4 or 5 columns, whichever leaves the
        // fewest empty places (6 → 3 + 3, 7 → 4 + 3, 8 → 4 + 4, 10 → 5 + 5).
        let n = stats.count
        let count = n <= 5 ? max(n, 1)
            : [columns, 4, 5].min { a, b in ((a - n % a) % a, a) < ((b - n % b) % b, b) } ?? columns
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .topLeading), count: count),
                  alignment: .leading, spacing: 14) {
            ForEach(stats) { stat in
                VStack(alignment: .leading, spacing: 2) {
                    Text(stat.label).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    CountUpText(text: stat.value)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(Kit.vibrant(stat.tint ?? tint))
                        .monospacedDigit()
                        .liveNumber(stat.value)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if !stat.detail.isEmpty {
                        Text(stat.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

enum Format {
    /// "120 seen · 4 clicks" from the fields that are present; a missing field is left out, never shown as 0.
    static func parts(_ v: JSONValue, _ fields: [(String, String)]) -> String {
        let s = fields.compactMap { k, label in v[path: k]?.number.map { "\(Int(safe: $0).formatted()) \(label)" } }
        return s.isEmpty ? "Numbers not in yet" : s.joined(separator: " · ")
    }
    static func number(_ value: JSONValue?) -> String {
        guard let n = value?.number else { return "–" }
        return n.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    static func percent(_ value: JSONValue?, decimals: Int = 1) -> String {
        // Senders give percentages as 0–100 (a 0.8% conversion is 0.8, not 80%), so no fraction guessing.
        // Trailing zeros go: 100.00% → 100%, 3.0% → 3%.
        guard let n = value?.number else { return "–" }
        return n.formatted(.number.precision(.fractionLength(0...decimals))) + "%"
    }

    @MainActor static func usd(_ value: JSONValue?) -> String {
        guard let n = value?.number else { return "–" }
        return Money.shared.format(n, from: "USD", decimals: 0)
    }

    static func signed(_ value: JSONValue?) -> String {
        guard let n = value?.number else { return "" }
        return n >= 0 ? "+\(Int(n))" : "\(Int(n))"
    }

    /// Always with the year, for expiries, renewals and payouts: "8 Apr 2027".
    static func fullDay(_ value: JSONValue?) -> String {
        guard let s = value?.string, let date = try? Date(String(s.prefix(10)) + "T12:00:00Z", strategy: .iso8601) else {
            return value?.string ?? "–"
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    static func day(_ value: JSONValue?) -> String {
        guard let s = value?.string, let date = try? Date(String(s.prefix(10)) + "T12:00:00Z", strategy: .iso8601) else {
            return value?.string ?? "–"
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

extension AppModel {
    /// The newest snapshot of a portal section, one per app.
    func snapshots(_ kind: String) -> [StoredEvent] { snapshotCache[kind] ?? [] }

    func snapshot(_ kind: String, app: String?) -> StoredEvent? {
        snapshots(kind).first { $0.app == app }
    }
}

// MARK: Apps

struct AppsPage: View {
    let model: AppModel
    @Environment(DetailPresenter.self) private var presenter: DetailPresenter?
    @State private var detail: DetailRequest?
    @State private var width: CGFloat = 1200

    static let detailKinds: [(String, String)] = [
        ("app.snapshot", "App Store"), ("subs.snapshot", "Subscribers and retention"),
        ("history.series", "Daily history"), ("rating.series", "Rating history"),
        ("competitors.changes", "Competitors"), ("attention.items", "Needs attention"),
    ]

    var body: some View {
        let apps = model.snapshots("app.snapshot")
        let parts = AppPart.all(model: model, apps: apps)
        let sideBySide = !apps.isEmpty && (width - 14 * CGFloat(apps.count - 1)) / CGFloat(apps.count) >= 380
        Group {
            if apps.isEmpty {
                GlassPanel(title: "Apps") { Text("Your apps are still doing their hair. Details soon").foregroundStyle(.secondary) }
            } else if sideBySide {
                // Apple's comparison layout: the same part sits in the same row for every app, each row as tall as
                // its tallest cell, so sections line up across apps and every column ends at the same height.
                Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 0) {
                    ForEach(Array(parts.enumerated()), id: \.element.id) { row, part in
                        GridRow {
                            ForEach(apps) { snapshot in
                                AppPartView(part: part, snapshot: snapshot, model: model, onOpen: { open(snapshot.app) })
                                    .padding(.horizontal, 20)
                                    .padding(.top, row == 0 ? 20 : 16)
                                    .padding(.bottom, row == parts.count - 1 ? 20 : 0)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                    .background(UnevenRoundedRectangle(
                                        topLeadingRadius: row == 0 ? 24 : 0, bottomLeadingRadius: row == parts.count - 1 ? 24 : 0,
                                        bottomTrailingRadius: row == parts.count - 1 ? 24 : 0, topTrailingRadius: row == 0 ? 24 : 0,
                                        style: .continuous).fill(Brand.surface))
                            }
                        }
                    }
                }
                .compositingGroup()
                .shadow(color: .black.opacity(0.10), radius: 16, y: 6)
            } else {
                VStack(spacing: 14) {
                    ForEach(apps) { snapshot in
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(parts) { AppPartView(part: $0, snapshot: snapshot, model: model, onOpen: { open(snapshot.app) }) }
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .contentCard(cornerRadius: 24)
                    }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // Details zoom open as a glass card (like a purchase), not a full sheet.
        .onChange(of: detail?.id) { _, _ in
            guard let d = detail else { return }
            presenter?.show(InfoModel.from(d), from: .zero)
            detail = nil
        }
        // `--args -HMOpen "app:My App"` opens that app's details at launch (for screenshots).
        .onAppear {
            if let open = UserDefaults.standard.string(forKey: "HMOpen"), open.hasPrefix("app:") { self.open(String(open.dropFirst(4))) }
        }
    }

    private func open(_ app: String?) {
        detail = .make(app ?? "App", "app.badge.fill", Brand.accent, model: model, kinds: Self.detailKinds, app: app)
    }
}

/// One row of the app comparison: the same kind of content for every app.
enum AppPart: Identifiable, Equatable {
    case header, release, timeline, stability, codes, section(String), attention, trends

    var id: String {
        switch self {
        case .header: "header"
        case .release: "release"
        case .timeline: "timeline"
        case .stability: "stability"
        case .codes: "codes"
        case .section(let key): "section-" + key
        case .attention: "attention"
        case .trends: "trends"
        }
    }

    /// The rows every app shows, in order; add-on sections slot in by their `order`.
    @MainActor static func all(model: AppModel, apps: [StoredEvent]) -> [AppPart] {
        let names = Set(apps.compactMap(\.app))
        let sections = model.snapshots("section.snapshot").compactMap(CustomSection.init).filter { names.contains($0.app) && !model.replacedByApp($0) }
        var order: [String: Int] = [:]
        for s in sections { order[s.key] = min(order[s.key] ?? .max, s.order) }
        let keys = order.keys.sorted { (order[$0]!, $0) < (order[$1]!, $1) }
        return [.header, .release, .timeline, .stability, .codes] + keys.map { .section($0) } + [.attention, .trends]
    }
}

struct AppPartView: View {
    let part: AppPart
    let snapshot: StoredEvent
    let model: AppModel
    let onOpen: () -> Void

    var body: some View {
        switch part {
        case .header:
            AppHeader(snapshot: snapshot).contentShape(.rect).onTapGesture(perform: onOpen)
        case .release:
            if let app = snapshot.app { ReleaseReportPart(app: app, model: model) }
        case .timeline:
            if let app = snapshot.app { ReleaseTimelinePart(app: app, model: model) }
        case .stability:
            // Stability and reviews side by side (stacks on narrow windows), so neither leaves a blank half.
            EqualRowsGrid(minWidth: 360, spacing: 28) {
                Stability(app: snapshot.app, events: model.events, model: model)
                if let app = snapshot.app { ReviewsGlance(app: ComingSoon.shortName(app), model: model) }
            }
        case .codes:
            if let app = snapshot.app {
                OfferCodesPart(app: app, model: model)
                TestFlightTidy(app: app, model: model)
                NominationsPart(app: app, model: model)
                PageTestsPart(app: app, model: model)
            }
        case .section(let key):
            if let section = model.snapshots("section.snapshot").compactMap(CustomSection.init)
                .first(where: { $0.app == snapshot.app && $0.key == key }) {
                VStack(alignment: .leading, spacing: 14) {
                    Divider()
                    SectionCard(section: section, inline: true)
                }
            }
        case .attention:
            AttentionList(items: AttentionItem.all(model).filter { $0.app == snapshot.app })
        case .trends:
            VStack(alignment: .leading, spacing: 14) {
                Divider()
                AppExtras(app: snapshot.app, model: model)
            }
        }
    }
}

private struct AppHeader: View {
    let snapshot: StoredEvent

    /// How many App Store countries the rating figures cover (0 when the sender didn't say).
    static func countryCount(_ p: JSONValue) -> Int {
        if case .object(let by)? = p[path: "ratings_count_by_country"] { return by.count }
        return 0
    }
    @Environment(AppModel.self) private var model: AppModel?

    var body: some View {
        let p = snapshot.payload
        let mrr = snapshot.app.flatMap { model?.mrr?.apps[$0] }
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                AppIcon(app: snapshot.app, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(snapshot.app ?? "App").font(.title2.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                        if let version = p[path: "version"]?.string {
                            Text("v\(version)").font(.callout.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 3).glassCapsule()
                        }
                    }
                    if let state = p[path: "version_state"]?.string {
                        Text(state.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if let rating = p[path: "rating"]?.number {
                    // What the number is, in plain sight (not only in a tooltip): an average over this many ratings.
                    let count = Format.number(p[path: "ratings_count"])
                    let countries = Self.countryCount(p)
                    VStack(alignment: .trailing, spacing: 1) {
                        Label(String(format: "%.1f", rating), systemImage: "star.fill")
                            .font(.headline).foregroundStyle(Brand.caution)
                        if !count.isEmpty { Text("average of \(count) ratings").font(.caption).foregroundStyle(.secondary) }
                    }
                    .help("The average star rating over all \(count) ratings" + (countries > 0 ? " in \(countries) App Store countries" : "") + ", from Apple's public App Store page.")
                }
            }
            if case .bool(true)? = p[path: "native"] {
                // This app's page was built from Hmunmawi's own connections and Apple's public listing (no script feed), so
                // some figures can't appear. Say so, instead of leaving people to wonder where they are.
                Text("Built from your connections and Apple's public listing. Active subscribers, conversion and traffic sources appear when you connect RevenueCat or a script feed.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            StatGrid(stats: Stat.known([
                Stat(label: "Downloads, 14 days", value: Format.number(p[path: "downloads_14d"]), tint: Brand.Category.users),
                Stat(label: "Active subscribers", value: Format.number(p[path: "active_subs"]), detail: "paying right now", tint: Brand.Category.money),
                Stat(label: "Crash-free (App Store)", value: Format.percent(p[path: "crash_free"], decimals: 2), detail: "sessions without a crash", tint: Brand.good),
                Stat(label: "Download to paid", value: Format.percent(p[path: "conversion"]), detail: "new paying customers ÷ first-time downloads", tint: Brand.Category.money),
                Stat(label: "New subscribers", value: Format.number(p[path: "new_subscribers"]), detail: "started a subscription (Apple's subscription report)", tint: Brand.Category.money),
                // Monthly recurring revenue after Apple's cut, from App Store Connect's daily Subscription report.
                Stat(label: "MRR", value: mrr?.latest.map { MRRSummary.amount($0.mrr) } ?? "",
                     detail: MRRSummary.projectionLine(mrr), tint: Brand.Category.money),
                Stat(label: "Installs", value: Format.number(p[path: "installations"]),
                     detail: p[path: "installations"]?.number == nil ? ""
                        : p[path: "analytics_days"]?.number.map { "last \(Int(safe: $0)) days" } ?? "", tint: Brand.Category.users),
            ]))
        }
    }
}

/// An app's problems, the two most urgent first; the rest one click away so one busy app can't stretch the row.
private struct AttentionList: View {
    let items: [AttentionItem]
    @State private var showAll = false

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Divider()
                HStack {
                    Text("Needs attention").font(.headline)
                    Spacer()
                    if items.count > 2 {
                        Button(showAll ? "Show fewer" : "Show all \(items.count)") {
                            withAnimation(.smooth) { showAll.toggle() }
                        }
                        .buttonStyle(.link)
                    }
                }
                ForEach(Array((showAll ? items : Array(items.prefix(2))).enumerated()), id: \.element.id) { index, item in
                    AttentionTile(item: item, index: index, showsApp: false)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The last week of crashes as one square per day: green for a crash-free day, red for a day with crashes.
struct Stability: View {
    let app: String?
    let events: [StoredEvent]
    var model: AppModel? = nil
    @State private var copiedBrief = false

    private struct Day: Identifiable {
        let date: Date
        let crashed: Int
        let sessions: Int
        var id: Date { date }
    }

    private func days() -> [Day] {
        var latest: [Date: StoredEvent] = [:]
        for event in events where event.kind == "crash.daily" && event.app == app {
            let day = event.reportDay
            if (latest[day]?.occurredAt ?? 0) < event.occurredAt { latest[day] = event }
        }
        // Always the last 7 calendar days ending at the newest report; a day with no report is a grey square.
        guard let end = latest.keys.max() else { return [] }
        return (0..<7).reversed().compactMap { back -> Day? in
            guard let day = Calendar.current.date(byAdding: .day, value: -back, to: end) else { return nil }
            guard let event = latest[day] else { return Day(date: day, crashed: -1, sessions: 0) }
            return Day(date: day, crashed: Int(safe: event.payload[path: "crashed"]?.number ?? 0), sessions: Int(safe: event.payload[path: "sessions"]?.number ?? 0))
        }
    }

    var body: some View {
        let week = days()
        if let today = week.last {
            let badDays = week.filter { $0.crashed > 0 }.count
            let known = week.filter { $0.crashed >= 0 }.count
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text("Stability").foregroundStyle(.primary)
                } icon: {
                    Image(systemName: badDays == 0 ? "checkmark.shield.fill" : "bolt.trianglebadge.exclamationmark.fill")
                        .foregroundStyle(badDays == 0 ? Brand.good : Brand.bad)
                }
                .font(.headline)
                Kit.glow(Self.headline(today), tint: today.crashed == 0 ? Brand.good : Brand.bad).font(.title3)
                HStack(spacing: 6) {
                    ForEach(week) { DaySquare(date: $0.date, crashed: $0.crashed) }
                }
                Text((badDays > 0 ? "\(badDays) of the last 7 days had session crashes" : known >= 7 ? "Crash-free sessions all week" : "Crash-free sessions on every day with data")
                     + (known < 7 ? " · grey = no report that day" : ""))
                    .font(.callout).foregroundStyle(.secondary)
                // Session health doesn't count freezes the watchdog or the user ended: show them beside it, neutrally
                // (tracked only, no colour change, no alerts).
                if let app, let freezes = FreezeWatch.shared.summary {
                    let short = ComingSoon.shortName(app)
                    let liveVersion = ReleaseDates.shared.live[short]?.version
                    ForEach(freezes.lines(for: app, liveVersion: liveVersion), id: \.self) { line in
                        Text(line).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let brief = Self.triageBrief(app: app, liveVersion: liveVersion, freezes: freezes, model: model) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(brief, forType: .string)
                            copiedBrief = true
                            Task { try? await Task.sleep(for: .seconds(2)); copiedBrief = false }
                        } label: {
                            Label(copiedBrief ? "Copied triage brief" : "Copy brief for Claude", systemImage: copiedBrief ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.pill)
                        .help("Copies open Sentry crash & live-release freeze context for your local Claude Teams session")
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    static func triageBrief(app: String, liveVersion: String?, freezes: FreezeSummary, model: AppModel?) -> String? {
        let short = ComingSoon.shortName(app)
        let appIssues = (model?.snapshots("issues.snapshot").flatMap { SentryIssues.parse($0.payload) } ?? []).filter { i in
            !SentryIssues.isHangTitle(i.title) && !SentryIssues.isAggregate(i)
                && (ComingSoon.shortName(i.project).caseInsensitiveCompare(short) == .orderedSame
                    || i.project.caseInsensitiveCompare(app) == .orderedSame)
        }
        let ourCodeLiveFreezes = freezes.issues.contains { $0.app == app && $0.verdict == .ourCode }
            && (liveVersion.map { live in freezes.releases.contains { $0.app == app && FreezeClassifier.version($0.release) == live && $0.events > 0 } } ?? true)
        guard !appIssues.isEmpty || ourCodeLiveFreezes else { return nil }
        var lines = ["Sentry triage for \(app)" + (liveVersion.map { " (live v\($0))" } ?? "") + ":"]
        for i in SentryIssues.sortedForTriage(appIssues).prefix(5) {
            lines.append("- \(i.title) (\(i.count)x)" + (i.permalink.map { " — \($0)" } ?? ""))
        }
        if ourCodeLiveFreezes {
            lines.append(contentsOf: freezes.lines(for: app, liveVersion: liveVersion))
        }
        return lines.joined(separator: "\n")
    }

    private static func headline(_ day: Day) -> String {
        let sessions = "\(day.sessions) session\(day.sessions == 1 ? "" : "s")"
        // The newest report is often yesterday's (Sentry's day ends at midnight UTC): name the day it is about.
        let cal = Calendar.current
        let when = cal.isDateInToday(day.date) ? "today" : cal.isDateInYesterday(day.date) ? "yesterday"
            : "on " + day.date.formatted(.dateTime.day().month(.abbreviated))
        return day.crashed == 0 ? "No session crashes \(when) across \(sessions)"
            : "\(day.crashed) crash\(day.crashed == 1 ? "" : "es") \(when) in \(sessions)"
    }

    private struct DaySquare: View {
        let date: Date
        let crashed: Int

        var body: some View {
            let tint = crashed < 0 ? Color.secondary.opacity(0.35) : crashed == 0 ? Brand.good : Brand.bad
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.gradient)
                    .frame(width: 34, height: 26)
                    .overlay {
                        if crashed > 0 { Text("\(crashed)").font(.callout.weight(.bold)).foregroundStyle(.white) }
                    }
                Text(date, format: .dateTime.weekday(.abbreviated)).font(.callout).foregroundStyle(.secondary)
            }
            .clickForDetail({
                var c = InfoModel(icon: .symbol(crashed == 0 ? "checkmark.shield.fill" : "bolt.trianglebadge.exclamationmark.fill"),
                                  tint: tint, title: crashed < 0 ? "No report that day" : crashed == 0 ? "No crashes" : "\(crashed) crash\(crashed == 1 ? "" : "es")", subtitle: date.dayText)
                c.facts = [c.fact("calendar", "Day", date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))),
                           c.fact("bolt.trianglebadge.exclamationmark", "Crashes", crashed < 0 ? "unknown" : "\(crashed)")].compactMap { $0 }
                c.source = "Sentry release health"
                return c
            }())
        }
    }
}

// MARK: Growth

/// A website's own search numbers from your script feed: kind `growth.site` (optional "name" field). Named by the
/// feed, else by your first website project.
struct SiteFeed {
    let name: String
    let kind: String
    let payload: JSONValue
    /// The key of its impressions series in `growth.series`.
    var seriesKey: String { "site_impressions" }

    /// The Search card's footer for the number it shows: a 28-day figure when the source has one, else the window the
    /// source names for its plain `impressions` (`window_days`, `window`: "1–7 Nov"), never a window it didn't say.
    static func seenFooter(_ search: JSONValue?) -> String {
        if search?[path: "impressions_28d"]?.number != nil || search?[path: "impressions"]?.number == nil {
            return "Times the site showed on Google in 28 days."
        }
        guard let days = search?[path: "window_days"]?.number, days >= 1 else { return "Times the site showed on Google." }
        let range = search?[path: "window"]?.string.map { " (\($0))" } ?? ""
        return "Times the site showed on Google in \(Int(days)) days\(range)."
    }

    @MainActor static func current(_ model: AppModel) -> SiteFeed? {
        for kind in ["growth.site"] {
            guard let p = model.snapshots(kind).first?.payload else { continue }
            let name = p[path: "name"]?.string
                ?? ProjectStore.shared.projects.first { $0.kind == .website }?.name ?? "Your website"
            return SiteFeed(name: name, kind: kind, payload: p)
        }
        return nil
    }
}

/// Growth as channel shots: one wide card per channel (Google, YouTube, X, your website) with its glass icon,
/// one hero number that counts up, one plain sentence, its other numbers, and, where the data has it, how much
/// of the 28 days happened in the last 7. Shots push in from depth as you scroll. Social warm-up is one row
/// at the end. Details open as zoom cards; nothing opens a new screen.
struct GrowthPage: View {
    let model: AppModel
    /// One channel only (0 Google, 1 YouTube, 2 X, 3 your website with Social warm-up), for the storyboard scenes.
    var part: Int? = nil
    func shows(_ k: Int) -> Bool { part == nil || part == k }

    var body: some View {
        let youtube = model.snapshots("growth.youtube").first
        let x = model.snapshots("growth.x").first?.payload
        let pulse = model.snapshots("growth.x_pulse").first?.payload
        let site = SiteFeed.current(model)
        let bing = model.snapshots("growth.bing").first
        let n: (JSONValue?) -> Double = { $0?.number ?? 0 }
        let history = model.snapshots("growth.series").first?.payload
        let trend: (String) -> [(Date, Double)] = { key in history.map { TrendChart.points($0, key) } ?? [] }
        VStack(alignment: .leading, spacing: 18) {
            // One card per Search Console site (a single site keeps the plain "Google Search" title and its weekly chart).
            if shows(0) {
                let sites = model.snapshots("growth.search")
                ForEach(sites, id: \.id) { site in
                    let search = site.payload
                    ChannelShot(symbol: "magnifyingglass", name: sites.count > 1 ? "Google Search · \(site.app ?? "site")" : "Google Search", tint: Brand.Category.web,
                                hero: n(search[path: "impressions_28d"]), heroLabel: "times you were seen",
                                sentence: "\(Int(n(search[path: "clicks_28d"]))) people clicked through, at an average position of \(String(format: "%.1f", n(search[path: "position_28d"]))).",
                                figures: [("Clicks", n(search[path: "clicks_28d"])), ("Clicks, 7 days", n(search[path: "clicks_7d"]))],
                                recent: search[path: "impressions_7d"]?.number, points: sites.count == 1 ? trend("google_impressions_7d") : [], index: 0,
                                detail: googleDetail(search))
                }
            }
            if let youtube, shows(1) {
                let p = youtube.payload
                ChannelShot(symbol: "play.rectangle.fill", name: "YouTube" + (youtube.app.map { " · \($0)" } ?? ""), tint: Brand.Category.video,
                            hero: p[path: "views_28d"]?.number ?? n(p[path: "views"]),
                            heroLabel: p[path: "views_28d"] == nil ? "views, all time" : "views",
                            sentence: (p[path: "best_video_7d.title"]?.string.map { "Best this week: \u{201C}\($0)\u{201D} (\(Int(n(p[path: "best_video_7d.views"]))) views). " } ?? "")
                                + "\(Int(n(p[path: "subscribers"]))) subscribers, \(Self.watched(n(p[path: "watch_minutes_28d"]))) watched across \(Int(n(p[path: "videos"]))) videos.",
                            figures: [("Subscribers", n(p[path: "subscribers"])), ("Videos", n(p[path: "videos"]))],
                            recent: p[path: "views_7d"]?.number, points: trend("youtube_subscribers"), index: 1,
                            detail: InfoModel.from(.make("YouTube", "play.rectangle.fill", Brand.Category.video, model: model, kinds: [("growth.youtube", "Channel")])))
            }
            if let pulse, pulse[path: "fresh"] == .bool(true), let impressions = Self.xItem(pulse, "Impressions"), shows(2) {
                // X from your Mac's X file (free): the last 24 hours. A number the file doesn't have is left out, never 0.
                let best = pulse[path: "best_yesterday.text"]?.string
                ?? model.snapshots("growth.x_glance").first?.payload[path: "taking_off.title"]?.string.map { "Taking off: \u{201C}\($0)\u{201D}" }
                let followers = pulse[path: "followers_total"]?.number ?? x?[path: "followers"]?.number
                let parts = [Self.xItem(pulse, "Posts").map { "\(Int($0)) posts and replies" },
                             Self.xItem(pulse, "Engagements").map { "\(Int($0)) engagements" },
                             Self.xItem(pulse, "Followers") != nil ? Self.followersText(pulse) : followers.map { "\(Int($0).formatted()) followers" }].compactMap { $0 }
                ChannelShot(symbol: "bubble.left.and.text.bubble.right.fill", name: "X · last 24 hours", tint: Brand.Category.social,
                            hero: impressions, heroLabel: "impressions",
                            sentence: (parts.isEmpty ? "" : parts.joined(separator: ", ") + ". ")
                                + (best.map { $0.hasSuffix(".") ? $0 + " " : $0 + ". " } ?? "") + "Read \(pulse[path: "as_of"]?.string ?? "today").",
                            figures: [followers.map { ("Followers", $0) }, Self.xItem(pulse, "Posts").map { ("Posts", $0) }].compactMap { $0 },
                            recent: nil, window: 1, points: trend("x_followers"), index: 2,
                            detail: Self.xDetail(pulse, glance: model.snapshots("growth.x_glance").first?.payload))
            } else if let x, let hero = x[path: "impressions_7d"]?.number ?? x[path: "impressions_30d"]?.number, shows(2) {
                let week = x[path: "impressions_7d"]?.number != nil
                let posts = week ? x[path: "posts_7d"]?.number : x[path: "posts_30d"]?.number
                let engagements = week ? x[path: "engagements_7d"]?.number : x[path: "engagements_30d"]?.number
                let followers = x[path: "followers"]?.number
                let parts = [posts.map { "\(Int($0)) posts" }, engagements.map { "\(Int($0)) engagements" }].compactMap { $0 }
                ChannelShot(symbol: "bubble.left.and.text.bubble.right.fill", name: "X", tint: Brand.Category.social,
                            hero: hero, heroLabel: week ? "impressions in 7 days" : "impressions in 30 days",
                            sentence: (parts.isEmpty ? "" : parts.joined(separator: " and ") + (week ? " in 7 days" : " in 30 days"))
                                + (followers.map { (parts.isEmpty ? "" : "; ") + "\(Int($0)) followers" } ?? "") + "."
                                + (x[path: "stale"]?.string.map { " \($0)" } ?? ""),
                            figures: [followers.map { ("Followers", $0) }, engagements.map { (week ? "Engagements, 7 days" : "Engagements, 30 days", $0) }].compactMap { $0 },
                            recent: week ? nil : x[path: "impressions_7d"]?.number, window: week ? 7 : 30, points: trend("x_followers"), index: 2,
                            detail: InfoModel.from(.make("X", "bubble.left.and.text.bubble.right.fill", Brand.Category.social, model: model, kinds: [("growth.x", "Account")])))
            }
            if let bing, shows(0) {
                let p = bing.payload
                ChannelShot(symbol: "magnifyingglass.circle.fill", name: "Bing" + (bing.app.map { " · \($0)" } ?? ""), tint: Brand.Category.web,
                            hero: n(p[path: "impressions_28d"]), heroLabel: "times seen on Bing",
                            sentence: "\(Int(n(p[path: "clicks_28d"]))) clicks in 28 days, \(Int(n(p[path: "clicks_7d"]))) in the last 7" + (p[path: "data_through"]?.string.map { ", up to \(InboxPage.shortDate($0))." } ?? "."),
                            figures: [("Clicks", n(p[path: "clicks_28d"])), ("Clicks, 7 days", n(p[path: "clicks_7d"]))],
                            recent: p[path: "impressions_7d"]?.number, points: [], index: 0,
                            detail: InfoModel.from(.make("Bing", "magnifyingglass.circle.fill", Brand.Category.web, model: model, kinds: [("growth.bing", "Site")])))
            }
            if let site, shows(3) {
                let s = site.payload
                ChannelShot(symbol: "globe", name: site.name, tint: Brand.Category.web,
                            hero: n(s[path: "impressions"]), heroLabel: "times seen on Google",
                            sentence: "\(Int(n(s[path: "clicks"]))) clicks (\(Int(n(s[path: "clicks_prev"]))) the period before), \(Int(n(s[path: "bing_clicks"]))) from Bing, \(Int(n(s[path: "posts"]))) blog posts.",
                            figures: [("Google clicks", n(s[path: "clicks"])), ("Position", n(s[path: "position"]))],
                            recent: nil, points: trend(site.seriesKey), index: 3,
                            detail: InfoModel.from(.make(site.name, "globe", Brand.Category.web, model: model, kinds: [(site.kind, "Search")])))
            }
            if let social = model.snapshots("growth.social").first?.payload, shows(3) {
                HStack(spacing: 12) {
                    IconBadge(symbol: "person.3.fill", tint: Brand.Category.social, size: 26)
                    Text("Social warm-up").font(.headline)
                    Text("\(Int(n(social[path: "discord_joined"]))) of \(Int(n(social[path: "discord_total"]))) Discord servers joined")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if let next = social[path: "next"]?.array?.compactMap(\.string), !next.isEmpty {
                        Text("Next: " + next.joined(separator: ", ")).font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
                .background { Color.clear.contentCard(cornerRadius: 18) }
                .depthOnScroll()
            }
        }
    }
}

extension GrowthPage {
    /// One number from the X pulse's items; nil when the file didn't have it (never 0 for missing).
    static func xItem(_ pulse: JSONValue, _ label: String) -> Double? {
        guard let raw = (pulse[path: "items"]?.array ?? []).first(where: { $0[path: "label"]?.string == label })?[path: "value"]?.string else { return nil }
        return Double(raw.replacingOccurrences(of: "+", with: "").replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "−", with: "-"))
    }

    /// "+1 follower" from a change, or "121 followers" from a total (the X add-on reports the total).
    static func followersText(_ pulse: JSONValue) -> String {
        let raw = (pulse[path: "items"]?.array ?? []).first { $0[path: "label"]?.string == "Followers" }?[path: "value"]?.string ?? ""
        let isChange = raw.hasPrefix("+") || raw.hasPrefix("-") || raw.hasPrefix("−")
        let n = Int(raw.replacingOccurrences(of: "+", with: "").replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: ",", with: "")) ?? 0
        let word = abs(n) == 1 ? "follower" : "followers"
        return isChange ? "\(n >= 0 ? "+" : "")\(n) \(word)" : "\(n.formatted()) \(word)"
    }

    /// The X detail card: each post and reply of the last 24 hours with its views.
    static func xDetail(_ pulse: JSONValue, glance glanceSource: JSONValue? = nil) -> InfoModel {
        var info = InfoModel(icon: .symbol("bubble.left.and.text.bubble.right.fill"), tint: Brand.Category.social,
                             title: "X, last 24 hours", subtitle: "Read \(pulse[path: "as_of"]?.string ?? "today")")
        info.facts = (pulse[path: "items"]?.array ?? []).compactMap { i in
            info.fact("chart.bar.fill", i[path: "label"]?.string ?? "", i[path: "value"]?.string)
        }
        info.paragraphs = (pulse[path: "posts"]?.array ?? []).compactMap { p in
            guard let text = p[path: "text"]?.string else { return nil }
            let kind = p[path: "kind"]?.string == "reply" ? "Reply" : "Post"
            let views = p[path: "views"]?.number.map { "\(Int(safe: $0)) views" } ?? ""
            return "\(kind) · \([views, p[path: "ago"]?.string ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")): \(text)"
        }
        if let best = pulse[path: "best_yesterday.text"]?.string { info.paragraphs.append(best) }
        let glance = Self.xGlance(glanceSource)
        info.facts += glance.compactMap { info.fact($0.symbol, $0.label, $0.value) }
        return info
    }

    /// Your X at a glance, as rows: pinned post, latest article, a post taking off (or why none is), top replies.
    static func xGlance(_ g: JSONValue?) -> [(symbol: String, label: String, value: String)] {
        guard let g, g != .null else { return [] }
        func stats(_ p: JSONValue) -> String {
            [p[path: "views"]?.number.map { "\(Int(safe: $0).formatted()) views" },
             p[path: "likes"]?.number.map { "\(Int(safe: $0).formatted()) likes" }].compactMap { $0 }.joined(separator: " · ")
        }
        func line(_ p: JSONValue) -> String {
            let t = p[path: "title"]?.string.map { "\u{201C}\($0)\u{201D}" } ?? "A post"
            let s = stats(p)
            return s.isEmpty ? t : "\(t) · \(s)"
        }
        var rows: [(String, String, String)] = []
        var shownURLs: Set<String> = []
        let pinnedItems = g[path: "pinned_items"]?.array ?? (g[path: "pinned"].flatMap { $0 != .null ? [$0] : nil } ?? [])
        for p in pinnedItems where p != .null {
            if let u = p[path: "url"]?.string, !shownURLs.insert(u).inserted { continue }
            rows.append(("pin.fill", p[path: "kind"]?.string == "article" ? "Pinned article" : "Pinned post", line(p)))
        }
        let articles = g[path: "articles"]?.array ?? (g[path: "latest_article"].flatMap { $0 != .null ? [$0] : nil } ?? [])
        var addedArticle = false
        for a in articles where a != .null {
            if let u = a[path: "url"]?.string, !shownURLs.insert(u).inserted { continue }
            rows.append(("doc.richtext", addedArticle ? "Article" : "Latest article", line(a)))
            addedArticle = true
        }
        if let t = g[path: "taking_off"], t != .null {
            rows.append(("flame.fill", "Taking off", line(t)))
        } else if let why = g[path: "taking_off_reason"]?.string {
            rows.append(("flame", "Taking off", why))
        }
        for r in g[path: "top_replies"]?.array ?? [] {
            let views = r[path: "views"]?.number.map { "\(Int(safe: $0).formatted()) views" } ?? ""
            rows.append(("arrowshape.turn.up.left.fill", "Top reply", [r[path: "to"]?.string.map { "To \($0)" }, views].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")))
        }
        return rows
    }

    /// Google's card plus what people searched and which pages they saw.
    func googleDetail(_ search: JSONValue) -> InfoModel {
        var m = InfoModel.from(.make("Google Search", "magnifyingglass", Brand.Category.web, model: model, kinds: [("growth.search", "Search Console")]))
        let queries = (search[path: "top_queries_28d"]?.array ?? []).compactMap { q -> InfoModel.Fact? in
            guard let text = q[path: "query"]?.string else { return nil }
            return InfoModel.Fact(symbol: "magnifyingglass", label: text, value: Format.parts(q, [("impressions", "seen"), ("clicks", "clicks")]))
        }
        let pages = (search[path: "top_pages_28d"]?.array ?? []).prefix(10).compactMap { q -> InfoModel.Fact? in
            guard let page = q[path: "page"]?.string else { return nil }
            return InfoModel.Fact(symbol: "doc.text", label: page, value: Format.parts(q, [("impressions", "seen"), ("clicks", "clicks")]))
        }
        m.groups = [("What people searched", queries), ("Pages they saw", pages)].filter { !$0.1.isEmpty }
        return m
    }
}

/// One channel's shot: icon and name, the hero number counting up, one sentence, two figures, and the share of
/// the 28 days that came in the last 7 (only when the channel reports both).
extension GrowthPage {
    /// "45 minutes", "1 hour", "12 hours".
    static func watched(_ minutes: Double) -> String {
        if minutes < 60 { return "\(Int(minutes.rounded())) \(Int(minutes.rounded()) == 1 ? "minute" : "minutes")" }
        let h = Int((minutes / 60).rounded())
        return "\(h) \(h == 1 ? "hour" : "hours")"
    }
}

private struct ChannelShot: View {
    let symbol: String
    let name: String
    let tint: Color
    let hero: Double
    let heroLabel: String
    let sentence: String
    let figures: [(String, Double)]
    let recent: Double?
    /// How many days `hero` covers (X reports 30, the others 28).
    var window = 28
    var points: [(Date, Double)] = []
    let index: Int
    let detail: InfoModel
    @Environment(\.sceneActive) private var sceneActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = true

    var body: some View {
        HStack(alignment: .center, spacing: 28) {
            IconBadge(symbol: symbol, tint: tint, size: 64)
            VStack(alignment: .leading, spacing: 6) {
                Text(name).font(.headline).foregroundStyle(tint)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(shown ? Int(hero).formatted() : "0")
                        .font(.system(size: 44, weight: .bold)).monospacedDigit()
                        .foregroundStyle(Kit.vibrant(tint))
                        .contentTransition(.numericText())
                        .fixedSize()
                    Text(heroLabel).font(Kit.outcome).foregroundStyle(.secondary).fixedSize()
                }
                Text(sentence).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 28) {
                ForEach(figures, id: \.0) { KitFigure(value: $0.1.formatted(.number.precision(.fractionLength(0...1))), label: $0.0, tint: tint) }
            }
            if points.count >= 7 {
                // A week or more of daily readings: the real trend.
                TrendChart(title: name, points: points, tint: tint, height: 70, showAxis: false, showHeader: false)
                    .frame(width: 200)
            } else if let recent, hero > 0 {
                LastWeekSplit(share: min(1, recent / hero), tint: tint, shown: shown, window: window)
                    .frame(width: 150)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { Color.clear.contentCard(cornerRadius: 22) }
        .hoverLift()
        .clickForDetail(detail)
        .depthOnScroll()
        .onAppear { arrive() }
        .onChange(of: sceneActive) { _, on in if on { arrive() } }
    }

    private func arrive() {
        guard !reduceMotion else { shown = true; return }
        shown = false
        withAnimation(.smooth(duration: 1.0).delay(0.25 + Double(index) * 0.18)) { shown = true }
    }
}

/// How much of the 28 days came in the last 7: one bar, the recent part in the channel colour.
private struct LastWeekSplit: View {
    let share: Double
    let tint: Color
    let shown: Bool
    var window = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(Int((share * 100).rounded()))% in the last 7 days").font(.callout.weight(.semibold)).foregroundStyle(tint)
            GeometryReader { g in
                ZStack(alignment: .trailing) {
                    Capsule().fill(Brand.secondaryText.opacity(0.15))
                    Capsule().fill(tint.gradient).frame(width: max(6, g.size.width * share * (shown ? 1 : 0)))
                }
            }
            .frame(height: 10)
            Text("of the last \(window) days").font(.callout).foregroundStyle(.secondary)
        }
    }
}

// MARK: Money (top of Revenue)

struct MoneySummary: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let lifetime = model.snapshots("money.lifetime_inr").first?.payload, (lifetime[path: "gross"]?.number ?? 1) > 0 {
                LifetimeSplit(lifetime: lifetime)
            }
            ProgramsCard(model: model)
            if MonthBars.months(model).isEmpty {
                NextPayment(model: model)   // no monthly report yet: no empty chart
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        MonthBars(model: model)
                        NextPayment(model: model).frame(width: 280)
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        MonthBars(model: model)
                        NextPayment(model: model)
                    }
                }
            }
        }
    }
}

extension MoneySummary {
    @MainActor static func inr(_ value: JSONValue?) -> String {
        guard let n = value?.number else { return "–" }
        return Money.shared.format(n, from: "INR", decimals: 0)
    }
}
