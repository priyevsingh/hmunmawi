import Foundation
import HmunmawiPluginKit

/// RevenueCat's overview metrics (GET /v2/projects/{id}/metrics/overview), shown as one section on the Revenue page.
/// Response: { "object": "overview_metrics", "currency": "USD",
///             "metrics": [{ "object": "overview_metric", "id", "name", "unit", "period", "value", ... }] }
struct RevenueCat: HmunmawiPlugin {
    func poll(core: Core) async throws -> [PluginEvent] {
        let settings = await core.settings
        let project = settings[path: "projectID"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !project.isEmpty, project.count <= 255,
              let encoded = project.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "_-")))
        else { throw WireError("not_set_up", "Add your RevenueCat project ID first (RevenueCat → Project settings)") }

        let response = try await core.http(HTTPRequestSpec(
            url: "https://api.revenuecat.com/v2/projects/\(encoded)/metrics/overview?currency=USD",
            headers: ["Authorization": "Bearer {{secret:apiKey}}", "Accept": "application/json"]))
        let json = (try? JSONValue.parse(response.body ?? "")) ?? .null
        guard response.status == 200 else {
            let detail = json[path: "message"]?.string ?? "status \(response.status)"
            throw WireError("revenuecat_failed", "RevenueCat: \(detail)")
        }

        var values: [String: Double] = [:]
        for metric in json[path: "metrics"]?.array ?? [] {
            guard let id = metric[path: "id"]?.string, let value = metric[path: "value"]?.number else { continue }
            values[id] = value
        }
        guard !values.isEmpty else { throw WireError("revenuecat_failed", "RevenueCat sent no metrics") }

        // Only the metrics this project actually reports.
        let wanted: [(id: String, label: String, format: String?)] = [
            ("active_subscriptions", "Active subscriptions", nil),
            ("active_trials", "Trials", nil),
            ("mrr", "MRR", "usd"),
            ("revenue", "Revenue, 28 days", "usd"),
        ]
        let figures: [JSONValue] = wanted.compactMap { w in
            guard let v = values[w.id] else { return nil }
            var f: [String: JSONValue] = ["label": .string(w.label), "value": .number(v)]
            if let format = w.format { f["format"] = .string(format) }
            return .object(f)
        }

        var outcome: [String] = []
        if let subs = values["active_subscriptions"] { outcome.append("\(Int(subs)) active subscriptions") }
        if let mrr = values["mrr"] { outcome.append("MRR $\(mrr.formatted(.number.precision(.fractionLength(0))))") }

        var payload: [String: JSONValue] = [
            "id": .string("revenuecat"), "title": .string("RevenueCat"), "page": .string("revenue"),
            "symbol": .string("creditcard.fill"), "order": .number(20), "color": .string("money"),
            "figures": .array(figures),
        ]
        if !outcome.isEmpty { payload["outcome"] = .string(outcome.joined(separator: " · ")) }

        let app = settings[path: "appName"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "RevenueCat project \(project)"
        let now = Date.now
        let hour = now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).prefix(13)
        return [PluginEvent(kind: "section.snapshot", app: app, payload: .object(payload),
                            occurredAt: Int64(now.timeIntervalSince1970 * 1000),
                            dedupeKey: "revenuecat-\(project)-\(hour)")]
    }
}

await PluginRuntime.run(RevenueCat())
