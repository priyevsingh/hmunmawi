import Foundation
import HmunmawiProtocol

/// Several Search Console sites become one set of totals for the Today page. One site is returned unchanged; with
/// more, impressions and clicks are summed and the average position is weighted by each site's impressions.
public enum SearchSites {
    public static func merge(_ payloads: [JSONValue]) -> JSONValue? {
        guard let first = payloads.first else { return nil }
        guard payloads.count > 1 else { return first }
        func sum(_ key: String) -> Double { payloads.reduce(0) { $0 + ($1[path: key]?.number ?? 0) } }
        let seen28 = sum("impressions_28d")
        let weighted28 = payloads.reduce(0.0) { $0 + ($1[path: "position_28d"]?.number ?? 0) * ($1[path: "impressions_28d"]?.number ?? 0) }
        var out: [String: JSONValue] = [
            "impressions_28d": .number(seen28), "clicks_28d": .number(sum("clicks_28d")),
            "impressions_7d": .number(sum("impressions_7d")), "clicks_7d": .number(sum("clicks_7d")),
        ]
        if seen28 > 0 { out["position_28d"] = .number(weighted28 / seen28) }
        return .object(out)
    }
}

/// Pages that rank but don't get clicked, judged against the site's own click rate (Search Console, 28 days).
public enum PageCTR {
    public struct Page: Sendable, Equatable {
        public let page: String
        public let impressions, clicks, position, ctr, siteCTR: Double
    }

    /// A page with at least `minImpressions`, an average position of 10 or better and a click rate under
    /// `factor` × the site's; the site needs 500+ impressions in the window to judge by. Strongest first, at most 5.
    public static func weak(_ payload: JSONValue, minImpressions: Double = 100, factor: Double = 0.5) -> [Page] {
        let siteImpressions = payload[path: "impressions_28d"]?.number ?? 0
        let siteClicks = payload[path: "clicks_28d"]?.number ?? 0
        guard siteImpressions >= 500, siteClicks > 0 else { return [] }
        let siteCTR = siteClicks / siteImpressions
        let pages: [Page] = (payload[path: "top_pages_28d"]?.array ?? []).compactMap { p in
            guard let page = p[path: "page"]?.string, let pos = p[path: "position"]?.number, pos > 0, pos <= 10 else { return nil }
            let imp = p[path: "impressions"]?.number ?? 0, clicks = p[path: "clicks"]?.number ?? 0
            guard imp >= minImpressions else { return nil }
            let ctr = clicks / imp
            guard ctr < siteCTR * factor else { return nil }
            return Page(page: page, impressions: imp, clicks: clicks, position: pos, ctr: ctr, siteCTR: siteCTR)
        }
        return Array(pages.sorted { $0.impressions > $1.impressions }.prefix(5))
    }

    /// 0.0123 -> "1.2%".
    public static func percent(_ rate: Double) -> String { String(format: "%.1f%%", rate * 100) }
}
