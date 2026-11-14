import Foundation
import HmunmawiPluginKit

/// Monthly recurring revenue from Apple's daily Subscription report (Sales and Trends, version 1_3): for each app,
/// active full-price subscriptions × what one subscription pays per period, scaled to a month. Apple's own MRR
/// (App Store Connect Analytics) can't be downloaded; this is the same idea from the report that can.
/// Net = your proceeds after Apple's cut; gross = customer prices. Free trials and intro offers aren't counted.
enum Subscriptions {
    /// One app on one report day.
    struct Day: Sendable {
        var name: String
        var activePaid = 0
        var mrrUSD = 0.0          // proceeds, per month
        var mrrGrossUSD = 0.0     // customer prices, per month
        var countries: [String: Country] = [:]   // where the paying subscribers are, and what each pays
    }
    struct Country: Sendable { var active = 0; var mrrUSD = 0.0 }

    /// Months in one billing period ("7 Days", "1 Month", "3 Months", "1 Year" …); nil when unknown.
    static func months(_ duration: String) -> Double? {
        let parts = duration.lowercased().split(separator: " ")
        guard parts.count == 2, let n = Double(parts[0]), n > 0 else { return nil }
        switch parts[1] {
        case "day", "days": return n / 30.4375
        case "week", "weeks": return n * 7 / 30.4375
        case "month", "months": return n
        case "year", "years": return n * 12
        default: return nil
        }
    }

    static func summarize(_ rows: [[String: String]], names: [String: String], rates: [String: Double]) -> [String: Day] {
        func usd(_ amount: Double, _ currency: String?) -> Double? {
            let c = (currency ?? "").trimmingCharacters(in: .whitespaces).uppercased()
            if c.isEmpty || c == "USD" { return amount }
            guard let r = rates[c], r > 0 else { return nil }
            return amount / r
        }
        var out: [String: Day] = [:]
        for row in rows {
            guard let appID = row["App Apple ID"], !appID.isEmpty else { continue }
            var d = out[appID] ?? Day(name: names[appID] ?? Sales.shortName(row["App Name"] ?? appID))
            let active = Int(row["Active Standard Price Subscriptions"] ?? "") ?? 0
            d.activePaid += active
            if active > 0, let m = months(row["Standard Subscription Duration"] ?? "") {
                if let p = Double(row["Developer Proceeds"] ?? ""), let v = usd(p, row["Proceeds Currency"]) {
                    d.mrrUSD += Double(active) * v / m
                    let c = (row["Country"] ?? "").trimmingCharacters(in: .whitespaces).uppercased()
                    if c.count == 2 { d.countries[c, default: Country()].active += active; d.countries[c, default: Country()].mrrUSD += Double(active) * v / m }
                }
                if let p = Double(row["Customer Price"] ?? ""), let v = usd(p, row["Customer Currency"]) { d.mrrGrossUSD += Double(active) * v / m }
            }
            out[appID] = d
        }
        return out
    }

    /// The newest published day (Apple is usually a day or two behind) plus a 60-day backfill, 12 days a round.
    static func events(vendor: String, apps: [JSONValue], core: Core) async -> [PluginEvent] {
        var names: [String: String] = [:]
        for app in apps { if let id = app[path: "id"]?.string { names[id] = Sales.shortName(app[path: "attributes.name"]?.string ?? id) } }
        guard let rates = await Sales.usdRates(core: core) else { core.log("mrr: exchange rates unavailable, skipped this round"); return [] }
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let f = DateFormatter()
        f.calendar = pacific; f.timeZone = pacific.timeZone; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let now = Date.now
        var days: [(String, [String: Day])] = []
        // Newest first: the latest day Apple has published (stop at the first one found).
        for back in 1...4 where Budget.left {
            guard let date = pacific.date(byAdding: .day, value: -back, to: now) else { continue }
            let day = f.string(from: date)
            do {
                if let rows = try await Sales.report(vendor: vendor, day: day, core: core, type: "SUBSCRIPTION", version: "1_3") {
                    let paid = rows.filter { (Int($0["Active Standard Price Subscriptions"] ?? "") ?? 0) > 0 }.count
                    if paid > 0 { core.log("mrr \(day): \(paid) paid subscription rows") }
                    days.append((day, summarize(rows, names: names, rates: rates))); break
                }
            } catch { core.log("mrr \(day): \(error)"); break }
        }
        // Backfill older days once each (a mark file per day), so projections have history from the start.
        var fetched = 0
        for back in 2...61 where fetched < 12 && Budget.left {
            guard let date = pacific.date(byAdding: .day, value: -back, to: now) else { continue }
            let day = f.string(from: date)
            if days.contains(where: { $0.0 == day }) { continue }
            let mark = State.file("hm-mrr-\(vendor)-\(day)")
            if FileManager.default.fileExists(atPath: mark.path) { continue }
            fetched += 1
            do {
                if let rows = try await Sales.report(vendor: vendor, day: day, core: core, type: "SUBSCRIPTION", version: "1_3") {
                    days.append((day, summarize(rows, names: names, rates: rates)))
                    Pending.note(mark, "")
                } else if back > 7 {
                    // Not published a week later: Apple has none for that day. A newer day not out yet is tried again.
                    Pending.note(mark, "")
                }
            } catch { core.log("mrr backfill \(day): \(error)") }
        }
        // Every app seen gets a row each day it has a report (0 when no one pays full price that day).
        let seen = Set(days.flatMap { $0.1.keys })
        let utc = DateFormatter()
        utc.locale = Locale(identifier: "en_US_POSIX"); utc.timeZone = TimeZone(identifier: "UTC"); utc.dateFormat = "yyyy-MM-dd"
        var out: [PluginEvent] = []
        for (day, byApp) in days {
            guard let start = utc.date(from: day) else { continue }
            let stamp = Int64(start.timeIntervalSince1970 * 1000) + 86_400_000 - 1
            for id in seen {
                let d = byApp[id] ?? Day(name: days.lazy.compactMap { $0.1[id]?.name }.first ?? names[id] ?? id)
                out.append(PluginEvent(kind: "subscription.mrr", app: d.name, payload: .object([
                    "day": .string(day), "active_paid": .number(Double(d.activePaid)),
                    "mrr_usd": .number(Sales.round2(d.mrrUSD)), "mrr_gross_usd": .number(Sales.round2(d.mrrGrossUSD)),
                    "countries": .object(d.countries.mapValues { .object(["active": .number(Double($0.active)), "mrr_usd": .number(Sales.round2($0.mrrUSD))]) }),
                ]), occurredAt: stamp, dedupeKey: "mrr-\(id)-\(day)"))
            }
        }
        return out
    }
}
