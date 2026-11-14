import AppKit
import CryptoKit
import Foundation
import HmunmawiCore
import Security

/// Backups of what can't be fetched again (everything else comes back with "Fetch everything again"):
/// - a daily **state backup** (a few MB): the irreplaceable database rows (Store.exportState), your own files
///   (rules/settings, projects, offer codes, costs, credits, rivals, routines) and the app's preferences
///   (Next-steps marks, undo memory…). Never passwords or keys: those stay in the Keychain.
///   Checked after writing, readable only by you, kept 30 daily + 12 monthly, and copied encrypted to iCloud Drive.
/// - two **full database copies** (Resilience), local only, for an instant restore.
@MainActor @Observable
final class Backups {
    static let shared = Backups()

    struct Entry: Identifiable, Hashable {
        let url: URL
        let kind: Kind
        let date: Date
        let bytes: Int64
        var verified: Bool
        var id: String { url.path }
        enum Kind: String { case state = "Your data", full = "Full database" }
    }

    private(set) var entries: [Entry] = []
    private(set) var lastResult: String?
    private(set) var iCloudStatus: String?

    nonisolated let support = URL.hmSupport
    nonisolated var folder: URL { support.appending(path: "Backups") }
    /// Health of full copies, remembered per file and date so the tab never re-checks an unchanged file.
    private var checked: [String: (Date, Bool)] = [:]
    nonisolated static let iCloudFolder = URL.homeDirectory.appending(path: "Library/Mobile Documents/com~apple~CloudDocs/Hmunmawi Backups")
    /// Your own files (no caches such as exchange rates or icons).
    nonisolated static let ownFiles = Resilience.ownFiles

    // MARK: Daily state backup

    /// Once a day (after the full copy): writes, checks, prunes, and copies the state backup to iCloud Drive.
    func runIfDue(store: Store, force: Bool = false) async {
        let target = folder.appending(path: "state-\(Resilience.today()).zip")
        guard force || !FileManager.default.fileExists(atPath: target.path) else { return }
        do {
            try await Task.detached(priority: .utility) { [self] in try await make(store: store, to: target) }.value
            let folder = folder
            await Task.detached(priority: .utility) { Self.prune(folder) }.value
            lastResult = "Saved and checked today's backup"
            await copyToICloud(target)
        } catch {
            lastResult = "Couldn't save today's backup: \(error.localizedDescription)"
            AppModel.logStartup("backup: \(lastResult ?? "")")
            try? await store.appendAudit(actor: "app", action: "backup.failed", subject: lastResult)
        }
        reload()
    }

    /// Builds, checks and zips a state backup. Runs off the main thread (file copies, zip, checks).
    nonisolated func make(store: Store, to target: URL) async throws {
        let fm = FileManager.default
        let support = support, folder = folder
        // Copies a crash left behind earlier (plain data) are removed first.
        for old in (try? fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path)) ?? [] where old.hasPrefix("hm-state-") {
            try? fm.removeItem(at: fm.temporaryDirectory.appending(path: old))
        }
        let work = fm.temporaryDirectory.appending(path: "hm-state-\(UUID().uuidString)")
        try fm.createDirectory(at: work.appending(path: "files"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        // 1. The database rows nothing else can give back.
        let dbPath = work.appending(path: "state.sqlite").path
        let written = try await store.exportState(to: dbPath)
        // 2. Your files and the app's preferences.
        for name in Self.ownFiles where fm.fileExists(atPath: support.appending(path: name).path) {
            try fm.copyItem(at: support.appending(path: name), to: work.appending(path: "files").appending(path: name))
        }
        if let id = Bundle.main.bundleIdentifier, let prefs = UserDefaults.standard.persistentDomain(forName: id) {
            let data = try PropertyListSerialization.data(fromPropertyList: prefs, format: .binary, options: 0)
            try data.write(to: work.appending(path: "preferences.plist"))
        }
        try JSONSerialization.data(withJSONObject: ["made": Date.now.formatted(.iso8601), "rows": written,
                                                    "app": Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?"],
                                   options: [.prettyPrinted, .sortedKeys]).write(to: work.appending(path: "manifest.json"))
        // 3. Checked before it counts: the database is healthy and has every row it should.
        guard Resilience.isHealthy(dbPath) else { throw WireError("backup_check", "The backup's database failed its check") }
        let expected = try await store.stateCounts()
        let copy = try Store(path: dbPath)
        let got = try await copy.stateCounts()
        try await copy.settle()
        for side in ["-wal", "-shm"] { try? fm.removeItem(atPath: dbPath + side) }
        guard got == expected || got == written else { throw WireError("backup_check", "The backup is missing rows") }
        // 4. One compressed file, readable only by you.
        try Self.privateFolder(folder)
        let tmpZip = folder.appending(path: ".\(target.lastPathComponent).partial")
        try? fm.removeItem(at: tmpZip)
        try Self.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", work.path, tmpZip.path])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmpZip.path)
        _ = try fm.replaceItemAt(target, withItemAt: tmpZip)   // the old one stays until the new one is in place
    }

    /// 30 daily + the first of each month for 12 months; full copies are pruned by Resilience.
    nonisolated static func prune(_ folder: URL) {
        let states = scan(folder).filter { $0.kind == .state }
        let keep = Resilience.keepStateNames(states.map { $0.url.deletingPathExtension().lastPathComponent })
        for e in states where !keep.contains(e.url.deletingPathExtension().lastPathComponent) { try? FileManager.default.removeItem(at: e.url) }
    }


    // MARK: Listing

    /// Re-reads the folder off the main thread; full copies are checked once per file version.
    func reload() {
        let folder = folder, known = checked
        Task {
            let (list, results) = await Task.detached(priority: .utility) { () -> ([Entry], [String: (Date, Bool)]) in
                var results = known
                let list = Self.scan(folder).map { e -> Entry in
                    guard e.kind == .full else { return e }
                    var e = e
                    if let c = known[e.url.path], c.0 == e.date { e.verified = c.1 }
                    else { e.verified = Resilience.isHealthy(e.url.path); results[e.url.path] = (e.date, e.verified) }
                    return e
                }
                return (list, results)
            }.value
            checked = results
            entries = list
        }
    }

    /// The backups in the folder, newest first (full copies not yet checked: `verified` false until reload checks them).
    nonisolated static func scan(_ folder: URL) -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        return files.compactMap { u in
            let name = u.lastPathComponent
            let kind: Entry.Kind
            if name.hasPrefix("state-") && name.hasSuffix(".zip") { kind = .state }
            else if (name.hasPrefix("hmunmawi-") || name.hasPrefix("pre-upgrade-") || name.hasPrefix("pre-restore-")) && name.hasSuffix(".sqlite") { kind = .full }
            else { return nil }
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return Entry(url: u, kind: kind, date: v?.contentModificationDate ?? .distantPast, bytes: Int64(v?.fileSize ?? 0),
                         verified: kind == .state)
        }.sorted { $0.date > $1.date }
    }

    // MARK: Encrypted copy in iCloud Drive

    /// The key that encrypts the iCloud copy: kept in the Keychain (kept on this Mac; the recovery code is what restores it elsewhere. iCloud Keychain sync needs a signed build with a keychain group, when the
    /// system allows it). The recovery code (the same key, as text) restores it on another Mac.
    nonisolated private static var keyService: String { "io.github.priyevsingh.Hmunmawi.backup" + TestProfile.suffix }

    /// A new key is made only when none exists. Any other Keychain trouble (locked, not allowed) throws, so a copy is
    /// never sealed with a key that wasn't saved.
    nonisolated static func key() throws -> SymmetricKey {
        if TestProfile.name != nil { throw WireError("test_profile", "Backups are off in a test profile.") }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.keyService,
                                   kSecAttrAccount as String: "backup-key"]
        var q = base; q[kSecReturnData as String] = true; q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecSuccess, let d = out as? Data, d.count == 32 { return SymmetricKey(data: d) }
        guard status == errSecItemNotFound else { throw WireError("keychain", "The Keychain didn't answer (\(status)); try again once the Mac is unlocked") }
        // A Mac without the key while iCloud already holds copies (a new Mac, or after a disk loss): a new key would
        // seal new copies differently from the old ones. Ask for the recovery code instead.
        let existing = ((try? FileManager.default.contentsOfDirectory(at: iCloudFolder, includingPropertiesForKeys: nil)) ?? [])
            .contains { $0.pathExtension == "hmbackup" }
        if existing {
            throw WireError("need_code", "Your iCloud copies were made with your backup key: enter your recovery code under Settings → Backups → iCloud Drive (Bring back) to use it on this Mac")
        }
        let new = SymmetricKey(size: .bits256)
        try save(new)
        return new
    }

    /// Saves the backup key in the Keychain (this Mac; keep the recovery code to restore it elsewhere).
    nonisolated static func save(_ key: SymmetricKey) throws {
        if TestProfile.name != nil { throw WireError("test_profile", "Backups are off in a test profile.") }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.keyService,
                                   kSecAttrAccount as String: "backup-key"]
        let data = key.withUnsafeBytes { Data($0) }
        var add = base; add[kSecValueData as String] = data; add[kSecAttrSynchronizable as String] = true
        var added = SecItemAdd(add as CFDictionary, nil)
        if added != errSecSuccess {
            add[kSecAttrSynchronizable as String] = false   // syncing not allowed here: keep it on this Mac
            added = SecItemAdd(add as CFDictionary, nil)
        }
        guard added == errSecSuccess else { throw WireError("keychain", "Couldn't save the backup key (\(added))") }
    }

    /// This Mac's backup key if it has one (never makes one).
    nonisolated static func existingKey() throws -> SymmetricKey? {
        if TestProfile.name != nil { return nil }
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.keyService,
                                kSecAttrAccount as String: "backup-key", kSecReturnData as String: true,
                                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        q.removeAll()
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let d = out as? Data, d.count == 32 else { throw WireError("keychain", "The Keychain didn't answer (\(status))") }
        return SymmetricKey(data: d)
    }

    /// The recovery code to keep in a password manager (read off the main thread).
    func recoveryCode() async -> String? {
        await Task.detached(priority: .userInitiated) { (try? Self.key())?.withUnsafeBytes { Data($0) }.base64EncodedString() }.value
    }

    func copyToICloud(_ file: URL) async {
        let folder = folder
        iCloudStatus = await Task.detached(priority: .utility) { Self.sealToICloud(file, folder: folder) }.value
    }

    nonisolated static func sealToICloud(_ file: URL, folder: URL) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.iCloudFolder.deletingLastPathComponent().path) else {
            return "iCloud Drive is off on this Mac, so backups stay on this Mac only."
        }
        do {
            try fm.createDirectory(at: Self.iCloudFolder, withIntermediateDirectories: true)
            let sealed = try AES.GCM.seal(try Data(contentsOf: file), using: try key())
            guard let combined = sealed.combined else { throw WireError("encrypt", "Couldn't encrypt") }
            let target = Self.iCloudFolder.appending(path: file.deletingPathExtension().lastPathComponent + ".hmbackup")
            try combined.write(to: target, options: .atomic)
            // Same 30 + 12 rule in iCloud, on iCloud's own names (never on what this Mac has: a new or wiped Mac
            // must not erase the history it may need to bring back).
            let copies = ((try? fm.contentsOfDirectory(at: Self.iCloudFolder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "hmbackup" && $0.lastPathComponent.hasPrefix("state-") }
            let keep = Resilience.keepStateNames(copies.map { $0.deletingPathExtension().lastPathComponent })
            for u in copies where !keep.contains(u.deletingPathExtension().lastPathComponent) { try? fm.removeItem(at: u) }
            return "Encrypted copy in iCloud Drive ✓"
        } catch {
            return "Couldn't copy to iCloud Drive: \(error.localizedDescription)"
        }
    }

    // MARK: Restore

    /// Saves the current state first (so a restore can itself be undone), marks the chosen backup, and restarts.
    func restore(_ entry: Entry, store: Store) async {
        do {
            let stamp = Resilience.today() + "-" + String(Int(Date.now.timeIntervalSince1970))
            try await store.backUp(to: folder.appending(path: "pre-restore-\(stamp).sqlite").path)
            let safety = folder.appending(path: "state-\(stamp)-before-restore.zip")
            try await Task.detached(priority: .userInitiated) { [self] in try await make(store: store, to: safety) }.value
            let marker = ["path": entry.url.path, "kind": entry.kind == .state ? "state" : "full"]
            try JSONSerialization.data(withJSONObject: marker).write(to: Resilience.pendingRestoreFile(support), options: .atomic)
            try? await store.appendAudit(actor: "owner", action: "backup.restore_requested", subject: entry.url.lastPathComponent)
            Self.relaunch()
        } catch {
            lastResult = "Couldn't restore: \(error.localizedDescription). Nothing was changed."
        }
    }

    func noteRestoreFailed(_ why: String) { lastResult = "Couldn't restore: \(why)" }

    /// Runs at launch, before the database opens (the work is in Resilience.applyPendingRestore, tested there).
    nonisolated static func applyPending(support: URL) -> (file: String, state: Bool, madeAt: Date, kept: Int)? {
        guard let r = Resilience.applyPendingRestore(support: support) else { return nil }
        if let prefs = r.preferences, let id = Bundle.main.bundleIdentifier { UserDefaults.standard.setPersistentDomain(prefs, forName: id) }
        return (r.file, r.state, r.madeAt, r.kept)
    }

    /// After a restore: what came back, and how many newer rows the database it replaced gave to it.
    func noteRestored(_ file: String, kept: Int) {
        lastResult = "Restored \(file)" + (kept > 0 ? "; kept \(kept) newer sale\(kept == 1 ? "" : "s"), review\(kept == 1 ? "" : "s") or daily figure\(kept == 1 ? "" : "s") recorded after it" : "")
    }

    static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Starts again only once this copy has fully quit, so the restore never swaps a database still open here.
        p.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open -n \"$0\"",
                       Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier)]
        try? p.run()
        NSApplication.shared.terminate(nil)
    }

    // MARK: iCloud copies (another Mac, or this one after a disk loss)

    func iCloudCopies() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: Self.iCloudFolder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "hmbackup" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Decrypts an iCloud copy into the local list (with this Mac's key, or a recovery code from another Mac).
    func bringBack(_ file: URL, recoveryCode code: String?) async throws {
        let folder = folder
        try await Task.detached(priority: .userInitiated) {
            let k: SymmetricKey
            if let code, !code.isEmpty {
                guard let d = Data(base64Encoded: code.trimmingCharacters(in: .whitespacesAndNewlines)), d.count == 32 else {
                    throw WireError("bad_code", "That recovery code isn't valid")
                }
                k = SymmetricKey(data: d)
            } else { k = try Self.key() }
            let codeKey = code.map { !$0.isEmpty } ?? false
            let plain: Data
            do { plain = try AES.GCM.open(try AES.GCM.SealedBox(combined: try Data(contentsOf: file)), using: k) }
            catch { throw WireError("bad_code", "This copy was made with a different key: enter its recovery code") }
            // The code worked and this Mac has no key yet: keep it, so this Mac's new copies use the same key.
            if codeKey, (try? Self.existingKey()) == nil { try? Self.save(k) }
            try Self.privateFolder(folder)
            // Never over this Mac's own backup of the same day.
            var target = folder.appending(path: file.deletingPathExtension().lastPathComponent + ".zip")
            if FileManager.default.fileExists(atPath: target.path) {
                target = folder.appending(path: file.deletingPathExtension().lastPathComponent + "-icloud.zip")
            }
            try Self.writePrivately(plain, to: target)
        }.value
        reload()
    }

    /// The backups folder, reachable only by you (0700), so nothing inside is ever readable by others, even briefly.
    nonisolated static func privateFolder(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }

    /// Created 0600 from the start, then moved into place.
    nonisolated static func writePrivately(_ data: Data, to target: URL) throws {
        let tmp = target.deletingLastPathComponent().appending(path: ".\(target.lastPathComponent).partial")
        try? FileManager.default.removeItem(at: tmp)
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw WireError("write", "Couldn't write \(target.lastPathComponent)")
        }
        _ = try FileManager.default.replaceItemAt(target, withItemAt: tmp)
    }

    /// Backs up now, even if today's backup exists (replaces today's).
    func backUpNow(store: Store) async {
        await runIfDue(store: store, force: true)   // today's stays until the new one is checked and swapped in
    }

    // MARK: Helpers

    nonisolated static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw WireError("tool_failed", "\(URL(fileURLWithPath: tool).lastPathComponent) failed") }
    }
}
