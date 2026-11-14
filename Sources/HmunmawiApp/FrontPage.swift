import AppKit
import HmunmawiCore
import SwiftUI

/// Today as one front page, no scrolling: the day's headline written from the data, three stories side by side
/// (Money, Reach, Health), and the journey along the bottom. Motion is the information: every big number rolls
/// from the value you saw last time to the value now, so if nothing changed, nothing moves. Click a story and
/// it opens in place with its trend and breakdown.
struct FrontPage: View {
    let model: AppModel
    @State private var opening = OpeningTitle.due
    @State private var sharingWeek = false
    @State private var revealed = !OpeningTitle.due
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let facts = OverviewFacts(model: model)
        let since = LastSeen.since
        let cutoff = Millis(since.timeIntervalSince1970 * 1000)
        let sales = model.events.filter { $0.occurredAt > cutoff && ["revenue.purchase", "revenue.renewal"].contains($0.kind) }
        let earned = sales.compactMap { Money.shared.amount($0) }.reduce(0, +)
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                headline(facts: facts, earned: earned, sales: sales, since: since)
                SetupChecklist(model: model, permissions: Permissions.shared) { step in
                    UserDefaults.standard.set(step, forKey: "HMSetupStep")
                    UserDefaults.standard.set(false, forKey: SetupState.doneKey)
                }
                // Sample label first, so the sample sales under it never look like yours.
                if model.isDemo { DemoBanner() }
                Ticker(events: model.events)
                if ProjectStore.shared.selected?.kind == .website {
                    WebsiteStories(model: model)
                    if !model.isDemo { SearchHealthCard(project: ProjectStore.shared.selected) }
                } else {
                    EqualRowsGrid(minWidth: 300) {
                        MoneyStory(model: model, facts: facts, earned: earned, since: since)
                        ReachStory(model: model)
                        HealthStory(model: model)
                    }
                    ProjectsStrip(model: model)
                    if !model.isDemo { SearchHealthCard(project: ProjectStore.shared.selected) }
                    // The journey is built from the script feed's funnel; without one every step would read 0, which
                    // is not what happened, so the card waits until the figures exist.
                    if !model.snapshots("flow.snapshot").isEmpty {
                        FlowMap(model: model, compact: true)
                            .padding(20)
                            .contentCard(cornerRadius: 22)
                    }
                    if !model.isDemo { MoneyPlanCard(model: model); UsageCard(); WeeklyStoryCard(model: model) }
                }
            }
            .readableWidth()
            .modifier(Entrance(active: revealed, delay: 0.05))
            .environment(\.sceneActive, revealed)
        }
        // Moments float above the page (no empty gap when there's none).
        .overlay(alignment: .top) { MomentBanner(model: model).frame(maxWidth: 560).padding(.top, 12) }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scaleEffect(revealed || reduceMotion ? 1 : 1.06)
        .background { SceneBackdrop(tint: mood, pulse: model.flash?.id) }
        .overlay {
            if opening && !reduceMotion {
                // The softened page behind the opening title is a material that exists only while the title shows. A blur on
                // the page itself put the whole Today page through an extra off-screen pass on every update and switch.
                ZStack {
                    Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                    OpeningTitle(greeting: TodayStory.greeting, line: StorySentence.make(facts)) {
                        withAnimation(.easeInOut(duration: 0.8)) { opening = false }
                        withAnimation(.spring(response: 1.2, dampingFraction: 0.9)) { revealed = true }
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 1.12)))
            }
        }
        .onAppear { if reduceMotion { revealed = true; OpeningTitle.markShown() } }
    }

    /// Green when wins lead the day, amber when worries do.
    private var mood: Color {
        switch model.findings.first(where: { $0.lane != .change })?.lane {
        case .win: Brand.good
        case .worry: Brand.caution
        default: Brand.Category.web
        }
    }

    /// The day's headline: what changed since you last looked, then the one thing worth knowing.
    private func headline(facts: OverviewFacts, earned: Double, sales: [StoredEvent], since: Date) -> some View {
        let when = since.formatted(.relative(presentation: .named))
        let span = LastSeen.spanText
        let first: String = {
            if ProjectStore.shared.selected?.kind == .website {
                // A website's headline is its own news (the first section's outcome).
                // A section can mark itself as the headline ("headline": true); otherwise the first by its order.
                let sections = model.snapshots("section.snapshot")
                let flagged = sections.first { $0.payload[path: "headline"] == .bool(true) && $0.payload[path: "outcome"]?.string != nil }
                let first = sections.compactMap(CustomSection.init).filter { $0.outcome != nil }.sorted { ($0.order, $0.title) < ($1.order, $1.title) }.first
                return (flagged?.payload[path: "outcome"]?.string ?? first?.outcome).map { $0 + "." }
                    ?? "Here's how the site is doing."
            }
            if model.isDemo { return "Welcome! This is a sample day. Connect App Store Connect to see yours." }
            guard !sales.isEmpty else { return Quips.pick(["No new sales \(span). The cash register is napping.",
                                                           "No new sales \(span). The money is fashionably late.",
                                                           "The till's been quiet \(span). Perfect time to ship something."]) }
            guard earned > 0 else {
                // The list holds renewals too, so it says "payments", not "new sales".
                return sales.count == 1 ? Quips.pick(["Ka-ching! One payment \(span).", "One payment \(span). Someone has excellent taste."])
                    : Quips.pick(["Ka-ching! \(sales.count) payments \(span).", "\(sales.count) payments \(span). The fans are restless."])
            }
            // "mostly X" only when more than one app sold, by amount.
            var byApp: [String: Double] = [:]
            for e in sales { if let a = e.app { byApp[a, default: 0] += Money.shared.amount(e) ?? 0 } }
            let top = byApp.count > 1 ? byApp.max { $0.value < $1.value }?.key : nil
            return "Customers paid \(Money.shared.format(earned, from: Money.shared.target, decimals: 0)) \(span)"
                + LastSeen.todayNote(earned: earned, today: LastSeen.earnedToday(model), span: span)
                + (top.map { ", mostly \($0)." } ?? ".") + " " + Quips.pick(["Ramen upgraded.", "Treat yourself (modestly).", "Your future self approves."])
        }()
        // The day's one thing worth knowing, with a wink up front (the fact itself stays exact).
        let shown = (UserDefaults.standard.dictionary(forKey: "HMStoryShown") as? [String: String]) ?? [:]
        let todays = model.isDemo ? StoryCards.pick(model.findings).first
            : StoryCards.today(model.findings, shown: shown, today: Date.now.localDay)
        if let t = todays, !model.isDemo { DispatchQueue.main.async { StoryCards.noteShown(t, today: Date.now.localDay) } }
        let second = todays.map { f in
            let lead = f.lane == .win ? Quips.pick(["Not to brag, but", "Pop the confetti:", "Brag-worthy:"])
                : f.lane == .worry ? Quips.pick(["Plot twist:", "Ahem:", "Heads-up, captain:"]) : Quips.pick(["Fun fact:", "Meanwhile:"])
            // A source's pseudo-app ("All channels", "All apps") isn't a name worth printing before the fact.
            let app = f.app.flatMap { $0.lowercased().hasPrefix("all ") ? nil : $0 }
            let text = (app.map { "\($0): " } ?? "") + StoryCards.headline(f) + "."
            return lead + " " + (app != nil || StoryCards.startsWithName(text) ? text : text.prefix(1).lowercased() + text.dropFirst())   // app names keep their capital
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(TodayStory.greeting) · \(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))\(LastSeen.isFirstLook ? "" : " · last looked \(when)")")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                // A card of the week to post (X, Threads, LinkedIn, stories).
                if !model.isDemo, model.weeklyStats() != nil {   // anything to share at all
                    Button { sharingWeek = true } label: { Label("Share", systemImage: "square.and.arrow.up") }
                        // A popover, not a sheet: clicking anywhere else closes it (Done and Esc still do too).
                        .popover(isPresented: $sharingWeek, arrowEdge: .bottom) { ShareWeekSheet(model: model).buttonStyle(.pill) }
                }
            }
            Text(first).font(.largeTitle).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            if let second {
                Kit.glow(second, tint: mood).font(.title2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The values you saw the last time the window was open, so numbers can roll from then to now.
@MainActor enum LastSeen {
    private static let sinceKey = "HMLastLooked"
    /// True while the screens show sample data (set by the app model).
    @MainActor static var demo = true   // the app starts on sample data until a connection is allowed
    private static let valuesKey = "HMLastSeenValues"
    private static var pending: [String: Double] = [:]

    /// True until the window has been left once, so nothing claims "since you last looked" on first launch.
    static var isFirstLook: Bool { UserDefaults.standard.double(forKey: sinceKey) == 0 }

    /// How "what changed" is worded. The screens hold the last 8 days of sales, so a last look longer ago than that
    /// says "in the last 8 days" (it used to say "since you last looked" and count only those 8 days).
    static var spanText: String {
        isFirstLook ? "in the last 24 hours"
            : Date.now.timeIntervalSince(since) > 8 * 86_400 ? "in the last 8 days" : "since you last looked"
    }

    static var since: Date {
        let v = UserDefaults.standard.double(forKey: sinceKey)
        let t = v > 0 ? Date(timeIntervalSince1970: v) : Date.now.addingTimeInterval(-86_400)
        return min(t, Date.now.addingTimeInterval(-60))
    }

    static func value(_ key: String) -> Double? { (UserDefaults.standard.dictionary(forKey: valuesKey) as? [String: Double])?[key] }
    /// Shown now; becomes "last seen" when you leave.
    static func showing(_ key: String, _ v: Double) { pending[key] = v }

    /// What customers paid since midnight (purchases and renewals, before Apple's cut), in the display currency.
    static func earnedToday(_ model: AppModel) -> Double {
        let start = Millis(Calendar.current.startOfDay(for: .now).timeIntervalSince1970 * 1000)
        return model.events.filter { $0.occurredAt >= start && ["revenue.purchase", "revenue.renewal"].contains($0.kind) }
            .compactMap { Money.shared.amount($0) }.reduce(0, +)
    }

    /// " (₹566 today in all)" when today's payments are more than the part since you last looked, so the line never leaves
    /// the impression that the day's money is only what came in since the last look. Empty otherwise. Pure.
    static func todayNote(earned: Double, today: Double, span: String, joined: Bool = false,
                          format: (Double) -> String = { Money.shared.format($0, from: Money.shared.target, decimals: 0) }) -> String {
        guard span == "since you last looked", today > earned + 0.5 else { return "" }
        return joined ? ", \(format(today)) today in all" : " (\(format(today)) today in all)"
    }

    /// "Looking" means using it, not just having it in front: the app counts you as having left when the Mac has had no input
    /// for this long, at the moment the quiet began, not when you finally switch to another app.
    static let idleAfter: TimeInterval = 180
    private static let beatKey = "HMLastBeat"
    private static var idleMarked = false

    /// When you stopped looking, if the quiet since your last input is long enough (and has not been recorded yet). Pure.
    static func leaveTime(idle: TimeInterval, alreadyMarked: Bool, now: Date, threshold: TimeInterval = idleAfter) -> Date? {
        guard !alreadyMarked, idle >= threshold else { return nil }
        return now.addingTimeInterval(-idle)
    }

    /// At launch: if the app ended without being left (killed, crashed, restarted for an update), the last time you were using
    /// it is the last heartbeat. Pure: returns the time to use as "last looked", or nil to keep the saved one.
    static func catchUp(beat: Double, saved: Double) -> Double? { beat > saved ? beat : nil }

    /// Called every 30 seconds while the window is open: records a heartbeat while you are using it, and the moment you
    /// stopped when you have been idle for a while.
    static func tick(idle: TimeInterval, appActive: Bool, now: Date = .now) {
        guard appActive else { return }
        if let left = leaveTime(idle: idle, alreadyMarked: idleMarked, now: now) { markLeft(at: left); idleMarked = true }
        else if idle < 60 { idleMarked = false }
        if idle < idleAfter { UserDefaults.standard.set(now.timeIntervalSince1970, forKey: beatKey) }
    }

    /// Called once at launch (see catchUp).
    static func recoverFromUnexpectedEnd() {
        let d = UserDefaults.standard
        if let t = catchUp(beat: d.double(forKey: beatKey), saved: d.double(forKey: sinceKey)) { d.set(t, forKey: sinceKey) }
    }

    static func markLeft(at: Date = .now) {
        UserDefaults.standard.set(min(at, .now).timeIntervalSince1970, forKey: sinceKey)
        var all = (UserDefaults.standard.dictionary(forKey: valuesKey) as? [String: Double]) ?? [:]
        for (k, v) in pending { all[k] = v }
        UserDefaults.standard.set(all, forKey: valuesKey)
    }
}

/// A big number that rolls from the value you last saw to the value now (and says by how much). Still when equal.
struct RollingNumber: View {
    let key: String
    let value: Double
    let format: (Double) -> String
    let tint: Color
    @State private var shown: Double?
    @Environment(\.sceneActive) private var sceneActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let before = LastSeen.value(scoped)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(format(shown ?? before ?? value))
                .font(.system(size: 44, weight: .bold)).monospacedDigit()
                .foregroundStyle(Kit.vibrant(tint))
                .contentTransition(.numericText(value: shown ?? value))
                .lineLimit(1).fixedSize()
            if let before, before != value {
                let d = value - before
                Text("\(d > 0 ? "+" : "−")\(format(abs(d))) since last look")
                    .font(.callout.weight(.semibold)).foregroundStyle(d > 0 ? Brand.good : Brand.caution)
                    .fixedSize()
            }
        }
        .onAppear { roll() }
        .onChange(of: sceneActive) { _, on in if on { roll() } }
        .onChange(of: value) { _, _ in roll() }
    }

    /// Each project remembers its own "last look", so switching projects never shows a false change.
    /// Sample data keeps its own too, so it's never compared with your real figures (or the other way round).
    private var scoped: String { (LastSeen.demo ? "demo." : "") + (ProjectStore.shared.selectedID ?? "all") + "." + key }

    private func roll() {
        LastSeen.showing(scoped, value)
        guard sceneActive else { return }
        // Roll from what is on screen now (after a refresh), or from the value last seen.
        let from = shown ?? LastSeen.value(scoped)
        guard !reduceMotion, let from, from != value else { shown = value; return }
        shown = from
        withAnimation(.smooth(duration: 1.4).delay(0.6)) { shown = value }
    }
}

/// One story column: header, what changed in a sentence, the rolling number, a small trend, one footer line.
/// Click to open the full story in place.
struct StoryColumn<Detail: View>: View {
    let symbol: String
    let title: String
    let tint: Color
    let sentence: String
    let number: RollingNumber?
    let trend: [(Date, Double)]
    let trendLabel: String
    let footer: String?
    @ViewBuilder let detail: Detail
    @Environment(DetailPresenter.self) private var presenter: DetailPresenter?
    @State private var box = FrameBox()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(symbol: symbol, title: title, tint: tint, caption: "Open")
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Open \(title)")
                .accessibilityAddTraits(.isButton)
            Kit.glow(sentence, tint: tint).font(Kit.outcome).fixedSize(horizontal: false, vertical: true)
            if let number { number }
            if trend.count > 2 {
                VStack(alignment: .leading, spacing: 2) {
                    TrendChart(title: trendLabel, points: trend, tint: tint, height: 64, showAxis: false, showHeader: false)
                        .allowsHitTesting(false)   // the whole card opens the story; the small chart must not take the click
                    Text(trendLabel).font(.callout).foregroundStyle(.secondary)
                }
            }
            if let footer { Text(footer).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { Color.clear.contentCard(cornerRadius: 22) }
        .hoverLift()
        .contentShape(.rect)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { box.rect = $0 }
        .onTapGesture { open() }
        // The same action as a tap, offered to assistive tools as a button (it also opens the card from the keyboard).
        .accessibilityAction(named: Text("Open \(title)")) { open() }
    }

    private func open() {
        presenter?.show(view: AnyView(VStack(alignment: .leading, spacing: 22) { detail }), from: box.rect)
    }
}

private struct MoneyStory: View {
    let model: AppModel
    let facts: OverviewFacts
    let earned: Double
    let since: Date

    var body: some View {
        // Two senders can report this (the script feed's 14 days, the App Store connection's 7): the longer window wins.
        let portals = model.snapshots("money.portal").map(\.payload)
        let portal = portals.first { $0[path: "window"]?.string?.contains("14") == true } ?? portals.first
        let days = portal?[path: "window"]?.string?.contains("7 days") == true && model.events.filter({ $0.kind == "revenue.daily" }).isEmpty ? 7 : 14
        // A picked project counts only its own apps (the per-app shares), not every app's total.
        let shares = portal?[path: "shares"]?.array ?? []
        // Worked out from Apple's daily sales (one row per app and day): the 14 report days up to the newest one.
        // A sender's ready-made total is only the fallback, so a script that stops can't freeze this number.
        let dailyRows = AppModel.oneSourcePerDay(model.events.filter { $0.kind == "revenue.daily" })
            .filter { ProjectStore.shared.selectedID == nil || ProjectStore.shared.shows($0.app) }
        let reportDays = Set(dailyRows.compactMap { $0.payload[path: "day"]?.string }).sorted().suffix(14)
        let fromDaily = reportDays.count >= 14
            ? dailyRows.filter { reportDays.contains($0.payload[path: "day"]?.string ?? "") }.compactMap { $0.payload[path: "proceeds_usd"]?.number }.reduce(0, +)
            : nil
        let usd = fromDaily ?? (ProjectStore.shared.selectedID != nil && !shares.isEmpty
            ? shares.filter { ProjectStore.shared.shows($0[path: "name"]?.string) }.compactMap { $0[path: "usd"]?.number }.reduce(0, +)
            : portal?[path: "proceeds_usd"]?.number ?? 0)
        // Without exchange rates (first launch offline) the figure stays in dollars rather than showing 0.
        let converted = Money.shared.convert(usd, from: "USD")
        let code = converted == nil ? "USD" : Money.shared.target
        let proceeds = converted ?? usd
        // The newest count: Apple's subscription report (MRR's) when it's there, so this matches the MRR line below.
        let subs = model.mrr?.total.latest.map { Double($0.active) } ?? facts.subscribers.last?.1 ?? 0
        StoryColumn(symbol: "banknote.fill", title: "Money", tint: Brand.Category.money,
                    sentence: earned > 0 ? "Customers paid \(Money.shared.format(earned, from: Money.shared.target, decimals: 0)) \(LastSeen.spanText)\(LastSeen.todayNote(earned: earned, today: LastSeen.earnedToday(model), span: LastSeen.spanText, joined: true)) (before Apple's cut)."
                                         : (subs == 1 ? "1 person pays for your apps right now." : subs > 0 ? "\(Int(safe: subs)) people pay for your apps right now." : "No paying subscribers yet."),
                    // Nothing earned and no report yet: no giant 0, the sentence says it.
                    number: proceeds > 0 || portal?[path: "proceeds_usd"] != nil
                        ? RollingNumber(key: "money.\(days)d.\(code)", value: proceeds.rounded(),
                                        format: { Money.text($0, code, decimals: 0) }, tint: Brand.Category.money) : nil,
                    trend: facts.subscribers, trendLabel: "Active subscribers, last 4 weeks",
                    footer: proceeds > 0 || portal?[path: "proceeds_usd"] != nil
                        ? "Earned in the last \(days) days, after Apple's cut." + MRRSummary.footer(model.mrr)
                        : "Your earnings show here once App Store Connect is connected.") {
            CardHeader(symbol: "banknote.fill", title: "Money", tint: Brand.Category.money)
            MoneySummary(model: model)
            PurchasesCard(model: model)
            CustomSections(model: model, page: "revenue")
        }
    }
}

private struct ReachStory: View {
    let model: AppModel

    var body: some View {
        let flow = model.snapshots("flow.snapshot").first?.payload
        let seen = (flow?[path: "sources"]?.array ?? []).compactMap { $0[path: "value"]?.number }.reduce(0, +)
        // First downloads, all apps, day by day.
        var byDay: [Date: Double] = [:]
        for e in model.snapshots("history.series") {
            // The script feed's "downloads" is a running total: each day's bar is how much it rose that day.
            for (d, v) in MetricExtractor.daily(fromRunningTotal: TrendChart.points(e.payload, "downloads")) { byDay[d, default: 0] += v }
        }
        let downloads = byDay.sorted { $0.key < $1.key }.suffix(28).map { ($0.key, $0.value) }
        // Nothing that measures how people find you is connected: say so instead of showing a 0 that reads as "nobody".
        let anyReach = flow != nil || ["growth.youtube", "growth.search", "growth.bing", "growth.x"].contains { !model.snapshots($0).isEmpty }
        let yt = model.snapshots("growth.youtube").first?.payload
        let google = SearchSites.merge(model.snapshots("growth.search").map(\.payload))
        // Same bar as Next steps: a quarter of the month in a week is ordinary, so "growing" needs over 35%, and at
        // least 50 in the month so 1 of 2 views isn't "50%".
        let ytShare = yt.flatMap { p in p[path: "views_7d"]?.number.flatMap { r in p[path: "views_28d"]?.number.flatMap { $0 >= 50 ? r / $0 : nil } } }
        let gShare = google.flatMap { p in p[path: "impressions_7d"]?.number.flatMap { r in p[path: "impressions_28d"]?.number.flatMap { $0 >= 50 ? r / $0 : nil } } }
        let fastest = [("YouTube", ytShare), ("Google", gShare)].compactMap { n, s in s.map { (n, $0) } }.filter { $0.1 > 0.35 }.max { $0.1 < $1.1 }
        return StoryColumn(symbol: "chart.line.uptrend.xyaxis", title: "Reach", tint: Brand.Category.web,
                           sentence: !anyReach ? "Connect Search Console, Bing or YouTube (Settings → Connections) to see how people find you."
                               : fastest.map { "\($0.0) is growing fastest: \(Int(($0.1 * 100).rounded()))% of its month came this week." }
                               ?? "How people found you this month.",
                           number: anyReach ? RollingNumber(key: "reach.seen", value: seen, format: { Int(safe: $0).formatted() }, tint: Brand.Category.web) : nil,
                           trend: downloads, trendLabel: "Downloads: first downloads a day, all apps",
                           footer: anyReach ? "Times you were seen on Google, YouTube and Bing in 28 days." : nil) {
            CardHeader(symbol: "chart.line.uptrend.xyaxis", title: "Reach", tint: Brand.Category.web)
            GrowthPage(model: model)
            CustomSections(model: model, page: "overview")
            CustomSections(model: model, page: "growth")
        }
    }
}

private struct HealthStory: View {
    let model: AppModel

    var body: some View {
        let checks = model.healthChecks
        // With sample data the Mac permissions belong to the setup checklist, not to the sample's health.
        let problems = checks.filter { $0.level != .good && !(model.isDemo && $0.id == "permissions") }
        let trend = model.crashTrend
        let releases = ComingSoon.releases(model).prefix(2)
        StoryColumn(symbol: "heart.text.square.fill", title: "Health", tint: Brand.Category.users,
                    sentence: model.truth.dot == .good || (model.isDemo && problems.isEmpty) ? "Everything is running fine." : problems.isEmpty ? model.truth.sentence : problems.prefix(2).map { "\($0.title): \($0.value)" }.joined(separator: " · ") + (problems.count > 2 ? " · +\(problems.count - 2) more" : ""),
                    number: trend.last.map { RollingNumber(key: "health.crashfree", value: ($0.1 * 10).rounded() / 10,
                                                           format: { String(format: "%.1f%%", $0) }, tint: Brand.Category.users) },
                    trend: trend, trendLabel: "Crash-free sessions (Sentry), lowest app each day",
                    footer: releases.isEmpty ? nil : releases.map { "\([$0.app, $0.version].compactMap { $0 }.joined(separator: " ")): \($0.status.prefix(1).lowercased() + $0.status.dropFirst())" }.joined(separator: " · ") + ".") {
            CardHeader(symbol: "heart.text.square.fill", title: "Health", tint: Brand.Category.users)
            HealthList(model: model).padding(20).contentCard(cornerRadius: 22)
            ComingSoon(model: model)
            CustomSections(model: model, page: "health")
        }
    }
}


/// Today for a website project: found on search, visitors, and what people did, then every section the
/// project's sources send (AI reads, pages, posts).
private struct WebsiteStories: View {
    let model: AppModel

    /// A figure from any of the project's sections, by the start of its label ("Visitors", "WhatsApp taps").
    private func figure(_ prefix: String) -> Double? {
        for e in model.snapshots("section.snapshot") {
            for f in e.payload[path: "figures"]?.array ?? [] where (f[path: "label"]?.string ?? "").hasPrefix(prefix) {
                if let v = f[path: "value"]?.number { return v }
            }
        }
        return nil
    }

    /// How much a figure changed against the week before (0.52 = up 52%), when the section says so.
    private func figureChange(_ prefix: String) -> Double? {
        for e in model.snapshots("section.snapshot") {
            for f in e.payload[path: "figures"]?.array ?? [] where (f[path: "label"]?.string ?? "").hasPrefix(prefix) {
                if let c = f[path: "change"]?.number { return c }
            }
        }
        return nil
    }

    /// The one-line result a section states about itself (its "outcome"), by section id.
    private func sectionOutcome(_ id: String) -> String? {
        model.snapshots("section.snapshot").first { $0.payload[path: "id"]?.string == id }?.payload[path: "outcome"]?.string
    }

    private func upDown(_ c: Double?) -> String {
        guard let c, abs(c) >= 0.01 else { return "" }
        return ", \(c > 0 ? "up" : "down") \(Int((abs(c) * 100).rounded()))% on the week before"
    }

    var body: some View {
        let search = SearchSites.merge(model.snapshots("growth.search").map(\.payload)) ?? SiteFeed.current(model)?.payload
        let seen = search?[path: "impressions_28d"]?.number ?? search?[path: "impressions"]?.number ?? 0
        let clicks = search?[path: "clicks_28d"]?.number ?? search?[path: "clicks"]?.number ?? 0
        let position = search?[path: "position_28d"]?.number ?? search?[path: "position"]?.number
        let visitors = figure("Visitors") ?? 0
        let taps = figure("WhatsApp") ?? figure("Contact") ?? figure("Enquir")
        let posts = SiteFeed.current(model)?.payload[path: "posts"]?.number
        VStack(alignment: .leading, spacing: 26) {
            EqualRowsGrid(minWidth: 300) {
                StoryColumn(symbol: "magnifyingglass", title: "Search", tint: Brand.Category.web,
                            sentence: (Int(safe: clicks) == 1 ? "1 person clicked" : "\(Int(safe: clicks)) people clicked") + " through from Google" + (position.map { ", average position \(String(format: "%.1f", $0))." } ?? "."),
                            number: RollingNumber(key: "web.seen", value: seen, format: { Int(safe: $0).formatted() }, tint: Brand.Category.web),
                            trend: [], trendLabel: "", footer: SiteFeed.seenFooter(search)) {
                    GrowthPage(model: model)
                }
                StoryColumn(symbol: "person.2.fill", title: "Visitors", tint: Brand.Category.users,
                            sentence: visitors > 0 ? "\(Int(safe: visitors)) \(Int(safe: visitors) == 1 ? "person" : "people") visited the site this week\(upDown(figureChange("Visitors")))." : "People who came to the site.",
                            number: RollingNumber(key: "web.visitors", value: visitors, format: { Int(safe: $0).formatted() }, tint: Brand.Category.users),
                            trend: [], trendLabel: "", footer: "Visitors in the last 7 days.") {
                    FigureDetail(model: model, symbol: "person.2.fill", title: "Visitors", tint: Brand.Category.users,
                                 caption: "People who came to the site, last 7 days", value: visitors > 0 ? visitors : nil,
                                 change: figureChange("Visitors"), prefixes: ["Visitors", "Visits", "Users", "Sessions"],
                                 noSource: "No source counts visitors yet. Connect your site's analytics (PostHog or a script feed section with a \"Visitors\" figure) and they show here.")
                }
                StoryColumn(symbol: "hand.tap.fill", title: "Enquiries", tint: Brand.Category.money,
                            sentence: taps.map { "\(Int(safe: $0)) \(Int(safe: $0) == 1 ? "person" : "people") tapped WhatsApp or contact this week\(upDown(figureChange("WhatsApp")))." } ?? "What people did on the site.",
                            number: taps.map { RollingNumber(key: "web.taps", value: $0, format: { Int(safe: $0).formatted() }, tint: Brand.Category.money) },
                            trend: [], trendLabel: "", footer: taps == nil ? "Connect a source that counts contact taps."
                                : "WhatsApp or contact taps in 7 days.") {
                    FigureDetail(model: model, symbol: "hand.tap.fill", title: "Enquiries", tint: Brand.Category.money,
                                 caption: "WhatsApp or contact taps, last 7 days", value: taps, change: figureChange("WhatsApp"),
                                 prefixes: ["WhatsApp", "Contact", "Enquir", "Call", "Email tap", "Form"],
                                 noSource: "No source counts contact taps yet. Send WhatsApp or contact-button taps from your site's analytics (PostHog, or a script feed section with a \"WhatsApp taps\" figure) and they show here.")
                }
            }
            CustomSections(model: model, page: "growth")
        }
    }
}


/// What opens from a website figure card (Visitors, Enquiries): the number, its change on last week, then every
/// section that reports that figure (wherever its source put it), or how to get it. Never an empty panel.
private struct FigureDetail: View {
    let model: AppModel
    let symbol: String, title: String, tint: Color, caption: String
    let value: Double?
    let change: Double?
    let prefixes: [String]
    let noSource: String

    var body: some View {
        let sections = model.snapshots("section.snapshot").compactMap(CustomSection.init)
            .filter { s in s.figures.contains { f in prefixes.contains { f.label.hasPrefix($0) } } }
            .sorted { ($0.order, $0.title) < ($1.order, $1.title) }
        CardHeader(symbol: symbol, title: title, tint: tint, caption: value == nil ? nil : caption)
        if let value {
            VStack(alignment: .leading, spacing: 6) {
                RollingNumber(key: "detail." + title, value: value, format: { Int(safe: $0).formatted() }, tint: tint)
                if let change, abs(change) >= 0.01 {
                    Text("\(change > 0 ? "Up" : "Down") \(Int((abs(change) * 100).rounded()))% on the week before.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        if sections.isEmpty {
            Text(value == nil ? noSource : "This is the total your site's source sends; it doesn't break it down further.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            EqualRowsGrid {
                ForEach(sections, id: \.id) { SectionCard(section: $0) }
            }
        }
    }
}

/// Witty lines, one per day (stable while you look, fresh tomorrow). Facts never change, only the wink.
enum Quips {
    static func pick(_ lines: [String]) -> String {
        guard !lines.isEmpty else { return "" }
        let day = Calendar.current.ordinality(of: .day, in: .era, for: .now) ?? 0
        return lines[(day + lines.count * 7) % lines.count]
    }
}
