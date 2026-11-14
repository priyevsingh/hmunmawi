import Foundation
import HmunmawiPluginKit

struct PostHog: HmunmawiPlugin {
    /// Full days only (today is still filling up). The last two days are sent again on later checks, because
    /// phones report sessions late; the app keeps the newest count for each day.
    static let query = """
        SELECT toString(toDate(timestamp)) AS day, count(DISTINCT person_id) AS users
        FROM events
        WHERE timestamp >= today() - 8 AND timestamp < today()
        GROUP BY day ORDER BY day
        """

    func poll(core: Core) async throws -> [PluginEvent] {
        let settings = await core.settings
        let regionText = (settings[path: "region"]?.string ?? "us").trimmingCharacters(in: .whitespaces).lowercased()
        guard ["us", "eu"].contains(regionText) else { throw WireError("not_set_up", "PostHog region must be \"us\" or \"eu\"") }
        let region = regionText
        let project = (settings[path: "projectID"]?.string ?? "").trimmingCharacters(in: .whitespaces)
        guard project.wholeMatch(of: /[0-9]{1,12}/) != nil else {
            throw WireError("not_set_up", "Add your PostHog project ID (digits only) first")
        }
        let body = try JSONValue.object(["query": .object(["kind": .string("HogQLQuery"), "query": .string(Self.query)])])
            .canonicalText()
        let response = try await core.http(HTTPRequestSpec(
            method: "POST", url: "https://\(region).posthog.com/api/projects/\(project)/query/",
            headers: ["Authorization": "Bearer {{secret:apiKey}}", "Content-Type": "application/json"], body: body))
        let json = (try? JSONValue.parse(response.body ?? "")) ?? .null
        guard response.status == 200 else {
            throw WireError("posthog_failed", "PostHog: \(json[path: "detail"]?.string ?? "status \(response.status)")")
        }

        let dayFormat = DateFormatter()
        dayFormat.dateFormat = "yyyy-MM-dd"
        dayFormat.timeZone = TimeZone(identifier: "UTC")
        let app = settings[path: "appName"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "PostHog project \(project)"
        let fresh = Date.now.addingTimeInterval(-2 * 86_400), checked = dayFormat.string(from: .now)

        return (json[path: "results"]?.array ?? []).compactMap { row in
            guard let cells = row.array, cells.count == 2, let day = cells[0].string,
                  let users = cells[1].number, let start = dayFormat.date(from: day) else { return nil }
            let endOfDay = Int64(start.timeIntervalSince1970 * 1000) + 86_400_000 - 1
            return PluginEvent(kind: "analytics.daily_users", app: app,
                               payload: .object(["users": .number(users), "day": .string(day)]),
                               occurredAt: endOfDay,
                               // Project in the key (switching projects mustn't drop the new one's days); recent days
                               // get a per-check version so a late re-count is stored too.
                               dedupeKey: "dau-\(project)-\(day)" + (start > fresh ? "-v\(checked)" : ""))
        }
    }
}

await PluginRuntime.run(PostHog())
