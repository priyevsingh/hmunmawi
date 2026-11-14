import Foundation
import HmunmawiCore
import HmunmawiProtocol

/// Reads fatal freezes (Sentry "Fatal App Hang" reports) for the Stability card, every 3 hours, read-only, with the
/// Sentry connection's own settings and saved token. Tracking only: it writes no events, sends no alerts and never
/// changes a health colour (owner, 10 Nov 2026). The Sentry add-on itself is unchanged, so its approval stays valid.
@MainActor @Observable
final class FreezeWatch {
    static let shared = FreezeWatch()

    /// Last result; nil until Sentry has been read once (the card then says nothing about freezes yet).
    private(set) var summary: FreezeSummary?
    private var verdicts: [String: FreezeVerdict] = [:]
    private var running = false
    private static let every: TimeInterval = 3 * 3600
    nonisolated private static let hosts: Set<String> = ["sentry.io", "us.sentry.io", "de.sentry.io"]
    nonisolated private static let maxIssueReads = 50

    private struct Cache: Codable { var summary: FreezeSummary?; var verdicts: [String: FreezeVerdict] }
    private var cacheURL: URL?

    func load(from directory: URL) {
        guard cacheURL == nil else { return }
        let url = directory.appending(path: "freezes.json")
        cacheURL = url
        guard summary == nil, let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder.freezes.decode(Cache.self, from: data) else { return }
        summary = cache.summary; verdicts = cache.verdicts
    }

    /// Reads Sentry when the last read is older than 3 hours (or failed). `token` is the Sentry connection's own key.
    func refreshIfDue(enabled: Bool, settings: JSONValue, token: @escaping @Sendable () throws -> String?) {
        guard enabled, !running else { return }
        if let s = summary, s.unavailable == nil, Date.now.timeIntervalSince(s.checkedAt) < Self.every { return }
        if let s = summary, s.unavailable != nil, Date.now.timeIntervalSince(s.checkedAt) < 1800 { return }
        running = true
        let known = verdicts
        Task {
            let (result, newVerdicts) = await Self.read(settings: settings, token: token, known: known)
            self.summary = result
            self.verdicts = newVerdicts
            self.running = false
            self.save()
        }
    }

    private func save() {
        guard let cacheURL, let data = try? JSONEncoder.freezes.encode(Cache(summary: summary, verdicts: verdicts)) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    // MARK: Reading Sentry (read-only GETs)

    nonisolated private struct Failure: Error { let reason: String }

    nonisolated private static func read(settings: JSONValue, token: @Sendable () throws -> String?,
                                         known: [String: FreezeVerdict]) async -> (FreezeSummary, [String: FreezeVerdict]) {
        do {
            let org = settings[path: "org"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard org.wholeMatch(of: /[A-Za-z0-9_-]{1,64}/) != nil else { throw Failure(reason: "The Sentry connection has no organization yet.") }
            var host = settings[path: "region"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            host = host.replacingOccurrences(of: "https://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if host.isEmpty { host = "sentry.io" }
            guard hosts.contains(host) else { throw Failure(reason: "The Sentry data region isn't one Hmunmawi knows.") }
            guard let key = try token(), !key.isEmpty else { throw Failure(reason: "The Sentry connection has no saved token.") }
            let base = "https://\(host)/api/0/organizations/\(org)"
            let mapping = parseMapping(settings[path: "apps"]?.string ?? "")

            var names: [String: String] = [:]
            for p in try await get("\(base)/projects/?per_page=100", key).array ?? [] {
                if let slug = p[path: "slug"]?.string { names[slug] = mapping[slug] ?? p[path: "name"]?.string ?? slug }
            }
            func app(_ slug: String) -> String { names[slug] ?? mapping[slug] ?? slug }

            let query = "level:fatal title:\"*App Hang*\""
            func discover(_ fields: [String]) async throws -> [JSONValue] {
                var c = URLComponents(string: "\(base)/events/")!
                c.queryItems = [URLQueryItem(name: "dataset", value: "errors"), URLQueryItem(name: "query", value: query),
                                URLQueryItem(name: "statsPeriod", value: "7d"), URLQueryItem(name: "per_page", value: "100"),
                                URLQueryItem(name: "sort", value: "-count()")] + fields.map { URLQueryItem(name: "field", value: $0) }
                return try await get(c.url!.absoluteString, key)[path: "data"]?.array ?? []
            }
            let byRelease = try await discover(["project", "release", "count()", "count_unique(user)"])
            let byIssue = try await discover(["project", "issue.id", "count()"])

            let releases = byRelease.compactMap { r -> FreezeReleaseCount? in
                guard let slug = r[path: "project"]?.string, let n = r[path: "count()"]?.number else { return nil }
                return FreezeReleaseCount(app: app(slug), release: r[path: "release"]?.string ?? "unknown release", events: Int(n),
                                          users: r[path: "count_unique(user)"]?.number.map { Int($0) })
            }
            var perIssue: [String: (app: String, events: Int)] = [:]
            for r in byIssue {
                guard let slug = r[path: "project"]?.string, let n = r[path: "count()"]?.number else { continue }
                guard let id = FreezeClassifier.issueID(r) else { continue }
                perIssue[id, default: (app(slug), 0)].events += Int(n)
            }
            var verdicts = known.filter { perIssue[$0.key] != nil && $0.value != .unchecked }
            // Sorted once per issue and remembered, so each read sorts up to `maxIssueReads` new issues, biggest first.
            for id in perIssue.sorted(by: { $0.value.events > $1.value.events }).map(\.key).filter({ verdicts[$0] == nil }).prefix(maxIssueReads) {
                guard id.allSatisfy(\.isNumber) else { continue }
                let title = (try? await get("\(base)/issues/\(id)/", key))?[path: "title"]?.string ?? ""
                let event = try? await get("\(base)/issues/\(id)/events/latest/", key)
                verdicts[id] = FreezeClassifier.verdict(issueTitle: title, latestEvent: event)
            }
            let issues = perIssue.map { FreezeIssueCount(app: $0.value.app, issueID: $0.key, events: $0.value.events, verdict: verdicts[$0.key] ?? .unchecked) }
                .sorted { $0.events > $1.events }
            return (FreezeSummary(checkedAt: .now, releases: releases, issues: issues), verdicts)
        } catch let f as Failure {
            return (.failed(f.reason), known)
        } catch {
            return (.failed("Sentry couldn't be reached (\(error.localizedDescription))."), known)
        }
    }

    nonisolated private static func get(_ url: String, _ key: String) async throws -> JSONValue {
        guard let u = URL(string: url), let h = u.host, hosts.contains(h), u.scheme == "https" else { throw Failure(reason: "Refused a Sentry address.") }
        var request = URLRequest(url: u, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: return (try? JSONValue.parse(String(decoding: data, as: UTF8.self))) ?? .null
        case 401: throw Failure(reason: "Sentry did not accept the saved token.")
        case 403: throw Failure(reason: "The Sentry token may not read error events (it needs the event:read scope).")
        case 429: throw Failure(reason: "Sentry asked to slow down; trying again later.")
        default: throw Failure(reason: "Sentry answered \(status).")
        }
    }

    nonisolated static func parseMapping(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in text.split(whereSeparator: { $0 == "," || $0 == "\n" }) {
            let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty { result[parts[0]] = parts[1] }
        }
        return result
    }
}

private extension JSONEncoder {
    static var freezes: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}
private extension JSONDecoder {
    static var freezes: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
