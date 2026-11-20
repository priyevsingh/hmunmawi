import Foundation
import HmunmawiPluginKit

struct Sentry: HmunmawiPlugin {
    static let hosts: Set<String> = ["sentry.io", "us.sentry.io", "de.sentry.io"]

    func poll(core: Core) async throws -> [PluginEvent] {
        let settings = await core.settings
        let org = settings[path: "org"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard org.wholeMatch(of: /[A-Za-z0-9_-]{1,64}/) != nil else {
            throw WireError("not_set_up", "Add your Sentry organization slug first (letters, digits and dashes)")
        }
        var host = settings[path: "region"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        host = host.replacingOccurrences(of: "https://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if host.isEmpty { host = "sentry.io" }
        guard Self.hosts.contains(host) else {
            throw WireError("not_set_up", "Data region must be empty, us.sentry.io or de.sentry.io")
        }
        let mapping = Self.parseMapping(settings[path: "apps"]?.string ?? "")
        let headers = ["Authorization": "Bearer {{secret:authToken}}"]
        let base = "https://\(host)/api/0/organizations/\(org)"

        // Project id -> (slug, name). The sessions endpoint groups by numeric project id.
        let projectsResponse = try await core.http(HTTPRequestSpec(url: "\(base)/projects/?per_page=100", headers: headers))
        let projectsJSON = try Self.checked(projectsResponse)
        var projects: [String: (slug: String, name: String)] = [:]
        for project in projectsJSON.array ?? [] {
            guard let id = project[path: "id"]?.string, let slug = project[path: "slug"]?.string else { continue }
            projects[id] = (slug, project[path: "name"]?.string ?? slug)
        }

        let query = "field=sum(session)&field=crash_free_rate(session)&groupBy=project&interval=1d&statsPeriod=8d&project=-1"
            .replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
        let sessionsResponse = try await core.http(HTTPRequestSpec(url: "\(base)/sessions/?\(query)", headers: headers))
        let sessions = try Self.checked(sessionsResponse)

        let iso = ISO8601DateFormatter()
        let intervals = (sessions[path: "intervals"]?.array ?? []).map { $0.string.flatMap(iso.date(from:)) }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        var events: [PluginEvent] = []
        for group in sessions[path: "groups"]?.array ?? [] {
            let idValue = group[path: "by.project"]
            let id = idValue?.number.map { String(Int64($0)) } ?? idValue?.string ?? ""
            guard let project = projects[id] else { continue }
            let app = mapping[project.slug] ?? project.name
            let counts = group[path: "series"].flatMap { $0[path: "sum(session)"]?.array } ?? []
            let rates = group[path: "series"].flatMap { $0[path: "crash_free_rate(session)"]?.array } ?? []
            for (index, start) in intervals.enumerated() {
                guard let start, index < counts.count, index < rates.count,
                      let total = counts[index].number, total > 0, let rate = rates[index].number else { continue }
                let startMs = Int64(start.timeIntervalSince1970 * 1000)
                let endOfDay = startMs + 86_400_000 - 1
                guard endOfDay < nowMs else { continue } // today is still filling up
                let day = Self.dayFormat.string(from: start)
                events.append(PluginEvent(
                    kind: "crash.daily", app: app,
                    payload: .object([
                        "day": .string(day),
                        "sessions": .number(total),
                        "crashed": .number((total * (1 - rate)).rounded()),
                        "crash_free_rate": .number(rate * 100),
                    ]),
                    occurredAt: endOfDay,
                    // Recent days are stored again on later checks (sessions arrive late); the app keeps the newest.
                    dedupeKey: "crash-\(project.slug)-\(day)" + (endOfDay > nowMs - 2 * 86_400_000 ? "-v\(Self.dayFormat.string(from: .now))" : "")))
            }
        }
        // Open problems (crashes, Sentry Uptime and Crons issues), for "Watch my services". Needs the token's
        // event:read scope; without it this part is skipped and the crash numbers above still arrive.
        if let issues = await Self.openIssues(core: core, base: base, headers: headers, projects: projects, mapping: mapping) {
            events.append(issues)
        }
        return events
    }

    /// Unresolved issues seen in the last 14 days, newest first (at most 50). nil when the token can't read them.
    static func openIssues(core: Core, base: String, headers: [String: String], projects: [String: (slug: String, name: String)],
                           mapping: [String: String]) async -> PluginEvent? {
        let url = "\(base)/issues/?query=is%3Aunresolved&statsPeriod=14d&sort=date&limit=50&project=-1"
        guard let r = try? await core.http(HTTPRequestSpec(url: url, headers: headers)) else { return nil }
        guard r.status == 200, let list = (try? JSONValue.parse(r.body ?? ""))?.array else {
            core.log(r.status == 403 ? "open issues skipped: the token needs the event:read scope" : "open issues skipped: status \(r.status)")
            return nil
        }
        let issues: [JSONValue] = list.compactMap { i in
            guard let id = i[path: "id"]?.string, let title = i[path: "title"]?.string else { return nil }
            let slug = i[path: "project.slug"]?.string ?? ""
            let name = mapping[slug] ?? i[path: "project.name"]?.string ?? slug
            var o: [String: JSONValue] = ["id": .string(id), "title": .string(String(title.prefix(200))), "project": .string(name),
                                          "category": .string(i[path: "issueCategory"]?.string ?? ""), "type": .string(i[path: "issueType"]?.string ?? ""),
                                          "level": .string(i[path: "level"]?.string ?? "error"),
                                          "count": .number(Double(i[path: "count"]?.string ?? "") ?? i[path: "count"]?.number ?? 0)]
            if let p = i[path: "permalink"]?.string, p.hasPrefix("https://") { o["permalink"] = .string(p) }
            if let s = i[path: "shortId"]?.string { o["short_id"] = .string(s) }
            if let f = i[path: "firstSeen"]?.string { o["first_seen"] = .string(f) }
            return .object(o)
        }
        _ = projects
        let ids = issues.compactMap { $0[path: "id"]?.string }.sorted().joined(separator: ",")
        let hash = String(ids.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }, radix: 36)
        let now = Date()
        return PluginEvent(kind: "issues.snapshot", app: "Sentry", payload: .object(["issues": .array(issues), "read_at": .number(now.timeIntervalSince1970 * 1000)]),
                           occurredAt: Int64(now.timeIntervalSince1970 * 1000), dedupeKey: "sentry-issues-\(hash)-\(Int(now.timeIntervalSince1970 / 3600))")
    }

    nonisolated(unsafe) static let dayFormat: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        format.timeZone = TimeZone(identifier: "UTC")
        return format
    }()

    /// "my-app=My App, other-app=Other App" -> ["my-app": "My App", "other-app": "Other App"]
    static func parseMapping(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in text.split(whereSeparator: { $0 == "," || $0 == "\n" }) {
            let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty { result[parts[0]] = parts[1] }
        }
        return result
    }

    static func checked(_ response: HTTPResponseSpec) throws -> JSONValue {
        let json = (try? JSONValue.parse(response.body ?? "")) ?? .null
        switch response.status {
        case 200: return json
        case 401: throw WireError("sentry_failed", "Sentry did not accept the auth token. Create a new one with org:read and project:read")
        case 403: throw WireError("sentry_failed", "Sentry: the auth token may not read this organization (needs org:read and project:read)")
        case 404: throw WireError("sentry_failed", "Sentry could not find that organization. Check the slug and the data region")
        default:
            throw WireError("sentry_failed", "Sentry: \(json[path: "detail"]?.string ?? "status \(response.status)")")
        }
    }
}

await PluginRuntime.run(Sentry())
