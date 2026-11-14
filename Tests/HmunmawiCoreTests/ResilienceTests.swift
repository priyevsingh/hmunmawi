import Foundation
import Testing
@testable import HmunmawiCore

@Suite(.serialized) struct ResilienceTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hm-res-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func settingsCopyOnlyWhenChanged() async throws {
        let dir = try tempDir()
        let backups = dir.appending(path: "Backups")
        let settings = dir.appending(path: "config.json")
        try Data("{\"a\":1}".utf8).write(to: settings)
        let store = try Store(path: dir.appending(path: "hmunmawi.sqlite").path)
        let day = 86_400.0, start = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try await Resilience.backUpIfDue(store: store, settings: settings, backups: backups, now: start)
        _ = try await Resilience.backUpIfDue(store: store, settings: settings, backups: backups, now: start + day)
        func configs() throws -> Int { try FileManager.default.contentsOfDirectory(atPath: backups.path).filter { $0.hasPrefix("config-") }.count }
        #expect(try configs() == 1)
        try Data("{\"a\":2}".utf8).write(to: settings)
        _ = try await Resilience.backUpIfDue(store: store, settings: settings, backups: backups, now: start + 2 * day)
        #expect(try configs() == 2)
    }

    @Test func backupIsDailyAndRestoresAfterDamage() async throws {
        let dir = try tempDir()
        let dbPath = dir.appending(path: "hmunmawi.sqlite").path
        let backups = dir.appending(path: "Backups")

        do {
            let store = try Store(path: dbPath)
            _ = try await store.ingest(Event(source: "t", kind: "revenue.purchase", app: "A", occurredAt: 1, dedupeKey: "k1"), rules: [])
            #expect(try await Resilience.backUpIfDue(store: store, settings: nil, backups: backups))
            #expect(try await !Resilience.backUpIfDue(store: store, settings: nil, backups: backups))
        }

        // Damage the live database the way a crash mid-write or a bad disk might.
        try Data(repeating: 0x42, count: 8192).write(to: URL(fileURLWithPath: dbPath))
        #expect(!Resilience.isHealthy(dbPath))

        let result = try Resilience.prepare(databaseAt: dbPath, backups: backups)
        guard case .restored = result else { Issue.record("expected a restore, got \(result)"); return }
        #expect(Resilience.isHealthy(dbPath))
        let reopened = try Store(path: dbPath)
        #expect(try await reopened.eventCount() == 1)
    }

    @Test func cleanlyClosedDatabaseIsNeverMistakenForDamage() async throws {
        // After a clean quit SQLite removes the -wal/-shm files; the database must still check as healthy and stay put.
        let dir = try tempDir()
        let dbPath = dir.appending(path: "hmunmawi.sqlite").path
        do {
            let store = try Store(path: dbPath)
            _ = try await store.ingest(Event(source: "t", kind: "review.new", occurredAt: 1, dedupeKey: "k"), rules: [])
        }
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbPath + suffix) }
        #expect(Resilience.health(dbPath) == .healthy)
        #expect(try Resilience.prepare(databaseAt: dbPath, backups: dir.appending(path: "Backups")) == .healthy)
        #expect(try await Store(path: dbPath).eventCount() == 1)
        // A file that can't be opened at all is "unreadable", never moved aside.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dbPath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dbPath) }
        #expect(Resilience.health(dbPath) == .unreadable)
        #expect(try Resilience.prepare(databaseAt: dbPath, backups: dir.appending(path: "Backups")) == .healthy)
        #expect(FileManager.default.fileExists(atPath: dbPath))
    }

    @Test func damagedWithoutBackupStartsFresh() throws {
        let dir = try tempDir()
        let dbPath = dir.appending(path: "hmunmawi.sqlite").path
        try Data(repeating: 0x13, count: 4096).write(to: URL(fileURLWithPath: dbPath))
        let result = try Resilience.prepare(databaseAt: dbPath, backups: dir.appending(path: "Backups"))
        guard case .startedFresh = result else { Issue.record("expected a fresh start, got \(result)"); return }
        #expect(!FileManager.default.fileExists(atPath: dbPath))
        #expect(throws: Never.self) { _ = try Store(path: dbPath) }
    }

    @Test func keepsOnlyAWeekOfBackups() throws {
        let dir = try tempDir()
        for day in 1...10 {
            try Data().write(to: dir.appending(path: String(format: "hmunmawi-2026-10-%02d.sqlite", day)))
        }
        Resilience.prune(dir, keep: 7)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(left.count == 7)
        #expect(left.first == "hmunmawi-2026-10-04.sqlite")
    }
}

@Suite struct RestoreTests {
    private func folder() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appending(path: "hm-restore-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    private func sale(_ k: String) -> Event { Event(source: "t", kind: "revenue.purchase", payload: .object(["amount": .number(4.99)]), occurredAt: 1, dedupeKey: k) }

    @Test func stateBackupRoundTrip() async throws {
        let support = try folder(); defer { try? FileManager.default.removeItem(at: support) }
        let livePath = support.appending(path: "hmunmawi.sqlite").path
        try "A".write(to: support.appending(path: "config.json"), atomically: true, encoding: .utf8)
        var expected: [String: Int] = [:]
        do {
            let live = try Store(path: livePath)
            _ = try await live.ingest(sale("s1"), rules: [])
            _ = try await live.ingest(Event(source: "t", kind: "app.snapshot", occurredAt: 1, dedupeKey: "snap"), rules: [])
            try await live.appendAudit(actor: "owner", action: "note")
            // The backup, packaged the way Settings → Backups does it.
            let pack = support.appending(path: "work/hm-state-x")
            try FileManager.default.createDirectory(at: pack.appending(path: "files"), withIntermediateDirectories: true)
            _ = try await live.exportState(to: pack.appending(path: "state.sqlite").path)
            expected = try await live.stateCounts()
            try FileManager.default.copyItem(at: support.appending(path: "config.json"), to: pack.appending(path: "files/config.json"))
            try Resilience.runTool("/usr/bin/ditto", ["-c", "-k", "--keepParent", pack.path, support.appending(path: "state.zip").path])
            // Life goes on after the backup: a new sale and a changed setting.
            _ = try await live.ingest(sale("s2"), rules: [])
            try "B".write(to: support.appending(path: "config.json"), atomically: true, encoding: .utf8)
        }
        try JSONSerialization.data(withJSONObject: ["path": support.appending(path: "state.zip").path, "kind": "state"])
            .write(to: Resilience.pendingRestoreFile(support))

        let r = try #require(Resilience.applyPendingRestore(support: support))
        #expect(r.state)
        #expect(!FileManager.default.fileExists(atPath: Resilience.pendingRestoreFile(support).path))   // once only
        #expect(try String(contentsOf: support.appending(path: "config.json"), encoding: .utf8) == "A")
        let back = try Store(path: livePath)
        // Every irreplaceable row is back, plus the sale made after the backup (a restore never loses money data).
        var withNewer = expected; withNewer["events", default: 0] += 1
        #expect(try await back.stateCounts() == withNewer)
        #expect(r.kept == 1)
        #expect(try await back.firstBrokenAuditEntry() == nil)            // activity log still verifies
        #expect(try await back.countEvents(kind: "revenue.purchase", since: 0) == 2)
        #expect(Resilience.applyPendingRestore(support: support) == nil)  // nothing waiting any more
    }

    @Test func fullCopyRestoreAndBadMarkerIsHarmless() async throws {
        let support = try folder(); defer { try? FileManager.default.removeItem(at: support) }
        let livePath = support.appending(path: "hmunmawi.sqlite").path
        let copy = support.appending(path: "copy.sqlite").path
        do {
            let live = try Store(path: livePath)
            _ = try await live.ingest(sale("s1"), rules: [])
            try await live.backUp(to: copy)
            _ = try await live.ingest(sale("s2"), rules: [])
        }
        // A marker pointing at a missing file changes nothing.
        try JSONSerialization.data(withJSONObject: ["path": "/nope.sqlite", "kind": "full"]).write(to: Resilience.pendingRestoreFile(support))
        #expect(Resilience.applyPendingRestore(support: support) == nil)
        #expect(try await Store(path: livePath).countEvents(kind: "revenue.purchase", since: 0) == 2)

        try JSONSerialization.data(withJSONObject: ["path": copy, "kind": "full"]).write(to: Resilience.pendingRestoreFile(support))
        #expect(Resilience.applyPendingRestore(support: support)?.state == false)
        // The backup had s1; s2 came later and is kept (sales are never lost to a restore).
        #expect(try await Store(path: livePath).countEvents(kind: "revenue.purchase", since: 0) == 2)
    }
}

@Suite struct RestoreSafetyTests {
    private func folder() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appending(path: "hm-rs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    private func sale(_ k: String) -> Event { Event(source: "t", kind: "revenue.purchase", payload: .object(["amount": .number(1)]), occurredAt: 1, dedupeKey: k) }

    /// A state zip like Settings → Backups makes, with extra file names inside "files".
    private func stateZip(from store: Store, in dir: URL, name: String, files: [String: String], made: String? = nil) async throws -> URL {
        let pack = dir.appending(path: "work-\(UUID().uuidString)/hm-state-x")
        try FileManager.default.createDirectory(at: pack.appending(path: "files"), withIntermediateDirectories: true)
        _ = try await store.exportState(to: pack.appending(path: "state.sqlite").path)
        for (n, text) in files { try text.write(to: pack.appending(path: "files/\(n)"), atomically: true, encoding: .utf8) }
        if let made { try JSONSerialization.data(withJSONObject: ["made": made]).write(to: pack.appending(path: "manifest.json")) }
        let zip = dir.appending(path: name)
        try Resilience.runTool("/usr/bin/ditto", ["-c", "-k", "--keepParent", pack.path, zip.path])
        return zip
    }

    @Test func damagedWithOnlyAStateBackupGetsItsDataBack() async throws {
        let support = try folder(); defer { try? FileManager.default.removeItem(at: support) }
        let backups = support.appending(path: "Backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let live = support.appending(path: "hmunmawi.sqlite").path
        do {
            let s = try Store(path: live)
            _ = try await s.ingest(sale("s1"), rules: [])
            _ = try await stateZip(from: s, in: support, name: "Backups/state-2026-11-01.zip", files: [:], made: "2026-11-01T10:00:00Z")
        }
        try Data(repeating: 0x42, count: 8192).write(to: URL(fileURLWithPath: live))
        let r = try Resilience.prepare(databaseAt: live, backups: backups)
        guard case .restoredState(let from, let made) = r else { Issue.record("got \(r)"); return }
        #expect(from == "state-2026-11-01.zip")
        #expect(made == (try Date("2026-11-01T10:00:00Z", strategy: .iso8601)))   // manifest time, not file time
        #expect(try await Store(path: live).countEvents(kind: "revenue.purchase") == 1)
        // The damaged file was kept aside, not deleted.
        #expect((try FileManager.default.contentsOfDirectory(atPath: support.path)).contains { $0.contains(".damaged-") })
    }

    @Test func badStateBackupChangesNothingAndSaysWhy() async throws {
        let support = try folder(); defer { try? FileManager.default.removeItem(at: support) }
        let live = support.appending(path: "hmunmawi.sqlite").path
        _ = try await Store(path: live).ingest(sale("keep"), rules: [])
        try "MINE".write(to: support.appending(path: "config.json"), atomically: true, encoding: .utf8)
        // A zip whose database is junk.
        let pack = support.appending(path: "w/hm-state-x")
        try FileManager.default.createDirectory(at: pack.appending(path: "files"), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 4096).write(to: pack.appending(path: "state.sqlite"))
        try "THEIRS".write(to: pack.appending(path: "files/config.json"), atomically: true, encoding: .utf8)
        let zip = support.appending(path: "bad.zip")
        try Resilience.runTool("/usr/bin/ditto", ["-c", "-k", "--keepParent", pack.path, zip.path])
        try JSONSerialization.data(withJSONObject: ["path": zip.path, "kind": "state"]).write(to: Resilience.pendingRestoreFile(support))
        #expect(Resilience.applyPendingRestore(support: support) == nil)
        #expect(try String(contentsOf: support.appending(path: "config.json"), encoding: .utf8) == "MINE")
        #expect(try await Store(path: live).countEvents(kind: "revenue.purchase") == 1)
        #expect(FileManager.default.fileExists(atPath: Resilience.restoreFailedFile(support).path))
    }

    @Test func restorePutsBackOnlyTheAppsOwnFiles() async throws {
        let support = try folder(); defer { try? FileManager.default.removeItem(at: support) }
        let live = support.appending(path: "hmunmawi.sqlite").path
        let s = try Store(path: live)
        _ = try await s.ingest(sale("a"), rules: [])
        let zip = try await stateZip(from: s, in: support, name: "x.zip", files: ["config.json": "OK", "Add-ons": "EVIL", "evil.sh": "EVIL"])
        try JSONSerialization.data(withJSONObject: ["path": zip.path, "kind": "state"]).write(to: Resilience.pendingRestoreFile(support))
        #expect(Resilience.applyPendingRestore(support: support)?.state == true)
        #expect(try String(contentsOf: support.appending(path: "config.json"), encoding: .utf8) == "OK")
        #expect(!FileManager.default.fileExists(atPath: support.appending(path: "Add-ons").path))
        #expect(!FileManager.default.fileExists(atPath: support.appending(path: "evil.sh").path))
    }

    @Test func backupIsCheckedAndLeavesNoPartialFile() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = try Store(path: dir.appending(path: "db.sqlite").path)
        _ = try await s.ingest(sale("a"), rules: [])
        let target = dir.appending(path: "copy.sqlite").path
        try await s.backUp(to: target)
        try await s.backUp(to: target)   // replacing an existing copy works too
        #expect(Resilience.isHealthy(target))
        #expect(!FileManager.default.fileExists(atPath: target + ".partial"))
        #expect(try await Store(path: target).countEvents(kind: "revenue.purchase") == 1)
    }
}

@Suite struct MigrationRaceTests {
    @Test func twoConnectionsUpgradingAtOnceBothSucceed() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hm-race-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "db.sqlite").path
        let opened = await withTaskGroup(of: Bool.self) { g in
            for _ in 0..<4 { g.addTask { do { _ = try Store(path: path); return true } catch { print("RACE-ERR \(error)"); return false } } }
            return await g.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(opened == 4)
        #expect(Schema.version(of: try SQLiteConnection(path: path)) == Schema.latestVersion)
    }
}

@Suite struct BackupRuleTests {
    @Test func keepsThirtyDailyAndTwelveMonthly() {
        var names: [String] = []
        var d = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2025, month: 1, day: 1))!
        for _ in 0..<500 {   // ~16 months of daily backups
            names.append("state-" + d.formatted(Date.ISO8601FormatStyle(timeZone: TimeZone(identifier: "UTC")!).year().month().day()))
            d = d.addingTimeInterval(86_400)
        }
        let keep = Resilience.keepStateNames(names)
        let newest = names.sorted(by: >)
        #expect(newest.prefix(30).allSatisfy(keep.contains))
        let months = Set(keep.map { String($0.dropFirst(6).prefix(7)) })
        #expect(months.count == 12 + 1 || months.count == 12)   // 12 monthly (+ the current month inside the 30 days)
        #expect(keep.count <= 30 + 12)
        #expect(!keep.contains("state-2025-01-01"))              // older than 12 months: gone
        // Only a few names (a new Mac's iCloud folder): nothing is dropped.
        #expect(Resilience.keepStateNames(Array(names.prefix(5))) == Set(names.prefix(5)))
    }
}

@Suite struct PoissonTests {
    @Test func busyDaysAreNotAlwaysUnusual() {
        // An ordinary busy day (1,000 a day, 1,000 seen) is right in the middle, not "maximally significant".
        let p = InsightEngine.poissonCDF(1000, 1000)
        #expect(p > 0.45 && p < 0.6)
        #expect(InsightEngine.poissonCDF(800, 1000) < 0.001)
        // Small numbers are unchanged from the exact sum.
        #expect(abs(InsightEngine.poissonCDF(3, 2) - 0.857123460498547) < 1e-12)
    }
}

@Suite struct RestoreKeepsNewerTests {
    @Test func restoreKeepsSalesAndApprovalsMadeAfterTheBackup() async throws {
        let support = FileManager.default.temporaryDirectory.appending(path: "hm-kn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let live = support.appending(path: "hmunmawi.sqlite").path
        let copy = support.appending(path: "copy.sqlite").path
        func sale(_ k: String) -> Event { Event(source: "t", kind: "revenue.purchase", payload: .object([:]), occurredAt: 1, dedupeKey: k) }
        do {
            let s = try Store(path: live)
            _ = try await s.ingest(sale("before"), rules: [])
            try await s.backUp(to: copy)
            _ = try await s.ingest(sale("after"), rules: [])                    // irreplaceable: must survive
            _ = try await s.ingest(Event(source: "t", kind: "app.snapshot", payload: .object([:]), occurredAt: 1, dedupeKey: "snap"), rules: [])
            try await s.rawExecute("INSERT INTO plugin_approvals (plugin_id, manifest_sha, approved_at, approved_by) VALUES ('asc', 'new-sha', 999999999999, 'owner')")
        }
        try JSONSerialization.data(withJSONObject: ["path": copy, "kind": "full"]).write(to: Resilience.pendingRestoreFile(support))
        let r = try #require(Resilience.applyPendingRestore(support: support))
        #expect(r.kept == 1)
        let back = try Store(path: live)
        #expect(try await back.countEvents(kind: "revenue.purchase") == 2)        // before + after, no duplicate
        #expect(try await back.countEvents(kind: "app.snapshot") == 0)            // routine rows come from the backup
        #expect(try await back.isPluginApproved(id: "asc", fingerprint: "new-sha"))
        #expect(!FileManager.default.fileExists(atPath: live + ".restoring-wal"))
    }
}
