import Foundation

/// What the menu bar shows, worked out from events the app already has (no extra checks, no network).
/// A number that isn't known is nil (hidden), never shown as 0.
public enum MenuBarFacts {
    public static let saleKinds: Set<String> = ["revenue.purchase", "revenue.renewal"]
    public static let feedKinds: Set<String> = ["revenue.purchase", "revenue.renewal", "revenue.refund", "revenue.cancelled",
                                                "review.new", "asc.webhook", "ci.build"]

    public struct Today: Equatable, Sendable {
        public var sales: Int
        public var amount: Double?
        public var reviews: Int
        public var refunds: Int
    }

    static func isToday(_ e: StoredEvent, now: Date, calendar: Calendar) -> Bool {
        calendar.isDate(Date(timeIntervalSince1970: Double(e.occurredAt) / 1000), inSameDayAs: now)
    }

    /// Today's sales, money (only when every sale's amount is known), reviews and refunds.
    public static func today(_ events: [StoredEvent], now: Date = .now, calendar: Calendar = .current,
                             amount: (StoredEvent) -> Double?) -> Today {
        let t = events.filter { isToday($0, now: now, calendar: calendar) }
        let sales = t.filter { saleKinds.contains($0.kind) }
        let amounts = sales.compactMap(amount)
        return Today(sales: sales.count, amount: !sales.isEmpty && amounts.count == sales.count ? amounts.reduce(0, +) : nil,
                     reviews: t.filter { $0.kind == "review.new" }.count,
                     refunds: t.filter { $0.kind == "revenue.refund" || $0.kind == "revenue.cancelled" }.count)
    }

    /// "₹1,240 today · 3 sales · 1 new review", or a plain "No sales yet today".
    public static func headline(_ t: Today, money: (Double) -> String) -> String {
        var parts: [String] = []
        if t.sales > 0 {
            if let a = t.amount { parts.append("\(money(a)) today") }
            parts.append(t.sales == 1 ? "1 sale" : "\(t.sales) sales")
        }
        if t.refunds > 0 { parts.append(t.refunds == 1 ? "1 refund" : "\(t.refunds) refunds") }
        if t.reviews > 0 { parts.append(t.reviews == 1 ? "1 new review" : "\(t.reviews) new reviews") }
        return parts.isEmpty ? "No sales or reviews yet today" : parts.joined(separator: " · ")
    }

    /// The number beside the icon: "none", "sales", "downloads" or "reviews". nil = show nothing.
    /// Sample data and sources that aren't connected show nothing.
    public static func number(_ choice: String, events: [StoredEvent], isSample: Bool, now: Date = .now,
                              calendar: Calendar = .current, amount: (StoredEvent) -> Double?, money: (Double) -> String) -> String? {
        guard !isSample else { return nil }
        switch choice {
        case "sales":
            let t = today(events, now: now, calendar: calendar, amount: amount)
            guard t.sales > 0 else { return events.contains { saleKinds.contains($0.kind) } ? money(0) : nil }
            return t.amount.map(money) ?? "\(t.sales)"
        case "downloads":
            // Apple's daily report: the newest day it has published (today or yesterday), never guessed.
            let days = DailyEvents.oneSourcePerDay(events.filter { $0.kind == "revenue.daily" })
            guard let newest = days.max(by: { $0.occurredAt < $1.occurredAt }),
                  let day = newest.payload[path: "day"]?.string else { return nil }
            let units = days.filter { $0.payload[path: "day"]?.string == day }.compactMap { $0.payload[path: "units"]?.number }
            return units.isEmpty ? nil : Int(units.reduce(0, +)).formatted()
        case "reviews":
            guard events.contains(where: { $0.kind == "review.new" || $0.kind == "reviews.snapshot" }) else { return nil }
            return "\(today(events, now: now, calendar: calendar, amount: amount).reviews)"
        default:
            return nil
        }
    }

    /// What sits beside the icon: an optional SF Symbol that says what the number is, and the number itself.
    public struct Badge: Equatable, Sendable {
        public var symbol: String?
        public var text: String
    }

    /// Short form for the menu bar: 999 → "999", 12_345 → "12.3K", 1_200_000 → "1.2M". Negative and non-finite → nil.
    public static func compact(_ n: Double) -> String? {
        guard n.isFinite, n >= 0 else { return nil }
        let v = n.rounded()
        func f(_ x: Double, _ unit: String) -> String {
            let r = (x * 10).rounded() / 10
            return (r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)) + unit
        }
        if v < 10_000 { return Int(v).formatted() }
        if v < 999_950 { return f(v / 1000, "K") }
        if v < 999_950_000 { return f(v / 1_000_000, "M") }
        return f(v / 1_000_000_000, "B")
    }

    /// The badge for a choice. Counts the app already knows (waiting, problems) come in as `counts`;
    /// `hideZero` hides a plain 0 so the bar stays quiet on a calm day. Sample data shows nothing.
    public static func badge(_ choice: String, events: [StoredEvent], isSample: Bool, counts: [String: Int] = [:],
                             hideZero: Bool = false, showSymbol: Bool = true, now: Date = .now, calendar: Calendar = .current,
                             amount: (StoredEvent) -> Double?, money: (Double) -> String) -> Badge? {
        guard !isSample else { return nil }
        let symbols = ["downloads": "arrow.down.circle", "reviews": "star", "waiting": "hand.raised", "problems": "exclamationmark.triangle"]
        var text: String?
        var isZero = false
        switch choice {
        case "waiting", "problems":
            guard let c = counts[choice] else { return nil }
            text = compact(Double(max(0, c))); isZero = c <= 0
        case "sales":
            let t = today(events, now: now, calendar: calendar, amount: amount)
            isZero = t.sales == 0
            text = number(choice, events: events, isSample: false, now: now, calendar: calendar, amount: amount, money: money)
            if t.sales > 0, t.amount == nil { text = compact(Double(t.sales)) }
            // Big amounts: the currency sign plus the short form ("₹1.2M"), never a cut-off "₹1,23,45,6".
            if let a = t.amount, a >= 10_000, let short = compact(a) {
                let sign = money(0).filter { !$0.isNumber && $0 != "." && $0 != "," && !$0.isWhitespace }
                text = sign.count <= 3 ? sign + short : short
            }
        default:
            text = number(choice, events: events, isSample: false, now: now, calendar: calendar, amount: amount, money: money)
            if let s = text, let n = Double(s.filter { $0.isNumber }) { isZero = n == 0; text = compact(n) }
        }
        guard let text, !text.isEmpty, !(hideZero && isZero) else { return nil }
        return Badge(symbol: showSymbol ? symbols[choice] : nil, text: String(text.prefix(10)))
    }

    /// The newest moments for the live feed (purchases, refunds, reviews, build changes), newest first.
    public static func feed(_ events: [StoredEvent], limit: Int) -> [StoredEvent] {
        Array(events.filter { feedKinds.contains($0.kind) }.sorted { $0.occurredAt > $1.occurredAt }.prefix(max(0, limit)))
    }

    /// The latest known value of a number in events of one kind ("followers" in growth.x); nil when none says.
    public static func latest(_ events: [StoredEvent], kind: String, field: String) -> Double? {
        events.filter { $0.kind == kind }.sorted { $0.occurredAt > $1.occurredAt }
            .lazy.compactMap { $0.payload[path: field]?.number }.first
    }
}
