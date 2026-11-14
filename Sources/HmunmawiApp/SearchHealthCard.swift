import AppKit
import HmunmawiCore
import HmunmawiProtocol
import SwiftUI

/// Reads the search health report and runs its fixes through the monitor script that wrote it. Safari fixes open one
/// new tab of their own (never one of yours), stop at a sign-in or captcha, and close only that tab.
@MainActor @Observable
final class SearchHealthStore {
    static let shared = SearchHealthStore()
    static let fileKey = "HMSearchHealthFile"

    private(set) var report: SearchHealthReport?
    private(set) var reportURL: URL?
    private(set) var scriptURL: URL?
    private(set) var loadedAt: Date?
    private(set) var busy: Set<String> = []
    private(set) var notes: [String: String] = [:]
    /// The one Safari tab a fix opened (at most one at a time).
    private(set) var safari: (key: String, site: String, issue: String, fix: SearchHealthFix, window: Int, tab: Int)?
    private var modified: Date?

    var chosenFile: String? {
        get {
            // A test profile may name the file in its environment (screenshots, fresh-user checks).
            if TestProfile.name != nil, let f = ProcessInfo.processInfo.environment["HMUNMAWI_SEARCH_HEALTH_FILE"], !f.isEmpty { return f }
            return UserDefaults.standard.string(forKey: Self.fileKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.fileKey); modified = nil; reload() }
    }

    func reload() {
        let url = SearchHealth.reportURL(chosen: chosenFile)
        reportURL = url
        scriptURL = SearchHealth.scriptURL(report: url)
        guard let url else { report = nil; return }
        let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if m != nil, m == modified, report != nil { return }
        modified = m
        report = SearchHealthReport.load(from: url)
        loadedAt = .now
    }

    static func key(_ site: String, _ issue: String) -> String { site + ":" + issue }

    // MARK: Script fixes (API, AI code fix, recheck)

    func run(site: String, issue: String, fix: SearchHealthFix?) async {
        let k = Self.key(site, issue)
        guard !busy.contains(k), let args = SearchHealth.arguments(fix: fix, site: site, issue: issue) else { return }
        busy.insert(k); defer { busy.remove(k) }
        notes[k] = fix?.kind == .aiCode ? "Writing the brief for your AI…" : "Working… (a recheck can take a few minutes)"
        let (code, out) = await script(args)
        notes[k] = code == 0 ? Self.outcome(fix: fix, output: out) : "Didn't work: \(String(out.suffix(200)))"
        modified = nil; reload()
    }

    func setStatus(site: String, issue: String, kind: String, state: String, detail: String) async {
        _ = await script(SearchHealth.statusArguments(site: site, issue: issue, kind: kind, state: state, detail: detail))
        modified = nil; reload()
    }

    static func outcome(fix: SearchHealthFix?, output: String) -> String {
        let obj = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any]
        if fix?.kind == .aiCode {
            switch obj?["state"] as? String {
            case "deferred": return "Deferred: your AI is paused. It runs by itself when the pause ends and opens a PR for your OK."
            case "queued": return "Queued with your AI. It opens a PR that must pass the site checks; nothing is merged without you."
            default: return (obj?["reason"] as? String) ?? "The AI fix didn't start."
            }
        }
        if let r = obj?["recheck"] as? String { return (obj?["ok"] as? Bool == true ? "Done" : "Didn't work") + "; recheck: \(r)." }
        return "Rechecked."
    }

    private func script(_ args: [String]) async -> (Int, String) {
        guard let script = scriptURL else { return (1, "No monitor script next to this report.") }
        let root = script.deletingLastPathComponent().deletingLastPathComponent()
        let venv = root.appending(path: ".venv/bin/python")
        let python = FileManager.default.isExecutableFile(atPath: venv.path) ? venv : URL(fileURLWithPath: "/usr/bin/python3")
        return await Task.detached(priority: .utility) {
            let p = Process(), pipe = Pipe()
            p.executableURL = python
            p.arguments = [script.path] + args
            p.currentDirectoryURL = root
            p.standardOutput = pipe; p.standardError = pipe
            do { try p.run() } catch { return (1, error.localizedDescription) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (Int(p.terminationStatus), String(data: data, encoding: .utf8) ?? "")
        }.value
    }

    // MARK: Safari fixes: one tab of its own

    func openSafari(site: String, issue: String, fix: SearchHealthFix) async {
        let k = Self.key(site, issue)
        guard safari == nil, let url = fix.startURL, let src = SafariFix.openScript(url) else {
            notes[k] = safari != nil ? "Finish the open Safari fix first." : "That page isn't one Hmunmawi opens."
            return
        }
        busy.insert(k); defer { busy.remove(k) }
        // Run once, never retried: a re-run could open a second tab.
        switch await Self.osa(src) {
        case .failure(let e):
            notes[k] = "Safari didn't open the tab: \(e.message). Nothing else was touched."
        case .success(let out):
            guard let h = SafariFix.parseHandle(out) else { notes[k] = "Safari didn't say which tab it opened; check Safari."; return }
            safari = (k, site, issue, fix, h.window, h.tab)
            notes[k] = "Opened one new Safari tab. Follow the steps there; change only what they say."
            await setStatus(site: site, issue: issue, kind: "safari", state: "running", detail: "tab open: \(fix.label)")
            try? await Task.sleep(for: .seconds(5))
            if case .success(let now) = await Self.osa(SafariFix.urlScript(window: h.window, tab: h.tab)), SafariFix.needsYou(now) {
                notes[k] = "Safari wants a sign-in or a check. Hmunmawi stopped: sign in yourself in that tab, then follow the steps (or Stop)."
            }
        }
    }

    /// You finished (or stopped) the steps: close only the tab this fix opened, record it, recheck.
    func finishSafari(done: Bool) async {
        guard let s = safari else { return }
        safari = nil
        let closed = await Self.osa(SafariFix.closeScript(window: s.window, tab: s.tab))
        let leftOpen = (try? closed.get()) == "left"
        notes[s.key] = (done ? "Marked done." : "Stopped.") + (leftOpen ? " The tab had moved to another page, so it was left open for you." : " Closed the tab.")
        await setStatus(site: s.site, issue: s.issue, kind: "safari", state: done ? "done" : "failed",
                        detail: done ? "owner did: \(s.fix.label)" : "stopped by owner")
        if done { await run(site: s.site, issue: s.issue, fix: nil) }
    }

    struct OSAError: Error { let message: String }

    /// Through the owner's Safari driver (owner.json `safariDriver`, e.g. an automation helper) when set, else
    /// Hmunmawi's own Apple Events permission.
    nonisolated static func osa(_ source: String) async -> Result<String, OSAError> {
        if let driver = OwnerConfig.current.safariDriverURL, FileManager.default.isExecutableFile(atPath: driver.path) {
            return await Task.detached(priority: .userInitiated) {
                let p = Process(), out = Pipe(), err = Pipe()
                p.executableURL = driver
                p.arguments = ["-e", source]
                var env = ProcessInfo.processInfo.environment; env["ETM_OSA_TIMEOUT"] = "60"; p.environment = env
                p.standardOutput = out; p.standardError = err
                do { try p.run() } catch { return .failure(OSAError(message: error.localizedDescription)) }
                let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let text = String(data: o, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return p.terminationStatus == 0 ? .success(text)
                    : .failure(OSAError(message: String((String(data: e, encoding: .utf8) ?? "error").prefix(160))))
            }.value
        }
        return await MainActor.run {
            var error: NSDictionary?
            guard let s = NSAppleScript(source: source) else { return .failure(OSAError(message: "couldn't prepare the script")) }
            let d = s.executeAndReturnError(&error)
            if let error {
                let code = error[NSAppleScript.errorNumber] as? Int ?? 0
                return .failure(OSAError(message: code == -1743 ? "Safari isn't allowed yet (Settings → Permissions)" : "error \(code)"))
            }
            return .success(d.stringValue ?? "")
        }
    }
}

private func shTint(_ status: String?) -> Color {
    switch status { case "red": Brand.bad; case "amber": Brand.caution; case "green": Brand.good; default: .secondary }
}

private func shSeverityTint(_ s: String) -> Color {
    switch s { case "high": Brand.bad; case "moderate": Brand.caution; default: .secondary }
}

/// Today page card: each of the project's websites with its search health and the top problems. Opens the detail
/// with every problem and its Fix buttons.
struct SearchHealthCard: View {
    let project: Project?
    @State private var store = SearchHealthStore.shared
    @State private var open = false

    var body: some View {
        let sites = store.report.map { SearchHealth.sites($0, project: project?.name, members: project?.members ?? []) } ?? []
        Group {
            if !sites.isEmpty {
                KitCard {
                    CardHeader(symbol: "magnifyingglass", title: "Search health", tint: Brand.Category.web,
                               caption: "Google, Bing, AI" + (store.report?.generated.flatMap(Self.when).map { " · \($0)" } ?? ""))
                    ForEach(sites) { s in siteRow(s) }
                    HStack {
                        Button { open = true } label: { Label("Problems and fixes", systemImage: "wrench.and.screwdriver") }
                            .buttonStyle(.pill)
                        Spacer()
                        if store.scriptURL == nil { Text("View only").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .sheet(isPresented: $open) { SearchHealthDetail(project: project).buttonStyle(.pill).frame(minWidth: 640, minHeight: 560) }
            } else if store.report == nil, project?.kind == .website, store.reportURL == nil {
                KitCard {
                    CardHeader(symbol: "magnifyingglass", title: "Search health", tint: Brand.Category.web)
                    Text("Point Hmunmawi at a search health file (search_health.json) your monitor writes to see Google, Bing and AI-search problems here.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Choose file…") { SearchHealthDetail.choose() }.buttonStyle(.pill)
                }
            }
        }
        .task {
            while !Task.isCancelled { store.reload(); try? await Task.sleep(for: .seconds(60)) }
        }
    }

    private func siteRow(_ s: SearchHealthSite) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(shTint(s.status)).frame(width: 9, height: 9)
                Text(s.name).font(.callout.weight(.semibold))
                Text(SearchHealth.headline(s)).font(.callout).foregroundStyle(shTint(s.status))
                Spacer()
                Text("\(s.count("high")) high · \(s.count("moderate")) moderate · \(s.count("low")) minor")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ForEach(s.issues.filter { $0.severity != "low" }.prefix(2)) { i in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•").foregroundStyle(shSeverityTint(i.severity))
                    Text(i.title).font(.caption).lineLimit(1)
                    if let st = i.fixStatus { Text("· " + st.line).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
        }
    }

    static func when(_ iso: String) -> String? {
        SearchHealth.date(iso).map { "checked \($0.formatted(.relative(presentation: .named)))" }
    }
}

/// Every problem per site, in plain words, with its Fix buttons and their status.
struct SearchHealthDetail: View {
    let project: Project?
    @State private var store = SearchHealthStore.shared
    @State private var confirm: (site: String, issue: SearchHealthIssue, fix: SearchHealthFix)?
    @Environment(\.dismiss) private var dismiss

    static func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose the search_health.json your monitor writes"
        if panel.runModal() == .OK, let url = panel.url { SearchHealthStore.shared.chosenFile = url.path }
    }

    var body: some View {
        let sites = store.report.map { SearchHealth.sites($0, project: project?.name, members: project?.members ?? []) } ?? []
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Search health").font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }
            }.padding(20)
            if let s = store.safari { safariBar(s.fix) }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(sites) { site in siteSection(site) }
                    Text(store.scriptURL == nil
                         ? "View only: there's no monitor script next to this file, so fixes can't run from here."
                         : "API fixes and rechecks run the monitor script. AI code fixes go to your configured AI as a pull request that must pass the site checks; nothing is merged without you, and they wait while your AI is paused. Safari fixes open one new tab of their own and stop at any sign-in or captcha.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if OwnerConfig.current.hubURL == nil {
                        Button("Use a different file…") { Self.choose() }
                    }
                }.padding(20)
            }
        }
        .confirmationDialog(confirm?.fix.label ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible, presenting: confirm) { c in
            Button("Open one Safari tab") { Task { await store.openSafari(site: c.site, issue: c.issue.id, fix: c.fix) } }
            Button("Cancel", role: .cancel) {}
        } message: { c in
            Text((c.fix.steps ?? []).enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
                 + "\n\nHmunmawi opens the page in one new tab and does nothing else there: you do the steps.")
        }
    }

    private func safariBar(_ fix: SearchHealthFix) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Safari fix open: \(fix.label)").font(.headline)
            ForEach(Array((fix.steps ?? []).enumerated()), id: \.offset) { i, step in Text("\(i + 1). \(step)").font(.callout) }
            HStack {
                Button("I've done it: close the tab and recheck") { Task { await store.finishSafari(done: true) } }
                Button("Stop and close the tab") { Task { await store.finishSafari(done: false) } }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.caution.opacity(0.12), in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 20)
    }

    private func siteSection(_ site: SearchHealthSite) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(shTint(site.status)).frame(width: 10, height: 10)
                Text(site.name).font(.headline)
                Text(SearchHealth.headline(site)).foregroundStyle(shTint(site.status))
                Spacer()
                Button { Task { await store.run(site: site.id, issue: "_site", fix: nil) } } label: {
                    Label(store.busy.contains(SearchHealthStore.key(site.id, "_site")) ? "Checking…" : "Recheck", systemImage: "arrow.clockwise")
                }.disabled(store.scriptURL == nil || store.busy.contains(SearchHealthStore.key(site.id, "_site")))
            }
            ForEach(["bing", "gsc"], id: \.self) { src in
                if let why = site.missingReason(src) {
                    Text("\(src == "bing" ? "Bing" : "Google") figures missing: \(why)").font(.caption).foregroundStyle(Brand.caution)
                }
            }
            if let n = store.notes[SearchHealthStore.key(site.id, "_site")] { Text(n).font(.caption).foregroundStyle(.secondary) }
            if site.issues.isEmpty { Text("No problems found.").foregroundStyle(.secondary) }
            ForEach(site.issues) { i in issueRow(site, i) }
        }
    }

    private func issueRow(_ site: SearchHealthSite, _ i: SearchHealthIssue) -> some View {
        let k = SearchHealthStore.key(site.id, i.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(i.severityLabel).font(.caption.bold()).foregroundStyle(shSeverityTint(i.severity))
                Text(i.title).font(.callout.weight(.semibold))
                if let c = i.count, c > 1 { Text("\(c) pages").font(.caption).foregroundStyle(.secondary) }
            }
            if let p = i.plain { Text(p).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let st = i.fixStatus { Text("Fix: " + st.line).font(.caption).foregroundStyle(st.state == "failed" ? Brand.bad : Brand.good) }
            if let n = store.notes[k] { Text(n).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 8) {
                ForEach(i.fixPaths, id: \.self) { f in fixButton(site, i, f) }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func fixButton(_ site: SearchHealthSite, _ i: SearchHealthIssue, _ f: SearchHealthFix) -> some View {
        let k = SearchHealthStore.key(site.id, i.id)
        switch f.kind {
        case .api:
            Button { Task { await store.run(site: site.id, issue: i.id, fix: f) } } label: { Label(f.label, systemImage: "bolt.horizontal") }
                .disabled(store.scriptURL == nil || store.busy.contains(k)).help("Runs through the search engine's API, then rechecks")
        case .aiCode:
            if store.scriptURL != nil {
                Button { Task { await store.run(site: site.id, issue: i.id, fix: f) } } label: { Label(f.label, systemImage: "sparkles") }
                    .disabled(store.busy.contains(k)).help("Your AI opens a pull request; nothing is merged without you")
            } else {
                Button { copyBrief(site, i, f) } label: { Label("Copy AI brief", systemImage: "doc.on.doc") }
            }
        case .safari:
            Button { confirm = (site.id, i, f) } label: { Label(f.label, systemImage: "safari") }
                .disabled(store.safari != nil || store.busy.contains(k) || !SafariFix.isAllowed(f.startURL ?? ""))
                .help("Opens one new Safari tab; you do the steps")
        }
    }

    private func copyBrief(_ site: SearchHealthSite, _ i: SearchHealthIssue, _ f: SearchHealthFix) {
        let text = "Fix on \(site.name): \(i.title)\n\n\(i.plain ?? "")\n\nWhat to change: \(f.brief ?? f.label)\n\nOpen a pull request; don't merge it."
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        store.objectWillChangeNote(SearchHealthStore.key(site.id, i.id), "Copied the brief: paste it into your AI.")
    }
}

extension SearchHealthStore {
    func objectWillChangeNote(_ key: String, _ text: String) { notes[key] = text }
}
