import Foundation
import SQLite3

/// Keeps the database safe across crashes and restarts: checks it at launch, restores from backup when it's
/// damaged, and keeps daily full copies (database and settings): a week of them, or 2 days for a database over
/// 300 MB (each copy is full size). The small daily state backups (Backups.swift) keep 30 days + 12 months.
public enum Resilience {
    public static let keepDays = 7
    public static let keepDaysLarge = 2
    /// The app's own files in its support folder (settings, lists you made). A restore puts back only these names.
    public static let ownFiles = ["config.json", "projects.json", "offercodes.json", "costs.json", "credits.json",
                                  "competitors.json", "automations.json", "joblists", "payouts.json", "banks", "outreach.json", "changes.json", "routines-deleted.json"]

    public enum StartupResult: Equatable, Sendable {
        case healthy
        case restored(from: String)
        case startedFresh(movedAside: String)
        /// No healthy full copy, so the newest state backup ("Your data") was put back; everything else is fetched
        /// again from the sources.
        case restoredState(from: String, madeAt: Date)
    }

    public enum Health: Equatable, Sendable { case healthy, damaged, unreadable }

    /// SQLite's own consistency check on a separate connection. Opened read-write (it changes nothing): a WAL
    /// database whose -wal/-shm files are gone after a clean quit can't be opened read-only, and that used to be
    /// mistaken for damage. Only a failed check counts as damaged; a database that can't be opened at all is
    /// "unreadable" and is never moved aside.
    public static func health(_ path: String) -> Health {
        guard FileManager.default.fileExists(atPath: path) else { return .healthy }
        var db: OpaquePointer?
        defer { sqlite3_close_v2(db) }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return .unreadable }
        sqlite3_busy_timeout(db, 5000)
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &stmt, nil) == SQLITE_OK else {
            // NOTADB / CORRUPT while preparing means the file isn't a usable database; anything else (busy, I/O)
            // isn't evidence of damage.
            let code = sqlite3_errcode(db)
            return code == SQLITE_NOTADB || code == SQLITE_CORRUPT ? .damaged : .unreadable
        }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else {
            return rc == SQLITE_NOTADB || rc == SQLITE_CORRUPT ? .damaged : .unreadable
        }
        return String(cString: text) == "ok" ? .healthy : .damaged
    }

    /// A fast check for launch: the file opens and its structure can be read (catches a file that isn't a
    /// database at all, or a broken header, in milliseconds). The full check runs after launch (`health`).
    public static func quickHealth(_ path: String) -> Health {
        guard FileManager.default.fileExists(atPath: path) else { return .healthy }
        var db: OpaquePointer?
        defer { sqlite3_close_v2(db) }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return .unreadable }
        sqlite3_busy_timeout(db, 5000)
        let rc = sqlite3_exec(db, "SELECT count(*) FROM sqlite_master; PRAGMA user_version;", nil, nil, nil)
        return rc == SQLITE_OK ? .healthy : (rc == SQLITE_NOTADB || rc == SQLITE_CORRUPT ? .damaged : .unreadable)
    }

    /// True only when the check ran and passed (backups are chosen with this).
    public static func isHealthy(_ path: String) -> Bool { health(path) == .healthy }

    /// Run before opening the store. A damaged database is replaced by the newest healthy backup, or moved aside.
    /// `full`: run SQLite's complete check (seconds on a large database). Launch uses the quick check unless a
    /// background check found damage last time.
    public static func prepare(databaseAt path: String, backups: URL, full: Bool = true) throws -> StartupResult {
        // Only real damage moves a database aside; one that merely can't be checked is left for opening to report.
        guard (full ? health(path) : quickHealth(path)) == .damaged else { return .healthy }
        let fm = FileManager.default
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = path + ".damaged-\(stamp)"
        try fm.moveItem(atPath: path, toPath: aside)
        // Its journal goes with it (the newest commits may be in there), never deleted.
        for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: path + suffix) {
            if (try? fm.moveItem(atPath: path + suffix, toPath: aside + suffix)) == nil { try? fm.removeItem(atPath: path + suffix) }
        }

        let candidates = (try? fm.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)) ?? []
        for backup in candidates.filter({ $0.lastPathComponent.hasPrefix("hmunmawi-") && $0.pathExtension == "sqlite" })
            .sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) where isHealthy(backup.path) {
            try fm.copyItem(atPath: backup.path, toPath: path)
            return .restored(from: backup.lastPathComponent)
        }
        // No full copy (e.g. skipped for low disk space): the newest state backup still has everything that can't
        // be fetched again. Only the database is put back; your files and settings weren't damaged.
        for zip in candidates.filter({ $0.lastPathComponent.hasPrefix("state-") && $0.pathExtension == "zip" })
            .sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            if let r = try? restoreState(zip: zip.path, live: path, support: nil) {
                return .restoredState(from: zip.lastPathComponent, madeAt: r.madeAt)
            }
        }
        return .startedFresh(movedAside: URL(fileURLWithPath: aside).lastPathComponent)
    }

    /// Before a database is upgraded to a new version, a full copy is kept (Backups/pre-upgrade-v<n>-<time>.sqlite),
    /// so an upgrade can always be undone. Returns the backup's name, or nil when no upgrade is due.
    @discardableResult
    public static func backUpBeforeUpgrade(databaseAt path: String, backups: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let connection = try SQLiteConnection(path: path)
        let current = Schema.version(of: connection)
        guard current > 0, current < Schema.latestVersion else { return nil }
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let name = "pre-upgrade-v\(current)-\(Int(Date().timeIntervalSince1970)).sqlite"
        let target = backups.appending(path: name).path
        try connection.execute("VACUUM INTO ?", [.text(target)])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target)
        return name
    }

    /// True when opening this database will run upgrades (so the app can say "Upgrading database…").
    public static func needsUpgrade(databaseAt path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path), let c = try? SQLiteConnection(path: path) else { return false }
        let v = Schema.version(of: c)
        return v > 0 && v < Schema.latestVersion
    }

    /// Writes today's backup if it's missing, copies the settings file alongside, and prunes old ones.
    @discardableResult
    public static func backUpIfDue(store: Store, settings: URL?, backups: URL, now: Date = .now) async throws -> Bool {
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let day = today(now)
        let target = backups.appending(path: "hmunmawi-\(day).sqlite")
        guard !FileManager.default.fileExists(atPath: target.path) else { return false }
        // Full copies only when there's room: free space must exceed twice the database plus 5 GB.
        let dbBytes = (try? FileManager.default.attributesOfItem(atPath: store.path)[.size] as? Int64) ?? 0
        let free = (try? backups.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? .max
        if free < dbBytes * 2 + 5_000_000_000 {
            try? await store.appendAudit(actor: "app", action: "backup.skipped_disk", subject: "Not enough free space for a full copy")
            _ = try? await store.prune()
            return false
        }
        try await store.backUp(to: target.path)
        if let settings, FileManager.default.fileExists(atPath: settings.path) {
            // Only when the settings changed since the newest copy: seven identical files restore nothing more.
            let fm = FileManager.default
            let newest = ((try? fm.contentsOfDirectory(atPath: backups.path)) ?? [])
                .filter { $0.hasPrefix("config-") && $0.hasSuffix(".json") }.sorted().last
            let same = newest.map { fm.contentsEqual(atPath: backups.appending(path: $0).path, andPath: settings.path) } ?? false
            if !same {
                let copy = backups.appending(path: "config-\(day).json")
                try? fm.removeItem(at: copy)
                try fm.copyItem(at: settings, to: copy)
            }
        }
        prune(backups, keep: dbBytes > 300_000_000 ? keepDaysLarge : keepDays)
        // Once a day, right after the backup (so nothing is lost for good): trim old routine rows.
        _ = try? await store.prune()
        return true
    }

    static func prune(_ backups: URL, keep: Int) {
        let files = (try? FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)) ?? []
        // Pre-restore and pre-upgrade copies are full-size too: the last 3 of each are plenty to undo with.
        for (prefix, n) in [("hmunmawi-", keep), ("config-", keep), ("pre-restore-", 3), ("pre-upgrade-", 3)] {
            let mine = files.filter { $0.lastPathComponent.hasPrefix(prefix) }.sorted { $0.lastPathComponent > $1.lastPathComponent }
            for old in mine.dropFirst(n) { try? FileManager.default.removeItem(at: old) }
        }
    }

    /// The 30 + 12 rule on state-backup names ("state-YYYY-MM-DD…"): the newest 30, plus the first of each of the
    /// newest 12 months. Works on names alone, so iCloud copies follow it without looking at this Mac's folder.
    public static func keepStateNames(_ names: [String]) -> Set<String> {
        var keep = Set(names.sorted(by: >).prefix(30))
        let byMonth = Dictionary(grouping: names) { String($0.dropFirst(6).prefix(7)) }   // "YYYY-MM"
        for month in byMonth.keys.sorted().suffix(12) { if let first = byMonth[month]?.min() { keep.insert(first) } }
        return keep
    }

    /// Today's date in this Mac's time zone, as backup names use it ("2026-11-02").
    public static func today(_ now: Date = .now) -> String {
        now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
    }
}

extension Store {
    /// A consistent copy of the live database, safe to take while the app is running.
    /// Written beside under a temporary name and checked first, so a failed or damaged copy (disk full, I/O error)
    /// never takes a backup's name or a retention slot.
    public func backUp(to path: String) throws {
        let fm = FileManager.default
        let partial = path + ".partial"
        try? fm.removeItem(atPath: partial)
        do {
            try db.execute("VACUUM INTO ?", [.text(partial)])
            guard Resilience.isHealthy(partial) else { throw WireError("backup_check", "The new backup failed its check") }
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: partial)   // readable only by you
            if fm.fileExists(atPath: path) { _ = try fm.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: partial)) }
            else { try fm.moveItem(atPath: partial, toPath: path) }
        } catch {
            try? fm.removeItem(atPath: partial)
            throw error
        }
        try appendAudit(actor: "app", action: "backup.saved", subject: URL(fileURLWithPath: path).lastPathComponent)
    }
}

extension Store {
    /// Folds the write-ahead log into the file so a copy is one self-contained file (used on backup files).
    public func settle() throws { try db.execute("PRAGMA journal_mode=DELETE") }

    /// Kinds of events that no source can give back in full later, kept in the state backup:
    /// money, reviews, daily figures (sales, users, crashes) and Apple's finance months.
    static let irreplaceable = "(kind LIKE 'revenue.%' OR kind LIKE 'review.%' OR kind LIKE '%.daily' OR kind = 'finance.month' OR kind = 'finance.forecast' OR kind = 'subscription.mrr' OR kind = 'subscription.events' OR kind = 'analytics.daily_users')"

    /// Writes only what can't be fetched again into a new database at `path`: the action log (with its chain
    /// anchor), jobs and approvals, rule timings, add-on approvals, and the irreplaceable history (plus any event
    /// a job points to). Small, even after years. Returns row counts per table for checking.
    public func exportState(to path: String) throws -> [String: Int] {
        try? FileManager.default.removeItem(atPath: path)
        do { let target = try SQLiteConnection(path: path); try Schema.migrate(target) }   // same tables, same version
        try db.execute("ATTACH DATABASE ? AS state", [.text(path)])
        defer { try? db.execute("DETACH DATABASE state") }
        var counts: [String: Int] = [:]
        try db.transaction {
            try db.execute("""
                INSERT INTO state.events SELECT * FROM main.events
                WHERE \(Store.irreplaceable) OR id IN (SELECT event_id FROM main.jobs WHERE event_id IS NOT NULL)
                """)
            counts["events"] = db.changes
            for table in ["audit", "audit_anchor", "jobs", "rule_fires", "plugin_approvals"] {
                try db.execute("INSERT INTO state.\(table) SELECT * FROM main.\(table)")
                counts[table] = db.changes
            }
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return counts
    }

    /// Row counts the state export should match (for the after-writing check).
    public func stateCounts() throws -> [String: Int] {
        var out: [String: Int] = [:]
        out["events"] = Int(try db.query("""
            SELECT COUNT(*) AS n FROM events WHERE \(Store.irreplaceable) OR id IN (SELECT event_id FROM jobs WHERE event_id IS NOT NULL)
            """).first?.int("n") ?? 0)
        for table in ["audit", "audit_anchor", "jobs", "rule_fires", "plugin_approvals"] {
            out[table] = Int(try db.query("SELECT COUNT(*) AS n FROM \(table)").first?.int("n") ?? 0)
        }
        return out
    }
}

// MARK: Restore (chosen in Settings → Backups, applied at the next launch before the database opens)

extension Resilience {
    public struct Restored: @unchecked Sendable {
        public let file: String
        public let state: Bool
        public let preferences: [String: Any]?
        /// When the backup was made (its file date): events before it already alerted once.
        public let madeAt: Date
        /// Irreplaceable rows recorded after the backup, kept from the database it replaced.
        public var kept = 0
    }

    /// Where a chosen restore waits for the next launch (the live database can't be swapped while open).
    public static func pendingRestoreFile(_ support: URL) -> URL { support.appending(path: "restore-pending.json") }

    /// Why the last chosen restore couldn't be applied (read and cleared by the app after launch).
    public static func restoreFailedFile(_ support: URL) -> URL { support.appending(path: "restore-failed.txt") }

    /// Applies a waiting restore: a full copy replaces the database; a state backup ("Your data") puts back its
    /// database, your files and (returned) preferences. Checked before anything is replaced; the database is swapped
    /// first and files only after that worked, so a failure changes nothing. Tried once only; a failure's reason is
    /// left in restore-failed.txt.
    public static func applyPendingRestore(support: URL) -> Restored? {
        let fm = FileManager.default
        let marker = pendingRestoreFile(support)
        guard let data = try? Data(contentsOf: marker) else { return nil }
        defer { try? fm.removeItem(at: marker) }   // tried once, never a restore loop
        func failed(_ why: String) -> Restored? {
            try? why.write(to: restoreFailedFile(support), atomically: true, encoding: .utf8)
            return nil
        }
        guard let m = try? JSONSerialization.jsonObject(with: data) as? [String: String], let path = m["path"] else {
            return failed("The restore request was unreadable. Nothing was changed.")
        }
        guard fm.fileExists(atPath: path) else { return failed("The backup file was gone. Nothing was changed.") }
        let live = support.appending(path: "hmunmawi.sqlite").path
        do {
            if m["kind"] == "state" { return try restoreState(zip: path, live: live, support: support) }
            guard isHealthy(path) else { return failed("The backup failed its check. Nothing was changed.") }
            let kept = try swapIn(path, live: live, keepNewer: true)
            let made = ((try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? .now
            return Restored(file: URL(fileURLWithPath: path).lastPathComponent, state: false, preferences: nil, madeAt: made, kept: kept)
        } catch {
            return failed("\(error). Nothing was changed.")
        }
    }

    /// Puts back a state backup's database (and, with `support`, your files and preferences).
    static func restoreState(zip path: String, live: String, support: URL?) throws -> Restored {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appending(path: "hm-restore-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try runTool("/usr/bin/ditto", ["-x", "-k", path, work.path])
        guard let root = (try? fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil))?.first(where: { $0.lastPathComponent.hasPrefix("hm-state-") }),
              isHealthy(root.appending(path: "state.sqlite").path) else { throw WireError("backup_check", "The backup failed its check") }
        // A chosen restore keeps what's newer; recovering from damage doesn't (the damaged file isn't trusted).
        let kept = try swapIn(root.appending(path: "state.sqlite").path, live: live, keepNewer: support != nil)
        var prefs: [String: Any]?
        if let support {
            // Only the app's own file names: a backup can never place anything else (e.g. add-ons) in the folder.
            for f in (try? fm.contentsOfDirectory(at: root.appending(path: "files"), includingPropertiesForKeys: nil)) ?? []
            where ownFiles.contains(f.lastPathComponent) {
                let dest = support.appending(path: f.lastPathComponent)
                let staged = support.appending(path: "." + f.lastPathComponent + ".restoring")
                try? fm.removeItem(at: staged)
                guard (try? fm.copyItem(at: f, to: staged)) != nil else { continue }
                if fm.fileExists(atPath: dest.path) { _ = try? fm.replaceItemAt(dest, withItemAt: staged) }
                else { try? fm.moveItem(at: staged, to: dest) }
                try? fm.removeItem(at: staged)
            }
            if let d = try? Data(contentsOf: root.appending(path: "preferences.plist")) {
                prefs = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any]
            }
        }
        // When it was made: the manifest's own time (a copy brought back from iCloud has a fresh file date).
        var made = ((try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? .now
        if let d = try? Data(contentsOf: root.appending(path: "manifest.json")),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let s = j["made"] as? String,
           let t = try? Date(s, strategy: .iso8601) { made = t }
        return Restored(file: URL(fileURLWithPath: path).lastPathComponent, state: true, preferences: prefs, madeAt: made, kept: kept)
    }

    /// Replaces the live database with `source`: copied beside first (a failed copy leaves the live one untouched),
    /// the live file's journal folded in and removed before the swap (never replayed onto the restored file).
    /// With `keepNewer`, rows the backup can't have (irreplaceable ones recorded after it) and your newest add-on
    /// approvals are first copied from the live database into the restored copy (see keepNewerRows).
    @discardableResult
    static func swapIn(_ source: String, live: String, keepNewer: Bool = false) throws -> Int {
        let fm = FileManager.default
        let staged = live + ".restoring"
        try? fm.removeItem(atPath: staged)
        do { try fm.copyItem(atPath: source, toPath: staged) } catch { try? fm.removeItem(atPath: staged); throw error }
        let kept = keepNewer && fm.fileExists(atPath: live) ? keepNewerRows(from: live, into: staged) : 0
        // The merge opened the copy: fold its journal in so the swapped file is complete on its own.
        if keepNewer { checkpoint(staged); for side in ["-wal", "-shm"] { try? fm.removeItem(atPath: staged + side) } }
        if fm.fileExists(atPath: live) {
            checkpoint(live)
            for side in ["-wal", "-shm"] { try? fm.removeItem(atPath: live + side) }
            do { _ = try fm.replaceItemAt(URL(fileURLWithPath: live), withItemAt: URL(fileURLWithPath: staged)) }
            catch { try? fm.removeItem(atPath: staged); throw error }
        } else {
            for side in ["-wal", "-shm"] { try? fm.removeItem(atPath: live + side) }
            try fm.moveItem(atPath: staged, toPath: live)
        }
        return kept
    }

    /// Copies into `target` (a restored copy, not yet live) what a restore must never lose from `current`: sales,
    /// reviews, daily figures, finance months and MRR days it has that the backup doesn't (the same rows backups
    /// keep; duplicates are skipped by their key, and they don't alert again), and each add-on's newest approval.
    /// The activity log isn't merged: its entries are chained. Best effort: any failure keeps the plain restore.
    static func keepNewerRows(from current: String, into target: String) -> Int {
        guard let db = try? SQLiteConnection(path: target) else { return 0 }
        do {
            try db.execute("ATTACH DATABASE ? AS cur", [.text(current)])
            defer { try? db.execute("DETACH DATABASE cur") }
            func columns(_ schema: String, _ table: String) throws -> [String] {
                try db.query("PRAGMA \(schema).table_info(\(table))").compactMap { $0.string("name") }
            }
            // Columns both files have (an older backup may lack a newer column; the upgrade fills it when opened).
            let cols = try columns("main", "events").filter { $0 != "id" && (try? columns("cur", "events").contains($0)) == true }
            guard !cols.isEmpty else { return 0 }
            let list = cols.joined(separator: ", ")
            var kept = 0
            try db.transaction {
                try db.execute("""
                    INSERT OR IGNORE INTO main.events (\(list)) SELECT \(list) FROM cur.events
                    WHERE \(Store.irreplaceable) OR kind = 'subscription.mrr'
                    """)
                kept = db.changes
                let mainA = try columns("main", "plugin_approvals"), curA = try columns("cur", "plugin_approvals")
                if !mainA.isEmpty, !curA.isEmpty {
                    // The signature travels with its approval when both files have it (an older backup doesn't).
                    let sig = mainA.contains("signature") && curA.contains("signature")
                    try db.execute("""
                        INSERT INTO main.plugin_approvals (plugin_id, manifest_sha, approved_at, approved_by\(sig ? ", signature" : ""))
                        SELECT plugin_id, manifest_sha, approved_at, approved_by\(sig ? ", signature" : "") FROM cur.plugin_approvals WHERE true
                        ON CONFLICT(plugin_id) DO UPDATE SET manifest_sha = excluded.manifest_sha,
                          approved_at = excluded.approved_at, approved_by = excluded.approved_by\(sig ? ", signature = excluded.signature" : "")
                        WHERE excluded.approved_at > main.plugin_approvals.approved_at
                        """)
                }
            }
            return kept
        } catch { return 0 }
    }

    /// Folds a database's write-ahead log into the main file (best effort; a damaged file is skipped).
    static func checkpoint(_ path: String) {
        var db: OpaquePointer?
        defer { sqlite3_close_v2(db) }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return }
        sqlite3_busy_timeout(db, 3000)
        sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
    }

    public static func runTool(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw WireError("tool_failed", "\(URL(fileURLWithPath: tool).lastPathComponent) failed") }
    }
}
