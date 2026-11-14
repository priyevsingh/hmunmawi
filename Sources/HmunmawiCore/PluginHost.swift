import CryptoKit
import Foundation
import Security

public struct InstalledPlugin: Sendable, Equatable {
    public var manifest: PluginManifest
    public var directory: URL
    /// Fingerprint of the manifest and the executable; any change needs fresh approval.
    public var fingerprint: String

    public static func load(from directory: URL) throws -> InstalledPlugin {
        let manifestData = try Data(contentsOf: directory.appending(path: "manifest.json"))
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)
        try manifest.validate()
        let executable = directory.appending(path: manifest.executable)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw WireError("invalid_manifest", "\(manifest.id): \(manifest.executable) is missing or not executable")
        }
        var hasher = SHA256()
        hasher.update(data: manifestData)
        if let codeHash = signedCodeHash(executable) {
            hasher.update(data: codeHash)
        } else {
            hasher.update(data: try Data(contentsOf: executable))
        }
        // Every other file in the folder too (scripts, data, helpers it may load), so a change anywhere in it needs
        // a new approval, not only a changed manifest or main program (security audit, Nov 2026).
        try hashFolder(directory, skipping: ["manifest.json", manifest.executable], into: &hasher)
        let fingerprint = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return InstalledPlugin(manifest: manifest, directory: directory, fingerprint: fingerprint)
    }

    /// Hashes each file below `directory` by its path and contents (links by their target), in a fixed order.
    /// Signed code (a bundled helper) counts by its code hash, like the main program.
    static func hashFolder(_ directory: URL, skipping: Set<String>, into hasher: inout SHA256) throws {
        let fm = FileManager.default
        func real(_ path: String) -> String {
            guard let r = realpath(path, nil) else { return path }
            defer { free(r) }
            return String(cString: r)
        }
        let base = real(directory.path)
        guard let walk = fm.enumerator(atPath: directory.path) else { return }
        var files: [(String, URL)] = []
        for case let rel as String in walk {
            if skipping.contains(rel) || (rel as NSString).lastPathComponent == ".DS_Store" { continue }
            let url = directory.appending(path: rel)
            let v = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if v.isSymbolicLink == true || v.isRegularFile == true { files.append((rel, url)) }
        }
        for (rel, url) in files.sorted(by: { $0.0 < $1.0 }) {
            hasher.update(data: Data("\u{0}\(rel)\u{0}".utf8))
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                // A link out of the folder would let its content change without a new approval.
                let target = real(url.path)
                guard target == base || target.hasPrefix(base + "/") else {
                    throw WireError("invalid_manifest", "\(rel) is a link that points outside the add-on folder")
                }
                hasher.update(data: Data(((try? fm.destinationOfSymbolicLink(atPath: url.path)) ?? "").utf8))
            } else if let code = signedCodeHash(url) {
                hasher.update(data: code)
            } else {
                hasher.update(data: try Data(contentsOf: url, options: .mappedIfSafe))
            }
        }
    }

    /// The code-signing hash (cdhash) of a validly signed executable. It changes only when the code changes,
    /// not when the same code is re-signed, so rebuilding the app doesn't reset approvals needlessly.
    static func signedCodeHash(_ url: URL) -> Data? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url.resolvingSymlinksInPath() as CFURL, [], &code) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess
        else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let unique = dict[kSecCodeInfoUnique as String] as? Data,
              dict[kSecCodeInfoFlags as String] as? UInt32 != SecCodeSignatureFlags.adhoc.rawValue
        else { return nil }
        return unique
    }
}

/// Starts add-ons on demand, keeps them running, restarts them after a crash (with backoff)
/// and answers their requests to the app.
public actor PluginHost {
    let store: Store
    let gate: NetworkGate
    let tally = HTTPTally()

    /// Writes one log row summing an add-on's web requests since the last call: how many, to which sites, which
    /// statuses (it used to be one row per request, ~17,000 a day). Blocked requests are still logged one by one.
    public func flushHTTP(_ id: String) async {
        guard let sum = await tally.take(id) else { return }
        try? await store.appendAudit(actor: id, action: "plugin.http", subject: sum.hosts.keys.sorted().joined(separator: ", "),
                                     detail: .object(["requests": .number(Double(sum.count)),
                                                      "hosts": .object(sum.hosts.mapValues { .number(Double($0)) }),
                                                      "statuses": .object(sum.statuses.mapValues { .number(Double($0)) })]))
    }
    let logsDirectory: URL?
    let mac: (any MacAbilities)?
    let now: @Sendable () -> Millis

    private var installed: [String: InstalledPlugin] = [:]
    private var processes: [String: PluginProcess] = [:]
    private var settings: [String: JSONValue] = [:]
    private var startFailures: [String: Int] = [:]
    private var retryAt: [String: Millis] = [:]
    private var starting: [String: Task<PluginProcess, any Error>] = [:]

    public init(store: Store, gate: NetworkGate, logsDirectory: URL? = nil, mac: (any MacAbilities)? = nil,
                now: @escaping @Sendable () -> Millis = Store.systemNow) {
        signal(SIGPIPE, SIG_IGN)
        self.store = store
        self.gate = gate
        self.logsDirectory = logsDirectory
        self.mac = mac
        self.now = now
    }

    /// Loads every `*.hmplugin` folder in `roots`. Broken add-ons are skipped and listed in the result.
    @discardableResult
    public func discover(in roots: [URL]) -> [(URL, Error)] {
        var problems: [(URL, Error)] = []
        var claimed: [String: Int] = [:]   // id -> the root that provided it
        for (r, root) in roots.enumerated() {
            let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for dir in items where dir.pathExtension == "hmplugin" {
                do {
                    let plugin = try InstalledPlugin.load(from: dir)
                    // A later folder (your own add-ons) can't take a built-in add-on's id: it would inherit that
                    // add-on's saved keys and approval history.
                    if let first = claimed[plugin.manifest.id], first < r {
                        problems.append((dir, WireError("duplicate_id", "Another add-on already uses the id “\(plugin.manifest.id)”")))
                        continue
                    }
                    claimed[plugin.manifest.id] = r
                    register(plugin)
                } catch { problems.append((dir, error)) }
            }
        }
        return problems
    }

    public func register(_ plugin: InstalledPlugin) {
        if let old = installed[plugin.manifest.id], old.fingerprint != plugin.fingerprint {
            Task { [processes] in await processes[plugin.manifest.id]?.stop() }
            processes[plugin.manifest.id] = nil
        }
        installed[plugin.manifest.id] = plugin
    }

    public func setSettings(_ value: JSONValue, for id: String) { settings[id] = value }

    /// Add-ons start inside a macOS sandbox (on unless turned off in Settings); applies from their next start.
    public private(set) var sandboxAddOns = true
    public func setSandbox(_ on: Bool) { sandboxAddOns = on }

    public var plugins: [InstalledPlugin] { installed.values.sorted { $0.manifest.id < $1.manifest.id } }
    public func installedPlugin(_ id: String) -> InstalledPlugin? { installed[id] }

    public func isApproved(_ id: String) async throws -> Bool {
        guard let plugin = installed[id] else { return false }
        let perms = ApprovedPermissions(plugin.manifest).stableHash()
        return try await store.isPluginApproved(id: id, fingerprint: plugin.fingerprint, permissionsHash: perms)
    }

    public func approve(_ id: String, by person: String) async throws {
        guard let plugin = installed[id] else { throw WireError("not_installed", "No add-on called \(id)") }
        let perms = ApprovedPermissions(plugin.manifest).stableHash()
        try await store.approvePlugin(id: id, fingerprint: plugin.fingerprint, permissionsHash: perms, by: person)
    }

    /// Prefers the add-on named by the job's resource, else any add-on offering the action.
    public func plugin(for action: String, preferred: String) -> InstalledPlugin? {
        if let p = installed[preferred], p.manifest.actions.contains(action) { return p }
        return plugins.first { $0.manifest.actions.contains(action) }
    }

    public func process(for id: String) async throws -> PluginProcess {
        guard let plugin = installed[id] else { throw WireError("not_installed", "No add-on called \(id)") }
        let perms = ApprovedPermissions(plugin.manifest).stableHash()
        guard try await store.isPluginApproved(id: id, fingerprint: plugin.fingerprint, permissionsHash: perms) else {
            throw WireError("not_approved", "\(plugin.manifest.name) needs your approval first")
        }
        if let running = processes[id], await running.isRunning { return running }
        if let wait = retryAt[id], now() < wait {
            throw WireError("restarting", "\(plugin.manifest.name) is restarting")
        }
        // Two callers asking at once share one start instead of launching two copies.
        if let pending = starting[id] { return try await pending.value }
        let launch = Task { try await self.launch(plugin) }
        starting[id] = launch
        defer { starting[id] = nil }
        return try await launch.value
    }

    /// Where locked copies of approved add-ons are kept; nil runs them in place (tests, command line).
    public private(set) var stagingDirectory: URL?
    public func setStagingDirectory(_ url: URL?) { stagingDirectory = url }

    /// A read-only copy of the approved folder; its files hash to the approved fingerprint or this throws.
    func stagedCopy(of plugin: InstalledPlugin) throws -> URL { try stage(plugin) }

    private func stage(_ plugin: InstalledPlugin) throws -> URL {
        guard let base = stagingDirectory else { return plugin.directory }
        let fm = FileManager.default
        try fm.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let id = plugin.manifest.id
        let target = base.appending(path: "\(id)-\(plugin.fingerprint.prefix(16)).hmplugin", directoryHint: .isDirectory)
        if (try? InstalledPlugin.load(from: target))?.fingerprint == plugin.fingerprint { return target }
        // Anything older for this add-on goes (made writable first so it can be removed).
        for old in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] where old.lastPathComponent.hasPrefix("\(id)-") {
            Self.makeWritable(old); try? fm.removeItem(at: old)
        }
        try fm.copyItem(at: plugin.directory, to: target)
        // Bundled add-ons point at their program with a link into the app; the locked copy holds the program itself.
        let exe = target.appending(path: plugin.manifest.executable)
        if (try? exe.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            let real = plugin.directory.appending(path: plugin.manifest.executable).resolvingSymlinksInPath()
            try fm.removeItem(at: exe)
            try fm.copyItem(at: real, to: exe)
        }
        Self.lock(target)
        let loaded = Result { try InstalledPlugin.load(from: target) }
        guard (try? loaded.get())?.fingerprint == plugin.fingerprint else {
            let why: String
            switch loaded {
            case .failure(let e): why = "copy can't load: \(e)"
            case .success(let c): why = "copy \(c.fingerprint.prefix(8)) vs approved \(plugin.fingerprint.prefix(8)); copy code signed: \(InstalledPlugin.signedCodeHash(target.appending(path: plugin.manifest.executable)) != nil)"
            }
            Self.makeWritable(target); try? fm.removeItem(at: target)
            throw WireError("not_approved", "the copy didn't match what was approved (\(why))")
        }
        return target
    }

    private static func lock(_ dir: URL) {
        let fm = FileManager.default
        for case let u as URL in fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey])! {
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let exec = fm.isExecutableFile(atPath: u.path)
            try? fm.setAttributes([.posixPermissions: isDir ? 0o500 : (exec ? 0o500 : 0o400)], ofItemAtPath: u.path)
        }
        try? fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
    }

    private static func makeWritable(_ dir: URL) {
        let fm = FileManager.default
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        guard let walk = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return }
        for case let u as URL in walk { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: u.path) }
    }

    private func launch(_ plugin: InstalledPlugin) async throws -> PluginProcess {
        let id = plugin.manifest.id
        // What runs must be what you approved: the files are checked again right before every start (they could
        // have been replaced since launch).
        guard (try? InstalledPlugin.load(from: plugin.directory))?.fingerprint == plugin.fingerprint else {
            try? await store.appendAudit(actor: id, action: "plugin.changed_on_disk", detail: .object([:]))
            throw WireError("not_approved", "\(plugin.manifest.name) changed on disk since you approved it; open Settings to check it")
        }
        let manifest = plugin.manifest
        let pluginSettings = settings[id] ?? .object([:])
        // It runs from a read-only copy only this app can change, re-checked against the approval: nothing can swap a
        // helper file between the check above and the add-on reading it (security re-check, Nov 2026).
        let runDirectory: URL
        do { runDirectory = try stage(plugin) } catch {
            try? await store.appendAudit(actor: id, action: "plugin.changed_on_disk", detail: .object(["error": .string("\(error)")]))
            throw WireError("not_approved", "\(plugin.manifest.name) changed on disk since you approved it; open Settings to check it")
        }
        let process = PluginProcess(
            manifest: manifest, directory: runDirectory, settings: pluginSettings,
            logURL: logsDirectory?.appending(path: "\(id).log"), sandboxed: sandboxAddOns,
            requestHandler: { [store, gate, mac, tally] message in
                await Self.answer(message, manifest: manifest, gate: gate, mac: mac, store: store,
                                  settings: pluginSettings, tally: tally)
            })
        do {
            try await process.start()
        } catch {
            let failures = (startFailures[id] ?? 0) + 1
            startFailures[id] = failures
            retryAt[id] = now() + min(1000 << Millis(min(failures, 6)), 60_000)
            try? await store.appendAudit(actor: id, action: "plugin.start_failed", detail: .object(["error": .string("\(error)")]))
            throw error
        }
        startFailures[id] = 0
        retryAt[id] = nil
        processes[id] = process
        try? await store.appendAudit(actor: id, action: "plugin.started")
        return process
    }

    /// Pings every running add-on; one that doesn't answer in 10 seconds is stopped and restarts on next use.
    /// A check that has already outlived its timeout is cancelled even if the add-on still answers `ping`
    /// (request handling is concurrent, so a hung poll used to look healthy and stay red in Settings).
    public func healthCheck() async {
        for (id, process) in processes {
            if await process.hasCallPastDeadline {
                await process.stop()
                processes[id] = nil
                try? await store.appendAudit(actor: id, action: "plugin.unresponsive",
                                             detail: .object(["error": .string(Engine.pollTimeoutText)]))
                continue
            }
            // A busy add-on (in the middle of a long poll that is still within its wait) isn't hung.
            if await process.isBusy { continue }
            do {
                _ = try await process.call("ping", timeout: .seconds(10))
            } catch {
                await process.stop()
                processes[id] = nil
                try? await store.appendAudit(actor: id, action: "plugin.unresponsive", detail: .object(["error": .string("\(error)")]))
            }
        }
    }

    /// Stops one add-on; it starts again (with fresh settings) the next time it's needed.
    public func restart(_ id: String) async {
        await processes[id]?.stop()
        processes[id] = nil
        retryAt[id] = nil
    }

    /// Stops an add-on only when it isn't answering anything right now (the memory-saving stop after a check).
    public func restartIfIdle(_ id: String) async {
        guard let process = processes[id] else { return }
        if await process.isBusy { return }
        guard processes[id] === process else { return }   // replaced while we looked
        await restart(id)
    }

    public func stopAll() async {
        for process in processes.values { await process.stop() }
        processes.removeAll()
    }

    static func answer(_ message: WireMessage, manifest: PluginManifest, gate: NetworkGate,
                       mac: (any MacAbilities)?, store: Store, settings: JSONValue = .object([:]),
                       tally: HTTPTally? = nil) async -> WireMessage {
        switch message.method {
        case "mac":
            let ability = message.params?[path: "ability"]?.string ?? ""
            do {
                guard manifest.permissions.mac.contains(ability) else {
                    throw WireError("blocked_ability", "\(manifest.name) did not declare “\(ability)”")
                }
                let params = message.params?[path: "params"] ?? .object([:])
                let result: JSONValue
                switch ability {
                case "launchd.list":
                    let prefixes = params[path: "prefixes"]?.array?.compactMap(\.string) ?? []
                    result = try await LocalCommands.launchdJobs(prefixes: prefixes, withRuns: params[path: "runs"] == .bool(true),
                                                                  watch: Set(params[path: "watch"]?.array?.compactMap(\.string) ?? []))
                case "script.run":
                    result = try await LocalCommands.runFeedScript(params: params, settings: settings)
                case "xfile.read":
                    // Only the X file chosen in Settings (and the digest beside it) is read; the add-on can't pick a path.
                    result = LocalCommands.readXFile(settings: settings)
                    var detail: [String: JSONValue] = ["status": result[path: "status"] ?? .null,
                                                       "source": result[path: "source"] ?? .null,
                                                       "as_of": result[path: "as_of"] ?? .null]
                    if let r = result[path: "reason"], r != .null { detail["reason"] = r }
                    try? await store.appendAudit(actor: manifest.id, action: "plugin.mac", subject: ability, detail: .object(detail))
                    return WireMessage(id: message.id, result: result)
                default:
                    guard let mac else { throw WireError("unavailable", "Mac abilities are not available here") }
                    // iMessage goes only to the recipient you set for this add-on, never one it picks itself.
                    if ability == "messages.send" {
                        let set = (settings[path: "to"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        let asked = (params[path: "to"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !set.isEmpty, asked == set else {
                            throw WireError("not_allowed", "Messages go only to the recipient set in this add-on's settings")
                        }
                    }
                    result = try await mac.perform(ability, params: params)
                }
                try? await store.appendAudit(actor: manifest.id, action: "plugin.mac", subject: ability)
                return WireMessage(id: message.id, result: result)
            } catch {
                let wireError = error as? WireError ?? WireError("mac_failed", "\(error)")
                try? await store.appendAudit(actor: manifest.id, action: "plugin.mac_blocked", subject: ability,
                                             detail: .object(["error": .string(wireError.description)]))
                return WireMessage(id: message.id, error: wireError)
            }
        case "http":
            do {
                let spec = try (message.params ?? .null).decode(HTTPRequestSpec.self)
                let response = try await gate.perform(spec, for: manifest)
                // Counted, then written as one summary row per check (flushHTTP); without a tally, one row each.
                if let tally {
                    await tally.add(manifest.id, host: URL(string: spec.url)?.host() ?? "?", status: response.status)
                } else {
                    try? await store.appendAudit(actor: manifest.id, action: "plugin.http",
                                                 subject: URL(string: spec.url)?.host(),
                                                 detail: .object(["method": .string(spec.method.uppercased()),
                                                                  "status": .number(Double(response.status))]))
                }
                return WireMessage(id: message.id, result: try JSONValue(encoding: response))
            } catch {
                let wireError = error as? WireError ?? WireError("http_failed", error.localizedDescription)
                try? await store.appendAudit(actor: manifest.id, action: "plugin.http_blocked",
                                             detail: .object(["error": .string(wireError.description)]))
                return WireMessage(id: message.id, error: wireError)
            }
        default:
            return WireMessage(id: message.id, error: WireError("unknown_method", "The app has no “\(message.method ?? "")” request"))
        }
    }
}

extension Store {
    public func approvePlugin(id: String, fingerprint: String, permissionsHash: String? = nil, by person: String) throws {
        let perms = permissionsHash ?? fingerprint
        try db.transaction {
            let t = now()
            try db.execute("""
                INSERT OR REPLACE INTO plugin_approvals (plugin_id, manifest_sha, permissions_sha, approved_at, approved_by, signature)
                VALUES (?, ?, ?, ?, ?, ?)
                """, [.text(id), .text(fingerprint), .text(perms), .integer(t), .text(person),
                      trustKey.map { .text(Self.sign(id: id, sha: perms, at: t, key: $0)) } ?? .null])
            try audit(actor: person, action: "plugin.approved", subject: "plugin:\(id)",
                                         detail: .object(["fingerprint": .string(fingerprint), "permissions": .string(perms)]))
        }
    }

    /// Add-ons you approved at some point (any version), so a changed one can be told apart from a new one.
    public func everApprovedPlugins() throws -> Set<String> {
        Set(try db.query("SELECT plugin_id FROM plugin_approvals").compactMap { $0.string("plugin_id") })
    }

    /// With a signing key set (the app's, kept in the Keychain), an approval counts only when its signature matches:
    /// a row written into the database by anything other than the app (or a changed one) isn't an approval.
    public func isPluginApproved(id: String, fingerprint: String, permissionsHash: String? = nil) throws -> Bool {
        let perms = permissionsHash ?? fingerprint
        guard let row = try db.query(
            "SELECT manifest_sha, permissions_sha, approved_at, signature FROM plugin_approvals WHERE plugin_id = ?",
            [.text(id)]).first else { return false }
        guard let key = trustKey else { return !requireSignedApprovals }
        guard let sig = row.string("signature"), let at = row.int("approved_at") else { return false }

        func bad() -> Bool {
            if !reportedForged.contains(id) {
                reportedForged.insert(id)
                try? audit(actor: "app", action: "trust.approval_not_signed", subject: "plugin:\(id)",
                           detail: .object(["note": .string("An approval not made in Hmunmawi (or changed since): ignored; approve it again in Settings.")]))
            }
            return false
        }

        if let stored = row.string("permissions_sha"), !stored.isEmpty {
            guard stored == perms, sig == Self.sign(id: id, sha: stored, at: at, key: key) else { return bad() }
            if row.string("manifest_sha") != fingerprint {
                try db.execute("UPDATE plugin_approvals SET manifest_sha = ? WHERE plugin_id = ?",
                               [.text(fingerprint), .text(id)])
            }
            return true
        }
        // Older rows signed on the full bundle fingerprint.
        guard let storedFp = row.string("manifest_sha"), storedFp == fingerprint,
              sig == Self.sign(id: id, sha: fingerprint, at: at, key: key) else { return bad() }
        try db.transaction {
            try db.execute("""
                UPDATE plugin_approvals SET permissions_sha = ?, signature = ? WHERE plugin_id = ?
                """, [.text(perms), .text(Self.sign(id: id, sha: perms, at: at, key: key)), .text(id)])
        }
        return true
    }

    /// Signs the approvals that have no signature yet (once, when signing is first switched on: today's approvals
    /// are trusted as they are). Returns how many.
    @discardableResult
    public func signUnsignedApprovals() throws -> Int {
        guard let key = trustKey else { return 0 }
        let rows = try db.query("SELECT plugin_id, manifest_sha, permissions_sha, approved_at FROM plugin_approvals WHERE signature IS NULL")
        try db.transaction {
            for r in rows {
                guard let id = r.string("plugin_id"), let at = r.int("approved_at") else { continue }
                let subject = r.string("permissions_sha").flatMap { $0.isEmpty ? nil : $0 } ?? r.string("manifest_sha")
                guard let subject else { continue }
                try db.execute("UPDATE plugin_approvals SET signature = ? WHERE plugin_id = ?",
                               [.text(Self.sign(id: id, sha: subject, at: at, key: key)), .text(id)])
            }
        }
        return rows.count
    }

    /// Re-signs every stored approval with the current trust key (same manifest and approval time). Used when the
    /// Keychain trust key changes but add-on code did not, for example after rebuilding with a new Developer certificate.
    @discardableResult
    public func resignAllApprovals() throws -> Int {
        guard let key = trustKey else { return 0 }
        let rows = try db.query("SELECT plugin_id, manifest_sha, permissions_sha, approved_at FROM plugin_approvals WHERE signature IS NOT NULL")
        try db.transaction {
            for r in rows {
                guard let id = r.string("plugin_id"), let at = r.int("approved_at") else { continue }
                let subject = r.string("permissions_sha").flatMap { $0.isEmpty ? nil : $0 } ?? r.string("manifest_sha")
                guard let subject else { continue }
                try db.execute("UPDATE plugin_approvals SET signature = ? WHERE plugin_id = ?",
                               [.text(Self.sign(id: id, sha: subject, at: at, key: key)), .text(id)])
            }
        }
        return rows.count
    }

    /// HMAC-SHA256 of one approval, hex.
    public static func sign(id: String, sha: String, at: Millis, key: SymmetricKey) -> String {
        HMAC<SHA256>.authenticationCode(for: Data("approval|\(id)|\(sha)|\(at)".utf8), using: key).map { String(format: "%02x", $0) }.joined()
    }
}

/// Web requests per add-on, counted between log rows.
public actor HTTPTally {
    public struct Sum: Sendable { var count = 0; var hosts: [String: Int] = [:]; var statuses: [String: Int] = [:] }
    private var sums: [String: Sum] = [:]
    func add(_ id: String, host: String, status: Int) {
        var s = sums[id] ?? Sum()
        s.count += 1; s.hosts[host, default: 0] += 1; s.statuses[String(status), default: 0] += 1
        sums[id] = s
    }
    func take(_ id: String) -> Sum? { sums.removeValue(forKey: id) }
}
