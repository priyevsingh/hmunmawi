import SQLite3
import Foundation

public struct StoredEvent: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var source: String
    public var kind: String
    public var app: String?
    public var payload: JSONValue
    public var occurredAt: Millis
    public init(id: Int64, source: String, kind: String, app: String?, payload: JSONValue, occurredAt: Millis) {
        self.id = id; self.source = source; self.kind = kind; self.app = app; self.payload = payload; self.occurredAt = occurredAt
    }
}

public struct TodayItem: Sendable, Equatable {
    public enum Kind: String, Sendable { case win, worry, next }

    public var kind: Kind
    public var title: String
    public var evidence: String
    /// True for "nothing to report" placeholders.
    public var isQuiet: Bool
}

public struct TodayCard: Sendable, Equatable {
    public var win: TodayItem
    public var worry: TodayItem
    public var next: TodayItem
    public var generatedAt: Millis
    public var hasWorry: Bool { !worry.isQuiet }
}

/// Rules-first Today card. Each slot walks a list of candidates in order of importance and takes the first that applies.
public enum TodayBuilder {
    public static let day: Millis = 86_400_000

    struct Context {
        let recent: [StoredEvent]
        let lastWeek: [StoredEvent]
        let all: [StoredEvent]
        let lowReviews: [StoredEvent]
        let waitingApprovals: Int
        let failedJobs: Int
        let failedJobNames: [String]
        let now: Millis

        func recent(_ kinds: Set<String>) -> [StoredEvent] { recent.filter { kinds.contains($0.kind) } }
    }

    public static func build(events: [StoredEvent], waitingApprovals: Int, failedJobs: Int, now: Millis,
                             failedJobNames: [String] = []) -> TodayCard {
        let past = events.filter { $0.occurredAt <= now }
        let recent = past.filter { $0.occurredAt > now - day }
        let context = Context(
            recent: recent,
            lastWeek: past.filter { $0.occurredAt <= now - day && $0.occurredAt > now - 8 * day },
            all: past.filter { $0.occurredAt > now - 9 * day },
            lowReviews: recent.filter { $0.kind == "review.new" && ($0.payload[path: "rating"]?.number ?? 5) <= 2 },
            waitingApprovals: waitingApprovals, failedJobs: failedJobs, failedJobNames: failedJobNames, now: now)
        return TodayCard(win: win(context), worry: worry(context), next: next(context), generatedAt: now)
    }

    // MARK: Win

    private static func win(_ c: Context) -> TodayItem {
        let today = countByApp(c.recent, kinds: ["revenue.purchase"])
        let week = countByApp(c.lastWeek, kinds: ["revenue.purchase"])
        let liveSpike = today.compactMap { app, count -> (app: String, count: Int, avg: Double, change: Double)? in
            let avg = Double(week[app] ?? 0) / 7
            guard count >= 3, avg > 0 else { return nil }
            let change = (Double(count) - avg) / avg
            return change >= 0.1 ? (app, count, avg, change) : nil
        }.max { $0.change < $1.change }
        if let s = liveSpike {
            return item(.win, "\(s.app) sales up \(percent(s.change))",
                        "\(s.count) in the last 24 hours vs \(format(s.avg)) a day last week")
        }
        if let s = dailyChanges(c.all, kind: "revenue.daily", field: "units").filter({ $0.change >= 0.25 && $0.latest >= 3 })
            .max(by: { $0.change < $1.change }) {
            // Apple's daily "units" are first downloads (free ones too), not sales: named as what they are.
            return item(.win, "\(s.app) downloads up \(percent(s.change))",
                        "\(s.latest) on \(s.day) vs \(format(s.avg)) a day the week before")
        }
        if let u = dailyChanges(c.all, kind: "analytics.daily_users", field: "users").filter({ $0.change >= 0.1 })
            .max(by: { $0.change < $1.change }) {
            return item(.win, "\(u.app) daily users up \(percent(u.change))",
                        "\(u.latest) yesterday vs \(format(u.avg)) a day the week before")
        }
        let payments = c.recent(["revenue.purchase", "revenue.renewal"])
        if !payments.isEmpty {
            let byApp = countByApp(payments, kinds: ["revenue.purchase", "revenue.renewal"])
                .sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }
            return item(.win, "\(plural(payments.count, "payment")) today", byApp.joined(separator: " · "))
        }
        if let review = c.recent.last(where: { $0.kind == "review.new" && ($0.payload[path: "rating"]?.number ?? 0) >= 5 }) {
            return item(.win, "New 5-star review for \(review.app ?? "your app")", quote(review))
        }
        return quiet(.win, "A steady day", "No big changes in the last 24 hours")
    }

    // MARK: Worry

    private static func worry(_ c: Context) -> TodayItem {
        if let site = c.recent(["site.down"]).last {
            let pages = Int(safe: site.payload[path: "pages"]?.number ?? 0)
            return item(.worry, "\(site.app ?? "Your site") has pages down", "\(plural(pages, "page")) not loading")
        }
        let refunds = countByApp(c.recent, kinds: ["revenue.refund"])
        let weekRefunds = countByApp(c.lastWeek, kinds: ["revenue.refund"])
        let topRefunds = refunds.max { $0.value < $1.value }
        func refundItem(_ app: String, _ count: Int) -> TodayItem {
            item(.worry, "\(app): \(plural(count, "refund")) today",
                 "vs \(format(Double(weekRefunds[app] ?? 0) / 7)) a day last week")
        }
        if let topRefunds, topRefunds.value >= 3 { return refundItem(topRefunds.key, topRefunds.value) }

        let crashes = latestByApp(c.all.filter { $0.kind == "crash.daily" && $0.occurredAt > c.now - day * 3 / 2 })
            .filter { ($0.payload[path: "crashed"]?.number ?? 0) > 0 }
            .max { ($0.payload[path: "crashed"]?.number ?? 0) < ($1.payload[path: "crashed"]?.number ?? 0) }
        if let crash = crashes {
            let crashed = Int(safe: crash.payload[path: "crashed"]?.number ?? 0)
            let rate = crash.payload[path: "crash_free_rate"]?.number.map { " · \(String(format: "%.1f", rateAsPercent($0)))% crash-free" } ?? ""
            return item(.worry, "\(crash.app ?? "An app"): \(plural(crashed, "crash")) in 24 hours", "Sentry\(rate)")
        }

        let brokenJobs = Array(Set(c.recent(["job.failed"]).compactMap(\.app))).sorted()
        if let first = brokenJobs.first {
            return item(.worry, brokenJobs.count == 1 ? "Mac job “\(first)” failed" : "\(brokenJobs.count) Mac jobs failed",
                        brokenJobs.count == 1 ? "Check its log" : brokenJobs.prefix(3).joined(separator: ", "))
        }
        if c.failedJobs > 0 {
            return item(.worry, "\(plural(c.failedJobs, "job")) failed", c.failedJobNames.first ?? "See Activity for the error")
        }
        if let s = dailyChanges(c.all, kind: "revenue.daily", field: "units").filter({ $0.change <= -0.4 && $0.avg >= 3 })
            .min(by: { $0.change < $1.change }) {
            return item(.worry, "\(s.app) downloads down \(percent(-s.change))",
                        "\(s.latest) on \(s.day) vs \(format(s.avg)) a day the week before")
        }
        if let u = dailyChanges(c.all, kind: "analytics.daily_users", field: "users").filter({ $0.change <= -0.2 })
            .min(by: { $0.change < $1.change }) {
            return item(.worry, "\(u.app) daily users down \(percent(-u.change))",
                        "\(u.latest) yesterday vs \(format(u.avg)) a day the week before")
        }
        if let review = c.lowReviews.last {
            return item(.worry, "\(plural(c.lowReviews.count, "low review")) for \(review.app ?? "your app")", quote(review))
        }
        let lost = c.recent(["revenue.billing_issue", "revenue.cancelled", "revenue.expired"])
        if let last = lost.last {
            return item(.worry, "\(plural(lost.count, "subscription")) at risk",
                        lost.count == 1 ? EventText.describe(last) : Set(lost.compactMap(\.app)).sorted().joined(separator: ", "))
        }
        if let topRefunds { return refundItem(topRefunds.key, topRefunds.value) }
        if let disk = c.recent(["disk.low"]).last {
            return item(.worry, "Disk space ran low", "\(Int(safe: disk.payload[path: "free_gb"]?.number ?? 0)) GB free; the disk guard cleaned up")
        }
        return quiet(.worry, "Nothing to worry about", "No refunds, crashes, failed jobs or low reviews in the last 24 hours")
    }

    // MARK: Next

    private static func next(_ c: Context) -> TodayItem {
        if c.waitingApprovals > 0 {
            return item(.next, "Approve \(plural(c.waitingApprovals, "waiting action"))", "Your rules asked before acting")
        }
        if !c.lowReviews.isEmpty {
            return item(.next, "Reply to \(plural(c.lowReviews.count, "low review"))", "Open them in App Store Connect")
        }
        let mail = c.recent(["mail.reply"]).filter { $0.payload[path: "unread"] != .bool(false) }
        if let last = mail.last {
            return item(.next, "Answer \(plural(mail.count, "email"))",
                        last.payload[path: "subject"]?.string.map { "Latest: “\($0)”" } ?? "In your inbox")
        }
        let outreach = latestOutreach(c.all)
        if !outreach.isEmpty {
            let overdue = outreach.filter { $0.payload[path: "overdue"] == .bool(true) }.count
            return item(.next, "Follow up with \(plural(outreach.count, "outlet"))",
                        overdue > 0 ? "\(overdue) overdue" : "Due this week")
        }
        if let step = PlanFreshness.current(latestSnapshot(c.all, kind: "plan.step"), liveVersions: PlanFreshness.liveVersions(c.all)).last {
            return item(.next, step.payload[path: "page"]?.string ?? "Planned step",
                        step.payload[path: "step"]?.string ?? "")
        }
        return quiet(.next, "Nothing needs you", "Hmunmawi keeps watching")
    }

    // MARK: Helpers

    struct DailyChange {
        let app: String
        let latest: Int
        let day: String
        let avg: Double
        let change: Double
    }

    /// Per app: the latest daily value against the average of up to 7 days before it (needs at least 3).
    static func dailyChanges(_ events: [StoredEvent], kind: String, field: String) -> [DailyChange] {
        let byApp = Dictionary(grouping: events.filter { $0.kind == kind }, by: { $0.app ?? "Your app" })
        return byApp.compactMap { app, list in
            let days = list.sorted { $0.occurredAt < $1.occurredAt }
            guard let latest = days.last, let value = latest.payload[path: field]?.number else { return nil }
            let before = days.dropLast().suffix(7).compactMap { $0.payload[path: field]?.number }
            guard before.count >= 3 else { return nil }
            let avg = before.reduce(0, +) / Double(before.count)
            guard avg > 0 else { return nil }
            return DailyChange(app: app, latest: Int(value), day: shortDay(latest), avg: avg, change: (value - avg) / avg)
        }
    }

    /// For "what is due now" signals sent as a daily snapshot: only the items from the most recent day.
    /// Follow-ups due: the newest list a tool sent. With an "outreach.batch" marker, exactly that batch (so a pitch
    /// closed today drops off at once, and an empty list is empty); without one, the newest day as before.
    public static func latestOutreach(_ events: [StoredEvent]) -> [StoredEvent] {
        guard let batch = events.filter({ $0.kind == "outreach.batch" }).map(\.occurredAt).max() else {
            return latestSnapshot(events, kind: "outreach.due")
        }
        return events.filter { $0.kind == "outreach.due" && abs($0.occurredAt - batch) < 120_000 }
    }

    public static func latestSnapshot(_ events: [StoredEvent], kind: String) -> [StoredEvent] {
        let matching = events.filter { $0.kind == kind }
        guard let newest = matching.map(\.occurredAt).max() else { return [] }
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(newest) / 1000))
        return matching.filter { calendar.startOfDay(for: Date(timeIntervalSince1970: Double($0.occurredAt) / 1000)) == day }
    }

    private static func latestByApp(_ events: [StoredEvent]) -> [StoredEvent] {
        Dictionary(grouping: events, by: { $0.app ?? "" }).compactMap { $0.value.max { $0.occurredAt < $1.occurredAt } }
    }

    private static func countByApp(_ events: [StoredEvent], kinds: Set<String>) -> [String: Int] {
        events.filter { kinds.contains($0.kind) }.reduce(into: [:]) { $0[$1.app ?? "Your app", default: 0] += 1 }
    }

    private static func item(_ kind: TodayItem.Kind, _ title: String, _ evidence: String) -> TodayItem {
        TodayItem(kind: kind, title: title, evidence: evidence, isQuiet: false)
    }

    private static func quiet(_ kind: TodayItem.Kind, _ title: String, _ evidence: String) -> TodayItem {
        TodayItem(kind: kind, title: title, evidence: evidence, isQuiet: true)
    }

    private static func quote(_ event: StoredEvent) -> String {
        let text = event.payload[path: "title"]?.string ?? event.payload[path: "text"]?.string ?? ""
        return text.isEmpty ? "No review text" : "“\(text.count > 70 ? String(text.prefix(70)) + "…" : text)”"
    }

    private static func shortDay(_ event: StoredEvent) -> String {
        if let day = event.payload[path: "day"]?.string, let date = try? Date(day + "T12:00:00Z", strategy: .iso8601) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return "the latest day"
    }

    /// Sentry reports either 0-1 or 0-100.
    private static func rateAsPercent(_ rate: Double) -> Double { rate <= 1 ? rate * 100 : rate }

    private static func percent(_ change: Double) -> String { "\(Int((change * 100).rounded()))%" }

    private static func format(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f", value) : String(Int(value.rounded()))
    }

    private static func plural(_ count: Int, _ noun: String) -> String {
        let plural = noun.hasSuffix("sh") || noun.hasSuffix("ch") ? noun + "es" : noun + "s"
        return "\(count) \(count == 1 ? noun : plural)"
    }
}

extension Store {
    /// One kind of event since a time (e.g. daily proceeds for the payout estimate), oldest first.
    public func events(kind: String, since: Millis) throws -> [StoredEvent] {
        try db.map("SELECT \(Self.eventColumns) FROM events WHERE kind = ? AND occurred_at > ? ORDER BY occurred_at", [.text(kind), .integer(since)], Self.readEvent)
    }

    public func events(since: Millis) throws -> [StoredEvent] {
        try db.map("SELECT \(Self.eventColumns) FROM events WHERE occurred_at > ? ORDER BY occurred_at, id", [.integer(since)], Self.readEvent)
    }

    public func event(_ id: Int64) throws -> StoredEvent? {
        try db.map("SELECT \(Self.eventColumns) FROM events WHERE id = ?", [.integer(id)], Self.readEvent).first
    }

    /// The columns an event needs, in the order `readEvent` reads them.
    static let eventColumns = "id, source, kind, app, payload, occurred_at"

    /// One event straight from the statement: columns by position, payload parsed with the fast parser.
    static func readEvent(_ stmt: OpaquePointer) -> StoredEvent {
        func text(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
        let payloadBytes = sqlite3_column_bytes(stmt, 4)
        let payload: JSONValue
        if let raw = sqlite3_column_text(stmt, 4), payloadBytes > 0 {
            payload = (try? JSONValue.fastParse(Data(bytes: raw, count: Int(payloadBytes)))) ?? .null
        } else {
            payload = (try? JSONValue.fastParse(Data("{}".utf8))) ?? .null
        }
        return StoredEvent(id: sqlite3_column_int64(stmt, 0), source: text(1) ?? "", kind: text(2) ?? "", app: text(3),
                           payload: payload, occurredAt: sqlite3_column_int64(stmt, 5))
    }

    /// The previous way of reading events (every column into a dictionary, payload through JSONDecoder).
    /// Kept only so `EquivalenceTests` can prove the fast reader returns exactly the same events.
    func legacyEvents(since: Millis) throws -> [StoredEvent] {
        try db.query("SELECT * FROM events WHERE occurred_at > ? ORDER BY occurred_at", [.integer(since)]).map(Self.storedEvent)
    }

    private static func storedEvent(_ row: Row) -> StoredEvent {
        StoredEvent(id: row.int("id") ?? 0, source: row.string("source") ?? "", kind: row.string("kind") ?? "",
                    app: row.string("app"),
                    payload: (try? JSONValue.parse(row.string("payload") ?? "{}")) ?? .null,
                    occurredAt: row.int("occurred_at") ?? 0)
    }

    /// How many events of one kind happened after `since`. Counted by SQL on an index: no rows are loaded.
    public func countEvents(kind: String, since: Millis = 0) throws -> Int {
        Int(try db.query("SELECT COUNT(*) AS n FROM events WHERE kind = ? AND occurred_at > ?",
                         [.text(kind), .integer(since)]).first?.int("n") ?? 0)
    }

    /// Events stored after the one with id `afterID` (new arrivals, including late reports about older days),
    /// oldest first by time and then by arrival, the same order `events(since:)` gives.
    public func events(afterID: Int64) throws -> [StoredEvent] {
        try db.map("SELECT \(Self.eventColumns) FROM events WHERE id > ? ORDER BY occurred_at, id", [.integer(afterID)], Self.readEvent)
    }

    /// One page of the newest events of some kinds after `since`, newest first (ties by id), starting below
    /// `before` when given. Callers page through until they have what they need, so a long history is never
    /// loaded whole.
    public func recentEvents(kinds: Set<String>, since: Millis, before: (occurredAt: Millis, id: Int64)? = nil,
                             limit: Int = 200) throws -> [StoredEvent] {
        guard limit > 0, !kinds.isEmpty else { return [] }
        var params: [SQLValue] = kinds.sorted().map { .text($0) } + [.integer(since)]
        var sql = "SELECT \(Self.eventColumns) FROM events WHERE kind IN (\(Array(repeating: "?", count: kinds.count).joined(separator: ","))) AND occurred_at > ?"
        if let b = before {
            sql += " AND (occurred_at < ? OR (occurred_at = ? AND id < ?))"
            params += [.integer(b.occurredAt), .integer(b.occurredAt), .integer(b.id)]
        }
        sql += " ORDER BY occurred_at DESC, id DESC LIMIT ?"
        params.append(.integer(Int64(limit)))
        return try db.map(sql, params, Self.readEvent)
    }

    /// The rows the insight engine needs after `since`, in `events(since:)` order: full events for the kinds whose
    /// contents it reads (series snapshots, sections, daily figures, sales), and only kind/app/time for everything
    /// else, which it just counts per day. Much lighter than reading every event in full.
    public func insightRows(since: Millis) throws -> [StoredEvent] {
        try insightRows(where: "occurred_at > ?", [.integer(since)])
    }

    /// The same lean/full rows for events stored after `afterID` (for the in-memory insight window).
    public func insightRows(afterID: Int64) throws -> [StoredEvent] {
        try insightRows(where: "id > ?", [.integer(afterID)])
    }

    func insightRows(where filter: String, _ params: [SQLValue]) throws -> [StoredEvent] {
        // Full rows for daily figures, section snapshots, money, and payloads with a top-level "days"/"day"
        // (has_day, set when stored); the rest only need kind, app and time. Both are decided from the covering
        // index, so payloads are read only for the rows that use them.
        let needsContents = "(kind LIKE '%.daily' OR kind = 'section.snapshot' OR kind LIKE 'revenue.%' OR has_day = 1)"
        // Raw payload bytes first, then parsed on every core at once (each row on its own: same values, faster).
        // By time, SQLite picks the covering index itself. By id ("what's new"), without table statistics it would
        // scan the whole covering index for the lean rows (17-35 ms at 1M events): NOT INDEXED keeps it on the
        // primary-key range (0.01 ms), and can't fail if an index is missing.
        let index = filter.hasPrefix("id >") ? "NOT INDEXED" : ""
        let raw = try db.map("SELECT \(Self.eventColumns) FROM events \(index) WHERE \(filter) AND \(needsContents) ORDER BY occurred_at, id",
                             params) { stmt -> (StoredEvent, Data?) in
            let bytes = sqlite3_column_bytes(stmt, 4)
            let data = sqlite3_column_text(stmt, 4).flatMap { bytes > 0 ? Data(bytes: $0, count: Int(bytes)) : nil }
            return (StoredEvent(id: sqlite3_column_int64(stmt, 0), source: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
                                kind: sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "",
                                app: sqlite3_column_text(stmt, 3).map { String(cString: $0) }, payload: .null,
                                occurredAt: sqlite3_column_int64(stmt, 5)), data)
        }
        let full = Self.parsePayloads(raw)
        let lean = try db.map("""
            SELECT id, source, kind, app, occurred_at FROM events \(index)
            WHERE \(filter) AND NOT \(needsContents) ORDER BY occurred_at, id
            """, params) { stmt in
            StoredEvent(id: sqlite3_column_int64(stmt, 0), source: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
                        kind: sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "",
                        app: sqlite3_column_text(stmt, 3).map { String(cString: $0) }, payload: .object([:]),
                        occurredAt: sqlite3_column_int64(stmt, 4))
        }
        // Merge the two sorted lists (oldest first, id breaking ties).
        var out: [StoredEvent] = []; out.reserveCapacity(full.count + lean.count)
        var i = 0, j = 0
        while i < full.count || j < lean.count {
            if j == lean.count || (i < full.count && (full[i].occurredAt, full[i].id) < (lean[j].occurredAt, lean[j].id)) {
                out.append(full[i]); i += 1
            } else { out.append(lean[j]); j += 1 }
        }
        return out
    }

    /// Fills in payloads exactly as readEvent does (empty -> {}, unreadable -> null).
    static func parsePayloads(_ raw: [(StoredEvent, Data?)]) -> [StoredEvent] {
        let empty = (try? JSONValue.fastParse(Data("{}".utf8))) ?? .null
        return raw.map { e, data in
            StoredEvent(id: e.id, source: e.source, kind: e.kind, app: e.app,
                        payload: data.map { (try? JSONValue.fastParse($0)) ?? .null } ?? empty, occurredAt: e.occurredAt)
        }
    }

    /// A window's first load: its rows, the highest id and the prune epoch, read in one actor turn, so no event
    /// can be stored between reading the rows and reading the id (it would otherwise be skipped for good).
    public func windowLoad(since: Millis, lean: Bool) throws -> (rows: [StoredEvent], maxID: Int64, epoch: Int) {
        (lean ? try insightRows(since: since) : try events(since: since), try maxEventID(), eventsEpoch)
    }

    /// A window's update: rows stored after `afterID`, with the prune epoch read in the same actor turn.
    public func windowUpdate(afterID: Int64, lean: Bool) throws -> (rows: [StoredEvent], epoch: Int) {
        (lean ? try insightRows(afterID: afterID) : try events(afterID: afterID), eventsEpoch)
    }

    /// An app's App Store ID (from the newest icon snapshot the App Store Connect add-on sent), for links.
    public func appStoreID(forApp name: String) throws -> String? {
        try db.query("SELECT json_extract(payload, '$.appID') AS id FROM events WHERE kind = 'icon.snapshot' AND app = ? ORDER BY id DESC LIMIT 1",
                     [.text(name)]).first?.string("id")
    }

    /// The highest event id so far (0 when empty).
    public func maxEventID() throws -> Int64 {
        try db.query("SELECT COALESCE(MAX(id), 0) AS m FROM events").first?.int("m") ?? 0
    }

    public func eventCount() throws -> Int {
        Int(try db.query("SELECT COUNT(*) AS n FROM events").first?.int("n") ?? 0)
    }

    public func today() throws -> TodayCard {
        try today(recent: try events(since: now() - 9 * TodayBuilder.day))
    }

    /// Changes whenever the jobs the Today card shows change (failures in the last day, approvals waiting), so a
    /// screen can tell it must rebuild the card even when no event came in.
    public func cardJobsFingerprint() throws -> String {
        let row = try db.query("""
            SELECT SUM(state = 'failed' AND updated_at > ?) AS f, SUM(state = 'waiting_approval') AS w,
                   COALESCE(MAX(updated_at), 0) AS u FROM jobs WHERE state IN ('failed', 'waiting_approval')
            """, [.integer(now() - TodayBuilder.day)]).first
        return "\(row?.int("f") ?? 0)|\(row?.int("w") ?? 0)|\(row?.int("u") ?? 0)"
    }

    /// The same card from events already in memory (`recent` must hold at least the last 9 days, oldest first,
    /// as `events(since:)` returns them); only the jobs are read here.
    public func today(recent: [StoredEvent]) throws -> TodayCard {
        let t = now()
        let failed = try jobs(in: .failed).filter { $0.updatedAt > t - TodayBuilder.day }
        let nine = recent.filter { $0.occurredAt > t - 9 * TodayBuilder.day }
        return TodayBuilder.build(events: DailyEvents.oneSourcePerDay(nine),
                                  waitingApprovals: try jobs(in: .waitingApproval).count,
                                  failedJobs: failed.count, now: t,
                                  failedJobNames: failed.reversed().map(JobText.failure))
    }
}

/// Daily figures can arrive from two senders for the same day (the App Store Connect add-on and a feed); keep
/// one per kind, app and day (the newest), so sums and averages never count a day twice.
public enum DailyEvents {
    public static func oneSourcePerDay(_ events: [StoredEvent]) -> [StoredEvent] {
        let daily: Set<String> = ["revenue.daily", "crash.daily", "analytics.daily_users"]
        func key(_ e: StoredEvent) -> String {
            // The sender's day, else the UTC day it was stamped with (both senders stamp the end of that day).
            let day = e.payload[path: "day"]?.string
                ?? Date(timeIntervalSince1970: Double(e.occurredAt) / 1000).formatted(Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day())
            return e.kind + "|" + (e.app ?? "") + "|" + day
        }
        // Newest by the day it describes, then by arrival (a later re-count of the same day, e.g. sessions that
        // reached the analytics late, replaces the early one).
        var best: [String: (Millis, Int64)] = [:]
        for e in events where daily.contains(e.kind) {
            let k = key(e), rank = (e.occurredAt, e.id)
            if best[k].map({ $0 < rank }) ?? true { best[k] = rank }
        }
        return events.filter { e in
            guard daily.contains(e.kind) else { return true }
            return best[key(e)].map { $0 == (e.occurredAt, e.id) } ?? false
        }
    }
}

/// The last few days of events, kept in memory: loaded once, then only rows stored since the last look are
/// fetched (new arrivals and late reports about older days), and rows older than the window drop out.
/// Always holds exactly what `events(since: now - days)` would return, in the same order (time, then arrival).
public struct EventWindow: Sendable {
    public let days: Int
    public private(set) var rows: [StoredEvent] = []
    public private(set) var lastID: Int64 = 0
    public private(set) var loaded = false
    private var epoch = 0

    /// Lean: rows as `insightRows` gives them (payloads only where insights read them).
    public let lean: Bool

    public init(days: Int, lean: Bool = false) { self.days = days; self.lean = lean }

    /// Brings the window up to date; returns true when anything changed.
    @discardableResult
    public mutating func update(from store: Store, now: Millis) async throws -> Bool {
        let cutoff = now - Millis(days) * TodayBuilder.day
        if loaded {
            let (fresh, e) = try await store.windowUpdate(afterID: lastID, lean: lean)
            if e == epoch { return merge(fresh, cutoff: cutoff) }
            // Old rows were deleted since the last look, so ids may be handed out again: load again.
        }
        let first = try await store.windowLoad(since: cutoff, lean: lean)
        rows = first.rows; lastID = first.maxID; epoch = first.epoch
        loaded = true
        return true
    }

    private mutating func merge(_ fresh: [StoredEvent], cutoff: Millis) -> Bool {
        let before = rows.count, firstBefore = rows.first?.id
        if let top = fresh.map(\.id).max() { lastID = max(lastID, top) }
        rows.removeAll { $0.occurredAt <= cutoff }
        let keep = fresh.filter { $0.occurredAt > cutoff }
        if !keep.isEmpty {
            rows += keep
            rows.sort { ($0.occurredAt, $0.id) < ($1.occurredAt, $1.id) }
        }
        return !keep.isEmpty || rows.count != before || rows.first?.id != firstBefore
    }

    /// Starts over (another database, or one that was replaced or trimmed).
    public mutating func reset() { rows = []; lastID = 0; loaded = false; epoch = 0 }
}

/// A launchd job's failure is news only while the job is still failing. When launchd's latest reading (taken
/// after the failure) says the job's last run ended fine, it recovered on its own and the failure is dropped
/// everywhere it shows (Today's worry, Health), not left red for a day. A failure newer than the reading, or one
/// without a launchd label (a routine), or for a job launchd no longer lists, still counts.
public enum JobFailures {
    public static func stillFailing(_ events: [StoredEvent], states: [String: String], readAt: Millis) -> [StoredEvent] {
        events.filter { e in
            guard e.kind == "job.failed", e.occurredAt < readAt, let label = e.payload[path: "label"]?.string,
                  let state = states[label] else { return true }
            return state == "failed"
        }
    }

    /// The same events with recovered job failures removed (every other kind untouched, order kept).
    public static func withoutRecovered(_ events: [StoredEvent], states: [String: String], readAt: Millis) -> [StoredEvent] {
        let failed = events.filter { $0.kind == "job.failed" }
        guard !failed.isEmpty else { return events }
        let keep = Set(stillFailing(failed, states: states, readAt: readAt).map(\.id))
        return events.filter { $0.kind != "job.failed" || keep.contains($0.id) }
    }
}
