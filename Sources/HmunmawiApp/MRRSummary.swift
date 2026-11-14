import Foundation
import HmunmawiCore

/// MRR per app and in total, built from the daily `subscription.mrr` rows (App Store Connect's Subscription report).
struct MRRSummary: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        let points: [MRRModel.Point]
        let projection: MRRModel.Projection?
        var latest: MRRModel.Point? { points.last }
    }
    let apps: [String: Entry]
    let total: Entry

    init?(_ rows: [StoredEvent]) {
        var byApp: [String: [(day: String, mrr: Double, gross: Double, active: Int)]] = [:]
        for e in rows {
            guard let app = e.app, let day = e.payload[path: "day"]?.string else { continue }
            byApp[app, default: []].append((day, e.payload[path: "mrr_usd"]?.number ?? 0,
                                            e.payload[path: "mrr_gross_usd"]?.number ?? 0,
                                            Int(e.payload[path: "active_paid"]?.number ?? 0)))
        }
        guard !byApp.isEmpty else { return nil }
        // Every day the account reported: an app without a row that day had no subscriptions (0).
        let allDays = Set(byApp.values.flatMap { $0.map(\.day) }).sorted()
        var apps: [String: Entry] = [:]
        for (app, list) in byApp {
            let pts = MRRModel.filled(MRRModel.series(list), days: allDays)
            apps[app] = Entry(points: pts, projection: MRRModel.project(pts))
        }
        let all = MRRModel.total(apps.values.map(\.points))
        self.apps = apps
        self.total = Entry(points: all, projection: MRRModel.project(all))
    }

    /// "Rough" wording when subscriber numbers are small.
    @MainActor static func rangeText(_ r: ClosedRange<Double>) -> String {
        let m = Money.shared
        // Without exchange rates (first launch offline) dollars stay dollars, never relabelled as the target currency.
        let lo = amount(r.lowerBound), hi = amount(r.upperBound)
        return lo == hi ? lo : "\(lo)–\(hi)"
    }
    /// " MRR ₹X a month, in 90 days ₹A–₹B (rough)." for the Money card; empty before the first report.
    @MainActor static func footer(_ s: MRRSummary?) -> String {
        guard let s, let latest = s.total.latest else { return "" }
        var t = " MRR \(amount(latest.mrr)) a month"
        if let p = s.total.projection { t += ", in 90 days \(rangeText(p.in90))" + (p.rough ? " (rough)" : "") }
        return t + "."
    }

    /// "in 90 days ₹A–₹B · rough" or why there's no projection yet.
    @MainActor static func projectionLine(_ e: Entry?) -> String {
        guard let e, e.latest != nil else { return "" }
        guard let p = e.projection else {
            return "projection after \(MRRModel.minimumDays) days of reports (\(e.points.count) so far)"
        }
        return "in 90 days \(rangeText(p.in90))" + (p.rough ? " · rough, few subscribers" : "")
    }

    @MainActor static func amount(_ usd: Double) -> String {
        let m = Money.shared
        return m.format(m.convert(usd, from: "USD") ?? usd, from: m.convert(usd, from: "USD") == nil ? "USD" : m.target, decimals: 0)
    }
}
