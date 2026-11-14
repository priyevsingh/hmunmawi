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
