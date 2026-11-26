import Charts
import HmunmawiCore
import SwiftUI

// MARK: Building blocks

struct GlassPanel<Content: View>: View {
    let title: String
    var count: Int?
    /// With a symbol the header is the Kit card header (gel icon, title in the section colour).
    var symbol: String? = nil
    var tint: Color = .primary
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let symbol {
                CardHeader(symbol: symbol, title: title, tint: tint, caption: count.flatMap { $0 > 0 ? "\($0)" : nil })
            } else {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    if let count, count > 0 {
                        Text("\(count)").font(.callout).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 3).glassCapsule()
                    }
                }
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentCard(cornerRadius: 22)
    }
}

struct EventRow: View {
    let symbol: String
    let tint: Color
    let title: String
    var detail: String = ""
    var at: Millis?
    var index = 0

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(symbol: symbol, tint: tint, size: 30)
                .arrivalBounce(index)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fixedSize(horizontal: false, vertical: true)
                if !detail.isEmpty {
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let at {
                Text(Ago.text(millis: at))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct AllClearRow: View {
    let text: String

    var body: some View {
        EventRow(symbol: "checkmark", tint: Brand.good, title: text)
    }
}

private struct PanelGrid<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
            content
        }
    }
}

/// Two balanced columns when the window is wide enough, one column otherwise.
struct TwoColumns<Left: View, Right: View>: View {
    @ViewBuilder var left: Left
    @ViewBuilder var right: Right
    @State private var width: CGFloat = 1000

    var body: some View {
        Group {
            if width >= 700 {
                // Side by side; each card is only as tall as what's in it, so a short list never leaves an empty
                // half-card beside a tall one (the shorter column just ends sooner).
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 14) { left }.frame(maxWidth: .infinity).fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 14) { right }.frame(maxWidth: .infinity).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(spacing: 14) {
                    left
                    right
                }
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

enum EventStyle {
    static func symbol(_ kind: String) -> (String, Color) {
        switch kind {
        case "revenue.purchase": ("bag.fill", Brand.good)
        case "revenue.renewal": ("arrow.triangle.2.circlepath", Brand.good)
        case "revenue.free": ("gift.fill", .secondary)
        case "revenue.refund": ("arrow.uturn.backward", Brand.caution)
        case "revenue.cancelled", "revenue.expired": ("xmark.circle.fill", Brand.caution)
        case "revenue.billing_issue": ("creditcard.trianglebadge.exclamationmark", Brand.bad)
        case "crash.daily": ("bolt.trianglebadge.exclamationmark", Brand.bad)
        case "job.failed": ("gearshape.2.fill", Brand.bad)
        case "job.attention": ("exclamationmark.bubble.fill", Brand.caution)
        case "testflight.feedback": ("airplane.departure", Brand.Category.users)
        case "ci.build": ("hammer.fill", .secondary)
        case "site.down": ("globe", Brand.bad)
        case "disk.low": ("internaldrive", Brand.caution)
        case "mail.reply": ("envelope.fill", .secondary)
        case "outreach.due": ("megaphone.fill", .secondary)
        case "plan.step": ("doc.text.magnifyingglass", .secondary)
        default: ("circle.fill", .secondary)
        }
    }

    static func row(_ event: StoredEvent, detail: String = "") -> EventRow {
        let (symbol, tint) = symbol(event.kind)
        return EventRow(symbol: symbol, tint: tint, title: EventText.describe(event), detail: detail, at: event.occurredAt)
    }
}

// MARK: Revenue

struct RevenuePage: View {
    let model: AppModel
    static let liveKinds: Set<String> = ["revenue.purchase", "revenue.renewal", "revenue.free", "revenue.refund",
                                         "revenue.cancelled", "revenue.expired", "revenue.billing_issue"]

    private struct DailyPoint: Identifiable {
        let app: String
        let date: Date
        let units: Double
        var id: String { "\(app)-\(date.timeIntervalSince1970)" }
    }

    private var daily: [DailyPoint] {
        // One row per app and day: the App Store Connect connection and a script feed can both send the same day.
        AppModel.oneSourcePerDay(model.events.filter { $0.kind == "revenue.daily" }).compactMap { event in
            guard let day = event.payload[path: "day"]?.string,
                  let date = try? Date(day + "T12:00:00Z", strategy: .iso8601) else { return nil }
            return DailyPoint(app: event.app ?? "App", date: date, units: event.payload[path: "units"]?.number ?? 0)
        }
    }

    var body: some View {
        let live = model.events.filter { Self.liveKinds.contains($0.kind) }
        VStack(alignment: .leading, spacing: 14) {
            MoneySummary(model: model)
            GlassPanel(title: "Daily sales from Apple's report") {
                if daily.isEmpty {
                    Text("No sales yet. Your first one is out there, warming up").foregroundStyle(.secondary)
                } else {
                    let byApp = Dictionary(grouping: daily, by: \.app)
                    SmallMultiples(series: byApp.map { app, points in
                        SmallMultiples.Series(name: app, points: points.sorted { $0.date < $1.date }.map { ($0.date, $0.units) })
                    }.sorted { $0.total > $1.total }, totalText: { "\(Int(safe: $0)) sales" })
                }
            }
            GlassPanel(title: "Live App Store events", count: live.count) {
                if live.isEmpty { AllClearRow(text: "No purchases or changes in the last 8 days") }
                ForEach(live) { event in
                    EventStyle.row(event, detail: event.payload[path: "detail"]?.string ?? "")
                }
            }
        }
    }
}

// MARK: Health

struct HealthPage: View {
    let model: AppModel

    private func latest(_ kind: String, within days: Millis = 2) -> [StoredEvent] {
        let cutoff = Millis(Date.now.timeIntervalSince1970 * 1000) - days * TodayBuilder.day
        let matching = model.events.filter { $0.kind == kind && $0.occurredAt > cutoff }
        return Dictionary(grouping: matching, by: { $0.app ?? "" }).compactMap { $0.value.max { $0.occurredAt < $1.occurredAt } }
            .sorted { ($0.app ?? "") < ($1.app ?? "") }
    }

    var body: some View {
        let crashes = latest("crash.daily")
        let crashing = crashes.filter { ($0.payload[path: "crashed"]?.number ?? 0) > 0 }
        let failed = HealthCheck.stillFailing(latest("job.failed", within: 1), successes: model.events.filter { JobFailures.successKinds.contains($0.kind) })
        let down = latest("site.down", within: 1)
        VStack(alignment: .leading, spacing: 14) {
            // Three equal status tiles: each says the outcome in a line, nothing stretched or empty.
            EqualRowsGrid(minWidth: 280) {
                HealthTile(title: "Crashes, last 24 hours", ok: crashing.isEmpty,
                           headline: crashes.isEmpty ? "No crash data yet" : crashing.isEmpty ? (crashes.count == 1 ? "Your app is crash-free" : "All \(crashes.count) apps crash-free")
                               : "\(crashing.count) app\(crashing.count == 1 ? "" : "s") crashed",
                           detail: crashing.isEmpty ? "No crashes in any session" : crashing.compactMap(\.app).joined(separator: ", "),
                           apps: crashes.compactMap(\.app))
                HealthTile(title: "Mac jobs", ok: failed.isEmpty,
                           headline: failed.isEmpty ? "Every watched routine ran fine" : "\(failed.count) routine\(failed.count == 1 ? "" : "s") failed",
                           detail: failed.isEmpty ? "Checked through the day" : failed.map { EventText.describe($0) }.joined(separator: ", "), apps: [])
                HealthTile(title: "Website", ok: down.isEmpty,
                           headline: down.isEmpty ? "All pages loading" : "The website is down",
                           detail: down.isEmpty ? "Checked every few minutes" : (down.first.map { EventText.describe($0) } ?? ""), apps: [])
            }
            if let account = model.snapshots("account.snapshot").first?.payload {
                GlassPanel(title: "Apple Developer account") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16, alignment: .topLeading)], alignment: .leading, spacing: 12) {
                        AccountFact(label: "Membership renews", value: Format.fullDay(account[path: "renews"]), detail: account[path: "fee"]?.string)
                        AccountFact(label: "Next certificate expiry", value: Format.fullDay(HealthCheck.certificateExpiry(for: model, account: account)), detail: nil)
                        AccountFact(label: "Devices", value: Format.number(account[path: "devices"]),
                                    detail: "\(Format.number(account[path: "users"])) team members")
                    }
                }
            }
            if crashTrend.count > 1 {
                GlassPanel(title: "Crash-free sessions (Sentry), lowest of your apps each day") {
                    TrendChart(title: "Crash-free", points: crashTrend, tint: Brand.Category.users, height: 150, showAxis: true, showHeader: false,
                               format: { String(format: "%.2f%%", $0) })
                }
            }
        }
    }

    private var crashTrend: [(Date, Double)] {
        var byDay: [Date: Double] = [:]
        for e in model.events where e.kind == "crash.daily" {
            guard var r = e.payload[path: "crash_free_rate"]?.number else { continue }
            if r <= 1 { r *= 100 }
            let d = e.reportDay
            byDay[d] = min(byDay[d] ?? 100, r)
        }
        return byDay.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}

/// One health status in a compact tile: a green or red seal, the outcome, a detail line, app icons if any.
private struct HealthTile: View {
    let title: String
    let ok: Bool
    let headline: String
    let detail: String
    let apps: [String]

    var body: some View {
        let tint = ok ? Brand.good : Brand.bad
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Image(systemName: ok ? "checkmark.seal.fill" : "exclamationmark.octagon.fill").font(.title)
                    .foregroundStyle(tint.gradient).symbolEffect(.bounce, value: ok)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                HStack(spacing: -6) { ForEach(apps, id: \.self) { AppIcon(app: $0, size: 26) } }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentCard(cornerRadius: 20)
        .hoverLift()
    }
}

/// A labelled fact whose value is never cut off (dates shrink a little rather than truncate).
private struct AccountFact: View {
    let label: String
    let value: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.system(size: 24, weight: .bold)).foregroundStyle(Brand.Category.users.gradient)
                .lineLimit(1).minimumScaleFactor(0.6)
            if let detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
        }
    }
}

// MARK: Inbox

struct InboxPage: View {
    let model: AppModel
    @State private var showOutreach = false

    struct FollowUp: Identifiable { let id: String; let outlet: String; let app: String; let due: String; let late: Bool }

    /// Follow-ups due within a week. From your outreach list itself when one is connected (so a pitch you just closed
    /// drops off at once); otherwise from the "outreach.due" events another tool sends.
    static func followUps(_ model: AppModel) -> [FollowUp] {
        let today = DayNumber.of(Date.now.localDay) ?? 0
        if Outreach.file != nil {
            var byOutlet: [String: FollowUp] = [:]   // one follow-up per outlet, whatever apps it covered
            for i in Outreach.items() where i.open {
                guard let d = i.followUp, let n = DayNumber.of(d), n <= today + 7 else { continue }
                let key = i.outlet.lowercased()
                let app = i.app.replacingOccurrences(of: "+", with: " & ")
                if let old = byOutlet[key] { if d < old.due { byOutlet[key] = FollowUp(id: key, outlet: i.outlet, app: app, due: d, late: n < today) } }
                else { byOutlet[key] = FollowUp(id: key, outlet: i.outlet, app: app, due: d, late: n < today) }
            }
            return byOutlet.values.filter { ProjectStore.shared.shows($0.app) }.sorted { $0.due < $1.due }
        }
        return TodayBuilder.latestOutreach(model.events)
            .sorted { ($0.payload[path: "due"]?.string ?? "") < ($1.payload[path: "due"]?.string ?? "") }
            .map { e in FollowUp(id: "\(e.id)", outlet: e.payload[path: "outlet"]?.string ?? "Outlet", app: e.app ?? "",
                                 due: e.payload[path: "due"]?.string ?? "", late: e.payload[path: "overdue"] == .bool(true)) }
            .filter { ProjectStore.shared.shows($0.app) }
    }

    var body: some View {
        let mail = model.events.filter { $0.kind == "mail.reply" }
        let outreach = Self.followUps(model)
        let overdue = outreach.filter(\.late).count
        let steps = Self.planned(PlanFreshness.current(TodayBuilder.latestSnapshot(model.events, kind: "plan.step"), liveVersions: PlanFreshness.liveVersions(model.events)))

        VStack(alignment: .leading, spacing: 26) {
            // The page's headline, like Today's: what needs you, then what is late.
            VStack(alignment: .leading, spacing: 6) {
                Text("Everything that came in, and what is waiting on you")
                    .font(.callout).foregroundStyle(.secondary)
                Kit.glow(model.waiting.isEmpty ? "Nothing needs your OK. Inbox zero, hero mode."
                     : model.waiting.count == 1 ? "One thing needs your OK." : "\(model.waiting.count) things need your OK.",
                         tint: model.waiting.isEmpty ? Brand.good : Brand.caution)
                    .font(.largeTitle).fixedSize(horizontal: false, vertical: true)
                if overdue > 0 {
                    Kit.glow(overdue == 1 ? "One follow-up is overdue." : "\(overdue) follow-ups are overdue.", tint: Brand.caution)
                        .font(.title2)
                }
            }
            NextSteps(model: model)
            if !model.waiting.isEmpty {
                KitCard {
                    CardHeader(symbol: "hand.raised.fill", title: "Needs your OK", tint: Brand.caution, caption: "\(model.waiting.count)")
                    ForEach(model.waiting) { action in
                        if action.job.kind == "outreach.send" {
                            OutreachWaitingRow(action: action, model: model)
                        } else {
                            HStack(alignment: .top) {
                                LogRow(title: action.title, detail: action.detail)
                                Button("Skip") { Task { await model.skip(action.job) } }.buttonStyle(.pill)
                                Button("Approve") { Task { await model.approve(action.job) } }.buttonStyle(.pillProminent)
                            }
                        }
                    }
                }
            }
            TwoColumns {
                GlassPanel(title: "Outreach follow-ups", count: outreach.count, symbol: "megaphone.fill", tint: Brand.Category.users) {
                    if outreach.isEmpty { LogRow(title: "No follow-ups due") }
                    ForEach(Array(outreach.prefix(12).enumerated()), id: \.element.id) { i, f in
                        if i > 0 { Divider() }
                        LogRow(title: f.outlet, detail: f.app,
                               trailing: "\(f.late ? "overdue since" : "due") \(Self.shortDate(f.due))",
                               trailingTint: f.late ? Brand.caution : Brand.secondaryText)
                    }
                    if outreach.count > 12 {
                        Text("And \(outreach.count - 12) more").font(.callout).foregroundStyle(.secondary)
                    }
                    let toLook = Outreach.newCount(Outreach.side().suggestions) { ProjectStore.shared.shows($0) }   // this project's only
                    Button(toLook > 0 ? "Open outreach · \(toLook) to look at" : "Open outreach") { showOutreach = true }
                        .buttonStyle(.pill)
                }
                .sheetFlow(isPresented: $showOutreach) { AnyView(OutreachSheet(model: model).buttonStyle(.pill)) }
            } right: {
                GlassPanel(title: "Mail replies", count: mail.count, symbol: "envelope.fill", tint: Brand.Category.web) {
                    if mail.isEmpty { LogRow(title: "No replies in the last 8 days") }
                    // When the inbox was last read, so an old reply never looks like the latest news.
                    if let seen = model.events.filter({ $0.kind == "mail.seen" || $0.kind == "mail.reply" }).map(\.occurredAt).max() {
                        Text("Mail checked \(Ago.text(millis: seen))")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(Array(mail.prefix(12).enumerated()), id: \.element.id) { i, event in
                        if i > 0 { Divider() }
                        LogRow(title: event.payload[path: "subject"]?.string ?? "No subject",
                               detail: event.app == "Mail" ? "" : event.app ?? "",
                               trailing: Ago.text(millis: event.occurredAt))
                    }
                }
                // Only when your scripts send plan steps that are still open; Next steps above is the app's own advice.
                if !steps.isEmpty {
                    GlassPanel(title: "Planned steps", count: steps.count, symbol: "list.bullet.clipboard.fill", tint: Brand.Category.money) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                            if i > 0 { Divider() }
                            LogRow(title: step.title, detail: step.detail)
                        }
                    }
                }
            }
        }
    }

    /// Plan steps, with steps that say the same thing (e.g. one plan filed under two pages) shown once.
    static func planned(_ events: [StoredEvent]) -> [(title: String, detail: String)] {
        var order: [String] = []
        var titles: [String: [String]] = [:]
        var details: [String: String] = [:]
        for event in events {
            let step = event.payload[path: "step"]?.string ?? ""
            let page = event.payload[path: "page"]?.string ?? "Page"
            if titles[step] == nil { order.append(step) }
            if !(titles[step]?.contains(page) ?? false) { titles[step, default: []].append(page) }
            if details[step] == nil {
                details[step] = step + (event.payload[path: "next_check"]?.string.map { "\nNext check: \(shortDate($0))" } ?? "")
            }
        }
        return order.map { step in
            let pages = titles[step] ?? []
            // "My App · weekly next step" + "My App · weekly worry step" → "My App · weekly next step, weekly worry step"
            let prefix = pages.first.flatMap { $0.components(separatedBy: " · ").first }
            let title = pages.count > 1 && pages.allSatisfy({ $0.hasPrefix((prefix ?? "") + " · ") })
                ? (prefix ?? "") + " · " + pages.map { $0.components(separatedBy: " · ").dropFirst().joined(separator: " · ") }.joined(separator: ", ")
                : pages.joined(separator: ", ")
            return (title, details[step] ?? step)
        }
    }
}

/// A plain list row for the Log: title, a grey detail line, and an optional note on the right.
struct LogRow: View {
    let title: String
    var detail: String = ""
    var trailing: String? = nil
    var trailingTint: Color = Brand.secondaryText

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fixedSize(horizontal: false, vertical: true)
                if !detail.isEmpty {
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing).font(.callout).foregroundStyle(trailingTint).fixedSize()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension InboxPage {
    static func shortDate(_ day: String?) -> String {
        guard let day, let date = try? Date(day + "T12:00:00Z", strategy: .iso8601) else { return day ?? "" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

// MARK: Activity

struct ActivityPage: View {
    let entries: [AuditEntry]

    var body: some View {
        GlassPanel(title: "Every step, newest first", symbol: "clock.arrow.circlepath", tint: Brand.Category.social) {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(ActivityGroup.make(entries)) { group in
                    HStack(spacing: 12) {
                        Text(Date(timeIntervalSince1970: Double(group.first.at) / 1000), format: .dateTime.day().month().hour().minute())
                            .monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 130, alignment: .leading)
                        Text(group.label)
                        Spacer()
                        Text(group.subject).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                }
            }
        }
    }
}

/// Two columns in a fixed ratio, each at its own natural height, top-aligned; below `stackBelow` they stack.
struct RatioColumns: Layout {
    var leading: CGFloat = 1
    var trailing: CGFloat = 2
    var spacing: CGFloat = 14
    var stackBelow: CGFloat = 900

    private func widths(_ total: CGFloat) -> (CGFloat, CGFloat)? {
        guard total >= stackBelow else { return nil }
        let usable = total - spacing
        let a = (usable * leading / (leading + trailing)).rounded()
        return (a, usable - a)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? 1000
        guard subviews.count == 2 else {
            return CGSize(width: total, height: subviews.first?.sizeThatFits(.init(width: total, height: nil)).height ?? 0)
        }
        if let (a, b) = widths(total) {
            let h = max(subviews[0].sizeThatFits(.init(width: a, height: nil)).height,
                        subviews[1].sizeThatFits(.init(width: b, height: nil)).height)
            return CGSize(width: total, height: h)
        }
        let h = subviews.map { $0.sizeThatFits(.init(width: total, height: nil)).height }.reduce(0, +) + spacing
        return CGSize(width: total, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else {
            subviews.first?.place(at: bounds.origin, proposal: .init(width: bounds.width, height: nil))
            return
        }
        if let (a, b) = widths(bounds.width) {
            subviews[0].place(at: bounds.origin, proposal: .init(width: a, height: nil))
            subviews[1].place(at: CGPoint(x: bounds.minX + a + spacing, y: bounds.minY), proposal: .init(width: b, height: nil))
        } else {
            let first = subviews[0].sizeThatFits(.init(width: bounds.width, height: nil)).height
            subviews[0].place(at: bounds.origin, proposal: .init(width: bounds.width, height: nil))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + first + spacing), proposal: .init(width: bounds.width, height: nil))
        }
    }
}

/// A card grid where every card in a row is as tall as the row's tallest card (Apple's comparison rule),
/// with as many columns of at least `minWidth` as fit. A short last row widens its cards to fill the width,
/// like widgets stepping up a size, so the grid never ends in an empty hole.
struct EqualRowsGrid: Layout {
    var minWidth: CGFloat = 400
    var spacing: CGFloat = 14

    private struct Row { let range: Range<Int>; let cell: CGFloat; let height: CGFloat }

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> [Row] {
        let cols = max(1, Int((width + spacing) / (minWidth + spacing)))
        var result: [Row] = []
        for start in stride(from: 0, to: subviews.count, by: cols) {
            let range = start..<min(start + cols, subviews.count)
            let cell = (width - spacing * CGFloat(range.count - 1)) / CGFloat(range.count)
            let height = range.map { subviews[$0].sizeThatFits(.init(width: cell, height: nil)).height }.max() ?? 0
            result.append(Row(range: range, cell: cell, height: height))
        }
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 1200
        let r = rows(width, subviews)
        return CGSize(width: width, height: r.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, r.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(bounds.width, subviews) {
            for (col, i) in row.range.enumerated() {
                subviews[i].place(at: CGPoint(x: bounds.minX + CGFloat(col) * (row.cell + spacing), y: y),
                                  proposal: .init(width: row.cell, height: row.height))
            }
            y += row.height + spacing
        }
    }
}

/// Editable outbound outreach draft in Log → Waiting with pinned recipient and MailCheck DNS status.
private struct OutreachWaitingRow: View {
    let action: WaitingAction
    let model: AppModel
    @State private var editing = false
    @State private var subject = ""
    @State private var bodyText = ""
    @State private var mailCheck: Outreach.MailCheck?

    private var toAddress: String { action.job.payload[path: "to"]?.string ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title).font(.body.weight(.medium))
                    Text("To: \(toAddress) · via \(MailSender.modeDescription)")
                        .font(.callout).foregroundStyle(.secondary)
                    if let mc = mailCheck, !mc.ok {
                        Label("Mail DNS warning: \(mc.advice.first ?? "SPF/DKIM/DMARC incomplete")", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(Brand.caution)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Button(editing ? "Hide" : "Edit") { editing.toggle() }.buttonStyle(.pill)
                Button("Skip") { Task { await model.skip(action.job) } }.buttonStyle(.pill)
                Button("Send") {
                    Task {
                        if editing { await model.updateOutreachDraft(action.job, subject: subject, body: bodyText) }
                        await model.approve(action.job)
                    }
                }.buttonStyle(.pillProminent)
            }
            if editing {
                TextField("Subject", text: $subject).textFieldStyle(.roundedBorder)
                TextEditor(text: $bodyText).font(.callout).frame(minHeight: 110, maxHeight: 200)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                HStack {
                    Spacer()
                    Button("Save draft") { Task { await model.updateOutreachDraft(action.job, subject: subject, body: bodyText) } }.buttonStyle(.pill)
                }
            }
        }
        .onAppear {
            subject = action.job.payload[path: "subject"]?.string ?? ""
            bodyText = action.job.payload[path: "body"]?.string ?? ""
        }
        .task {
            let own = UserDefaults.standard.string(forKey: Outreach.ownKey) ?? ""
            if let domain = ReplyMatch.domain(own), mailCheck == nil {
                mailCheck = await Outreach.mailCheck(domain: domain)
            }
        }
    }
}
