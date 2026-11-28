import Charts
import HmunmawiCore
import SwiftUI

/// One plain sentence about the day, from the same facts the page shows.
enum StorySentence {
    /// Payments in the last 7 days that make it "a busy" day, everywhere the app says so.
    static let busyWeek = 7

    @MainActor
    static func make(_ facts: OverviewFacts) -> String {
        let calendar = Calendar.current
        let today = facts.allPayments.filter {
            calendar.isDateInToday(Date(timeIntervalSince1970: Double($0.occurredAt) / 1000))
        }.count
        let pace = facts.paymentsWeek >= busyWeek ? "A busy" : "A quiet"
        let day = Date.now.formatted(.dateTime.weekday(.wide))
        var parts = ["\(pace) \(day)"]
        parts.append(today == 0 ? "no payments yet today" : "\(today) payment\(today == 1 ? "" : "s") today")
        if let crash = facts.crashFree { parts.append(crash >= 99.5 ? "apps running smoothly" : "crashes worth a look") }
        let direction = Direction(facts.subscribers.map(\.1))
        if let change = direction.change, abs(change) >= 0.005 {
            parts.append("subscribers \(change > 0 ? "up" : "down") \(Int(abs(change * 100).rounded()))% on their recent average")
        }
        return parts.joined(separator: ", ") + "."
    }
}

/// Every moment of the last 24 hours, newest first, on a vertical line.
struct TodayTimeline: View {
    let events: [StoredEvent]
    var heals: [String: AppModel.HealState] = [:]
    // Money moments live in the ticker; Today keeps everything else that happened.
    static let kinds: Set<String> = ["review.new", "mail.reply", "job.failed", "job.attention", "site.down", "disk.low", "crash.spike", "testflight.feedback", "ci.build"]

    var body: some View {
        let dayAgo = Millis(Date.now.timeIntervalSince1970 * 1000) - TodayBuilder.day
        let moments = Self.collapse(events.filter { Self.kinds.contains($0.kind) && $0.occurredAt > dayAgo }).prefix(12)
        GlassPanel(title: "Today", count: moments.count) {
            if moments.isEmpty {
                AllClearRow(text: "A calm day so far")
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(moments.enumerated()), id: \.element.id) { index, moment in
                    let event = moment.latest
                    let heal = heals[event.kind]
                    let (symbol, tint): (String, Color) = switch heal {
                    case .running: ("bandage.fill", Brand.caution)
                    case .done: ("checkmark.seal.fill", Brand.good)
                    default: EventStyle.symbol(event.kind)
                    }
                    HStack(alignment: .top, spacing: 14) {
                        Text(Date(timeIntervalSince1970: Double(event.occurredAt) / 1000), format: .dateTime.hour().minute())
                            .font(.caption.weight(.medium)).monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .trailing)
                            .padding(.top, 6)
                        VStack(spacing: 0) {
                            IconBadge(symbol: symbol, tint: tint, size: 26)
                                // Healing: a gentle pulse while the fix runs, one bounce when it is done.
                                .symbolEffect(.pulse, options: .repeating, isActive: heal == .running)
                                .symbolEffect(.bounce, value: heal)
                                .arrivalBounce(index)
                                .ripple(tint, trigger: index == 0 ? event.id : 0)
                            if index < moments.count - 1 {
                                Rectangle().fill(.quaternary).frame(width: 1.5).frame(minHeight: 18, maxHeight: .infinity)
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(EventText.describe(event)).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                                if moment.count > 1 {
                                    Text("×\(moment.count)").font(.callout.weight(.semibold)).monospacedDigit()
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(tint.opacity(0.15), in: Capsule())
                                        .foregroundStyle(tint)
                                }
                            }
                            if let heal {
                                switch heal {
                                case .running: Text("Fixing it now: freeing space").font(.callout.weight(.medium)).foregroundStyle(Brand.caution)
                                case .done(let text): Text("Healed · \(text)").font(.callout.weight(.medium)).foregroundStyle(Brand.good)
                                case .failed(let text): Text(text).font(.callout).foregroundStyle(Brand.bad)
                                }
                            }
                            if moment.count > 1 {
                                Text("\(moment.count) times today, first at \(Date(timeIntervalSince1970: Double(moment.first) / 1000).formatted(date: .omitted, time: .shortened))")
                                    .font(.callout).foregroundStyle(.secondary)
                            } else if let detail = event.payload[path: "detail"]?.string ?? event.payload[path: "subject"]?.string, !detail.isEmpty {
                                Text([TickerItems.flag(event), event.kind.hasPrefix("revenue.") ? Money.shared.purchaseLine(event) : detail].compactMap { $0 }.joined(separator: " ")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.top, 3)
                        .padding(.bottom, 14)
                        Spacer(minLength: 0)
                    }
                    .clickForDetail({
                        var c = InfoModel(icon: .symbol(symbol), tint: tint, title: EventText.describe(event), subtitle: event.app)
                        var heal: String?
                        if case .done(let t)? = heals[event.kind] { heal = t } else if case .failed(let t)? = heals[event.kind] { heal = t }
                        c.facts = [c.fact("clock", "When", Date(timeIntervalSince1970: Double(event.occurredAt) / 1000).formatted(date: .abbreviated, time: .shortened)),
                                   c.fact("repeat", "Times today", moment.count > 1 ? "\(moment.count)" : nil),
                                   c.fact("text.alignleft", "Details", event.payload[path: "detail"]?.string ?? event.payload[path: "subject"]?.string),
                                   c.fact("bandage", "Self-healing", heal)].compactMap { $0 }
                        return c
                    }())
                    .arrival(index)
                }
            }
        }
    }

    struct Moment: Identifiable {
        let latest: StoredEvent
        var count: Int
        var first: Millis
        var id: Int64 { latest.id }
    }

    /// Repeats of the same thing (the same alert for the same app) become one row with a count; events are newest first.
    static func collapse(_ events: [StoredEvent]) -> [Moment] {
        var order: [String] = []
        var groups: [String: Moment] = [:]
        for event in events {
            // Money is never merged: every sale is its own moment.
            let key = event.kind.hasPrefix("revenue.") ? "\(event.id)" : "\(event.kind)|\(event.app ?? "")|\(EventText.describe(event))"
            if var g = groups[key] {
                g.count += 1
                g.first = min(g.first, event.occurredAt)
                groups[key] = g
            } else {
                groups[key] = Moment(latest: event, count: 1, first: event.occurredAt)
                order.append(key)
            }
        }
        return order.compactMap { groups[$0] }
    }
}

struct DemoBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles.rectangle.stack").foregroundStyle(.secondary)
            Text("Sample data").font(.callout.weight(.medium))
            Spacer()
            OpenSettingsButton { Text("Connect your apps") }
                .buttonStyle(.pillProminent)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .contentCard(cornerRadius: 22)
    }
}

private struct TodayRow: View {
    let model: AppModel

    var body: some View {
        if let card = model.card {
            GlassEffectContainer(spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    TodayTile(item: card.win)
                    TodayTile(item: card.worry)
                    TodayTile(item: card.next, action: model.waiting.first, more: max(0, model.waiting.count - 1),
                              model: model)
                }
            }
        } else if let error = model.errorText {
            Text(error).foregroundStyle(Brand.bad)
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: 140)
        }
    }
}

private struct TodayTile: View {
    let item: TodayItem
    var action: WaitingAction?
    var more = 0
    var model: AppModel?

    var body: some View {
        let tint = item.isQuiet ? Brand.secondaryText : item.kind.tint
        VStack(alignment: .leading, spacing: 8) {
            Label(action == nil ? item.kind.label.uppercased() : "NEEDS YOUR OK", systemImage: item.kind.symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
            Text(action?.title ?? item.title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(action?.detail ?? item.evidence)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let action, let model {
                let isBusy = model.isWaitingBusy(action.job.id)
                let approveWord = action.job.kind == "outreach.send" || action.job.kind == "release.notify" ? "Sending…" : "Working…"
                HStack {
                    Button { Task { await model.approve(action.job) } } label: {
                        WaitingBusyLabel(title: "Approve", busyTitle: approveWord, busy: model.isWaitingApproving(action.job.id))
                    }
                    .buttonStyle(.pillProminent)
                    .disabled(isBusy)
                    Button { Task { await model.skip(action.job) } } label: {
                        WaitingBusyLabel(title: "Skip", busyTitle: "Skipping…", busy: model.isWaitingSkipping(action.job.id))
                    }
                    .buttonStyle(.pill)
                    .disabled(isBusy)
                    if more > 0 {
                        Spacer()
                        Text("+\(more) more").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .controlSize(.small)
                if let err = model.jobErrors[action.job.id] {
                    WaitingErrorBanner(text: err)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .contentCard(cornerRadius: 22)
        .accessibilityElement(children: .contain)
    }
}

private struct AppTile: View {
    let app: AppSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(app.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if let rating = app.averageRating {
                    Label(rating.formatted(.number.precision(.fractionLength(1))), systemImage: "star.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Brand.caution)
                        .help("\(app.reviewCount) reviews this week")
                }
            }
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(app.latest.formatted(.number.notation(.compactName)))
                        .font(.system(.title, weight: .bold))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: app.latest))
                        .animation(.snappy, value: app.latest)
                    Text(app.caption)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                TrendChart(title: "", points: app.daily.enumerated().map {
                    (Calendar.current.date(byAdding: .day, value: $0.offset - 6, to: .now) ?? .now, $0.element)
                }, height: 48)
            }
        }
        .padding(16)
        .contentCard(cornerRadius: 22)
    }
}

private struct ConnectionsTile: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connections").font(.headline)
            HStack(spacing: 16) {
                ForEach(model.addOns) { row in
                    OpenSettingsButton {
                        VStack(spacing: 6) {
                            Image(systemName: AddOnStyle.symbol(row.id))
                                .font(.title3)
                                .frame(width: 44, height: 44)
                                .glassEffect(.regular.interactive(), in: Circle())
                                .overlay(alignment: .topTrailing) {
                                    Image(systemName: "circle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(AddOnStyle.statusColor(row))
                                        .ripple(AddOnStyle.statusColor(row), trigger: AddOnStyle.status(row).0,
                                                breathes: AddOnStyle.status(row).0 == "Connected")
                                }
                            Text(AddOnStyle.shortName(row))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("\(row.manifest.name): \(AddOnStyle.status(row).0)")
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .contentCard(cornerRadius: 22)
    }
}

private struct ActivityTile: View {
    let groups: [ActivityGroup]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Activity").font(.headline)
            if groups.isEmpty {
                Text("Waiting for the first numbers to land. Kettle's on").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(groups) { group in
                HStack(spacing: 8) {
                    Text(Date(timeIntervalSince1970: Double(group.first.at) / 1000), format: .dateTime.hour().minute())
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(group.label).fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .contentCard(cornerRadius: 22)
    }
}

enum AddOnStyle {
    static func symbol(_ id: String) -> String {
        switch id {
        case "ntfy": "bell.badge"
        case "imessage": "message"
        case "appstoreconnect": "app.badge"
        case "posthog": "chart.line.uptrend.xyaxis"
        case "sentry": "ant.fill"
        case "searchconsole": "magnifyingglass"
        case "bing": "magnifyingglass.circle"
        case "youtube": "play.rectangle"
        case "x": "bubble.left.and.text.bubble.right"
        case "cloudflare": "globe"
        case "revenuecat": "creditcard"
        case "macjobs": "terminal"
        case "scriptfeed": "doc.text"
        default: "puzzlepiece.extension"
        }
    }

    static func shortName(_ row: AddOnRow) -> String {
        switch row.id {
        case "appstoreconnect": "App Store"
        case "ntfy": "ntfy"
        default: row.manifest.name
        }
    }

    static func status(_ row: AddOnRow) -> (String, Color) {
        if !row.approved { return ("Needs your OK", Brand.caution) }
        if !row.missing.isEmpty { return ("Needs setup", Brand.caution) }
        return ("Connected", Brand.good)
    }

    static func statusColor(_ row: AddOnRow) -> Color { status(row).1 }
}

/// Consecutive entries with the same action and actor, shown as one row.
struct ActivityGroup: Identifiable {
    let first: AuditEntry
    var count: Int
    /// Add-ons started in the same minute (the app opening or waking): one row naming them all.
    var started: [String] = []
    var id: Int64 { first.id }
    var label: String {
        started.count > 1 ? "\(started.count) connections started" : ActivityText.label(first) + (count > 1 ? " ×\(count)" : "")
    }
    /// Internal ids like "event:219" mean nothing to a reader.
    var subject: String {
        if started.count > 1 { return started.sorted().joined(separator: ", ") }
        guard count == 1, let s = first.subject, !s.hasPrefix("event:"), !s.hasPrefix("job:") else { return "" }
        return s.split(separator: ",").map { part -> String in
            let t = part.trimmingCharacters(in: .whitespaces)
            return ActivityText.macActions[t] ?? t
        }.joined(separator: ", ").replacingOccurrences(of: "plugin:", with: "").replacingOccurrences(of: "rule:", with: "rule ")
    }

    static func make(_ entries: [AuditEntry]) -> [ActivityGroup] {
        var groups: [ActivityGroup] = []
        var startedRow: [Int64: Int] = [:]          // minute -> index of its "add-ons started" row
        for entry in entries {
            if entry.action == "plugin.started" {
                let minute = entry.at / 60_000
                let name = entry.actor
                if let i = startedRow[minute] {
                    if !groups[i].started.contains(name) { groups[i].started.append(name) }
                    groups[i].count += 1
                } else {
                    startedRow[minute] = groups.count
                    groups.append(ActivityGroup(first: entry, count: 1, started: [name]))
                }
                continue
            }
            if let last = groups.last, last.started.isEmpty, last.first.action == entry.action, last.first.actor == entry.actor {
                groups[groups.count - 1].count += 1
            } else {
                groups.append(ActivityGroup(first: entry, count: 1))
            }
        }
        return groups
    }
}

enum ActivityText {
    private static let labels: [String: String] = [
        "event.received": "New data",
        "job.created": "Job added",
        "job.claimed": "Job started",
        "job.done": "Job done",
        "job.retry": "Will retry",
        "job.failed": "Job failed",
        "job.attention": "Needs a look",
        "testflight.feedback": "TestFlight feedback",
        "ci.build": "Xcode Cloud build",
        "job.approved": "Approved",
        "job.skipped": "Skipped",
        "rule.dry_run": "Rule tried out",
        "rule.cooldown": "Held by cooldown",
        "rule.blocked": "Blocked by rule",
        "plugin.approved": "Connection approved",
        "plugin.started": "Add-on started",
        "plugin.http": "Web request",
        "plugin.http_blocked": "Web request blocked",
        "plugin.mac": "Mac action",
        "plugin.poll_failed": "Check failed",
        "plugin.settings_saved": "Settings saved",
        "routine.ran": "Routine ran",
        "routine.failed": "Routine failed",
        "routine.ok": "Routine ran",
    ]
    /// Who did it, in plain words (internal add-on ids mean nothing to a reader).
    private static let actors: [String: String] = [
        "routine": "your routines", "hmunmawi": "Hmunmawi", "macjobs": "Mac jobs", "scriptfeed": "hub scripts",
        "appstoreconnect": "App Store Connect", "x": "X", "vercel": "Vercel", "sentry": "Sentry", "mail": "Mail",
        "posthog": "PostHog", "searchconsole": "Search Console", "bing": "Bing", "youtube": "YouTube",
        "cloudflare": "Cloudflare", "ntfy": "ntfy", "imessage": "iMessage",
    ]
    /// What a Mac action did, in plain words.
    static let macActions: [String: String] = [
        "launchd.list": "checked the Mac jobs", "script.run": "ran a hub script", "xfile.read": "read the X file",
    ]

    static func label(_ entry: AuditEntry) -> String {
        let base = labels[entry.action] ?? entry.action
        guard entry.actor != "rules", entry.actor != "queue", entry.actor != "engine" else { return base }
        return "\(base) · \(actors[entry.actor] ?? entry.actor)"
    }
}
