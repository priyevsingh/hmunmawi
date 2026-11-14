import Foundation
import HmunmawiPluginKit

/// Your X numbers, free: read from the X file your Mac writes (via the app; this add-on has no network access
/// and no key). A number the file doesn't have is sent as null with a reason, never as 0.
struct XFromFile: HmunmawiPlugin {
    func poll(core: Core) async throws -> [PluginEvent] {
        let r = try await core.mac("xfile.read", params: .object([:]))
        let status = r[path: "status"]?.string ?? "missing"
        guard status != "missing" else {
            throw WireError("x_file_missing", r[path: "reason"]?.string ?? "Your Mac's X file isn't there")
        }
        let now = Date()
        let asOfDate = r[path: "as_of"]?.string.flatMap(Self.parseDate) ?? now
        let asOf = DateFormatter()
        asOf.locale = Locale(identifier: "en_GB")
        asOf.timeZone = .current
        asOf.dateFormat = "d MMM HH:mm"
        let asOfText = asOf.string(from: asOfDate)
        let fresh = status == "fresh"
        let stamp = Int64(asOfDate.timeIntervalSince1970)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)

        func value(_ v: JSONValue?) -> JSONValue {
            guard let n = v?.number else { return .null }
            return .string(Int64(n).formatted())
        }
        var items: [JSONValue] = []
        func add(_ label: String, _ key: String, reasonKey: String) {
            let v = value(r[path: key])
            items.append(.object(["label": .string(label), "value": v,
                                  "reason": v == .null ? (r[path: reasonKey] ?? .string("Not in the X file")) : .null]))
        }
        add("Posts", "posts_24h", reasonKey: "day_reason")
        add("Impressions", "impressions_24h", reasonKey: "day_reason")
        add("Engagements", "engagements_24h", reasonKey: "day_reason")
        add("Followers", "followers", reasonKey: "followers_reason")
        let posts: [JSONValue] = (r[path: "posts"]?.array ?? []).map { p in
            let created = p[path: "created_at"]?.string.flatMap(Self.parseDate)
            return .object(["kind": p[path: "kind"] ?? .string("post"), "text": p[path: "text"] ?? .string(""),
                            "url": p[path: "url"] ?? .string(""), "views": p[path: "views"] ?? .null,
                            "ago": .string(created.map { Self.ago(from: $0, to: now) } ?? "")])
        }
        let source = r[path: "source"]?.string == "digest" ? "your morning digest" : "your Mac's X file"
        var p: [String: JSONValue] = [:]
        p["as_of"] = .string(asOfText)
        p["fresh"] = .bool(fresh)
        p["reason"] = r[path: "reason"] ?? .null
        p["source"] = .string(source)
        p["items"] = .array(items)
        p["followers_total"] = r[path: "followers"] ?? .null
        p["posts"] = .array(posts)
        let pulse = PluginEvent(kind: "growth.x_pulse", app: "X", payload: .object(p),
                                occurredAt: nowMs, dedupeKey: "growth.x_pulse-file-\(stamp)")
        var g: [String: JSONValue] = [:]
        g["followers"] = r[path: "followers"] ?? .null
        g["followers_reason"] = r[path: "followers_reason"] ?? .null
        g["followers_1d"] = r[path: "followers_delta_1d"] ?? .null
        g["posts_7d"] = r[path: "posts_7d"] ?? .null
        g["impressions_7d"] = r[path: "impressions_7d"] ?? .null
        g["engagements_7d"] = r[path: "engagements_7d"] ?? .null
        g["data_from"] = .string(asOfText)
        g["followers_from"] = .string(source)
        let staleReason: JSONValue = r[path: "reason"] ?? .string("The X file is out of date")
        g["stale"] = fresh ? .null : staleReason
        let growth = PluginEvent(kind: "growth.x", app: "X", payload: .object(g),
                                 occurredAt: nowMs, dedupeKey: "growth.x-file-\(stamp)")
        // Your X at a glance, as its own event so another X feed (a script) never hides it.
        guard let glance = r[path: "glance"], glance != .null else { return [pulse, growth] }
        let glanceAt = Int64(r[path: "glance.updated"]?.string.flatMap(Self.parseDate)?.timeIntervalSince1970 ?? Double(stamp))
        let card = PluginEvent(kind: "growth.x_glance", app: "X", payload: glance,
                               occurredAt: nowMs, dedupeKey: "growth.x_glance-\(glanceAt)")
        return [pulse, growth, card]
    }

    static func parseDate(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: text)
    }

    static func ago(from date: Date, to now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        if minutes < 48 * 60 { return "\(minutes / 60)h ago" }
        return "\(minutes / 1440)d ago"
    }
}

await PluginRuntime.run(XFromFile())
