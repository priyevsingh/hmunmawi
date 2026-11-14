import Foundation

/// "yyyy-MM-dd" <-> a day number (days since 1970-01-01), without a DateFormatter: report days are compared and
/// shifted by whole days thousands of times per refresh. The conversion is Howard Hinnant's public-domain
/// days_from_civil / civil_from_days (https://howardhinnant.github.io/date_algorithms.html).
public enum DayNumber {
    public static func of(_ day: String) -> Int? {
        let p = day.split(separator: "-")
        guard p.count == 3, let y0 = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]), (1...12).contains(m), (1...31).contains(d) else { return nil }
        // Howard Hinnant's days_from_civil.
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    public static func day(_ n: Int) -> String {
        let z = n + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    public static func of(millis: Int64) -> Int { Int((Double(millis) / 86_400_000).rounded(.down)) }
}

/// Why people start and stop paying for one app, from Apple's Subscription Event report (`subscription.events`
/// rows, one per app and day). Counts are Apple's own; nothing is estimated except where a label says so.
public struct SubscriptionTruth: Sendable, Equatable {
    public struct Renewal: Sendable, Equatable {
        public let after: Int          // paid periods after the first one
        public let kept: Int           // started the period after that
        public let of: Int             // started their first paid period early enough to have got there
    }
    public struct Plan: Sendable, Equatable {
        public let name: String        // "weekly", "monthly", "yearly" …
        public let periodDays: Double
        public let starts: Int         // first paid periods in the whole history
        public let points: [Renewal]   // only the steps the history is long enough for
    }

    public let app: String
    public let windowDays: Int, fromDay: String, toDay: String
    public let historyFrom: String
    public let trialsStarted: Int, trialsEnded: Int, trialsPaid: Int, trialsCancelled: Int, trialsFailed: Int
    public let newPaid: Int, fromTrial: Int, reactivated: Int
    public let cancels: Int, cancelsFirst: Int
    public let billingTrouble: Int, recovered: Int, billingLost: Int, daysRecovered: Int
    public let refunds: Int, payments: Int
    public let plans: [Plan]
    public let newByCountry: [String: Int]

    /// Everyone who started paying in the window (new, after a trial, or back again).
    public var starts: Int { newPaid + fromTrial + reactivated }
    public var leavers: Int { cancels + billingLost }
    public var trialToPaid: Double? { trialsEnded > 0 ? Double(min(trialsPaid, trialsEnded)) / Double(trialsEnded) : nil }
    public var refundRate: Double? { payments > 0 ? Double(refunds) / Double(payments) : nil }
    /// The most common plan among first payments: its period names the "first week/month/year".
    public var mainPlan: Plan? { plans.max { $0.starts < $1.starts } }

    static let periodDays: [String: Double] = ["weekly": 7, "monthly": 30.4375, "every 2 months": 60.875, "quarterly": 91.3125,
                                               "half-yearly": 182.625, "yearly": 365.25]
    public static let steps = [1, 3, 6, 12]

    /// One per app with any subscription events. `windowDays`: how far back the counts look, ending at the newest
    /// report day across all apps (Apple publishes all apps' days together).
    public static func make(_ rows: [StoredEvent], windowDays: Int = 90) -> [String: SubscriptionTruth] {
        let rows = rows.filter { $0.kind == "subscription.events" }
        let dayOf: (StoredEvent) -> Int? = { $0.payload[path: "day"]?.string.flatMap(DayNumber.of) }
        guard let last = rows.compactMap(dayOf).max() else { return [:] }
        let first = last - windowDays + 1
        var out: [String: SubscriptionTruth] = [:]
        for (app, list) in Dictionary(grouping: rows, by: { $0.app ?? "Your app" }) {
            // One row per day (a re-sent day would otherwise count twice).
            var byDay: [Int: JSONValue] = [:]
            for e in list { if let d = dayOf(e) { byDay[d] = e.payload } }
            func sum(_ field: String, _ days: ClosedRange<Int> = first...last) -> Int {
                byDay.reduce(0) { days.contains($1.key) ? $0 + Int($1.value[path: field]?.number ?? 0) : $0 }
            }
            func map(_ p: JSONValue, _ field: String) -> [String: Int] {
                guard case .object(let m)? = p[path: field] else { return [:] }
                return m.compactMapValues { $0.number.map { Int($0) } }
            }
            // Trials that have run their course by the newest day (length known; 7 days when Apple didn't say).
            var started = 0, ended = 0
            for (d, p) in byDay where d >= first {
                let lengths = map(p, "trial_lengths")
                let n = Int(p[path: "trials"]?.number ?? 0)
                started += n
                let known = lengths.reduce(0) { $0 + $1.value }
                for (len, count) in lengths where d + (Int(len) ?? 7) <= last { ended += count }
                if n > known, d + 7 <= last { ended += n - known }
            }
            var countries: [String: Int] = [:]
            for (d, p) in byDay where d >= first { for (c, n) in map(p, "new_by_country") { countries[c, default: 0] += n } }
            // Paid periods by plan over the whole history, for renewal by plan.
            var paid: [String: [Int: [Int: Int]]] = [:]   // plan -> period -> day -> count
            var payments = 0
            for (d, p) in byDay {
                for (key, n) in map(p, "paid") {
                    let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
                    guard parts.count == 2, let period = Int(parts[1]) else { continue }
                    paid[parts[0], default: [:]][period, default: [:]][d, default: 0] += n
                    if d >= first { payments += n }
                }
            }
            let historyStart = byDay.keys.min() ?? last
            let plans = paid.compactMap { name, periods -> Plan? in
                guard let length = periodDays[name] else { return nil }
                let firsts = periods[1] ?? [:]
                let points = steps.compactMap { k -> Renewal? in
                    let shift = Int((Double(k) * length).rounded())
                    // First payments early enough that their k-th renewal is due (3 days' slack for a late charge).
                    let lastStart = last - shift - 3
                    guard lastStart >= historyStart else { return nil }
                    let of = firsts.reduce(0) { $1.key <= lastStart ? $0 + $1.value : $0 }
                    guard of > 0 else { return nil }
                    let kept = (periods[k + 1] ?? [:]).reduce(0) { $1.key - shift <= lastStart + 3 ? $0 + $1.value : $0 }
                    return Renewal(after: k, kept: min(kept, of), of: of)
                }
                return Plan(name: name, periodDays: length, starts: firsts.values.reduce(0, +), points: points)
            }.sorted { $0.periodDays < $1.periodDays }
            out[app] = SubscriptionTruth(
                app: app, windowDays: windowDays, fromDay: DayNumber.day(max(first, historyStart)), toDay: DayNumber.day(last),
                historyFrom: DayNumber.day(historyStart),
                trialsStarted: started, trialsEnded: ended, trialsPaid: sum("trial_paid"), trialsCancelled: sum("trial_cancel"), trialsFailed: sum("trial_failed"),
                newPaid: sum("new_paid"), fromTrial: sum("trial_paid"), reactivated: sum("reactivated"),
                cancels: sum("cancels"), cancelsFirst: sum("cancels_first"),
                billingTrouble: sum("billing_trouble"), recovered: sum("recovered"), billingLost: sum("billing_lost"),
                daysRecovered: sum("days_recovered"), refunds: sum("refunds"), payments: payments,
                plans: plans, newByCountry: countries)
        }
        return out
    }

    /// "week" for weekly, "month", "year"; "period" otherwise.
    public static func periodWord(_ plan: String?) -> String {
        switch plan { case "weekly": "week"; case "monthly": "month"; case "yearly": "year"; default: "period" }
    }

    /// The one line that says where subscribers are lost; nil when nothing was lost in the window.
    public var headline: String? {
        let word = Self.periodWord(mainPlan?.name)
        if trialsEnded >= 2, trialsPaid == 0 { return "None of the \(trialsEnded) free trials that ended became paid" }
        guard leavers > 0 else { return starts > 0 ? "Nobody turned renewal off in the last \(windowDays) days" : nil }
        // "Most" needs a few people behind it; one person is not a pattern.
        if starts >= 5, cancelsFirst * 2 >= max(cancels, 2) {
            return "Most who leave turn renewal off in their first \(word): \(cancelsFirst) of \(starts) who started paying"
        }
        if billingLost > cancels { return "More subscribers were lost to failed payments (\(billingLost)) than to cancelling (\(cancels))" }
        return "\(cancels) turned renewal off" + (billingLost > 0 ? " and \(billingLost) left after a failed payment" : "")
    }
}

/// Countries whose paying subscribers bring in well under the app's usual amount each: Apple's local price there
/// may be low. Advice only: prices are changed (or not) in App Store Connect by you.
public struct CountryValue: Sendable, Equatable {
    public let app: String, country: String
    public let active: Int
    public let perSubUSD: Double, appPerSubUSD: Double
    /// Over the days that have downloads by country (nil until there are 28 of them).
    public let conversion: Double?, appConversion: Double?
    public let newPaid: Int, downloads: Double

    /// `mrr`: subscription.mrr rows (the newest per app is used); `daily`: revenue.daily rows; `subs`: subscription.events rows.
    public static func flags(mrr: [StoredEvent], daily: [StoredEvent], subs: [StoredEvent], minActive: Int = 3) -> [CountryValue] {
        var latest: [String: StoredEvent] = [:]
        for e in mrr where e.kind == "subscription.mrr" {
            let app = e.app ?? ""
            if let cur = latest[app], (cur.payload[path: "day"]?.string ?? "") >= (e.payload[path: "day"]?.string ?? "") { continue }
            latest[app] = e
        }
        var out: [CountryValue] = []
        for (app, e) in latest {
            guard case .object(let countries)? = e.payload[path: "countries"] else { continue }
            let active = e.payload[path: "active_paid"]?.number ?? 0, total = e.payload[path: "mrr_usd"]?.number ?? 0
            guard active >= Double(minActive) * 2, total > 0 else { continue }
            let avg = total / active
            // Downloads and new paid subscribers per country, over the same days (those that have country data).
            let days = Set(daily.filter { $0.kind == "revenue.daily" && $0.app == app && $0.payload[path: "units_by_country"] != nil }
                .compactMap { $0.payload[path: "day"]?.string })
            var downloads: [String: Double] = [:], newPaid: [String: Int] = [:]
            for r in daily where r.kind == "revenue.daily" && r.app == app {
                guard let d = r.payload[path: "day"]?.string, days.contains(d), case .object(let m)? = r.payload[path: "units_by_country"] else { continue }
                for (c, v) in m { downloads[c, default: 0] += v.number ?? 0 }
            }
            for r in subs where r.kind == "subscription.events" && r.app == app {
                guard let d = r.payload[path: "day"]?.string, days.contains(d), case .object(let m)? = r.payload[path: "new_by_country"] else { continue }
                for (c, v) in m { newPaid[c, default: 0] += Int(v.number ?? 0) }
            }
            let enough = days.count >= 28
            let allDownloads = downloads.values.reduce(0, +), allNew = newPaid.values.reduce(0, +)
            for (code, v) in countries {
                let n = Int(v[path: "active"]?.number ?? 0), money = v[path: "mrr_usd"]?.number ?? 0
                guard n >= minActive, Double(n) < active else { continue }   // one country holding everyone has nothing to compare with
                let each = money / Double(n)
                guard each < avg * 0.5 else { continue }
                let dl = downloads[code] ?? 0
                out.append(CountryValue(app: app, country: code, active: n, perSubUSD: each, appPerSubUSD: avg,
                                        conversion: enough && dl >= 20 ? Double(newPaid[code] ?? 0) / dl : nil,
                                        appConversion: enough && allDownloads >= 50 ? Double(allNew) / allDownloads : nil,
                                        newPaid: newPaid[code] ?? 0, downloads: dl))
            }
        }
        return out.sorted { ($0.app, $0.perSubUSD / $0.appPerSubUSD) < ($1.app, $1.perSubUSD / $1.appPerSubUSD) }
    }
}

/// Did a release help or hurt? The 7 days from the day a version went live against the 7 days before it:
/// crash-free sessions (Sentry), new ratings and their stars, and how many downloads started paying or a trial.
/// Downloads per day are shown for context but not judged (search and features move them more than a release).
public struct ReleaseReport: Sendable, Equatable {
    public enum Call: String, Sendable { case better, same, worse, tooFew }
    public enum Verdict: Sendable, Equatable { case helped, hurt(String), noChange, tooFew }
    public struct Measure: Sendable, Equatable {
        public let name: String
        public let before: String, after: String
        public let call: Call
        public let note: String
        public var judged = true
    }

    public let app: String, version: String
    public let liveDay: String, readyDay: String
    public let measures: [Measure]
    public let verdict: Verdict

    /// `liveDay`: the UTC day the version went live. `newestDay`: the newest day Apple's daily reports cover; the
    /// report is nil until it covers the whole 7 days after. `snapshots`: app.snapshot rows (rating, ratings_count).
    /// Every list holds this app's rows only (apps are named differently by different sources).
    public static func make(app: String, version: String, liveDay: String, newestDay: String?,
                            crash: [StoredEvent], daily: [StoredEvent], subs: [StoredEvent], snapshots: [StoredEvent]) -> ReleaseReport? {
        guard let live = DayNumber.of(liveDay), let newest = newestDay.flatMap(DayNumber.of), newest >= live + 6 else { return nil }
        let before = (live - 7)...(live - 1), after = live...(live + 6)
        func rows(_ list: [StoredEvent], _ kind: String, _ days: ClosedRange<Int>) -> [JSONValue] {
            list.filter { $0.kind == kind }.compactMap { e in
                e.payload[path: "day"]?.string.flatMap(DayNumber.of).map { days.contains($0) ? e.payload : nil } ?? nil
            }
        }
        func total(_ list: [JSONValue], _ field: String) -> Double { list.reduce(0) { $0 + ($1[path: field]?.number ?? 0) } }
        var measures: [Measure] = []

        // Crash-free sessions.
        let cb = rows(crash, "crash.daily", before), ca = rows(crash, "crash.daily", after)
        let sb = total(cb, "sessions"), sa = total(ca, "sessions")
        if sb > 0 || sa > 0 {
            func rate(_ l: [JSONValue], _ s: Double) -> Double { s > 0 ? 100 * (1 - total(l, "crashed") / s) : 100 }
            let rb = rate(cb, sb), ra = rate(ca, sa)
            let call: Call = sb < 20 || sa < 20 ? .tooFew
                : ra < rb - 0.5 && total(ca, "crashed") >= 2 ? .worse : ra > rb + 0.5 ? .better : .same
            measures.append(Measure(name: "Crash-free sessions", before: pct(rb), after: pct(ra), call: call,
                                    note: call == .tooFew ? "only \(Int(sb)) and \(Int(sa)) sessions" : "\(Int(sa)) sessions since"))
        }

        // Downloads, and how many of them started paying or a trial.
        let db = rows(daily, "revenue.daily", before), da = rows(daily, "revenue.daily", after)
        let ub = total(db, "units"), ua = total(da, "units")
        let pb = rows(subs, "subscription.events", before), pa = rows(subs, "subscription.events", after)
        let nb = total(pb, "new_paid") + total(pb, "trials"), na = total(pa, "new_paid") + total(pa, "trials")
        if ub > 0 || ua > 0 {
            measures.append(Measure(name: "Downloads a day", before: one(ub / 7), after: one(ua / 7), call: .same,
                                    note: "context only", judged: false))
            let cb = ub > 0 ? nb / ub : 0, ca = ua > 0 ? na / ua : 0
            let call: Call = ub < 20 || ua < 20 || nb + na < 3 ? .tooFew
                : ca < cb * 0.75 && nb - na >= 2 ? .worse : ca > cb * 1.25 && na - nb >= 2 ? .better : .same
            measures.append(Measure(name: "Downloads that started paying or a trial", before: pct(cb * 100), after: pct(ca * 100), call: call,
                                    note: "\(Int(nb)) of \(Int(ub)) before, \(Int(na)) of \(Int(ua)) after"))
        }

        // New ratings: the count and average at the start and end of each week give the new ones' own average.
        let mine = snapshots.filter { $0.kind == "app.snapshot" }
        func at(_ day: Int) -> (r: Double, n: Double)? {
            let target = Int64(day) * 86_400_000
            guard let e = mine.min(by: { abs($0.occurredAt - target) < abs($1.occurredAt - target) }),
                  abs(e.occurredAt - target) <= 36 * 3_600_000,
                  let r = e.payload[path: "rating"]?.number, let n = e.payload[path: "ratings_count"]?.number else { return nil }
            return (r, n)
        }
        func added(_ a: (r: Double, n: Double)?, _ b: (r: Double, n: Double)?) -> (n: Int, avg: Double)? {
            guard let a, let b, b.n > a.n else { return nil }
            return (Int(b.n - a.n), min(5, max(1, (b.r * b.n - a.r * a.n) / (b.n - a.n))))
        }
        let start = at(live), end = at(live + 7)
        if let s = start {
            let newer = added(start, end), older = added(at(live - 7), start)
            let base = older?.avg ?? s.r
            let call: Call = (newer?.n ?? 0) < 2 ? .tooFew : newer!.avg < base - 0.5 ? .worse : newer!.avg > base + 0.3 ? .better : .same
            measures.append(Measure(name: "Stars from new ratings",
                                    before: older.map { stars($0.avg) } ?? stars(s.r),
                                    after: newer.map { stars($0.avg) } ?? "none", call: call,
                                    note: (newer.map { "\($0.n) new rating\($0.n == 1 ? "" : "s")" } ?? "no new ratings in the 7 days")
                                        + (older == nil && newer == nil ? " · before is the overall average" : "")))
        }

        let judged = measures.filter(\.judged)
        let verdict: Verdict
        if let bad = judged.first(where: { $0.call == .worse }) { verdict = .hurt(bad.name) }
        else if judged.contains(where: { $0.call == .better }) { verdict = .helped }
        else if judged.allSatisfy({ $0.call == .tooFew }) { verdict = .tooFew }
        else { verdict = .noChange }
        return ReleaseReport(app: app, version: version, liveDay: liveDay, readyDay: DayNumber.day(live + 7),
                             measures: measures, verdict: verdict)
    }

    static func pct(_ v: Double) -> String { v >= 99.95 ? "100%" : String(format: "%.1f%%", v) }
    static func one(_ v: Double) -> String { v >= 10 ? String(Int(v.rounded())) : String(format: "%.1f", v) }
    static func stars(_ v: Double) -> String { String(format: "%.1f★", v) }
}
