import Foundation
import HmunmawiCore
import SwiftUI

/// The routines that look after your services: "Watch my services" (Sentry problems and website deploys in plain
/// words), "Mac-alive heartbeat" (Sentry Crons check-ins, so you hear when this Mac stops), "Check links on my site"
/// (dead outside links, twice-checked) and "Check my workspace Python" (venvs a Python upgrade broke).
/// None of them changes anything outside Hmunmawi on its own: a redeploy or a Python repair waits for your OK.
extension Routines {
    // MARK: Watch my services

    func serviceWatch(_ r: MyRoutine, key: String) async -> (ok: Bool, note: String) {
        guard let model else { return (false, "The app isn't ready.") }
        let d = UserDefaults.standard
        var lines: [String] = []
        var notes: [String] = []
        let stateKey = "HMServiceWatch-\(r.id)"
        var st = d.dictionary(forKey: stateKey) ?? [:]

        // Sentry: each new open problem once, and once when it closes. The first read only remembers.
        if r.params?["issues"] != "0", let snap = model.snapshots("issues.snapshot").max(by: { $0.occurredAt < $1.occurredAt }) {
            let now = SentryIssues.parse(snap.payload)
            let previous = (st["issues"] as? [String: String])
            let (opened, closed) = SentryIssues.diff(previous: previous.map { $0.mapValues { String($0.split(separator: "|", maxSplits: 1).last ?? "") } }, now: now)
            for i in opened.prefix(8) { lines.append(SentryIssues.opened(i) + (i.permalink.map { " \($0)" } ?? "")) }
            if opened.count > 8 { lines.append("…and \(opened.count - 8) more new problems in Sentry.") }
            for c in closed.prefix(8) {
                let kindRaw = previous?[c.id].flatMap { $0.split(separator: "|", maxSplits: 1).first.map(String.init) } ?? ""
                lines.append(SentryIssues.closed(title: c.title, kind: SentryIssues.Kind(rawValue: kindRaw) ?? .other))
            }
            st["issues"] = Dictionary(uniqueKeysWithValues: now.map { ($0.id, SentryIssues.kind($0).rawValue + "|" + $0.title) })
            notes.append("\(now.count) open in Sentry")
        }

        // Website deploys: a failed or stuck build, or a branch commit that never got a deploy. Told once per
        // problem (per commit), and once when production catches up. Redeploy waits in Log → Waiting.
        var redeploys: [(args: [String: String], reason: String, summary: String)] = []
        if r.params?["deploys"] != "0" {
            var told = st["deploys"] as? [String: String] ?? [:]
            let grace = min(max(Self.finite(r.params?["behind"]) ?? 10, 3), 240)
            for e in model.snapshots("deploy.snapshot") {
                guard let s = DeployWatch.Snapshot(e.payload) else { continue }
                let status = DeployWatch.status(s, graceMinutes: grace)
                let mark = "\(status.rawValue)|\(s.headSHA ?? s.productionSHA ?? "")"
                if status == .behind || status == .failed {
                    guard told[s.project] != mark, let text = DeployWatch.sentence(s, status: status) else { continue }
                    told[s.project] = mark
                    lines.append(text)
                    let args = s.headSHA.map { ["project": s.project, "sha": $0] } ?? ["project": s.project, "deployment": e.payload[path: "production_id"]?.string ?? ""]
                    redeploys.append((args, text, "\(r.title): redeploy \(s.project) (\(String((s.headSHA ?? "").prefix(7))))"))
                } else if status == .ok, told[s.project] != nil {
                    told[s.project] = nil
                    lines.append("✅ \(s.project): production runs \(s.branch ?? "the branch")'s newest commit again.")
                }
                notes.append("\(s.project): \(status.rawValue)")
            }
            st["deploys"] = told
        }

        guard !lines.isEmpty else {
            d.set(st, forKey: stateKey)
            return (true, notes.isEmpty ? "Nothing to watch yet: connect Sentry (with event:read) or Vercel in Settings → Connections." : notes.joined(separator: "; ") + ".")
        }
        let sent = await tell(r, text: lines.joined(separator: "\n"), key: key, urgent: lines.contains { $0.hasPrefix("⚠️") })
        if sent.ok {   // remembered (and the Redeploy parked) only once told, so a failed send tries again without duplicates
            d.set(st, forKey: stateKey)
            for p in redeploys { _ = await model.parkAgentRequest(command: "deploy-redeploy", args: p.args, agent: r.title, reason: p.reason, summary: p.summary) }
        }
        return sent
    }

    /// Runs an approved redeploy through the Vercel connection (only from Log → Waiting or your own tap).
    func redeploy(project: String, sha: String?, deployment: String?) async -> (ok: Bool, message: String) {
        guard let model else { return (false, "The app isn't ready.") }
        var params: [String: JSONValue] = ["project": .string(project)]
        if let sha, !sha.isEmpty { params["sha"] = .string(sha) } else if let deployment, !deployment.isEmpty { params["deployment"] = .string(deployment) }
        return await model.performAction("vercel.redeploy", resource: "vercel", params: .object(params))
    }

    // MARK: Mac-alive heartbeat (Sentry Crons)

    func heartbeat(_ r: MyRoutine) async -> (ok: Bool, note: String) {
        guard let target = Heartbeat.parse(dsn: r.params?["dsn"] ?? "") else { return (false, "Add your Sentry project's DSN (Settings → Client Keys).") }
        let slug = r.params?["slug"].flatMap { $0.isEmpty ? nil : $0 } ?? "hmunmawi-mac"
        guard let url = Heartbeat.url(target, slug: slug) else { return (false, "The monitor name must be lowercase letters, digits, - or _.") }
        let every = r.every.flatMap { Int($0.prefix { $0.isNumber }) } ?? 30
        // "error" when a Mac job Hmunmawi watches is failing (only with jobs=1); otherwise "ok" means alive.
        var status = "ok"
        if r.params?["jobs"] == "1", let model, HealthCheck.checks(model).first(where: { $0.id == "jobs" })?.level == .bad { status = "error" }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: Heartbeat.body(status: status, everyMinutes: every, marginMinutes: max(5, every / 2),
                                                                                   timezone: TimeZone.current.identifier))
        let code = ((try? await URLSession(configuration: .ephemeral).data(for: req))?.1 as? HTTPURLResponse)?.statusCode
        // Never alarms you itself: if this Mac can't reach Sentry, Sentry notices the missing check-in and tells you.
        guard let code, (200..<300).contains(code) else { return (false, "Sentry didn't take the check-in (\(code.map(String.init) ?? "no answer")).") }
        return (true, "Checked in (\(status)) to monitor \(slug).")
    }

    // MARK: Check links on my site

    static func linkStateURL(_ id: String) -> URL { URL.hmSupport.appending(path: "link-check-\(id).json") }

    /// One web read for link checks and outreach checks. Never calls this Mac or its own network (also not through a
    /// redirect), stops reading at `maxBytes` (a bigger page gives no body) and gives up after 30 seconds in all.
    nonisolated static func fetch(_ url: URL, method: String = "GET", timeout: TimeInterval = 15, maxBytes: Int = 2_000_000) async -> (status: Int?, body: String?, final: URL?, noSuchHost: Bool) {
        guard WebGuard.allowed(url) else { return (nil, nil, nil, false) }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("Mozilla/5.0 (Macintosh) Hmunmawi link check", forHTTPHeaderField: "User-Agent")
        if method == "GET", maxBytes == 0 { req.setValue("bytes=0-1023", forHTTPHeaderField: "Range") }   // only the answer matters, not a big file
        do {
            let (bytes, resp) = try await WebGuard.session.bytes(for: req, delegate: WebGuard.shared)
            let http = resp as? HTTPURLResponse
            guard method == "GET", maxBytes > 0 else { bytes.task.cancel(); return (http?.statusCode, nil, http?.url, false) }
            if let length = http?.expectedContentLength, length > Int64(maxBytes) { bytes.task.cancel(); return (http?.statusCode, nil, http?.url, false) }
            var data = Data()
            data.reserveCapacity(min(maxBytes, 256_000))
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes { bytes.task.cancel(); return (http?.statusCode, nil, http?.url, false) }
            }
            return (http?.statusCode, String(decoding: data, as: UTF8.self), http?.url, false)
        } catch let e as URLError {
            return (nil, nil, nil, e.code == .cannotFindHost || e.code == .dnsLookupFailed)
        } catch {
            return (nil, nil, nil, false)
        }
    }

    /// The pages to read: your sitemap (or sitemap index, up to 5 sitemaps), else the one address you gave.
    nonisolated static func pages(for start: URL, max: Int) async -> [URL] {
        var sitemap = start
        if !start.path.lowercased().hasSuffix(".xml"), let root = URL(string: "/sitemap.xml", relativeTo: start)?.absoluteURL { sitemap = root }
        let first = await fetch(sitemap)
        var locs: [String] = []
        if let body = first.body, first.status == 200 {
            if LinkCheck.isSitemapIndex(body) {
                for child in LinkCheck.sitemapLocations(body).prefix(5) {
                    guard let u = URL(string: child), WebGuard.allowed(u), let b = await fetch(u).body else { continue }
                    locs += LinkCheck.sitemapLocations(b)
                    if locs.count >= max { break }
                }
            } else {
                locs = LinkCheck.sitemapLocations(body)
            }
        }
        let own = LinkCheck.site(start.host)
        let pages = locs.compactMap(URL.init(string:)).filter { LinkCheck.site($0.host) == own && WebGuard.allowed($0) }
        return pages.isEmpty ? [start] : Array(pages.prefix(max))
    }

    /// One outside link checked: App Store links by Apple's lookup, others HEAD first, then GET when HEAD isn't answered.
    nonisolated static func check(_ link: URL) async -> (verdict: LinkCheck.Verdict, status: String) {
        if let app = LinkCheck.appStoreID(link) {
            let lookup = URL(string: "https://itunes.apple.com/lookup?id=\(app.id)&country=\(app.country)")!
            let l = await fetch(lookup, timeout: 15)
            let count = l.body.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }?["resultCount"] as? Int
            let page = count == 0 ? await fetch(link, method: "HEAD").status : nil
            return (LinkCheck.appStoreVerdict(lookupCount: l.status == 200 ? count : nil, pageStatus: page), count.map { $0 > 0 ? "listed" : "not listed" } ?? "lookup failed")
        }
        var r = await fetch(link, method: "HEAD")
        if r.status == nil || [403, 405, 404, 501].contains(r.status!) { r = await fetch(link, maxBytes: 0) }   // some sites only answer GET
        return (LinkCheck.verdict(status: r.status, noSuchHost: r.noSuchHost), r.noSuchHost ? "no such host" : r.status.map(String.init) ?? "no answer")
    }

    func linkCheck(_ r: MyRoutine, key: String) async -> (ok: Bool, note: String) {
        guard let start = (r.params?["url"]).flatMap(InputCheck.httpsURL) else { return (false, "No website address.") }
        if await !Self.internetIsUp() { return (true, "No internet on this Mac; check skipped.") }
        let maxPages = min(max(Int(r.params?["pages"] ?? "") ?? 50, 1), LinkCheck.maxPages)
        let pages = await Self.pages(for: start, max: maxPages)
        // Outside links, each with the first page it was found on.
        var found: [String: String] = [:], order: [URL] = []
        let own: Set<String> = [start.host ?? ""]
        for chunk in stride(from: 0, to: pages.count, by: 4).map({ Array(pages[$0..<min($0 + 4, pages.count)]) }) {
            let bodies = await withTaskGroup(of: (URL, String?).self) { g in
                for p in chunk { g.addTask { (p, await Self.fetch(p).body) } }
                var out: [(URL, String?)] = []; for await x in g { out.append(x) }; return out
            }
            for (page, body) in bodies {
                guard let body else { continue }
                for l in LinkCheck.outside(LinkCheck.links(in: body, base: page), ownHosts: own) where found[l.absoluteString] == nil && WebGuard.allowed(l) {
                    found[l.absoluteString] = page.absoluteString; order.append(l)
                }
            }
        }
        let links = Array(order.prefix(LinkCheck.maxLinks))
        var results: [String: (verdict: LinkCheck.Verdict, page: String, status: String)] = [:]
        for chunk in stride(from: 0, to: links.count, by: 4).map({ Array(links[$0..<min($0 + 4, links.count)]) }) {
            let checked = await withTaskGroup(of: (URL, LinkCheck.Verdict, String).self) { g in
                for l in chunk { g.addTask { let c = await Self.check(l); return (l, c.verdict, c.status) } }
                var out: [(URL, LinkCheck.Verdict, String)] = []; for await x in g { out.append(x) }; return out
            }
            for (l, v, s) in checked { results[l.absoluteString] = (v, found[l.absoluteString] ?? "", s) }
        }
        let url = Self.linkStateURL(r.id)
        let old = (try? JSONDecoder().decode(LinkCheck.State.self, from: Data(contentsOf: url))) ?? LinkCheck.State()
        var (state, newDead, fixed) = LinkCheck.fold(old, results: results, day: Date.now.localDay)
        state.pages = pages.count; state.checked = links.count
        let summary = "Checked \(pages.count) pages and \(links.count) outside links."
        var lines: [String] = []
        for l in newDead.prefix(10) {
            let e = state.dead[l]
            lines.append("Dead link (\(e?.status ?? "dead")) on \(e?.page ?? "your site"): \(l)")
        }
        if newDead.count > 10 { lines.append("…and \(newDead.count - 10) more (hm links-dead lists them all).") }
        for l in fixed.prefix(5) { lines.append("Works again: \(l)") }
        func save() { if let data = try? JSONEncoder().encode(state) { try? data.write(to: url, options: .atomic) } }
        guard !lines.isEmpty else { save(); return (true, summary + " No new dead links.") }
        let sent = await tell(r, text: "\(r.title): " + summary + "\n" + lines.joined(separator: "\n"), key: key, urgent: false)
        if sent.ok { save() }
        return sent
    }

    // MARK: Check my workspace Python

    struct VenvRow { let root: String; let usedBy: [String]; let health: PythonEnv.Health }

    nonisolated static let locksFolder = URL.hmSupport.appending(path: "python-locks", directoryHint: .isDirectory)

    /// Every venv your script routines and Mac jobs run with, plus folders you named.
    func venvs(extra: String?) -> [VenvRow] {
        let fm = FileManager.default
        let exists: (String) -> Bool = { fm.fileExists(atPath: $0) }
        var used: [String: [String]] = [:]
        func add(_ interpreter: String, _ who: String) {
            if let root = PythonEnv.root(ofInterpreter: (interpreter as NSString).expandingTildeInPath, exists: exists) { used[root, default: []].append(who) }
        }
        func shebang(_ file: String) -> String? {
            guard let h = FileHandle(forReadingAtPath: (file as NSString).expandingTildeInPath) else { return nil }
            defer { try? h.close() }
            let head = String(decoding: h.readData(ofLength: 300), as: UTF8.self)
            return PythonEnv.shebang(String(head.split(separator: "\n").first ?? ""))
        }
        for r in MyRoutines.read() where r.does == RoutineKind.script.rawValue {
            let cmd = r.params?["command"] ?? ""
            let args = ArgLine.split(r.params?["args"] ?? "")
            for i in PythonEnv.interpreters(program: cmd, args: args) { add(i, r.title) }
            if let s = shebang(cmd) { add(s, r.title) }
            if (cmd as NSString).lastPathComponent.hasPrefix("python"), let script = args.first(where: { $0.hasSuffix(".py") }) {
                let full = script.hasPrefix("/") ? script : ((r.params?["folder"] ?? "") as NSString).appendingPathComponent(script)
                if let s = shebang(full) { add(s, r.title) }
            }
        }
        for job in MacAutomations.shared.jobs {
            guard let plist = job.plist, let data = fm.contents(atPath: plist),
                  let p = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
            let argv = (p["ProgramArguments"] as? [String]) ?? (p["Program"] as? String).map { [$0] } ?? []
            guard let program = argv.first else { continue }
            for i in PythonEnv.interpreters(program: program, args: Array(argv.dropFirst())) { add(i, job.label) }
            for a in argv where a.hasSuffix(".py") || a == program { if let s = shebang(a) { add(s, job.label) } }
        }
        for f in (extra ?? "").split(separator: ",").map({ ($0.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath }) where !f.isEmpty {
            if PythonEnv.isVenv(f, exists: exists) { used[f, default: []].append("you") }
        }
        return used.keys.sorted().map { root in
            VenvRow(root: root, usedBy: Array(Set(used[root] ?? [])).sorted(),
                    health: PythonEnv.health(root: root, exists: exists, read: { try? String(contentsOfFile: $0, encoding: .utf8) }))
        }
    }

    nonisolated static func lockURL(_ root: String) -> URL { locksFolder.appending(path: PythonEnv.lockName(root)) }

    /// Runs a program and waits (with a time limit); output is never shown anywhere but the result.
    nonisolated static func runTool(_ argv: [String], timeout: TimeInterval) async -> (code: Int32, output: String) {
        await Task.detached(priority: .utility) { runToolBlocking(argv, timeout: timeout) }.value
    }

    private final class Box: @unchecked Sendable { var data = Data() }

    nonisolated static func runToolBlocking(_ argv: [String], timeout: TimeInterval) -> (code: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0]); p.arguments = Array(argv.dropFirst())
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe; p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0), read = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let box = Box()
        // The reader runs at a higher priority and is given up to 10 s after a normal exit: on a busy machine (a CI
        // runner) a 2 s wait could end before the reader thread was scheduled and return the output empty. A child
        // that keeps the pipe open after exiting still can't hold this up for long.
        DispatchQueue.global(qos: .userInitiated).async { box.data = pipe.fileHandleForReading.readDataToEndOfFile(); read.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut { p.terminate(); _ = read.wait(timeout: .now() + 2); return (-2, "timed out") }
        _ = read.wait(timeout: .now() + 10)
        return (p.terminationStatus, String(decoding: box.data.prefix(20_000), as: UTF8.self))
    }

    /// The python3 a repair builds with: Homebrew's first, then the system's.
    nonisolated static var python3: String? {
        ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func pythonCheck(_ r: MyRoutine, key: String) async -> (ok: Bool, note: String) {
        await MacAutomations.shared.refresh()
        let rows = venvs(extra: r.params?["folders"])
        guard !rows.isEmpty else { return (true, "No Python environments in your script routines or Mac jobs.") }
        try? FileManager.default.createDirectory(at: Self.locksFolder, withIntermediateDirectories: true)
        let d = UserDefaults.standard, toldKey = "HMPythonCheckTold-\(r.id)"
        var told = Set(d.stringArray(forKey: toldKey) ?? [])
        var lines: [String] = []
        for row in rows {
            switch row.health {
            case .ok:
                // A working venv: keep its package list (at most once a day) so a repair can put the same packages back.
                let lock = Self.lockURL(row.root)
                if (fileModified(lock.path).map { Date.now.timeIntervalSince($0) > 86_400 } ?? true) {
                    let r = await Self.runTool([row.root + "/bin/python3", "-m", "pip", "freeze", "--disable-pip-version-check"], timeout: 60)
                    if r.code == 0, !r.output.isEmpty { try? r.output.write(to: lock, atomically: true, encoding: .utf8) }
                }
                if told.remove(row.root) != nil { lines.append("✅ Python works again: \(row.root)") }
            case .broken(let why):
                guard !told.contains(row.root) else { continue }
                let lock = FileManager.default.fileExists(atPath: Self.lockURL(row.root).path) ? Self.lockURL(row.root).path : nil
                if r.params?["repair"] == "auto" {
                    let fixed = await repairPython(row.root, actor: "routine")
                    lines.append(fixed.ok ? "🔧 Repaired \(row.root) (\(why)); used by \(row.usedBy.joined(separator: ", ")). \(fixed.message)"
                                          : "⚠️ \(row.root) is broken (\(why)) and the repair failed: \(fixed.message)")
                    if !fixed.ok { told.insert(row.root) }
                } else {
                    told.insert(row.root)
                    lines.append("⚠️ \(row.root) is broken: \(why). Used by \(row.usedBy.joined(separator: ", ")). Repair it in the routine (Edit → Repair), with hm python-repair venv=\(row.root), or in Terminal: \(PythonEnv.repairCommand(root: row.root, lock: lock, day: Date.now.localDay))")
                }
            }
        }
        let summary = "\(rows.count) Python environment\(rows.count == 1 ? "" : "s"), \(rows.filter { !$0.health.isOK }.count) broken."
        guard !lines.isEmpty else { d.set(Array(told), forKey: toldKey); return (true, summary) }
        let sent = await tell(r, text: lines.joined(separator: "\n"), key: key, urgent: false)
        if sent.ok { d.set(Array(told), forKey: toldKey) }
        return sent
    }

    /// Rebuilds a broken venv: the old folder is kept beside it (<venv>.broken-<day>), a fresh one is made with the
    /// current python3 and the saved package list is installed. Only from your tap or an approved request.
    func repairPython(_ root: String, actor: String = "you") async -> (ok: Bool, message: String) {
        guard let python3 = Self.python3 else { return (false, "No python3 found on this Mac (install it with Homebrew first).") }
        guard PythonEnv.isVenv(root, exists: { FileManager.default.fileExists(atPath: $0) }) else { return (false, "\(root) is not a Python environment (no pyvenv.cfg); nothing was changed.") }
        guard case .broken = PythonEnv.health(root: root, exists: { FileManager.default.fileExists(atPath: $0) },
                                              read: { try? String(contentsOfFile: $0, encoding: .utf8) }) else { return (false, "\(root) works; nothing to repair.") }
        let lockPath = Self.lockURL(root).path
        let lock = FileManager.default.fileExists(atPath: lockPath) ? lockPath : nil
        let day = Date.now.localDay
        guard !FileManager.default.fileExists(atPath: root + ".broken-" + day) else { return (false, "A repair already ran today (\(root).broken-\(day) exists).") }
        for step in PythonEnv.repairSteps(root: root, python3: python3, lock: lock, day: day) {
            let r = await Self.runTool(step, timeout: step.contains("pip") ? 900 : 120)
            guard r.code == 0 else { return (false, "\((step[0] as NSString).lastPathComponent) failed: \(r.output.suffix(300))") }
        }
        try? await model?.liveStore?.appendAudit(actor: actor, action: "python.repaired", subject: root)
        return (true, lock == nil ? "Made a fresh one; no saved package list, so install its packages again." : "Packages put back from the saved list.")
    }
}

extension AppModel {
    /// Runs an add-on action (e.g. a Vercel redeploy) the owner approved, with a plain result line.
    func performAction(_ action: String, resource: String, params: JSONValue) async -> (ok: Bool, message: String) {
        guard let engine = engineForActions else { return (false, "The app is still starting; try again in a moment.") }
        do {
            let r = try await engine.perform(action, resource: resource, params: params)
            try? await liveStore?.appendAudit(actor: "you", action: action, subject: params[path: "project"]?.string, detail: params)
            return (true, r[path: "done"]?.string ?? "Done")
        } catch {
            return (false, (error as? WireError)?.message ?? "\(error)")
        }
    }
}

/// The venvs "Check my workspace Python" finds, each with its state and, when broken, a Repair button.
struct PythonVenvList: View {
    let extra: String?
    @State private var rows: [Routines.VenvRow] = []
    @State private var busy: String?
    @State private var note: String?
    @State private var confirm: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows, id: \.root) { row in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: row.health.isOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(row.health.isOK ? Brand.good : Brand.caution)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.root).font(.callout.monospaced()).textSelection(.enabled)
                        Text(row.usedBy.joined(separator: ", ") + { if case .broken(let why) = row.health { return " · " + why }; return "" }())
                            .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if !row.health.isOK {
                        Button("Repair…") { confirm = row.root }.disabled(busy != nil)
                    }
                }
            }
            if rows.isEmpty { Text("No Python environments found yet.").font(.callout).foregroundStyle(.secondary) }
            if let busy { HStack { ProgressView().controlSize(.small); Text("Repairing \(busy)…").font(.callout) } }
            if let note { Text(note).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
        }
        .task(id: extra) { await MacAutomations.shared.refresh(); rows = Routines.shared.venvs(extra: extra) }
        .confirmationDialog("Repair this Python environment?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Repair") {
                guard let root = confirm else { return }
                busy = root
                Task {
                    let r = await Routines.shared.repairPython(root)
                    note = r.message; busy = nil
                    rows = Routines.shared.venvs(extra: extra)
                }
            }
        } message: {
            Text("The old folder is kept as <name>.broken-<today>; a fresh one is made with this Mac's python3 and the saved packages are installed.")
        }
    }
}
