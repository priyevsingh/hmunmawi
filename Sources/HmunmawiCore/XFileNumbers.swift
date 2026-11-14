import Foundation

/// Your X numbers, read for free from files on this Mac: the X file a Mac job writes every 6 hours
/// (`x/native.json`, a read of your own signed-in X page) or, when that's missing, the X block of the
/// morning digest. Nothing here talks to X or needs a key. A number the file doesn't have stays nil with a
/// reason: it is never shown as 0.
public enum XFileNumbers {
    /// The Mac job writes the X file at 03:50, 09:50, 15:50 and 21:50: one run plus two hours of slack.
    public static let freshFor: TimeInterval = 8 * 3600
    /// The morning digest is written once a day.
    public static let digestFreshFor: TimeInterval = 26 * 3600
    static let maxBytes = 5_000_000

    public enum Status: String, Sendable { case fresh, stale, missing }

    /// Where the digest sits next to the X file: `<hub>/x/native.json` → `<hub>/out/digest/morning_digest.json`.
    public static func digestPath(nextTo file: String) -> String? {
        let url = URL(fileURLWithPath: file)
        guard url.lastPathComponent == "native.json", url.deletingLastPathComponent().lastPathComponent == "x" else { return nil }
        return url.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "out/digest/morning_digest.json").path
    }

    static func date(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s)
    }

    static func int(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double, d.isFinite { return Int(d) }
        return nil
    }

    static func ageText(_ seconds: TimeInterval) -> String {
        let h = Int(seconds / 3600)
        if h < 1 { return "\(max(1, Int(seconds / 60))) min" }
        if h < 48 { return "\(h) h" }
        return "\(h / 24) days"
    }

    static func read(_ path: String) -> (data: Data, modified: Date)? {
        guard !path.isEmpty,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int, size > 0, size <= maxBytes,
              let modified = attrs[.modificationDate] as? Date,
              let data = FileManager.default.contents(atPath: path) else { return nil }
        return (data, modified)
    }

    /// Reads the X file (preferred) or the digest (fallback) and returns what the X connection reports.
    /// `glanceFiles`: other X glances on this Mac, newest wins: a file your bot writes (the glance's fields at the top)
    /// or the Safari read's own X file (a `glance` block inside). So a Safari read and a bot can both feed it.
    public static func load(file: String, digest: String?, glanceFile: String? = nil, glanceFiles: [String] = [], now: Date = .now) -> JSONValue {
        let result = loadNumbers(file: file, digest: digest, now: now)
        guard case .object(var out) = result, out["status"] != .string(Status.missing.rawValue) else { return result }
        var bestAt = out["glance"]?[path: "updated"]?.string.flatMap { date($0) }
        for path in ([glanceFile].compactMap { $0 } + glanceFiles) where path != file {
            guard let (data, modified) = read(path),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let raw = (root["glance"] as? [String: Any]) ?? root
            guard case .object(var g) = glance(raw) else { continue }
            let at = date(raw["updated"]) ?? modified
            if g["updated"] == nil || g["updated"] == .null { g["updated"] = .string(ISO8601DateFormatter().string(from: at)) }
            if bestAt == nil || at > bestAt! { out["glance"] = .object(g); bestAt = at }
        }
        return .object(out)
    }

    static func loadNumbers(file: String, digest: String?, now: Date) -> JSONValue {
        if let (data, modified) = read(file),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return fromNative(root, modified: modified, path: file, now: now)
        }
        if let digest, let (data, modified) = read(digest),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let x = root["x"] as? [String: Any] {
            return fromDigest(root, x: x, modified: modified, path: digest, now: now,
                              nativeProblem: file.isEmpty ? "No X file is set" : "The X file is missing or unreadable")
        }
        let reason = file.isEmpty
            ? "No X file is set. Point Hmunmawi at the X file your Mac writes (Settings → General → X)."
            : "Your Mac's X file isn't there (\((file as NSString).abbreviatingWithTildeInPath)), and no digest with X numbers was found."
        return .object(["status": .string(Status.missing.rawValue), "reason": .string(reason),
                        "path": .string(file)])
    }

    static func status(age: TimeInterval, window: TimeInterval, what: String) -> (Status, String?) {
        if age <= window { return (.fresh, nil) }
        return (.stale, "\(what) was last updated \(ageText(age)) ago; it is normally refreshed every \(window <= freshFor ? "6 hours" : "day"). The numbers shown are from then.")
    }

    static func num(_ v: Int?) -> JSONValue { v.map { .number(Double($0)) } ?? .null }

    static func fromNative(_ d: [String: Any], modified: Date, path: String, now: Date) -> JSONValue {
        let asOf = date(d["generated"]) ?? modified
        let (st, reason) = status(age: now.timeIntervalSince(asOf), window: freshFor, what: "Your Mac's X file")
        let account = d["account"] as? [String: Any] ?? [:]
        let followers = int(account["followers"])
        let posts = d["posts"] as? [[String: Any]]
        var out: [String: JSONValue] = [
            "status": .string(st.rawValue), "reason": reason.map(JSONValue.string) ?? .null,
            "source": .string("x_file"), "path": .string(path),
            "as_of": .string(ISO8601DateFormatter().string(from: asOf)),
            "username": (account["username"] as? String).map(JSONValue.string) ?? .null,
            "followers": num(followers),
            "followers_reason": followers == nil ? .string("The X file has no follower count") : .null,
            "followers_delta_1d": num(int(d["followers_delta_1d"])),
        ]
        if let posts {
            let day = posts.filter { (date($0["created_at"]) ?? .distantPast) > asOf.addingTimeInterval(-86_400) }
            func n(_ p: [String: Any], _ k: String) -> Int { int(p[k]) ?? 0 }
            out["posts_24h"] = .number(Double(day.count))
            out["impressions_24h"] = .number(Double(day.reduce(0) { $0 + n($1, "impressions") }))
            out["engagements_24h"] = .number(Double(day.reduce(0) { t, p in
                t + ["likes", "replies", "reposts", "quotes", "bookmarks"].reduce(0) { $0 + n(p, $1) } }))
            let feed: [JSONValue] = day.sorted { (date($0["created_at"]) ?? .distantPast) > (date($1["created_at"]) ?? .distantPast) }
                .prefix(6).map { p in
                    .object(["kind": .string((p["type"] as? String) == "reply" ? "reply" : "post"),
                             "text": .string(p["text"] as? String ?? ""), "url": .string(p["url"] as? String ?? ""),
                             "views": num(int(p["impressions"])),
                             "created_at": (p["created_at"] as? String).map(JSONValue.string) ?? .null])
                }
            out["posts"] = .array(feed)
        } else {
            out["posts_24h"] = .null; out["impressions_24h"] = .null; out["engagements_24h"] = .null
            out["day_reason"] = .string("The X file has no post list")
        }
        out["glance"] = glance(d["glance"])
        if let t = d["totals_7d"] as? [String: Any] {
            out["posts_7d"] = num(int(t["posts"]))
            out["impressions_7d"] = num(int(t["impressions"]))
            let e = ["likes", "replies", "reposts"].compactMap { int(t[$0]) }
            out["engagements_7d"] = e.isEmpty ? .null : .number(Double(e.reduce(0, +)))
        } else {
            out["posts_7d"] = .null; out["impressions_7d"] = .null; out["engagements_7d"] = .null
            out["week_reason"] = .string("The X file has no 7-day totals")
        }
        return .object(out)
    }

    /// The X file's `glance` block (written by the Safari read or by your bot), checked field by field: only x.com
    /// links, whole counts and short text pass; anything else is dropped. Nil when there's nothing usable.
    static func glance(_ any: Any?) -> JSONValue {
        guard let g = any as? [String: Any] else { return .null }
        func link(_ v: Any?) -> String? {
            guard let s = v as? String, s.count <= 200, s.wholeMatch(of: /https:\/\/x\.com\/[A-Za-z0-9_]{1,15}\/status\/[0-9]{1,25}/) != nil else { return nil }
            return s
        }
        func text(_ v: Any?, _ max: Int) -> JSONValue {
            guard let s = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return .null }
            return .string(String(s.prefix(max)))
        }
        func post(_ v: Any?, article: Bool = false) -> JSONValue {
            guard let p = v as? [String: Any], let url = link(p["url"]) else { return .null }
            return .object(["title": text(p["title"], 200), "kind": .string(article || (p["kind"] as? String) == "article" ? "article" : "post"),
                            "url": .string(url), "views": num(int(p["views"])), "likes": num(int(p["likes"])),
                            "replies": num(int(p["replies"])), "posted": text(p["posted"], 40)])
        }
        let replies: [JSONValue] = ((g["top_replies"] as? [[String: Any]]) ?? []).prefix(2).compactMap { r -> JSONValue? in
            guard let url = link(r["url"]) else { return nil }
            let to = (r["to"] as? String).flatMap { s -> String? in
                let h = s.hasPrefix("@") ? String(s.dropFirst()) : s
                return XNative.validHandle(h).map { "@\($0)" } } ?? "a reply"
            return .object(["to": .string(to), "url": .string(url), "views": num(int(r["views"]))])
        }
        let out: [String: JSONValue] = ["pinned": post(g["pinned"]), "latest_article": post(g["latest_article"], article: true),
                                        "taking_off": post(g["taking_off"]), "taking_off_reason": text(g["taking_off_reason"], 240),
                                        "top_replies": .array(replies), "updated": text(g["updated"], 40)]
        let any = out.contains { k, v in k == "top_replies" ? !replies.isEmpty : (k != "updated" && v != .null) }
        return any ? .object(out) : .null
    }

    static func fromDigest(_ root: [String: Any], x: [String: Any], modified: Date, path: String, now: Date,
                           nativeProblem: String) -> JSONValue {
        let sources = root["sources"] as? [String: Any] ?? [:]
        let asOf = date(sources["native_x_as_of"]) ?? date(root["generated"]) ?? modified
        var (st, reason) = status(age: now.timeIntervalSince(asOf), window: digestFreshFor, what: "The X numbers in your morning digest")
        let note = "\(nativeProblem), so these come from the morning digest."
        reason = reason.map { "\(note) \($0)" } ?? note
        let followers = int(x["followers"])
        return .object([
            "status": .string(st.rawValue), "reason": .string(reason ?? note),
            "source": .string("digest"), "path": .string(path),
            "as_of": .string(ISO8601DateFormatter().string(from: asOf)),
            "username": .null,
            "followers": num(followers),
            "followers_reason": followers == nil ? .string("The digest has no follower count") : .null,
            "followers_delta_1d": .null,
            "posts_24h": .null, "impressions_24h": .null, "engagements_24h": .null,
            "day_reason": .string("The digest has no last-24-hours numbers"),
            "posts_7d": num(int(x["posts_7d"])), "impressions_7d": num(int(x["impr_7d"])), "engagements_7d": .null,
            "posts": .array([]),
        ])
    }
}
