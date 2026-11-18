import AppKit
import CryptoKit
import HmunmawiCore

/// Publish: turns what the app shows into a portal page as one self-contained web page and writes it to a folder.
/// The app is the source; the page is only a copy of it. Sample data is never published.
@MainActor
enum PortalPublisher {
    static let folderKey = "HMPublishFolder"
    static let titleKey = "HMPublishTitle"
    static let lastKey = "HMPublishLast"
    static let autoKey = "HMPublishAuto"
    static let excludedKey = "HMPublishExcluded"      // section ids left out, comma separated (new ones are in)
    static let publicKey = "HMPublishPublicSafe"
    static let commandKey = "HMPublishCommand"
    static let approvedKey = "HMPublishCommandApproved" // the exact command text you approved
    static let lastUploadKey = "HMPublishLastUpload"
    static let uploadNoteKey = "HMPublishUploadNote"
    static let keepDays = 8
    static let uploadEvery: TimeInterval = 2 * 3600   // 12 a day at most: well inside Cloudflare's 500 a month

    static var excluded: Set<String> {
        get { Set((UserDefaults.standard.string(forKey: excludedKey) ?? "").split(separator: ",").map(String.init)) }
        set { UserDefaults.standard.set(newValue.sorted().joined(separator: ","), forKey: excludedKey) }
    }
    static var publicSafe: Bool { UserDefaults.standard.bool(forKey: publicKey) }
    static var command: String { (UserDefaults.standard.string(forKey: commandKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    /// The approval is a signature of the exact text with the app's own key (Keychain), like every other approval:
    /// a preference changed from outside the app can't approve a command.
    static func signature(_ cmd: String) -> String? {
        guard let key = AppModel.trustKey(KeychainSecretStore()) else { return nil }
        return HMAC<SHA256>.authenticationCode(for: Data(("portal-upload|" + cmd).utf8), using: key).map { String(format: "%02x", $0) }.joined()
    }
    static var commandApproved: Bool {
        guard !command.isEmpty, let sig = signature(command) else { return false }
        return UserDefaults.standard.string(forKey: approvedKey) == sig
    }
    static func approve(_ cmd: String) {
        if let sig = signature(cmd) { UserDefaults.standard.set(sig, forKey: approvedKey) }
    }

    /// Default: a "Portal" folder in the app's data folder (private to this Mac).
    static var defaultFolder: URL { URL.hmSupport.appending(path: "Portal", directoryHint: .isDirectory) }
    static var folder: URL {
        UserDefaults.standard.string(forKey: folderKey).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultFolder
    }
    static var title: String {
        let t = (UserDefaults.standard.string(forKey: titleKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "My apps" : String(t.prefix(60))
    }
    static var lastPublished: Date? {
        let t = UserDefaults.standard.double(forKey: lastKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    static func resource(_ file: String) -> String {
        let name = "Hmunmawi_HmunmawiApp.bundle"
        let exe = Bundle.main.executableURL?.deletingLastPathComponent()
        let places = [exe?.appending(path: name), Bundle.main.resourceURL?.appending(path: name), Bundle.main.bundleURL.appending(path: name),
                      Bundle.main.resourceURL].compactMap { $0 }
        for dir in places {
            for sub in [file, "Contents/Resources/" + file] {
                if let s = try? String(contentsOf: dir.appending(path: sub), encoding: .utf8), !s.isEmpty { return s }
            }
        }
        return ""
    }

    static var css: String {
        // Not Bundle.module: it traps when its bundle isn't where SwiftPM expects (inside the built .app it sits in
        // Contents/MacOS). Look in each known place instead and fall back to an unstyled page.
        let name = "Hmunmawi_HmunmawiApp.bundle"
        let exe = Bundle.main.executableURL?.deletingLastPathComponent()
        let places = [exe?.appending(path: name), Bundle.main.resourceURL?.appending(path: name), Bundle.main.bundleURL.appending(path: name),
                      Bundle.main.resourceURL].compactMap { $0 }
        for dir in places {
            for sub in ["portal.css", "Contents/Resources/portal.css"] {
                if let s = try? String(contentsOf: dir.appending(path: sub), encoding: .utf8), !s.isEmpty { return s }
            }
        }
        return ""
    }

    static func money(_ usd: Double) -> String { Money.shared.format(usd, from: "USD", decimals: 0) }

    /// The page, built from the same numbers the app's screens use.
    static func page(_ model: AppModel, now: Date = .now) -> PortalBuilder.Page {
        typealias S = PortalBuilder.Section
        typealias St = PortalBuilder.Stat
        var sections: [S] = []

        // Same wording as Today: no "All channels:" before a fact, an app's name only when it's a real app.
        let glance = StoryCards.pick(model.findings).prefix(3).map { f in
            (f.app.flatMap { $0.lowercased().hasPrefix("all ") ? nil : "\($0): " } ?? "") + StoryCards.headline(f) + "."
        }

        let t = MenuBarFacts.today(model.events, amount: { Money.shared.amount($0) })
        sections.append(S(id: "today", title: "Today",
                          meaning: MenuBarFacts.headline(t, money: { Money.shared.format($0, from: Money.shared.target, decimals: 0) })))

        if let w = model.weeklyStats() {
            var stats: [St] = []
            if let m = w.mrrUSD, m > 0 { stats.append(St(money(m), "Monthly recurring revenue", money: true)) }
            if let p = w.paying { stats.append(St(p.formatted(), "Paying subscribers")) }
            if let c = w.earnedChange { stats.append(St(c.formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always())), "Earned vs the week before")) }
            let span = (w.days.first.map(day) ?? "", w.days.last.map(day) ?? "")
            var m = S(id: "money", title: "Money", headline: money(w.earnedUSD), unit: "earned in Apple's last 7 report days",
                      stats: stats, spark: PortalBuilder.Spark(caption: "Earned each day", values: w.dailyEarnedUSD, start: span.0, end: span.1),
                      details: [("Week before", money(w.earnedBeforeUSD))])
            m.moneyHeadline = true; m.moneySpark = true
            sections.append(m)
            let tiles = w.apps.filter { $0.downloads > 0 || $0.earnedUSD > 0 }.prefix(9).map { a in
                PortalBuilder.Tile(name: a.name, headline: Int(safe: a.downloads).formatted(), unit: "downloads, 7 days",
                                   stats: a.earnedUSD > 0 ? [St(money(a.earnedUSD), "Earned, 7 days", money: true)] : [])
            }
            if !tiles.isEmpty { sections.append(S(id: "apps", title: "Apps", tiles: Array(tiles))) }
            var dl: [St] = []
            if let c = w.downloadsChange { dl.append(St(c.formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always())), "vs the week before")) }
            sections.append(S(id: "downloads", title: "Downloads", headline: Int(safe: w.downloads).formatted(),
                              unit: "first downloads in Apple's last 7 report days", stats: dl,
                              spark: PortalBuilder.Spark(caption: "First downloads each day", values: w.dailyDownloads, start: span.0, end: span.1),
                              details: [("Week before", Int(safe: w.downloadsBefore).formatted())]))
        }

        let facts = OverviewFacts(model: model)
        var health: [St] = []
        if let cf = facts.crashFree { health.append(St(String(format: "%.1f%%", cf), "Crash-free sessions")) }
        health.append(St("\(model.status.connections.filter(\.healthy).count) of \(model.status.connections.count)", "Connections working"))
        var h = S(id: "health", title: "Health", meaning: model.truth.headline, stats: health, lines: Array(model.truth.problems.prefix(5)))
        h.privateLines = true
        sections.append(h)

        // Each project's own sections (websites, socials), one card each, by their order.
        let custom = model.snapshots("section.snapshot").compactMap(CustomSection.init)
            .filter { $0.into == nil && ($0.outcome != nil || !$0.figures.isEmpty) }
            .sorted { ($0.order, $0.title) < ($1.order, $1.title) }
        // Two projects can send a section with the same title ("From website to money"): name the project then.
        let repeated = Set(Dictionary(grouping: custom.prefix(12), by: \.title).filter { $0.value.count > 1 }.keys)
        for c in custom.prefix(12) {
            let stats = c.figures.prefix(3).map { f in St(figure(f.value, f.format), f.label, money: f.format == "usd" || f.format == "inr") }
            sections.append(S(id: "s-" + c.id, title: repeated.contains(c.title) && !c.app.isEmpty ? "\(c.title) · \(c.app)" : c.title, meaning: c.outcome.map { $0 + "." }, stats: Array(stats)))
        }

        sections += extraSections(model)

        let feed = MenuBarFacts.feed(model.events, limit: 8).map { e in
            "\(EventText.describe(e)) · \(Ago.text(millis: e.occurredAt))"
        }
        var latest = S(id: "latest", title: "Latest", lines: feed)
        latest.privateSection = true
        sections.append(latest)

        let updated = "Updated " + now.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())
        return PortalBuilder.Page(product: title, updated: updated, glance: Array(glance), sections: sections)
    }

    /// Every section that has something now, for the tick list (id, title).
    /// Building the page takes a moment, so the list is kept until the data changes (Settings redraws often).
    @MainActor private static var availableCache: (key: String, list: [(id: String, title: String)])?
    @MainActor static func available(_ model: AppModel) -> [(id: String, title: String)] {
        let key = "\(model.events.count)-\(model.events.map(\.id).max() ?? 0)-\(model.status.lastCheck?.timeIntervalSince1970 ?? 0)"
        if let c = availableCache, c.key == key { return c.list }
        let list = page(model).sections.filter(\.hasContent).map { ($0.id, $0.title) }
        availableCache = (key, list)
        return list
    }

    /// What gets written: your ticks applied, public-safe if switched on, and the earlier copies linked.
    static func finalPage(_ model: AppModel, earlier: [(String, String)], now: Date = .now) -> PortalBuilder.Page {
        var p = page(model, now: now)
        let off = excluded
        p.sections.removeAll { off.contains($0.id) }
        if publicSafe { p = PortalBuilder.publicSafe(p) }
        p.earlier = earlier
        return p
    }

    /// "2026-11-06" → "6 Nov".
    static func day(_ iso: String) -> String {
        guard let d = try? Date(iso + "T12:00:00Z", strategy: .iso8601) else { return iso }
        return d.formatted(.dateTime.day().month(.abbreviated))
    }

    static func figure(_ v: Double, _ format: String) -> String {
        switch format {
        case "usd": money(v)
        case "inr": Money.text(v, "INR", decimals: 0)
        case "percent": (abs(v) <= 1 ? v * 100 : v).formatted(.number.precision(.fractionLength(0...1))) + "%"
        default: v.formatted(.number.precision(.fractionLength(0...1)))
        }
    }

    enum PublishError: LocalizedError {
        case sample
        var errorDescription: String? { "Sample numbers aren't published. Connect App Store Connect first." }
    }

    /// Snapshots: one dated copy a day in "Earlier copies", the last 8 days. Local only.
    static func snapshotDir(_ dir: URL) -> URL { dir.appending(path: "earlier", directoryHint: .isDirectory) }
    static func earlierCopies(_ dir: URL, today: String) -> [(String, String)] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: snapshotDir(dir).path)) ?? [])
            .filter { $0.hasSuffix(".html") && $0 != today + ".html" }.sorted(by: >)
        return names.prefix(keepDays - 1).map { n in
            let iso = String(n.dropLast(5))
            let label = (try? Date(iso + "T12:00:00Z", strategy: .iso8601))?.formatted(.dateTime.weekday(.wide).day().month(.wide)) ?? iso
            return (label, "earlier/" + n)
        }
    }
    static func pruneSnapshots(_ dir: URL) {
        let sd = snapshotDir(dir)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: sd.path)) ?? []).filter { $0.hasSuffix(".html") }.sorted(by: >)
        for n in names.dropFirst(keepDays) { try? FileManager.default.removeItem(at: sd.appending(path: n)) }
    }

    /// Writes index.html into the folder (created if needed, private to you) and returns its address.
    @discardableResult
    static func publish(_ model: AppModel) throws -> URL {
        guard !model.isDemo else { throw PublishError.sample }
        let dir = folder
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = dir.appending(path: "index.html", directoryHint: .notDirectory)
        let today = ISO8601DateFormatter.string(from: .now, timeZone: .current, formatOptions: [.withFullDate])
        let html = PortalBuilder.html(finalPage(model, earlier: earlierCopies(dir, today: today)), css: css,
                                      navCSS: resource("portal-nav.css"), navJS: resource("portal-nav.js"))
        try Data(html.utf8).write(to: file, options: .atomic)
        // Today's copy (replaced through the day), its links pointing back up a folder.
        let sd = snapshotDir(dir)
        try? FileManager.default.createDirectory(at: sd, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? Data(html.replacingOccurrences(of: "href=\"earlier/", with: "href=\"").utf8).write(to: sd.appending(path: today + ".html"), options: .atomic)
        pruneSnapshots(dir)
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: lastKey)
        return file
    }
}

/// "After publishing, run my upload command": your own command (wrangler, netlify, rsync, …) run in the portal folder
/// once you've approved that exact text. It gets a plain environment (no Hmunmawi keys), stops after 2 minutes, and
/// runs at most every 2 hours when publishing happens by itself.
@MainActor
enum PortalUpload {
    static var running = false

    static var lastUpload: Date? {
        let t = UserDefaults.standard.double(forKey: PortalPublisher.lastUploadKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
    static var note: String? { UserDefaults.standard.string(forKey: PortalPublisher.uploadNoteKey) }

    /// Called after a publish. `manual`: you pressed Publish (no 2-hour wait).
    static func afterPublish(manual: Bool, done: (@MainActor (String) -> Void)? = nil) {
        let cmd = PortalPublisher.command
        guard !cmd.isEmpty, PortalPublisher.commandApproved, !running else { return }
        if !manual, let last = lastUpload, Date.now.timeIntervalSince(last) < PortalPublisher.uploadEvery { return }
        running = true
        let dir = PortalPublisher.folder
        Task.detached {
            let result = run(cmd, in: dir)
            await MainActor.run {
                running = false
                UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: PortalPublisher.lastUploadKey)
                UserDefaults.standard.set(result, forKey: PortalPublisher.uploadNoteKey)
                done?(result)
            }
        }
    }

    nonisolated static func run(_ cmd: String, in dir: URL) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", cmd]
        p.currentDirectoryURL = dir
        let env = ProcessInfo.processInfo.environment
        p.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                         "HOME": env["HOME"] ?? NSHomeDirectory(), "USER": env["USER"] ?? "", "LANG": "en_US.UTF-8",
                         "HM_PORTAL_DIR": dir.path]
        let out = Pipe()
        p.standardOutput = out; p.standardError = out; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return "Couldn't start the upload command: \(error.localizedDescription)" }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        let text = String(decoding: data.prefix(200_000), as: UTF8.self)
        let last = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.suffix(2).joined(separator: " · ")
        let when = Date.now.formatted(.dateTime.hour().minute())
        if p.terminationReason == .uncaughtSignal { return "Upload stopped after 2 minutes (\(when))." }
        return p.terminationStatus == 0
            ? "Uploaded at \(when)." + (last.isEmpty ? "" : " \(String(last.prefix(160)))")
            : "Upload failed at \(when) (exit \(p.terminationStatus))." + (last.isEmpty ? "" : " \(String(last.prefix(200)))")
    }
}
