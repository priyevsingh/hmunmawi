import Foundation
import HmunmawiPluginKit

struct SearchConsole: HmunmawiPlugin {
    static let scope = "https://www.googleapis.com/auth/webmasters.readonly"
    /// Search Console data is about 2-3 days behind, so every window ends 3 days ago.
    static let lagDays = 3

    func poll(core: Core) async throws -> [PluginEvent] {
        let settings = await core.settings
        let sites = (settings[path: "sites"]?.string ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !sites.isEmpty else {
            throw WireError("not_set_up", "Add at least one Search Console property, for example sc-domain:example.com")
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        day.timeZone = calendar.timeZone
        day.locale = Locale(identifier: "en_US_POSIX")
        let now = Date()
        let end = calendar.date(byAdding: .day, value: -Self.lagDays, to: now)!
        let start28 = day.string(from: calendar.date(byAdding: .day, value: -27, to: end)!)
        let start7 = day.string(from: calendar.date(byAdding: .day, value: -6, to: end)!)
        let endText = day.string(from: end)
        let hour = calendar.component(.hour, from: now)
        let occurredAt = Int64(now.timeIntervalSince1970 * 1000)

        var events: [PluginEvent] = []
        var failures: [WireError] = []
        for site in sites {
            do {
                let totals28 = try await query(core, site, ["startDate": .string(start28), "endDate": .string(endText)])
                let totals7 = try await query(core, site, ["startDate": .string(start7), "endDate": .string(endText)])
                let queries = try await query(core, site, ["startDate": .string(start28), "endDate": .string(endText),
                                                           "dimensions": .array([.string("query")]), "rowLimit": .number(10)])
                let pages = try await query(core, site, ["startDate": .string(start28), "endDate": .string(endText),
                                                         "dimensions": .array([.string("page")]), "rowLimit": .number(50)])
                let t28 = totals28.first ?? .object([:])
                let t7 = totals7.first ?? .object([:])
                let position = ((t28[path: "position"]?.number ?? 0) * 10).rounded() / 10
                let payload: JSONValue = .object([
                    "clicks_28d": .number(t28[path: "clicks"]?.number ?? 0),
                    "impressions_28d": .number(t28[path: "impressions"]?.number ?? 0),
                    "position_28d": .number(position),
                    "clicks_7d": .number(t7[path: "clicks"]?.number ?? 0),
                    "impressions_7d": .number(t7[path: "impressions"]?.number ?? 0),
                    "data_through": .string(endText),
                    "top_queries_28d": .array(queries.compactMap { row in
                        guard let key = row[path: "keys"]?.array?.first?.string else { return nil }
                        return .object(["query": .string(key), "clicks": .number(row[path: "clicks"]?.number ?? 0),
                                        "impressions": .number(row[path: "impressions"]?.number ?? 0)])
                    }),
                    "top_pages_28d": .array(pages.compactMap { row in
                        guard let key = row[path: "keys"]?.array?.first?.string else { return nil }
                        return .object(["page": .string(Self.pathOnly(key)), "clicks": .number(row[path: "clicks"]?.number ?? 0),
                                        "impressions": .number(row[path: "impressions"]?.number ?? 0),
                                        "position": .number(((row[path: "position"]?.number ?? 0) * 10).rounded() / 10)])
                    }),
                ])
                let name = Self.displayName(site)
                events.append(PluginEvent(kind: "growth.search", app: name, payload: payload, occurredAt: occurredAt,
                                          // Keyed by the property itself: "sc-domain:x" and "https://x/" share a display
                                          // name, and the second would otherwise be dropped as a duplicate.
                                          dedupeKey: "growth.search-\(site)-\(day.string(from: now))-\(hour)"))
            } catch let error as WireError {
                // One unreachable property shouldn't hide the others; fail only when none worked.
                core.log("\(site): \(error.message)")
                failures.append(error)
            }
        }
        if events.isEmpty, let first = failures.first { throw first }
        return events
    }

    private func query(_ core: Core, _ site: String, _ body: [String: JSONValue]) async throws -> [JSONValue] {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = site.addingPercentEncoding(withAllowedCharacters: allowed) ?? site
        let response = try await core.http(HTTPRequestSpec(
            method: "POST", url: "https://www.googleapis.com/webmasters/v3/sites/\(encoded)/searchAnalytics/query",
            headers: ["Authorization": "Bearer {{google-token:\(Self.scope)}}", "Content-Type": "application/json"],
            body: try JSONValue.object(body).canonicalText()))
        let json = (try? JSONValue.parse(response.body ?? "")) ?? .null
        guard response.status == 200 else {
            if response.status == 403 {
                throw WireError("searchconsole_forbidden", "Search Console won't share \(site) with this service account. "
                                + "Add the account's email as a user of that property in Search Console.")
            }
            let detail = json[path: "error.message"]?.string ?? "status \(response.status)"
            throw WireError("searchconsole_failed", "Search Console (\(site)): \(detail)")
        }
        return json[path: "rows"]?.array ?? []
    }

    /// "sc-domain:example.com" or "https://www.example.com/" -> "example.com" / "www.example.com".
    static func displayName(_ site: String) -> String {
        var name = site
        for prefix in ["sc-domain:", "https://", "http://"] where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
        }
        while name.hasSuffix("/") { name.removeLast() }
        return name
    }

    /// "https://www.example.com/compare/x/?a=1" -> "/compare/x/?a=1".
    static func pathOnly(_ page: String) -> String {
        guard let parts = URLComponents(string: page), parts.host != nil else { return page }
        var path = parts.path.isEmpty ? "/" : parts.path
        if let query = parts.query, !query.isEmpty { path += "?" + query }
        return path
    }
}

await PluginRuntime.run(SearchConsole())
