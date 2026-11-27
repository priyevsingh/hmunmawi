import Foundation
import HmunmawiProtocol

// MARK: - Fatal freezes (Sentry), tracked only
//
// Sentry's session health counts crashes, not freezes: an app the user or the iOS watchdog killed while its screen
// thread was blocked ("Fatal App Hang") leaves crash-free sessions at 100%. These types count those reports per app
// and release so the Stability card can say so. Tracking only (owner, 10 Nov 2026): no alerts, no amber, nothing in
// Needs attention. Many reports are noise, so each Sentry issue is sorted by the rules below.

/// How the freeze check sorts one Sentry issue.
public enum FreezeVerdict: String, Codable, Sendable, Equatable {
    /// Our own code was on the screen thread: a real freeze worth a look.
    case ourCode
    /// The screen thread sat idle with only `main` from our binary, or the "freeze" lasted longer than iOS lets a
    /// blocked app live (the phone asleep with the app open): usually noise or a false positive.
    case noAppCode
    /// The issue's latest report couldn't be read, so it isn't sorted (never guessed).
    case unchecked
}

public enum FreezeClassifier {
    /// Longer than this, iOS would have killed a truly blocked app long before: the hub's HANG_MAX_REAL_S.
    public static let maxRealSeconds = 60.0
    nonisolated(unsafe) private static let between = /(?i)App Hang.*?between ([\d.]+) and ([\d.]+) seconds/

    /// True for Sentry issue or event titles that are app hangs ("App Hang Fully Blocked", "Fatal App Hang …").
    public static func isHang(_ title: String) -> Bool { title.range(of: "App Hang", options: .caseInsensitive) != nil }

    /// The hub's verdict for one App Hang issue, from its title and latest event (no symbols needed).
    /// Differs in one place on purpose: with no readable event the hub assumes "real"; here it is `.unchecked`.
    public static func verdict(issueTitle: String, latestEvent: JSONValue?) -> FreezeVerdict {
        if let m = issueTitle.firstMatch(of: between), let low = Double(m.1), low > maxRealSeconds { return .noAppCode }
        guard let event = latestEvent, case .object = event else { return .unchecked }
        for entry in event[path: "entries"]?.array ?? [] where entry[path: "type"]?.string == "threads" {
            for thread in entry[path: "data.values"]?.array ?? [] where thread[path: "current"] == .bool(true) {
                let frames = thread[path: "stacktrace.frames"]?.array ?? []
                let ours = frames.filter { $0[path: "inApp"] == .bool(true) || ($0[path: "package"]?.string ?? "").contains(".app/") }
                return ours.count <= 1 ? .noAppCode : .ourCode
            }
        }
        return .ourCode   // the hub's rule: no screen-thread stack to clear it
    }

    /// A Discover column by its exact name: "issue.id" is one key with a dot in it, not a path.
    public static func column(_ row: JSONValue, _ name: String) -> JSONValue? {
        guard case .object(let o) = row else { return nil }
        return o[name]
    }

    /// Discover's issue id (a number, sometimes a string) as text; nil when missing.
    public static func issueID(_ row: JSONValue) -> String? {
        let raw = column(row, "issue.id")
        if let n = raw?.number { return String(Int64(n)) }
        if let s = raw?.string, !s.isEmpty, s.allSatisfy(\.isNumber) { return s }
        return nil
    }

    /// "com.example.app@4.1.7+176" -> "4.1.7"; anything else is shown as it is.
    public static func version(_ release: String) -> String {
        guard let at = release.lastIndex(of: "@") else { return release }
        let rest = release[release.index(after: at)...]
        return String(rest.split(separator: "+").first ?? rest)
    }
}

/// One Sentry issue's fatal freeze count in the window, with its verdict.
public struct FreezeIssueCount: Codable, Sendable, Equatable {
    public var app: String
    public var issueID: String
    public var events: Int
    public var verdict: FreezeVerdict
    public init(app: String, issueID: String, events: Int, verdict: FreezeVerdict) {
        self.app = app; self.issueID = issueID; self.events = events; self.verdict = verdict
    }
}

/// Fatal freezes for one app and release in the window, and how many different users they hit.
public struct FreezeReleaseCount: Codable, Sendable, Equatable {
    public var app: String
    public var release: String
    public var events: Int
    public var users: Int?
    public init(app: String, release: String, events: Int, users: Int?) {
        self.app = app; self.release = release; self.events = events; self.users = users
    }
}

/// What one read of Sentry found. `unavailable` holds the reason when Sentry couldn't be read; then there are no
/// counts at all (shown as "not available", never as 0).
public struct FreezeSummary: Codable, Sendable, Equatable {
    public var checkedAt: Date
    public var windowDays: Int
    public var releases: [FreezeReleaseCount]
    public var issues: [FreezeIssueCount]
    public var unavailable: String?

    public init(checkedAt: Date, windowDays: Int = 7, releases: [FreezeReleaseCount] = [], issues: [FreezeIssueCount] = [], unavailable: String? = nil) {
        self.checkedAt = checkedAt; self.windowDays = windowDays; self.releases = releases; self.issues = issues; self.unavailable = unavailable
    }

    public static func failed(_ reason: String, at: Date = .now) -> FreezeSummary { FreezeSummary(checkedAt: at, unavailable: reason) }

    /// The lines the Stability card shows for one app. When `liveVersion` is supplied, older releases are called out cleanly.
    public func lines(for app: String, liveVersion: String? = nil) -> [String] {
        if let unavailable { return ["Fatal freezes (Sentry): not available. \(unavailable)"] }
        let rel = releases.filter { $0.app == app && $0.events > 0 }.sorted { $0.events > $1.events }
        let total = rel.reduce(0) { $0 + $1.events }
        guard total > 0 else { return ["No fatal freezes in \(windowDays) days (Sentry)."] }
        let live = liveVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasLive = live.map { !$0.isEmpty } ?? false
        let liveHits = hasLive && rel.contains { FreezeClassifier.version($0.release) == live }
        let perRelease = rel.map { r in
            let v = FreezeClassifier.version(r.release)
            let ageTag = (hasLive && v != live) ? " (older release)" : ""
            return "\(r.events.formatted()) on \(v)\(ageTag)" + (r.users.map { " (\($0.formatted()) user\($0 == 1 ? "" : "s"))" } ?? "")
        }.joined(separator: ", ") + ((hasLive && !liveHits) ? "; 0 on live \(live!)" : "")
        let mine = issues.filter { $0.app == app }
        func sum(_ v: FreezeVerdict) -> Int { mine.filter { $0.verdict == v }.reduce(0) { $0 + $1.events } }
        var sorted = ["\(sum(.ourCode).formatted()) with our code on the screen thread",
                      "\(sum(.noAppCode).formatted()) with no app code or longer than \(Int(FreezeClassifier.maxRealSeconds)) s (usually noise or a false positive)"]
        if sum(.unchecked) > 0 { sorted.append("\(sum(.unchecked).formatted()) not checked") }
        return ["\(total.formatted()) fatal freeze\(total == 1 ? "" : "s") in \(windowDays) days (Sentry): \(perRelease).",
                "Freeze check: " + sorted.joined(separator: " · ") + ". Tracked, no alerts."]
    }
}
