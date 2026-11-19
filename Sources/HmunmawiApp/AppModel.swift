import AppKit
import CryptoKit
import Foundation
import HmunmawiCore
import Observation

struct WaitingAction: Identifiable {
    let job: Job
    let title: String
    let detail: String
    var id: Int64 { job.id }
}

struct AddOnRow: Identifiable {
    let plugin: InstalledPlugin
    var approved: Bool
    var savedSecrets: Set<String>
    var missing: [String]
    var id: String { plugin.manifest.id }
    var manifest: PluginManifest { plugin.manifest }
}

@Observable @MainActor
final class AppModel {
    var card: TodayCard?
    var apps: [AppSummary] = []
    private(set) var events: [StoredEvent] = []
    /// Newest daily snapshot per kind (one per app), built once per refresh so views never scan all events.
    private(set) var snapshotCache: [String: [StoredEvent]] = [:]

    /// A check where Apple's build or TestFlight request failed sends the version without its build facts; those
    /// come from the newest earlier reading of the same version, so one server error doesn't read as "Parked".
    nonisolated static func keepBuildFacts(_ e: StoredEvent, earlier: [StoredEvent]) -> StoredEvent {
        guard case .object(var p) = e.payload, p["build"] == nil, let version = p["version_id"],
              let prior = earlier.filter({ $0.app == e.app && $0.occurredAt < e.occurredAt
                                         && $0.payload[path: "version_id"] == version && $0.payload[path: "build"] != nil })
                                 .max(by: { $0.occurredAt < $1.occurredAt }),
              case .object(let q) = prior.payload else { return e }
        for k in ["build", "build_processing", "build_uploaded", "testflight_external", "testflight_internal"] where p[k] == nil {
            if let v = q[k] { p[k] = v }
        }
        var out = e
        out.payload = .object(p)
        return out
    }

    nonisolated private static func buildSnapshots(_ events: [StoredEvent]) -> [String: [StoredEvent]] {
        let kinds = Set(events.map(\.kind)).filter { kind in
            kind.hasSuffix(".snapshot") || kind.hasPrefix("growth.") || kind.hasPrefix("money.")
                || kind.hasSuffix(".series") || kind.hasSuffix(".changes") || kind.hasSuffix(".items")
                || kind.hasSuffix(".months") || kind.hasPrefix("automation.") || kind.hasPrefix("store.") || kind == "outreach.due" || kind == "plan.step" || kind == "asc.access" || kind == "release.check" || kind == "asc.watch"
        }
        // Lists (many items per app per day) keep the whole day; sections keep only the newest snapshot per app.
        let lists: Set<String> = ["outreach.due", "plan.step"]
        var cache: [String: [StoredEvent]] = [:]
        for kind in kinds {
            // Lists keep the newest day as a whole; everything else keeps the newest per app (an app whose
            // snapshot is a day older than another app's mustn't drop off its page).
            let day = lists.contains(kind) ? TodayBuilder.latestSnapshot(events, kind: kind) : events.filter { $0.kind == kind }
            // Custom sections: one per app and section id.
            let group: (StoredEvent) -> String = kind == "section.snapshot"
                ? { ($0.app ?? "") + "|" + ($0.payload[path: "id"]?.string ?? "") }
                : kind == "money.portal" ? { ($0.app ?? "") + "|" + $0.source } : { $0.app ?? "" }
            var chosen = lists.contains(kind) ? day
                : Dictionary(grouping: day, by: group).compactMap { $0.value.max { $0.occurredAt < $1.occurredAt } }
            if kind == "release.snapshot" { chosen = chosen.map { keepBuildFacts($0, earlier: day) } }
            cache[kind] = chosen.sorted { ($0.app ?? "") < ($1.app ?? "") }
        }
        return cache
    }
    var audit: [AuditEntry] = []
    var waiting: [WaitingAction] = []
    var status = SystemStatus()
    /// The one health answer every screen, the menu bar and notifications use (see HealthTruth).
    private(set) var truth = HealthTruth.make(connected: 0, brokenConnections: [], badChecks: [], cautionChecks: [], recovering: false, isDemo: true)
    func updateTruth() {
        let t = HealthTruth.make(self, paused: MenuBarSettings.shared.notificationsPaused)
        if t != truth {
            let before = truth
            truth = t
            MacNotifier.shared.healthChanged(from: before, to: t, model: self)
        }
    }
    /// What the insight engine found in the last 60 days, strongest first.
    private(set) var findings: [Finding] = []
    private(set) var ruleStats: [String: RuleStat] = [:]
    /// The latest self-healing result per problem kind, read from the log (survives restarts).
    private(set) var lastHeals: [String: AuditEntry] = [:]

    enum HealState: Equatable { case running, done(String), failed(String) }
    /// While the Keychain was unavailable, log entries were held back; once the key is readable they're written, signed.
    func retryTrustKey() async {
        guard let store = liveStore, await store.pendingAuditCount > 0, let key = Self.trustKey(secrets) else { return }
        await store.setTrustKey(key)
    }

    /// Remembers the newest log entry (Keychain), so the next launch can tell if the tail was cut off.
    func saveAuditHead() async {
        guard Self.trustKey(secrets) != nil, let head = try? await liveStore?.auditHead() else { return }
        TrustFlags.setText("audit-head", "\(head.id):\(head.hash)")
    }

    /// Heal scripts and the sandbox switch match what the app signed (see configSignature).
    private var configTrusted = false
    static func configSignature(_ c: AppConfig, _ key: SymmetricKey) -> String {
        let fields: [Any] = ["config", c.sandboxAddOns ?? true, (c.healScripts ?? [:]).sorted { $0.key < $1.key }.map { [$0.key, $0.value] }]
        let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return HMAC<SHA256>.authenticationCode(for: data, using: key).map { String(format: "%02x", $0) }.joined()
    }

    /// Self-healing in progress or finished, by event kind (see AppConfig.healScripts).
    private(set) var heals: [String: HealState] = [:]
    private var healedEvent: [String: Int64] = [:]
    /// A new sale, renewal, refund or review that arrived since the last refresh; the pill shows it for a few seconds.
    private(set) var flash: StoredEvent?
    private var newestMoment: Millis?
    var addOns: [AddOnRow] = []
    var errorText: String?
    var isDemo = true
    private(set) var config = AppConfig()

    let supportDirectory: URL
    private let runsEngine: Bool
    private let secrets = KeychainSecretStore()
    private var secretCatalog: SecretSourceCatalog { SecretSourceCatalog(url: supportDirectory.appending(path: SecretSourceCatalog.fileName)) }
    private var demoStore: Store?
    private(set) var liveStore: Store?
    private var host: PluginHost?
    private var engine: Engine?
    private var morningBusy = false   // the AI line takes a few seconds; a refresh meanwhile mustn't start a second story
    /// Connections whose last checks failed in a row (for the key-watch routine).
    func failingConnections() async -> [String: Int] { await engine?.failing() ?? [:] }
    func succeededConnections() async -> [String: Millis] { await engine?.succeeded() ?? [:] }
    private var loops: [Task<Void, Never>] = []
    private var loadStarted = false

    private var configURL: URL { supportDirectory.appending(path: "config.json") }
    private var currentStore: Store? { isDemo ? demoStore : liveStore }

    init(supportDirectory: URL = AppModel.defaultSupportDirectory(), runsEngine: Bool = true) {
        self.supportDirectory = supportDirectory
        self.runsEngine = runsEngine
        KeychainSecretStore.catalogURL = supportDirectory.appending(path: SecretSourceCatalog.fileName)
    }

    static func defaultSupportDirectory() -> URL {
        URL.applicationSupportDirectory.appending(path: "Hmunmawi" + (TestProfile.name.map { "-Test-" + $0 } ?? ""), directoryHint: .isDirectory)
    }

    var backupsDirectory: URL { supportDirectory.appending(path: "Backups", directoryHint: .isDirectory) }

    /// Set when a state backup was restored at launch: everything else is fetched again once add-ons are up.
    var refetchAfterRestore = false
    /// Set by any restore: the backup's time, before which re-arriving events must not alert again.
    var restoredFrom: Date?

    /// "Fetch everything again": forgets the add-ons' "already read today" marks (sales backfill, daily reads)
    /// and checks every source now. Safe to repeat: events are deduplicated, nothing is sent twice.
    func fetchEverythingAgain() async {
        // The App Store Connect add-on's "already read" notes (its own folder, and the temp folder older builds used).
        let state = supportDirectory.appending(path: "AddOnState/appstoreconnect")
        for dir in [state, FileManager.default.temporaryDirectory] {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            where ["hm-sales-", "hm-watch-", "hm-mrr-", "cadence-", "sales-day-"].contains(where: f.hasPrefix) {
                try? FileManager.default.removeItem(at: dir.appending(path: f))
            }
        }
        try? await liveStore?.appendAudit(actor: "owner", action: "backup.refetch", subject: "all sources")
        await engine?.pollEverything()
        await refresh()
    }

    func backUpIfDue() async {
        guard let liveStore else { return }
        _ = try? await Resilience.backUpIfDue(store: liveStore, settings: configURL, backups: backupsDirectory)
        await Backups.shared.runIfDue(store: liveStore)
    }

    func catchUpAfterWake() async {
        guard let engine, let liveStore else { return }
        try? await liveStore.appendAudit(actor: "app", action: "heal.caught_up", subject: "after sleep")
        // Wi-Fi usually needs a few seconds after a wake; checking at once made every add-on fail and back off.
        try? await Task.sleep(for: .seconds(20))
        await engine.pollEverything()
        await refresh()
    }

    func load() async {
        watchForReturn()
        // The dashboard and Settings both call this at launch; only the first one starts things.
        guard !loadStarted else { return }
        loadStarted = true
        do {
            let addOnsDir = supportDirectory.appending(path: "Add-ons", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: addOnsDir, withIntermediateDirectories: true)
            // The data and log folders are yours only (everything inside inherits the protection).
            for dir in [supportDirectory, URL.libraryDirectory.appending(path: "Logs/Hmunmawi")] {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            }
            Self.stage("start")
            let livePath = supportDirectory.appending(path: "hmunmawi.sqlite").path
            // No database yet = a brand-new install: it gets the starter routines switched on (see Routines.seedIfNeeded).
            let freshInstall = !FileManager.default.fileExists(atPath: livePath)
            let demoPath = supportDirectory.appending(path: "demo.sqlite").path
            let backups = backupsDirectory
            if Resilience.needsUpgrade(databaseAt: livePath) { busyNote = "Upgrading database…" }
            // Opening is done off the main thread, so the window never freezes while it runs: check the database
            // (a damaged one is restored from the newest healthy backup), keep a copy before any upgrade, then open.
            let livePathURL = supportDirectory
            let (startup, live, demo, upgradeBackup, restored) = try await Task.detached(priority: .userInitiated) {
                // Quick check at launch; the full one runs after the window is up (see below), and if it ever
                // finds damage, the next launch does the full check and restores from a backup.
                let restored = Backups.applyPending(support: livePathURL)
                let full = UserDefaults.standard.bool(forKey: "HMFullCheckNextLaunch")
                let startup = try Resilience.prepare(databaseAt: livePath, backups: backups, full: full)
                if full { UserDefaults.standard.set(false, forKey: "HMFullCheckNextLaunch") }
                let upgradeBackup = try? Resilience.backUpBeforeUpgrade(databaseAt: livePath, backups: backups)
                return (startup, try Store(path: livePath), try Store(path: demoPath), upgradeBackup ?? nil, restored)
            }.value
            Self.stage("database opened")
            busyNote = nil
            try await DemoData.seedIfEmpty(demo)
            // The key first, so even these early entries are signed (an unsigned one after signed ones reads as tampering).
            await live.setTrustKey(Self.trustKey(secrets))
            await live.setRequireSignedApprovals(true)   // no key (Keychain silent): approvals are not trusted, never waved through
            if let upgradeBackup { try? await live.appendAudit(actor: "app", action: "heal.upgrade_backup", subject: upgradeBackup) }
            if let restored {
                try? await live.appendAudit(actor: "owner", action: "backup.restored", subject: restored.file,
                                            detail: .object(["kept_newer_rows": .number(Double(restored.kept))]))
                Backups.shared.noteRestored(restored.file, kept: restored.kept)
                refetchAfterRestore = restored.state   // a state backup holds only what can't be fetched: fetch the rest
                restoredFrom = restored.madeAt
            }
            switch startup {
            case .healthy: break
            case .restored(let file):
                try? await live.appendAudit(actor: "app", action: "heal.restored", subject: file)
            case .startedFresh(let aside):
                try? await live.appendAudit(actor: "app", action: "heal.fresh_start", subject: aside)
            case .restoredState(let file, let madeAt):
                // Only what can't be fetched came back: fetch the rest, quietly for events before the backup.
                try? await live.appendAudit(actor: "app", action: "heal.restored_state", subject: file)
                refetchAfterRestore = true
                restoredFrom = madeAt
            }
            // A restore chosen in Settings that couldn't be applied: say why (nothing was changed).
            let failedNote = Resilience.restoreFailedFile(supportDirectory)
            if let why = try? String(contentsOf: failedNote, encoding: .utf8) {
                try? FileManager.default.removeItem(at: failedNote)
                try? await live.appendAudit(actor: "app", action: "backup.restore_failed", subject: why)
                Self.logStartup("restore failed: \(why)")
                Backups.shared.noteRestoreFailed(why)
            }
            Self.stage("before daily backup")
            _ = try? await Resilience.backUpIfDue(store: live, settings: configURL, backups: backupsDirectory)
            Self.stage("before settings load")
            config = try AppConfig.load(from: configURL)
            Routines.shared.seedIfNeeded(freshInstall: freshInstall)
            Routines.shared.start(model: self)
            // The weekly digest rule is switched on once for you (Monday 9 am by iMessage); deleting it is respected.
            // Only once iMessage is set up (a new install without it adds the digest later from Automations; no text is sent before then).
            if !UserDefaults.standard.bool(forKey: "HMWeeklyDigestAdded"), !freshInstall || config.plugins["imessage"]?.isEmpty == false {
                if !config.rules.contains(where: { $0.id == "tpl-weekly-digest" }) {
                    var r = RuleTemplates.notify("tpl-weekly-digest", "story.weekly", "imessage")
                    r.name = "The weekly digest"
                    config.rules.append(r)
                    try? config.save(to: configURL)
                }
                UserDefaults.standard.set(true, forKey: "HMWeeklyDigestAdded")
                // The first one is the next scheduled time, never a late one for a week that's already gone.
                if let slot = WeeklySchedule.dueSlot(now: .now, weekday: Self.digestWeekday, hour: Self.digestHour) {
                    UserDefaults.standard.set(slot.localDay, forKey: "HMWeeklyDigestSent")
                }
            }
            // Keys saved by an older Hmunmawi (older Keychain name) come across first, then file-backed ones.
            LegacySecretMigrator.migrateKeychain(into: secrets)
            // File-backed ones are imported in the background once the window is up (see `startSecretRebind`): a key
            // file in a protected folder can make macOS show a permission prompt, and that must never freeze launch.
            // Trust settings are signed with a key only Hmunmawi keeps (Keychain): agent permissions and add-on
            // approvals changed outside the app don't count. Today's are trusted once, when this is first on.
            let trust = Self.trustKey(secrets)
            await live.setTrustKey(trust)
            if let trust {
                let keyB64 = trust.withUnsafeBytes { Data($0) }.base64EncodedString()
                let prevKeyB64 = UserDefaults.standard.string(forKey: "HMTrustKeyB64")
                if let prevKeyB64, prevKeyB64 != keyB64 {
                    let n = (try? await live.resignAllApprovals()) ?? 0
                    if n > 0 {
                        try? await live.appendAudit(actor: "app", action: "trust.approvals_rebound",
                                                    subject: "\(n) add-ons",
                                                    detail: .object(["note": .string("Approvals were re-signed after the app's trust key changed (for example a new Developer certificate).")]))
                    }
                }
                UserDefaults.standard.set(keyB64, forKey: "HMTrustKeyB64")
            }
            if let trust {
                _ = try? await live.signUnsignedApprovals()
                if !TrustFlags.isSet("trust-signed", legacyDefaultsKey: "HMTrustSigned") {
                    AgentPolicy.shared.signCurrent(trust)
                    TrustFlags.set("trust-signed")
                }
            }
            if !AgentPolicy.shared.verify(trust) {
                try? await live.appendAudit(actor: "app", action: "trust.agent_policy_changed",
                                            subject: trust == nil ? "Keychain unavailable" : "changed outside Hmunmawi",
                                            detail: .object(["note": .string("Agents may do nothing without your OK until you set their permissions again in Settings → Rules.")]))
            }
            if trust == nil { try? await live.appendAudit(actor: "app", action: "trust.keychain_unavailable", subject: "approvals not checked this session") }
            // The two settings that can run your own scripts or switch the add-on sandbox off are signed too; changed
            // in config.json outside the app, they're not used (sandbox stays on, no heal scripts) until set in the app.
            if let trust, !TrustFlags.isSet("config-signed", legacyDefaultsKey: "HMConfigTrustSigned") {
                UserDefaults.standard.set(Self.configSignature(config, trust), forKey: "HMConfigTrustSig")
                TrustFlags.set("config-signed")
            }
            configTrusted = trust.map { UserDefaults.standard.string(forKey: "HMConfigTrustSig") == Self.configSignature(config, $0) } ?? false
            if !configTrusted, config.sandboxAddOns == false || !(config.healScripts ?? [:]).isEmpty {
                try? await live.appendAudit(actor: "app", action: "trust.config_changed", subject: "heal scripts / sandbox",
                                            detail: .object(["note": .string("Changed outside Hmunmawi: the sandbox stays on and no heal script runs until you set them in the app.")]))
            }
            // The activity log is checked once per launch: any entry changed, removed or re-ordered outside the app
            // is named (security audit, Nov 2026). From the first signed entry on, unsigned rewrites show up too.
            if trust != nil {
                let signedBefore = TrustFlags.isSet("audit-signed", legacyDefaultsKey: "HMAuditSigned")
                // Named once per break, not again at every launch.
                if let broken = try? await live.firstBrokenAuditEntry(requireSigned: signedBefore),
                   TrustFlags.text("audit-broken-at") != String(broken) {
                    TrustFlags.setText("audit-broken-at", String(broken))
                    try? await live.appendAudit(actor: "app", action: "trust.audit_log_changed", subject: "entry \(broken)",
                                                detail: .object(["note": .string("The activity log doesn't match its signatures at or after this entry: it was changed outside Hmunmawi, or the Keychain was unavailable when it was written.")]))
                }
                // The newest entry as of last time must still be there (cutting off the tail leaves a valid chain).
                if let saved = TrustFlags.text("audit-head"), let sep = saved.firstIndex(of: ":"),
                   let id = Int64(saved[..<sep]),
                   (try? await live.auditEntryExists(id: id, hash: String(saved[saved.index(after: sep)...]))) == false {
                    try? await live.appendAudit(actor: "app", action: "trust.audit_log_changed", subject: "newest entries removed",
                                                detail: .object(["note": .string("Entries written after the last check are missing from the activity log.")]))
                }
                await saveAuditHead()
                TrustFlags.set("audit-signed")
            }
            AgentBridge.shared.start(model: self)
            OfferCodes.shared.importPendingPortalFile()
            Money.shared.setTarget(config.displayCurrency)
            Task { await Money.shared.load() }

            Self.stage("before add-ons")
            let host = PluginHost(store: live, gate: NetworkGate(secrets: secrets),
                                  logsDirectory: URL.libraryDirectory.appending(path: "Logs/Hmunmawi"),
                                  mac: AppMacAbilities())
            await host.setStagingDirectory(supportDirectory.appending(path: "AddOnRun", directoryHint: .isDirectory))
            await host.discover(in: [Bundle.main.resourceURL?.appending(path: "Add-ons"), addOnsDir].compactMap { $0 })
            for plugin in await host.plugins {
                await host.setSettings(config.settingsJSON(for: plugin.manifest.id), for: plugin.manifest.id)
            }
            await host.setSandbox(configTrusted ? (config.sandboxAddOns ?? true) : true)
            await live.setQuietHours(config.quietHours ?? .standard)
            Self.stage("before engine")
            let engine = Engine(store: live, host: host, rules: config.rules, stamps: TestProfile.name == nil ? .standard : .memory())

            demoStore = demo
            liveStore = live
            await Fixtures.seedNoHub(live)
            self.host = host
            self.engine = engine
            // After any restore (full or "Your data"), before the first check: events from before the backup were
            // already alerted on once, so they're stored quietly when they come back.
            if let made = restoredFrom {
                let ids = Set(await host.plugins.filter { $0.manifest.poll != nil }.map(\.manifest.id))
                await engine.quietBefore(Millis(made.timeIntervalSince1970 * 1000), addOns: ids)
                restoredFrom = nil
            }
            if runsEngine {
                loops.append(Task.detached { await engine.run() })
                loops.append(Task { [weak self] in
                    var ticks = 0
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(20))
                        await self?.localFeeds(ticks)
                        ticks += 1
                        // A window on screen refreshes every 20 s; with none showing (closed, hidden or covered),
                        // every 5 minutes, which still feeds story, status and fix-script alerts. Screens catch up
                        // the moment the app comes forward (MainView refreshes on activation).
                        if Self.windowOnScreen() || ticks % 15 == 0 { await self?.refresh() }
                        // Measured Claude API spend for "Costs a month": every 30 minutes, whether or not a screen shows it.
                        if ticks % 90 == 1 { await Credits.shared.refreshLive(); await AIAccounts.shared.refreshAll() }
                        await self?.backUpIfDue()
                    }
                })
                // After the Mac wakes, every add-on checks in at once instead of waiting for its timer.
                loops.append(Task { [weak self] in
                    for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification) {
                        await self?.catchUpAfterWake()
                    }
                })
            }
            await refreshAddOns()
            startSecretRebind()
            startLivePurchases()
            ProjectStore.shared.onChange = { [weak self] in Task { await self?.refresh() } }
            Self.stage("before first refresh")
            await refresh()
            Self.stage("ready")
            if refetchAfterRestore { refetchAfterRestore = false; Task { [weak self] in await self?.fetchEverythingAgain() } }
            Diagnostics.shared.start(store: live)
            // The complete database check, in the background after launch.
            Task.detached(priority: .background) { [weak self] in
                guard Resilience.health(livePath) == .damaged else { return }
                UserDefaults.standard.set(true, forKey: "HMFullCheckNextLaunch")
                Self.logStartup("background check: database damage found; restoring at next launch")
                await MainActor.run { self?.startError = "The database check found damage. Quit and reopen Hmunmawi to restore it from the latest backup." }
            }
        } catch {
            busyNote = nil
            startError = (error as? SQLiteError).map { "Hmunmawi couldn't start. \($0.plain)" } ?? "Hmunmawi couldn't start: \(error)"
            errorText = startError
            Self.logStartup(startError ?? "")
        }
    }

    /// A startup that failed, shown across the window (never only on one card) with a Retry.
    var startError: String?

    /// Tries starting again after a failure (e.g. once a locked or busy database is free).
    func retryStart() async {
        startError = nil; errorText = nil; loadStarted = false
        await load()
    }

    /// Each startup stage with the time since launch, in app.log (finds a slow or stuck step).
    @ObservationIgnored static let launchClock = ContinuousClock.now
    static func stage(_ name: String) {
        let ms = (ContinuousClock.now - launchClock).components
        logStartup(String(format: "startup %@ +%.0f ms", name, Double(ms.seconds) * 1000 + Double(ms.attoseconds) / 1e15))
    }

    /// Startup problems go to ~/Library/Logs/Hmunmawi/app.log too, so they can be found later.
    nonisolated static func logStartup(_ text: String) {
        let dir = URL.libraryDirectory.appending(path: "Logs/Hmunmawi")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "app.log")
        let line = "\(Date.now.formatted(.iso8601)) \(text)\n"
        if let h = try? FileHandle(forWritingTo: file) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: file, atomically: true, encoding: .utf8) }
    }

    @ObservationIgnored private var eventsSignature = ""

    /// Daily figures can arrive from two places (a native connection and a script feed, e.g. your own scripts): keep one
    /// per app per day, the newest, so nothing is counted twice.
    /// Every metric in the last 60 days, across all projects (for judging changes). Worked out off the main thread.
    func historyMetrics() async -> [Metric] {
        let rows = Self.oneSourcePerDay(insightWindow.rows)
        return await Task.detached(priority: .utility) { MetricExtractor.extract(rows) }.value
    }

    nonisolated static func oneSourcePerDay(_ events: [StoredEvent]) -> [StoredEvent] { DailyEvents.oneSourcePerDay(events) }

    /// One refresh at a time: a call while one runs asks for one more pass afterwards (never two at once, which
    /// could update the in-memory window twice).
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshAgain = false
    /// The last 9 days of events in memory; each refresh fetches only what's new (see EventWindow).
    @ObservationIgnored private var window = EventWindow(days: 9)
    /// 60 days for insights, lean: loaded once, then only new rows are read.
    @ObservationIgnored private var insightWindow = EventWindow(days: 60, lean: true)
    @ObservationIgnored private var insightsProject: String?? = .none
    /// Monthly recurring revenue per app and in total, with its 30/90-day projection (nil until the first report).
    private(set) var mrr: MRRSummary?
    /// Per app: trials, cancels, failed payments, refunds and renewal by plan (Apple's Subscription Event report).
    private(set) var subTruth: [String: SubscriptionTruth] = [:]
    /// Countries whose subscribers pay well under the app's usual amount each (a Playbook tip).
    private(set) var countryFlags: [CountryValue] = []
    @ObservationIgnored private var windowStore: ObjectIdentifier?
    /// True once insights have been worked out at least once (digests wait for it, so they're never empty).
    @ObservationIgnored private var insightsReady = false
    /// The last weekly digest text (what agents read; worked out once a week, never on every refresh).
    @ObservationIgnored private(set) var lastDigestText: String?
    /// The newest stored event id the screens have seen (changes whenever anything new is stored). Observed, so
    /// views keyed on it (Payday) redraw and reload when it moves.
    private(set) var windowLastID: Int64 = 0

    func refresh() async {
        if refreshing { refreshAgain = true; return }
        refreshing = true
        defer { refreshing = false }
        repeat {
            refreshAgain = false
            await refreshOnce()
        } while refreshAgain
    }

    private func refreshOnce() async {
        guard let store = currentStore else { return }
        do {
            let nowMs = Millis(Date.now.timeIntervalSince1970 * 1000)
            if windowStore != ObjectIdentifier(store) { window.reset(); insightWindow.reset(); windowStore = ObjectIdentifier(store) }
            var w = window
            try await w.update(from: store, now: nowMs)
            window = w
            if w.lastID != windowLastID { windowLastID = w.lastID }
            let recent = w.rows
            let all: [StoredEvent] = Self.oneSourcePerDay(recent.filter { $0.occurredAt > nowMs - 8 * TodayBuilder.day }
                .reversed())
            ProjectStore.shared.suggest(from: all)
            // The selected project only (all projects when none is picked).
            let fresh = all.filter { ProjectStore.shared.shows($0.app) }
            // Every 20 s this runs; when no event came in, nothing the screens draw from is replaced, so SwiftUI
            // has nothing to redraw and an open window stays at ~0% CPU.
            // The window's newest id is part of it: a re-count of an older day replaces a row without changing the
            // count or the first/last ids.
            // Which launchd jobs are failing right now: when one recovers on its own, the card is rebuilt (its
            // old failure stops being Today's worry) even though no new event came in.
            if MacAutomations.shared.lastRead == nil || Date.now.timeIntervalSince(MacAutomations.shared.lastRead!) > 300 {
                await MacAutomations.shared.refresh()
            }
            let jobStates = HealthCheck.macJobStates(), jobsReadAt = HealthCheck.macReadAt()
            let failingJobs = jobStates.filter { $0.value == "failed" }.keys.sorted().joined(separator: ",")
            let signature = "\(failingJobs)|\(ProjectStore.shared.selectedID ?? "all")|\(fresh.count)|\(fresh.first?.id ?? 0)|\(fresh.last?.id ?? 0)|\(w.lastID)|\(String(describing: store === liveStore))|\((try? await store.cardJobsFingerprint()) ?? "")"
            // Insights look back 60 days, so late reports for older days (a sales backfill) count too: the window
            // is brought up to date on every refresh, and insights re-run only when it changed.
            var iw = insightWindow
            let insightsChanged = try await iw.update(from: store, now: nowMs)
            insightWindow = iw
            if insightsChanged || signature != eventsSignature || insightsProject != ProjectStore.shared.selectedID {
                insightsProject = ProjectStore.shared.selectedID
                let mrrRows = iw.rows.filter { $0.kind == "subscription.mrr" && ProjectStore.shared.shows($0.app) }
                mrr = await Task.detached(priority: .utility) { MRRSummary(mrrRows) }.value
                // Apple's subscription events go back up to a year (renewal by plan), beyond the insight window.
                let subRows = ((try? await store.events(kind: "subscription.events", since: 0)) ?? []).filter { ProjectStore.shared.shows($0.app) }
                let dailyRows = iw.rows.filter { $0.kind == "revenue.daily" && ProjectStore.shared.shows($0.app) }
                (subTruth, countryFlags) = await Task.detached(priority: .utility) {
                    (SubscriptionTruth.make(subRows), CountryValue.flags(mrr: mrrRows, daily: dailyRows, subs: subRows))
                }.value
                let history: [StoredEvent] = Self.oneSourcePerDay(iw.rows).filter { ProjectStore.shared.shows($0.app) }
                findings = await Task.detached(priority: .utility) { InsightEngine.run(MetricExtractor.extract(history)) }.value
                insightsReady = true
            }
            if signature != eventsSignature {
            eventsSignature = signature
            // The picked project only, like every other number on screen (all projects when none is picked).
            let scoped = recent.filter { ProjectStore.shared.shows($0.app) }
            // A Mac job that failed and has since run fine again isn't Today's worry (Health already says so).
            card = try await store.today(recent: JobFailures.withoutRecovered(scoped, states: jobStates, readAt: jobsReadAt))
            apps = await store.appSummaries(recent: scoped)
            // Sorting and grouping happen off the main thread; the screen only receives the finished lookup.
            var cache = await Task.detached(priority: .userInitiated) { Self.buildSnapshots(fresh) }.value
            // Apps the script feed doesn't describe get their page from Hmunmawi's own add-on data (see NativeApps).
            // Two weeks of daily sales are read for it, because the in-memory window is shorter.
            let salesRows = (try? await store.events(kind: "revenue.daily", since: Millis(Date.now.addingTimeInterval(-15 * 86_400).timeIntervalSince1970 * 1000))) ?? []
            let native = NativeApps.snapshots(events: fresh + salesRows, short: { ComingSoon.shortName($0) })
            if !native.isEmpty { cache["app.snapshot"] = (cache["app.snapshot"] ?? []) + native }
            events = fresh
            snapshotCache = cache
            APPName.known = (cache["app.snapshot"] ?? []).compactMap(\.app)
            WorldWatch.developerSites = ProjectStore.shared.projects.flatMap(\.members).filter { $0.contains(".") && !$0.contains(" ") }
            await postStoryEvents()
            await checkRatingDrops()
            await checkQuotas()
            PublicRatings.runIfDue(model: self)
            ruleStats = (try? await liveStore?.ruleStats()) ?? [:]
            lastHeals = (try? await liveStore?.latestHeals()) ?? [:]
            noticeNewMoment(in: fresh)
            healIfNeeded(fresh)
            }
            await postMorningStory()
            await postWeeklyDigest()
            let rules = config.rules + DemoData.rules
            var actions: [WaitingAction] = []
            for job in try await store.jobs(in: .waitingApproval) {
                let event: StoredEvent? = if let id = job.eventID { try await store.event(id) } else { nil }
                let ruleName = rules.first { $0.id == job.ruleID }?.name
                actions.append(WaitingAction(job: job, title: JobText.title(job),
                                             detail: JobText.detail(job, event: event, ruleName: ruleName)))
            }
            // Assigned only when something differs: every assignment redraws the screens that read it, and this
            // runs every 20 s.
            // Sample data is never something to approve: its made-up jobs are not shown as waiting for you.
            if isDemo { actions = [] }
            if actions.map({ "\($0.id)|\($0.title)|\($0.detail)" }) != waiting.map({ "\($0.id)|\($0.title)|\($0.detail)" }) { waiting = actions }
            // Under 1 GB free, saving can fail: say so instead of failing quietly.
            let free = (try? URL.applicationSupportDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage ?? Int64.max
            let low = free < 1_000_000_000
            if low != lowDisk { lowDisk = low }
            // Computed once per refresh; screens read these instead of recomputing them on every draw.
            await Permissions.shared.refreshIfStale(from: self)
            let checks = HealthCheck.checks(self, permissions: Permissions.shared.snapshot), trend = HealthCheck.crashTrend(self)
            if checks.map(\.signature) != healthChecks.map(\.signature) { healthChecks = checks }
            if trend.map(\.1) != crashTrend.map(\.1) || trend.map(\.0) != crashTrend.map(\.0) { crashTrend = trend }
            // Daily proceeds by month and app for the "Earned by month" chart, from the store (older than the
            // events kept in memory). One source per day: the App Store Connect connection wins over a script feed.
            if let store = liveStore {
                let since = Millis(Date.now.addingTimeInterval(-400 * 86_400).timeIntervalSince1970 * 1000)
                let rows = (try? await store.events(kind: "revenue.daily", since: since)) ?? []
                var best: [String: StoredEvent] = [:]
                for e in rows {
                    guard let day = e.payload[path: "day"]?.string else { continue }
                    let k = day + "|" + APPName.pretty(e.app ?? "App")
                    if let old = best[k], old.source == "appstoreconnect", e.source != "appstoreconnect" { continue }
                    best[k] = e
                }
                var byMonth: [String: [String: Double]] = [:]
                for (_, e) in best {
                    guard let day = e.payload[path: "day"]?.string, day.count >= 7, let v = e.payload[path: "proceeds_usd"]?.number else { continue }
                    byMonth[String(day.prefix(7)), default: [:]][APPName.pretty(e.app ?? "App"), default: 0] += v
                }
                if byMonth != dailyProceeds { dailyProceeds = byMonth }
            }
            // Fatal freezes for the Stability card: read-only, every 3 hours, tracked only (no events, no alerts).
            if !isDemo {
                FreezeWatch.shared.load(from: supportDirectory)
                let secrets = self.secrets
                FreezeWatch.shared.refreshIfDue(enabled: addOns.contains { $0.id == "sentry" && $0.approved },
                                                settings: config.settingsJSON(for: "sentry"),
                                                token: { try secrets.secret(plugin: "sentry", name: "authToken") })
            }
            AgentBridge.shared.publishState()
            let newAudit = try await store.recentAudit(limit: 100)
            if newAudit.first?.id != audit.first?.id || newAudit.count != audit.count || newAudit.last?.id != audit.last?.id { audit = newAudit }
            if let liveStore {
                let s = SystemStatus.make(audit: try await liveStore.recentAudit(limit: 400),
                                          addOns: addOns, backups: backupsDirectory)
                if String(describing: s) != String(describing: status) { status = s }
            }
            updateTruth()
            MacNotifier.shared.consider(events: events, model: self)
            if !isDemo, !TestProfile.runningUnitTests { Task { await PayoutBook.shared.autoFillIfDue() } }
            // Settings → Publish → "Publish again after each refresh". Quiet on failure; the tab shows the last time.
            if UserDefaults.standard.bool(forKey: PortalPublisher.autoKey), !isDemo, !TestProfile.runningUnitTests {
                if (try? PortalPublisher.publish(self)) != nil { PortalUpload.afterPublish(manual: false) }
            }
        } catch {
            errorText = "Couldn't refresh: \(plainError(error))"
            Self.logStartup("refresh failed: \(error)")
        }
    }

    /// Runs the configured fix once for each new problem event (a day at most), measuring free disk space
    /// before and after, and logs the result so the status pill lists it under "Healed automatically".
    private func healIfNeeded(_ events: [StoredEvent]) {
        let dayAgo = Millis(Date.now.timeIntervalSince1970 * 1000) - TodayBuilder.day
        for (kind, script) in configTrusted ? (config.healScripts ?? [:]) : [:] {
            guard let latest = events.filter({ $0.kind == kind && $0.occurredAt > dayAgo }).max(by: { $0.occurredAt < $1.occurredAt }),
                  healedEvent[kind] != latest.id, heals[kind] != .running else { continue }
            // Each warning is healed once, remembered across restarts.
            let remembered = "HMHealed.\(kind)"
            if Int64(UserDefaults.standard.integer(forKey: remembered)) == latest.id {
                healedEvent[kind] = latest.id
                continue
            }
            healedEvent[kind] = latest.id
            UserDefaults.standard.set(Int(latest.id), forKey: remembered)
            let path = (script as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else {
                heals[kind] = .failed("Fix script not found"); continue
            }
            guard Self.healScriptUnchanged(kind, script) else {
                heals[kind] = .failed("The fix script changed outside the app; allow it again in Settings"); continue
            }
            heals[kind] = .running
            let store = liveStore
            Task { [weak self] in
                let before = Self.freeGB()
                let ok = await Task.detached(priority: .utility) { () -> Bool in
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/bin/bash")
                    p.arguments = [path]
                    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                    do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
                }.value
                let after = Self.freeGB()
                let freed = max(0, after - before)
                let text = !ok ? "The fix didn't finish; it will try again"
                    : kind != "disk.low" ? "Ran your fix script"
                    : freed >= 0.5 ? "Freed \(freed.formatted(.number.precision(.fractionLength(0...1)))) GB · now \(Int(after)) GB free"
                    : "Space is fine now · \(Int(after)) GB free"
                self?.heals[kind] = ok ? .done(text) : .failed(text)
                try? await store?.appendAudit(actor: "app", action: "heal.\(kind)", subject: text)
            }
        }
    }

    nonisolated static func freeGB() -> Double {
        let values = try? URL.homeDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Double(values?.volumeAvailableCapacityForImportantUsage ?? 0) / 1_000_000_000
    }

    private func noticeNewMoment(in events: [StoredEvent]) {
        let newest = TickerItems.recent(events).first
        defer { newestMoment = max(newestMoment ?? 0, newest?.occurredAt ?? 0) }
        guard let newest, let seen = newestMoment, newest.occurredAt > seen else { return }
        // Not looking (window hidden or another app in front): keep it and play it when you come back.
        // The menu bar "H" pulses either way; the window's animation is kept to replay.
        if !Self.windowInFront() { missedMoment = newest }
        showFlash(newest)
    }

    /// A sale or renewal that arrived while Hmunmawi wasn't in front; played once when you bring it back (12 h at most).
    private var missedMoment: StoredEvent?
    private var replayObserver: NSObjectProtocol?
    func watchForReturn() {
        guard replayObserver == nil else { return }
        replayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, let m = self.missedMoment else { return }
                self.missedMoment = nil
                guard Date.now.timeIntervalSince1970 * 1000 - Double(m.occurredAt) < 12 * 3_600_000 else { return }
                try? await Task.sleep(for: .milliseconds(600))   // let the window come forward first
                self.showFlash(m)
            }
        }
    }
    static func windowInFront() -> Bool {
        NSApp.isActive && NSApp.windows.contains { $0.isVisible && $0.isKeyWindow && $0.title.hasPrefix("Hmunmawi") }
    }

    private func showFlash(_ newest: StoredEvent) {
        flash = newest
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if self?.flash?.id == newest.id { self?.flash = nil }
        }
    }

    /// The "text me about refunds" rule starts off on a new install (no iMessage yet); the first time iMessage is
    /// connected it is switched on once. Your own later choice is never overridden.
    private func enableRefundTextIfIMessageReady(_ rows: [AddOnRow]) {
        let flag = "HMRefundTextAutoEnabled"
        guard !UserDefaults.standard.bool(forKey: flag),
              rows.contains(where: { $0.id == "imessage" && $0.approved && $0.missing.isEmpty }),
              let i = config.rules.firstIndex(where: { $0.id == "refund-alert" }) else { return }
        UserDefaults.standard.set(true, forKey: flag)
        guard !config.rules[i].enabled else { return }
        config.rules[i].enabled = true
        try? config.save(to: configURL)
        Task { await engine?.setRules(config.rules) }
    }

    /// Connections whose saved key file couldn't be imported (macOS refused it, or it is gone), by add-on id.
    private(set) var secretsNeedingAttention: [String] = []
    private var secretRebindDone = false

    /// Imports keys from their saved files into the Keychain off the main thread. A slow or refused read only delays
    /// this task; after `Self.secretRebindPatience` the affected connections are flagged as needing attention, and when
    /// the pass ends the add-ons check in at once with what was imported.
    func startSecretRebind(reader: SecretReadPass = SecretReadPass(), patience: Duration = secretRebindPatience) {
        secretRebindDone = false
        let store = secrets, catalog = secretCatalog
        Task.detached(priority: .utility) { [weak self] in
            let report = SecretRebinder.rebindPass(store: store, catalog: catalog, pass: reader)
            await self?.finishSecretRebind(report)
        }
        Task { [weak self] in
            try? await Task.sleep(for: patience)
            guard let self, !self.secretRebindDone else { return }
            Self.logStartup("secret rebind still waiting (a permission prompt may be open); starting without it")
            try? await self.liveStore?.appendAudit(actor: "app", action: "secrets.read_slow", subject: "key files",
                                                   detail: .object(["note": .string("Reading saved key files is taking long, possibly because macOS is asking for permission. Connections that need them are marked until it finishes.")]))
            await self.refreshAddOns()
        }
    }

    static let secretRebindPatience: Duration = .seconds(20)

    private func finishSecretRebind(_ report: SecretRebindReport) async {
        secretRebindDone = true
        secretsNeedingAttention = report.addOnIDs
        if !report.needsAttention.isEmpty {
            let refused = !report.refusedPaths.isEmpty
            Self.logStartup("secret rebind: \(report.rebound) imported, \(report.needsAttention.count) need attention\(refused ? " (macOS refused \(report.refusedPaths.count) file(s))" : "")")
            try? await liveStore?.appendAudit(actor: "app", action: refused ? "secrets.read_denied" : "secrets.read_failed",
                                              subject: report.addOnIDs.joined(separator: ", "),
                                              detail: .object(["note": .string(refused
                                                ? "macOS didn't let Hmunmawi read a saved key file. Allow it under System Settings → Privacy & Security → Files and Folders, or choose the key again in Settings."
                                                : "A saved key file couldn't be read. Choose the key again in Settings.")]))
        }
        await refreshAddOns()
        if report.rebound > 0 { await engine?.pollEverything() }
        await refresh()
    }

    func refreshAddOns(_ pass: Int = 0) async {
        guard let host else { return }
        var rows: [AddOnRow] = []
        for plugin in await host.plugins {
            let id = plugin.manifest.id
            var saved = Set<String>()
            var missing: [String] = []
            for setting in plugin.manifest.settings {
                let isSecret = setting.type.hasPrefix("secret")
                let hasValue: Bool
                if isSecret {
                    // peekSecret never reads a key file: this runs on the main thread, where a protected folder's prompt would freeze the app.
                    if let s = try? secrets.peekSecret(plugin: id, name: setting.key), !s.isEmpty {
                        hasValue = true
                    } else {
                        hasValue = secrets.secretItemExists(plugin: id, name: setting.key)
                    }
                } else {
                    hasValue = config.plugins[id]?[setting.key]?.isEmpty == false
                }
                if isSecret && hasValue { saved.insert(setting.key) }
                if setting.required == true && !hasValue { missing.append(setting.label) }
            }
            rows.append(AddOnRow(plugin: plugin, approved: (try? await host.isApproved(id)) ?? false,
                                 savedSecrets: saved, missing: missing))
        }
        // Connections you approved before whose code changed (e.g. after an update) and need your OK again.
        let ever = (try? await liveStore?.everApprovedPlugins()) ?? []
        // Ones you chose to keep off ("Keep off") don't ask again; Allow still works any time.
        let keptOff = Self.keptOff
        // Re-approve when only the helper fingerprint changed and saved settings are still complete (a rebuild).
        var rebound = false
        if pass < 3 {
            for r in rows where !r.approved && ever.contains(r.id) && r.missing.isEmpty && !keptOff.contains(r.id) {
                try? await host.approve(r.id, by: "you (re-approved after update)")
                _ = try? await liveStore?.signUnsignedApprovals()
                if (try? await host.isApproved(r.id)) == true { rebound = true }
            }
        }
        if rebound {
            await refreshAddOns(pass + 1)
            return
        }
        addOns = rows
        // First time this version sees an approved connection: remember what it may do now, for later comparison.
        for r in rows where r.approved && Self.approvedPermissions(r.id) == nil { Self.recordApproved(r.id, ApprovedPermissions(r.manifest)) }
        changedAddOns = rows.filter { !$0.approved && ever.contains($0.id) && !keptOff.contains($0.id) }.map(\.manifest.name).sorted()
        let wasDemo = isDemo
        isDemo = !Fixtures.noHub && !rows.contains { $0.approved && $0.missing.isEmpty }
        LastSeen.demo = isDemo
        enableRefundTextIfIMessageReady(rows)
        if wasDemo != isDemo { await refresh() }
        updateTruth()
    }

    /// Settings > General > Alerts: quiet hours (alerts wait; urgent rules still go out).
    var quietHours: QuietHours { config.quietHours ?? .standard }
    func setQuietHours(_ q: QuietHours) {
        config.quietHours = q
        try? config.save(to: configURL)
        Task { await liveStore?.setQuietHours(q) }
    }

    /// Settings > General > Connections run in a sandbox (applies from each one's next start).
    var sandboxAddOns: Bool { configTrusted ? (config.sandboxAddOns ?? true) : true }
    func setSandboxAddOns(_ on: Bool) {
        config.sandboxAddOns = on
        // Heal scripts that appeared outside the app are dropped, never signed along with this switch.
        if !configTrusted { config.healScripts = nil }
        try? config.save(to: configURL)
        // Set here, so it's yours: signed (heal scripts as they are now come along with it).
        if let trust = Self.trustKey(secrets) {
            UserDefaults.standard.set(Self.configSignature(config, trust), forKey: "HMConfigTrustSig")
            configTrusted = true
        }
        Task { [host] in await host?.setSandbox(on) }
    }

    /// Fix scripts (config.json "healScripts") that were added outside the app and wait for your OK before they run.
    /// Bumped when a fix script is pinned, so Settings redraws (the pins live in preferences, which SwiftUI doesn't watch).
    private(set) var healPins = 0
    var healScriptsWaiting: [String: String] {
        _ = healPins
        let all = config.healScripts ?? [:]
        return configTrusted ? all.filter { !Self.healScriptUnchanged($0.key, $0.value) } : all
    }
    /// The script's contents as of your OK (SHA-256): a script rewritten later waits for a new OK instead of running.
    nonisolated static func healHash(_ path: String) -> String? {
        guard let d = FileManager.default.contents(atPath: (path as NSString).expandingTildeInPath) else { return nil }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }
    static func pinHealScript(_ kind: String, _ path: String?) {
        UserDefaults.standard.set(path.flatMap(healHash), forKey: "HMHealHash.\(kind)")
    }
    static func healScriptUnchanged(_ kind: String, _ path: String) -> Bool {
        guard let want = UserDefaults.standard.string(forKey: "HMHealHash.\(kind)") else { return false }
        return healHash(path) == want
    }
    /// Settings > General > "Allow": signs the fix scripts as they are now, so self-healing runs them.
    func allowHealScripts() {
        guard let trust = Self.trustKey(secrets) else { return }
        UserDefaults.standard.set(Self.configSignature(config, trust), forKey: "HMConfigTrustSig")
        configTrusted = true
        for (k, v) in config.healScripts ?? [:] { Self.pinHealScript(k, v) }
        healPins += 1
        Task { [liveStore] in try? await liveStore?.appendAudit(actor: "owner", action: "trust.heal_allowed", subject: (config.healScripts ?? [:]).keys.sorted().joined(separator: ", ")) }
    }

    /// Fix scripts that run (signed by you), by problem kind.
    var healScriptsActive: [String: String] { configTrusted ? (config.healScripts ?? [:]) : [:] }
    /// Settings > General > Self-healing: add (path) or remove (nil) the fix for one kind of problem. Set here, so it's
    /// yours and signed at once; scripts that appeared outside the app are dropped, never signed along with it.
    func setHealScript(_ kind: String, _ path: String?) {
        var scripts = configTrusted ? (config.healScripts ?? [:]) : [:]
        scripts[kind] = path.map { ($0 as NSString).abbreviatingWithTildeInPath }
        config.healScripts = scripts.isEmpty ? nil : scripts
        try? config.save(to: configURL)
        if let trust = Self.trustKey(secrets) {
            UserDefaults.standard.set(Self.configSignature(config, trust), forKey: "HMConfigTrustSig")
            configTrusted = true
        }
        UserDefaults.standard.removeObject(forKey: "HMHealed.\(kind)")
        Self.pinHealScript(kind, path)
        healPins += 1
        Task { [liveStore] in try? await liveStore?.appendAudit(actor: "owner", action: path == nil ? "trust.heal_removed" : "trust.heal_set", subject: kind) }
    }

    /// Settings > General > Show money in. nil goes back to the Mac's currency.
    func setDisplayCurrency(_ code: String?) {
        config.displayCurrency = code
        try? config.save(to: configURL)
        Money.shared.setTarget(code)
    }

    /// Every new purchase recorded since Hmunmawi started keeping score (for milestone moments). Read at most
    /// every 30 minutes; the database read is cheap but there's no reason to repeat it on every refresh.
    func lifetimePurchases() async -> Int? {
        // The cache belongs to one database (switching between demo and live must not show the other's count).
        if let (at, n, s) = purchaseCountCache, s == currentStore.map(ObjectIdentifier.init),
           Date.now.timeIntervalSince(at) < 1800 { return n }
        // Counted by the database on an index (it used to load every event ever recorded to count one kind).
        guard let store = currentStore, let n = try? await store.countEvents(kind: "revenue.purchase") else { return nil }
        purchaseCountCache = (.now, n, ObjectIdentifier(store))
        return n
    }
    @ObservationIgnored private var purchaseCountCache: (Date, Int, ObjectIdentifier?)?

    /// Past purchases, newest first, read on demand from the local database (up to a year back).
    func purchaseHistory(limit: Int) async -> [StoredEvent] {
        guard let store = currentStore else { return [] }
        let since = Millis(Date.now.timeIntervalSince1970 * 1000) - 365 * TodayBuilder.day
        // Page by page, newest first, until `limit` pass the project filter (it used to load a whole year of
        // every kind). Same kinds, same filter, same order.
        var out: [StoredEvent] = [], cursor: (occurredAt: Millis, id: Int64)? = nil
        while out.count < limit {
            guard let page = try? await store.recentEvents(kinds: TickerItems.kinds, since: since, before: cursor, limit: 200),
                  let last = page.last else { break }
            out += page.filter { ProjectStore.shared.shows($0.app) }.prefix(limit - out.count)
            if page.count < 200 { break }
            cursor = (last.occurredAt, last.id)
        }
        return out
    }

    /// The story engine speaks through events, so rules can act on it: each top win and worry once a day,
    /// and one morning digest after 8 am. The store's dedupe keys keep each to once.
    /// A fall in an app's star rating over about a week becomes a `rating.drop` event (rules can alert on it) and a worry
    /// on Today. One per app and week for the same fall. Off in Settings → General → Alerts.
    private func checkRatingDrops() async {
        let d = UserDefaults.standard
        guard !isDemo, let liveStore, (d.object(forKey: "HMRatingDropOn") as? Bool) ?? true else { return }
        let threshold = max(0.1, d.double(forKey: "HMRatingDropBy") > 0 ? d.double(forKey: "HMRatingDropBy") : 0.2)
        let since = Millis(Date.now.addingTimeInterval(-21 * 86_400).timeIntervalSince1970 * 1000)
        // Each source on its own: a feed's series and Hmunmawi's own reading of the public listing count ratings over different
        // sets of storefronts, so mixing them in one comparison could show a fall that never happened.
        let feedRows = (try? await liveStore.events(kind: "app.snapshot", since: since)) ?? []
        let ownRows = (try? await liveStore.events(kind: "rating.snapshot", since: since)) ?? []
        let sources = [feedRows, ownRows]
        let week = Calendar(identifier: .iso8601).dateComponents([.yearForWeekOfYear, .weekOfYear], from: .now)
        let weekKey = "\(week.yearForWeekOfYear ?? 0)w\(week.weekOfYear ?? 0)"
        let now = Millis(Date.now.timeIntervalSince1970 * 1000)
        for rows in sources { for (app, snaps) in Dictionary(grouping: rows, by: { $0.app ?? "" }) where !app.isEmpty && ProjectStore.shared.shows(app) {
            guard let f = RatingDrop.detect(app: ComingSoon.shortName(app), snapshots: snaps, threshold: threshold) else { continue }
            let key = "\(app)-\(f.from)-\(f.to)-\(weekKey)"
            let drop = Event(source: "app", kind: "rating.drop", app: app,
                             payload: .object(["title": .string(f.title), "from": .number(f.from), "to": .number(f.to), "days": .number(Double(f.days)),
                                               "new_ratings": .number(Double(f.newRatings))]),
                             occurredAt: now, dedupeKey: "ratingdrop-\(key)")
            _ = try? await liveStore.ingest(drop, rules: await rules(for: drop))
            let worry = Event(source: "story", kind: "story.worry", app: app,
                              payload: .object(["title": .string(f.title), "evidence": .string("Average rating \(String(format: "%.1f", f.to)), was \(String(format: "%.1f", f.from))"),
                                                "family": .string("rating drop"), "detector": .string("rating-drop")]),
                              occurredAt: now, dedupeKey: "story-ratingdrop-\(key)")
            _ = try? await liveStore.ingest(worry, rules: await rules(for: worry))
        } }
    }

    /// A service whose own request limit is nearly used up becomes a `quota.high` event (once per service per hour) and a
    /// worry on Today. The warning level is in Settings → General → Alerts (default 80%).
    private func checkQuotas() async {
        let d = UserDefaults.standard
        guard !isDemo, let liveStore else { return }
        let warn = Double(d.object(forKey: "HMQuotaWarnAt") as? Int ?? 80)
        let hour = Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day().time(includingFractionalSeconds: false)).prefix(13)
        let now = Millis(Date.now.timeIntervalSince1970 * 1000)
        for q in QuotaLedger.shared.readings() {
            guard let used = q.usedPercent, used >= warn, Date.now.timeIntervalSince(q.seen) < 7200 else { continue }
            let title = "\(q.service): \(Int(used.rounded()))% of the request limit used (\(q.detail()))"
            let event = Event(source: "app", kind: "quota.high", app: nil,
                              payload: .object(["title": .string(title), "service": .string(q.service), "used_percent": .number(used)]),
                              occurredAt: now, dedupeKey: "quota-\(q.host)-\(hour)")
            _ = try? await liveStore.ingest(event, rules: await rules(for: event))
            let worry = Event(source: "story", kind: "story.worry", app: nil,
                              payload: .object(["title": .string(title), "evidence": .string("Reported by the service itself"), "family": .string("request limit"), "detector": .string("quota")]),
                              occurredAt: now, dedupeKey: "story-quota-\(q.host)-\(hour)")
            _ = try? await liveStore.ingest(worry, rules: await rules(for: worry))
        }
    }

    private func postStoryEvents() async {
        guard !isDemo, let liveStore else { return }
        let day = Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())   // your day, not UTC's
        let now = Millis(Date.now.timeIntervalSince1970 * 1000)
        for lane in [Finding.Lane.win, .worry] {
            for f in findings.filter({ $0.lane == lane }).prefix(3) {
                let event = Event(source: "story", kind: lane == .win ? "story.win" : "story.worry", app: f.app,
                                  payload: .object(["title": .string(f.title), "evidence": .string(f.evidence),
                                                    "family": .string(f.family ?? ""), "detector": .string(f.detector.rawValue)]),
                                  occurredAt: now, dedupeKey: "story-\(f.id)-\(day)")
                _ = try? await liveStore.ingest(event, rules: await rules(for: event))
            }
        }
        // Problems the data declares itself (urgent and important) are worries too, e.g. "rating-below-floor".
        for item in AttentionItem.all(self).filter({ $0.severityRank <= 1 }) {
            let event = Event(source: "story", kind: "story.worry", app: item.app.isEmpty ? nil : item.app,
                              payload: .object(["title": .string("\(item.app): \(item.outcome ?? item.title)"),
                                                "evidence": .string(item.feedFigure ?? item.severityText),
                                                "family": .string(item.id + " " + item.title.lowercased()), "detector": .string("declared")]),
                              occurredAt: now, dedupeKey: "story-declared-\(item.id)-\(day)")
            _ = try? await liveStore.ingest(event, rules: await rules(for: event))
        }
    }

    /// The morning story: once a day after 8 am, checked on every refresh (it used to run only when new data came
    /// in, so a quiet morning had none). Only once insights have been worked out, so it never goes out empty.
    private func postMorningStory(now: Date = .now) async {
        guard !isDemo, insightsReady, let liveStore, Calendar.current.component(.hour, from: now) >= 8 else { return }
        let day = now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        guard UserDefaults.standard.string(forKey: "HMMorningStorySent") != day else { return }
        guard Routines.builtInOn(.morningStory) else { return }   // switched off in Your routines
        let win = findings.first { $0.lane == .win }?.title
        let worry = findings.first { $0.lane == .worry }?.title
        let next = AttentionItem.all(self).first { $0.action != nil }?.action
        guard !morningBusy else { return }
        morningBusy = true; defer { morningBusy = false }
        // Optional (Your routines → Morning story): one line from your AI, a summary only you see.
        let aiLine = await Routines.shared.morningLine()
        let text = ["Today's story", win.map { "Win: \($0)" }, worry.map { "Worry: \($0)" }, next.map { "Next: \($0)" }, aiLine]
            .compactMap { $0 }.joined(separator: "\n")
        let event = Event(source: "story", kind: "story.digest", payload: .object(["text": .string(text)]),
                          occurredAt: Millis(now.timeIntervalSince1970 * 1000), dedupeKey: "story-digest-\(day)")
        if (try? await liveStore.ingest(event, rules: await rules(for: event))) != nil { UserDefaults.standard.set(day, forKey: "HMMorningStorySent") }
    }

    /// The signing key for trust settings: made once, kept in the Keychain (only this app reads it without asking).
    /// nil when the Keychain doesn't answer: no approval is trusted that session (add-ons stay off until it answers), agents get nothing.
    nonisolated static func trustKey(_ secrets: KeychainSecretStore) -> SymmetricKey? {
        do {
            if let s = try secrets.secret(plugin: "hmunmawi", name: "trust-key"), let d = Data(base64Encoded: s), d.count == 32 {
                return SymmetricKey(data: d)
            }
            let k = SymmetricKey(size: .bits256)
            try secrets.setSecret(k.withUnsafeBytes { Data($0) }.base64EncodedString(), plugin: "hmunmawi", name: "trust-key")
            return k
        } catch {
            // A differently signed copy can't read the trust key without a prompt; keep the last known key in
            // preferences so a new Developer certificate can re-bind approvals without redoing every connection.
            if let b64 = UserDefaults.standard.string(forKey: "HMTrustKeyB64"),
               let d = Data(base64Encoded: b64), d.count == 32 {
                UserDefaults.standard.set(b64, forKey: "HMTrustKeyB64")
                try? secrets.setSecret(b64, plugin: "hmunmawi", name: "trust-key")
                return SymmetricKey(data: d)
            }
            return nil
        }
    }

    // MARK: Weekly digest

    /// When the weekly digest goes out (Settings > General): weekday 1 = Sunday … 7 = Saturday, and the hour.
    static var digestWeekday: Int { (UserDefaults.standard.object(forKey: "HMDigestWeekday") as? Int) ?? 2 }
    static var digestHour: Int { (UserDefaults.standard.object(forKey: "HMDigestHour") as? Int) ?? 9 }

    /// The week's numbers in a few lines (under 900 characters, for iMessage). All projects; nil before any data.
    /// The week's numbers (digest and shareable card). `apps`: nil = all apps; else only these app names.
    func weeklyStats(weeksBack: Int = 0, apps: ((String?) -> Bool)? = nil) -> WeeklyStats? {
        let keep = apps ?? { _ in true }
        let daily = Self.oneSourcePerDay(insightWindow.rows.filter { $0.kind == "revenue.daily" && keep($0.app) })
        let mrr = MRRSummary(insightWindow.rows.filter { $0.kind == "subscription.mrr" && keep($0.app) })?.total.points ?? []
        return WeeklyStats.make(daily: daily, mrr: mrr, weeksBack: weeksBack)
    }

    func weeklyDigestText(now: Date = .now, allFindings: [Finding]) -> String? {
        let m = Money.shared
        func money(_ usd: Double) -> String {
            let local = m.convert(usd, from: "USD").map { m.format($0, from: m.target, decimals: 0) } ?? Money.text(usd, "USD", decimals: 0)
            return local + (m.target == "USD" ? "" : " (" + Money.text(usd, "USD", decimals: 0) + ")")
        }
        func change(_ a: Double, _ b: Double) -> String {
            guard b > 0 else { return "" }
            let p = Int(((a - b) / b * 100).rounded())
            return p == 0 ? ", same as the week before" : ", \(p > 0 ? "up" : "down") \(abs(p))% on the week before"
        }
        // The same numbers as the shareable card (WeeklyStats): Apple's last 7 reported days vs the 7 before, all apps.
        guard let w = weeklyStats() else { return nil }
        let span = [w.days.first, w.days.last].compactMap { $0 }.compactMap { try? Date($0 + "T12:00:00Z", strategy: .iso8601) }
            .map { $0.formatted(.dateTime.day().month(.abbreviated)) }.joined(separator: "–")
        var lines = ["Your week (\(span))"]
        lines.append("Earned \(money(w.earnedUSD))\(change(w.earnedUSD, w.earnedBeforeUSD))")
        if let mrr = w.mrrUSD {
            let d = w.mrrWeekAgoUSD.map { mrr - $0 }
            lines.append("MRR \(money(mrr)) a month, \(w.paying ?? 0) paying" + (d.map { abs($0) < 0.5 ? ", steady" : ", \($0 > 0 ? "+" : "−")\(Money.text(abs($0), "USD", decimals: 0)) in 7 days" } ?? ""))
        }
        lines.append("Downloads \(Int(safe: w.downloads))\(change(w.downloads, w.downloadsBefore))")
        if let w = allFindings.first(where: { $0.lane == .win }) { lines.append("Win: " + String(w.title.prefix(140))) }
        if let w = allFindings.first(where: { $0.lane == .worry }) { lines.append("Worry: " + String(w.title.prefix(140))) }
        if !waiting.isEmpty { lines.append("\(waiting.count) action\(waiting.count == 1 ? "" : "s") wait for your OK") }
        return String(lines.joined(separator: "\n").prefix(900))
    }

    /// Once a week at the chosen time: the digest goes through the rules (the "weekly digest" rule texts it). If the
    /// app wasn't running then, it goes out later that day or the next, until 24 hours have passed; then that week
    /// is skipped rather than sent days late. The store's key keeps it to once a week.
    func postWeeklyDigest(now: Date = .now) async {
        guard !isDemo, let liveStore else { return }
        guard let slot = WeeklySchedule.dueSlot(now: now, weekday: Self.digestWeekday, hour: Self.digestHour) else { return }
        let key = slot.localDay
        // Stored before 4 Nov 2026 as the UTC day: either form means this week's digest went out.
        let sentKey = UserDefaults.standard.string(forKey: "HMWeeklyDigestSent")
        guard insightsReady, sentKey != key, sentKey != slot.formatted(.iso8601.year().month().day()) else { return }
        guard Routines.builtInOn(.weeklyDigest) else { return }   // switched off in Your routines
        // Insights across every app (once a week, off the main thread).
        let rows = Self.oneSourcePerDay(insightWindow.rows)
        let all = await Task.detached(priority: .utility) { InsightEngine.run(MetricExtractor.extract(rows)) }.value
        guard let text = weeklyDigestText(now: now, allFindings: all) else { return }
        lastDigestText = text
        let event = Event(source: "story", kind: "story.weekly", payload: .object(["text": .string(text)]),
                          occurredAt: Millis(now.timeIntervalSince1970 * 1000), dedupeKey: "story-weekly-\(key)")
        if (try? await liveStore.ingest(event, rules: await rules(for: event))) != nil { UserDefaults.standard.set(key, forKey: "HMWeeklyDigestSent") }
    }

    /// Saves the rules and hands them to the running engine at once.
    func setRules(_ rules: [Rule]) async {
        config.rules = rules
        try? config.save(to: configURL)
        await engine?.setRules(rules)
        await refresh()
    }

    func value(_ key: String, for id: String) -> String { config.plugins[id]?[key] ?? "" }

    func recordSecretSource(plugin: String, name: String, ref: SecretSourceRef) {
        secretCatalog.record(plugin: plugin, name: name, ref: ref)
    }

    /// Add-ons you decided not to re-approve after their code changed: off, and no longer in the banner.
    static var keptOff: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "HMKeptOffAddOns") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "HMKeptOffAddOns") }
    }
    static func approvedPermissions(_ id: String) -> ApprovedPermissions? {
        UserDefaults.standard.data(forKey: "HMApprovedPerms-\(id)").flatMap { try? JSONDecoder().decode(ApprovedPermissions.self, from: $0) }
    }
    static func recordApproved(_ id: String, _ p: ApprovedPermissions) {
        if let d = try? JSONEncoder().encode(p) { UserDefaults.standard.set(d, forKey: "HMApprovedPerms-\(id)") }
    }

    func keepOff(_ id: String) async { Self.keptOff.insert(id); await refreshAddOns() }

    func allow(_ id: String) async {
        Self.keptOff.remove(id)
        guard let host else { return }
        // Remember what is being allowed, so a later change can be described ("now also reports ...").
        if let m = addOns.first(where: { $0.id == id })?.manifest { Self.recordApproved(id, ApprovedPermissions(m)) }
        do { try await host.approve(id, by: "you") } catch { errorText = "Couldn't approve it: \(plainError(error))" }
        await refreshAddOns()
        await checkNowIfReady(id)
    }

    /// Plain values go to config.json; secrets go to the Keychain. Empty secret fields keep the saved value.
    func save(_ values: [String: String], for row: AddOnRow) async {
        guard let host else { return }
        do {
            var plain = config.plugins[row.id] ?? [:]
            // Only the fields given change: saving one field (an agent's set-key) must not blank the others.
            for setting in row.manifest.settings where values[setting.key] != nil {
                let value = (values[setting.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if setting.type.hasPrefix("secret") {
                    if !value.isEmpty { try secrets.replaceSecret(value, plugin: row.id, name: setting.key) }
                } else {
                    plain[setting.key] = value
                }
            }
            config.plugins[row.id] = plain
            try config.save(to: configURL)
            await host.setSettings(config.settingsJSON(for: row.id), for: row.id)
            await host.restart(row.id)
            try await liveStore?.appendAudit(actor: "you", action: "plugin.settings_saved", subject: "plugin:\(row.id)")
        } catch {
            errorText = "Couldn't save: \(plainError(error))"
        }
        await refreshAddOns()
        await checkNowIfReady(row.id)
    }

    /// Local sources the app reads itself: the X file a bot or Mac job writes (every 20 s, only when it
    /// changed) and Apple's notification history (every 5 minutes). Live purchases from a worker collect
    /// on their own timer.
    func localFeeds(_ tick: Int) async {
        var events: [Event] = []
        // X numbers come from the X connection, which reads the same file (free); here only the plan line is read.
        await XFileFeed.shared.readPlan()
        if tick % 15 == 0 { Task { await XSafariReader.shared.readIfDue() } }   // your own X page through Safari, every 6 h when on
        if tick % 15 == 0 {
            // Real ntfy sends by the App Store alerts relay count as checks of the ntfy row (read-only).
            if let liveStore, addOns.contains(where: { $0.id == "ntfy" && $0.approved }) { await NtfyRelayWatch.check(store: liveStore) }
            OfferCodes.shared.merge(self)                       // App Store Connect facts (custom codes, expiry)
            events += OfferCodes.shared.statusEvents(self)      // deduped per day
                await ExpiryWatch.shared.checkWeb()
            events += ExpiryWatch.shared.statusEvents(self)
                await UsageWatch.shared.refresh()
            events += UsageWatch.shared.statusEvents()
            }
        if tick % 15 == 0, UserDefaults.standard.string(forKey: "HMLiveMode") == "history" { events += await AppleHistory.shared.check() }
        await ingestLocal(events)
    }

    /// The rules an event of the app's own feeds goes through: the engine's, so the quiet stretch after a restore
    /// (events from before the backup alert no more) applies to these too, not only to add-ons' events.
    /// The rules that apply to an event (for routines, which raise events like everything else).
    func rulesFor(_ e: Event) async -> [Rule] { await rules(for: e) }

    private func rules(for e: Event) async -> [Rule] {
        if let engine { return await engine.rulesFor(e) }
        return config.rules
    }

    func ingestLocal(_ events: [Event]) async {
        guard let liveStore, !events.isEmpty else { return }
        for e in events { _ = try? await liveStore.ingest(e, rules: await rules(for: e)) }
    }

    func startLivePurchases() {
        LivePurchases.shared.onEvents = { [weak self] in await self?.ingestLocal($0) }
        LivePurchases.shared.applyAscEvents = { [weak self] events in
            guard let self, let liveStore else { throw AscWebhookStream.StreamError.applyFailed }
            for e in events {
                _ = try await liveStore.ingest(e, rules: await self.rules(for: e))
            }
        }
        // Names an App Store version id ("Pulse Diary 4.1.7") from the add-on's release snapshots, when it knows it.
        LivePurchases.shared.versionName = { [weak self] id in
            guard let self else { return nil }
            for s in self.snapshots("release.snapshot") where s.payload[path: "version_id"]?.string == id {
                return [s.app.map(ComingSoon.shortName), s.payload[path: "version"]?.string].compactMap { $0 }.joined(separator: " ")
            }
            return nil
        }
        Task { await LivePurchases.shared.upgradeHooksToEventRelayIfNeeded() }
        LivePurchases.shared.start()
    }

    /// Run now / Pause / Resume on a Mac job, written to the activity log.
    func recordJobAction(_ what: String, label: String) async {
        try? await liveStore?.appendAudit(actor: "you", action: "job.\(what.split(separator: ":").first ?? "action")", subject: label)
        await refresh()
    }

    /// Right after a connection is allowed or its keys are saved, it checks once, so the result shows in
    /// seconds instead of at its next scheduled check (which can be hours away).
    func checkNowIfReady(_ id: String) async {
        guard let row = addOns.first(where: { $0.id == id }), row.approved, row.missing.isEmpty,
              row.manifest.poll != nil, let engine else { return }
        await engine.poll(id, preempt: true)
        await refresh()
    }

    /// Checks a connection now without sending anything: a messaging connection with its own check (ntfy) only
    /// sees whether its server answers; one without a check falls back to `test` (a real test alert).
    /// Menu bar → Check all: every connected source that reads data checks now (one refresh at the end).
    func checkAll() async {
        guard let engine else { return }
        for row in addOns where row.approved && row.missing.isEmpty && row.manifest.poll != nil { await engine.poll(row.id, preempt: true) }
        await refresh()
    }

    func check(_ row: AddOnRow) async {
        guard let engine else { return }
        if row.manifest.poll != nil {
            await engine.poll(row.id, preempt: true)
            await refresh()
        } else {
            await test(row)
        }
    }

    /// Sends a test alert, or fetches now for add-ons that read data.
    func test(_ row: AddOnRow) async {
        guard let engine, let liveStore else { return }
        if row.manifest.actions.contains("notify") {
            _ = try? await liveStore.enqueue(kind: "notify", resource: row.id, priority: 1, maxAttempts: 1,
                                             payload: .object(["params": .object([
                                                 "title": .string("Hmunmawi"),
                                                 "message": .string("Test alert. If you can read this, it works.")])]))
            await engine.runNextJob()
        } else {
            await engine.poll(row.id, preempt: true)
        }
        await refresh()
    }

    @ObservationIgnored private var approving: Set<Int64> = []
    /// True when one of Hmunmawi's windows is actually visible on screen (not closed, minimised or fully covered).
    static func windowOnScreen() -> Bool {
        NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) && $0.canBecomeMain }
    }

    /// Health checks and the crash-free trend, as of the last refresh (see refreshOnce).
    var healthChecks: [HealthCheck.Check] = []
    var crashTrend: [(Date, Double)] = []
    /// "2026-11" -> app -> US dollars of proceeds from Apple's daily sales reports (see refresh).
    private(set) var dailyProceeds: [String: [String: Double]] = [:]

    /// Approved connections that changed and wait for your OK again (shown as a banner, never a silent switch
    /// to sample data).
    var changedAddOns: [String] = []
    /// Less than 1 GB free on the disk holding Hmunmawi's data.
    var lowDisk = false

    /// A short note while the app does something slow at launch (e.g. "Upgrading database…").
    var busyNote: String?
    func approve(_ job: Job) async {
        // One approval per item: a double click (or owner and agent at once) must not run it twice. Checked and
        // claimed before any await, so the main actor can't interleave two runs.
        guard !approving.contains(job.id) else { return }
        approving.insert(job.id); defer { approving.remove(job.id) }
        // An agent's request you approved: the app runs it itself, then marks it done.
        if job.kind == "agent.request", case .object(let p) = job.payload {
            var args: [String: String] = [:]
            if case .object(let o)? = p["args"] { for (k, v) in o { if let t = v.string { args[k] = t } } }
            // The pending secret is kept under this request's own token, so another request for the same field
            // can't swap in a different value (older requests used "<connection>.<field>").
            let pendingName = p["pending"]?.string ?? "\(args["connection"] ?? "").\(args["field"] ?? "")"
            if p["command"]?.string == "set-key" {
                args["value"] = (try? secrets.secret(plugin: "agent-pending", name: pendingName)) ?? nil
                secrets.deleteSecret(plugin: "agent-pending", name: pendingName)
            }
            let answer = await AgentBridge.shared.handle(p["command"]?.string ?? "", args, agent: p["agent"]?.string ?? "an agent",
                                                         reason: "", approved: true)
            let ok = answer["ok"] as? Bool ?? false
            let message = (answer["result"] as? String) ?? (answer["error"] as? String) ?? ""
            await act { try await $0.resolveApproved(job.id, ok: ok, by: "you", detail: .object([
                "ok": .bool(ok), "approved_by": .string("you"), "result": .string(String(message.prefix(500)))])) }
            if !ok { errorText = "The agent's request ran but didn't work: \(message)" }
            return
        }
        await act { try await $0.approve(job.id, by: "you") }
    }

    /// Parks an agent's request in "Waiting for your OK". Secrets are never stored in the request.
    func parkAgentRequest(command: String, args: [String: String], agent: String, reason: String, summary: String) async -> Int64? {
        guard let liveStore else { return nil }
        var safe = args
        if command == "set-key" { safe["value"] = nil }
        let pending = UUID().uuidString
        var fields: [String: JSONValue] = ["command": .string(command), "agent": .string(agent), "reason": .string(reason),
                                           "summary": .string(summary), "args": .object(safe.mapValues(JSONValue.string))]
        if command == "set-key", let v = args["value"] {
            // Kept in the Keychain under this request's own token until you decide; removed if you skip.
            try? secrets.setSecret(v, plugin: "agent-pending", name: pending)
            fields["pending"] = .string(pending)
        }
        let payload: JSONValue = .object(fields)
        let id = try? await liveStore.enqueue(kind: "agent.request", resource: "agent", priority: 3, maxAttempts: 1,
                                              payload: payload, needsApproval: true)
        try? await liveStore.appendAudit(actor: "agent:\(agent)", action: "agent.waiting", subject: summary)
        await refresh()
        return id
    }

    /// Runs one Rejection Shield fix through the App Store Connect add-on. Returns a plain result line and the
    /// undo payload. Failures come back as a readable message, never silently.
    func shieldFix(_ params: JSONValue, by: String = "you") async -> (ok: Bool, message: String, undo: JSONValue?) {
        guard let engine else { return (false, "The app is still starting; try again in a moment.", nil) }
        do {
            let r = try await engine.perform("asc.fix", resource: "appstoreconnect", params: params)
            try? await liveStore?.appendAudit(actor: by, action: "shield.fix", subject: params[path: "fix"]?.string, detail: params)
            return (true, r[path: "done"]?.string ?? "Done", r[path: "undo"].flatMap { $0 == .null ? nil : $0 })
        } catch {
            return (false, plainError(error), nil)
        }
    }

    /// A read through the same path (e.g. listing old builds before asking you), returning the raw result.
    func shieldFixRaw(_ params: JSONValue) async -> Result<JSONValue, WireError> {
        guard let engine else { return .failure(WireError("starting", "The app is still starting")) }
        do { return .success(try await engine.perform("asc.fix", resource: "appstoreconnect", params: params)) }
        catch { return .failure((error as? WireError) ?? WireError("failed", "\(error)")) }
    }

    /// Daily proceeds (USD) per day since a date, summed across apps, from the App Store sales reports.
    func dailyProceeds(since: Date) async -> [String: Double] {
        guard let liveStore else { return [:] }
        let list = (try? await liveStore.events(kind: "revenue.daily", since: Millis(since.timeIntervalSince1970 * 1000))) ?? []
        var out: [String: Double] = [:]
        // Two senders (the App Store Connect add-on and the script feed) report the same day; count each day once.
        for e in Self.oneSourcePerDay(list) { if let d = e.payload[path: "day"]?.string, let v = e.payload[path: "proceeds_usd"]?.number { out[d, default: 0] += v } }
        return out
    }

    /// Apple's official finance reports: month "YYYY-MM" -> amount owed per currency (newest report wins).
    /// Records this fiscal month's payday forecast once, from day 15 (mid-month: enough days to judge, early enough
    /// to be a real forecast). Kept for good, to compare with Apple's finance report when it arrives.
    func recordForecast(month: String, usd: Double) async {
        guard !isDemo, let liveStore, usd > 0 else { return }
        let e = Event(source: "hmunmawi", kind: "finance.forecast", payload: .object(["month": .string(month), "forecast_usd": .number((usd * 100).rounded() / 100)]),
                      occurredAt: Millis(Date.now.timeIntervalSince1970 * 1000), dedupeKey: "forecast-\(month)")
        _ = try? await liveStore.ingest(e, rules: [])
    }

    /// Recorded forecasts by fiscal month (USD).
    func recordedForecasts() async -> [String: Double] {
        guard let liveStore else { return [:] }
        let list = (try? await liveStore.events(kind: "finance.forecast", since: 0)) ?? []
        var out: [String: Double] = [:]
        for e in list { if let m = e.payload[path: "month"]?.string, let f = e.payload[path: "forecast_usd"]?.number { out[m] = f } }
        return out
    }

    func financeMonths(days: Int = 120) async -> [String: [String: Double]] {
        guard let liveStore else { return [:] }
        let list = (try? await liveStore.events(kind: "finance.month", since: Millis(Date.now.addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970 * 1000))) ?? []
        var out: [String: [String: Double]] = [:]
        for e in list {
            // Only reports asked for by Apple's fiscal period number carry "report_date"; the earlier ones (asked by
            // calendar name) are another month's report under a wrong name, so they're left out.
            guard e.payload[path: "report_date"]?.string != nil,
                  let m = e.payload[path: "month"]?.string, case .object(let t)? = e.payload[path: "totals"] else { continue }
            out[m] = t.compactMapValues(\.number)
        }
        return out
    }

    /// Mail rows from a mail source (Apple Mail, IMAP) become `mail.seen` events, the same kind the outreach reply watch
    /// already reads. Returns how many were new (the same message twice is dropped by its key).
    func ingestMail(_ rows: [MailRow]) async -> Int {
        guard !isDemo, let liveStore else { return 0 }
        let iso = ISO8601DateFormatter(), now = Millis(Date.now.timeIntervalSince1970 * 1000)
        var added = 0
        for r in rows {
            var p: [String: JSONValue] = ["id": .string(r.id), "from": .string(String(r.from.prefix(300))), "subject": .string(String(r.subject.prefix(300))),
                                          "folder": .string(r.folder), "seen_at": .string(iso.string(from: .now))]
            if let ms = r.sentMs { p["sent_ms"] = .number(Double(ms)) }
            if let m = r.messageID { p["message_id"] = .string(String(m.prefix(300))) }
            if let m = r.inReplyTo { p["in_reply_to"] = .string(String(m.prefix(300))) }
            let event = Event(source: "mail", kind: "mail.seen", app: nil, payload: .object(p), occurredAt: min(now, r.sentMs ?? now),
                              dedupeKey: "mail-seen-\(r.id)")
            if let result = try? await liveStore.ingest(event, rules: await rules(for: event)), !result.duplicate { added += 1 }
        }
        return added
    }

    func recordAgent(agent: String, command: String) async {
        guard command != "status" else { return }
        try? await liveStore?.appendAudit(actor: "agent:\(agent)", action: "agent.\(command)", subject: command)
    }

    /// Forgets a connection's saved keys (the add-on stays installed, asking for keys again).
    func forget(_ row: AddOnRow) async {
        for s in row.manifest.settings where s.type.hasPrefix("secret") { secrets.deleteSecret(plugin: row.id, name: s.key) }
        try? await liveStore?.appendAudit(actor: "app", action: "plugin.keys_removed", subject: "plugin:\(row.id)")
        await refreshAddOns()
    }
    func skip(_ job: Job) async {
        if job.kind == "agent.request", case .object(let p) = job.payload, p["command"]?.string == "set-key",
           case .object(let a)? = p["args"] {
            // Only this request's own secret (skipping one request never deletes another's).
            secrets.deleteSecret(plugin: "agent-pending", name: p["pending"]?.string ?? "\(a["connection"]?.string ?? "").\(a["field"]?.string ?? "")")
        }
        await act { try await $0.skip(job.id, by: "you") }
    }

    private func act(_ body: (Store) async throws -> Void) async {
        guard let store = currentStore else { return }
        do { try await body(store) } catch { errorText = "\(error)" }
        await refresh()
    }
}

/// "Done once" marks for the trust checks (first signing, signed log seen, last tamper notice). Kept in the Keychain
/// beside the trust key, not in preferences: any program can `defaults delete` a preference and so make the app sign
/// whatever is on disk again (security re-check, Nov 2026). An old preference that says "done" is carried over once.
enum TrustFlags {
    nonisolated(unsafe) private static let store = KeychainSecretStore()

    static func isSet(_ name: String, legacyDefaultsKey: String? = nil) -> Bool {
        // Fail closed: a Keychain that can't be read (locked, or the mark belongs to a differently signed copy) counts
        // as "already done". Treating it as "never done" would make the app sign whatever is on disk again, which is
        // exactly what these marks exist to stop.
        let answer: String?
        do { answer = try store.secret(plugin: "hmunmawi", name: "flag-\(name)") } catch { return true }
        if answer == "1" { return true }
        if let k = legacyDefaultsKey, UserDefaults.standard.bool(forKey: k) { set(name); return true }
        return false
    }
    static func set(_ name: String) { try? store.setSecret("1", plugin: "hmunmawi", name: "flag-\(name)") }

    static func text(_ name: String) -> String? { (try? store.secret(plugin: "hmunmawi", name: "flag-\(name)")) ?? nil }
    static func setText(_ name: String, _ value: String) { try? store.setSecret(value, plugin: "hmunmawi", name: "flag-\(name)") }
}
