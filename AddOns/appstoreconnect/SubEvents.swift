import Foundation
import HmunmawiPluginKit

/// Why people start and stop paying, from Apple's daily Subscription Event report (Sales and Trends, version 1_3):
/// trials started and how they ended, new paid subscribers, renewals by paid period, people turning renewal off,
/// failed payments and the ones Apple recovered, and refunds. One read-only download per day; a published day never
/// changes, so each is read once (a mark per day) and the year before is filled in 14 days per check.
enum SubEvents {
    /// One app's counts for one report day. `paid` keys are "<plan>|<consecutive paid periods>" ("weekly|3": a
    /// weekly subscriber's third paid week started that day); renewal by plan is worked out from them in the app.
    struct Day: Sendable, Equatable {
        var name: String
        var trials = 0, trialPaid = 0, trialCancel = 0, trialFailed = 0   // trialFailed: the payment at the trial's end failed and was never made
        var trialLengths: [String: Int] = [:]       // trial length in days -> trials started
        var newPaid = 0, reactivated = 0, renewals = 0
        var cancels = 0, cancelsFirst = 0           // turned renewal off (voluntary); in their first paid period
        var billingTrouble = 0, recovered = 0, billingLost = 0, daysRecovered = 0
        var refunds = 0
        var paid: [String: Int] = [:]
        var newByCountry: [String: Int] = [:]
    }

    /// "7 Days" -> "weekly", "1 Month" -> "monthly", "1 Year" -> "yearly"; other lengths keep their own words.
    static func plan(_ duration: String) -> String {
        switch duration.lowercased().trimmingCharacters(in: .whitespaces) {
        case "7 days", "1 week": "weekly"
        case "1 month": "monthly"
        case "2 months": "every 2 months"
        case "3 months": "quarterly"
        case "6 months": "half-yearly"
        case "1 year", "12 months": "yearly"
        default: duration.lowercased().trimmingCharacters(in: .whitespaces)
        }
    }

    /// Days in an offer's length ("3 Days", "1 Week", "1 Month"); nil when unknown.
    static func days(_ duration: String) -> Int? {
        Subscriptions.months(duration).map { Int(($0 * 30.4375).rounded()) }
    }

    /// What one event means. Apple's names (developer.apple.com/help/app-store-connect/reference/reporting/
    /// subscription-events) follow a pattern, so families are matched by their words rather than listed one by one.
    enum Meaning: Equatable { case trialStart, trialPaid, newPaid, reactivated, renewal, recovered, cancel, billingLost, billingTrouble, refund, other }

    static func meaning(_ event: String, offerType: String, reason: String) -> Meaning {
        let e = event.lowercased().trimmingCharacters(in: .whitespaces)
        let trial = offerType.lowercased().contains("free trial")
        if e.hasPrefix("refund") { return .refund }
        if e.hasPrefix("canceled from billing") || ((e == "cancel" || e.hasPrefix("canceled")) && reason.lowercased().contains("billing")) { return .billingLost }
        if e == "cancel" || e.hasPrefix("canceled") { return .cancel }
        // "Billing Retry from Grace Period" is the same failed payment moving on, not a new one.
        if e == "billing retry from grace period" { return .other }
        if e.hasPrefix("billing retry from") || e.hasPrefix("grace period from") { return .billingTrouble }
        if e.contains("from billing retry") || e.contains("from grace period") { return .recovered }
        if e == "start introductory offer" || e.hasPrefix("reactivate to introductory") || (e.hasPrefix("reactivate with") && e.hasSuffix("to introductory offer")) {
            return trial ? .trialStart : .other
        }
        if e.hasPrefix("paid subscription from introductory") || ["crossgrade from introductory offer", "downgrade from introductory offer",
                                                                  "upgrade from introductory offer"].contains(e) { return .trialPaid }
        if e == "subscribe" { return offerType.trimmingCharacters(in: .whitespaces).isEmpty ? .newPaid : .other }
        if e.hasPrefix("paid subscription from") { return .newPaid }
        if e == "reactivate" || (e.hasPrefix("reactivate with") && !e.contains("offer")) { return .reactivated }
        if ["renew", "upgrade", "downgrade", "crossgrade"].contains(e) { return .renewal }
        return .other
    }

    static func summarize(_ rows: [[String: String]], names: [String: String]) -> [String: Day] {
        var out: [String: Day] = [:]
        for row in rows {
            guard let appID = row["App Apple ID"], !appID.isEmpty else { continue }
            var d = out[appID] ?? Day(name: names[appID] ?? Sales.shortName(row["App Name"] ?? appID))
            let q = max(0, Int(row["Quantity"] ?? "") ?? 0)
            guard q > 0 else { continue }
            let offer = row["Subscription Offer Type"] ?? ""
            let periods = Int(row["Consecutive Paid Periods"] ?? "") ?? 0
            let what = meaning(row["Event"] ?? "", offerType: offer, reason: row["Cancellation Reason"] ?? "")
            switch what {
            case .trialStart:
                d.trials += q
                if let n = days(row["Subscription Offer Duration"] ?? "") { d.trialLengths[String(n), default: 0] += q }
            case .trialPaid: d.trialPaid += q
            case .newPaid: d.newPaid += q
            case .reactivated: d.reactivated += q
            case .renewal: d.renewals += q
            case .recovered:
                d.recovered += q
                d.daysRecovered += q * (Int(row["Paid Service Days Recovered"] ?? "") ?? 0)
            case .cancel:
                // Cancelling during a free trial is a trial outcome, not a paying subscriber leaving.
                if offer.lowercased().contains("free trial") && periods == 0 { d.trialCancel += q }
                else { d.cancels += q; if periods <= 1 { d.cancelsFirst += q } }
            // A free trial whose first charge fails never had a paying subscriber: a trial outcome, not one lost.
            case .billingLost: if offer.lowercased().contains("free trial") && periods == 0 { d.trialFailed += q } else { d.billingLost += q }
            case .billingTrouble: if !(offer.lowercased().contains("free trial") && periods == 0) { d.billingTrouble += q }
            case .refund: d.refunds += q
            case .other: break
            }
            // A paid period started: the first one (new, from a trial, back again) or a later one (renewed, recovered).
            if [.newPaid, .trialPaid, .reactivated, .renewal, .recovered].contains(what), periods >= 1 {
                d.paid["\(plan(row["Standard Subscription Duration"] ?? ""))|\(periods)", default: 0] += q
            }
            if [.newPaid, .trialPaid, .reactivated].contains(what) {
                let c = (row["Country"] ?? "").trimmingCharacters(in: .whitespaces).uppercased()
                if c.count == 2 { d.newByCountry[c, default: 0] += q }
            }
            out[appID] = d
        }
        return out
    }

    static func payload(_ d: Day, day: String) -> JSONValue {
        func n(_ v: Int) -> JSONValue { .number(Double(v)) }
        func map(_ m: [String: Int]) -> JSONValue { .object(m.mapValues { .number(Double($0)) }) }
        return .object([
            "day": .string(day), "trials": n(d.trials), "trial_paid": n(d.trialPaid), "trial_cancel": n(d.trialCancel), "trial_failed": n(d.trialFailed),
            "trial_lengths": map(d.trialLengths), "new_paid": n(d.newPaid), "reactivated": n(d.reactivated),
            "renewals": n(d.renewals), "cancels": n(d.cancels), "cancels_first": n(d.cancelsFirst),
            "billing_trouble": n(d.billingTrouble), "recovered": n(d.recovered), "billing_lost": n(d.billingLost),
            "days_recovered": n(d.daysRecovered), "refunds": n(d.refunds), "paid": map(d.paid), "new_by_country": map(d.newByCountry),
        ])
    }

    /// Newest days first, then back up to a year (Apple keeps daily reports that long), 14 unread days a check.
    /// A day Apple answers "no sales" for is marked done once it's 4 days old (newer ones may just not be out yet).
    static func events(vendor: String, apps: [JSONValue], core: Core) async -> [PluginEvent] {
        var names: [String: String] = [:]
        for app in apps { if let id = app[path: "id"]?.string { names[id] = Sales.shortName(app[path: "attributes.name"]?.string ?? id) } }
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let f = DateFormatter()
        f.calendar = pacific; f.timeZone = pacific.timeZone; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let utc = DateFormatter()
        utc.locale = Locale(identifier: "en_US_POSIX"); utc.timeZone = TimeZone(identifier: "UTC"); utc.dateFormat = "yyyy-MM-dd"
        let now = Date.now
        var out: [PluginEvent] = []
        var fetched = 0
        // A recent day Apple hasn't published (or had nothing for) is asked again at most every 6 hours, not every check.
        let triesFile = State.file("subev-tries-\(vendor).json")
        var tries = (try? JSONDecoder().decode([String: Double].self, from: Data(contentsOf: triesFile))) ?? [:]
        for back in 1...365 where fetched < 14 && (back <= 3 || Budget.left) {
            guard let date = pacific.date(byAdding: .day, value: -back, to: now) else { continue }
            let day = f.string(from: date)
            let mark = State.file("hm-subev-\(vendor)-\(day)")
            if FileManager.default.fileExists(atPath: mark.path) { continue }
            if back < 4, let t = tries[day], now.timeIntervalSince1970 - t < 6 * 3600 { continue }
            fetched += 1
            do {
                guard let rows = try await Sales.report(vendor: vendor, day: day, core: core, type: "SUBSCRIPTION_EVENT", version: "1_3") else {
                    if back >= 4 { Pending.note(mark, "") } else { tries[day] = now.timeIntervalSince1970 }
                    continue
                }
                guard let start = utc.date(from: day) else { continue }
                let stamp = Int64(start.timeIntervalSince1970 * 1000) + 86_400_000 - 1
                for (id, d) in summarize(rows, names: names) {
                    out.append(PluginEvent(kind: "subscription.events", app: d.name, payload: payload(d, day: day),
                                           occurredAt: stamp, dedupeKey: "subev-\(id)-\(day)"))
                }
                Pending.note(mark, "")
            } catch {
                core.log("subscription events \(day): \(error)")
                break   // a key or network problem: try again next check rather than burn through the year
            }
        }
        let recent = Set((1...4).compactMap { pacific.date(byAdding: .day, value: -$0, to: now).map(f.string(from:)) })
        tries = tries.filter { recent.contains($0.key) }
        if let data = try? JSONEncoder().encode(tries) { StateFile.write(data, to: triesFile) }
        return out
    }
}
