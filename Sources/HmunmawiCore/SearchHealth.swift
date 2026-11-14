import Foundation
import HmunmawiProtocol

/// The search health report (Google, Bing and AI-search problems per website) that a monitor script writes as
/// `search_health.json`. Hmunmawi only reads it, groups its sites under your projects, and offers each problem's
/// fixes: an API action or an AI code fix run by the script, or Safari steps you do yourself in one new tab.
/// Nothing here is tied to one owner: the file comes from the owner hub (owner.json) or a file you choose.
public struct SearchHealthReport: Codable, Sendable, Equatable {
    public var generated: String?
    public var sites: [SearchHealthSite]
    public var fixLog: [JSONValue]?
    enum CodingKeys: String, CodingKey { case generated, sites, fixLog = "fix_log" }

    public init(generated: String? = nil, sites: [SearchHealthSite]) { self.generated = generated; self.sites = sites }

    public static func load(from url: URL) -> SearchHealthReport? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SearchHealthReport.self, from: data)
    }
}

public struct SearchHealthSite: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var project: String?
    public var origin: String?
    public var status: String?
    public var checkedAt: String?
    public var counts: [String: Int]?
    public var issues: [SearchHealthIssue]
    public var bing: JSONValue?
    public var gsc: JSONValue?
    enum CodingKeys: String, CodingKey { case id, name, project, origin, status, counts, issues, bing, gsc, checkedAt = "checked_at" }

    public init(id: String, name: String, project: String? = nil, status: String? = nil, issues: [SearchHealthIssue] = []) {
        self.id = id; self.name = name; self.project = project; self.status = status; self.issues = issues
    }

    public func count(_ severity: String) -> Int { counts?[severity] ?? issues.filter { $0.severity == severity }.count }

    /// Why a source has no figures ("no Bing key", "API checks skipped"), or nil when it reported.
    public func missingReason(_ source: String) -> String? {
        let v = source == "bing" ? bing : gsc
        guard let v, case .object(let o) = v else { return "not checked yet" }
        if case .bool(false)? = o["available"] { return o["reason"]?.string ?? "not available" }
        return nil
    }
}

public struct SearchHealthIssue: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var severity: String
    public var source: String?
    public var title: String
    public var plain: String?
    public var kind: String?
    public var count: Int?
    public var urls: [String]?
    public var firstSeen: String?
    public var fixPaths: [SearchHealthFix]
    public var fixStatus: SearchHealthFixStatus?
    enum CodingKeys: String, CodingKey {
        case id, severity, source, title, plain, kind, count, urls
        case firstSeen = "first_seen", fixPaths = "fix_paths", fixStatus = "fix_status"
    }

    public init(id: String, severity: String, title: String, plain: String? = nil, fixPaths: [SearchHealthFix] = [],
                fixStatus: SearchHealthFixStatus? = nil) {
        self.id = id; self.severity = severity; self.title = title; self.plain = plain; self.fixPaths = fixPaths; self.fixStatus = fixStatus
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        severity = (try? c.decode(String.self, forKey: .severity)) ?? "low"
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        title = (try? c.decode(String.self, forKey: .title)) ?? id
        plain = try? c.decodeIfPresent(String.self, forKey: .plain)
        kind = try? c.decodeIfPresent(String.self, forKey: .kind)
        count = try? c.decodeIfPresent(Int.self, forKey: .count)
        urls = try? c.decodeIfPresent([String].self, forKey: .urls)
        firstSeen = try? c.decodeIfPresent(String.self, forKey: .firstSeen)
        fixPaths = (try? c.decodeIfPresent([SearchHealthFix].self, forKey: .fixPaths)) ?? []
        fixStatus = try? c.decodeIfPresent(SearchHealthFixStatus.self, forKey: .fixStatus)
    }

    /// "Needs attention" etc. in plain words.
    public var severityLabel: String {
        switch severity { case "high": "Needs attention"; case "moderate": "Worth fixing"; case "low": "Minor"; default: "Note" }
    }
}

public struct SearchHealthFix: Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable { case api, aiCode = "ai_code", safari }
    public var kind: Kind
    public var action: String
    public var label: String
    public var brief: String?
    public var startURL: String?
    public var steps: [String]?
    enum CodingKeys: String, CodingKey { case kind, action, label, brief, steps, startURL = "start_url" }

    public init(kind: Kind, action: String, label: String, brief: String? = nil, startURL: String? = nil, steps: [String]? = nil) {
        self.kind = kind; self.action = action; self.label = label; self.brief = brief; self.startURL = startURL; self.steps = steps
    }
}

public struct SearchHealthFixStatus: Codable, Sendable, Equatable {
    public var kind: String?
    public var state: String
    public var at: String?
    public var detail: JSONValue?

    public init(kind: String? = nil, state: String, at: String? = nil, detail: JSONValue? = nil) {
        self.kind = kind; self.state = state; self.at = at; self.detail = detail
    }

    /// One line: "Deferred: AI is paused; runs when the pause ends".
    public var line: String {
        let name: String = switch state {
        case "queued": "Queued"; case "deferred": "Deferred"; case "running": "Running"; case "done": "Done"; case "failed": "Failed"
        default: state.capitalized
        }
        var why: String?
        switch detail {
        case .string(let s)?: why = s
        case .object(let o)?: why = o["recheck"]?.string.map { "recheck: \($0)" } ?? o["action"]?.string
        default: why = nil
        }
        return [name, why].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
    }
}

public enum SearchHealth {
    public static let fileName = "search_health.json"

    /// The report to show: a file you picked wins, else the owner hub's `out/search/search_health.json`.
    public static func reportURL(owner: OwnerConfig = .current, chosen: String?) -> URL? {
        if let chosen, !chosen.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: (chosen as NSString).expandingTildeInPath)
        }
        return owner.hubURL?.appending(path: "out/search/\(fileName)")
    }

    /// The monitor script that runs fixes: the hub's `scripts/search_health.py`, else one next to the report's folder
    /// (`<root>/out/search/search_health.json` → `<root>/scripts/search_health.py`). nil = view only.
    public static func scriptURL(report: URL?, owner: OwnerConfig = .current, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL? {
        var candidates: [URL] = []
        if let hub = owner.hubURL { candidates.append(hub.appending(path: "scripts/search_health.py")) }
        if let report {
            candidates.append(report.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "scripts/search_health.py"))
        }
        return candidates.first(where: exists)
    }

    /// The sites shown under a project: those naming the project, or whose name/project is one of its members.
    /// Everything when no project is picked.
    public static func sites(_ report: SearchHealthReport, project: String?, members: [String] = []) -> [SearchHealthSite] {
        guard let project else { return report.sites }
        let needles = ([project] + members).map { $0.lowercased() }.filter { $0.count >= 3 }
        return report.sites.filter { s in
            let hay = [s.project ?? "", s.name, s.origin ?? ""].map { $0.lowercased() }
            return hay.contains { h in !h.isEmpty && needles.contains { h == $0 || h.contains($0) } }
        }
    }

    /// Script arguments for a fix (api and AI code fixes), or for a recheck. Safari fixes run in the app.
    public static func arguments(fix: SearchHealthFix?, site: String, issue: String) -> [String]? {
        guard let fix else { return ["run", "--site", site, "--reason", "recheck"] }
        switch fix.kind {
        case .api: return fix.action == "recheck" ? ["run", "--site", site, "--reason", "recheck"]
                                                  : ["fix", "--site", site, "--issue", issue, "--action", fix.action]
        case .aiCode: return ["ai-fix", "--site", site, "--issue", issue]
        case .safari: return nil
        }
    }

    public static func statusArguments(site: String, issue: String, kind: String, state: String, detail: String) -> [String] {
        ["fix-status", "--site", site, "--issue", issue, "--kind", kind, "--state", state, "--detail", String(detail.prefix(300))]
    }

    /// The script's times ("2026-11-10T17:24+05:30", minutes only) or full ISO 8601.
    public static func date(_ iso: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: iso) { return d }
        guard let r = iso.range(of: #"T\d\d:\d\d(?=[+-]|Z)"#, options: .regularExpression) else { return nil }
        var s = iso
        s.insert(contentsOf: ":00", at: r.upperBound)
        return f.date(from: s)
    }

    /// The overall word for a site ("All clear", "Needs attention", "Worth a look").
    public static func headline(_ s: SearchHealthSite) -> String {
        if s.count("high") > 0 { return "Needs attention" }
        if s.count("moderate") > 0 { return "Worth a look" }
        return s.issues.isEmpty ? "All clear" : "Minor things only"
    }
}

/// Safari fixes open ONE new tab of their own at a search tool's own page, and only there. The tab is closed only
/// when it is still on that tool (so a tab you moved elsewhere, or one of yours, is never closed).
public enum SafariFix {
    public static let allowed: [(host: String, path: String)] = [("www.bing.com", "/webmasters"), ("search.google.com", "/search-console")]

    public static func isAllowed(_ s: String) -> Bool {
        guard let u = URL(string: s), u.scheme == "https", let host = u.host, !s.contains("\""), !s.contains("\\") else { return false }
        return allowed.contains { host == $0.host && u.path.hasPrefix($0.path) }
    }

    /// A sign-in page or a captcha in the tab: the fix stops and you take over.
    public static func needsYou(_ s: String) -> Bool {
        let l = s.lowercased()
        return ["login.live.com", "login.microsoftonline.com", "accounts.google.com", "/signin", "/login", "captcha", "/sorry/"].contains { l.contains($0) }
    }

    /// AppleScript that opens the one tab (reusing the window's single blank document only when Safari has no window)
    /// and returns "<window id>,<tab index>".
    public static func openScript(_ url: String) -> String? {
        guard isAllowed(url) else { return nil }
        return """
        tell application "Safari"
            if (count of windows) is 0 then
                make new document with properties {URL:"\(url)"}
                return ((id of front window) as text) & ",1"
            end if
            set w to front window
            set t to make new tab at end of tabs of w with properties {URL:"\(url)"}
            set current tab of w to t
            return ((id of w) as text) & "," & ((count of tabs of w) as text)
        end tell
        """
    }

    public static func urlScript(window: Int, tab: Int) -> String {
        """
        tell application "Safari"
            try
                return URL of tab \(tab) of window id \(window)
            on error
                return ""
            end try
        end tell
        """
    }

    public static func closeScript(window: Int, tab: Int) -> String {
        let checks = allowed.map { "u starts with \"https://\($0.host)\($0.path)\"" }.joined(separator: " or ")
        return """
        tell application "Safari"
            try
                set t to tab \(tab) of window id \(window)
                set u to URL of t
                if \(checks) then
                    close t
                    return "closed"
                end if
                return "left"
            on error
                return "gone"
            end try
        end tell
        """
    }

    public static func parseHandle(_ s: String) -> (window: Int, tab: Int)? {
        let p = s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",").compactMap { Int($0) }
        return p.count == 2 ? (p[0], p[1]) : nil
    }
}
