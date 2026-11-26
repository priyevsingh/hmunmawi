import Foundation
import HmunmawiProtocol

// MARK: - Metrics

/// One daily number the engine watches, built generically from whatever data arrives.
public struct Metric: Sendable, Identifiable {
    public enum Better: String, Sendable { case up, down }

    public let key: String          // stable id, e.g. "history.series|My App|downloads"
    public let name: String         // plain name, e.g. "Downloads"
    public let app: String?
    public let better: Better?      // nil = the source didn't say; findings stay neutral
    public let isCount: Bool        // whole events per day (Poisson-like) vs a measured level
    public let isMoney: Bool
    /// True when each point is a day's amount (downloads, earnings, crashes a day), so sentences say "a day" instead of leaving
    /// the reader to guess whether a figure is a total or a daily one. Levels (MRR, subscribers, a rating) stay without it.
    public var perDay = false
    public let points: [(day: Date, value: Double)]
    /// The same measure across apps shares a family ("history.series|downloads"); totals and drivers use it.
    public var family: String = ""
    /// True when the source says this number can be summed across apps.
    public var additive = false
    /// The source's own window for the latest value ("1–7 Nov"), for a rolling total that is read days after its window
    /// ends (Search Console). Sentences then name that window instead of "since <the day it was read>".
    public var period: String?
    /// For totals: dimension ("app", "country", "plan") -> part -> its own daily series.
    public var breakdowns: [String: [String: [(day: Date, value: Double)]]] = [:]
    public var id: String { key }
}

/// Turns stored events into metrics without knowing any source in advance:
/// - any payload with a `days` array and numeric arrays of the same length (one metric per array),
///   and section `series` in the same shape; direction from the payload's `better` map;
/// - per-day events (`*.daily`, or a payload `day`) become one series per numeric field;
/// - every other event kind becomes a daily count per app.
/// Core event kinds of the Hmunmawi protocol carry their direction (sales up, refunds down, crashes down).
public enum MetricExtractor {
    static let protocolDirection: [String: Metric.Better] = [
        "revenue.purchase": .up, "revenue.renewal": .up, "revenue.free": .up, "revenue.refund_reversed": .up,
        "revenue.renewal_extended": .up,
        "revenue.refund": .down, "revenue.cancelled": .down, "revenue.expired": .down, "revenue.billing_issue": .down,
        "revenue.revoked": .down, "revenue.refund_declined": .down, "revenue.price_increase": .down,
        "review.new": .up, "crash.daily|crashed": .down, "crash.daily|crash_free_rate": .up,
        "revenue.daily|units": .up, "revenue.daily|proceeds_usd": .up,
    ]
    static let moneyFields: Set<String> = ["proceeds_usd", "usd", "revenue", "proceeds", "earned"]
    /// Money is shown with "$": the known names, and any field that says it's in dollars ("mrr_usd").
    static func isMoney(_ field: String) -> Bool { moneyFields.contains(field) || field.hasSuffix("_usd") }
    /// Fields that only repeat another one (MRR before Apple's cut moves with MRR): never a finding of their own.
    static let echoFields: Set<String> = ["mrr_gross_usd"]
    static let ignoredKinds: Set<String> = ["routine.run", "routine.tell", "icon.snapshot", "outreach.due", "outreach.batch", "plan.step", "mail.reply", "disk.low",
                                            "attention.items", "revenue.family_shares", "section.snapshot",
                                            // The app's own bookkeeping (status checks, its story events, the daily
                                            // automation log), never business activity; counting story events would
                                            // feed findings back into themselves.
                                            "asc.watch", "asc.access", "automation.day", "automation.extras",
                                            "story.win", "story.worry", "story.digest", "usage.status", "store.signals",
                                            "expiry.status", "offercodes.status", "release.check", "finance.month", "finance.forecast",
                                            // Counts per day with no row on quiet days: read by SubscriptionTruth, not as daily series.
                                            "subscription.events",
                                            // Which of your chosen Mac jobs finished: a notice, not business activity.
                                            "job.finished", "routine.ok"]

    /// The script feed's history series that are running totals since it started counting (they only ever go up), not
    /// values per day. Trends and records must use their day-to-day changes, or they "climb" every day.
    public static let runningTotalFields: Set<String> = ["downloads", "new_subs", "paying"]

    /// Per-day changes of a running total: each point becomes how much it rose since the previous known point (a
    /// day with no figure leaves its rise to the next one). Never negative; the first point has nothing before it.
    public static func daily(fromRunningTotal pts: [(Date, Double)]) -> [(Date, Double)] {
        zip(pts, pts.dropFirst()).map { a, b in (b.0, max(0, b.1 - a.1)) }
    }

    /// True when a series never goes down (what a running total looks like); used as a safety check.
    static func neverFalls(_ pts: [(Date, Double)]) -> Bool { !zip(pts, pts.dropFirst()).contains { $1.1 < $0.1 } }

    public static func extract(_ events: [StoredEvent], now: Date = .now) -> [Metric] {
        var metrics: [String: Metric] = [:]
        let cal = Calendar.current

        // 1. Series payloads (newest snapshot per kind+app wins).
        let snapshots = Dictionary(grouping: events.filter { $0.payload[path: "days"]?.array != nil },
                                   by: { "\($0.kind)|\($0.app ?? "")" })
            .compactMap { $0.value.max { $0.occurredAt < $1.occurredAt } }
        for e in snapshots {
            guard case .object(let fields) = e.payload, let days = e.payload[path: "days"]?.array?.compactMap(\.string) else { continue }
            for (field, value) in fields where field != "days" {
                guard let values = value.array, values.count == days.count else { continue }
                var pts = zip(days, values).compactMap { d, v -> (Date, Double)? in
                    guard let n = v.number, let date = day(d) else { return nil }; return (date, n)
                }
                var convertedToDaily = false
                if e.kind == "history.series", runningTotalFields.contains(field), neverFalls(pts) { pts = daily(fromRunningTotal: pts); convertedToDaily = true }
                guard pts.count >= 7 else { continue }
                let key = "\(e.kind)|\(e.app ?? "")|\(field)"
                // The script feed's "paying" series is new paying customers in its report window (new subscribers +
                // lifetime buyers), not people paying right now; its "Paying subscribers" label would clash
                // with the active-subscriber count, so it gets an honest name here.
                let label = e.kind == "history.series" && field == "paying" ? "New paying customers"
                    : e.payload[path: "labels.\(field)"]?.string ?? readable(field)
                var m = Metric(key: key, name: label, app: e.app,
                               better: better(e.payload, field, kind: e.kind), isCount: false,
                               isMoney: isMoney(field), points: pts)
                m.perDay = convertedToDaily
                m.family = "\(e.kind)|\(field)"
                m.additive = e.payload[path: "additive"]?.array?.contains(.string(field)) ?? false
                m.period = e.payload[path: "periods.\(field)"]?.string
                metrics[key] = m
            }
        }
        // Section series ({label, days, values}) and their direction.
        for e in latestPerKey(events.filter { $0.kind == "section.snapshot" }) {
            for s in e.payload[path: "series"]?.array ?? [] {
                guard let label = s[path: "label"]?.string, let days = s[path: "days"]?.array?.compactMap(\.string),
                      let values = s[path: "values"]?.array, values.count == days.count else { continue }
                let pts = zip(days, values).compactMap { d, v -> (Date, Double)? in
                    guard let n = v.number, let date = day(d) else { return nil }; return (date, n)
                }
                guard pts.count >= 7 else { continue }
                let key = "section|\(e.app ?? "")|\(label)"
                var m = Metric(key: key, name: label, app: e.app,
                               better: s[path: "better"]?.string.flatMap(Metric.Better.init(rawValue:)),
                               isCount: false, isMoney: s[path: "format"]?.string.map { ["usd", "inr"].contains($0) } ?? false,
                               points: pts)
                m.family = "section|\(label)"
                m.additive = s[path: "additive"] == .bool(true)
                metrics[key] = m
            }
        }

        // 2. Per-day events: one series per numeric field.
        let daily = events.filter { ($0.kind.hasSuffix(".daily") || $0.payload[path: "day"]?.string != nil) && $0.kind != "subscription.events" }
        for (group, list) in Dictionary(grouping: daily, by: { "\($0.kind)|\($0.app ?? "")" }) {
            var byField: [String: [Date: Double]] = [:]
            for e in list {
                let d = e.payload[path: "day"]?.string.flatMap(day) ?? cal.startOfDay(for: date(e.occurredAt))
                guard case .object(let fields) = e.payload else { continue }
                for (f, v) in fields { if let n = v.number { byField[f, default: [:]][d] = n } }
            }
            for (field, raw) in byField where raw.count >= 5 && !echoFields.contains(field) {
                let kind = String(group.split(separator: "|").first ?? "")
                // Sales: a day with no report at all is a day nothing sold anywhere (Apple publishes no file), so it's a 0,
                // not a gap; otherwise averages count only the days something sold.
                var values = raw
                if kind == "revenue.daily", let first = raw.keys.min(), let last = raw.keys.max() {
                    var d = first
                    while d < last { if values[d] == nil { values[d] = 0 }; d = cal.date(byAdding: .day, value: 1, to: d) ?? last }
                }
                let key = "\(group)|\(field)"
                var dm = Metric(key: key, name: readable(field), app: list.first?.app,
                                better: protocolDirection["\(kind)|\(field)"], isCount: field == "units" || field == "crashed",
                                isMoney: isMoney(field), points: values.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
                // A day's units, crashes or proceeds; a crash-free percentage or MRR (a monthly level reported daily) is a level.
                dm.perDay = dm.isCount || (dm.isMoney && !field.hasPrefix("mrr"))
                metrics[key] = dm
            }
        }

        // 3. Everything else: a daily count per kind and app, zero-filled from the first day seen.
        let counted = events.filter { e in
            !ignoredKinds.contains(e.kind) && !e.kind.hasSuffix(".snapshot") && !e.kind.hasSuffix(".series")
                && !e.kind.hasSuffix(".daily") && e.payload[path: "days"] == nil && e.payload[path: "day"] == nil
                && !e.kind.hasPrefix("growth.") && !e.kind.hasPrefix("money.") && !e.kind.hasSuffix(".changes")
                && !e.kind.hasSuffix(".months") && !e.kind.hasSuffix(".items")
        }
        let today = cal.startOfDay(for: now)
        // Zero-filled from the first day the source delivered anything at all, not from the first event of this
        // kind: a day the connection was working and nothing happened is a 0, and leaving those days out would make
        // a rare event (one review) look like a daily rate.
        var sourceFirst: [String: Date] = [:]
        for e in events {
            let d = cal.startOfDay(for: date(e.occurredAt))
            if sourceFirst[e.source].map({ d < $0 }) ?? true { sourceFirst[e.source] = d }
        }
        for (group, list) in Dictionary(grouping: counted, by: { "\($0.kind)|\($0.app ?? "")" }) {
            let kind = String(group.split(separator: "|").first ?? "")
            var counts: [Date: Double] = [:]
            for e in list { counts[cal.startOfDay(for: date(e.occurredAt)), default: 0] += 1 }
            guard let firstEvent = counts.keys.min() else { continue }
            let first = list.first.flatMap { sourceFirst[$0.source] }.map { min($0, firstEvent) } ?? firstEvent
            var pts: [(Date, Double)] = []
            var d = first
            while d <= today { pts.append((d, counts[d] ?? 0)); d = cal.date(byAdding: .day, value: 1, to: d)! }
            guard pts.count >= 5 else { continue }
            var m = Metric(key: "count|\(group)", name: kindName(kind), app: list.first?.app,
                           better: protocolDirection[kind], isCount: true, isMoney: false, points: pts)
            m.family = "count|\(kind)"
            m.perDay = true
            m.additive = true
            metrics[m.key] = m
        }

        // 4. Totals across apps for additive families, with a breakdown by app.
        for (family, parts) in Dictionary(grouping: metrics.values.filter { $0.additive && $0.app != nil }, by: \.family) where parts.count >= 2 {
            let series = Dictionary(uniqueKeysWithValues: parts.map { ($0.app!, $0.points) })
            let days = Set(parts[0].points.map(\.day)).filter { d in parts.allSatisfy { p in p.points.contains { $0.day == d } } }.sorted()
            guard days.count >= 7 else { continue }
            let total = days.map { d in (d, parts.map { p in p.points.first { $0.day == d }!.value }.reduce(0, +)) }
            var m = Metric(key: "total|\(family)", name: parts[0].name, app: nil, better: parts[0].better,
                           isCount: parts[0].isCount, isMoney: parts[0].isMoney, points: total)
            m.family = family
            m.perDay = parts[0].perDay
            m.breakdowns["app"] = series
            // Purchases also split by country and plan, read from the events themselves.
            if family.hasPrefix("count|revenue.") {
                let kind = String(family.dropFirst("count|".count))
                for (dim, label) in [("country", { (e: StoredEvent) in e.payload[path: "flag"]?.string }),
                                     ("plan", { (e: StoredEvent) in planName(e) })] {
                    var byPart: [String: [Date: Double]] = [:]
                    for e in events where e.kind == kind {
                        guard let part = label(e) else { continue }
                        byPart[part, default: [:]][cal.startOfDay(for: date(e.occurredAt)), default: 0] += 1
                    }
                    if byPart.count >= 2 {
                        m.breakdowns[dim] = byPart.mapValues { counts in days.map { ($0, counts[$0] ?? 0) } }
                    }
                }
            }
            metrics[m.key] = m
        }
        return Array(metrics.values)
    }

    /// "Weekly", "Yearly", "Lifetime": the plan word at the start of a purchase line, else the product id's last part.
    static func planName(_ e: StoredEvent) -> String? {
        if let detail = e.payload[path: "detail"]?.string, let word = detail.split(separator: "·").first?.trimmingCharacters(in: .whitespaces),
           !word.isEmpty, !word.contains(where: \.isNumber) { return word }
        return e.payload[path: "facts.productId"]?.string?.split(separator: ".").last.map(String.init)
    }

    static func latestPerKey(_ events: [StoredEvent]) -> [StoredEvent] {
        Dictionary(grouping: events, by: { "\($0.app ?? "")|\($0.payload[path: "id"]?.string ?? "")" })
            .compactMap { $0.value.max { $0.occurredAt < $1.occurredAt } }
    }

    static func better(_ payload: JSONValue, _ field: String, kind: String) -> Metric.Better? {
        payload[path: "better.\(field)"]?.string.flatMap(Metric.Better.init(rawValue:)) ?? protocolDirection["\(kind)|\(field)"]
    }

    static func day(_ s: String) -> Date? {
        let parts = s.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func date(_ ms: Millis) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    static func readable(_ field: String) -> String {
        let known = ["mrr_usd": "MRR", "mrr_gross_usd": "MRR before Apple's cut", "active_paid": "Paying subscribers",
                     "proceeds_usd": "Earnings", "units": "Downloads", "crashed": "Crashes"]
        if let k = known[field] { return k }
        let s = field.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: " usd", with: "")
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    static func kindName(_ kind: String) -> String {
        ["revenue.purchase": "New subscribers", "revenue.renewal": "Renewals", "revenue.cancelled": "Cancellations",
         "revenue.refund": "Refunds", "revenue.expired": "Expired subscriptions", "revenue.billing_issue": "Billing problems",
         "revenue.free": "Free trials", "revenue.refund_reversed": "Refunds reversed",
         "revenue.refund_declined": "Refunds declined", "revenue.plan_change": "Plan changes",
         "revenue.price_increase": "Price increases", "revenue.renewal_extended": "Renewals extended",
         "revenue.revoked": "Access revoked", "revenue.consumption_request": "Refund checks",
         "review.new": "New reviews"][kind] ?? readable(kind.split(separator: ".").last.map(String.init) ?? kind)
    }
}

// MARK: - Findings

public struct Finding: Sendable, Identifiable {
    public enum Lane: String, Sendable { case win, worry, change }
    public enum Detector: String, Sendable { case unusual, newLevel, trend, record, declared }

    public let id: String
    public let lane: Lane
    public let detector: Detector
    public let app: String?
    public let title: String        // plain sentence
    public let evidence: String     // the number chip
    public let why: String          // how the engine knows, in plain words
    public let score: Double        // ranking: significance x value x freshness
    public let metricKey: String?
    public let points: [(day: Date, value: Double)]
    /// What drove the change, e.g. "mostly My App (80%)"; nil when no single part explains it.
    public var driver: String?
    public var family: String?
    /// Exact percentage shift for two-segment level changes (`newLevel`), matching the headline split.
    public var deltaPercent: Int?

    public init(id: String, lane: Lane, detector: Detector, app: String?, title: String, evidence: String, why: String,
                score: Double, metricKey: String? = nil, points: [(day: Date, value: Double)] = [], deltaPercent: Int? = nil) {
        self.id = id; self.lane = lane; self.detector = detector; self.app = app; self.title = title
        self.evidence = evidence; self.why = why; self.score = score; self.metricKey = metricKey; self.points = points
        self.deltaPercent = deltaPercent
    }
}

/// Statistical detectors that judge each metric against its own normal, so a slow, steady indie pace is
/// never flagged; only real changes surface. Counts use a Poisson test (1 sale vs 0 is noise), levels use a
/// robust z-score (median and MAD), new levels use a two-segment split, trends use Theil-Sen with Mann-Kendall.
public enum InsightEngine {
    /// The one moment a run judges freshness against (read once per run, so scores don't drift while it runs).
    @TaskLocal static var runNow: Date?
    /// "Today" for the run's own time (a replay or report for an earlier date), not the wall clock.
    static func isRunToday(_ day: Date) -> Bool { Calendar.current.isDate(day, inSameDayAs: runNow ?? .now) }

    public static func run(_ metrics: [Metric], now: Date = .now) -> [Finding] {
        $runNow.withValue(now) { runAt(metrics) }
    }

    private static func runAt(_ metrics: [Metric]) -> [Finding] {
        let found = metrics.flatMap { m in
            [unusual(m), newLevel(m), trend(m), record(m)].compactMap { f -> Finding? in
                guard var f else { return nil }
                f.family = m.family
                f.driver = driver(m, f.detector)
                return f
            }
        }
        // A total explained by one app makes that app's own finding on the same measure redundant.
        let explained = Set(found.compactMap { f -> String? in
            guard f.metricKey?.hasPrefix("total|") == true, let d = f.driver, let fam = f.family else { return nil }
            return metrics.first { $0.key == f.metricKey }?.breakdowns["app"]?.keys.first { d.contains($0) }.map { "\(fam)|\($0)" }
        })
        return found.filter { f in !(f.app.map { explained.contains("\(f.family ?? "")|\($0)") } ?? false) }
        .sorted { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }   // equal scores in a fixed order (no reshuffling between refreshes)
        .reduce(into: [Finding]()) { out, f in   // one finding per metric: the strongest
            if !out.contains(where: { $0.metricKey == f.metricKey }) { out.append(f) }
        }
    }

    // 1. Unusual vs its own normal (last value against the previous 28 days).
    static func unusual(_ m: Metric) -> Finding? {
        guard m.points.count >= 8, let last = m.points.last else { return nil }
        // A level (MRR, subscribers) that has stayed put for several readings changed when the run began, not on
        // the latest reading: "has been $0.00 since 17 Oct", judged against the days before the run.
        var runStart = m.points.count - 1
        if !m.isCount { while runStart > 0 && m.points[runStart - 1].value == last.value { runStart -= 1 } }
        let inRun = runStart < m.points.count - 1
        let base = (inRun ? Array(m.points[..<runStart]) : Array(m.points.dropLast())).suffix(28).map(\.value)
        guard base.count >= 5 else { return nil }
        let since = m.period.map { "for \($0)" } ?? ("since " + m.points[runStart].day.formatted(.dateTime.day().month(.abbreviated)))
        var significance: Double
        let normal: Double
        if m.isCount {
            normal = base.reduce(0, +) / Double(base.count)
            // Today is still in progress, so a low count today is not news; and against a history of zeros
            // a single event is noise.
            guard normal > 0.2 else { return nil }
            if last.value < normal && isRunToday(last.day) { return nil }
            let p = last.value >= normal ? poissonUpper(Int(last.value), normal) : poissonLower(Int(last.value), normal)
            guard p < 0.02, abs(last.value - normal) >= 1 else { return nil }
            significance = min(1, -log10(max(p, 1e-6)) / 4)
        } else {
            normal = median(base)
            let mad = median(base.map { abs($0 - normal) }) * 1.4826
            let z = mad > 0 ? (last.value - normal) / mad : (last.value == normal ? 0 : (abs(last.value - normal) / max(abs(normal), 1)) * 10)
            guard abs(z) >= 3.5, abs(last.value - normal) / max(abs(normal), 1e-9) >= 0.05 else { return nil }
            significance = min(1, abs(z) / 8)
        }
        let up = last.value > normal
        return finding(m, .unusual, up: up, significance: significance,
                       title: inRun ? "\(plainName(m.name)) \(up ? "rose to" : "dropped to") \(fmtRate(last.value, m)) \(since), from a usual \(fmtRate(normal, m))"
                            : up ? "\(plainName(m.name)) hit \(fmt(last.value, m)) \(when(last.day)), well above the usual \(fmtRate(normal, m))"
                                 : "\(plainName(m.name)) fell to \(fmt(last.value, m)) \(when(last.day)), well below the usual \(fmtRate(normal, m))",
                       evidence: fmt(last.value, m),
                       why: m.isCount
                         ? "A day like this happens by chance less than 1 in 50 days, given the usual \(fmt(normal, m)) a day."
                         : "Far outside its normal range over the last \(base.count) days (median \(fmt(normal, m)))."
                       , effect: last.value - normal)
    }

    // 2. Settled at a new level: the best two-segment split of the last 28 days.
    static func newLevel(_ m: Metric) -> Finding? {
        let pts = Array(m.points.suffix(28))
        guard pts.count >= 12 else { return nil }
        var best: (i: Int, t: Double)?
        for i in 5...(pts.count - 5) {
            let a = pts[..<i].map(\.value), b = pts[i...].map(\.value)
            let t = welchT(a, b)
            if abs(t) > abs(best?.t ?? 0) { best = (i, t) }
        }
        guard let best, abs(best.t) >= 4 else { return nil }
        let before = mean(pts[..<best.i].map(\.value)), after = mean(pts[best.i...].map(\.value))
        guard abs(after - before) / max(abs(before), 1e-9) >= 0.15 else { return nil }
        let up = after > before
        let pct = before > 0 ? Int((((after - before) / abs(before)) * 100).rounded()) : nil
        var f = finding(m, .newLevel, up: up, significance: min(1, abs(best.t) / 10),
                        title: {
                            let since = pts[best.i].day.formatted(.dateTime.day().month(.abbreviated))
                            if let period = m.period {   // a rolling window read later: name the window, not the reading day
                                if after.rounded() == 0 { return "No \(lower(m.name)) for \(period) (\(approx(fmt(before, m))) before)" }
                                return "\(plainName(m.name)) \(up ? "up" : "down"): \(approx(fmtRate(after, m))) in recent readings (latest \(period)), \(up ? "from" : "down from") \(fmtRate(before, m))"
                            }
                            if after.rounded() == 0 { return "No \(lower(m.name)) since \(since) (\(approx(fmt(before, m))) before)" }
                            return "\(plainName(m.name)) \(up ? "up" : "down") since \(since): \(approx(fmtRate(after, m))) now, \(up ? "from" : "down from") \(fmtRate(before, m))"
                        }(),
                        evidence: "\(up ? "up" : "down") to \(fmt(after, m))",
                        why: "The days since \(pts[best.i].day.formatted(.dateTime.day().month(.abbreviated))) sit clearly apart from the days before, not a one-day blip.",
                        effect: after - before)
        f.deltaPercent = pct
        return f
    }

    // 3. Steady trend: Theil-Sen slope, kept only when Mann-Kendall says it is real (p < 0.01).
    static func trend(_ m: Metric) -> Finding? {
        let pts = Array(m.points.suffix(28))
        guard pts.count >= 10 else { return nil }
        let v = pts.map(\.value)
        var s = 0.0
        for i in 0..<v.count { for j in (i + 1)..<v.count { s += v[j] > v[i] ? 1 : v[j] < v[i] ? -1 : 0 } }
        let n = Double(v.count), varS = n * (n - 1) * (2 * n + 5) / 18
        let z = s == 0 ? 0 : (s - (s > 0 ? 1 : -1)) / varS.squareRoot()
        guard abs(z) >= 2.58 else { return nil }
        var slopes: [Double] = []
        for i in 0..<v.count { for j in (i + 1)..<v.count { slopes.append((v[j] - v[i]) / Double(j - i)) } }
        let perWeek = median(slopes) * 7
        guard perWeek != 0, abs(perWeek) / max(abs(mean(v)), 1e-9) >= 0.05 else { return nil }
        let up = perWeek > 0
        return finding(m, .trend, up: up, significance: min(1, abs(z) / 5),
                       title: "\(plainName(m.name)) \(up ? "climbing" : "slipping") week after week",
                       evidence: "\(up ? "+" : "−")\(fmt(abs(perWeek), m)) a week",
                       why: "Most days over the last \(pts.count) moved the same way; a pattern this consistent is very unlikely by chance.",
                       effect: perWeek)
    }

    // 4. Records: best or worst day in all the history there is (at least 14 days).
    static func record(_ m: Metric) -> Finding? {
        guard m.points.count >= 14, let last = m.points.last else { return nil }
        let rest = m.points.dropLast().map(\.value)
        guard let hi = rest.max(), let lo = rest.min(), hi != lo else { return nil }
        let high = last.value > hi, low = last.value < lo
        guard high || low else { return nil }
        // Today is still running: a low count so far isn't a record (same rule as the unusual-day detector).
        if low && m.isCount && isRunToday(last.day) { return nil }
        return finding(m, .record, up: high, significance: 0.6,
                       title: high ? "Best day for \(lower(m.name)) in \(m.points.count) days" : "Lowest \(lower(m.name)) in \(m.points.count) days",
                       evidence: fmt(last.value, m),
                       why: "Higher or lower than every day since \(m.points.first!.day.formatted(.dateTime.day().month(.abbreviated))).",
                       effect: last.value - (high ? hi : lo))
    }

    /// A metric's name for a sentence: unit hints like " (%)" belong on chart axes, not in prose.
    /// The metric's name inside a sentence: no "(%)" and "Google clicks, 7 days" → "Google clicks over 7 days".
    static func plainName(_ name: String) -> String {
        var n = name.replacingOccurrences(of: " (%)", with: "")
            .replacingOccurrences(of: #", (\d+) days?$"#, with: " over $1 days", options: .regularExpression)
        // "Fit: Workout Timer: Earnings" reads as a sentence: "Fit: Workout Timer earnings" (one colon, in the app's name).
        if let r = n.range(of: ": ", options: .backwards) {
            n = String(n[..<r.lowerBound]) + " " + lower(String(n[r.upperBound...]))
        }
        return n
    }

    /// "First downloads" → "first downloads" mid-sentence; brand/camelCase names ("YouTube", "iPhone", "X followers") stay.
    static func lower(_ name: String) -> String {
        let clean = name.replacingOccurrences(of: " (%)", with: "")
        let firstWord = clean.split(separator: " ", maxSplits: 1).first ?? ""
        if firstWord.dropFirst().contains(where: \.isUppercase) { return clean }
        guard let first = clean.first, clean.dropFirst().first?.isLowercase == true else { return clean }
        return first.lowercased() + clean.dropFirst()
    }

    static func businessWeight(for m: Metric, lane: Finding.Lane) -> Double {
        let k = (m.key + "|" + m.family).lowercased()
        if m.isMoney || k.contains("mrr") || k.contains("active_subs") || k.contains("paying") || k.contains("crashed") || k.contains("crash_free") {
            return lane == .worry ? 1.55 : 1.30
        }
        if k.contains("new_subs") || k.contains("conversion") || k.contains("downloads") {
            return lane == .worry ? 1.25 : 1.15
        }
        return 1.0
    }

    static func finding(_ m: Metric, _ d: Finding.Detector, up: Bool, significance: Double,
                        title: String, evidence: String, why: String, effect: Double) -> Finding {
        let lane: Finding.Lane = m.better.map { ($0 == .up) == up ? .win : .worry } ?? .change
        let value = m.isMoney ? 1 + log10(1 + abs(effect)) : 1 + log10(1 + abs(effect)) * 0.5
        let at = runNow ?? .now
        let age = at.timeIntervalSince(m.points.last?.day ?? at) / 86_400
        let freshness = max(0.3, 1 - age / 7)
        let laneWeight = lane == .change ? 0.4 : 1
        let business = businessWeight(for: m, lane: lane)
        return Finding(id: "\(m.key)|\(d.rawValue)", lane: lane, detector: d, app: m.app,
                       title: (m.app.map { "\($0): " } ?? "") + title, evidence: evidence, why: why,
                       score: significance * value * freshness * laneWeight * business, metricKey: m.key, points: m.points)
    }

    /// Splits the change by each breakdown; names the part behind at least 60% of it, using the dimension
    /// that explains the most. Compares the latest day (unusual) or the last 7 days (others) with the days before.
    static func driver(_ m: Metric, _ d: Finding.Detector) -> String? {
        func delta(_ pts: [(day: Date, value: Double)]) -> Double {
            let recent = d == .unusual ? Array(pts.suffix(1)) : Array(pts.suffix(7))
            let before = Array(pts.dropLast(recent.count).suffix(28))
            guard !recent.isEmpty, !before.isEmpty else { return 0 }
            return mean(recent.map(\.value)) - mean(before.map(\.value))
        }
        var best: (text: String, share: Double)?
        for (dim, parts) in m.breakdowns {
            let deltas = parts.mapValues(delta)
            let total = deltas.values.reduce(0, +)
            guard total != 0, let top = deltas.max(by: { $0.value * total.sign.rawSign < $1.value * total.sign.rawSign }) else { continue }
            let share = top.value / total
            guard share >= 0.6, share <= 1.5 else { continue }
            if share > (best?.share ?? 0) {
                let pct = Int((min(share, 1) * 100).rounded())
                best = ("mostly \(top.key)\(dim == "plan" ? " plan" : "") (\(pct)%)", share)
            }
        }
        return best?.text
    }

    // MARK: Statistics

    static func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }

    static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted(); return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func welchT(_ a: [Double], _ b: [Double]) -> Double {
        let ma = mean(a), mb = mean(b)
        let va = a.map { ($0 - ma) * ($0 - ma) }.reduce(0, +) / Double(max(a.count - 1, 1))
        let vb = b.map { ($0 - mb) * ($0 - mb) }.reduce(0, +) / Double(max(b.count - 1, 1))
        let se = (va / Double(a.count) + vb / Double(b.count)).squareRoot()
        return se > 0 ? (mb - ma) / se : (mb == ma ? 0 : (mb > ma ? 99 : -99))
    }

    /// P(X >= k) for Poisson(lambda).
    static func poissonUpper(_ k: Int, _ lambda: Double) -> Double {
        guard k > 0 else { return 1 }
        return max(0, 1 - poissonCDF(k - 1, lambda))
    }

    /// P(X <= k) for Poisson(lambda).
    static func poissonLower(_ k: Int, _ lambda: Double) -> Double { poissonCDF(k, lambda) }

    static func poissonCDF(_ k: Int, _ lambda: Double) -> Double {
        guard lambda > 0 else { return 1 }
        // exp(-lambda) underflows to 0 past ~745, which made every busy day look "unusual": sum in log space there.
        // Below that the old exact loop stays, so numbers don't change.
        if lambda > 700 {
            var logTerm = -lambda, logSum = logTerm
            if k > 0 {
                for i in 1...k {
                    logTerm += log(lambda) - log(Double(i))
                    let hi = max(logSum, logTerm)
                    logSum = hi + log(exp(logSum - hi) + exp(logTerm - hi))
                }
            }
            return min(1, exp(logSum))
        }
        var term = exp(-lambda), sum = term
        if k > 0 { for i in 1...k { term *= lambda / Double(i); sum += term } }
        return min(1, sum)
    }

    /// How money reads in findings: the app sets your currency (converted, "≈₹9,170"); dollars until then.
    nonisolated(unsafe) public static var money: @Sendable (Double) -> String = { v in "$" + v.formatted(.number.precision(.fractionLength(v < 100 ? 2 : 0))) }

    /// "about 141", or just "≈₹10,474" when the amount already says it's approximate (never "about ≈").
    static func approx(_ s: String) -> String { s.hasPrefix("≈") ? s : "about " + s }

    static func fmt(_ v: Double, _ m: Metric) -> String {
        if m.isMoney { return money(v) }
        // The script feed's conversion series is already in percent (15.79 = 15.79%).
        if m.key.hasSuffix("|conversion") { return v.formatted(.number.precision(.fractionLength(1))) + "%" }
        return v.formatted(.number.precision(.fractionLength(abs(v) < 10 && v != v.rounded() ? 1 : 0)))
    }

    /// A value with its unit when it is a day's amount: "≈₹397 a day". Levels are shown as they are.
    static func fmtRate(_ v: Double, _ m: Metric) -> String { fmt(v, m) + (m.perDay ? " a day" : "") }

    static func when(_ day: Date) -> String {
        let at = runNow ?? .now, cal = Calendar.current
        return cal.isDate(day, inSameDayAs: at) ? "today"
            : cal.date(byAdding: .day, value: -1, to: at).map { cal.isDate(day, inSameDayAs: $0) } == true ? "yesterday"
            : "on \(day.formatted(.dateTime.day().month(.abbreviated)))"
    }
}

private extension FloatingPointSign {
    var rawSign: Double { self == .minus ? -1 : 1 }
}
