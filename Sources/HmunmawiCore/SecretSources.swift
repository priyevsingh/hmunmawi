import Foundation

/// Where a connection secret was picked from. Only paths and field names are stored, never the secret value.
public struct SecretSourceRef: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case envLine
        case tomlKey
        case wholeFile
        case tomlPathFile
    }

    public var path: String
    public var kind: Kind
    /// Env var name, TOML key, or (for `tomlPathFile`) the TOML key whose value is a path to the secret file.
    public var field: String

    public init(path: String, kind: Kind, field: String) {
        self.path = path
        self.kind = kind
        self.field = field
    }
}

public struct SecretSourceCatalog: Sendable {
    public static let fileName = "secret-sources.json"
    private let url: URL
    private let lock = NSLock()

    public let fileURL: URL
    public init(url: URL) { self.url = url; self.fileURL = url }

    private struct Entry: Codable {
        var sources: [String: SecretSourceRef] = [:]
    }

    private func load() -> Entry {
        guard let data = try? Data(contentsOf: url),
              let e = try? JSONDecoder().decode(Entry.self, from: data) else { return Entry() }
        return e
    }

    private func save(_ entry: Entry) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func key(plugin: String, name: String) -> String { "\(plugin)/\(name)" }

    public func record(plugin: String, name: String, ref: SecretSourceRef) {
        lock.lock()
        defer { lock.unlock() }
        var entry = load()
        entry.sources[Self.key(plugin: plugin, name: name)] = ref
        save(entry)
    }

    public func ref(plugin: String, name: String) -> SecretSourceRef? {
        lock.lock()
        defer { lock.unlock() }
        return load().sources[Self.key(plugin: plugin, name: name)]
    }

    public func allPluginNames() -> [(String, String)] {
        lock.lock()
        defer { lock.unlock() }
        return load().sources.keys.compactMap { k in
            let parts = k.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return (parts[0], parts[1])
        }
    }
}

/// Reads each file at most once during one rebind pass and remembers which ones macOS refused (a protected folder
/// such as Documents, Desktop, Downloads, iCloud or a removable volume). A second key from the same file costs no
/// second read, so macOS asks at most once per folder per pass. `read` is replaceable so tests can stand in a slow
/// or refused file.
public final class SecretReadPass: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String: String?] = [:]
    private var refused = Set<String>()
    private let read: @Sendable (String) -> (text: String?, refused: Bool)

    public init(read: @escaping @Sendable (String) -> (text: String?, refused: Bool) = SecretReadPass.readFile) {
        self.read = read
    }

    public static let readFile: @Sendable (String) -> (text: String?, refused: Bool) = { path in
        do {
            return (try String(contentsOfFile: path, encoding: .utf8), false)
        } catch let e as NSError {
            let underlying = (e.userInfo[NSUnderlyingErrorKey] as? NSError)?.code
            let denied = (e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoPermissionError)
                || (e.domain == NSPOSIXErrorDomain && (e.code == Int(EPERM) || e.code == Int(EACCES)))
                || underlying == Int(EPERM) || underlying == Int(EACCES)
            return (nil, denied)
        }
    }

    public func text(_ path: String) -> String? {
        lock.lock()
        if let hit = texts[path] { lock.unlock(); return hit }
        lock.unlock()
        let r = read(path)   // never under the lock: a read can wait on a macOS prompt
        lock.lock()
        defer { lock.unlock() }
        if let hit = texts[path] { return hit }
        texts[path] = .some(r.text)
        if r.refused { refused.insert(path) }
        return r.text
    }

    /// Paths macOS refused to read during this pass.
    public var refusedPaths: Set<String> { lock.lock(); defer { lock.unlock() }; return refused }
    public func wasRefused(_ path: String) -> Bool { lock.lock(); defer { lock.unlock() }; return refused.contains(path) }
}

/// Reads secrets from local files the app is already allowed to read (no network).
public enum SecretFileReader {
    public static func value(ref: SecretSourceRef, pass: SecretReadPass? = nil) -> String? {
        let path = NSString(string: ref.path).expandingTildeInPath
        let load: (String) -> String? = { p in pass?.text(p) ?? (pass == nil ? try? String(contentsOfFile: p, encoding: .utf8) : nil) }
        switch ref.kind {
        case .envLine:
            return load(path).flatMap { envValue(text: $0, key: ref.field) }
        case .tomlKey:
            return load(path).flatMap { tomlValue(text: $0, key: ref.field) }
        case .wholeFile:
            return load(path)
        case .tomlPathFile:
            guard let inner = load(path).flatMap({ tomlValue(text: $0, key: ref.field) }) else { return nil }
            return load(inner)
        }
    }

    public static func envValue(path: String, key: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return envValue(text: text, key: key)
    }

    static func envValue(text: String, key: String) -> String? {
        let want = key.uppercased()
        for line in text.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "export ", with: "")
            guard !l.hasPrefix("#"), let eq = l.firstIndex(of: "=") else { continue }
            let name = String(l[..<eq])
            guard name.uppercased() == want else { continue }
            return envRHS(String(l[l.index(after: eq)...]))
        }
        return nil
    }

    public static func tomlValue(path: String, key: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return tomlValue(text: text, key: key)
    }

    static func tomlValue(text: String, key: String) -> String? {
        let pattern = try? NSRegularExpression(pattern: "^\(NSRegularExpression.escapedPattern(for: key))\\s*=\\s*\"([^\"]+)\"", options: [.anchorsMatchLines])
        guard let pattern, let m = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    public static func wholeFile(path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    private static func envRHS(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if !s.hasPrefix("\""), !s.hasPrefix("'"), let hash = s.range(of: " #") { s = String(s[..<hash.lowerBound]) }
        let value = s.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        return value.isEmpty ? nil : value
    }
}

/// Where the owner's own key files live (see `OwnerConfig`): nothing on a normal install, so a new user's keys are
/// only ever read from places they chose. No secret values here.
public enum SecretSourceDefaults {
    public static func home() -> URL { .homeDirectory }

    /// The owner's script hub (nil unless owner extras are on).
    public static func hub() -> URL? { OwnerConfig.current.hubURL }

    /// The owner's key folder of `.env` files (nil unless owner extras are on).
    public static func keyFolder() -> URL? { OwnerConfig.current.keyFolderURL }

    /// The owner's App Store Connect config.toml (nil unless owner extras are on).
    public static func ascConfig() -> URL? { OwnerConfig.current.ascConfigURL }

    /// Which file and field holds each connection key in the owner's key folder (names only, no values).
    static let keyFolderFields: [String: (file: String, kind: SecretSourceRef.Kind, field: String)] = [
        "posthog/apiKey": ("posthog.env", .envLine, "POSTHOG_API_KEY"),
        "sentry/authToken": ("sentry.env", .envLine, "SENTRY_AUTH_TOKEN"),
        "bing/apiKey": ("bing.env", .envLine, "BING_WEBMASTER_API_KEY"),
        "cloudflare/apiToken": ("cloudflare_analytics.env", .envLine, "CF_ANALYTICS_TOKEN"),
        "searchconsole/serviceAccount": ("gsc_service_account.json", .wholeFile, ""),
        "live/hookRelayKey": ("asn_relay.env", .envLine, "RELAY_KEY"),
        // Same file as the hooks key: the Pages purchase outbox uses this name.
        "live/relayKey": ("asn_relay.env", .envLine, "RELAY_KEY"),
        "live/hookCloudflareToken": ("cloudflare_analytics.env", .envLine, "CF_ANALYTICS_TOKEN"),
        // The YouTube sign-in the hub's upload and stats scripts already use (client id/secret + refresh token).
        "youtube/signIn": ("youtube_token.json", .wholeFile, ""),
    ]

    /// Where a key typed in Settings is also kept, so a changed app signature (an old Keychain item no longer
    /// readable) recovers without typing it again. Owner extras only: a normal install keeps keys in the Keychain
    /// alone. One file per key, `<add-on>.<key>`, mode 0600, folder 0700. `HMUNMAWI_TYPED_KEYS` overrides (tests).
    public static func typedKeyFolder() -> URL? {
        if let p = ProcessInfo.processInfo.environment["HMUNMAWI_TYPED_KEYS"], !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
        }
        guard OwnerConfig.current.enabled else { return nil }
        return home().appending(path: ".config/hmunmawi/keys", directoryHint: .isDirectory)
    }

    static func typedKeyURL(plugin: String, name: String, in folder: URL? = typedKeyFolder()) -> URL? {
        let safe = CharacterSet.alphanumerics
        guard !plugin.isEmpty, !name.isEmpty, plugin.unicodeScalars.allSatisfy(safe.contains), name.unicodeScalars.allSatisfy(safe.contains) else { return nil }
        return folder?.appending(path: "\(plugin).\(name)")
    }

    /// Writes a key typed in Settings to its 0600 file (see `typedKeyFolder`). No-op on a normal install.
    @discardableResult
    public static func mirrorTypedKey(_ value: String, plugin: String, name: String, in folder: URL? = typedKeyFolder()) -> Bool {
        guard !value.isEmpty, let url = typedKeyURL(plugin: plugin, name: name, in: folder) else { return false }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            // Create empty at 0600 first so the value is never readable by others, then replace atomically.
            let tmp = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).tmp")
            fm.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600])
            try Data(value.utf8).write(to: tmp)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
            return true
        } catch { return false }
    }

    /// Every `<add-on>.<key>` pair that has a typed-key file.
    public static func typedKeyPairs() -> [(String, String)] {
        guard let dir = typedKeyFolder(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.compactMap { n in
            guard !n.hasPrefix("."), let dot = n.firstIndex(of: ".") else { return nil }
            let plugin = String(n[..<dot]), name = String(n[n.index(after: dot)...])
            return plugin.isEmpty || name.isEmpty ? nil : (plugin, name)
        }
    }

    public static func ref(plugin: String, name: String, keyFolder keys: URL? = keyFolder(),
                           typedFolder: URL? = typedKeyFolder()) -> SecretSourceRef? {
        func existing(_ url: URL?, _ kind: SecretSourceRef.Kind, _ field: String) -> SecretSourceRef? {
            guard let p = url?.path, FileManager.default.fileExists(atPath: p) else { return nil }
            return SecretSourceRef(path: p, kind: kind, field: field)
        }
        switch (plugin, name) {
        case ("appstoreconnect", "issuerID"): return existing(ascConfig(), .tomlKey, "issuer_id")
        case ("appstoreconnect", "keyID"): return existing(ascConfig(), .tomlKey, "key_id")
        case ("appstoreconnect", "privateKey"): return existing(ascConfig(), .tomlPathFile, "private_key_path")
        case ("sentry", "authToken"):
            return existing(keys?.appending(path: "sentry.env"), .envLine, "SENTRY_AUTH_TOKEN")
                ?? existing(ascConfig(), .tomlKey, "auth_token")
        default:
            if let f = keyFolderFields["\(plugin)/\(name)"],
               let r = existing(keys?.appending(path: f.file), f.kind, f.field) { return r }
            // A key typed in Settings and mirrored to its own file.
            return existing(typedKeyURL(plugin: plugin, name: name, in: typedFolder), .wholeFile, "")
        }
    }
}

/// What one rebind pass found. `needsAttention` holds `"<add-on>/<key>"` for every key that has a saved file but
/// could not be imported (macOS refused the file, or it is gone), so the add-on shows as needing attention.
public struct SecretRebindReport: Sendable, Equatable {
    public var rebound = 0
    public var needsAttention: [String] = []
    public var refusedPaths: [String] = []
    public init() {}
    /// Add-on ids with at least one key that needs attention.
    public var addOnIDs: [String] { Set(needsAttention.compactMap { $0.split(separator: "/").first.map(String.init) }).sorted() }
}

public enum SecretRebinder {
    /// Tries to read from the catalog or defaults and write into the Keychain with the current app signature.
    public static func rebind(store: KeychainSecretStore, catalog: SecretSourceCatalog, plugin: String, name: String,
                              pass: SecretReadPass? = nil) -> Bool {
        if (try? store.peekSecret(plugin: plugin, name: name))?.isEmpty == false { return true }
        guard let value = readValue(catalog: catalog, plugin: plugin, name: name, pass: pass), !value.isEmpty else { return false }
        do {
            try store.replaceSecret(value, plugin: plugin, name: name)
            if let ref = catalog.ref(plugin: plugin, name: name) ?? SecretSourceDefaults.ref(plugin: plugin, name: name) {
                catalog.record(plugin: plugin, name: name, ref: ref)
            }
        } catch {
            return false
        }
        return (try? store.peekSecret(plugin: plugin, name: name))?.isEmpty == false
    }

    public static func rebindAll(store: KeychainSecretStore, catalog: SecretSourceCatalog, pass: SecretReadPass? = nil) -> Int {
        rebindPass(store: store, catalog: catalog, pass: pass ?? SecretReadPass()).rebound
    }

    /// One pass over every saved key. Each file is read at most once (`pass`), and a key that can't be imported is
    /// reported instead of retried. Slow or refused reads only ever delay this pass, never the caller's thread
    /// (the app runs it in the background).
    public static func rebindPass(store: KeychainSecretStore, catalog: SecretSourceCatalog, pass: SecretReadPass) -> SecretRebindReport {
        var report = SecretRebindReport()
        var seen = Set<String>()
        var pairs = catalog.allPluginNames()
        pairs += Self.builtInConnectionSecrets()
        for (plugin, name) in pairs {
            let k = "\(plugin)/\(name)"
            guard seen.insert(k).inserted else { continue }
            if rebind(store: store, catalog: catalog, plugin: plugin, name: name, pass: pass) {
                report.rebound += 1
            } else if hasSavedSource(catalog: catalog, plugin: plugin, name: name) {
                report.needsAttention.append(k)
            }
        }
        report.refusedPaths = pass.refusedPaths.sorted()
        return report
    }

    private static func hasSavedSource(catalog: SecretSourceCatalog, plugin: String, name: String) -> Bool {
        catalog.ref(plugin: plugin, name: name) != nil || SecretSourceDefaults.ref(plugin: plugin, name: name) != nil
    }

    /// Every built-in connection key as `"<add-on>/<field>"` (used by the legacy migration too).
    public static var connectionSecretNames: [String] { builtInConnectionSecrets().map { "\($0.0)/\($0.1)" }  }

    private static func builtInConnectionSecrets() -> [(String, String)] {
        [
            ("appstoreconnect", "issuerID"), ("appstoreconnect", "keyID"), ("appstoreconnect", "privateKey"),
            ("posthog", "apiKey"), ("sentry", "authToken"), ("bing", "apiKey"),
            ("cloudflare", "apiToken"), ("searchconsole", "serviceAccount"),
            ("live", "hookRelayKey"), ("live", "hookCloudflareToken"),
            ("youtube", "apiKey"), ("youtube", "signIn"),
        ] + SecretSourceDefaults.typedKeyPairs()
    }

    private static func readValue(catalog: SecretSourceCatalog, plugin: String, name: String, pass: SecretReadPass?) -> String? {
        if let r = catalog.ref(plugin: plugin, name: name), let v = SecretFileReader.value(ref: r, pass: pass), !v.isEmpty { return v }
        if let r = SecretSourceDefaults.ref(plugin: plugin, name: name), let v = SecretFileReader.value(ref: r, pass: pass), !v.isEmpty { return v }
        return nil
    }
}
