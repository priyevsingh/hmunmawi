import Foundation
import HmunmawiPluginKit

struct Bing: HmunmawiPlugin {
    func poll(core: Core) async throws -> [PluginEvent] {
        let settings = await core.settings
        var site = (settings[path: "siteURL"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !site.isEmpty, !site.contains("://") { site = "https://" + site }
        guard let host = URL(string: site)?.host(), !host.isEmpty else {
            throw WireError("not_set_up", "Add your site address exactly as Bing Webmaster Tools lists it, for example https://example.com/")
        }

        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = site.addingPercentEncoding(withAllowedCharacters: allowed) ?? site
        let response = try await core.http(HTTPRequestSpec(
            url: "https://ssl.bing.com/webmaster/api.svc/json/GetRankAndTrafficStats?siteUrl=\(encoded)&apikey={{secret:apiKey}}"))
        let json = (try? JSONValue.parse(response.body ?? "")) ?? .null
        guard response.status == 200 else {
            let detail = json[path: "Message"]?.string ?? "status \(response.status)"
            throw WireError("bing_failed", "Bing Webmaster Tools: \(detail). Check the API key and that the site address matches Bing exactly.")
        }

        // Rows look like {"Date": "/Date(1793232000000)/", "Clicks": 3, "Impressions": 57}, one per UTC day.
        var byDay: [Int64: (clicks: Double, impressions: Double)] = [:]
        for row in json[path: "d"]?.array ?? [] {
            guard let ms = Self.milliseconds(row[path: "Date"]?.string ?? "") else { continue }
            let dayStart = Int64((Double(ms) / 86_400_000).rounded(.down)) * 86_400_000
            let old = byDay[dayStart] ?? (0, 0)
            byDay[dayStart] = (old.clicks + (row[path: "Clicks"]?.number ?? 0),
                               old.impressions + (row[path: "Impressions"]?.number ?? 0))
        }
        guard let last = byDay.keys.max() else {
            throw WireError("bing_empty", "Bing has no search data for \(site) yet")
        }

        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        day.timeZone = TimeZone(identifier: "UTC")
        day.locale = Locale(identifier: "en_US_POSIX")
        // A full 28-day series ending on Bing's latest day; days Bing left out count as zero.
        let starts = (0..<28).map { last - Int64(27 - $0) * 86_400_000 }
        let clicks = starts.map { byDay[$0]?.clicks ?? 0 }
        let impressions = starts.map { byDay[$0]?.impressions ?? 0 }
        let lastText = day.string(from: Date(timeIntervalSince1970: Double(last) / 1000))

        let payload: JSONValue = .object([
            "clicks_28d": .number(clicks.reduce(0, +)),
            "impressions_28d": .number(impressions.reduce(0, +)),
            "clicks_7d": .number(clicks.suffix(7).reduce(0, +)),
            "impressions_7d": .number(impressions.suffix(7).reduce(0, +)),
            "data_through": .string(lastText),
            "days": .array(starts.map { .string(day.string(from: Date(timeIntervalSince1970: Double($0) / 1000))) }),
            "clicks": .array(clicks.map { .number($0) }),
            "impressions": .array(impressions.map { .number($0) }),
        ])

        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let hour = calendar.component(.hour, from: now)
        return [PluginEvent(kind: "growth.bing", app: host, payload: payload,
                            occurredAt: Int64(now.timeIntervalSince1970 * 1000),
                            dedupeKey: "growth.bing-\(host)-\(day.string(from: now))-\(hour)")]
    }

    /// "/Date(1793232000000)/" or "/Date(1793232000000-0700)/" -> 1793232000000.
    static func milliseconds(_ text: String) -> Int64? {
        guard let match = text.firstMatch(of: /\/Date\((-?\d+)/) else { return nil }
        return Int64(match.1)
    }
}

await PluginRuntime.run(Bing())
