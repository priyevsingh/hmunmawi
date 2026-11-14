import Foundation

/// Which moments may become a Mac notification (Settings → Menu bar & notifications).
public enum NotifyKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case purchase, refund, badReview, review, build, connection
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .purchase: "New purchases and renewals"
        case .refund: "Refunds and cancellations"
        case .badReview: "1- and 2-star reviews"
        case .review: "Other new reviews"
        case .build: "Build and review changes from Apple"
        case .connection: "A connection stops working"
        }
    }
    /// Urgent ones (time-sensitive, allowed in quiet hours and Focus): a broken connection or a rejected build only.
    public var isUrgentCapable: Bool { self == .connection || self == .build }
}

/// Your notification choices. Defaults: money, refunds, bad reviews, builds and broken connections; private details off.
public struct NotifyPrefs: Codable, Sendable, Equatable {
    public var enabled: Bool = true
    public var kinds: Set<NotifyKind> = [.purchase, .refund, .badReview, .build, .connection]
    /// Show review text and buyer country in the notification (off: "New 1-star review in Pocket Garden").
    public var showDetails: Bool = false
    public init() {}
}

/// One moment that might be announced.
public struct NotifyCandidate: Sendable, Equatable, Codable {
    public var id: Int64
    public var kind: NotifyKind
    public var app: String?
    /// Amount in the person's display currency (nil when unknown).
    public var amount: Double?
    public var rating: Int?
    /// Short, already-plain text ("Weekly · $2.99", "An App Store version: IN_REVIEW → REJECTED").
    public var text: String
    /// Private extra (review title, country); shown only with `showDetails`.
    public var privateText: String?
    public var urgent: Bool = false
    /// Sample data is never announced.
    public var isSample: Bool = false
    /// Where tapping it goes ("today", "apps", "log", "settings").
    public var page: String = "today"
    /// What exactly happened, for the title: "renewal", "new purchase", "refund", "cancellation" (nil = by kind).
    public var label: String?

    public init(id: Int64, kind: NotifyKind, app: String?, amount: Double? = nil, rating: Int? = nil, text: String,
                privateText: String? = nil, urgent: Bool = false, isSample: Bool = false, page: String = "today") {
        self.id = id; self.kind = kind; self.app = app; self.amount = amount; self.rating = rating; self.text = text
        self.privateText = privateText; self.urgent = urgent; self.isSample = isSample; self.page = page
    }

    /// The candidate for a stored event, or nil when that kind is never a notification.
    public static func from(id: Int64, kind: String, app: String?, payload: JSONValue, amount: Double?, text: String,
                            isSample: Bool) -> NotifyCandidate? {
        switch kind {
        case "revenue.purchase", "revenue.renewal":
            var c = NotifyCandidate(id: id, kind: .purchase, app: app, amount: amount, text: text, isSample: isSample)
            c.label = kind == "revenue.renewal" ? "renewal" : "new purchase"
            return c
        case "revenue.refund", "revenue.cancelled":
            var c = NotifyCandidate(id: id, kind: .refund, app: app, amount: amount, text: text, isSample: isSample)
            c.label = kind == "revenue.cancelled" ? "cancellation" : "refund"
            return c
        case "review.new":
            let r = payload[path: "rating"]?.number.map { Int($0) }
            let title = payload[path: "title"]?.string
            return NotifyCandidate(id: id, kind: (r ?? 5) <= 2 ? .badReview : .review, app: app, rating: r, text: text,
                                   privateText: title, isSample: isSample, page: "apps")
        case "asc.webhook", "ci.build", "release.rejected":
            let rejected = payload[path: "rejected"] == .bool(true) || kind == "release.rejected"
            return NotifyCandidate(id: id, kind: .build, app: app, text: text, urgent: rejected, isSample: isSample, page: "apps")
        default:
            return nil
        }
    }
}

/// A notification ready to post.
public struct PlannedNotification: Sendable, Equatable {
    public var id: String
    public var title: String
    public var body: String
    /// Notifications for one app stack together (per-app thread).
    public var thread: String
    public var timeSensitive: Bool
    public var page: String
    public var eventIDs: [Int64]
}

/// Decides what becomes a Mac notification, with no side effects (so every rule is tested):
/// sample data never; kinds you switched off never; paused → nothing; window in front → only urgent ones;
/// quiet hours → only urgent ones (the rest wait until they end); bursts become one per app and kind
/// ("3 new purchases, $8.90"); at most `cap` an hour (urgent ones always go).
public enum NotificationPlanner {
    public struct Context: Sendable {
        public var prefs: NotifyPrefs
        public var now: Date
        public var quiet: QuietHours
        public var sentLastHour: Int
        public var cap: Int
        public var windowFrontmost: Bool
        /// The window is in front but on a page that doesn't show these (Settings, Log): hold them, don't drop them.
        public var windowElsewhere: Bool = false
        public var pausedUntil: Date?
        public var calendar: Calendar
        public var money: @Sendable (Double) -> String
        public init(prefs: NotifyPrefs, now: Date = .now, quiet: QuietHours = .standard, sentLastHour: Int = 0,
                    cap: Int = Store.alertsPerChannelPerHour, windowFrontmost: Bool = false, pausedUntil: Date? = nil,
                    calendar: Calendar = .current, money: @escaping @Sendable (Double) -> String) {
            self.prefs = prefs; self.now = now; self.quiet = quiet; self.sentLastHour = sentLastHour; self.cap = cap
            self.windowFrontmost = windowFrontmost; self.pausedUntil = pausedUntil; self.calendar = calendar; self.money = money
        }
    }

    public struct Result: Sendable, Equatable {
        public var send: [PlannedNotification] = []
        /// Kept for later (quiet hours or over the hourly cap): offered again on the next pass.
        public var later: [NotifyCandidate] = []
        /// Dropped for good (sample, switched off, paused, window in front).
        public var dropped: [Int64] = []
    }

    public static func plan(_ candidates: [NotifyCandidate], _ c: Context) -> Result {
        var r = Result()
        var keep: [NotifyCandidate] = []
        let paused = c.pausedUntil.map { $0 > c.now } ?? false
        for x in candidates {
            if x.isSample || !c.prefs.enabled || !c.prefs.kinds.contains(x.kind) { r.dropped.append(x.id); continue }
            let urgent = x.urgent && x.kind.isUrgentCapable
            if paused && !urgent { r.dropped.append(x.id); continue }
            if c.windowFrontmost && !urgent { r.dropped.append(x.id); continue }
            if c.windowElsewhere && !urgent { r.later.append(x); continue }
            keep.append(x)
        }
        let quiet = c.quiet.end(after: c.now, calendar: c.calendar) != nil
        var budget = max(0, c.cap - c.sentLastHour)
        // Urgent first, then by kind, each group per app.
        let urgent = keep.filter { $0.urgent && $0.kind.isUrgentCapable }
        let normal = keep.filter { !($0.urgent && $0.kind.isUrgentCapable) }
        for u in urgent { r.send.append(single(u, c, timeSensitive: true)) ; budget = max(0, budget - 1) }
        if quiet { r.later += normal; return r }
        var groups: [(key: String, items: [NotifyCandidate])] = []
        for x in normal {
            let key = "\(x.kind.rawValue)|\(x.app ?? "")"
            if let i = groups.firstIndex(where: { $0.key == key }) { groups[i].items.append(x) } else { groups.append((key, [x])) }
        }
        // Several kinds at once (after quiet hours, a pause or a long sleep): one "while you were away" summary
        // instead of a stack of banners.
        if groups.count >= 3, budget > 0 {
            r.send.append(summary(groups.map(\.items), c))
            return r
        }
        for g in groups {
            guard budget > 0 else { r.later += g.items; continue }
            r.send.append(g.items.count == 1 ? single(g.items[0], c, timeSensitive: false) : burst(g.items, c))
            budget -= 1
        }
        return r
    }

    /// "While you were away: 4 purchases (₹1,200), 1 refund, 1 low review", newest app names in the title.
    static func summary(_ groups: [[NotifyCandidate]], _ c: Context) -> PlannedNotification {
        let all = groups.flatMap { $0 }
        func count(_ k: NotifyKind, _ one: String, _ many: String) -> String? {
            let n = all.filter { $0.kind == k }.count
            return n == 0 ? nil : "\(n) \(n == 1 ? one : many)"
        }
        let money = all.filter { $0.kind == .purchase }.compactMap(\.amount)
        let parts = [count(.purchase, "purchase", "purchases").map { p in money.isEmpty ? p : "\(p) (\(c.money(money.reduce(0, +))))" },
                     count(.refund, "refund or cancellation", "refunds or cancellations"),
                     count(.badReview, "low review", "low reviews"), count(.review, "new review", "new reviews"),
                     count(.build, "build update", "build updates"), count(.connection, "connection problem", "connection problems")].compactMap { $0 }
        let apps = Array(Set(all.compactMap(\.app))).sorted()
        let title = apps.isEmpty ? "While you were away" : "While you were away · " + (apps.count <= 2 ? apps.joined(separator: ", ") : "\(apps.count) apps")
        return PlannedNotification(id: "hm-summary-\(all.map(\.id).max() ?? 0)", title: title, body: parts.joined(separator: ", "),
                                   thread: "summary", timeSensitive: false, page: "today", eventIDs: all.map(\.id))
    }

    static func appName(_ x: NotifyCandidate) -> String { x.app?.isEmpty == false ? x.app! : "Hmunmawi" }

    static func single(_ x: NotifyCandidate, _ c: Context, timeSensitive: Bool) -> PlannedNotification {
        let name = appName(x)
        var title: String, body: String
        switch x.kind {
        case .purchase:
            title = "\(name): \(x.label ?? "new purchase")"
            body = [x.text, x.amount.map(c.money)].compactMap { $0 }.filter { !$0.isEmpty }.first ?? "A new purchase"
        case .refund:
            title = "\(name): \(x.label ?? "refund or cancellation")"
            body = x.text.isEmpty ? "A purchase was refunded or cancelled" : x.text
        case .badReview, .review:
            let stars = x.rating.map { "\($0)-star" } ?? "new"
            title = "\(name): \(stars) review"
            body = c.prefs.showDetails ? (x.privateText ?? x.text) : "Open Hmunmawi to read and reply."
        case .build:
            title = x.urgent ? "\(name): build rejected" : "\(name): build update"
            body = x.text
        case .connection:
            // app "" = not a connection (a Mac job or check failed); nil = several connections.
            title = x.app == "" ? "Needs fixing" : "\(x.app ?? "A connection") stopped working"
            body = x.text
        }
        return PlannedNotification(id: "hm-\(x.kind.rawValue)-\(x.id)", title: title, body: body, thread: name,
                                   timeSensitive: timeSensitive, page: x.page, eventIDs: [x.id])
    }

    static func burst(_ xs: [NotifyCandidate], _ c: Context) -> PlannedNotification {
        let first = xs[0], name = appName(first), n = xs.count
        let total = xs.compactMap(\.amount)
        // Known amounts still add up; "+" says some were unknown.
        let sum = total.isEmpty ? nil : c.money(total.reduce(0, +)) + (total.count < n ? "+" : "")
        let labels = Set(xs.compactMap(\.label))
        let one = labels.count == 1 && xs.allSatisfy { $0.label != nil } ? labels.first : nil
        let what: String = switch first.kind {
        case .purchase: one == "renewal" ? "\(n) renewals" : one == "new purchase" || one == nil && labels.isEmpty ? "\(n) new purchases" : "\(n) purchases and renewals"
        case .refund: one == "refund" ? "\(n) refunds" : one == "cancellation" ? "\(n) cancellations" : "\(n) refunds or cancellations"
        case .badReview: "\(n) low reviews"
        case .review: "\(n) new reviews"
        case .build: "\(n) build updates"
        case .connection: "\(n) connection problems"
        }
        return PlannedNotification(id: "hm-\(first.kind.rawValue)-\(first.id)-x\(n)", title: name,
                                   body: [what, sum].compactMap { $0 }.joined(separator: ", "), thread: name,
                                   timeSensitive: false, page: first.page, eventIDs: xs.map(\.id))
    }
}
