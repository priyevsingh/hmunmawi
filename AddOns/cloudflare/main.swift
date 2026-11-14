import Foundation
import HmunmawiPluginKit

/// Zone analytics (visits that pass through Cloudflare's proxy), full UTC days only.
struct CloudflareVisitors: HmunmawiPlugin {
    static let query = """
        query($zone: String!, $since: Date!, $until: Date!) { viewer { zones(filter: {zoneTag: $zone}) {
          httpRequests1dGroups(limit: 40, filter: {date_geq: $since, date_lt: $until}, orderBy: [date_ASC]) {
            dimensions { date } sum { pageViews requests } uniq { uniques } } } } }
        """

    func poll(core: Core) async throws -> [PluginEvent] {
        let settings = await core.settings
        let account = Self.text(settings, "accountID")
        var zone = Self.text(settings, "zoneID")
        var siteName = Self.text(settings, "siteName")
        let headers = ["Authorization": "Bearer {{secret:apiToken}}", "Content-Type": "application/json"]
        let idPattern = /[0-9a-fA-F]{32}/

        if zone.isEmpty {
            guard account.wholeMatch(of: idPattern) != nil else {
                throw WireError("not_set_up", "Add your Cloudflare Account ID (32 letters and digits) or a Zone ID first")
            }
            let response = try await core.http(HTTPRequestSpec(
                url: "https://api.cloudflare.com/client/v4/zones?account.id=\(account)&per_page=5", headers: headers))
            let json = try Self.checked(response)
            guard let first = json[path: "result"]?.array?.first, let id = first[path: "id"]?.string else {
                throw WireError("cloudflare_failed", "Cloudflare: no website found in this account. Add the Zone ID")
            }
            zone = id
            if siteName.isEmpty { siteName = first[path: "name"]?.string ?? "" }
        }
        guard zone.wholeMatch(of: idPattern) != nil else {
            throw WireError("not_set_up", "The Zone ID should be 32 letters and digits")
        }
        if siteName.isEmpty { siteName = "Website" }

        let dayFormat = DateFormatter()
        dayFormat.locale = Locale(identifier: "en_US_POSIX")
        dayFormat.timeZone = TimeZone(identifier: "UTC")
        dayFormat.dateFormat = "yyyy-MM-dd"
        let now = Date()
        let today = dayFormat.string(from: now)
        let since28 = dayFormat.string(from: now.addingTimeInterval(-28 * 86_400))
        let since7 = dayFormat.string(from: now.addingTimeInterval(-7 * 86_400))

        let body = try JSONValue.object([
            "query": .string(Self.query),
            "variables": .object(["zone": .string(zone), "since": .string(since28), "until": .string(today)]),
        ]).canonicalText()
        let response = try await core.http(HTTPRequestSpec(
            method: "POST", url: "https://api.cloudflare.com/client/v4/graphql", headers: headers, body: body))
        let json = try Self.checked(response)
        guard let zones = json[path: "data.viewer.zones"]?.array, let first = zones.first else {
            throw WireError("cloudflare_failed", "Cloudflare: the token cannot read analytics for this website")
        }

        var days: [JSONValue] = [], values: [JSONValue] = []
        var visitors7 = 0.0, pageViews7 = 0.0, visitors28 = 0.0
        for row in first[path: "httpRequests1dGroups"]?.array ?? [] {
            guard let day = row[path: "dimensions.date"]?.string else { continue }
            let uniques = row[path: "uniq.uniques"]?.number ?? 0
            let pageViews = row[path: "sum.pageViews"]?.number ?? 0
            visitors28 += uniques
            if day >= since7 {
                visitors7 += uniques
                pageViews7 += pageViews
            }
            days.append(.string(day))
            values.append(.number(uniques))
        }

        let payload = JSONValue.object([
            "id": .string("cloudflare-visitors"),
            "title": .string("Website traffic (Cloudflare)"),
            "page": .string("growth"),
            "symbol": .string("globe"),
            "order": .number(12),
            "color": .string("web"),
            "outcome": .string("\(Int64(visitors7).formatted()) unique addresses in 7 days, bots included"),
            "figures": .array([
                .object(["label": .string("Daily unique addresses, added up (7 days)"), "value": .number(visitors7)]),
                .object(["label": .string("Page views, 7 days"), "value": .number(pageViews7)]),
                .object(["label": .string("Daily unique addresses, added up (28 days)"), "value": .number(visitors28)]),
            ]),
            "series": .array([.object([
                "label": .string("Unique addresses each day"), "days": .array(days), "values": .array(values),
            ])]),
        ])
        var out = [PluginEvent(kind: "section.snapshot", app: siteName, payload: payload,
                               occurredAt: Int64(now.timeIntervalSince1970 * 1000),
                               dedupeKey: "section.snapshot-cloudflare-visitors-\(zone.lowercased())-\(today)-\(Self.utcHour())")]   // UTC hour with the UTC date
        // When the token itself expires (once a day; a token without an end date says so). Never fails the poll.
        if let login = await Self.tokenExpiry(core: core, account: account, headers: headers, today: today) { out.append(login) }
        return out
    }

    /// Cloudflare's own answer to "is this token valid, and until when?". A user token is checked at
    /// /user/tokens/verify, an account-owned one at /accounts/<id>/tokens/verify.
    static func tokenExpiry(core: Core, account: String, headers: [String: String], today: String) async -> PluginEvent? {
        var urls = ["https://api.cloudflare.com/client/v4/user/tokens/verify"]
        if account.wholeMatch(of: /[0-9a-fA-F]{32}/) != nil { urls.append("https://api.cloudflare.com/client/v4/accounts/\(account)/tokens/verify") }
        for url in urls {
            guard let r = try? await core.http(HTTPRequestSpec(url: url, headers: headers)), r.status == 200,
                  let json = try? JSONValue.parse(r.body ?? ""), json[path: "success"] == .bool(true) else { continue }
            let expires = json[path: "result.expires_on"]?.string
            return PluginEvent(kind: "login.cloudflare.snapshot", app: nil,
                               payload: .object(["name": .string("Cloudflare API token"), "connection": .string("cloudflare"),
                                                 "expires": expires.map(JSONValue.string) ?? .null,
                                                 "status": .string(json[path: "result.status"]?.string ?? "active")]),
                               occurredAt: Int64(Date.now.timeIntervalSince1970 * 1000), dedupeKey: "login-cloudflare-\(today)")
        }
        return nil
    }

    static func text(_ settings: JSONValue, _ key: String) -> String {
        settings[path: key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func checked(_ response: HTTPResponseSpec) throws -> JSONValue {
        let json = (try? JSONValue.parse(response.body ?? "")) ?? .null
        let message = json[path: "errors"]?.array?.first?[path: "message"]?.string
        switch response.status {
        case 200:
            if let message { throw WireError("cloudflare_failed", "Cloudflare: \(message)") }
            return json
        case 401, 403:
            throw WireError("cloudflare_failed", "Cloudflare did not accept the API token. It needs Analytics Read for this website")
        default:
            throw WireError("cloudflare_failed", "Cloudflare: \(message ?? "status \(response.status)")")
        }
    }
}

extension CloudflareVisitors {
    /// The hour in UTC, matching the UTC date in the same key (a local hour repeated within one UTC day).
    static func utcHour() -> Int {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        return c.component(.hour, from: .now)
    }
}

await PluginRuntime.run(CloudflareVisitors())
