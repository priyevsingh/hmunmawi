import Foundation
import HmunmawiPluginKit

/// Vercel: visitors and page views (Web Analytics query API, every 3 hours) and production deploy health
/// (every 15 minutes): which commit production runs, and, with a GitHub repository set, whether your branch has a
/// newer commit that never got a deploy. The only write is `vercel.redeploy`, which the app runs after your OK.
struct Vercel: HmunmawiPlugin {
    static let api = "https://api.vercel.com"

    struct Project { var id: String; var name: String; var branch: String; var repo: String? }

    func poll(core: Core) async throws -> [PluginEvent] {
        let settings = await core.settings
        let entries = try await Self.projects(core, settings)
        let now = Date()
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        var events: [PluginEvent] = []

        for (project, siteName) in entries {
            // Production now: the newest production deploy and the commit it was built from.
            let prod = try await Self.deployments(core, settings, project: project.id, extra: "target=production&limit=3").first
            var payload: [String: JSONValue] = [
                "project": .string(siteName), "vercel_project": .string(project.name), "branch": .string(project.branch),
                "production_state": prod.flatMap { Self.state($0) }.map(JSONValue.string) ?? .null,
                "production_sha": prod.flatMap { $0[path: "meta.githubCommitSha"]?.string }.map(JSONValue.string) ?? .null,
                "production_url": prod.flatMap { $0[path: "url"]?.string }.map { .string("https://" + $0) } ?? .null,
                "production_id": prod.flatMap { $0[path: "uid"]?.string }.map(JSONValue.string) ?? .null,
                "checked_at": .number(Double(ms)),
            ]
            // The branch's newest commit (GitHub), and any deploy Vercel started for it.
            if let repo = project.repo, let head = await Self.head(core, repo: repo, branch: project.branch) {
                payload["repo"] = .string(repo)
                payload["head_sha"] = .string(head.sha)
                if let at = head.at { payload["head_at"] = .number(at.timeIntervalSince1970 * 1000) }
                if head.sha != payload["production_sha"]?.string,
                   let d = try? await Self.deployments(core, settings, project: project.id, extra: "sha=\(head.sha)&limit=3").first {
                    payload["head_deploy_state"] = Self.state(d).map(JSONValue.string) ?? .null
                    if let c = d[path: "createdAt"]?.number { payload["head_deploy_at"] = .number(c) }
                }
            }
            let key = ["production_sha", "production_state", "head_sha", "head_deploy_state"].map { payload[$0]?.string ?? "-" }.joined(separator: "|")
            events.append(PluginEvent(kind: "deploy.snapshot", app: siteName, payload: .object(payload), occurredAt: ms,
                                      dedupeKey: "deploy-\(project.id)-\(key)-\(Int(now.timeIntervalSince1970 / 3600))"))

            // Visitors: at most every 3 hours per project (each read counts against Vercel's API limits).
            if Self.analyticsDue(now, projectID: project.id) {
                do {
                    if let card = try await Self.visitors(core, settings, project: project, siteName: siteName, now: now) {
                        events.append(card)
                        Self.markAnalytics(now, projectID: project.id)
                    }
                } catch let e as WireError {
                    core.log("web analytics skipped (\(siteName)): \(e.message)")
                    Self.markAnalytics(now, projectID: project.id)
                }
            }
        }
        return events
    }

    /// Redeploy production, only ever after the owner's OK in the app. With a GitHub repository, it deploys the
    /// branch's newest commit (it must still be the one you approved); without one, it rebuilds the given deployment.
    func act(action: String, params: JSONValue, core: Core) async throws -> JSONValue {
        guard action == "vercel.redeploy" else { throw WireError("unknown_action", "No action \(action)") }
        let settings = await core.settings
        let entries = try await Self.projects(core, settings)
        let targetName = params[path: "project"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let project: Project
        if targetName.isEmpty {
            guard entries.count == 1 else {
                throw WireError("bad_params", "Multiple Vercel projects are configured; give project=<site or project name>.")
            }
            project = entries[0].project
        } else if let hit = entries.first(where: {
            $0.siteName.caseInsensitiveCompare(targetName) == .orderedSame
                || $0.project.name.caseInsensitiveCompare(targetName) == .orderedSame
                || $0.project.id.caseInsensitiveCompare(targetName) == .orderedSame
        }) {
            project = hit.project
        } else {
            throw WireError("vercel_unknown_project", "No configured Vercel project matches \(targetName).")
        }
        var body: [String: JSONValue] = ["name": .string(project.name), "project": .string(project.id), "target": .string("production")]
        if let sha = params[path: "sha"]?.string, sha.wholeMatch(of: /[0-9a-f]{7,40}/) != nil {
            guard let repo = project.repo, let head = await Self.head(core, repo: repo, branch: project.branch) else {
                throw WireError("vercel_no_repo", "Set the GitHub repository in this connection's settings first.")
            }
            guard head.sha.hasPrefix(sha) || sha.hasPrefix(head.sha) else {
                throw WireError("vercel_moved", "\(project.branch) moved on since you approved (now \(head.sha.prefix(7))); check again and approve the new one.")
            }
            let parts = repo.split(separator: "/").map(String.init)
            body["gitSource"] = .object(["type": .string("github"), "org": .string(parts[0]), "repo": .string(parts[1]),
                                         "ref": .string(project.branch), "sha": .string(head.sha)])
        } else if let id = params[path: "deployment"]?.string, id.wholeMatch(of: /dpl_[A-Za-z0-9]{6,64}/) != nil {
            body["deploymentId"] = .string(id)
        } else {
            throw WireError("bad_params", "Give sha=<commit> or deployment=<dpl_…>.")
        }
        let text = try JSONValue.object(body).canonicalText()
        let r = try await core.http(HTTPRequestSpec(method: "POST", url: "\(Self.api)/v13/deployments?forceNew=1\(Self.team(settings, "&"))",
                                                    headers: Self.headers, body: text))
        let json = try Self.checked(r)
        let url = json[path: "url"]?.string.map { "https://" + $0 } ?? ""
        return .object(["done": .string("Redeploy started\(url.isEmpty ? "" : ": " + url). It shows as building until Vercel finishes."),
                        "id": json[path: "id"].map { $0 } ?? .null])
    }

    // MARK: Reads

    static let headers = ["Authorization": "Bearer {{secret:apiToken}}", "Content-Type": "application/json"]

    static func list(_ settings: JSONValue, _ key: String) -> [String] {
        text(settings, key).split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func projects(_ core: Core, _ settings: JSONValue) async throws -> [(project: Project, siteName: String)] {
        let rawList = list(settings, "project")
        guard !rawList.isEmpty, rawList.allSatisfy({ $0.wholeMatch(of: /[A-Za-z0-9._-]{1,100}/) != nil }) else {
            throw WireError("not_set_up", "Add your Vercel project name or ID first (letters, digits, dots and dashes; comma-separated for multiple)")
        }
        let teamID = text(settings, "teamID")
        guard teamID.isEmpty || teamID.wholeMatch(of: /team_[A-Za-z0-9]{6,64}/) != nil else {
            throw WireError("not_set_up", "The Team ID starts with team_ (or leave it empty for a personal account)")
        }
        let siteNames = list(settings, "siteName")
        let repos = list(settings, "repo")
        let branches = list(settings, "branch")
        var out: [(Project, String)] = []
        for (i, raw) in rawList.enumerated() {
            let r = try await core.http(HTTPRequestSpec(url: "\(api)/v9/projects/\(raw)\(team(settings, "?"))", headers: headers))
            let json = try checked(r)
            guard let id = json[path: "id"]?.string else { throw WireError("vercel_failed", "Vercel didn't return that project") }
            var repo = (repos.count == rawList.count ? repos[i] : (rawList.count == 1 ? repos.first : nil)) ?? ""
            if repo.isEmpty, json[path: "link.type"]?.string == "github", let org = json[path: "link.org"]?.string, let name = json[path: "link.repo"]?.string {
                repo = "\(org)/\(name)"
            }
            let branchSetting = (branches.count == rawList.count ? branches[i] : branches.first) ?? ""
            let branch = branchSetting.isEmpty ? (json[path: "link.productionBranch"]?.string ?? "main") : branchSetting
            let validRepo = repo.wholeMatch(of: /[A-Za-z0-9_.-]{1,100}\/[A-Za-z0-9_.-]{1,100}/) != nil ? repo : nil
            guard branch.wholeMatch(of: /[A-Za-z0-9._\/-]{1,200}/) != nil else { throw WireError("not_set_up", "That branch name has characters Git doesn't use") }
            let proj = Project(id: id, name: json[path: "name"]?.string ?? raw, branch: branch, repo: validRepo)
            let siteOverride = siteNames.count == rawList.count ? siteNames[i] : (rawList.count == 1 ? siteNames.first : nil)
            let site = (siteOverride?.isEmpty == false ? siteOverride! : proj.name)
            out.append((proj, site))
        }
        return out
    }

    static func deployments(_ core: Core, _ settings: JSONValue, project: String, extra: String) async throws -> [JSONValue] {
        let r = try await core.http(HTTPRequestSpec(url: "\(api)/v7/deployments?projectId=\(project)&\(extra)\(team(settings, "&"))", headers: headers))
        return try checked(r)[path: "deployments"]?.array ?? []
    }

    /// The branch's newest commit from GitHub. A public repository needs no token; a private one uses the optional one.
    static func head(_ core: Core, repo: String, branch: String) async -> (sha: String, at: Date?)? {
        let url = "https://api.github.com/repos/\(repo)/commits/\(branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch)"
        var h = ["Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "Hmunmawi"]
        var response: HTTPResponseSpec?
        h["Authorization"] = "Bearer {{secret:githubToken}}"
        response = try? await core.http(HTTPRequestSpec(url: url, headers: h))   // fails at once when no token is saved
        if response?.status != 200 {
            h["Authorization"] = nil
            response = try? await core.http(HTTPRequestSpec(url: url, headers: h))
        }
        guard let r = response, r.status == 200, let json = try? JSONValue.parse(r.body ?? ""), let sha = json[path: "sha"]?.string else {
            core.log("GitHub: couldn't read \(repo)@\(branch) (\(response.map { "status \($0.status)" } ?? "no answer"))")
            return nil
        }
        let at = (json[path: "commit.committer.date"]?.string ?? json[path: "commit.author.date"]?.string).flatMap { try? Date($0, strategy: .iso8601) }
        return (sha, at)
    }

    static func visitors(_ core: Core, _ settings: JSONValue, project: Project, siteName: String, now: Date) async throws -> PluginEvent? {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let end = cal.startOfDay(for: now)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func window(_ days: Int) -> String { "since=\(iso.string(from: end.addingTimeInterval(Double(-days) * 86_400)))&until=\(iso.string(from: end))" }
        let base = "projectId=\(project.id)\(team(settings, "&"))"
        func count(_ days: Int) async throws -> (Double, Double) {
            let r = try await core.http(HTTPRequestSpec(url: "\(api)/v1/query/web-analytics/visits/count?\(base)&\(window(days))", headers: headers))
            let d = try checked(r)[path: "data"]
            return (d?[path: "visitors"]?.number ?? 0, d?[path: "pageviews"]?.number ?? 0)
        }
        let (v7, p7) = try await count(7)
        let (v28, _) = try await count(28)
        let daily = try await core.http(HTTPRequestSpec(url: "\(api)/v1/query/web-analytics/visits/aggregate?\(base)&by=day&limit=40&\(window(28))", headers: headers))
        var days: [JSONValue] = [], values: [JSONValue] = []
        let today = String(iso.string(from: end).prefix(10))
        for row in (try checked(daily)[path: "data"]?.array ?? []) {
            guard let d = row[path: "timestamp"]?.string.map({ String($0.prefix(10)) }), d < today else { continue }
            days.append(.string(d)); values.append(.number(row[path: "visitors"]?.number ?? 0))
        }
        // Nothing in 28 days on a project with Web Analytics on almost always means the site doesn't load Vercel's
        // analytics script. Say so, and send no "Visitors" figure: a 0 there would read as "nobody came" and could
        // replace the site's real visitor count from another source (both are found by the "Visitors" label).
        if v28 == 0 && p7 == 0 {
            return PluginEvent(kind: "section.snapshot", app: siteName, payload: .object([
                "id": .string("vercel-visitors-\(project.id)"),
                "title": .string("Website visitors (Vercel)"),
                "page": .string("growth"), "symbol": .string("globe"), "order": .number(13), "color": .string("web"),
                "outcome": .string("Vercel Web Analytics recorded no visits in 28 days. The site probably doesn't load Vercel's analytics script (add @vercel/analytics, or the /_vercel/insights script, to count visits here). Visitors from any other source you connected still show on Today."),
                "figures": .array([]), "series": .array([]),
            ]), occurredAt: Int64(now.timeIntervalSince1970 * 1000),
               dedupeKey: "section.snapshot-vercel-\(project.id)-\(today)-\(Int(now.timeIntervalSince1970 / 10800))")
        }
        let payload = JSONValue.object([
            "id": .string("vercel-visitors-\(project.id)"),
            "title": .string("Website visitors (Vercel)"),
            "page": .string("growth"),
            "symbol": .string("globe"),
            "order": .number(13),
            "color": .string("web"),
            "outcome": .string("\(Int64(v7).formatted()) visitors and \(Int64(p7).formatted()) page views in 7 days (Vercel Web Analytics)"),
            "figures": .array([
                .object(["label": .string("Visitors, 7 days"), "value": .number(v7)]),
                .object(["label": .string("Page views, 7 days"), "value": .number(p7)]),
                .object(["label": .string("Visitors, 28 days"), "value": .number(v28)]),
            ]),
            "series": .array([.object(["label": .string("Visitors each day"), "days": .array(days), "values": .array(values)])]),
        ])
        return PluginEvent(kind: "section.snapshot", app: siteName, payload: payload, occurredAt: Int64(now.timeIntervalSince1970 * 1000),
                           dedupeKey: "section.snapshot-vercel-\(project.id)-\(today)-\(Int(now.timeIntervalSince1970 / 10800))")
    }

    // MARK: Helpers

    static func state(_ d: JSONValue) -> String? { d[path: "readyState"]?.string ?? d[path: "state"]?.string }

    static func team(_ settings: JSONValue, _ joiner: String) -> String {
        let t = text(settings, "teamID")
        return t.isEmpty ? "" : "\(joiner)teamId=\(t)"
    }

    static func text(_ settings: JSONValue, _ key: String) -> String {
        settings[path: key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func checked(_ response: HTTPResponseSpec) throws -> JSONValue {
        let json = (try? JSONValue.parse(response.body ?? "")) ?? .null
        switch response.status {
        case 200, 201: return json
        case 401: throw WireError("vercel_failed", "Vercel did not accept the token. Create a new one in Account Settings → Tokens")
        case 403: throw WireError("vercel_failed", "Vercel: this token can't read that project (check its scope and the Team ID)")
        case 404: throw WireError("vercel_failed", "Vercel could not find that project. Check its name or ID, and the Team ID")
        default: throw WireError("vercel_failed", "Vercel: \(json[path: "error.message"]?.string ?? "status \(response.status)")")
        }
    }

    static func stamp(projectID: String) -> URL {
        let d = URL.applicationSupportDirectory.appending(path: "Hmunmawi/AddOnState/vercel", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let safe = projectID.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return d.appending(path: "analytics-\(safe.isEmpty ? "default" : safe).txt")
    }
    static func analyticsDue(_ now: Date, projectID: String) -> Bool {
        guard let t = (try? String(contentsOf: stamp(projectID: projectID), encoding: .utf8)).flatMap(Double.init) else { return true }
        return now.timeIntervalSince1970 - t >= 3 * 3600
    }
    static func markAnalytics(_ now: Date, projectID: String) { StateFile.write(String(now.timeIntervalSince1970), to: stamp(projectID: projectID)) }
}

await PluginRuntime.run(Vercel())
