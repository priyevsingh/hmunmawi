import Foundation

/// "Watch my services": the pure rules behind it. Sentry issues (crashes, website-down from Sentry Uptime, Mac
/// jobs from Sentry Crons) become one plain sentence each when they first appear and when they close; a website's
/// production deploy that failed or fell behind its branch becomes one sentence and a Redeploy you approve.
public enum SentryIssues {
    public struct Issue: Sendable, Equatable {
        public var id: String
        public var title: String
        public var project: String
        public var category: String     // issueCategory (error, uptime, cron, performance, …) or ""
        public var type: String         // issueType or ""
        public var level: String
        public var count: Int
        public var permalink: String?
        public var culprit: String?
        public init(id: String, title: String, project: String, category: String = "", type: String = "", level: String = "error",
                    count: Int = 0, permalink: String? = nil, culprit: String? = nil) {
            self.id = id; self.title = title; self.project = project; self.category = category; self.type = type
            self.level = level; self.count = count; self.permalink = permalink; self.culprit = culprit
        }
    }

    public enum Kind: String, Sendable { case websiteDown, jobProblem, crash, slow, other }

    public static func kind(_ i: Issue) -> Kind {
        let c = (i.category + " " + i.type).lowercased()
        if c.contains("uptime") { return .websiteDown }
        if c.contains("cron") || c.contains("monitor_check") { return .jobProblem }
        if c.contains("performance") || c.contains("profile") { return .slow }
        if i.category.isEmpty || c.contains("error") { return .crash }
        return .other
    }

    /// The issues in an add-on payload (`{"issues": [...]}`).
    public static func parse(_ payload: JSONValue) -> [Issue] {
        (payload[path: "issues"]?.array ?? []).compactMap { o in
            guard let id = o[path: "id"]?.string, let title = o[path: "title"]?.string else { return nil }
            return Issue(id: id, title: String(title.prefix(200)), project: o[path: "project"]?.string ?? "",
                         category: o[path: "category"]?.string ?? "", type: o[path: "type"]?.string ?? "",
                         level: o[path: "level"]?.string ?? "error", count: Int(o[path: "count"]?.number ?? 0),
                         permalink: o[path: "permalink"]?.string, culprit: o[path: "culprit"]?.string)
        }
    }

    /// One plain sentence for a new problem.
    public static func opened(_ i: Issue) -> String {
        switch kind(i) {
        case .websiteDown: "⚠️ Website down (Sentry Uptime): \(i.title)."
        case .jobProblem: "⚠️ A job Sentry watches is late or failed (\(i.project)): \(i.title)."
        case .crash: "🐞 New problem in \(i.project): \(i.title)" + (i.count > 1 ? " (\(i.count) times so far)." : ".")
        case .slow: "🐢 Slow spot in \(i.project): \(i.title)."
        case .other: "Sentry (\(i.project)): \(i.title)."
        }
    }

    /// One plain sentence when it's gone (resolved, or no longer open).
    public static func closed(title: String, kind: Kind) -> String {
        switch kind {
        case .websiteDown: "✅ Website back (Sentry Uptime): \(title)."
        case .jobProblem: "✅ Back to normal: \(title)."
        default: "✅ Closed in Sentry: \(title)."
        }
    }

    /// Compares what's open now with what was open last time: (new ones, closed ones). The first run (no memory
    /// yet) reports nothing, so connecting Sentry never floods you with old problems.
    public static func diff(previous: [String: String]?, now: [Issue]) -> (opened: [Issue], closed: [(id: String, title: String)]) {
        guard let previous else { return ([], []) }
        let ids = Set(now.map(\.id))
        let opened = now.filter { previous[$0.id] == nil }
        let closed = previous.filter { !ids.contains($0.key) }.sorted { $0.key < $1.key }.map { (id: $0.key, title: $0.value) }
        return (opened, closed)
    }
}

/// A website's production deploy against its branch (from the Vercel connection).
public enum DeployWatch {
    public enum Status: String, Sendable, Equatable { case ok, building, behind, failed, unknown }

    public struct Snapshot: Sendable, Equatable {
        public var project: String
        public var branch: String?
        public var headSHA: String?
        public var headAt: Date?            // when the branch's newest commit was made
        public var productionSHA: String?
        public var productionState: String? // READY, ERROR, CANCELED, BUILDING, …
        public var productionURL: String?
        public var headDeployState: String? // the state of a deploy for the head commit, if one exists
        public var headDeployAt: Date?
        public init(project: String, branch: String? = nil, headSHA: String? = nil, headAt: Date? = nil, productionSHA: String? = nil,
                    productionState: String? = nil, productionURL: String? = nil, headDeployState: String? = nil, headDeployAt: Date? = nil) {
            self.project = project; self.branch = branch; self.headSHA = headSHA; self.headAt = headAt; self.productionSHA = productionSHA
            self.productionState = productionState; self.productionURL = productionURL; self.headDeployState = headDeployState; self.headDeployAt = headDeployAt
        }

        public init?(_ p: JSONValue) {
            guard let project = p[path: "project"]?.string else { return nil }
            func date(_ k: String) -> Date? { p[path: k]?.number.map { Date(timeIntervalSince1970: $0 / 1000) } }
            self.init(project: project, branch: p[path: "branch"]?.string, headSHA: p[path: "head_sha"]?.string, headAt: date("head_at"),
                      productionSHA: p[path: "production_sha"]?.string, productionState: p[path: "production_state"]?.string,
                      productionURL: p[path: "production_url"]?.string, headDeployState: p[path: "head_deploy_state"]?.string,
                      headDeployAt: date("head_deploy_at"))
        }
    }

    static let inProgress: Set<String> = ["BUILDING", "QUEUED", "INITIALIZING"]
    static let failedStates: Set<String> = ["ERROR", "CANCELED"]

    /// `graceMinutes`: how long a new commit may go without any deploy before it counts as behind (default 10);
    /// a build running longer than `stuckMinutes` (default 30) counts as failed.
    public static func status(_ s: Snapshot, now: Date = .now, graceMinutes: Double = 10, stuckMinutes: Double = 30) -> Status {
        let prodFailed = failedStates.contains(s.productionState ?? "")
        guard let head = s.headSHA, !head.isEmpty else { return prodFailed ? .failed : (s.productionState == nil ? .unknown : .ok) }
        if let prod = s.productionSHA, prod == head { return prodFailed ? .failed : (s.productionState == "READY" ? .ok : inProgress.contains(s.productionState ?? "") ? .building : .unknown) }
        if let st = s.headDeployState {
            if failedStates.contains(st) { return .failed }
            if inProgress.contains(st) {
                if let at = s.headDeployAt, now.timeIntervalSince(at) > stuckMinutes * 60 { return .failed }
                return .building
            }
            if st == "READY" { return .building }   // built but not promoted yet: give it the next check
        }
        guard let at = s.headAt else { return .unknown }
        return now.timeIntervalSince(at) > graceMinutes * 60 ? .behind : .building
    }

    /// One plain sentence (nil when there's nothing to say).
    public static func sentence(_ s: Snapshot, status: Status) -> String? {
        let short = s.headSHA.map { String($0.prefix(7)) } ?? "the newest commit"
        let branch = s.branch ?? "your branch"
        switch status {
        case .behind: return "⚠️ \(s.project): \(branch) has \(short), but no deploy started for it. Production still shows the older version. Redeploy waits for your OK (Log → Waiting, or hm deploy-redeploy)."
        case .failed: return "⚠️ \(s.project): the production deploy of \(short) failed or got stuck (\(s.headDeployState ?? s.productionState ?? "error")). Check the build log; Redeploy waits for your OK."
        default: return nil
        }
    }
}

/// Sentry Crons check-ins for "Mac-alive heartbeat": a monitor that expects a check-in every few minutes, so Sentry
/// tells you when this Mac or Hmunmawi stops (asleep, off, crashed). Built from the project's DSN.
public enum Heartbeat {
    public struct Target: Sendable, Equatable {
        public let host: String
        public let projectID: String
        public let publicKey: String
    }

    /// "https://<public key>@o123.ingest.us.sentry.io/456" -> host, project id, public key. nil when it isn't a DSN.
    public static func parse(dsn: String) -> Target? {
        let t = dsn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = URLComponents(string: t), c.scheme == "https", let key = c.user, key.wholeMatch(of: /[0-9a-f]{16,64}/) != nil,
              let host = c.host?.lowercased(), host == "sentry.io" || host.hasSuffix(".sentry.io"),
              let project = c.path.split(separator: "/").last.map(String.init), project.wholeMatch(of: /\d{1,20}/) != nil else { return nil }
        return Target(host: host, projectID: project, publicKey: key)
    }

    /// A monitor name: lowercase letters, digits, - and _, up to 50.
    public static func validSlug(_ s: String) -> Bool { s.wholeMatch(of: /[a-z0-9][a-z0-9_-]{0,49}/) != nil }

    /// The documented HTTP check-in address: https://<host>/api/<project>/cron/<slug>/<key>/
    public static func url(_ t: Target, slug: String) -> URL? {
        guard validSlug(slug) else { return nil }
        return URL(string: "https://\(t.host)/api/\(t.projectID)/cron/\(slug)/\(t.publicKey)/")
    }

    /// The check-in body, with `monitor_config` so Sentry creates or updates the monitor itself (an interval
    /// schedule of `everyMinutes`, a margin, and the time zone).
    public static func body(status: String, everyMinutes: Int, marginMinutes: Int, timezone: String) -> [String: Any] {
        ["status": status,
         "monitor_config": ["schedule": ["type": "interval", "value": max(1, everyMinutes), "unit": "minute"],
                            "checkin_margin": max(1, marginMinutes), "max_runtime": 5, "timezone": timezone,
                            "failure_issue_threshold": 1, "recovery_threshold": 1] as [String: Any]]
    }
}
