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
        return events
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
